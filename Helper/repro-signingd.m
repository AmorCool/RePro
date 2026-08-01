//
//  repro-signingd.m
//  RePro 后台定时续签守护进程（全程静默，不依赖拉 App）
//
//  以 root 身份由 launchd 拉起（RunAtLoad + KeepAlive），运行在 App jbroot
//  namespace 外。职责：定时检查 → 到达续签时间 → 写触发标记 + 通知 App。
//  App 运行中立即执行续签，未运行时下次打开时处理。全部日志写入
//  <jbroot>/var/log/reprorefresh_at.log。
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#import <Foundation/Foundation.h>

// ─── 常量 ────────────────────────────────────────────────────────

static NSString *const kIpcDir          = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath      = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kTriggerPath     = @"/var/mobile/Library/RePro/auto-resign-trigger";

static const BOOL       kDefaultAutoResign    = YES;
static const NSInteger  kDefaultCheckMinutes  = 360;
static const NSInteger  kDefaultThreshold     = 2;
static const NSTimeInterval kMinTimerInterval = 60.0;

// ─── 日志路径（动态：从 daemon 自身路径推导 jbroot）─────────────

static NSString *gLogPath = nil;

static NSString *SDResolveJbroot(void) {
    // 从 argv[0] 推导（launchd 会传绝对路径）
    NSString *argv0 = [[[NSProcessInfo processInfo] arguments] firstObject];
    if (argv0.length > 0 && [argv0 containsString:@"/usr/libexec/"]) {
        NSRange r = [argv0 rangeOfString:@"/usr/libexec/" options:NSBackwardsSearch];
        if (r.location != NSNotFound) return [argv0 substringToIndex:r.location];
    }

    // 回退：扫描常见路径
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in @[@"/var/jb",
                             @"/private/var/jb",
                             @"/var/mobile/Containers/Shared/AppGroup"]) {
        NSString *test = [cand stringByAppendingPathComponent:@"usr/libexec/repro-signingd"];
        if ([fm fileExistsAtPath:test]) return cand;
    }

    // 最后回退
    return @"/var/jb";
}

// ─── 文件日志 ─────────────────────────────────────────────────────

static FILE *gLogFile = NULL;

static void SDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    char ts[64];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_now);

    if (gLogFile) {
        fprintf(gLogFile, "[%s] %s\n", ts, msg.UTF8String);
        fflush(gLogFile);
    }

    NSLog(@"[repro-signingd] %@", msg);
}

static BOOL SDOpenLog(void) {
    NSString *logDir = [gLogPath stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:logDir]) {
        [fm createDirectoryAtPath:logDir withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0755} error:nil];
    }

    gLogFile = fopen(gLogPath.UTF8String, "a");
    if (!gLogFile) {
        NSLog(@"[repro-signingd] 无法打开日志 %@: %s", gLogPath, strerror(errno));
        return NO;
    }
    chmod(gLogPath.UTF8String, 0644);
    return YES;
}

// ─── IPC ────────────────────────────────────────────────────────

static BOOL SDEnsureIpcDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kIpcDir]) return YES;
    NSError *err;
    if (![fm createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0755} error:&err]) {
        SDLog(@"创建 IPC 目录失败: %@", err);
        return NO;
    }
    chown(kIpcDir.UTF8String, 501, 501);
    return YES;
}

static NSDictionary *SDLoadConfig(void) {
    // 1. 优先读 App 同步的 plist
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (cfg) return cfg;

    // 2. 回退：从 CFPreferences 直接读 App 的 UserDefaults（跨进程，原 reprovisiond 方案）
    CFStringRef appID = CFSTR("com.reprovision.repro");
    CFPreferencesAppSynchronize(appID);
    CFArrayRef keys = CFPreferencesCopyKeyList(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        NSDictionary *prefs = (__bridge_transfer NSDictionary *)
            CFPreferencesCopyMultiple(keys, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
        if (prefs.count > 0) {
            // 适配 key 名：App 用 "resignThreshold" / "checkIntervalMin" / "autoResign"
            NSNumber *autoR = prefs[@"autoResign"];
            NSNumber *interval = prefs[@"checkIntervalMin"];
            NSNumber *threshold = prefs[@"resignThreshold"];
            return @{
                @"autoResign":       autoR ?: @(kDefaultAutoResign),
                @"checkIntervalMin": interval ?: @(kDefaultCheckMinutes),
                @"resignThreshold":  threshold ?: @(kDefaultThreshold),
            };
        }
    }
    return @{
        @"autoResign":       @(kDefaultAutoResign),
        @"checkIntervalMin": @(kDefaultCheckMinutes),
        @"resignThreshold":  @(kDefaultThreshold),
    };
}

// ─── NSTimer ────────────────────────────────────────────────────

static NSTimer *gSigningTimer;
static time_t   gLastFireTime;

static void SDFireResignRequest(void) {
    NSDictionary *cfg = SDLoadConfig();
    if (![cfg[@"autoResign"] boolValue]) {
        SDLog(@"自动续签已关闭，跳过");
        return;
    }

    time_t now = time(NULL);
    SDEnsureIpcDir();

    NSInteger threshold = [cfg[@"resignThreshold"] integerValue];
    if (threshold < 1) threshold = kDefaultThreshold;

    // 写触发标记
    NSDictionary *trigger = @{
        @"timestamp": @(now),
        @"threshold": @(threshold),
    };
    [trigger writeToFile:kTriggerPath atomically:YES];
    chown(kTriggerPath.UTF8String, 501, 501);

    // 通知 App（App 在前台/后台时立即处理，否则下次打开时处理）
    notify_post("com.reprovision.schedule-resign");

    SDLog(@"══════ 定时续签触发 ══════");
    SDLog(@"阈值: %ld 天 | App 运行中则立即续签，否则下次打开时自动处理", (long)threshold);
}

static void SDScheduleTimer(NSTimeInterval interval) {
    [gSigningTimer invalidate];
    gSigningTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        time_t now = time(NULL);
        if (now - gLastFireTime < 60) return;
        gLastFireTime = now;
        SDFireResignRequest();
    }];
}

// ─── main ───────────────────────────────────────────────────────

int main(void) {
    // 确定 jbroot 及日志路径
    NSString *jbroot = SDResolveJbroot();
    gLogPath = [jbroot stringByAppendingPathComponent:@"var/log/reprorefresh_at.log"];

    SDOpenLog();
    SDLog(@"══════════════════════════════════════");
    SDLog(@"repro-signingd 启动, pid=%d uid=%d, jbroot=%@", getpid(), getuid(), jbroot);
    SDEnsureIpcDir();

    NSDictionary *cfg = SDLoadConfig();
    NSInteger intervalMin = [cfg[@"checkIntervalMin"] integerValue];
    if (intervalMin < 1) intervalMin = kDefaultCheckMinutes;
    NSTimeInterval interval = MAX((NSTimeInterval)intervalMin * 60.0, kMinTimerInterval);

    SDLog(@"配置 — 自动续签: %@, 间隔: %ld 分钟, 阈值: %@ 天",
          [cfg[@"autoResign"] boolValue] ? @"开启" : @"关闭",
          (long)intervalMin,
          cfg[@"resignThreshold"] ?: @(kDefaultThreshold));

    if ([cfg[@"autoResign"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            SDFireResignRequest();
        });
    }

    SDScheduleTimer(interval);

    int configToken;
    notify_register_dispatch("com.reprovision.signingd-config-updated", &configToken,
        dispatch_get_main_queue(), ^(int unused) {
            NSDictionary *c = SDLoadConfig();
            NSInteger im = [c[@"checkIntervalMin"] integerValue];
            if (im < 1) im = kDefaultCheckMinutes;
            NSTimeInterval inv = MAX((NSTimeInterval)im * 60.0, kMinTimerInterval);
            SDLog(@"配置已更新 — 间隔: %ld 分钟", (long)im);
            SDScheduleTimer(inv);
        });

    int completeToken;
    notify_register_dispatch("com.reprovision.signing-complete", &completeToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"App 续签完成");
        });

    [[NSRunLoop mainRunLoop] run];
    return 0;
}
