//
//  repro-signingd.m
//  RePro 后台定时续签守护进程
//
//  以 root 身份由 launchd 拉起（RunAtLoad + KeepAlive），运行在 App jbroot
//  namespace 外。职责：定时检查并触发续签。
//  - 到达续签时间：写触发标记 + notify_post 通知 App
//  - App 运行中 → 立即执行续签，写结果到 /tmp/reprorefresh_at.log
//  - App 未运行 → 标记保留，下次 App 打开时自动处理
//  - 所有日志写入 /tmp/reprorefresh_at.log（daemon + App 共同维护）
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <dlfcn.h>
#import <Foundation/Foundation.h>

// ─── 常量 ────────────────────────────────────────────────────────

static NSString *const kIpcDir          = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath      = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kTriggerPath     = @"/var/mobile/Library/RePro/auto-resign-trigger";
static NSString *const kLogPath         = @"/tmp/reprorefresh_at.log";
static NSString *const kAppBundleID     = @"com.reprovision.repro";

static const BOOL       kDefaultAutoResign    = YES;
static const NSInteger  kDefaultCheckMinutes  = 360;
static const NSInteger  kDefaultThreshold     = 2;
static const NSTimeInterval kMinTimerInterval = 60.0;

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
    gLogFile = fopen(kLogPath.UTF8String, "a");
    if (!gLogFile) {
        NSLog(@"[repro-signingd] 无法打开日志 %@: %s", kLogPath, strerror(errno));
        return NO;
    }
    chown(kLogPath.UTF8String, 501, 501);
    chmod(kLogPath.UTF8String, 0644);
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
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    return cfg ?: @{
        @"autoResign":       @(kDefaultAutoResign),
        @"checkIntervalMin": @(kDefaultCheckMinutes),
        @"resignThreshold":  @(kDefaultThreshold),
    };
}

// ─── 后台拉起 App ───────────────────────────────────────────────
//
// 使用 SpringBoardServices 私有 API 以后台 content-fetch 模式拉起 App，
// App 在 didFinishLaunchingWithOptions 中检测触发标记后执行续签。
// daemon 无 entitlements 时该调用会失败，降级为纯 notify_post 方案。

static BOOL SDLaunchAppBackgrounded(void) {
    // 动态加载 SpringBoardServices
    void *sbsHandle = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_LAZY);
    if (!sbsHandle) {
        SDLog(@"⚠ 无法加载 SpringBoardServices（将降级为 notify 方案）");
        return NO;
    }

    typedef int (*SBSLaunchFunc)(CFStringRef, CFDictionaryRef, BOOL);
    SBSLaunchFunc SBSLaunch =
        (SBSLaunchFunc)dlsym(sbsHandle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
    if (!SBSLaunch) {
        SDLog(@"⚠ 无法找到 SBSLaunchApplicationWithIdentifierAndLaunchOptions");
        dlclose(sbsHandle);
        return NO;
    }

    // BKSActivateForEventOptionTypeBackgroundContentFetching = 后台拉起的 key
    NSString *eventKey = @"BKSActivateForEventOptionTypeBackgroundContentFetching";
    NSString *optionKey = @"BKSOpenApplicationOptionKeyActivateForEvent";

    NSDictionary *eventOpts = @{ eventKey: @"" };
    NSDictionary *launchOpts = @{ optionKey: eventOpts };

    int result = SBSLaunch(CFSTR("com.reprovision.repro"),
                           (__bridge CFDictionaryRef)launchOpts,
                           YES); // YES = suspended（后台）

    dlclose(sbsHandle);

    if (result == 0) {
        SDLog(@"✅ 已后台拉起 App（pid 将由 App 侧写入日志）");
        return YES;
    } else {
        SDLog(@"⚠ 后台拉起 App 失败（错误码 %d，可能缺少 entitlements）", result);
        return NO;
    }
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

    // 写触发标记（App 检测此文件判断是否由 daemon 触发）
    NSDictionary *trigger = @{
        @"timestamp": @(now),
        @"threshold": @(threshold),
    };
    [trigger writeToFile:kTriggerPath atomically:YES];
    chown(kTriggerPath.UTF8String, 501, 501);

    // 写日志
    SDLog(@"══════ 定时续签触发 ══════");
    SDLog(@"阈值: %ld 天, 触发时间戳: %lld", (long)threshold, (long long)now);

    // 尝试后台拉起 App 执行续签
    BOOL launched = SDLaunchAppBackgrounded();

    // 同时 notify_post（App 在前台时能收到）
    notify_post("com.reprovision.schedule-resign");

    if (launched) {
        SDLog(@"续签触发完成 → App 已后台拉起，等待 App 写入续签结果…");
    } else {
        SDLog(@"续签触发完成 → App 未运行，续签将在 App 下次打开时自动执行");
    }
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
    SDLog(@"repro-signingd 启动, pid=%d uid=%d", getpid(), getuid());
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
