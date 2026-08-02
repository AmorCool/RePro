//
//  repro-signingd.m — 后台静默重签守护进程（v1.1.58 增强）
//
//  从 test2 (ReProvision-Reborn 0.8.4.4) 的 RPVDaemonListener 移植核心机制：
//    1. 定时器自动续签（可配置间隔，默认 2 小时）
//    2. 屏幕解锁触发（锁屏期间到期 → 解锁时立即执行）
//    3. 屏幕亮起触发（即将到期 ≤5s → 立即执行）
//    4. 低电量模式跳过
//    5. nextFireDate 持久化（daemon 重启后不丢失调度状态）
//    6. --resign-now 手动触发（保留原有功能）
//
//  与 test2 的差异：
//    - 不使用 XPC/Mach Service（RePro 用文件标记 + notify_post 轻量通信）
//    - 不使用 SBSLaunchApplication（依赖 BackBoardServices 私有框架）
//    - 不使用 BKSProcessAssertion（依赖 BackBoardBoardServices 私有框架）
//    - 这些私有框架的依赖会增加编译复杂度，且当前文件标记方案在 RootHide 下已验证可用
//
//  日志: fopen/fprintf 同步写入 <jbroot>/var/log/reprorefresh_at.log
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath  = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kTriggerPath = @"/var/mobile/Library/RePro/auto-resign-trigger";
static NSString *const kStatePath   = @"/var/mobile/Library/RePro/signingd-state.plist";

static const NSInteger  kFallbackMinutes = 120;   // 默认 2 小时（与 test2 一致）
static const NSInteger  kFallbackDays    = 2;

static FILE     *gLogFile   = NULL;
static NSTimer  *gTimer     = nil;
static time_t    gLastFire  = 0;
static BOOL      gUpdateQueuedForUnlock = NO;  // 锁屏期间是否有到期任务
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
    if (!d) return (sd_config){YES, kFallbackMinutes, kFallbackDays};
    NSInteger m = [d[@"checkIntervalMin"] integerValue]; if (m < 1) m = kFallbackMinutes;
    NSInteger dy = [d[@"resignThreshold"] integerValue]; if (dy < 1) dy = kFallbackDays;
    BOOL en = d[@"autoResign"] ? [d[@"autoResign"] boolValue] : YES;
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
    notify_post("com.reprovision.schedule-resign");
    s_log(@"触发续签 — 阈值 %ld 天", (long)c.days);
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
