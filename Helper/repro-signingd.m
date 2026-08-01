//
//  repro-signingd.m
//  RePro 后台定时续签守护进程
//
//  复刻原 ReProvision-Reborn reprovisiond 的调度逻辑：
//  - 以 root 身份由 launchd 在系统启动时拉起（RunAtLoad + KeepAlive）
//  - 运行在 App jbroot namespace 外
//  - NSTimer 定时检查是否需要续签
//  - 触发时写共享文件 + notify_post 通知 App
//  - App 收到后执行续签，完成后直接发 UNUserNotificationCenter 通知
//    （与原项目一致：daemon 不碰通知，App 自己发）
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir          = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath      = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kRequestPath     = @"/var/mobile/Library/RePro/auto-resign-request";

static const BOOL       kDefaultAutoResign    = YES;
static const NSInteger  kDefaultCheckInterval = 6;
static const NSInteger  kDefaultThreshold     = 2;
static const NSTimeInterval kMinTimerInterval = 3600.0;

static void SDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-signingd] %@", msg);
}

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
        @"autoResign":     @(kDefaultAutoResign),
        @"checkInterval":  @(kDefaultCheckInterval),
        @"resignThreshold":@(kDefaultThreshold),
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

    // 写时间戳到共享路径（App 在 didBecomeActive 时检查）
    NSString *ts = [NSString stringWithFormat:@"%lld", (long long)now];
    [ts writeToFile:kRequestPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chown(kRequestPath.UTF8String, 501, 501);

    // 通知 App（notify 跨 namespace）
    notify_post("com.reprovision.schedule-resign");

    NSInteger threshold = [cfg[@"resignThreshold"] integerValue];
    if (threshold < 1) threshold = kDefaultThreshold;
    SDLog(@"已触发自动续签请求（阈值 %ld 天）", (long)threshold);
}

static void SDScheduleTimer(NSTimeInterval interval) {
    [gSigningTimer invalidate];
    gSigningTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        time_t now = time(NULL);
        if (now - gLastFireTime < 60) return; // 防重复
        gLastFireTime = now;
        SDFireResignRequest();
    }];
}

// ─── main ───────────────────────────────────────────────────────

int main(void) {
    SDLog(@"启动，pid=%d，uid=%d", getpid(), getuid());
    SDEnsureIpcDir();

    NSDictionary *cfg = SDLoadConfig();
    NSInteger intervalHours = [cfg[@"checkInterval"] integerValue];
    if (intervalHours < 1) intervalHours = kDefaultCheckInterval;
    NSTimeInterval interval = MAX((NSTimeInterval)intervalHours * 3600.0, kMinTimerInterval);

    SDLog(@"自动续签: %@, 间隔: %.0f 分钟, 阈值: %@ 天",
          [cfg[@"autoResign"] boolValue] ? @"开启" : @"关闭",
          interval / 60.0,
          cfg[@"resignThreshold"] ?: @(kDefaultThreshold));

    // 启动时立即检查一次（如果自动续签已开启）
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
            SDLog(@"收到配置更新通知，重新加载");
            NSDictionary *c = SDLoadConfig();
            NSInteger ih = [c[@"checkInterval"] integerValue];
            if (ih < 1) ih = kDefaultCheckInterval;
            NSTimeInterval inv = MAX((NSTimeInterval)ih * 3600.0, kMinTimerInterval);
            SDLog(@"自动续签: %@, 间隔: %.0f 分钟",
                  [c[@"autoResign"] boolValue] ? @"开启" : @"关闭", inv / 60.0);
            SDScheduleTimer(inv);
        });

    // 监听 App 续签完成（匹配原项目 applicationDidFinishTask）
    int completeToken;
    notify_register_dispatch("com.reprovision.signing-complete", &completeToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"App 续签完成");
        });

    [[NSRunLoop mainRunLoop] run];
    return 0;
}
