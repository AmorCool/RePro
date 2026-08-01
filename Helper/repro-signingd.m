//
//  repro-signingd.m
//  RePro 后台定时续签守护进程 + 系统通知
//
//  由 launchd 在系统启动时拉起（RunAtLoad / KeepAlive），完全在 App jbroot
//  namespace 外运行，以 root 身份工作。两件事：
//
//  1. 定时续签检查：NSTimer 每 N 小时 fire → 写入 request 时间戳
//     → notify_post("com.reprovision.schedule-resign") → App 收到后执行续签
//
//  2. 系统通知：监听 notify_post("com.reprovision.show-notification")，
//     读 /var/mobile/Library/RePro/auto-resign-notification.plist，
//     用 CFUserNotification 显示系统横幅通知。
//     这是通知的唯一出口——App 不直接调 UNUserNotificationCenter
//     （RootHide namespace 内 XPC 可能落 overlay 假成功），
//     全部改由本 daemon 在 namespace 外以 root 身份发出。
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir              = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath          = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kRequestPath         = @"/var/mobile/Library/RePro/auto-resign-request";
static NSString *const kNotificationPath    = @"/var/mobile/Library/RePro/auto-resign-notification.plist";

static const BOOL       kDefaultAutoResign    = YES;
static const NSInteger  kDefaultCheckInterval = 6;
static const NSInteger  kDefaultThreshold     = 2;
static const NSTimeInterval kMinTimerInterval = 3600.0;

// ─── 日志 ───────────────────────────────────────────────────────

static void SDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-signingd] %@", msg);
}

// ─── 共享目录 ───────────────────────────────────────────────────

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

// ─── 读配置 ─────────────────────────────────────────────────────

static NSDictionary *SDLoadConfig(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    return cfg ?: @{
        @"autoResign":     @(kDefaultAutoResign),
        @"checkInterval":  @(kDefaultCheckInterval),
        @"resignThreshold":@(kDefaultThreshold),
    };
}

// ─── 定时续签触发 ───────────────────────────────────────────────

static void SDFireResignRequest(void) {
    NSDictionary *cfg = SDLoadConfig();
    NSInteger threshold = [cfg[@"resignThreshold"] integerValue];
    if (threshold < 1) threshold = kDefaultThreshold;
    time_t now = time(NULL);

    SDEnsureIpcDir();

    NSString *ts = [NSString stringWithFormat:@"%lld", (long long)now];
    [ts writeToFile:kRequestPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chown(kRequestPath.UTF8String, 501, 501);

    notify_post("com.reprovision.schedule-resign");
    SDLog(@"已触发自动续签请求（阈值 %ld 天）", (long)threshold);
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

// ─── 系统通知（CFUserNotification banner） ──────────────────────

/// 用 CFUserNotification 显示非阻塞横幅通知。
/// CFUserNotification 是 CoreFoundation 的 C API，任何 root 进程都可以调用，
/// 不受 App namespace 影响——这正是我们让 daemon 发通知的原因。
static void SDShowNotificationBanner(NSString *title, NSString *body) {
    if (!title.length && !body.length) return;

    // CFUserNotificationDisplayNotice: 非阻塞，显示横幅后立即返回
    // kCFUserNotificationNoteAlertLevel: 系统通知级别（带声音）
    CFOptionFlags flags = 0;
    CFUserNotificationDisplayNotice(
        0,                                  // timeout: 0 = system default
        kCFUserNotificationNoteAlertLevel,   // alert level
        NULL,                                // icon URL
        NULL,                                // sound URL
        NULL,                                // localization URL
        (__bridge CFStringRef)(title ?: @""),
        (__bridge CFStringRef)(body ?: @""),
        NULL                                 // default button
    );

    SDLog(@"已显示系统通知: %@ — %@", title, body);
}

/// 从共享 plist 读取通知内容并显示。
static void SDHandleShowNotification(void) {
    NSDictionary *noti = [NSDictionary dictionaryWithContentsOfFile:kNotificationPath];
    if (!noti) {
        SDLog(@"收到显示通知请求但没有内容文件");
        return;
    }

    NSString *title = [noti[@"title"] description] ?: @"";
    NSString *body  = [noti[@"body"] description] ?: @"";

    // 去重：同一个时间戳的通知只显示一次
    NSInteger ts = [noti[@"timestamp"] integerValue];
    static NSInteger gLastNotiTimestamp = 0;
    if (ts && ts == gLastNotiTimestamp) return;
    gLastNotiTimestamp = ts;

    SDShowNotificationBanner(title, body);
}

// ─── main ────────────────────────────────────────────────��──────

int main(void) {
    SDLog(@"启动，pid=%d", getpid());
    SDEnsureIpcDir();

    // 1. 加载配置，启动定时续签检查
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

    // 2. 监听 App 配置更新
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

    // 3. 监听 App 的通知请求（续签完成后 App 写共享 plist 然后 notify_post）
    int notifyToken;
    notify_register_dispatch("com.reprovision.show-notification", &notifyToken,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"收到显示通知请求");
            SDHandleShowNotification();
        });

    [[NSRunLoop mainRunLoop] run];
    return 0;
}
