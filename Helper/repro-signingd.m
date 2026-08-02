//
//  repro-signingd.m — 后台静默重签守护进程（v1.1.62 全面修复）
//
//  核心能力：
//    1. 定时器自动续签（可配置间隔，默认 2 小时）
//    2. 屏幕解锁触发（锁屏期间到期 → 解锁时立即执行）
//    3. 屏幕亮起触发（即将到期 ≤5s → 立即执行）
//    4. 低电量模式跳过
//    5. nextFireDate 持久化（daemon 重启后不丢失调度状态）
//    6. --resign-now 手动触发（同步执行，等待完成）
//    7. SIGHUP 信号触发续签（不退出 daemon）
//    8. 主动唤醒 App 到后台执行静默续签
//    9. ★ BKSProcessAssertion 保活（防止 App 被系统挂起）
//   10. ★ IOPMSchedulePowerEvent 系统级唤醒（锁屏时也能准时触发）
//
//  架构说明（与 test2 reprovisiond 一致）：
//    Daemon 本身不执行签名操作（签名需要 zsign + 凭证访问 + 网络请求）。
//    Daemon 的角色是「调度器 + 唤醒器 + 保活管理者」：
//      定时器/解锁/亮屏/SIGHUP → 写 trigger 标记 → SBSLaunchApplication 唤醒 App 到后台
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
static NSString *const kResultPath  = @"/var/mobile/Library/RePro/last-resign-result.plist";
static NSString *const kPidPath     = @"/var/mobile/Library/RePro/signingd.pid";
static NSString *const kAppBundleID = @"jp.soh.reprovision";

static const NSInteger  kFallbackMinutes = 120;   // 默认 2 小时
static const NSInteger  kFallbackDays    = 2;

static FILE     *gLogFile   = NULL;
static NSTimer  *gTimer     = nil;
static time_t    gLastFire  = 0;
static BOOL      gUpdateQueuedForUnlock = NO;
static int gLockStateToken = 0;
static int gBacklightToken = 0;

// ─── 续签状态跟踪 ────────────────────────────────────────────
// 用于判断续签是否真的成功：记录每次续签的开始/结束时间和状态
static time_t     gResignStartTime = 0;       // 本次续签开始时间
static BOOL       gResignInProgress = NO;     // 是否有续签正在进行
static NSInteger  gResignTotalCount  = 0;     // 累计续签次数
static NSInteger  gResignSuccessCount = 0;    // 成功次数
static NSString *gLastResignStatus  = @"";    // 上次续签状态

// ─── 日志（带文件删除自愈） ───────────────────────────────────

// 前向声明（C99 要求调用点之前声明）
static void s_open_log(void);
static void s_log(NSString *fmt, ...);

/// 检查日志文件是否仍然有效（被 rm 后 nlink 归零，写入会落到孤儿 inode）
///
/// ⚠️ v1.1.63 致命 BUG 修复：
///   旧版这里调用了 s_log()，而 s_log() 开头又会调用本函数 →
///   文件被删除时 gLogFile 尚未置空、nlink 仍为 0 → 无限递归 → 栈溢出 → daemon 崩溃退出。
///   这正是「删掉 reprorefresh_at.log 后 daemon 再也不写日志 / killall 找不到进程」的真正原因。
///   本函数内部一律只能用 NSLog，绝不能调用 s_log()。
static void s_ensure_log_valid(void) {
    if (!gLogFile) { s_open_log(); return; }
    struct stat st;
    if (fstat(fileno(gLogFile), &st) != 0 || st.st_nlink == 0) {
        NSLog(@"[repro-signingd] 日志文件已失效(nlink=0)，自动重建");
        fclose(gLogFile);
        gLogFile = NULL;
        s_open_log();
        if (gLogFile) {
            fprintf(gLogFile, "=== 日志文件曾被删除，已由 daemon 自动重建 ===\n");
            fflush(gLogFile);
        }
    }
}

static void s_log(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    char ts[64]; strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
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
    id rawMin = d[@"checkIntervalMin"];
    id rawEn  = d[@"autoResign"];
    id rawDy  = d[@"resignThreshold"];

    NSInteger m = [rawMin integerValue]; if (m < 1) m = kFallbackMinutes;
    NSInteger dy = [rawDy integerValue]; if (dy < 1) dy = kFallbackDays;
    BOOL en = rawEn ? [rawEn boolValue] : YES;

    return (sd_config){en, m, dy};
}

// ─── 状态持久化（nextFireDate） ──────────────────────────────────

static NSDate *s_getNextFireDate(void) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if (!state) return nil;
    return state[@"nextFireDate"];
}

static void s_setNextFireDate(NSDate *date) {
    if (!date) return;
    [@{@"nextFireDate": date} writeToFile:kStatePath atomically:YES];
    chown(kStatePath.UTF8String, 501, 501);
}

static void s_clearNextFireDate(void) {
    [[NSFileManager defaultManager] removeItemAtPath:kStatePath error:nil];
}

// 前向声明
static void s_start_timer(NSTimeInterval sec);

// ─── 唤醒 App 到后台执行静默续签（含保活 + 系统唤醒） ────────

static int32_t gAppPID = 0;
static void    *gBKSAssertion = NULL;

/// 前向声明：s_getAppPID 在 s_getAppPIDWithRetry 之前需要声明
static pid_t s_getAppPID(NSString *bundleID);

/// 获取 App 的 PID（通过 SBSProcessIDForDisplayIdentifier）
/// 带重试机制：RootHide 下 App 启动较慢，2秒可能不够
static pid_t s_getAppPIDWithRetry(NSString *bundleID, int maxRetries) {
    const int delays[] = {2, 5, 10};
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

/// 获取 BKSProcessAssertion 防止 App 被挂起
static void *s_acquireBKSAssertion(pid_t targetPid) {
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

    Class bksClass = NSClassFromString(@"BKSProcessAssertion");
    if (!bksClass) {
        s_log(@"无法获取 BKSProcessAssertion 类");
        dlclose(bksHandle);
        return NULL;
    }

    uint32_t flags = 0x3;  // PreventSuspend | AllowIdleSleep

    id assertion = [[bksClass alloc] init];
    SEL sel = NSSelectorFromString(@"_initWithPID:flags:reason:name:withHandler:");

    NSMethodSignature *sig = [assertion methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:assertion];

    pid_t pidVal = targetPid;
    uint32_t flagsVal = flags;
    NSString *reasonStr = @"jp.soh.reprovision background signing";
    NSString *nameStr = @"ReProvision";

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

    id finalResult = result ?: assertion;
    return (__bridge_retained void *)finalResult;
}

/// 设置系统级电源唤醒
///
/// ⚠️ RootHide 限制：IOPMSchedulePowerEvent 需要 IOKit 特权，
///    namespace 隔离环境下通常返回 kIOReturnNotPrivileged (0xE00002C6)。
///    此功能是「增强体验」非「核心链路」，失败时不阻塞续签。
///    屏幕解锁/背光监听仍能覆盖大部分场景。
static BOOL s_scheduleSystemWake(NSTimeInterval secondsFromNow) {
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKit) {
        s_log(@"[Step 3/3] 无法加载 IOKit — 系统级唤醒不可用（非致命）");
        return NO;
    }

    typedef int (*IOPMSchedFn)(CFDateRef, CFStringRef, CFStringRef);
    IOPMSchedFn schedFn = (IOPMSchedFn)dlsym(ioKit, "IOPMSchedulePowerEvent");
    if (!schedFn) {
        s_log(@"[Step 3/3] 无法找到 IOPMSchedulePowerEvent — 系统级唤醒不可用（非致命）");
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
        // 用十六进制避免溢出警告
        const char *reason = "未知";
        unsigned int uret = (unsigned int)ret;
        if (uret == 0xE00002C6) reason = "kIOReturnNotPrivileged (RootHide namespace 限制)";
        else if (uret == 0xE00002C5) reason = "kIOReturnNotPermitted (权限不足)";
        else if (uret == 0xE00002CA) reason = "kIOReturnBadArgument (参数错误)";
        s_log(@"[Step 3/3] 系统级唤醒失败 (ret=0x%08X: %s) — 非致命，屏幕解锁触发仍可用",
              uret, reason);
        return NO;
    }
}

/// 释放 BKSProcessAssertion
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

/// 同步版本：唤醒 App 并等待保活就绪（用于 --resign-now 和 SIGHUP 触发）
/// 与异步版 s_launchAppInBackground 的区别：此函数同步等待 BKS 获取完成
static BOOL s_launchAppAndWait(BOOL waitForCompletion) {
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

    if (!waitForCompletion) {
        // 异步模式：定时器触发的正常流程，用 dispatch_after 不阻塞主循环
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            pid_t appPID = s_getAppPIDWithRetry(kAppBundleID, 3);
            if (appPID > 0) {
                gAppPID = appPID;
                gBKSAssertion = s_acquireBKSAssertion(appPID);
                if (gBKSAssertion) {
                    s_log(@"[Step 2/3] BKSProcessAssertion 已生效 (pid=%d)", appPID);
                } else {
                    s_log(@"[Step 2/3] BKSProcessAssertion 获取失败");
                }
            } else {
                s_log(@"[Step 2/3] 重试3次仍无法获取 App PID — BKS 保活跳过");
            }
        });

        // Step 3: IOPM
        sd_config c = s_cfg();
        NSTimeInterval wakeInterval = ((NSTimeInterval)c.minutes * 60.0) - 30;
        if (wakeInterval > 10) {
            s_scheduleSystemWake(wakeInterval);
        }
        return YES;
    }

    // ── 同步模式：--resign-now / SIGHUP 触发，阻塞等待完成 ──
    // 等 2 秒让 App 启动
    sleep(2);

    // Step 2: 获取 PID + BKS 保活（同步重试）
    pid_t appPID = s_getAppPIDWithRetry(kAppBundleID, 3);
    if (appPID > 0) {
        gAppPID = appPID;
        gBKSAssertion = s_acquireBKSAssertion(appPID);
        if (gBKSAssertion) {
            s_log(@"[Step 2/3] BKSProcessAssertion 已生效 (pid=%d)", appPID);
        } else {
            s_log(@"[Step 2/3] BKSProcessAssertion 获取失败");
        }
    } else {
        s_log(@"[Step 2/3] 重试3次仍无法获取 App PID — BKS 保活跳过");
    }

    // Step 3: IOPM
    sd_config c = s_cfg();
    NSTimeInterval wakeInterval = ((NSTimeInterval)c.minutes * 60.0) - 30;
    if (wakeInterval > 10) {
        s_scheduleSystemWake(wakeInterval);
    }

    s_log(@"[完成] 已唤醒 App 并尝试保活 — App 将在后台静默执行续签");
    return YES;
}

/// 异步版本：用于定时器/解锁/亮屏触发（不阻塞主循环）
static BOOL s_launchAppInBackground(void) {
    return s_launchAppAndWait(NO);
}

// ─── 触发 ────────────────────────────────────────────────────────

static void s_fire(void) {
    sd_config c = s_cfg();
    if (!c.enabled) { s_log(@"自动续签已关闭，跳过"); return; }

    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        s_log(@"低电量模式，跳过续签");
        return;
    }

    // 记录续签开始
    gResignStartTime = time(NULL);
    gResignInProgress = YES;
    gResignTotalCount++;
    s_log(@"═══ 续签开始 #%ld ═══", (long)gResignTotalCount);

    time_t now = time(NULL);
    [@{
        @"timestamp": @(now),
        @"threshold": @(c.days),
        @"triggeredBy": @"daemon-timer",
    } writeToFile:kTriggerPath atomically:YES];
    chown(kTriggerPath.UTF8String, 501, 501);

    if (s_launchAppInBackground()) {
        s_log(@"触发续签 — 阈值 %ld 天（已唤醒 App）", (long)c.days);
    } else {
        notify_post("com.reprovision.schedule-resign");
        s_log(@"触发续签 — 阈值 %ld 天（降级为 notify_post）", (long)c.days);
    }
}

/// 执行一次完整的重签周期，然后重新设定时器
static void s_initiateAndReschedule(void) {
    s_fire();

    sd_config c = s_cfg();
    NSTimeInterval interval = (NSTimeInterval)c.minutes * 60.0;

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

static void s_startSigningTimer(void) {
    NSDate *savedNextFire = s_getNextFireDate();
    NSTimeInterval defaultInterval = (NSTimeInterval)s_cfg().minutes * 60.0;
    NSTimeInterval interval = defaultInterval;

    if (savedNextFire) {
        interval = [savedNextFire timeIntervalSinceNow];
        if (interval < 0) {
            s_log(@"保存的触发时间已过期，5 秒后立即执行");
            interval = 5;
        } else {
            s_log(@"从持久化恢复 — %.0f 秒后触发", interval);
        }
    }

    s_start_timer(interval);
}

// ─── 屏幕解锁 / 亮屏检测 ────────────────────────────────────────

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

static void bb_backlightChanged(int state) {
    if (state > 0) {
        s_log(@"屏幕亮起");

        NSDate *nextFire = s_getNextFireDate();
        if (nextFire) {
            NSTimeInterval remaining = [nextFire timeIntervalSinceNow];
            if (remaining <= 5) {
                s_log(@"即将到期 (%.0fs remaining) → 立即触发", remaining);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    s_initiateAndReschedule();
                });
                return;
            }
            s_log(@"未到期 — 重设剩余 %.0f 秒", remaining);
            s_start_timer(remaining);
        } else {
            s_start_timer((NSTimeInterval)s_cfg().minutes * 60.0);
        }
    } else {
        s_log(@"屏幕熄灭 → 停止定时器省电");
        [gTimer invalidate];
        gTimer = nil;
    }
}

static void s_setupNotifyPosts(void) {
    notify_register_dispatch("com.apple.springboard.lockstate", &gLockStateToken,
        dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        if (state == 0) { sb_didUIUnlockNotification(); }
    });

    notify_register_dispatch("com.apple.backboardd.backlight.changed", &gBacklightToken,
        dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        bb_backlightChanged((int)state);
    });

    s_log(@"已注册屏幕解锁/背光监听");
}

// ─── 信号处理 ─────────────────────────────────────────────────────
//
// v1.1.62 修复：
//   SIGTERM → 优雅退出（launchd stop / 系统关机）
//   SIGHUP  → 触发续签（用户手动 killall -HUP 或 launchctl kickstart）
//   SIGINT  → 优雅退出（调试用 Ctrl+C）

static dispatch_source_t gSigHupSrc  = nil;
static dispatch_source_t gSigTermSrc = nil;
static dispatch_source_t gSigIntSrc  = nil;
static dispatch_queue_t  gSignalQueue = nil;

/// 手动触发一次续签（SIGHUP 与 --resign-now 共用同一条路径）
static void s_manualResign(NSString *reason) {
    sd_config c = s_cfg();
    if (!c.enabled) { s_log(@"[%@] 自动续签已关闭，忽略本次触发", reason); return; }
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        s_log(@"[%@] 低电量模式，忽略本次触发", reason);
        return;
    }
    if (gResignInProgress && (time(NULL) - gResignStartTime) < 120) {
        s_log(@"[%@] 上一次续签仍在进行中（已 %ld 秒），忽略本次",
              reason, (long)(time(NULL) - gResignStartTime));
        return;
    }

    time_t now = time(NULL);
    gResignStartTime  = now;
    gResignInProgress = YES;
    gResignTotalCount++;
    s_log(@"═══ %@ 触发续签 #%ld ═══", reason, (long)gResignTotalCount);

    [@{
        @"timestamp":   @(now),
        @"threshold":   @(c.days),
        @"triggeredBy": reason,
    } writeToFile:kTriggerPath atomically:YES];
    chown(kTriggerPath.UTF8String, 501, 501);

    s_launchAppAndWait(YES);

    s_log(@"[%@] 唤醒流程结束 — 接下来应出现 App 侧日志（[AppDelegate] / [BridgeClient]）", reason);
    s_log(@"[%@] 若 30 秒内没有 App 侧日志，说明 App 没被拉起，请用 --status 查看诊断", reason);
}

static void s_gracefulExit(int sig) {
    s_log(@"收到信号 %d → 释放资源并退出", sig);
    s_releaseBKSAssertion();
    if (gLogFile) { fflush(gLogFile); fclose(gLogFile); gLogFile = NULL; }
    _exit(0);
}

/// v1.1.63 致命 BUG 修复：改用 dispatch_source 处理信号
///
/// 旧版用 signal(SIGHUP, handler) 注册 C 信号处理器，然后在处理器里调用
/// NSDictionary/NSLog/dlopen/sleep —— 这些统统不是「异步信号安全」函数。
/// 信号随时可能在主线程持有 malloc 锁 / NSLog 锁时到达，此时在处理器里再次
/// 申请同一把锁 → 直接死锁，进程卡死不再有任何输出。
/// 这就是 `sudo killall -HUP repro-signingd` 之后「没下文了」的根因。
///
/// dispatch_source 的 handler 在普通 dispatch 队列上执行（不在信号上下文中），
/// 可以安全调用任意 ObjC / Foundation / sleep。
static void s_setup_signal_handlers(void) {
    // dispatch source 只做「计数通知」，必须先把默认动作设为 SIG_IGN，
    // 否则 SIGHUP/SIGTERM 的默认动作（终止进程）会抢先生效。
    signal(SIGHUP,  SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT,  SIG_IGN);

    // SIGHUP 处理里有同步 sleep（最长十几秒），放独立串行队列，
    // 避免阻塞主 RunLoop 上的定时器与 notify 回调。
    gSignalQueue = dispatch_queue_create("com.reprovision.signingd.signal", DISPATCH_QUEUE_SERIAL);

    gSigHupSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, gSignalQueue);
    dispatch_source_set_event_handler(gSigHupSrc, ^{ s_manualResign(@"SIGHUP"); });
    dispatch_resume(gSigHupSrc);

    gSigTermSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gSigTermSrc, ^{ s_gracefulExit(SIGTERM); });
    dispatch_resume(gSigTermSrc);

    gSigIntSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gSigIntSrc, ^{ s_gracefulExit(SIGINT); });
    dispatch_resume(gSigIntSrc);

    s_log(@"已注册信号处理(dispatch_source): SIGHUP=触发续签(不退出), SIGTERM/SIGINT=优雅退出");
}

// ─── 续签完成回调 ───────────────────────────────────────────────

static void s_onSigningComplete(void) {
    time_t now = time(NULL);
    double elapsed = gResignStartTime > 0 ? difftime(now, gResignStartTime) : 0;

    gResignInProgress = NO;
    gResignSuccessCount++;
    gLastResignStatus = @"成功";

    s_log(@"═══ 续签完成 ═══ 耗时=%.0f秒 总计=%ld(成功=%ld)",
          elapsed, (long)gResignTotalCount, (long)gResignSuccessCount);

    s_releaseBKSAssertion();

    // 读取 App 侧写入的详细报告（谁被续签了 / 成功失败原因）
    NSDictionary *appReport = [NSDictionary dictionaryWithContentsOfFile:
                               [kIpcDir stringByAppendingString:@"/app-resign-report.plist"]];
    if (appReport) {
        BOOL ok = [appReport[@"result"] isEqualToString:@"success"];
        s_log(@"App 报告: 结果=%@ App侧耗时=%.1f秒 详情=%@",
              ok ? @"成功" : @"失败",
              [appReport[@"elapsed"] doubleValue],
              appReport[@"detail"] ?: @"（无）");
        gLastResignStatus = ok ? @"成功" : @"失败";
        if (!ok && gResignSuccessCount > 0) gResignSuccessCount--;  // 回滚乐观计数
    } else {
        s_log(@"App 未写入详细报告（可能是旧版 App 或续签未真正执行）");
    }

    // 将续签结果写入状态文件供 --status / App 查看
    NSMutableDictionary *result = [@{
        @"lastResignTime":    @(now),
        @"lastResignElapsed": @(elapsed),
        @"totalCount":        @(gResignTotalCount),
        @"successCount":      @(gResignSuccessCount),
        @"status":            gLastResignStatus ?: @"成功",
    } mutableCopy];
    if (appReport) result[@"appReport"] = appReport;
    [result writeToFile:kResultPath atomically:YES];
    chown(kResultPath.UTF8String, 501, 501);
}

// ─── --status 诊断输出 ──────────────────────────────────────────
// 让用户能一眼判断「到底有没有真的续签」，不用去猜日志。

static int s_printStatus(void) {
    printf("═══════════ RePro 续签守护进程状态 ═══════════\n");

    // 1. daemon 是否在跑
    NSString *pidStr = [NSString stringWithContentsOfFile:kPidPath
                                                 encoding:NSUTF8StringEncoding error:nil];
    pid_t dpid = pidStr ? (pid_t)[pidStr integerValue] : 0;
    if (dpid > 0 && kill(dpid, 0) == 0) {
        printf("daemon 状态      : ✅ 运行中 (pid=%d)\n", dpid);
    } else {
        printf("daemon 状态      : ❌ 未运行%s\n",
               dpid > 0 ? "（pid 文件存在但进程已死）" : "");
        printf("                   修复: launchctl kickstart -k system/jp.soh.reprovision.signingd\n");
    }

    // 2. 当前配置
    sd_config c = s_cfg();
    printf("自动续签开关     : %s\n", c.enabled ? "开" : "关");
    printf("检查间隔         : %ld 分钟\n", (long)c.minutes);
    printf("到期阈值         : %ld 天\n", (long)c.days);

    // 3. 下次计划触发
    NSDate *next = s_getNextFireDate();
    if (next) {
        printf("下次计划触发     : %s (%.1f 分钟后)\n",
               next.description.UTF8String, [next timeIntervalSinceNow] / 60.0);
    } else {
        printf("下次计划触发     : 未记录\n");
    }

    // 4. 最近一次「触发」（daemon 写 trigger 的时间）
    NSDictionary *trg = [NSDictionary dictionaryWithContentsOfFile:kTriggerPath];
    if (trg) {
        NSTimeInterval ago = [[NSDate date] timeIntervalSince1970] - [trg[@"timestamp"] doubleValue];
        printf("最近一次触发     : %.1f 分钟前，来源=%s\n",
               ago / 60.0, [(trg[@"triggeredBy"] ?: @"?") UTF8String]);
    } else {
        printf("最近一次触发     : 无记录\n");
    }

    // 5. 最近一次「续签结果」—— 这才是判断有没有真的续签的依据
    NSDictionary *res = [NSDictionary dictionaryWithContentsOfFile:kResultPath];
    if (res) {
        NSDate *rt = [NSDate dateWithTimeIntervalSince1970:[res[@"lastResignTime"] doubleValue]];
        printf("──────────────────────────────────────────────\n");
        printf("最近一次续签完成 : %s\n", rt.description.UTF8String);
        printf("  距今           : %.1f 分钟前\n", -[rt timeIntervalSinceNow] / 60.0);
        printf("  耗时           : %.0f 秒\n", [res[@"lastResignElapsed"] doubleValue]);
        printf("  结果           : %s\n", [(res[@"status"] ?: @"?") UTF8String]);
        printf("  累计/成功      : %ld / %ld\n",
               (long)[res[@"totalCount"] integerValue],
               (long)[res[@"successCount"] integerValue]);
        NSDictionary *ar = res[@"appReport"];
        if (ar) {
            printf("  ── App 侧回报 ──\n");
            printf("  结果           : %s\n", [(ar[@"result"] ?: @"?") UTF8String]);
            printf("  App 侧耗时     : %.1f 秒\n", [ar[@"elapsed"] doubleValue]);
            printf("  详情           : %s\n", [(ar[@"detail"] ?: @"（无）") UTF8String]);
            printf("  触发方式       : %s\n", [(ar[@"trigger"] ?: @"?") UTF8String]);
        } else {
            printf("  App 详细报告   : 无（App 未回报，续签可能没真正执行）\n");
        }
    } else {
        printf("──────────────────────────────────────────────\n");
        printf("最近一次续签完成 : ❌ 从未收到过 App 的完成回报\n");
        printf("  说明: daemon 只负责唤醒 App，真正签名在 App 内完成。\n");
        printf("        这里为空说明 App 没被成功拉起或没执行到续签。\n");
    }
    printf("══════════════════════════════════════════════\n");
    printf("日志: <jbroot>/var/log/reprorefresh_at.log\n");
    printf("      daemon 行前缀 [repro-signingd]，App 行前缀 [AppDelegate]/[BridgeClient]\n");
    return 0;
}

// ─── main ────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    s_open_log();

    // ── --status: 打印诊断状态（不写日志噪音，直接输出到终端） ──
    if (argc >= 2 && strcmp(argv[1], "--status") == 0) {
        return s_printStatus();
    }

    // ── --resign-now: 终端手动触发（同步执行） ──
    if (argc >= 2 && strcmp(argv[1], "--resign-now") == 0) {
        s_log(@"========================================");
        s_log(@"收到 --resign-now（同步模式）");
        s_log(@"========================================");

        // 与 SIGHUP 完全同一条路径，避免两份逻辑走偏
        s_manualResign(@"--resign-now");

        s_log(@"--resign-now 结束。用 --status 查看是否真的完成续签");
        s_log(@"========================================");
        if (gLogFile) { fflush(gLogFile); fclose(gLogFile); }
        return 0;
    }

    // ── 正常守护模式 ──
    s_log(@"========================================");
    s_log(@"=== 启动 pid=%d uid=%d ===", getpid(), getuid());
    s_log(@"管理命令:");
    s_log(@"  sudo /usr/libexec/repro-signingd --status      ← 查看是否真的续签了（推荐先看这个）");
    s_log(@"  sudo killall -HUP repro-signingd              ← 手动触发续签（daemon 不会退出）");
    s_log(@"  sudo /usr/libexec/repro-signingd --resign-now  ← 同步手动触发（前台看完整输出）");
    s_log(@"  sudo launchctl kickstart -k system/jp.soh.reprovision.signingd  ← 重启 daemon");
    s_log(@"========================================");
    s_setup_signal_handlers();

    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    chown(kIpcDir.UTF8String, 501, 501);

    // 写 pid 文件，供 --status 判断 daemon 是否存活
    [[NSString stringWithFormat:@"%d", getpid()] writeToFile:kPidPath
                                                  atomically:YES
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    chown(kPidPath.UTF8String, 501, 501);

    sd_config c = s_cfg();
    s_log(@"配置: 自动=%@ 间隔=%ld分 阈值=%ld天",
          c.enabled ? @"是" : @"否", (long)c.minutes, (long)c.days);
    s_log(@"BundleID: %@ | 触发路径: %@", kAppBundleID, kTriggerPath);
    s_log(@"架构: Daemon(调度+唤醒+保活) → App(后台静默签名) → exit(0)");
    s_log(@"      用户无需手动打开 App");

    // 注册系统通知监听
    s_setupNotifyPosts();

    // 启动定时器
    s_startSigningTimer();

    // 首次启动 5 秒后执行一次
    if (c.enabled) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ s_fire(); });
    }

    // 配置变更通知
    int t; notify_register_dispatch("com.reprovision.signingd-config-updated", &t,
        dispatch_get_main_queue(), ^(int _){
        s_log(@"配置变更 → 重读并重设定时器");
        s_startSigningTimer();
    });

    // 续签完成通知 → 更新统计 + 释放 BKS
    int t2; notify_register_dispatch("com.reprovision.signing-complete", &t2,
        dispatch_get_main_queue(), ^(int _){
        s_onSigningComplete();
    });

    s_log(@"进入主循环（等待定时器/SIGHUP/解锁/亮屏触发）");
    [[NSRunLoop mainRunLoop] run];
    return 0;
}
