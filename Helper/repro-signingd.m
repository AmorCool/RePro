//
//  repro-signingd.m — 后台静默重签守护进程（v1.1.64~1.1.67 持续修复）
//
//  ★ v1.1.64 修了 6 个真实存在、且互相叠加导致「自动续签从来没成功过」的硬伤：
//    1. 配置读不到（用户主诉：App 里设的间隔/阈值跟 daemon 用的对不上）
//       → 改为优先直读 App 的 UserDefaults(CFPreferences)，三级回退
//    2. SBSProcessIDForDisplayIdentifier 把「出参 pid」当返回值用
//       → 永远拿不到 App PID，日志刷屏「BKS 保活跳过」
//    3. SBSLaunchApplicationWithIdentifierAndLaunchOptions 的字典 key 是编的、
//       第三个参数 suspended 传成了 NULL、返回值被丢弃
//       → App 从头到尾根本没被拉起来
//    4. BKSProcessAssertion 的 flags/reason/selector/block 生命周期四处错
//    5. IOPMSchedulePowerEvent 的 type 传了不存在的 "AutoWakeOrPowerOn"
//       → 恒定 kIOReturnBadArgument(0xE00002C2)，正确值是 "wakepoweron"
//    6. 熄屏就 invalidate 定时器 → 锁屏期间彻底没有触发源
//    另外：CI 对本 daemon 只做裸签（零 entitlements），缺
//    com.apple.backboardd.launchapplications 等三项权限，2/3/4 注定失败。
//    已新增 Resources/entitlements-signingd{,-roothide}.plist 并接入 CI。
//
//  核心能力：
//    1. 🔴 v1.1.155 起「短命模式」：launchd StartCalendarInterval 每 5 分钟拉起一次，
//       每次启动立即做一轮到期检查 → 需要续签则唤醒 App 并等待其完成 → 退出。
//       进程不再 KeepAlive 常驻 → 绕开 iOS 17 launchd "inefficient" SIGKILL 杀循环，
//       也让 RootHide XPC 拦截器的常驻泄漏彻底没有累积机会（一石二鸟）。
//    2. 到期检查：读 App 配置（间隔/阈值/开关）+ 24h 冷却（last-resign-result.plist）
//    3. 低电量模式跳过
//    4. --resign-now 手动触发（同步执行，等待完成）★ 手动触发的推荐方式
//    5. SIGHUP 信号触发续签（仅进程存活期间有效，短命模式不保证）
//    6. 主动唤醒 App 到后台执行静默续签
//    7. ★ BKSProcessAssertion 保活（等待 App 完成期间防止被系统挂起）
//    8. v1.1.95 解除免费账号「同一设备最多 3 个自签应用」限制
//          （删除 .app 目录上的 com.apple.installd.validatedByFreeProfile 扩展属性，
//           参考 rooootdev/Lara；每次签名/续签完成后自动执行，需在 App 设置里开启）
//
//  架构说明（与 test2 reprovisiond 一致）：
//    Daemon 本身不执行签名操作（签名需要 zsign + 凭证访问 + 网络请求）。
//    Daemon 的角色是「短命调度器 + 唤醒器 + 保活管理者」：
//      launchd 定时拉起 → 冷却检查 → 写 trigger 标记 → SBSLaunchApplication 唤醒 App 到后台
//      → BKSProcessAssertion 防止 App 被挂起 → App 执行 silentResignAndExit → exit(0)
//      → App 完成时 notify("cn.analy.resign.signing-complete") → daemon 写 lastResignTime → 退出
//    用户全程无需手动打开 App；设备深睡错过调度会在唤醒后由 launchd 立即补执行。
//
//  日志: fopen/fprintf 同步写入 <jbroot>/var/log/reprorefresh_at.log
//  日志文件被删除后会自动检测并重新创建（fstat nlink 检查）
//

#include <notify.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <dlfcn.h>
#include <pthread.h>   // v1.1.186：超时看门狗独立线程（不依赖主 runloop）
#include <mach-o/dyld.h>   // v2.1.13：_NSGetExecutablePath 推自身越狱根（TMPDIR 用 jbroot 绝对路径）
#include <limits.h>        // PATH_MAX
#include <spawn.h>         // v2.1.26：fix-cellular 由 daemon 代拉 repro-helper（posix_spawn）
#include <sys/wait.h>      // v2.1.26：waitpid / WEXITSTATUS
#include <fcntl.h>         // v2.1.26：posix_spawn_file_actions_addopen 的 O_WRONLY/O_CREAT/O_TRUNC
#import <mach/mach.h>
#import <Foundation/Foundation.h>

// 🔴 v2.1.0：signingd 自己执行签名管线（原版 ReProvision 架构，不再唤醒 App）。
// 需要签名相关的私有实现头：
#import "RPVProfileStore.h"   // profile 解析/安装/通知 profiled
#import "EEBackend.h"         // 签名管线入口（内部走 EEProvisioning + RZSignRunner/zsign）

// LSApplicationWorkspace 不在公开 SDK 头（与 App 侧 RPVApplicationSigning 相同声明方式）
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
@end

// ─── 越狱形态检测（前向声明：崩溃循环诊断在文件前部即调用，须先声明） ───
typedef NS_ENUM(NSInteger, RPVJbFlavor) {
    RPVJbFlavorRootful  = 0,
    RPVJbFlavorRootless = 1,
    RPVJbFlavorRootHide = 2,
};
static BOOL s_path_exists(NSString *p);
static RPVJbFlavor s_jb_flavor(void);
static NSString *s_flavor_name(RPVJbFlavor f);
static NSString *s_exec_env_report(void);

static NSString *const kIpcDir      = @"/var/mobile/Library/Resign";
static NSString *const kConfigPath  = @"/var/mobile/Library/Resign/signingd-config.plist";
static NSString *const kTriggerPath = @"/var/mobile/Library/Resign/auto-resign-trigger";
static NSString *const kResultPath  = @"/var/mobile/Library/Resign/last-resign-result.plist";
static NSString *const kPidPath     = @"/var/mobile/Library/Resign/signingd.pid";

// 🔴 v2.1.26：联网修复（fix-cellular）请求/结果通道。
// 背景：App 是沙箱进程，iOS 不允许沙箱进程 posix_spawn 一个带 no-sandbox 的二进制；
// 而 CoreTelephony 私有 API 必须在**无沙箱**上下文里调（沙箱下 CommCenter XPC 被拒，
// _CTServerConnectionCreateOnTargetQueue 返回空 → 退出码 13）。
// 本 daemon 由 launchd 以 root 拉起、天然无沙箱，正好当这个执行者：
//   App 写 request → helper(setuid root) kickstart 本 daemon（或 notify 直达在跑的实例）
//   → daemon spawn `repro-helper fix-cellular <bid>` → 写 result → App 轮询读走。
static NSString *const kFixCellReqPath = @"/var/mobile/Library/Resign/fix-cellular-request.plist";
static NSString *const kFixCellResPath = @"/var/mobile/Library/Resign/fix-cellular-result.plist";
// 请求有效期：超过这个秒数的残留请求直接丢弃，避免开机时补跑一个几天前的老请求
static const NSTimeInterval kFixCellReqTTL = 180.0;
// ⚠️ v1.1.69 关键修复：此前此处写成 @"cn.analy.resign"，但 App 真实的
// CFBundleIdentifier（SpringBoard 注册 ID）= "cn.analy.resign"（见 pbxproj
// PRODUCT_BUNDLE_IDENTIFIER 与 deb 内 Info.plist）。SBS 用 BundleID 查 App，
// 传错 ID → SBSProcessIDForDisplayIdentifier 返回 NO、SBSLaunch 返回 7（"App 未注册"），
// App 永远拉不起来 → 自动续签从未真正发生。现已改为正确的 BundleID。
// （kAppBundleID 也用于读 App 配置：App 把设置同步到共享 plist
//  /var/mobile/Library/Resign/signingd-config.plist，与 BundleID 无关，不受影响。）
static NSString *const kAppBundleID = @"cn.analy.resign";

// 免费账号「同一设备最多 3 个自签应用」限制所依赖的扩展属性名
static const char *const kFreeProfileXattr = "com.apple.installd.validatedByFreeProfile";
// 用户 App 安装根目录（rootless / RootHide 下真实路径一致；daemon 跑在 rootfs 真实命名空间）
static NSString *const kBundleRoot = @"/var/containers/Bundle/Application";

static const NSInteger  kFallbackDays    = 2;

// 🔴 v1.1.184：**取消续签后 24 小时冷却**（用户明确要求）。
// 冷却本来是为了压住「刚签完还在到期窗口内 → 每 2 小时全量重签」的老问题，
// 但那个问题的真正根因是「提前重签天数 ≥ profile 有效期」，已由 kMaxThresholdDays=6
// 和续签窗口的**严格小于**判定（见 RPVApplicationSigning）从源头解决：
// 免费账号刚签完剩余 7 天 > 6 天窗口 → 自然要等约一天才会再次命中。
// 冷却在此之上属于重复约束，还会让用户「改完设置马上想续签」时被静默拒绝。
// 现改为由用户可配的「检测间隔」节流（下方 kMaxCheckIntervalHours）。

// v1.1.184 检测间隔：launchd 每小时把本 daemon 拉起一次，daemon 自己按用户设定的
// 间隔决定这一轮到底干不干活。用户要求上限 12 小时。
static const NSInteger kDefaultCheckIntervalHours = 1;
static const NSInteger kMaxCheckIntervalHours     = 12;
// 记录「上一次真正执行检测的时刻」，跨进程持久化（daemon 是短命进程，内存变量留不住）
static NSString *const kCheckStatePath = @"/var/mobile/Library/Resign/signingd-check-state.plist";

// 🔴 v1.1.148 提前重签阈值上限（用户要求：最多只能提前 6 天）。
// 根因：免费 Apple ID 的 profile 有效期只有 7 天，若阈值允许 7 天，
// 刚签完的应用剩余 7 天 ≤ 7 天窗口 → 永远在到期窗口内 → 每次触发都全量重签。
// 上限 6 天保证「签完 → 至少第 2 天起才可能再次命中窗口」，配合 24h 冷却，
// 免费账号实际续签频率被约束为「最多每天一次」。
static const NSInteger  kMaxThresholdDays = 6;

static FILE     *gLogFile   = NULL;
static NSString *sLogPath   = nil;   // v1.1.152：实际写入的文件路径（调试/--status 用）
static time_t    gResignStartTime = 0;       // 本次续签开始时间
static BOOL      gResignInProgress = NO;     // 是否有续签正在进行

// 前向声明（定义在本文件后面，看门狗等早期函数需要调用）
static void s_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// ─── 内存看门狗（v1.1.150，2026-08-06 v1.1.192 根本性重写）─────────────
//
// 🔴 真机实锤（22:25-22:27，31 次 Jetsam largestProcess=repro-signingd）：
//   旧版用 dispatch_source_timer 挂在 dispatch_get_main_queue() ——
//   signingd 在 RootHide SafeMode 注入异常下主线程卡死时，
//   dispatch_source timer handler 同样停摆 → 内存看门狗形同虚设 →
//   2 分钟内暴涨到 largestProcess（>1GB）→ 触发整机 Jetsam 雪崩 31 次 →
//   SpringBoard 反复被杀 → 用户看到注销动画死循环 → ResetCounter 整机重启。
//
//   现在与超时看门狗（v1.1.186/190）同一模式：独立 pthread sleep+_exit，
//   不依赖主 runloop，不调 NSLog（避免 logd 阻塞），1 分钟检查一次。
//   🔴 v2.1.2：签名中不再豁免。v2.1.0 起签名管线（EEBackend/ChOma/zsign）
//   在 daemon 进程内执行，签名卡死时内存失控恰好落在旧豁免区 → 涨到
//   largestProcess 触发整机 Jetsam（真机 17:14 实锤）。签名峰值放宽到
//   250MB（4GB 设备远低于危险线），超限无条件 _exit，launchd 下轮拉起。
static const uint64_t kMemWatchdogLimit = 45ULL * 1024 * 1024;        // 非签名：45 MB（< MemoryLimit 50MB）
static const uint64_t kMemWatchdogSigningLimit = 250ULL * 1024 * 1024; // 签名中：250 MB（防 Jetsam 级暴涨）

static void *s_memWatchdogMain(void *arg) {
    (void)arg;
    sleep(10);  // 首次 10 秒检查（泄漏可能很快超 MemoryLimit 50MB，必须早于系统 jetsam）
    while (1) {
        task_vm_info_data_t info;
        mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
        kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                     (task_info_t)&info, &cnt);
        uint64_t limit = gResignInProgress ? kMemWatchdogSigningLimit : kMemWatchdogLimit;
        if (kr != KERN_SUCCESS || info.phys_footprint <= limit) {
            sleep(15);  // 正常或取不到数据，每 15 秒检查一次（低于 MemoryLimit 50MB 的卡点）
            continue;
        }
        // 超标（签名中 250MB / 非签名 45MB）：无条件 _exit(0)，不调 NSLog（避免 logd 阻塞）
        if (gLogFile) { fflush(gLogFile); fclose(gLogFile); gLogFile = NULL; }
        _exit(0);
    }
    return NULL;
}
static void s_startMemWatchdog(void) {
    pthread_t t;
    if (pthread_create(&t, NULL, s_memWatchdogMain, NULL) == 0) {
        pthread_detach(t);
        s_log(@"内存看门狗已启动（独立线程，10 秒首次自检后每 15 秒；非签名超 45MB / 签名中超 250MB 主动退出）");
    }
}

// ─── 超时看门狗（v1.1.186，方案D：防僵尸实例）──────────────────────────
//
// 🔴 真机实锤：11:02 被 launchd 拉起的实例在主线程上被**永久阻塞**——
// 5 分钟超时的 dispatch_after 也在主 runloop 上，主线程卡死它同样不触发，
// 于是那个进程成了僵尸，占住 job 整整 3 小时（pid 1468 直到 14:23 被我强杀）。
// 而 launchd 的 StartCalendarInterval 不会为「运行中」的 job 新起实例 →
// 12:00 / 13:00 / 14:00 的定时检查全部被僵尸吞掉 → 用户设置 1 小时却一直没检查。
//
// 解决：用**独立 pthread**（sleep + _exit，不依赖主 runloop / dispatch）——
// 正常流程最坏 5 分钟（等 App 完成）必然结束，10 分钟阈值绝不会误杀；
// 一旦主线程真卡死，看门狗照样强制退出，launchd 下一轮重新拉起。
//
// 🔴 v1.1.190 教训（真机 pid 5363 卡死 92 分钟实锤）：旧版线程先 NSLog 再 _exit(0)——
// RootHide 下 NSLog 走 ASL/os_log，logd 通信一旦不可达就可能**永久阻塞**，
// _exit(0) 永远执行不到 → 看门狗形同虚设 → 僵尸实例照样挡住下一轮拉起。
// 必须**先 _exit(0) 再考虑打日志**（_exit 是无条件进程终止，不依赖任何服务）。
// 🔴 v2.1.0：看门狗从「固定 10 分钟」改为「空闲 10 分钟」。
// 背景：daemon 自己签名（v2.1.0 起）多个 app 串行可能超过 10 分钟
//（每个 app 上限 5 分钟），固定超时会误杀正常签名。
// 新逻辑：签名进行中（gResignInProgress）不累计；空闲超过 10 分钟仍不退出
// → 判定僵尸，无条件 _exit（launchd 下一轮拉起）。
static void *s_runWatchdogMain(void *arg) {
    (void)arg;
    time_t idleSince = time(NULL);
    time_t signSince = 0;   // 🔴 v2.1.2：签名开始时间（防签名卡死永不结束）
    while (1) {
        sleep(60);
        if (gResignInProgress) {
            if (signSince == 0) signSince = time(NULL);
            // 🔴 v2.1.2：签名中加整体硬超时（20 分钟）。v2.1.0 签名在 daemon 内，
            // 单 app 5 分钟超时已 _exit；此兜底覆盖多 app 串行整体卡死场景。
            if ((time(NULL) - signSince) >= 20 * 60) {
                _exit(0);
            }
            continue;
        }
        signSince = 0;
        if ((time(NULL) - idleSince) >= 10 * 60) {
            // 无条件终止进程——NSLog 放 _exit 之后（不可达），避免 logd 阻塞拖死看门狗
            _exit(0);
        }
    }
    return NULL;
}
static void s_startRunWatchdog(void) {
    pthread_t t;
    if (pthread_create(&t, NULL, s_runWatchdogMain, NULL) == 0) {
        pthread_detach(t);
        s_log(@"超时看门狗已启动（独立线程，空闲超 10 分钟 / 签名整体超 20 分钟强制退出）");
    }
}

// ─── 崩溃循环检测（v1.1.150，方案C）──────────────────────────────────
// daemon 每次被 launchd 拉起都记一次。若 10 分钟内 ≥3 次，说明在崩溃循环
// （RootHide hook 不稳定时常见），写醒目告警帮助定位是环境问题还是代码问题。
static void s_checkCrashLoop(void) {
    NSString *path = [kIpcDir stringByAppendingString:@"/signingd-crash-count.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    double first = d ? [d[@"first"] doubleValue] : 0;
    NSInteger count = d ? [d[@"count"] integerValue] : 0;
    time_t now = time(NULL);
    if (first <= 0 || (now - (time_t)first) > 600) { first = now; count = 1; }
    else { count += 1; }
    [@{@"first": @(first), @"count": @(count)} writeToFile:path atomically:YES];
    chown(path.UTF8String, 501, 501);
    if (count >= 3) {
        s_log(@"⚠️⚠️⚠️ daemon 10 分钟内已被拉起 %ld 次（崩溃循环）", (long)count);
        s_log(@"   疑似越狱环境 hook 问题（%@）—— 建议更新对应越狱工具/roothide，或重装本 deb；", s_flavor_name(s_jb_flavor()));
        s_log(@"   若重启后仍循环，用 --status 排查，并把本日志反馈给作者");
    }
}
static NSInteger  gResignTotalCount  = 0;     // 累计续签次数
static NSInteger  gResignSuccessCount = 0;    // 成功次数
static NSString *gLastResignStatus  = @"";    // 上次续签状态

// ─── 日志（带文件删除自愈） ───────────────────────────────────

// 前向声明（C99 要求调用点之前声明）
static void s_open_log(void);
static void s_log(NSString *fmt, ...);
static void *s_sbsHandle(void);

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
    // ★ v1.1.152：写文件失败时仍强制 NSLog 多次（iOS 17 launchd 下 stdout
    // 可能被丢，但 NSLog 走 ASL/os_log 系统服务，至少在 syslog -w 或 Console.app 能看到）
    NSLog(@"[repro-signingd] %@", s);
    // 写文件失败时额外打 stderr（plink --status 这类场景能直接看到）
    if (!gLogFile) fprintf(stderr, "[repro-signingd] [%s] %s\n", ts, s.UTF8String);
}

static void s_open_log(void) {
    NSString *dir = nil, *jb = nil;
    NSString *a0 = [[[NSProcessInfo processInfo] arguments] firstObject];
    if (a0) {
        NSRange r = [a0 rangeOfString:@"/usr/libexec/" options:NSBackwardsSearch];
        if (r.location != NSNotFound) jb = [a0 substringToIndex:r.location];
    }
    // 🔴 v1.1.186：argv[0] 可能是 "/usr/libexec/repro-signingd"（无 jbroot 前缀，
    //  RootHide 的 env 包装启动路径），substringToIndex:0 得到的是 @""（非 nil）——
    //  旧代码 `if (!jb)` 接不住空串 → dir 变成相对路径 "var/log" → 日志写到
    //  cwd 下的 var/log，落点完全错误。必须用 length == 0 判断。
    if (jb.length == 0) jb = @"/var/jb";
    dir = [jb stringByAppendingPathComponent:@"var/log"];

    // ★ v1.1.152 fallback 链：iOS 17 RootHide 容器化下 fopen("a") 可能写不出
    // （实测：/var/jb/var/log/reprorefresh_at.log mtime=安装时间，size=0）。
    // 按真实可写性顺序尝试 4 个候选路径，任意一个成功就 break。
    //
    // 🔴 v1.1.186 候选顺序调整：把「豁免目录」放到第一位。
    // 真机实测（RootHide + user/501 域 + SafeMode env 包装）：daemon 是 vroot 进程，
    // /var/jb/var/log 与 /var/mobile/Library/Logs/RePro 都被 overlay 重定向到
    // AppGroup 假目录（/rootfs/var/mobile/Containers/Shared/AppGroup/.jbroot-XXX/…），
    // 日志写在那里，用户 SSH / 爱思 / App 全部看不到 —— 表现为「没生成日志」。
    // 而 /var/mobile/Library/Resign 是 RootHide 明确的「豁免 overlay 共享 IPC 目录」，
    // daemon 写它 = 真实 rootfs（pid/check-state/crash-count 都写在这里），
    // App 也是 mobile 可读 → 日志放这里，App 日志页与 SSH 都能直接看到。
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/Library/Resign/reprorefresh_at.log",               // ★ 豁免目录=真实 rootfs（v1.1.186 首选）
        [dir stringByAppendingPathComponent:@"reprorefresh_at.log"],   // 原路径：jbroot 容器内
        @"/var/mobile/Library/Logs/RePro/reprorefresh_at.log",        // 真实 syslog 旁路
        @"/tmp/reprorefresh_at.log",                                   // 最后兜底（重启清空）
    ];
    for (NSString *p in candidates) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions:@0755}
                                                        error:nil];
        gLogFile = fopen(p.UTF8String, "a");
        if (gLogFile) {
            chmod(p.UTF8String, 0666);
            sLogPath = p;  // 记录成功路径，s_log 失败时打印
            return;
        }
    }
    // 四条路径全部失败 → 留 NSLog 警告，但 s_log 仍能 NSLog 输出
    NSLog(@"[repro-signingd] ⚠️ 无法打开任何日志文件路径（候选：%@），仅写系统日志", candidates);
}

/// 运行 shell 命令并取 stdout（用于读取自身 entitlement）
static NSString *s_run_cmd(NSString *cmd) {
    FILE *pipe = popen(cmd.UTF8String, "r");
    if (!pipe) return nil;
    NSMutableData *data = [NSMutableData data];
    char buf[1024];
    while (fgets(buf, sizeof(buf), pipe)) [data appendBytes:buf length:strlen(buf)];
    pclose(pipe);
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return (out.length ? out : nil);
}

/// 判断某个命令行工具是否在当前 PATH 可达（popen 用 /bin/sh，PATH 来自 launchd 环境）
static BOOL s_tool_exists(NSString *name) {
    NSString *out = s_run_cmd([NSString stringWithFormat:
        @"command -v '%@' 2>/dev/null || which '%@' 2>/dev/null", name, name]);
    return out.length > 0;
}

/// 读取 daemon 自身签名里的 entitlement XML。
/// iOS 上 codesign 可能没装，用 ldid -e 兜底（越狱设备通常都有 ldid）。
static NSString *s_read_self_entitlements_xml(void) {
    NSString *me = [[[NSProcessInfo processInfo] arguments] firstObject];
    if (!me.length) return nil;
    NSString *out = s_run_cmd([NSString stringWithFormat:
        @"/usr/bin/codesign -d --entitlements :- '%@' 2>/dev/null", me]);
    if (out.length) return out;
    out = s_run_cmd([NSString stringWithFormat:@"ldid -e '%@' 2>/dev/null", me]);
    return out;
}

/// daemon 自包含的越狱形态检测（daemon 不是 App bundle，拿不到 App 的 .jbroot 符号链接，
/// 故用文件系统标记判断）：
///   /.roothide 存在           → RootHide（随机 jbroot + namespace 隔离）
///   /var/jb 存在（bind mount）→ Rootless（Dopamine/TrollStore，无 namespace 隔离）
///   其它                       → Rootful（标准根路径）

static BOOL s_path_exists(NSString *p) {
    return [[NSFileManager defaultManager] fileExistsAtPath:p];
}

static RPVJbFlavor s_jb_flavor(void) {
    if (s_path_exists(@"/.roothide")) return RPVJbFlavorRootHide;
    if (s_path_exists(@"/var/jb"))    return RPVJbFlavorRootless;
    return RPVJbFlavorRootful;
}

static NSString *s_flavor_name(RPVJbFlavor f) {
    switch (f) {
        case RPVJbFlavorRootHide: return @"RootHide";
        case RPVJbFlavorRootless: return @"Rootless";
        case RPVJbFlavorRootful:  return @"Rootful";
    }
    return @"Unknown";
}

/// 说明 daemon 实际运行环境。
///   RootHide：有 namespace 隔离，是否跑在真实 rootfs namespace 决定 entitlement 是否被剥离。
///   Rootless/Rootful：无 namespace 隔离，jbroot 只是 bind mount，entitlement 完整保留。
/// 注：libproc.h/proc_pidpath 是 macOS 专属，iOS SDK 没有，故用进程启动路径判断。
static NSString *s_exec_env_report(void) {
    NSString *me = [[[NSProcessInfo processInfo] arguments] firstObject];
    RPVJbFlavor f = s_jb_flavor();
    if (me.length == 0) return @"无法取得自身启动路径";
    if (f == RPVJbFlavorRootHide) {
        if ([me hasPrefix:@"/var/jb/"])
            return [NSString stringWithFormat:@"jbroot namespace (启动路径=%@) ❌ 私有权限会被 RootHide 剥离", me];
        return [NSString stringWithFormat:@"rootfs 真实 namespace (启动路径=%@) ✅ entitlement 应保留", me];
    }
    NSString *kind = (f == RPVJbFlavorRootless)
        ? @"rootless jbroot（bind mount，无 namespace 隔离）"
        : @"rootfs（rootful，无 namespace 隔离）";
    return [NSString stringWithFormat:@"%@ (启动路径=%@) ✅ entitlement 完整保留（无 namespace 剥离）", kind, me];
}

/// 缓存的自检报告（进程内只算一次，每次触发都打印，避免重复 popen 刷屏）
static NSString *gSelfEntitlementReport = nil;

/// 计算自身 entitlement 自检报告（进程启动时调用一次）
static void s_compute_self_entitlements(void) {
    RPVJbFlavor f = s_jb_flavor();
    NSString *flavor = s_flavor_name(f);
    // RootHide 下 daemon 跑在 rootfs 真实 namespace，而 ldid/codesign 装在 jbroot，
    // 不在 daemon 的 PATH 里 → popen 调不到。Rootless 同理（工具在 /var/jb/usr/bin）。
    // 此时读不到 ≠ 二进制没签名（已用 Mach-O 解析证明 CI 确实签上了 entitlements）。
    // 避免误报「CI 裸签」。
    BOOL toolsAvailable = s_tool_exists(@"/usr/bin/codesign") || s_tool_exists(@"/var/jb/usr/bin/codesign")
                       || s_tool_exists(@"/usr/bin/ldid")    || s_tool_exists(@"/var/jb/usr/bin/ldid")
                       || s_tool_exists(@"codesign")         || s_tool_exists(@"ldid");
    if (!toolsAvailable) {
        NSString *daemonPath = (f == RPVJbFlavorRootless) ? @"/var/jb/usr/libexec/repro-signingd"
                                                          : @"/usr/libexec/repro-signingd";
        gSelfEntitlementReport = [NSString stringWithFormat:
            @"ℹ️ 无法自检 entitlement（ldid/codesign 装在 jbroot 不在 daemon 的 PATH，属 %@ 越狱环境正常现象，不代表未签名）\n"
            @"  %@\n"
            @"  （若怀疑裸签，请用 ssh 进设备执行 `ldid -e %@` 手动确认）",
            flavor, s_exec_env_report(), daemonPath];
        return;
    }
    NSString *xml = s_read_self_entitlements_xml();
    if (xml.length == 0) {
        gSelfEntitlementReport = [NSString stringWithFormat:
            @"⚠️ 无法读取自身 entitlement（codesign/ldid 可用但都没返回 → 确属 CI 裸签，必须 do_sign 带 entitlements）\n  %@", s_exec_env_report()];
        return;
    }
    BOOL hasLaunch = [xml containsString:@"com.apple.backboardd.launchapplications"];
    BOOL hasUnlim  = [xml containsString:@"com.apple.multitasking.unlimitedassertions"];
    BOOL hasSys    = [xml containsString:@"com.apple.multitasking.systemappassertions"];
    NSString *launchNote = (f == RPVJbFlavorRootHide) ? @"❌缺失(被 RootHide 剥离)" : @"❌缺失";
    NSMutableString *r = [NSMutableString stringWithFormat:
        @"自身 entitlement 自检: backboardd.launchapplications=%@  unlimitedassertions=%@  systemappassertions=%@\n"
        @"  %@",
        hasLaunch ? @"✅有" : launchNote,
        hasUnlim  ? @"✅有" : @"❌缺失",
        hasSys    ? @"✅有" : @"❌缺失",
        s_exec_env_report()];
    if (!hasLaunch && f == RPVJbFlavorRootHide) {
        [r appendString:@"\n  ❌ 致命: backboardd.launchapplications 缺失 → daemon 跑在 jbroot namespace，"
                        "SBSLaunch 必返回 7。修复: roothide postinst 必须用 jbroot 命令把 plist 转 rootfs 路径再 launchctl bootstrap。"];
    }
    gSelfEntitlementReport = r;
}

/// 每次触发都打印的自检（进程内只算一次，之后复用缓存）。
/// 🔴 v1.1.187：打印也去重 —— 旧版 s_fire 每轮都重复打 3 行
/// （无法自检/namespace/若怀疑裸签），App 日志页导入后全是噪音。
static void s_report_self_entitlements(void) {
    static BOOL printed = NO;
    if (!gSelfEntitlementReport) s_compute_self_entitlements();
    if (!printed) {
        printed = YES;
        s_log(@"%@", gSelfEntitlementReport ?: @"⚠️ 未检测到自身 entitlement 信息");
    }
}

/// App 是否已注册到 SpringBoard（即便没在运行，注册了 SBSProcessID 也返回 YES）。
/// 用于区分「App 未注册(uicache 问题)」与「App 已注册但后台启动被拒(权限问题)」。
static BOOL s_isAppRegistered(NSString *bundleID, pid_t *outPid) {
    void *sbs = s_sbsHandle();
    if (!sbs) { if (outPid) *outPid = 0; return NO; }
    static BOOL (*fn)(CFStringRef, pid_t *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (BOOL (*)(CFStringRef, pid_t *))dlsym(sbs, "SBSProcessIDForDisplayIdentifier");
    });
    if (!fn) { if (outPid) *outPid = 0; return NO; }
    pid_t pid = 0;
    BOOL ok = fn((__bridge CFStringRef)bundleID, &pid);
    if (outPid) *outPid = pid;
    return ok;
}

// ─── 配置 ────────────────────────────────────────────────────────
//
// ⚠️ v1.1.64 关键修复 —— 用户主诉「App 里设的检查间隔 / 提前重签天数，跟 daemon 实际用的不一样」
//
//   旧版 daemon 只认 /var/mobile/Library/Resign/signingd-config.plist 这一个来源，
//   而这个文件只有 App 在前台改设置时才会被写出来。只要 App 没被打开过
//   （而 daemon 的整个存在意义恰恰就是「不用打开 App」），文件就不存在，
//   daemon 于是一路打「配置文件不存在」并用死值 120 分 / 2 天 跑，
//   跟界面上的设置完全脱节。这就是日志里刷屏的那行的真正含义。
//
//   现在按 ReProvision 原版 reprovisiond 的做法：优先直接读 App 自己的
//   UserDefaults（CFPreferences，appID=cn.analy.resign，user=mobile）。
//   只要用户在界面上动过设置，这份数据一定存在，且不依赖 App 主动同步。
//   读不到再依次回退到共享 plist、App 容器内的偏好文件。

typedef struct {
    BOOL      enabled;
    NSInteger days;
    BOOL      forceResignLowPower;
    NSInteger checkIntervalHours;   // v1.1.184：用户可配检测间隔（1~12 小时）
} sd_config;

/// 本次实际生效的配置来源（--status 会打印，方便一眼确认有没有读到 App 的设置）
static NSString *gCfgSource = @"未读取";

/// 从字典解析配置（key 与 App 端 @AppStorage 完全一致）
static BOOL s_parseCfg(NSDictionary *d, sd_config *out) {
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    id rawDy  = d[@"resignThreshold"];
    id rawEn  = d[@"autoResign"];
    if (!rawDy && !rawEn) return NO;   // 两个键一个都没有 = 不是我们的配置

    NSInteger dy = rawDy ? [rawDy integerValue] : kFallbackDays;
    if (dy < 1) dy = kFallbackDays;
    // v1.1.148：兜底 clamp 提前重签天数上限（防旧配置残留 7 或手改 plist 塞进更大值；
    // 7 天 = 免费账号 7 天有效期下永远在到期窗口内 → 每 24h 全量重签 → zsign 内存暴涨）
    if (dy > kMaxThresholdDays) dy = kMaxThresholdDays;

    out->days    = dy;
    out->enabled = rawEn ? [rawEn boolValue] : YES;
    id rawLow = d[@"forceResignLowPower"];
    out->forceResignLowPower = rawLow ? [rawLow boolValue] : NO;

    // v1.1.184：检测间隔（小时）。key 与 App 端 @AppStorage("resignCheckInterval") 一致。
    id rawIv = d[@"resignCheckInterval"];
    NSInteger iv = rawIv ? [rawIv integerValue] : kDefaultCheckIntervalHours;
    if (iv < 1) iv = kDefaultCheckIntervalHours;
    if (iv > kMaxCheckIntervalHours) iv = kMaxCheckIntervalHours;
    out->checkIntervalHours = iv;
    return YES;
}

/// 直接读 App（mobile 用户）的 UserDefaults —— 与原版 reprovisiond 同款做法
static NSDictionary *s_readAppPreferences(void) {
    CFStringRef appID = (__bridge CFStringRef)kAppBundleID;
    CFPreferencesAppSynchronize(appID);
    CFArrayRef keys = CFPreferencesCopyKeyList(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    if (!keys) return nil;
    CFDictionaryRef dict = CFPreferencesCopyMultiple(keys, appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    CFRelease(keys);
    if (!dict) return nil;
    NSDictionary *result = (__bridge_transfer NSDictionary *)dict;
    return result.count ? result : nil;
}

/// 兜底：直接翻 App 的偏好 plist（RootHide 下 cfprefsd 有时跨 namespace 读不到）
static NSDictionary *s_readContainerPreferences(void) {
    NSString *plistName = [kAppBundleID stringByAppendingPathExtension:@"plist"];

    NSString *direct = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:plistName];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:direct];
    if (d.count) return d;

    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray *subs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    for (NSString *sub in subs) {
        NSString *p = [NSString stringWithFormat:@"%@/%@/Library/Preferences/%@", root, sub, plistName];
        NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:p];
        if (c.count) return c;
    }
    return nil;
}

static sd_config s_cfg(void) {
    sd_config cfg = (sd_config){YES, kFallbackDays, NO, kDefaultCheckIntervalHours};
    NSString *source = nil;

    if (s_parseCfg(s_readAppPreferences(), &cfg)) {
        source = @"App 设置(CFPreferences)";
    } else if (s_parseCfg([NSDictionary dictionaryWithContentsOfFile:kConfigPath], &cfg)) {
        source = @"共享 plist";
    } else if (s_parseCfg(s_readContainerPreferences(), &cfg)) {
        source = @"App 容器偏好文件";
    }

    // 只在配置值或来源发生变化时才写日志，避免像旧版那样每秒刷屏
    static NSInteger lastDays = -1;
    static int lastEn = -1;
    static NSString *lastSource = nil;
    NSString *srcName = source ?: @"内置默认值";
    gCfgSource = srcName;   // 供 --status 显示，让用户一眼看出读的是不是 App 里的设置

    if (lastDays != cfg.days ||
        lastEn != (int)cfg.enabled || ![lastSource isEqualToString:srcName]) {
        lastDays = cfg.days;
        lastEn = (int)cfg.enabled; lastSource = srcName;

        if (source) {
            s_log(@"读取配置[来源: %@]: 提前重签=%ld天 自动续签=%@ 检测间隔=%ld小时",
                  srcName, (long)cfg.days, cfg.enabled ? @"开" : @"关",
                  (long)cfg.checkIntervalHours);
        } else {
            s_log(@"⚠️ 两个来源都没读到配置，退回默认值: 提前重签=%ld天",
                  (long)kFallbackDays);
            s_log(@"   来源1 CFPreferences(%@, user=mobile) / 来源2 %@ / 来源3 App 容器偏好",
                  kAppBundleID, kConfigPath);
        }
    }
    return cfg;
}

// ─── 免费账号「3 个自签应用」限制绕过 ────────────────────────────
//

/// 读设置开关 bypassFreeAppLimit（三级来源回退，默认关闭）
static BOOL s_bypassEnabled(void) {
    NSArray *sources = @[
        s_readAppPreferences() ?: @{},
        [NSDictionary dictionaryWithContentsOfFile:kConfigPath] ?: @{},
        s_readContainerPreferences() ?: @{},
    ];
    for (NSDictionary *d in sources) {
        id v = d[@"bypassFreeAppLimit"];
        if (v) return [v boolValue];
    }
    return NO;
}

/// 递归收集一个 App 容器里所有「会被 installd 打免费计数 xattr」的 bundle：
/// 主 .app 以及它内部的扩展 .appex（扩展还可能嵌套在 PlugIns 下，逐层向下找）。
/// 这是 v1.1.105 修复「带多个扩展的 App 没正确绕过」的关键——每个 .appex 也是独立计数 bundle。
static void s_enumerateSignedBundles(NSString *root, void (^cb)(NSString *bundlePath)) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        NSString *full = [root stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (!isDir) continue;
        if ([entry.pathExtension isEqualToString:@"app"] ||
            [entry.pathExtension isEqualToString:@"appex"]) {
            cb(full);
        }
        s_enumerateSignedBundles(full, cb); // 继续向下找嵌套扩展
    }
}

/// 扫描所有已安装 App（含扩展），删除免费账号计数用的 xattr。返回实际清除的个数。
static NSInteger s_bypass3AppLimit(NSString *reason) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *uuids = [fm contentsOfDirectoryAtPath:kBundleRoot error:nil];
    if (uuids.count == 0) {
        s_log(@"3应用绕过[%@]: %@ 为空或不可读，跳过", reason, kBundleRoot);
        return 0;
    }

    __block NSInteger scanned = 0, cleared = 0, failed = 0;
    __block NSMutableArray<NSString *> *names = [NSMutableArray array];

    for (NSString *uuid in uuids) {
        @autoreleasepool {
            NSString *container = [kBundleRoot stringByAppendingPathComponent:uuid];
            s_enumerateSignedBundles(container, ^(NSString *bp) {
                const char *cpath = bp.fileSystemRepresentation;
                scanned++;

                // 没有该 xattr = App Store 应用 或 已经绕过过了 → 不动
                if (getxattr(cpath, kFreeProfileXattr, NULL, 0, 0, 0) < 0) return;

                if (removexattr(cpath, kFreeProfileXattr, 0) == 0) {
                    cleared++;
                    [names addObject:bp.lastPathComponent];
                } else {
                    failed++;
                    s_log(@"3应用绕过: 清除「%@」的 xattr 失败 errno=%d(%s)",
                          bp.lastPathComponent, errno, strerror(errno));
                }
            });
        }
    }

    if (cleared > 0) {
        s_log(@"3应用绕过[%@]: 扫描 %ld 个 bundle（含扩展），已解除 %ld 个 → %@",
              reason, (long)scanned, (long)cleared, [names componentsJoinedByString:@", "]);
    } else if (failed > 0) {
        s_log(@"3应用绕过[%@]: 扫描 %ld 个 bundle，%ld 个清除失败",
              reason, (long)scanned, (long)failed);
    } else {
        s_log(@"3应用绕过[%@]: 扫描 %ld 个 bundle，没有需要处理的（均已解除或非免费签名）",
              reason, (long)scanned);
    }
    return cleared;
}

/// 带开关判断的入口：设置里没开就直接返回
static void s_bypass3AppLimitIfEnabled(NSString *reason) {
    if (!s_bypassEnabled()) {
        s_log(@"3应用绕过[%@]: 设置未开启，跳过", reason);
        return;
    }
    s_bypass3AppLimit(reason);
}

// 前向声明
static void s_requestBypass(NSString *reason);

// ─── 唤醒 App 到后台执行静默续签（含保活 + 系统唤醒） ────────

static int32_t gAppPID = 0;
static void    *gBKSAssertion = NULL;
/// BKS 回调 block 的全局强引用（block 是异步回调，必须活到回调发生）
static void (^gBKSHandler)(BOOL) = nil;

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

/// SpringBoardServices 句柄（只 dlopen 一次，绝不 dlclose：
/// 私有框架里注册了 ObjC 类，反复 open/close 既慢又危险）
static void *s_sbsHandle(void) {
    static void *h = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        if (!h) s_log(@"无法加载 SpringBoardServices: %s", dlerror());
    });
    return h;
}

/// BackBoardServices 句柄（同上）
static void *s_bksHandle(void) {
    static void *h = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const char *paths[] = {
            "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
            "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
            NULL
        };
        for (int i = 0; paths[i]; i++) {
            h = dlopen(paths[i], RTLD_NOW);
            if (h) break;
        }
        if (!h) s_log(@"无法加载 BackBoardServices/BoardServices: %s", dlerror());
    });
    return h;
}

/// 取 BackBoardServices 导出的 NSString 常量（dlsym 拿到的是「指针的地址」，要再解一层）
static NSString *s_bksString(const char *symbol, NSString *fallback) {
    void *h = s_bksHandle();
    if (h) {
        NSString * __unsafe_unretained *p = (NSString * __unsafe_unretained *)dlsym(h, symbol);
        if (p && *p) return *p;
    }
    return fallback;
}

/// 获取 App 的 PID（单次查询）
///
/// ⚠️ v1.1.64 关键修复：SBSProcessIDForDisplayIdentifier 的真实原型是
///       BOOL SBSProcessIDForDisplayIdentifier(CFStringRef identifier, pid_t *pid);
///    pid 是**出参**，函数的返回值只是个 BOOL。旧版把返回值当 PID 用，
///    拿到的永远是 0 或 1 这种垃圾值 → 永远判定「无法获取 App PID」→ BKS 保活永远跳过。
///    这正是日志里每次触发都出现那行的直接原因。
static pid_t s_getAppPID(NSString *bundleID) {
    void *sbs = s_sbsHandle();
    if (!sbs) return 0;

    static BOOL (*fn)(CFStringRef, pid_t *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (BOOL (*)(CFStringRef, pid_t *))dlsym(sbs, "SBSProcessIDForDisplayIdentifier");
        if (!fn) s_log(@"无法找到 SBSProcessIDForDisplayIdentifier: %s", dlerror());
    });
    if (!fn) return 0;

    pid_t pid = 0;
    fn((__bridge CFStringRef)bundleID, &pid);
    return pid;
}

/// 获取 BKSProcessAssertion 防止 App 被系统挂起
///
/// ⚠️ v1.1.64 修复了 5 处误用（全部对照 ReProvision 原版 reprovisiond）：
///   1. flags 旧版写死 0x3，实为 PreventSuspend|PreventThrottleDownCPU（语义错误，
///      普通进程申请「禁止降频」会被 assertiond 判为滥用）。
///      正确值 = PreventSuspend(1<<0) | AllowIdleSleep(1<<2) = 5
///   2. reason 旧版传了个 NSString，真实类型是枚举 BKSProcessAssertionReason，
///      后台收尾任务应为 BKSProcessAssertionReasonFinishTask = 4
///   3. selector 旧版用带下划线的 _initWithPID:...，公开实例方法没有下划线
///   4. 旧版先 [[cls alloc] init] 再 invoke 一次 init → 双重初始化
///   5. handler 旧版标 __unsafe_unretained，是栈上 block，异步回调时早已失效（野指针）
static void *s_acquireBKSAssertion(pid_t targetPid) {
    if (!s_bksHandle()) return NULL;

    Class bksClass = NSClassFromString(@"BKSProcessAssertion");
    if (!bksClass) {
        s_log(@"无法获取 BKSProcessAssertion 类");
        return NULL;
    }

    SEL sel = NSSelectorFromString(@"initWithPID:flags:reason:name:withHandler:");
    if (![bksClass instancesRespondToSelector:sel]) {
        sel = NSSelectorFromString(@"_initWithPID:flags:reason:name:withHandler:");  // 老系统兜底
        if (![bksClass instancesRespondToSelector:sel]) {
            s_log(@"BKSProcessAssertion 不响应 initWithPID:flags:reason:name:withHandler:");
            return NULL;
        }
    }

    NSMethodSignature *sig = [bksClass instanceMethodSignatureForSelector:sel];
    if (!sig) { s_log(@"无法取得 BKSProcessAssertion 方法签名"); return NULL; }

    // 用 64 位变量承载，NSInvocation 会按方法签名声明的实际宽度截取低位，
    // 无论真实类型是 unsigned int 还是 NSUInteger 都不会读到未初始化内存。
    int64_t  pidVal    = targetPid;
    uint64_t flagsVal  = (1 << 0) | (1 << 2);   // PreventSuspend | AllowIdleSleep = 5
    uint64_t reasonVal = 4;                     // BKSProcessAssertionReasonFinishTask
    NSString *nameStr  = kAppBundleID;

    // 用全局强引用持有回调，避免 block 在异步回调到来之前被 ARC 回收
    gBKSHandler = [^(BOOL success) {
        s_log(@"BKSProcessAssertion 回调: %@ (pid=%d)",
              success ? @"已生效" : @"被系统拒绝（检查 multitasking.unlimitedassertions 权限）",
              targetPid);
    } copy];
    void (^handler)(BOOL) = gBKSHandler;

    id assertion = [bksClass alloc];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:sel];
    [inv setTarget:assertion];
    [inv setArgument:&pidVal    atIndex:2];
    [inv setArgument:&flagsVal  atIndex:3];
    [inv setArgument:&reasonVal atIndex:4];
    [inv setArgument:&nameStr   atIndex:5];
    [inv setArgument:&handler   atIndex:6];
    [inv invoke];

    __unsafe_unretained id raw = nil;
    [inv getReturnValue:&raw];

    id result = raw ?: assertion;
    if (!result) {
        s_log(@"BKSProcessAssertion 初始化返回 nil");
        return NULL;
    }
    return (__bridge_retained void *)result;
}

/// 释放 BKSProcessAssertion
///
/// ⚠️ v1.1.64 修复：旧版 performSelector:@selector(release) —— ARC 下这既不合法
///    也不会真正撤销断言。BKSProcessAssertion 的正确撤销方式是 -invalidate，
///    对象本身交回 ARC 释放。旧版等于断言永远挂着不放，assertiond 侧会累积泄漏。
static void s_releaseBKSAssertion(void) {
    if (!gBKSAssertion) return;

    id assertion = (__bridge_transfer id)gBKSAssertion;   // 转回 ARC 管理
    gBKSAssertion = NULL;

    SEL invalidateSel = NSSelectorFromString(@"invalidate");
    if ([assertion respondsToSelector:invalidateSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [assertion performSelector:invalidateSel];
#pragma clang diagnostic pop
    }
    gBKSHandler = nil;
    gAppPID = 0;
    s_log(@"已释放 BKSProcessAssertion");
}

/// 同步版本：唤醒 App 并等待保活就绪（用于 --resign-now 和 SIGHUP 触发）
/// 与异步版 s_launchAppInBackground 的区别：此函数同步等待 BKS 获取完成
static BOOL s_launchAppAndWait(BOOL waitForCompletion) {
    void *handle = s_sbsHandle();
    if (!handle) return NO;

    // v1.1.67：每次触发都打印自身 entitlement + namespace 自检，
    // 这样无论 daemon 是否重启，下一次测试（SIGHUP / 定时器）都能拿到铁证，
    // 不再靠猜。定位 result=7 到底是「私有权限被剥离」还是「App 未注册」。
    s_report_self_entitlements();

    // ⚠️ v1.1.64 修复：真实原型是
    //     int SBSLaunchApplicationWithIdentifierAndLaunchOptions(
    //             CFStringRef identifier, CFDictionaryRef launchOptions, BOOL suspended);
    //   第三个参数是 BOOL suspended（原版传 1），旧版声明成 void** 并传 NULL(=0)，
    //   而且返回值 int 被丢掉了，出错也看不见。
    typedef int (*SBSLaunchFn)(CFStringRef, CFDictionaryRef, BOOL);
    static SBSLaunchFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (SBSLaunchFn)dlsym(handle, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
        if (!fn) s_log(@"无法找到 SBSLaunchApplicationWithIdentifierAndLaunchOptions: %s", dlerror());
    });
    if (!fn) return NO;

    // App 已经在跑就先把断言拿到手（原版同样的顺序）
    pid_t existingPid = s_getAppPID(kAppBundleID);
    if (existingPid > 0 && !gBKSAssertion) {
        gAppPID = existingPid;
        gBKSAssertion = s_acquireBKSAssertion(existingPid);
        s_log(@"[Step 0/3] App 已在运行 (pid=%d)，先申请保活断言", existingPid);
    }

    // ⚠️ v1.1.64 修复：launchOptions 的两个 key 旧版是自己编的
    //   （@"SBSBackgroundOnly" / @"SBSUnlockDevice" 根本不存在），
    //   backboardd 收到无法识别的字典就按「普通前台启动」处理甚至直接拒绝。
    //   正确写法是 BKSOpenApplicationOptionKeyActivateForEvent →
    //   { BKSActivateForEventOptionTypeBackgroundContentFetching : @"" }，
    //   这才是「以后台内容刷新事件唤醒」的标准姿势。
    NSString *keyActivateForEvent =
        s_bksString("BKSOpenApplicationOptionKeyActivateForEvent", @"__ActivateForEvent");
    NSString *typeBackgroundFetch =
        s_bksString("BKSActivateForEventOptionTypeBackgroundContentFetching",
                    @"__ActivateForEventOptionTypeBackgroundContentFetching");

    NSDictionary *options = @{ keyActivateForEvent : @{ typeBackgroundFetch : @"" } };

    int launchResult = fn((__bridge CFStringRef)kAppBundleID,
                          (__bridge CFDictionaryRef)options,
                          1 /* suspended */);

    if (launchResult == 0 || launchResult == 7) {
        if (launchResult == 0) {
            s_log(@"[Step 1/3] 后台唤醒请求已被 backboardd 接受 (result=0) — %@", kAppBundleID);
        } else {
            // result=7 是「后台内容刷新式唤醒」的常见返回值：backboardd 实际已把 App 拉起，
            // 只是前台激活式启动的返回值语义不同。属假阴性，已证实 App 确实会被拉起并完成续签
            // （见日志：18:35:45 result=7 之后 18:35:59 App 被拉起 pid=17570 且续签成功）。
            s_log(@"[Step 1/3] 后台唤醒已提交 (result=7，后台内容刷新式启动，App 实际会被拉起) — %@", kAppBundleID);
        }
    } else {
        s_log(@"[Step 1/3] ⚠️ 后台唤醒被拒绝 (result=%d)", launchResult);
        // 失败时立刻区分根因 —— App 是否已注册到 SpringBoard？
        pid_t regPid = 0;
        BOOL registered = s_isAppRegistered(kAppBundleID, &regPid);
        if (registered) {
            s_log(@"   App 已注册到 SpringBoard（pid=%d，未运行）。"
                  @"→ 根因是 daemon 的后台启动权限被拒：请检查上方『自身 entitlement 自检』的运行环境行；"
                  @"%@下若显示 jbroot namespace，说明 daemon 仍跑在 jbroot 路径下（postinst 未用 jbroot 命令转 rootfs）。",
                  regPid, s_flavor_name(s_jb_flavor()));
        } else {
            s_log(@"   ⚠️ App 未注册到 SpringBoard（SBSProcessID 返回 NO）。"
                  @"→ 根因是 uicache 注册问题，不是权限。请在 App 内或终端执行 uicache -p /Applications/ReSign.app 后重试。");
        }
    }

    // Step 2 的公共逻辑：拿 PID → 申请保活断言
    void (^acquireAssertion)(void) = ^{
        if (gBKSAssertion) { s_log(@"[Step 2/3] 已持有保活断言，跳过重复申请"); return; }
        pid_t appPID = s_getAppPIDWithRetry(kAppBundleID, 3);
        if (appPID > 0) {
            gAppPID = appPID;
            gBKSAssertion = s_acquireBKSAssertion(appPID);
            s_log(@"[Step 2/3] App 已在后台运行 (pid=%d)，保活断言%@",
                  appPID, gBKSAssertion ? @"已申请" : @"申请失败");
        } else {
            // 注意：在 RootHide 下 SBSProcessIDForDisplayIdentifier 常因 namespace 差异拿不到 PID，
            // 但 App 实际已被拉起并会自行完成后台续签（App 侧用 beginBackgroundTask 保活）。
            // 这里拿不到 PID 只意味着 daemon 无法持有 BKS 断言，不影响续签本身，勿误判为「App 没被拉起」。
            s_log(@"[Step 2/3] 重试3次仍拿不到 App PID（daemon 无法持有 BKS 断言；App 自行保活续签，非致命）");
        }
    };

    // v1.1.158：删除「预约下一次系统级唤醒」（IOPMSchedulePowerEvent）——
    // signingd 短命化后由 launchd StartCalendarInterval 每 5 分钟定时拉起，
    // 设备深睡错过调度会在唤醒后立即补执行，无需 IOPM 自定义唤醒。

    if (!waitForCompletion) {
        // 异步模式：定时器触发的正常流程，用 dispatch_after 不阻塞主循环
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ acquireAssertion(); });
        // result==7（后台内容刷新式启动）同样视为成功：App 实际已被拉起
        return (launchResult == 0 || launchResult == 7 || existingPid > 0);
    }

    // ── 同步模式：--resign-now / SIGHUP 触发，阻塞等待 ──
    sleep(2);                 // 给 App 一点启动时间
    acquireAssertion();

    s_log(@"[完成] 唤醒流程结束 — App 将在后台静默执行续签");
    // result==7（后台内容刷新式启动）同样视为成功：App 实际已被拉起
    return (launchResult == 0 || launchResult == 7 || gAppPID > 0);
}

/// 异步版本：用于定时器/解锁/亮屏触发（不阻塞主循环）
static BOOL s_launchAppInBackground(void) {
    return s_launchAppAndWait(NO);
}

// ─── 触发 ────────────────────────────────────────────────────────
// v1.1.155 起返回 BOOL：YES=已真正触发续签（调用方需等待 App 完成）；
// NO=本轮跳过（开关关闭/低电量/24h 冷却中），调用方应立即退出。

// ═══════════════════════════════════════════════════════════════════════
// 🔴 v2.1.0 自签名管线（原版 ReProvision 架构：daemon 自己签，不唤醒 App）
// ═══════════════════════════════════════════════════════════════════════
// 凭据由 App 登录时写入共享 IPC 目录 /var/mobile/Library/Resign/credentials.cache：
//   { username: "apple_id|DSID", password: gsToken, teamID: "TEAMID" }
// 证书/私钥在 provisioning.cache（EEProvisioning 内部走 RPVResources 读 Keychain+cache）。
// daemon 是 root 进程 + no-sandbox，能读这些 0600 文件（root 不受权限限制）。

static NSString *const kDaemonCredentialsCachePath = @"/var/mobile/Library/Resign/credentials.cache";

/// 读凭据缓存。identity = DSID（EEBackend 需要的 user identity）。
static BOOL s_readCredentials(NSString **identityOut, NSString **gsTokenOut, NSString **teamIDOut) {
    NSDictionary *cred = [NSDictionary dictionaryWithContentsOfFile:kDaemonCredentialsCachePath];
    if (cred.count == 0) {
        s_log(@"凭据缓存缺失/为空：%@（请先在 App 里登录 Apple ID）", kDaemonCredentialsCachePath);
        return NO;
    }
    NSString *username = cred[@"username"];
    NSString *gsToken  = cred[@"password"];
    NSString *teamID   = cred[@"teamID"];
    if (username.length == 0 || gsToken.length == 0 || teamID.length == 0) {
        s_log(@"凭据缓存不完整（username/gsToken/teamID 至少一项缺失），跳过本轮续签");
        return NO;
    }
    // username 格式 "apple_id|DSID"，DSID 是 Apple API 需要的 identity
    NSArray *parts = [username componentsSeparatedByString:@"|"];
    NSString *identity = parts.count >= 2 ? parts[1] : username;
    if (identityOut) *identityOut = identity;
    if (gsTokenOut)  *gsTokenOut  = gsToken;
    if (teamIDOut)   *teamIDOut   = teamID;
    s_log(@"凭据就绪：identity=%@ teamID=%@", identity, teamID);
    // 🔴 v2.1.5：记录 gsToken 缓存年龄，帮助判断是否因 token 过期导致签名失败
    {
        struct stat st;
        if (stat(kDaemonCredentialsCachePath.UTF8String, &st) == 0) {
            double ageHours = difftime(time(NULL), st.st_mtime) / 3600.0;
            s_log(@"  gsToken 缓存年龄：%.1f 小时（若 > 数小时 + 签名仍 No Team ID → 请在 App 重新登录）", ageHours);
        }
    }
    return YES;
}

/// 递归收集 root 下的所有 .app bundle 路径（深度上限 3：
/// 普通 app = Application/xxx/app.app；RootHide 越狱 app = Application/.jbroot-XXX/Applications/app.app）
/// 🔴 v2.1.15：跳过名为 tmp 的目录（jbroot/tmp、jbroot/var/tmp、系统 /tmp）——
/// 否则会把 daemon 自己的签名临时副本（…/tmp/repro-sign/xxx.app）也枚举进来，
/// 当成待续签 app 重复处理（真机 23:12 实锤：同一 Relaxin 被处理 2 次）。
static void s_collectAppBundles(NSString *dir, NSMutableArray<NSString *> *outPaths, int depth) {
    if (depth > 3) return;
    NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in entries ?: @[]) {
        if ([name isEqualToString:@"tmp"]) continue;   // v2.1.15：绝不进入临时目录
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) continue;
        if (isDir) {
            if ([name hasSuffix:@".app"]) {
                [outPaths addObject:path];
            } else {
                s_collectAppBundles(path, outPaths, depth + 1);
            }
        }
    }
}

/// 枚举「需要重签」的应用：embedded.mobileprovision 剩余有效期 **严格小于** 阈值天数。
/// 与 App 侧 RPVApplicationDatabase 的 NSOrderedAscending 判定口径一致（v1.1.184 实锤）。
static NSMutableArray<NSDictionary *> *s_enumerateExpiredApps(NSInteger thresholdDays) {
    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    NSMutableArray<NSString *> *bundles = [NSMutableArray array];
    s_collectAppBundles(kBundleRoot, bundles, 0);

    for (NSString *appPath in bundles) {
        NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSString *profilePath = [appPath stringByAppendingPathComponent:@"embedded.mobileprovision"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        NSString *bundleId = info[@"CFBundleIdentifier"];
        if (bundleId.length == 0) continue;
        if ([bundleId isEqualToString:kAppBundleID]) continue;   // 不签自己

        NSDictionary *profilePlist = RPVPSPlistAtPath(profilePath);
        NSDate *expiry = [profilePlist isKindOfClass:[NSDictionary class]] ? profilePlist[@"ExpirationDate"] : nil;
        if (![expiry isKindOfClass:[NSDate class]]) continue;    // 无 profile = 非自签应用，跳过

        NSTimeInterval remain = [expiry timeIntervalSinceNow];
        if (remain < thresholdDays * 24 * 3600) {                 // 严格小于
            [found addObject:@{
                @"path": appPath,
                @"bundleId": bundleId,
                @"expiry": expiry,
            }];
            s_log(@"  到期: %@ 剩余 %.1f 天（阈值 %ld 天）→ 需要重签",
                  bundleId, remain / 86400.0, (long)thresholdDays);
        }
    }
    return found;
}

/// 安装签名后的 app（daemon 独立完成，不唤醒 App）。
/// 🔴 v2.1.17 策略：优先 LSApplicationWorkspace（补全 InstallLocalProvisioned
/// entitlement 后应能装——App 进程同 API 同 options 能装，差异就是 allowedSPI
/// 数组缺 InstallLocalProvisioned，真机 23:12/23:46 实锤）；失败 fallback
/// MobileInstallationInstall（设备 jbroot 框架符号可能被 strip，dlsym 失败则跳过）。
static BOOL s_installSignedApp(NSString *appPath, NSString *bundleId) {
    // 方式 1：LSApplicationWorkspace（与 App 侧 RPVApplicationSigning 同 API/options）
    {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            id workspace = [wsClass performSelector:@selector(defaultWorkspace)];
            NSURL *appURL = [NSURL fileURLWithPath:appPath];
            NSDictionary *opts = @{
                @"CFBundleIdentifier": bundleId ?: @"",
                @"AllowInstallLocalProvisioned": @YES,
            };
            NSError *err = nil;
            BOOL ok = NO;
            @try {
                ok = [workspace installApplication:appURL withOptions:opts error:&err];
            } @catch (NSException *e) {
                s_log(@"安装异常(LSAW): %@", e.description ?: @"?");
            }
            if (ok) {
                s_log(@"安装成功: %@", bundleId);
                return YES;
            }
            s_log(@"安装失败(LSAW) %@: %@ (domain=%@ code=%ld userInfo=%@)",
                  bundleId, err.localizedDescription ?: @"?", err.domain ?: @"?",
                  (long)err.code, err.userInfo ?: @{});
            // 🔴 v2.1.21：免费账号 3 应用限制（MIInstallerErrorDomain code=13 /
            // "maximum number of installed apps"）→ 自动绕过（删除已装 app 的
            // com.apple.installd.validatedByFreeProfile xattr）→ 重试一次。
            // 真机（设备2，iOS16.3.1）09:20 实锤：第 4 个 app 安装失败 code=13。
            if (err.code == 13 ||
                [err.localizedDescription containsString:@"maximum number of installed apps"]) {
                s_log(@"检测到免费账号 3 应用限制 → 自动绕过（删 validatedByFreeProfile xattr）后重试");
                s_bypass3AppLimit(@"安装失败自动绕过");
                NSError *err2 = nil;
                BOOL ok2 = NO;
                @try {
                    ok2 = [workspace installApplication:appURL withOptions:opts error:&err2];
                } @catch (NSException *e) {
                    s_log(@"安装异常(重试): %@", e.description ?: @"?");
                }
                if (ok2) {
                    s_log(@"绕过后续签安装成功: %@", bundleId);
                    return YES;
                }
                s_log(@"绕过重试仍失败: %@ (domain=%@ code=%ld)",
                      err2.localizedDescription ?: @"?", err2.domain ?: @"?", (long)err2.code);
            }
        } else {
            s_log(@"安装: LSApplicationWorkspace 不可用 → 试 MobileInstallation");
        }
    }
    // 方式 2：MobileInstallationInstall（直连 installd；符号被 strip 则失败）
    void *mi = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW);
    if (!mi) { s_log(@"安装失败: MobileInstallation.framework 加载失败 (%s)", dlerror()); return NO; }
    void (*installFunc)(CFURLRef, CFDictionaryRef, void *, void *) =
        (void (*)(CFURLRef, CFDictionaryRef, void *, void *))dlsym(mi, "MobileInstallationInstall");
    if (!installFunc) { s_log(@"安装失败: MobileInstallationInstall 符号不存在（框架被 strip）"); return NO; }

    __block BOOL done = NO;
    __block BOOL ok = NO;
    __block NSString *errMsg = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    void (^completion)(NSDictionary *, NSError *) = [^(NSDictionary *result, NSError *error) {
        ok = (error == nil);
        if (error) {
            errMsg = error.localizedDescription ?: @"未知错误";
        } else if ([result isKindOfClass:[NSDictionary class]] && [result[@"errorString"] length] > 0) {
            ok = NO;
            errMsg = result[@"errorString"];
        }
        done = YES;
        dispatch_semaphore_signal(sema);
    } copy];
    NSDictionary *opts = @{
        @"CFBundleIdentifier": bundleId ?: @"",
        @"ApplicationType": @"User",
        @"AllowInstallLocalProvisioned": @YES,
    };
    installFunc((__bridge CFURLRef)[NSURL fileURLWithPath:appPath],
                (__bridge CFDictionaryRef)opts,
                (__bridge void *)completion, NULL);
    long rc = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
    if (rc != 0 || !done) {
        s_log(@"安装超时（120 秒）: %@", bundleId);
        return NO;
    }
    if (!ok) s_log(@"安装失败(MI) %@: %@", bundleId, errMsg ?: @"未知错误");
    else s_log(@"安装成功: %@", bundleId);
    return ok;
}

/// 单个应用：复制到临时目录 → EEBackend 签名 → 装 profile → 安装回。
static BOOL s_signAndInstallOneApp(NSString *appPath, NSString *identity,
                                   NSString *gsToken, NSString *teamID) {
    // 1. 复制 .app 到临时目录（EEBackend 就地签名）
    NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"repro-sign"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpRoot
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpApp = [tmpRoot stringByAppendingPathComponent:[appPath lastPathComponent]];
    [[NSFileManager defaultManager] removeItemAtPath:tmpApp error:nil];
    NSError *copyErr = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:appPath toPath:tmpApp error:&copyErr]) {
        s_log(@"复制 %@ 到临时目录失败: %@", appPath, copyErr.localizedDescription);
        return NO;
    }
    s_log(@"已复制 %@ → %@，开始签名", [appPath lastPathComponent], tmpApp);
    // 🔴 v2.1.8-diagnostic：确认临时 .app 里是否有 embedded.mobileprovision
    {
        NSString *mp = [tmpApp stringByAppendingPathComponent:@"embedded.mobileprovision"];
        unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:mp error:nil] fileSize];
        s_log(@"  临时 app 内 profile: %@（%@ 字节）", sz > 0 ? @"✅ 存在" : @"❌ 缺失", sz > 0 ? @(sz) : @"0");
    }

    // 2. EEBackend 签名（内部：EEProvisioning 四阶段 + RZSignRunner/zsign）。
    //    completion 是异步回调 → 用信号量同步等待（上限 5 分钟，防卡死）。
    __block NSError *signErr = nil;
    __block BOOL done = NO;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [EEBackend signBundleAtPath:tmpApp identity:identity gsToken:gsToken
              priorChosenTeamID:teamID withCompletionHandler:^(NSError *error) {
        signErr = error;
        done = YES;
        dispatch_semaphore_signal(sema);
    }];
    long waitRC = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * 60 * NSEC_PER_SEC));
    if (waitRC != 0 || !done) {
        // 🔴 v2.1.2：签名超时直接 _exit(0)（不留残留线程）。
        // 旧逻辑 return NO 后 EEBackend 的 completion block 仍可能在后台继续跑
        // （网络/Anisette XPC/ChOma 线程残留）→ 内存持续暴涨 → 整机 Jetsam
        // （真机 17:14 实锤 largestProcess=repro-signingd）。短命 daemon 自杀最干净。
        s_log(@"签名超时（5 分钟）: %@ → 立即退出本轮，launchd 下轮拉起", tmpApp);
        if (gLogFile) { fflush(gLogFile); fclose(gLogFile); gLogFile = NULL; }
        _exit(0);
    }
    if (signErr) {
        s_log(@"签名失败 %@: %@", [appPath lastPathComponent], signErr.localizedDescription);
        // 🔴 v2.1.7：若错误信息已含 Apple 返回的 resultCode（如 1100 "session expired"），
        // 不再加通用指引（用户直接看到了具体原因）；否则补上下文帮助。
        if ([signErr.localizedDescription containsString:@"resultCode"]) {
            // 已明确，无需补充
        } else if ([signErr.localizedDescription containsString:@"No Team ID"]) {
            s_log(@"  ↳ 可能是 Anisette 缓存缺失或过期。请打开 ReSign App（前台）一次刷新 anisette.cache");
        }
        return NO;
    }
    s_log(@"签名成功: %@", [appPath lastPathComponent]);

    // 3. 提取 embedded.mobileprovision → 写系统描述文件库 + 通知 profiled 重扫
    NSData *profileData = [NSData dataWithContentsOfFile:
                           [tmpApp stringByAppendingPathComponent:@"embedded.mobileprovision"]];
    if (profileData.length > 0) {
        NSString *stableName = RPVPSStableNameForData(profileData);
        NSString *written = RPVPSWriteProfileToDirs(profileData, stableName);
        s_log(@"描述文件已写入系统库: %@", written ?: stableName);
        RPVPSNudgeProfiled();
    } else {
        s_log(@"⚠️ 签名后 bundle 里没有 embedded.mobileprovision（异常）");
    }

    // 4. 读签名后的 bundle id（libProvision 会加 TeamID 前缀，installd 按它匹配）
    NSDictionary *signedInfo = [NSDictionary dictionaryWithContentsOfFile:
                                [tmpApp stringByAppendingPathComponent:@"Info.plist"]];
    NSString *signedBundleId = signedInfo[@"CFBundleIdentifier"] ?: @"";
    if (signedBundleId.length == 0) {
        s_log(@"签名后 Info.plist 读不到 CFBundleIdentifier");
        return NO;
    }

    // 5. LSApplicationWorkspace 安装回
    return s_installSignedApp(tmpApp, signedBundleId);
}

/// 🔴 v2.1.18：签名前确保 Anisette 缓存新鲜。
/// RootHide 下 daemon 无法自生成 Anisette（anisette XPC 不放行，23:43 实测
/// "daemon 自生成缺 X-Apple-I-MD"），新鲜 Anisette 只能 App 进程生成（AuthKit
/// 上下文）。App 生成的 anisette.cache 时效约 15-20 分钟（真机 23:12 成功 /
/// 23:29 失败实锤），daemon 每小时跑必用旧缓存 → resultCode=1100 失败。
/// 方案：签名前检查缓存年龄，过期则写 anisette-refresh-request 标记 +
/// 唤醒 App 后台 → App setupCommon 读到标记只做「刷新 Anisette 缓存」然后
/// exit(0)（不参与签名/安装）→ daemon 轮询缓存 mtime 变新后用新缓存签名。
static void s_ensureFreshAnisette(void) {
    NSString *cachePath = @"/var/mobile/Library/Resign/anisette.cache";
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:cachePath error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (mtime) {
        NSTimeInterval age = -[mtime timeIntervalSinceNow];
        if (age < 10 * 60) {
            s_log(@"Anisette 缓存年龄 %.1f 分钟 → 新鲜，无需刷新", age / 60.0);
            return;
        }
        s_log(@"Anisette 缓存年龄 %.1f 分钟 → 过期，唤醒 App 刷新", age / 60.0);
    } else {
        s_log(@"Anisette 缓存缺失 → 唤醒 App 生成");
    }

    // 写刷新请求标记 + 唤醒 App（后台启动，App 刷新后自动退出）
    [@{@"timestamp": @([[NSDate date] timeIntervalSince1970])}
        writeToFile:@"/var/mobile/Library/Resign/anisette-refresh-request" atomically:YES];
    if (!s_launchAppInBackground()) {
        s_log(@"⚠️ 唤醒 App 刷新 Anisette 失败（SBS 拉起失败）→ 用旧缓存继续，可能 1100");
        return;
    }
    // 轮询缓存 mtime 变新（上限 60 秒，App 刷新通常 2-3 秒）
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        NSDictionary *a2 = [[NSFileManager defaultManager] attributesOfItemAtPath:cachePath error:nil];
        NSDate *m2 = a2[NSFileModificationDate];
        if (m2 && (!mtime || [m2 compare:mtime] == NSOrderedDescending)) {
            s_log(@"✅ Anisette 缓存已由 App 刷新（%s）", m2.description.UTF8String);
            return;
        }
        usleep(2000000);  // 2s
    }
    s_log(@"⚠️ 等待 App 刷新 Anisette 超时（60s）→ 用旧缓存继续，可能 1100");
}

/// v2.1.0：daemon 自签名主流程。返回 YES 表示执行了（无论成败），NO 表示本轮跳过。
static BOOL s_selfSignPipeline(sd_config c) {
    // 1. 凭据
    NSString *identity = nil, *gsToken = nil, *teamID = nil;
    if (!s_readCredentials(&identity, &gsToken, &teamID)) {
        s_log(@"续签中止：无可用凭据（请在 App 里重新登录）");
        return NO;
    }

    // 🔴 v2.1.18：签名前确保 Anisette 新鲜（过期则唤醒 App 后台刷新，用户无感）
    s_ensureFreshAnisette();

    // 2. 枚举到期应用
    NSArray *expired = s_enumerateExpiredApps(c.days);
    if (expired.count == 0) {
        s_log(@"续签检查完成：所有应用剩余有效期充足，无需重签（阈值 %ld 天）", (long)c.days);
        return NO;
    }
    s_log(@"共 %lu 个应用需要重签", (unsigned long)expired.count);

    // 3. 逐个签名 + 安装
    NSInteger okCount = 0, failCount = 0;
    for (NSDictionary *app in expired) {
        BOOL ok = s_signAndInstallOneApp(app[@"path"], identity, gsToken, teamID);
        if (ok) okCount++; else failCount++;
        s_log(@"  [%@] %@", ok ? @"✅" : @"❌", app[@"bundleId"]);
    }
    s_log(@"续签完成：成功 %ld 个，失败 %ld 个", (long)okCount, (long)failCount);
    return YES;
}

static BOOL s_fire(void) {
    sd_config c = s_cfg();
    if (!c.enabled) { s_log(@"自动续签已关闭，跳过"); return NO; }

    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled] && !c.forceResignLowPower) {
        s_log(@"低电量模式，跳过续签");
        return NO;
    }

    // 🔴 v1.1.184：24 小时冷却已删除（用户要求）。改由「检测间隔」节流：
    // launchd 每小时拉起本进程一次，但只有距上一次真正检测 ≥ 用户设定的间隔
    // （1~12 小时，设置页可调）才干活，否则本轮直接退出。
    // 与旧冷却的本质区别：
    //   旧冷却基准 = 上次「续签完成」时间 → 刚续签完就被锁死 24 小时，用户无法调节；
    //   新间隔基准 = 上次「检测」时间     → 用户自己决定多久看一次，不再有隐藏锁。
    // 至于「会不会又变成频繁全量重签」——不会：命中续签窗口的前提是剩余有效期
    // **严格小于** 提前重签天数（上限 6 天 < 免费 profile 的 7 天），刚签完的应用
    // 剩余 7 天不在窗口内，自然要等约一天才可能再次命中。
    time_t nowCheck = time(NULL);
    {
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:kCheckStatePath];
        double lastCheck = st ? [st[@"lastCheckTime"] doubleValue] : 0;
        NSTimeInterval interval = (NSTimeInterval)c.checkIntervalHours * 3600.0;
        if (lastCheck > 0 && (nowCheck - (time_t)lastCheck) < interval) {
            // 🔴 v1.1.186：跳过日志补上「下次检测时间」，用户一眼能看到检查何时到期
            time_t nextCheck = (time_t)lastCheck + (time_t)interval;
            struct tm tm; localtime_r(&nextCheck, &tm);
            char buf[32]; strftime(buf, sizeof(buf), "%m-%d %H:%M", &tm);
            s_log(@"距上次检测 %.1f 小时 < 设定间隔 %ld 小时，本轮跳过（下次检测约 %s）",
                  (nowCheck - (time_t)lastCheck) / 3600.0, (long)c.checkIntervalHours, buf);
            return NO;
        }
        [@{ @"lastCheckTime": @(nowCheck) } writeToFile:kCheckStatePath atomically:YES];
        chown(kCheckStatePath.UTF8String, 501, 501);
    }

    // 记录续签开始
    gResignStartTime = time(NULL);
    gResignInProgress = YES;
    gResignTotalCount++;
    s_log(@"═══ 续签开始 #%ld（daemon 自签名，不唤醒 App）═══", (long)gResignTotalCount);

    // 🔴 v2.1.0：daemon 自己执行签名管线。
    // 旧逻辑：写 trigger 文件 → SBSLaunch 唤醒 App → notify → 等 App 完成回调。
    // 新逻辑：读凭据缓存 → 枚举到期应用 → EEBackend 签名 → 装 profile → 安装回。
    // 不再依赖 App 进程存在（用户划掉 App 也不影响），不存在「等 notify 卡死」。
    BOOL executed = s_selfSignPipeline(c);

    // 写状态文件供 --status / App 状态页读取（与 s_onSigningComplete 同字段）
    double elapsed = difftime(time(NULL), gResignStartTime);
    NSDictionary *result = @{
        @"lastResignTime":    @(time(NULL)),
        @"lastResignElapsed": @(elapsed),
        @"totalCount":        @(gResignTotalCount),
        @"successCount":      @(executed ? 1 : 0),
        @"status":            executed ? @"已检查" : @"跳过",
    };
    [result writeToFile:kResultPath atomically:YES];
    chown(kResultPath.UTF8String, 501, 501);

    gResignInProgress = NO;
    return executed;
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
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled] && !c.forceResignLowPower) {
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
    s_log(@"═══ %@ 触发续签 #%ld（daemon 自签名）═══", reason, (long)gResignTotalCount);

    // 🔴 v2.1.0：手动触发同样走 daemon 自签名管线（不再唤醒 App）
    s_selfSignPipeline(c);

    // 🔴 v2.1.19：手动触发也更新「检测时间」（check-state 的 lastCheckTime）。
    // 否则 check-state 停在旧值，App「下次检测」按旧 lastCheckTime + 间隔计算
    // 会显示「即将检测」（真机 00:13 实锤：23:57 手动签成功，check-state 还是
    // 23:11 的值 → App 显示下次检测 00:11 已过 =「即将检测」）。
    // 与自动路径 s_fire 的节流写入保持一致（自动/手动都算一次检测）。
    [@{ @"lastCheckTime": @(time(NULL)) } writeToFile:kCheckStatePath atomically:YES];
    chown(kCheckStatePath.UTF8String, 501, 501);

    s_log(@"[%@] 自签名流程结束 — 结果见上方日志", reason);
}

static void s_gracefulExit(int sig) {
    s_log(@"收到信号 %d → 释放资源并退出", sig);
    // 🔴 v2.1.2：不再调 s_releaseBKSAssertion()。
    // 它走 BKS XPC（performSelector invalidate），RootHide 下 XPC 不可达会
    // 永久阻塞 → _exit 永远执行不到 → 进程残留占住 job、内存继续涨
    // （真机 17:03 卡死实例实锤：打印"退出"后进程仍存活到 17:14 Jetsam）。
    // 短命 daemon 不需要优雅清理，OS 会自动回收一切，直接 _exit 最稳。
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
        // 🔴 v1.1.191：按用户要求回退 v1.1.190 的改动——skipped（无需重签）**不**视为成功。
        // 语义口径：skipped = 剩余有效期没到「提前重签窗口」（严格小于）的正常跳过，
        // 本轮**没有执行续签**，标「成功」会误导用户以为真的续签了；
        // 「失败 + 详情=无需重签」虽然字面刺眼，但详情把原因说清楚了，用户认可这个口径。
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

    // 续签重装完成 → 解除免费账号 3 应用限制（installd 会在安装时重新打上 xattr）。
    // 通过合并计时器，2 秒后执行一次（让 installd 收尾，避免刚删又被写回）。
    s_requestBypass(@"续签完成");

    // 🔴 v1.1.155 短命模式：收到 App 完成回报 → 本轮拉起使命结束，立即退出。
    // （launchd StartCalendarInterval 会定时再拉起；不再 KeepAlive 常驻 →
    //  绕开 iOS 17 "inefficient" SIGKILL 杀循环 + RootHide 拦截器常驻泄漏。）
    if (gLogFile) { fflush(gLogFile); fclose(gLogFile); gLogFile = NULL; }
    _exit(0);
}

// ─── 3 应用绕过：合并计时器 ────────────────────────────────────
// 批量签名时每个 app / 每次流水线结束都会请求一次，这里合并为
// 「最后一次请求后 2 秒」只真正执行一次，避免反复扫描 installd 目录。
static dispatch_source_t s_bypassTimer = NULL;
static NSString *s_bypassReason = nil;

static void s_requestBypass(NSString *reason) {
    s_bypassReason = reason ?: @"合并请求";
    if (!s_bypassTimer) {
        s_bypassTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               dispatch_get_main_queue());
        dispatch_source_set_event_handler(s_bypassTimer, ^{
            dispatch_source_cancel(s_bypassTimer);
            s_bypassTimer = NULL;
            s_bypass3AppLimitIfEnabled(s_bypassReason);
        });
        dispatch_resume(s_bypassTimer);
    }
    // 以最后一次请求为准，2 秒后触发
    dispatch_source_set_timer(s_bypassTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
}

// ─── --status 诊断输出 ──────────────────────────────────────────
// 让用户能一眼判断「到底有没有真的续签」，不用去猜日志。

static int s_printStatus(void) {
    printf("═══════════ ReSign 续签守护进程状态 ═══════════\n");

    // 0. 自身 entitlement + namespace 自检（最关键的权限证据）
    s_report_self_entitlements();
    printf("\n");

    // 1. daemon 状态（v1.1.159 适配短命模式：进程由 launchd 每 5 分钟拉起、做完即退，
    //    时有时无属正常，不能再用「进程此刻是否存活」判断健康）
    NSString *pidStr = [NSString stringWithContentsOfFile:kPidPath
                                                 encoding:NSUTF8StringEncoding error:nil];
    pid_t dpid = pidStr ? (pid_t)[pidStr integerValue] : 0;
    if (dpid > 0 && kill(dpid, 0) == 0) {
        printf("daemon 状态      : ✅ 本轮进程运行中 (pid=%d)\n", dpid);
    } else {
        printf("daemon 状态      : ⏸ 本轮进程未运行（非持久化定时检查正常——launchd 每小时拉起一轮）\n");
        printf("                   判断健康请用下方「最近一次续签完成」；手动拉起: launchctl kickstart -k system/cn.analy.resign.signingd\n");
    }

    // 2. 当前配置
    sd_config c = s_cfg();
    printf("配置来源         : %s\n", gCfgSource.UTF8String);
    printf("自动续签开关     : %s\n", c.enabled ? "开" : "关");
    printf("提前重签阈值     : %ld 天     ← 应与 App「设置」页一致\n", (long)c.days);
    printf("检测间隔         : %ld 小时   ← v1.1.184 起可在设置页调整（上限 12 小时）\n",
           (long)c.checkIntervalHours);
    {
        NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:kCheckStatePath];
        double lastCheck = st ? [st[@"lastCheckTime"] doubleValue] : 0;
        if (lastCheck > 0) {
            printf("上次检测         : %.1f 小时前\n",
                   (time(NULL) - (time_t)lastCheck) / 3600.0);
        } else {
            printf("上次检测         : 无记录\n");
        }
    }

    // 2b. 免费账号 3 应用限制绕过
    {
        BOOL on = s_bypassEnabled();
        printf("3应用绕过开关    : %s\n", on ? "开" : "关");

        NSFileManager *fm = [NSFileManager defaultManager];
        __block NSInteger total = 0, marked = 0;
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:kBundleRoot error:nil]) {
            NSString *container = [kBundleRoot stringByAppendingPathComponent:uuid];
            s_enumerateSignedBundles(container, ^(NSString *p) {
                total++;
                if (getxattr(p.fileSystemRepresentation, kFreeProfileXattr, NULL, 0, 0, 0) >= 0) marked++;
            });
        }
        printf("免费签名计数     : %ld / %ld 个 bundle 仍带计数标记%s\n",
               (long)marked, (long)total,
               marked > 0 ? "（≥3 个会触发限制，可 --bypass-3app 手动解除）" : "");
    }

    // 3. 下次触发（v1.1.155 短命模式：launchd StartCalendarInterval 每 5 分钟拉起一次）
    printf("下次触发         : launchd 每小时拉起一次；是否干活由设置里的「检测间隔」决定\n");

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

#pragma mark - v2.1.26 联网修复（fix-cellular）代跑

/// 推算自身所在的越狱根（与 main 里 TMPDIR 那段同一套判据）。
/// rootless=/var/jb，rootful=/，RootHide=随机 jbroot（本功能不走 RootHide，见下）。
static NSString *s_selfJbRoot(void) {
    char buf[PATH_MAX] = {0};
    uint32_t size = (uint32_t)sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) {
        char resolved[PATH_MAX] = {0};
        const char *use = realpath(buf, resolved) ? resolved : buf;
        NSString *selfPath = [NSString stringWithUTF8String:use];
        // .../usr/libexec/repro-signingd → 去掉 repro-signingd/libexec/usr 三级
        NSString *r = selfPath.stringByDeletingLastPathComponent
                             .stringByDeletingLastPathComponent
                             .stringByDeletingLastPathComponent;
        if (r.length > 0) return r;
    }
    return (s_jb_flavor() == RPVJbFlavorRootless) ? @"/var/jb" : @"/";
}

/// 找到与自己同一个越狱根下的 repro-helper。
static NSString *s_resolveHelperPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSString *root = s_selfJbRoot();
    if (root.length > 0) {
        [cands addObject:[root stringByAppendingPathComponent:@"usr/libexec/repro-helper"]];
    }
    [cands addObjectsFromArray:@[ @"/var/jb/usr/libexec/repro-helper",
                                  @"/usr/libexec/repro-helper" ]];
    for (NSString *p in cands) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

/// 同步跑一次 `repro-helper fix-cellular <bundleID>`，返回它的真实退出码。
/// 本 daemon 是 launchd 系统守护（uid 0、无沙箱），子进程继承「无沙箱」上下文，
/// 与 SSH 里 root 手动执行完全等价（真机 iPhone XS/iOS18.0/Dopamine 实测 exit=0）。
/// spawn 本身失败返回 -errno，便于和退出码区分。
static int s_runFixCellularOnce(NSString *bundleID, NSString **outLog) {
    NSString *helper = s_resolveHelperPath();
    if (helper.length == 0) {
        s_log(@"联网修复: 找不到 repro-helper");
        if (outLog) *outLog = @"找不到 repro-helper";
        return -2;
    }

    NSString *logPath = [NSString stringWithFormat:@"%@/fix-cellular-helper.log", kIpcDir];

    const char *argv[] = { [helper fileSystemRepresentation],
                           "fix-cellular",
                           [(bundleID ?: kAppBundleID) UTF8String],
                           NULL };

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO,
                                     [logPath fileSystemRepresentation],
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fa, STDOUT_FILENO, STDERR_FILENO);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [helper fileSystemRepresentation], &fa, NULL,
                         (char *const *)argv, NULL);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0) {
        s_log(@"联网修复: posix_spawn 失败 errno=%d（%@）", rc, helper);
        if (outLog) *outLog = [NSString stringWithFormat:@"posix_spawn 失败 errno=%d", rc];
        return -rc;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

    NSString *out = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
    if (outLog) *outLog = out.length ? out : @"（helper 无输出）";

    s_log(@"联网修复: helper fix-cellular %@ exit=%d", bundleID ?: kAppBundleID, code);
    return code;
}

/// 消费一次 App 写来的 fix-cellular 请求；没有待处理请求返回 NO。
///
/// 铁律（沿用 profiledaemon 的经验）：
///   · 先原子 rename 成 .consumed 再干活 —— 防止 daemon 被拉起两次重复执行；
///   · 消费后**必回结果**（哪怕失败也写 result），否则 App 只能干等到超时。
static BOOL s_handleFixCellularRequest(NSString *reason) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kFixCellReqPath]) return NO;

    NSString *consumed = [kFixCellReqPath stringByAppendingPathExtension:@"consumed"];
    [fm removeItemAtPath:consumed error:nil];
    NSError *mvErr = nil;
    if (![fm moveItemAtPath:kFixCellReqPath toPath:consumed error:&mvErr]) {
        // 另一个实例抢先消费了，本轮什么都不做（正常竞态，不算错误）
        s_log(@"联网修复: 请求已被其它实例消费（%@）", mvErr.localizedDescription ?: @"-");
        return NO;
    }

    NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:consumed] ?: @{};
    [fm removeItemAtPath:consumed error:nil];

    NSString *reqId    = req[@"requestId"] ?: @"";
    NSString *bundleID = req[@"bundleID"]  ?: kAppBundleID;
    NSTimeInterval ts  = [req[@"timestamp"] doubleValue];
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - ts;

    s_log(@"════ 联网修复请求（来源=%@，requestId=%@，%.1f 秒前写入）════", reason, reqId, age);

    if (ts > 0 && age > kFixCellReqTTL) {
        s_log(@"联网修复: 请求已过期（%.0f 秒 > %.0f 秒上限）→ 丢弃", age, kFixCellReqTTL);
        NSDictionary *res = @{ @"requestId": reqId,
                               @"timestamp": @([[NSDate date] timeIntervalSince1970]),
                               @"ok": @NO,
                               @"exitCode": @(-100),
                               @"message": @"请求已过期（守护进程唤醒太慢），请重试" };
        [res writeToFile:kFixCellResPath atomically:YES];
        chown(kFixCellResPath.UTF8String, 501, 501);
        return YES;
    }

    NSString *helperOut = nil;
    int code = s_runFixCellularOnce(bundleID, &helperOut);
    // helper 的 fix-cellular：0 = 成功；2 = CoreTelephony 无策略条目/系统应用忽略，
    //   也按成功处理（见 RPVHelperFixCellularViaCTServer 注释）。其余非零码才是真失败。
    // ⚠️ 这条必须与 helper 的返回语义保持一致，否则会误报「修复失败」。
    BOOL ok = (code == 0 || code == 2);

    NSString *msg;
    if (ok)                 msg = @"已修复当前插件联网";
    else if (code == -2)    msg = @"未找到 repro-helper（root 助手）";
    else if (code < 0)      msg = [NSString stringWithFormat:@"守护进程无法启动助手（errno %d）", -code];
    else                    msg = [NSString stringWithFormat:@"修复失败（助手退出码 %d）", code];

    NSDictionary *res = @{ @"requestId": reqId,
                           @"timestamp": @([[NSDate date] timeIntervalSince1970]),
                           @"ok": @(ok),
                           @"exitCode": @(code),
                           @"message": msg,
                           @"helperOutput": (helperOut ?: @"") };
    [res writeToFile:kFixCellResPath atomically:YES];
    chown(kFixCellResPath.UTF8String, 501, 501);
    s_log(@"联网修复: 结果已写回 → %@（exit=%d）", msg, code);
    return YES;
}

// ─── main ────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    // 🔴 v2.1.13：TMPDIR 指向自身越狱根内的 <root>/var/tmp（jbroot 绝对路径）。
    // 真机 22:39/22:50 实验实锤：daemon 与 posix_spawn 的 zsign 子进程文件系统
    // 视图不一致——zsign 读 /var/mobile/Library/Resign/tmp/...（rootfs 里存在）
    // 和 /rootfs/... 都失败（读 /etc/hosts 成功、读 jbroot 绝对路径成功），
    // 说明 zsign 的 /var/ 是 overlay shadow，而 jbroot（/var/containers/Bundle/
    // Application/.jbroot-XXXX/...）是真实目录、任何进程都能访问。
    // 所以临时 app/profile/key/cert 全放 <jbroot>/var/tmp，daemon 与 zsign
    // 必然看到同一份文件。v2.1.12 的 /var/mobile/Library/Resign/tmp 方案
    // 被实验证伪（zsign 读不到，仍报 "Can't find provision file!"）。
    {
        NSString *root = nil;
        char buf[PATH_MAX] = {0};
        uint32_t size = (uint32_t)sizeof(buf);
        if (_NSGetExecutablePath(buf, &size) == 0) {
            char resolved[PATH_MAX] = {0};
            const char *use = realpath(buf, resolved) ? resolved : buf;
            NSString *selfPath = [NSString stringWithUTF8String:use];
            // .../usr/libexec/repro-signingd → 去掉 repro-signingd/libexec/usr 三级
            NSString *r = selfPath.stringByDeletingLastPathComponent
                                 .stringByDeletingLastPathComponent
                                 .stringByDeletingLastPathComponent;
            if ([r containsString:@".jbroot"] || [r hasPrefix:@"/var/jb"] || [r isEqualToString:@"/"]) {
                root = r;
            }
        }
        if (!root) {
            // 兜底：候选根里找 daemon 自身二进制
            for (NSString *cand in @[ @"/var/jb", @"/" ]) {
                NSString *p = [cand stringByAppendingPathComponent:@"usr/libexec/repro-signingd"];
                if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) { root = cand; break; }
            }
        }
        if (root.length > 0) {
            NSString *tmp = [root stringByAppendingPathComponent:@"var/tmp"];
            [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                                     withIntermediateDirectories:YES
                                                      attributes:@{NSFilePosixPermissions:@0777}
                                                           error:nil];
            setenv("TMPDIR", tmp.UTF8String, 1);
            unsetenv("TMP");  // 防止 fallback
            NSLog(@"[repro-signingd] TMPDIR → %@（自身根 %@）", tmp, root);
        } else {
            NSLog(@"[repro-signingd] ⚠️ 无法推算越狱根，TMPDIR 保持环境默认");
        }
    }
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

    // ── 🔴 v2.1.26 --fix-cellular [bundleID]: 终端手动跑一次联网修复（排查用） ──
    if (argc >= 2 && strcmp(argv[1], "--fix-cellular") == 0) {
        NSString *bid = (argc >= 3) ? [NSString stringWithUTF8String:argv[2]] : kAppBundleID;
        NSString *out = nil;
        int code = s_runFixCellularOnce(bid, &out);
        printf("fix-cellular %s → exit=%d\n%s\n", bid.UTF8String, code, (out ?: @"").UTF8String);
        if (gLogFile) { fflush(gLogFile); fclose(gLogFile); }
        return code;
    }

    // ── --bypass-3app: 手动解除免费账号 3 应用限制（无视设置开关，强制执行一次） ──
    if (argc >= 2 && strcmp(argv[1], "--bypass-3app") == 0) {
        s_log(@"========================================");
        s_log(@"收到 --bypass-3app（手动强制执行，忽略设置开关）");
        NSInteger n = s_bypass3AppLimit(@"手动命令");
        printf("已解除 %ld 个应用的免费签名计数标记\n", (long)n);
        s_log(@"========================================");
        if (gLogFile) { fflush(gLogFile); fclose(gLogFile); }
        return 0;
    }

    // ── 🔴 v2.1.26：优先处理 App 的「联网修复」请求 ──
    // 触发链：App 写 fix-cellular-request.plist → helper(setuid root) kickstart 本 daemon
    //        → launchd 以 root/无沙箱拉起我们 → 这里消费请求、代跑 helper、写回结果 → 退出。
    // 放在正常续签轮次之前：这是用户点按钮后在前台干等的操作，必须秒回；
    // 本轮跳过的续签检查由 launchd 下一次拉起补上（最多晚一小时，无影响）。
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
        if (s_handleFixCellularRequest(@"launchd 唤醒")) {
            s_log(@"联网修复处理完毕 → 本轮退出（续签检查由 launchd 下次拉起补上）");
            if (gLogFile) { fflush(gLogFile); fclose(gLogFile); }
            return 0;
        }
    }

    // ── 正常守护模式（v1.1.155 短命化） ──
    // 由 launchd StartCalendarInterval 每 5 分钟拉起一次（+ RunAtLoad 开机一次）。
    // 每次拉起：做一轮到期检查 → 需要续签则唤醒 App 并等待其完成 → 退出。
    // 进程不再常驻 → 绕开 iOS 17 launchd "inefficient" SIGKILL 杀循环，
    // 也让 RootHide XPC 拦截器的常驻泄漏彻底没有累积机会。
    s_log(@"========================================");
    s_log(@"=== 启动 pid=%d uid=%d（非持久化定时检查，本轮做完即退出）===", getpid(), getuid());
    s_log(@"管理命令:");
    s_log(@"  sudo /usr/libexec/repro-signingd --status      ← 查看是否真的续签了（推荐先看这个）");
    s_log(@"  sudo /usr/libexec/repro-signingd --resign-now  ← 手动触发续签（同步等待完成，推荐）");
    s_log(@"  sudo /usr/libexec/repro-signingd --bypass-3app ← 手动解除免费账号 3 应用限制");
    s_log(@"  sudo launchctl kickstart -k system/cn.analy.resign.signingd  ← 立即拉起一轮");
    s_log(@"========================================");
    s_setup_signal_handlers();

    // v1.1.150：崩溃循环检测（方案C）——10 分钟内反复被拉起 → 告警疑似 RootHide hook 问题
    s_checkCrashLoop();

    // v1.1.150/151：内存看门狗（方案A）——防等待 App 期间（最长 5 分钟）RootHide 拦截器泄漏
    s_startMemWatchdog();

    // v1.1.186：超时看门狗（方案D）——防主线程永久阻塞的僵尸实例占住 job、
    // 吞掉后续所有定时拉起（真机 pid 1468 卡死 3 小时实锤）。独立线程，不依赖主 runloop。
    s_startRunWatchdog();

    // v1.1.67：启动时自检自身 entitlement + namespace（每次触发也会再打印）
    s_report_self_entitlements();

    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    chown(kIpcDir.UTF8String, 501, 501);

    // 写 pid 文件，供 --status 判断 daemon 是否存活
    [[NSString stringWithFormat:@"%d", getpid()] writeToFile:kPidPath
                                                  atomically:YES
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    chown(kPidPath.UTF8String, 501, 501);

    sd_config c = s_cfg();
    s_log(@"配置: 自动=%@ 阈值=%ld天",
          c.enabled ? @"是" : @"否", (long)c.days);
    s_log(@"BundleID: %@ | 触发路径: %@", kAppBundleID, kTriggerPath);
    s_log(@"架构: Daemon(非持久化定时检查+唤醒+保活) → App(后台静默签名) → daemon 退出");
    s_log(@"      launchd 每小时重新拉起，用户无需手动打开 App");

    // 续签完成通知 → 更新统计 + 释放 BKS + 退出本轮
    int t2; notify_register_dispatch("cn.analy.resign.signing-complete", &t2,
        dispatch_get_main_queue(), ^(int _){
        s_onSigningComplete();
    });

    // ★ App 每完成一个应用的签名安装就发一次，daemon 立即解除 3 应用限制。
    //   前台手动签名 / IPA 导入安装 / 其它应用签名 / 后台续签 全部走这条通道。
    //   2 秒延迟让 installd 把 xattr 写完再删，避免竞态。
    int t3; notify_register_dispatch("cn.analy.resign.bypass-3app-request", &t3,
        dispatch_get_main_queue(), ^(int _){
        s_log(@"3应用绕过: 收到 App 的 bypass-3app-request 信号（合并后执行）");
        s_requestBypass(@"App 签名完成");
    });

    // 🔴 v2.1.26：本实例已经在跑（比如正等 App 完成续签）时，launchctl kickstart 不会
    // 再拉一个新实例 —— 那样请求文件就只能等下一次拉起才被消费。所以这里再挂一条
    // notify 通道：App 写完请求会同时 notify_post，活着的实例即时响应。
    // （notify 是纯 userland API，不依赖 launchd LaunchEvents；App→daemon 的
    //   signing-complete 早就在用同一套机制，已被真机验证可靠。）
    int t4; notify_register_dispatch("cn.analy.resign.fix-cellular-request", &t4,
        dispatch_get_main_queue(), ^(int _){
        (void)s_handleFixCellularRequest(@"notify 直达");
    });

    // ── 核心：立即执行一轮到期检查 ──
    // （不再需要常驻定时器/解锁/亮屏监听——launchd 每小时拉起天然覆盖，
    //   设备深睡错过调度会在唤醒后立即补执行。）
    BOOL fired = s_fire();
    if (!fired) {
        // 🔴 v1.1.187：文案修正——24h 冷却 v1.1.184 已删除，本轮跳过是「检测间隔未到」等
        s_log(@"本轮检查无需续签（检测间隔未到/开关关闭/低电量）→ 立即退出，下次由 launchd 拉起");
        s_gracefulExit(0);
        return 0;
    }

    // 🔴 v1.1.166：3 应用标记清理移到「真正触发续签」之后执行。
    // 旧版在 main 开头无条件 s_requestBypass(@"daemon 启动") —— daemon 每 5 分钟被
    // launchd 拉起一次，即使冷却跳过（不续签）也遍历全部 App 容器清 xattr：
    // /var/containers/Bundle/Application 是 data vault，递归遍历 + 每个 .app/.appex
    // 一次 getxattr/removexattr，在 RootHide 下每次系统调用都被 launchdhook 拦截 →
    // 持续 IO + XPC 拦截器活动累积 → 设备发热卡顿（用户实测「显示无需重签后手机慢慢
    // 变热卡顿，只能重启」）。冷却跳过的轮次没有新安装/新签名，无需清理；
    // 手动签名场景由 App 的 bypass-3app-request notify 即时覆盖，不依赖本轮启动清理。
    s_requestBypass(@"daemon 启动（本轮触发续签）");

    // 已触发续签：等待 App 完成（signing-complete notify）或 5 分钟超时，避免进程常驻。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * 60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        s_log(@"⚠️ 等待 App 完成超时(5 分钟) → 本轮退出，下次由 launchd 拉起（App 侧会自行兜底写入冷却时间）");
        s_gracefulExit(0);
    });
    s_log(@"已触发续签，等待 App 完成（最多 5 分钟，完成或超时即退出）");
    [[NSRunLoop mainRunLoop] run];
    return 0;
}
