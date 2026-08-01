//
//  repro-signingd.m
//  RePro 后台定时续签守护进程
//
//  由 launchd 在系统启动时拉起（RunAtLoad / KeepAlive），root 身份，
//  App jbroot namespace 外运行。唯一职责：NSTimer 定时检查是否需要续签，
//  通过 notify_post + 共享文件通知 App。
//
//  通知不由 daemon 直接发（iOS 没有 daemon 可用的通知 API），
//  而是由 App 在收到续签请求并执行完毕后自己发 UNUserNotificationCenter。
//  App 端在 didFinishLaunching 中一次性请求通知权限（系统去重，不会反复弹窗）。
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

static void SDFireResignRequest(void) {
    NSDictionary *cfg = SDLoadConfig();
    NSInteger threshold = [cfg[@"resignThreshold"] integerValue];
    if (threshold < 1) threshold = kDefaultThreshold;
    time_t now = time(NULL);

    SDEnsureIpcDir();

    // 写 request 时间戳 + 通知内容
    NSString *ts = [NSString stringWithFormat:@"%lld", (long long)now];
    [ts writeToFile:kRequestPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chown(kRequestPath.UTF8String, 501, 501);

    NSDictionary *noti = @{
        @"title": @"后台定时续签检查",
        @"body":  [NSString stringWithFormat:@"repro-signingd 已触发续签检查，下次打开 RePro 将自动续签", (long)threshold],
        @"timestamp": @(now),
    };
    [noti writeToFile:kNotificationPath atomically:YES];
    chown(kNotificationPath.UTF8String, 501, 501);

    // 通知 App
    notify_post("com.reprovision.schedule-resign");
    SDLog(@"已触发自动续签请求（阈值 %ld 天）", (long)threshold);
}

// App 续签完成后也会通过这个 notify 告诉 daemon 显示结果通知，
// 但因为 iOS 不支持 daemon 级的通知 API（CFUserNotification 是 macOS only），
// daemon 收到后把通知内容写共享路径，App 自己发 UNUserNotificationCenter。
static void SDHandleShowNotification(void) {
    // App 已经写好了通知内容 plist，daemon 的职责只是协调——
    // 通过 notify_post 回传给 App 让它发通知。
    // 这里直接转发：发一个 notify 让 App 的 dispatch source 触发。
    notify_post("com.reprovision.show-notification-done");
    SDLog(@"转发通知请求回 App");
}

// ─── NSTimer ────────────────────────────────────────────────────

static NSTimer *gSigningTimer;
static time_t   gLastFireTime;

static void SDScheduleTimer(NSTimeInterval interval) {
    [gSigningTimer invalidate];
    gSigningTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        NSDictionary *cfg = SDLoadConfig();
        if (![cfg[@"autoResign"] boolValue]) return;
        time_t now = time(NULL);
        if (now - gLastFireTime < 60) return;
        gLastFireTime = now;
        SDFireResignRequest();
    }];
}

// ─── main ───────────────────────────────────────────────────────

int main(void) {
    SDLog(@"启动，pid=%d", getpid());
    SDEnsureIpcDir();

    NSDictionary *cfg = SDLoadConfig();
    NSInteger intervalHours = [cfg[@"checkInterval"] integerValue];
    if (intervalHours < 1) intervalHours = kDefaultCheckInterval;
    NSTimeInterval interval = MAX((NSTimeInterval)intervalHours * 3600.0, kMinTimerInterval);

    BOOL autoResign = [cfg[@"autoResign"] boolValue];
    SDLog(@"自动续签: %@, 间隔: %.0f 分钟, 阈值: %@ 天",
          autoResign ? @"开启" : @"关闭", interval / 60.0,
          cfg[@"resignThreshold"] ?: @(kDefaultThreshold));

    SDScheduleTimer(interval);

    int configToken;
    notify_register_dispatch("com.reprovision.signingd-config-updated", &configToken,
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

    // 接收 App 的通知显示请求，转发回 App
    int notifyToken;
    notify_register_dispatch("com.reprovision.show-notification", &notifyToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDHandleShowNotification();
        });

    [[NSRunLoop mainRunLoop] run];
    return 0;
}
