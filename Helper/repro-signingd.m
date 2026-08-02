//
//  repro-signingd.m — 后台静默重签守护进程（v1.1.60 增强）
//
//  核心能力：
//    1. 定时器自动续签（可配置间隔，默认 2 小时）
//    2. 屏幕解锁触发（锁屏期间到期 → 解锁时立即执行）
//    3. 屏幕亮起触发（即将到期 ≤5s → 立即执行）
//    4. 低电量模式跳过
//    5. nextFireDate 持久化（daemon 重启后不丢失调度状态）
//    6. --resign-now 手动触发
//    7. 主动唤醒 App 到后台执行静默续签
//    8. ★ BKSProcessAssertion 保活（防止 App 被系统挂起）
//    9. ★ IOPMSchedulePowerEvent 系统级唤醒（锁屏时也能准时触发）
//
//  架构说明（与 test2 reprovisiond 一致）：
//    Daemon 本身不执行签名操作（签名需要 zsign + 凭证访问 + 网络请求）。
//    Daemon 的角色是「调度器 + 唤醒器 + 保活管理者」：
//      定时器/解锁/亮屏 → 写 trigger 标记 → SBSLaunchApplication 唤醒 App 到后台
//      → BKSProcessAssertion 防止 App 被挂起 → App 执行 silentResignAndExit → exit(0)
//    用户全程无需手动打开 App。
//
//  日志: fopen/fprintf 同步写入 <jbroot>/var/log/reprorefresh_at.log
//  日志文件被删除后会自动检测并重新创建（fstat nlink 检查）
//

#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
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

// ─── 日志（带文件删除自愈） ───────────────────────────────────
// 修复：日志文件被外部删除后，通过 fstat(st_nlink == 0) 检测，
//       自动 fclose + 重新 fopen，避免 fd 泄漏和静默丢日志。

// 前向声明（s_ensure_log_valid 在 s_log 之前使用它们）
static void s_open_log(void);
static void s_log(NSString *fmt, ...);

static void s_ensure_log_valid(void) {
    if (!gLogFile) { s_open_log(); return; }
    struct stat st;
    if (fstat(fileno(gLogFile), &st) != 0 || st.st_nlink == 0) {
        s_log(@"检测到日志文件失效（nlink=0 或 fstat 错误），重新打开");
        fclose(gLogFile);
        gLogFile = NULL;
        s_open_log();
    }
}

static void s_log(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    char ts[64]; strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
    // 每次写入前检查文件是否仍然有效
    s_ensure_log_valid();
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

// ─── 唤醒 App 到后台执行静默续签（含保活 + 系统唤醒） ────────
// 与 test2 RPVDaemonListener._launchApplicationBackgroundedWithNotification 一致：
//   1. SBSLaunchApplicationWithIdentifierAndLaunchOptions 唤醒 App 到后台
//   2. BKSProcessAssertion 防止 App 被系统挂起/杀死
//   3. IOPMSchedulePowerEvent 确保锁屏时设备也能准时醒来
//
// 所有私有 API 通过 dlopen+dlsym 运行时动态加载，无需编译时链接。

static int32_t gAppPID = 0;            // 被唤醒 App 的 PID（用于 BKS）
static void    *gBKSAssertion = NULL;  // BKSProcessAssertion 对象

/// 获取 App 的 PID（通过 SBSProcessIDForDisplayIdentifier）
/// 带重试机制：RootHide 下 App 启动较慢，2秒可能不够
static pid_t s_getAppPIDWithRetry(NSString *bundleID, int maxRetries) {
    const int delays[] = {2, 5, 10};  // 重试延迟（秒）
    const int retryCount = maxRetries < 3 ? maxRetries : 3;

    for (int i = 0; i < retryCount; i++) {
        if (i > 0) {
            s_log(@"获取 PID 第 %d/%d 次重试（等待 %ds）...", i + 1, retryCount, delays[i]);
            sleep(delays[i]);
        }
        pid_t pid = s_getAppPID(bundleID);
        if (pid > 0) return pid;
    }
    return 0;
}

/// 获取 App 的 PID（单次查询）
static pid_t s_getAppPID(NSString *bundleID) {
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (!sbs) return 0;
    typedef pid_t (*Fn)(CFStringRef);
    Fn fn = (Fn)dlsym(sbs, "SBSProcessIDForDisplayIdentifier");
    if (!fn) { dlclose(sbs); return 0; }
    pid_t pid = fn((__bridge CFStringRef)bundleID);
    dlclose(sbs);
    return pid;
}

/// 获取 BKSProcessAssertion 防止 App 被挂起（与 test2 一致）
static void *s_acquireBKSAssertion(pid_t targetPid) {
    // dlopen BackBoardServices（iOS 16+）或 BoardServices（iOS 15）
    static const char *frameworkPaths[] = {
        "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
        NULL
    };

    void *bksHandle = NULL;
    for (int i = 0; frameworkPaths[i]; i++) {
        bksHandle = dlopen(frameworkPaths[i], RTLD_NOW);
        if (bksHandle) break;
    }
    if (!bksHandle) {
        s_log(@"无法加载 BackBoardServices/BoardServices: %s", dlerror());
        return NULL;
    }

    // 获取 BKSProcessAssertion 类
    Class bksClass = NSClassFromString(@"BKSProcessAssertion");
    if (!bksClass) {
        s_log(@"无法获取 BKSProcessAssertion 类");
        dlclose(bksHandle);
        return NULL;
    }

    // flags: PreventSuspend | AllowIdleSleep (与 test2 一致)
    uint32_t flags = 0x3;  // PreventSuspend=0x1 | AllowIdleSleep=0x2

    id assertion = [[bksClass alloc] init];
    SEL sel = NSSelectorFromString(@"_initWithPID:flags:reason:name:withHandler:");

    // 用 NSInvocation 调用 5 参数方法（ARC 不允许 performSelector 带 >2 个参数）
    NSMethodSignature *sig = [assertion methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:assertion];

    // 参数索引：0=target, 1=selector, 2=第一个参数...
    pid_t pidVal = targetPid;
    uint32_t flagsVal = flags;
    NSString *reasonStr = @"jp.soh.reprovision background signing";
    NSString *nameStr = @"ReProvision";

    // 使用 __unsafe_unretained 避免 ARC 对 block 参数的强引用问题
    typedef void (^BKSHandler)(BOOL);
    __unsafe_unretained BKSHandler handler = ^(BOOL success) {
        s_log(@"BKSProcessAssertion %@ (pid=%d)", success ? @"生效" : @"失败", targetPid);
    };

    [inv setArgument:&pidVal atIndex:2];
    [inv setArgument:&flagsVal atIndex:3];
    [inv setArgument:&reasonStr atIndex:4];
    [inv setArgument:&nameStr atIndex:5];
    [inv setArgument:&handler atIndex:6];
    [inv invoke];

    id result = nil;
    [inv getReturnValue:&result];

    // 不 dlclose——BKS 对象运行时可能还需要该框架
    s_log(@"已获取 BKSProcessAssertion (pid=%d)", targetPid);
    // 如果返回值非空使用它，否则使用初始化的 assertion 对象
    id finalResult = result ?: assertion;
    return (__bridge_retained void *)finalResult;
}

/// 设置系统级电源唤醒（与 test2 IOPMSchedulePowerEvent 一致）
/// 确保锁屏状态下设备也能在指定时间醒来执行续签。
///
/// ⚠️ RootHide 限制：IOPMSchedulePowerEvent 需要 IOKit 特权，
///    在 namespace 隔离环境下可能返回 kIOReturnNotPrivileged (0xE00002C6)。
///    此功能是「增强体验」非「核心链路」，失败时不阻塞续签。
///    屏幕解锁/背光监听仍能覆盖大部分场景。
static BOOL s_scheduleSystemWake(NSTimeInterval secondsFromNow) {
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKit) { s_log(@"无法加载 IOKit — 系统级唤醒不可用（非致命）"); return NO; }

    // IOReturn 本质是 int32_t，不链接 IOKit 框架时需手动声明
    typedef int (*IOPMSchedFn)(CFDateRef, CFStringRef, CFStringRef);
    IOPMSchedFn schedFn = (IOPMSchedFn)dlsym(ioKit, "IOPMSchedulePowerEvent");
    if (!schedFn) {
        s_log(@"无法找到 IOPMSchedulePowerEvent — 系统级唤醒不可用（非致命）");
        dlclose(ioKit);
        return NO;
    }

    NSDate *wakeDate = [NSDate dateWithTimeIntervalSinceNow:secondsFromNow];
    int ret = schedFn((__bridge CFDateRef)wakeDate,
                       CFSTR("jp.soh.reprovision.signingd"),
                       CFSTR("AutoWakeOrPowerOn"));
    dlclose(ioKit);

    if (ret == 0) {
        s_log(@"[Step 3/3] 已设置系统级唤醒 — %.0f 秒后 (%@)", secondsFromNow, wakeDate);
        return YES;
    } else {
        // 常见错误码说明
        const char *reason = "未知";
        if (ret == -536870206) reason = "kIOReturnNotPrivileged (RootHide namespace 限制)";
        else if (ret == -536870211) reason = "kIOReturnNotPermitted (权限不足)";
        else if (ret == -4294957038) reason = "kIOReturnBadArgument (参数错误)";
        s_log(@"[Step 3/3] 系统级唤醒设置失败 (ret=0x%08X: %s) — 非致命，屏幕解锁触发仍可用",
              (unsigned int)ret, reason);
        return NO;
    }
}

/// 释放 BKSProcessAssertion（续签完成后调用）
static void s_releaseBKSAssertion(void) {
    if (gBKSAssertion) {
        SEL relSel = NSSelectorFromString(@"release");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [(__bridge id)gBKSAssertion performSelector:relSel];
#pragma clang diagnostic pop
        gBKSAssertion = NULL;
        s_log(@"已释放 BKSProcessAssertion");
    }
}

static BOOL s_launchAppInBackground(void) {
    // ── Step 1: SBSLaunchApplication 唤醒 App 到后台 ──
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (!handle) {
        s_log(@"无法加载 SpringBoardServices: %s", dlerror());
        return NO;
    }

    typedef void (*SBSLaunchFn)(CFStringRef, CFDictionaryRef, void **);
    SBSLaunchFn fn = (SBSLaunchFn)dlsym(handle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
    if (!fn) {
        s_log(@"无法找到 SBSLaunchApplicationWithIdentifierAndLaunchOptions: %s", dlerror());
        dlclose(handle);
        return NO;
    }

    NSDictionary *options = @{
        @"SBSBackgroundOnly": @YES,
        @"SBSUnlockDevice": @NO,
    };

    fn((__bridge CFStringRef)kAppBundleID, (__bridge CFDictionaryRef)options, NULL);
    dlclose(handle);
    s_log(@"[Step 1/3] 已发送后台启动请求给 %@", kAppBundleID);

    // ── Step 2: 获取 App PID 并创建 BKSProcessAssertion 保活 ──
    // RootHide 下 App 启动较慢，使用重试机制（2s → 5s → 10s）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        pid_t appPID = s_getAppPIDWithRetry(kAppBundleID, 3);
        if (appPID > 0) {
            gAppPID = appPID;
            gBKSAssertion = s_acquireBKSAssertion(appPID);
            if (gBKSAssertion) {
                s_log(@"[Step 2/3] BKSProcessAssertion 已生效 (pid=%d)", appPID);
            } else {
                s_log(@"[Step 2/3] BKSProcessAssertion 获取失败 — App 可能被系统挂起");
            }
        } else {
            s_log(@"[Step 2/3] 重试3次仍无法获取 App PID — BKS 保活跳过（RootHide SBS 隔离？）");
        }
    });

    // ── Step 3: 设置系统级电源唤醒（确保锁屏时也能触发）──
    sd_config c = s_cfg();
    // 在下次触发前 30 秒唤醒设备（给 App 足够的启动+签名时间）
    NSTimeInterval wakeInterval = ((NSTimeInterval)c.minutes * 60.0) - 30;
    if (wakeInterval > 10) {
        s_scheduleSystemWake(wakeInterval);
    }

    return YES;
}

// ─── 触发 ────────────────────────────────────────────────────────

static void s_fire(void) {
    sd_config c = s_cfg();
    if (!c.enabled) { s_log(@"自动续签已关闭，跳过"); return; }

    // 低电量模式检查（与 test2 一致）
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        s_log(@"低电量模式，跳过续签");
        return;
    }

    time_t now = time(NULL);
    [@{
        @"timestamp": @(now),
        @"threshold": @(c.days),
        @"triggeredBy": @"daemon-timer",
    } writeToFile:kTriggerPath atomically:YES];
    chown(kTriggerPath.UTF8String, 501, 501);

    // 主动唤醒 App 到后台执行静默续签（含保活 + 系统唤醒）
    if (s_launchAppInBackground()) {
        s_log(@"触发续签 — 阈值 %ld 天（已唤醒 App + BKS 保活 + 系统唤醒）", (long)c.days);
    } else {
        // 降级：仅发 notify_post
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

// ─── 信号处理（优雅退出） ─────────────────────────────────────

static void s_signal_handler(int sig) {
    s_log(@"收到信号 %d → 释放资源并退出", sig);
    s_releaseBKSAssertion();
    if (gLogFile) { fflush(gLogFile); fclose(gLogFile); gLogFile = NULL; }
    _exit(0);
}

static void s_setup_signal_handlers(void) {
    signal(SIGTERM, s_signal_handler);  // launchd 发送
    signal(SIGHUP, s_signal_handler);   // launchctl unload
    signal(SIGINT, s_signal_handler);   // Ctrl+C（调试用）
    s_log(@"已注册信号处理 (SIGTERM/SIGHUP/SIGINT)");
}

// ─── main ────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    s_open_log();

    // --resign-now: 终端手动触发（保留原有功能）
    if (argc >= 2 && strcmp(argv[1], "--resign-now") == 0) {
        s_log(@"收到 --resign-now");
        s_fire();
        s_log(@"触发完成 — 打开 App 时自动续签");
        if (gLogFile) { fflush(gLogFile); fclose(gLogFile); }
        return 0;
    }

    // 正常守护模式
    s_log(@"=== 启动 pid=%d uid=%d ===", getpid(), getuid());
    s_log(@"管理命令: sudo killall -HUP repro-signingd  (手动触发)");
    s_log(@"          launchctl kickstart gui/501/jp.soh.reprovision.signingd  (重启)");
    s_setup_signal_handlers();

    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    chown(kIpcDir.UTF8String, 501, 501);

    sd_config c = s_cfg();
    s_log(@"配置: 自动=%@ 间隔=%ld分 阈值=%ld天",
          c.enabled ? @"是" : @"否", (long)c.minutes, (long)c.days);
    s_log(@"BundleID: %@ | 触发路径: %@", kAppBundleID, kTriggerPath);
    s_log(@"架构: Daemon(调度+唤醒+保活) → App(后台静默签名) → exit(0)");
    s_log(@"      用户无需手动打开 App");

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

    // 续签完成通知 → 释放 BKS 保活
    int t2; notify_register_dispatch("com.reprovision.signing-complete", &t2,
        dispatch_get_main_queue(), ^(int _){
        s_log(@"续签完成 → 释放 BKSProcessAssertion");
        s_releaseBKSAssertion();
    });

    s_log(@"进入主循环");
    [[NSRunLoop mainRunLoop] run];
    return 0;
}
