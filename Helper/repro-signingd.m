//
//  repro-signingd.m
//  RePro 后台定时续签守护进程
//
//  由 launchd 在系统启动时拉起（RunAtLoad / KeepAlive），完全在 App jbroot
//  namespace 外运行。用 NSTimer 定时触发续签检查。
//
//  与 App 通过 /var/mobile/Library/RePro/ 共享路径通信：
//  1. App 把 autoResign/checkInterval/resignThreshold 写入 signingd-config.plist
//  2. Daemon NSTimer fire 时读配置，写 auto-resign-request（时间戳）
//     和 auto-resign-notification.plist（通知标题+正文）
//  3. notify_post 通知 App（如果 App 正在前台运行则立即处理）
//  4. App 下次 didBecomeActive 时检查 request 文件 → 执行续签
//     → 完成/失败后把通知内容显示给用户
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir              = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath          = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kRequestPath         = @"/var/mobile/Library/RePro/auto-resign-request";
static NSString *const kNotificationPath    = @"/var/mobile/Library/RePro/auto-resign-notification.plist";
static NSString *const kNotifyName          = @"com.reprovision.schedule-resign";

static const BOOL       kDefaultAutoResign    = YES;
static const NSInteger  kDefaultCheckInterval = 6;     // 小时
static const NSInteger  kDefaultThreshold     = 2;     // 天
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

// MARK: - 触发续签 + 写通知内容

/// 写时间戳 + 通知内容到共享路径，然后 notify_post 通知 App。
/// App（前台时）或下次打开时读到这些东西后执行续签，并把通知内容展示给用户。
static void SDFireResignRequest(void) {
    NSDictionary *cfg = SDLoadConfig();
    NSInteger threshold = [cfg[@"resignThreshold"] integerValue];
    if (threshold < 1) threshold = kDefaultThreshold;
    time_t now = time(NULL);

    SDEnsureIpcDir();

    // 1. 时间戳请求
    NSString *ts = [NSString stringWithFormat:@"%lld", (long long)now];
    NSError *err;
    [ts writeToFile:kRequestPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    chown(kRequestPath.UTF8String, 501, 501);

    // 2. 通知内容（App 在续签结束后显示给用户）
    //    这里只写 daemon 触发时的预告；续签的实际结果由 App 覆盖写入。
    NSDictionary *noti = @{
        @"title": @"后台定时续签检查",
        @"body":  [NSString stringWithFormat:@"repro-signingd 已触发续签检查（阈值 %ld 天），下次打开 RePro 将自动续签", (long)threshold],
        @"timestamp": @(now),
    };
    [noti writeToFile:kNotificationPath atomically:YES];
    chown(kNotificationPath.UTF8String, 501, 501);

    // 3. 发 notify
    notify_post(kNotifyName.UTF8String);
    SDLog(@"已触发自动续签（阈值 %ld 天），通知内容已写入共享路径", (long)threshold);
}

// MARK: - NSTimer 驱动

static NSTimer *gSigningTimer;
static time_t   gLastFireTime;

static void SDScheduleTimer(NSTimeInterval interval) {
    [gSigningTimer invalidate];
    gSigningTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        NSDictionary *cfg = SDLoadConfig();
        if (![cfg[@"autoResign"] boolValue]) {
            SDLog(@"自动续签已关闭，跳过本次检查");
            return;
        }
        time_t now = time(NULL);
        if (now - gLastFireTime < 60) return;
        gLastFireTime = now;
        SDFireResignRequest();
    }];
}

// MARK: - main

int main(void) {
    SDLog(@"启动，pid=%d", getpid());
    SDEnsureIpcDir();

    NSDictionary *cfg = SDLoadConfig();
    NSInteger intervalHours = [cfg[@"checkInterval"] integerValue];
    if (intervalHours < 1) intervalHours = kDefaultCheckInterval;
    NSTimeInterval interval = MAX((NSTimeInterval)intervalHours * 3600.0, kMinTimerInterval);

    BOOL autoResign = [cfg[@"autoResign"] boolValue];
    SDLog(@"自动续签: %@, 间隔: %.0f 分钟, 阈值: %@ 天",
          autoResign ? @"开启" : @"关闭",
          interval / 60.0,
          cfg[@"resignThreshold"] ?: @(kDefaultThreshold));

    SDScheduleTimer(interval);

    // 收到 App 的配置更新通知时重新加载
    int token;
    notify_register_dispatch("com.reprovision.signingd-config-updated", &token,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"收到配置更新通知，重新加载");
            NSDictionary *c = SDLoadConfig();
            BOOL ar = [c[@"autoResign"] boolValue];
            NSInteger ih = [c[@"checkInterval"] integerValue];
            if (ih < 1) ih = kDefaultCheckInterval;
            NSTimeInterval inv = MAX((NSTimeInterval)ih * 3600.0, kMinTimerInterval);
            SDLog(@"自动续签: %@, 间隔: %.0f 分钟",
                  ar ? @"开启" : @"关闭", inv / 60.0);
            SDScheduleTimer(inv);
        });

    [[NSRunLoop mainRunLoop] run];
    return 0;
}
