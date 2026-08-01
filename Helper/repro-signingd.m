//
//  repro-signingd.m
//  RePro 后台定时续签守护进程
//
//  以 root 身份由 launchd 拉起（RunAtLoad + KeepAlive），运行在 App jbroot
//  namespace 外。职责：定时检查是否需要续签，通过 notify_post + 共享文件
//  通知 App 执行自动续签。所有日志写入 /tmp/reprorefresh_at.log。
//
//  App 未运行时 daemon 独立完成检查并记录；App 下次打开时读取请求文件执行续签。
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#import <Foundation/Foundation.h>

// ─── 常量 ────────────────────────────────────────────────────────

static NSString *const kIpcDir          = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath      = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kRequestPath     = @"/var/mobile/Library/RePro/auto-resign-request";
static NSString *const kLogPath         = @"/tmp/reprorefresh_at.log";

static const BOOL       kDefaultAutoResign    = YES;
static const NSInteger  kDefaultCheckMinutes  = 360; // 默认 6 小时 = 360 分钟
static const NSInteger  kDefaultThreshold     = 2;
static const NSTimeInterval kMinTimerInterval = 60.0; // 最少 1 分钟

// ─── 文件日志 ─────────────────────────────────────────────────────

static FILE *gLogFile = NULL;

static void SDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    // 时间戳
    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    char ts[64];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_now);

    // 写文件日志（/tmp/reprorefresh_at.log）
    if (gLogFile) {
        fprintf(gLogFile, "[%s] %s\n", ts, msg.UTF8String);
        fflush(gLogFile);
    }

    // 同时 NSLog
    NSLog(@"[repro-signingd] %@", msg);
}

static BOOL SDOpenLog(void) {
    gLogFile = fopen(kLogPath.UTF8String, "a");
    if (!gLogFile) {
        NSLog(@"[repro-signingd] 无法打开日志文件 %@: %s", kLogPath, strerror(errno));
        return NO;
    }
    // 确保 mobile 用户也能读
    chown(kLogPath.UTF8String, 501, 501);
    chmod(kLogPath.UTF8String, 0644);
    return YES;
}

// ─── IPC 目录 ────────────────────────────────────────────────────

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

// ─── 配置 ────────────────────────────────────────────────────────

static NSDictionary *SDLoadConfig(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    return cfg ?: @{
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

    NSString *ts = [NSString stringWithFormat:@"%lld", (long long)now];
    [ts writeToFile:kRequestPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chown(kRequestPath.UTF8String, 501, 501);

    notify_post("com.reprovision.schedule-resign");

    NSInteger threshold = [cfg[@"resignThreshold"] integerValue];
    if (threshold < 1) threshold = kDefaultThreshold;
    SDLog(@"已触发自动续签请求（阈值 %ld 天，时间戳 %@）", (long)threshold, ts);
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
    SDOpenLog();
    SDLog(@"══════════════════════════════════════");
    SDLog(@"repro-signingd 启动，pid=%d uid=%d", getpid(), getuid());
    SDEnsureIpcDir();

    NSDictionary *cfg = SDLoadConfig();
    NSInteger intervalMin = [cfg[@"checkIntervalMin"] integerValue];
    if (intervalMin < 1) intervalMin = kDefaultCheckMinutes;
    NSTimeInterval interval = MAX((NSTimeInterval)intervalMin * 60.0, kMinTimerInterval);

    SDLog(@"自动续签: %@, 检查间隔: %ld 分钟, 阈值: %@ 天",
          [cfg[@"autoResign"] boolValue] ? @"开启" : @"关闭",
          (long)intervalMin,
          cfg[@"resignThreshold"] ?: @(kDefaultThreshold));

    // 启动时立即检查一次
    if ([cfg[@"autoResign"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            SDFireResignRequest();
        });
    }

    SDScheduleTimer(interval);

    // 监听配置更新
    int configToken;
    notify_register_dispatch("com.reprovision.signingd-config-updated", &configToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"收到配置更新，重新加载");
            NSDictionary *c = SDLoadConfig();
            NSInteger im = [c[@"checkIntervalMin"] integerValue];
            if (im < 1) im = kDefaultCheckMinutes;
            NSTimeInterval inv = MAX((NSTimeInterval)im * 60.0, kMinTimerInterval);
            SDLog(@"新配置 — 自动续签: %@, 间隔: %ld 分钟",
                  [c[@"autoResign"] boolValue] ? @"开启" : @"关闭", (long)im);
            SDScheduleTimer(inv);
        });

    // 监听 App 续签完成
    int completeToken;
    notify_register_dispatch("com.reprovision.signing-complete", &completeToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"App 续签完成");
        });

    [[NSRunLoop mainRunLoop] run];
    return 0;
}
