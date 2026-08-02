//
//  repro-signingd.m — 后台静默重签守护进程（v1.1.59 增强）
//
//  核心能力：
//    1. 定时器自动续签（可配置间隔，默认 2 小时）
//    2. 屏幕解锁触发（锁屏期间到期 → 解锁时立即执行）
//    3. 屏幕亮起触发（即将到期 ≤5s → 立即执行）
//    4. 低电量模式跳过
//    5. nextFireDate 持久化（daemon 重启后不丢失调度状态）
//    6. --resign-now 手动触发
//    7. ★ 主动唤醒 App 到后台执行静默续签（不再依赖用户手动打开 App）
//
//  日志: fopen/fprintf 同步写入 <jbroot>/var/log/reprorefresh_at.log
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <dlfcn.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath  = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kTriggerPath = @"/var/mobile/Library/RePro/auto-resign-trigger";
static NSString *const kStatePath   = @"/var/mobile/Library/RePro/signingd-state.plist";
static NSString *const kAppBundleID = @"jp.soh.reprovision";

static const NSInteger  kFallbackMinutes = 120;   // 默认 2 小时
static const NSInteger  kFallbackDays    = 2;

static FILE     *gLogFile   = NULL;
static NSTimer  *gTimer     = nil;
static time_t    gLastFire  = 0;
static BOOL      gUpdateQueuedForUnlock = NO;
static int gLockStateToken = 0;
static int gBacklightToken = 0;

// ─── 日志 ────────────────────────────────────────────────────────

static void s_log(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    char ts[64]; strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
    if (gLogFile) { fprintf(gLogFile, "[%s] %s\n", ts, s.UTF8String); fflush(gLogFile); }
    NSLog(@"[repro-signingd] %@", s);
}

static void s_open_log(void) {
    NSString *dir = nil, *jb = nil;
    NSString *a0 = [[[NSProcessInfo processInfo] arguments] firstObject];
    if (a0) {
        NSRange r = [a0 rangeOfString:@"/usr/libexec/" options:NSBackwardsSearch];
        if (r.location != NSNotFound) jb = [a0 substringToIndex:r.location];
    }
    if (!jb) jb = @"/var/jb";
    dir = [jb stringByAppendingPathComponent:@"var/log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    NSString *p = [dir stringByAppendingPathComponent:@"reprorefresh_at.log"];
    gLogFile = fopen(p.UTF8String, "a");
    if (gLogFile) chmod(p.UTF8String, 0666);
    if (!gLogFile) NSLog(@"[repro-signingd] 无法打开 %@", p);
}

// ─── 配置 ────────────────────────────────────────────────────────

typedef struct { BOOL enabled; NSInteger minutes; NSInteger days; } sd_config;

static sd_config s_cfg(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (!d) {
        s_log(@"配置文件不存在 (%@)，使用默认值: 间隔=%ld分 阈值=%ld天 启用=YES",
              kConfigPath, (long)kFallbackMinutes, (long)kFallbackDays);
        return (sd_config){YES, kFallbackMinutes, kFallbackDays};
    }
    // 打印原始值便于排查同步问题
    id rawMin = d[@"checkIntervalMin"];
    id rawEn  = d[@"autoResign"];
    id rawDy  = d[@"resignThreshold"];

    NSInteger m = [rawMin integerValue]; if (m < 1) m = kFallbackMinutes;
    NSInteger dy = [rawDy integerValue]; if (dy < 1) dy = kFallbackDays;
    BOOL en = rawEn ? [rawEn boolValue] : YES;

    s_log(@"读取配置: autoResign=%@(%@) checkIntervalMin=%@(%ld) resignThreshold=%@(%ld)",
          rawEn, en ? @"YES" : @"NO", rawMin, (long)m, rawDy, (long)dy);
    return (sd_config){en, m, dy};
}

// ─── 状态持久化（nextFireDate） ──────────────────────────────────
// 与 test2 一致：将下次触发时间写入 plist，daemon 重启后恢复调度。

static NSDate *s_getNextFireDate(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if (!state) return nil;
    return state[@"nextFireDate"];
}

static void s_setNextFireDate(NSDate *date) {
    if (!date) return;
    [@{@"nextFireDate": date} writeToFile:kStatePath atomically:YES];
    // 保持 mobile 可读
    chown(kStatePath.UTF8String, 501, 501);
}

static void s_clearNextFireDate(void) {
    [[NSFileManager defaultManager] removeItemAtPath:kStatePath error:nil];
}

// 前向声明：s_start_timer 在 s_initiateAndReschedule 之后定义，
// 但 s_initiateAndReschedule 需要调用它。
static void s_start_timer(NSTimeInterval sec);

// ─── 唤醒 App 到后台执行静默续签 ─────────────────────────────
// 通过 dlopen+dlsym 动态调用 SBSLaunchApplicationWithIdentifierAndLaunchOptions（SpringBoardServices 私有 API）。
// 不需要在编译时链接私有框架。失败时降级为纯 notify_post（App 下次激活时检查）。

static BOOL s_launchAppInBackground(void) {
    // dlopen SpringBoardServices
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (!handle) {
        s_log(@"无法加载 SpringBoardServices: %s", dlerror());
        return NO;
    }

    // dlsym 获取 SBSLaunchApplicationWithIdentifierAndLaunchOptions
    typedef void (*SBSLaunchFn)(CFStringRef identifier, CFDictionaryRef options, void **error);
    SBSLaunchFn fn = (SBSLaunchFn)dlsym(handle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
    if (!fn) {
        s_log(@"无法找到 SBSLaunchApplicationWithIdentifierAndLaunchOptions: %s", dlerror());
        dlclose(handle);
        return NO;
    }

    // 构造 launch options：后台启动、不显示 UI、不添加到切换器
    NSDictionary *options = @{
        @(kSBSLaunchOptionBackgroundOnlyKey): @YES,          // 后台启动
        @(kSBSLaunchOptionUnlockDeviceKey): @NO,             // 不解锁设备
    };

    // 调用
    fn((__bridge CFStringRef)kAppBundleID, (__bridge CFDictionaryRef)options, NULL);
    dlclose(handle);

    s_log(@"已发送后台启动请求给 %@", kAppBundleID);
    return YES;
}

// ─── 触发 ────────────────────────────────────────────────────────

static void s_fire(void) {
    sd_config c = s_cfg();
    if (!c.enabled) { s_log(@"自动续签已关闭，跳过"); return; }

    // 低电量模式检查（与 test2 一致）
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        s_log(@"低电量模式，跳过续签");
        // 不更新 nextFireDate，下次检查再试
        return;
    }

    time_t now = time(NULL);
    [@{
        @"timestamp": @(now),
        @"threshold": @(c.days),
        @"triggeredBy": @"daemon-timer",
    } writeToFile:kTriggerPath atomically:YES];
    chown(kTriggerPath.UTF8String, 501, 501);

    // ★ 主动唤醒 App 到后台执行静默续签
    // App 被 launchd 拉起后，didFinishLaunchingWithOptions 检测到 trigger 文件新鲜（10秒内）
    // → 走 silentResignAndExit() 路径 → 完成后续签后 exit(0)
    if (s_launchAppInBackground()) {
        s_log(@"触发续签 — 阈值 %ld 天（已唤醒 App 后台执行）", (long)c.days);
    } else {
        // 降级：仅发 notify_post，等用户下次打开 App 时触发
        notify_post("com.reprovision.schedule-resign");
        s_log(@"触发续签 — 阈值 %ld 天（唤醒失败，降级为 notify_post）", (long)c.days);
    }
}

/// 执行一次完整的重签周期，然后重新设定时器。
/// 对应 test2 的 _initiateNewSigningRoutine + _restartSigningTimerWithInterval。
static void s_initiateAndReschedule(void) {
    s_fire();

    sd_config c = s_cfg();
    NSTimeInterval interval = (NSTimeInterval)c.minutes * 60.0;

    // 持久化下次触发时间
    NSDate *nextFire = [[NSDate date] dateByAddingTimeInterval:interval];
    s_setNextFireDate(nextFire);

    s_start_timer(interval);
    s_log(@"已重新调度 — 下次触发 %.0f 分钟后 (%@)",
          interval / 60.0, nextFire);
}

// ─── 定时器管理 ─────────────────────────────────────────────────

static void s_start_timer(NSTimeInterval sec) {
    [gTimer invalidate];
    gTimer = [NSTimer scheduledTimerWithTimeInterval:sec repeats:NO block:^(NSTimer *t) {
        time_t n = time(NULL); if (n - gLastFire < 30) return; gLastFire = n;
        s_initiateAndReschedule();
    }];
    s_log(@"定时器已设定 — %.0f 秒后触发", sec);
}

/// 启动或恢复定时器（考虑持久化的 nextFireDate）。
/// 对应 test2 的 _startSigningTimer。
static void s_startSigningTimer(void) {
    NSDate *savedNextFire = s_getNextFireDate();
    NSTimeInterval defaultInterval = (NSTimeInterval)s_cfg().minutes * 60.0;
    NSTimeInterval interval = defaultInterval;

    if (savedNextFire) {
        interval = [savedNextFire timeIntervalSinceNow];
        if (interval < 0) {
            // 已过期 → 5 秒后立即触发（与 test2 一致）
            s_log(@"保存的触发时间已过期，5 秒后立即执行");
            interval = 5;
        } else {
            s_log(@"从持久化恢复 — %.0f 秒后触发", interval);
        }
    }

    s_start_timer(interval);
}

// ─── 屏幕解锁 / 亮屏检测（移植自 test2 RPVDaemonListener） ────────

/// 设备解锁回调。
/// 如果锁屏期间有到期任务，立即执行。同时检查凭证是否需要刷新。
static void sb_didUIUnlockNotification(void) {
    s_log(@"设备解锁");

    if (gUpdateQueuedForUnlock) {
        gUpdateQueuedForUnlock = NO;
        s_log(@"锁屏期间有到期任务 → 立即执行续签");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            s_initiateAndReschedule();
        });
    }
}

/// 背光变化回调。
/// 屏幕亮起时：如果即将到期（≤5 秒），立即触发；否则重置剩余时间。
/// 屏幕熄灭时：停止当前定时器以省电（下次解锁/亮屏时恢复）。
static void bb_backlightChanged(int state) {
    if (state > 0) {
        // 屏幕亮起
        s_log(@"屏幕亮起");

        NSDate *nextFire = s_getNextFireDate();
        if (nextFire) {
            NSTimeInterval remaining = [nextFire timeIntervalSinceNow];
            if (remaining <= 5) {
                // 即将到期 → 立即触发（与 test2 一致）
                s_log(@"即将到期 (%.0fs remaining) → 立即触发", remaining);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    s_initiateAndReschedule();
                });
                return;
            }
            // 未到期 → 用剩余时间重设定时器
            s_log(@"未到期 — 重设剩余 %.0f 秒", remaining);
            s_start_timer(remaining);
        } else {
            // 无保存的触发时间 → 用默认间隔
            s_start_timer((NSTimeInterval)s_cfg().minutes * 60.0);
        }
    } else {
        // 屏幕熄灭 → 停止定时器省电（与 test2 一致）
        s_log(@"屏幕熄灭 → 停止定时器省电");
        [gTimer invalidate];
        gTimer = nil;
    }
}

/// 注册 Darwin Notify 监听（屏幕锁定、背光变化）。
/// 对应 test2 的 setupNotifyPosts。
static void s_setupNotifyPosts(void) {
    // 设备锁定状态变化
    notify_register_dispatch("com.apple.springboard.lockstate", &gLockStateToken,
        dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        if (state == 0) { // 0 = 解锁状态
            sb_didUIUnlockNotification();
        }
    });

    // 背光状态变化
    notify_register_dispatch("com.apple.backboardd.backlight.changed", &gBacklightToken,
        dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        bb_backlightChanged((int)state);
    });

    s_log(@"已注册屏幕解锁/背光监听");
}

// ─── main ────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    s_open_log();

    // --resign-now: 终端手动触发（保留原有功能）
    if (argc >= 2 && strcmp(argv[1], "--resign-now") == 0) {
        s_log(@"收到 --resign-now");
        s_fire();
        s_log(@"触发完成 — 打开 App 时自动续签");
        return 0;
    }

    // 正常守护模式
    s_log(@"=== 启动 pid=%d uid=%d ===", getpid(), getuid());
    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    chown(kIpcDir.UTF8String, 501, 501);

    sd_config c = s_cfg();
    s_log(@"配置: 自动=%@ 间隔=%ld分 阈值=%ld天",
          c.enabled ? @"是" : @"否", (long)c.minutes, (long)c.days);
    s_log(@"BundleID: %@ | 触发路径: %@", kAppBundleID, kTriggerPath);

    // 注册系统通知监听（解锁/背光）
    s_setupNotifyPosts();

    // 启动定时器（优先从持久化的 nextFireDate 恢复）
    s_startSigningTimer();

    // 首次启动 5 秒后执行一次（确保安装后不久就能续签）
    if (c.enabled) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ s_fire(); });
    }

    // 配置变更通知 → 重读配置 + 重设定时器
    int t; notify_register_dispatch("com.reprovision.signingd-config-updated", &t,
        dispatch_get_main_queue(), ^(int _){
        s_log(@"配置变更 → 重读并重设定时器");
        sd_config nc = s_cfg();
        s_startSigningTimer();
    });

    // 续签完成通知
    int t2; notify_register_dispatch("com.reprovision.signing-complete", &t2,
        dispatch_get_main_queue(), ^(int _){ s_log(@"续签完成"); });

    s_log(@"进入主循环");
    [[NSRunLoop mainRunLoop] run];
    return 0;
}
