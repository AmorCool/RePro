//
//  repro-signingd.m
//  RePro 后台定时续签守护进程
//
//  由 launchd 在系统启动时拉起（RunAtLoad / KeepAlive），完全在 App jbroot
//  namespace 外运行。用一个 NSTimer 定时触发续签检查，通过
//  /var/mobile/Library/RePro/ 共享路径与 App 通信。
//
//  设计（与 repro-profiledaemon 保持一致的 IPC 模式）：
//    - App 每次保存设置时把 autoResign / checkInterval 写进共享 plist
//    - Daemon 的 NSTimer 每小时 fire 一次，读共享 plist 判断是否需要签名
//    - 如果需要签名 → notify_post("com.reprovision.schedule-resign")
//      并写 /var/mobile/Library/RePro/auto-resign-request
//    - App 前台时通过 notify_register_dispatch 收到通知直接跑自动续签；
//      不在前台时，下次 didBecomeActive 检查 auto-resign-request
//      的 mtime 是否新于上次执行时间。
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir          = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath      = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kRequestPath     = @"/var/mobile/Library/RePro/auto-resign-request";
static NSString *const kNotifyName      = @"com.reprovision.schedule-resign";

// 默认值（与 App 内 UserDefaults 一致）
static const BOOL    kDefaultAutoResign     = YES;
static const NSInteger kDefaultCheckInterval = 6;   // 小时
static const NSInteger kDefaultThreshold     = 2;   // 天

// 计时器最短间隔：防止配置出错导致高频唤醒
static const NSTimeInterval kMinTimerInterval = 3600.0;  // 1 小时

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
    if (![fm createDirectoryAtPath:kIpcDir
       withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0755}
                             error:&err]) {
        SDLog(@"创建 IPC 目录失败: %@", err);
        return NO;
    }
    chown(kIpcDir.UTF8String, 501, 501);               // mobile:mobile
    return YES;
}

// ─── 读配置 ─────────────────────────────────────────────────────
// App 把 autoResign / checkInterval / resignThreshold 写到
// /var/mobile/Library/RePro/signingd-config.plist；
// 如果文件不存在则用默认值。

static NSDictionary *SDLoadConfig(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (!cfg) {
        // 还没有写入过，用默认值
        return @{
            @"autoResign":     @(kDefaultAutoResign),
            @"checkInterval":  @(kDefaultCheckInterval),
            @"resignThreshold":@(kDefaultThreshold),
        };
    }
    return cfg;
}

// ─── 触发续签 ──────────────────────────────────────────────────

static void SDFireResignRequest(void) {
    // 1. 写时间戳文件（App 在 didBecomeActive 检查这个）
    NSString *ts = [NSString stringWithFormat:@"%lld", (long long)time(NULL)];
    SDEnsureIpcDir();
    NSError *err;
    if (![ts writeToFile:kRequestPath atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        SDLog(@"写请求时间戳失败: %@", err);
        return;
    }
    chown(kRequestPath.UTF8String, 501, 501);

    // 2. 发 notify（如果 App 正在运行，会通过 dispatch source 收到）
    notify_post(kNotifyName.UTF8String);
    SDLog(@"已触发自动续签请求 (%@)", ts);
}

// ─── 主逻辑：NSTimer 驱动 ──────────────────────────────────────

static NSTimer *gSigningTimer;
static time_t   gLastFireTime;

static void SDScheduleTimer(NSTimeInterval interval) {
    [gSigningTimer invalidate];
    gSigningTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        NSDictionary *cfg = SDLoadConfig();
        BOOL autoResign = [cfg[@"autoResign"] boolValue];
        if (!autoResign) {
            SDLog(@"自动续签已关闭，跳过本次检查");
            return;
        }

        time_t now = time(NULL);
        // 防止同一次 fire 重复触发（NSTimer repeats 可能因为系统唤醒连发）
        if (now - gLastFireTime < 60) return;
        gLastFireTime = now;

        SDFireResignRequest();
    }];
}

int main(void) {
    SDLog(@"启动，pid=%d", getpid());
    SDEnsureIpcDir();

    // 初始配置
    NSDictionary *cfg = SDLoadConfig();
    NSInteger intervalHours = [cfg[@"checkInterval"] integerValue];
    if (intervalHours < 1) intervalHours = kDefaultCheckInterval;
    NSTimeInterval interval = MAX((NSTimeInterval)intervalHours * 3600.0, kMinTimerInterval);

    BOOL autoResign = [cfg[@"autoResign"] boolValue];
    SDLog(@"自动续签: %@, 检查间隔: %.0f 分钟, 阈值: %@ 天",
          autoResign ? @"开启" : @"关闭",
          interval / 60.0,
          cfg[@"resignThreshold"] ?: @(kDefaultThreshold));

    SDScheduleTimer(interval);

    // 同时监听 notify 以便 App 通知 daemon 配置已更新
    int token;
    notify_register_dispatch("com.reprovision.signingd-config-updated", &token,
        dispatch_get_main_queue(), ^(int unused) {
            SDLog(@"收到配置更新通知，重新加载");
            NSDictionary *c = SDLoadConfig();
            BOOL ar = [c[@"autoResign"] boolValue];
            NSInteger ih = [c[@"checkInterval"] integerValue];
            if (ih < 1) ih = kDefaultCheckInterval;
            NSTimeInterval inv = MAX((NSTimeInterval)ih * 3600.0, kMinTimerInterval);
            SDLog(@"自动续签: %@, 检查间隔: %.0f 分钟",
                  ar ? @"开启" : @"关闭", inv / 60.0);
            SDScheduleTimer(inv);
        });

    // 保持 runloop 不退出
    [[NSRunLoop mainRunLoop] run];
    return 0;
}
