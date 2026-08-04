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
//   11. v1.1.95 解除免费账号「同一设备最多 3 个自签应用」限制
//          （删除 .app 目录上的 com.apple.installd.validatedByFreeProfile 扩展属性，
//           参考 rooootdev/Lara；每次签名/续签完成后自动执行，需在 App 设置里开启）
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
#include <sys/xattr.h>
#include <sys/sysctl.h>
#include <errno.h>
#include <string.h>
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
// v1.1.129：App 续签因网络失败时写的修复请求文件（notify 丢失时文件轮询兜底）
static NSString *const kFixCellularReqPath = @"/var/mobile/Library/RePro/fix-cellular-request";
// ⚠️ v1.1.69 关键修复：此前此处写成 @"jp.soh.reprovision"，但 App 真实的
// CFBundleIdentifier（SpringBoard 注册 ID）= "com.reprovision.repro"（见 pbxproj
// PRODUCT_BUNDLE_IDENTIFIER 与 deb 内 Info.plist）。SBS 用 BundleID 查 App，
// 传错 ID → SBSProcessIDForDisplayIdentifier 返回 NO、SBSLaunch 返回 7（"App 未注册"），
// App 永远拉不起来 → 自动续签从未真正发生。现已改为正确的 BundleID。
// （kAppBundleID 也用于读 App 配置：App 把设置同步到共享 plist
//  /var/mobile/Library/RePro/signingd-config.plist，与 BundleID 无关，不受影响。）
static NSString *const kAppBundleID = @"com.reprovision.repro";

// 免费账号「同一设备最多 3 个自签应用」限制所依赖的扩展属性名
static const char *const kFreeProfileXattr = "com.apple.installd.validatedByFreeProfile";
// 用户 App 安装根目录（rootless / RootHide 下真实路径一致；daemon 跑在 rootfs 真实命名空间）
static NSString *const kBundleRoot = @"/var/containers/Bundle/Application";

static const NSInteger  kFallbackMinutes = 120;   // 默认 2 小时
static const NSInteger  kFallbackDays    = 2;

static FILE     *gLogFile   = NULL;
// 🔴 v1.1.130：NSTimer 依赖 runloop，在越狱/RootHide daemon 环境实测从不触发
// （两份日志「5 秒后立即执行」都无续签日志，#1 永远是 SIGHUP）→ 换 GCD dispatch timer，
// 与 SIGHUP/notify（dispatch source）同一机制，SIGHUP 能工作证明 GCD 主队列可靠。
static dispatch_source_t gTimerSrc = nil;
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

/// 判断 daemon 实际跑在哪个 namespace（这是 RootHide 下 result=7 的决定性证据）：
///   argv[0] = /var/jb/usr/libexec/...     → jbroot namespace ❌（私有 entitlement 被剥离）
///   argv[0] = /usr/libexec/...            → rootfs 真实 namespace ✅（entitlement 保留）
/// 注：libproc.h/proc_pidpath 是 macOS 专属，iOS SDK 没有，故用进程启动路径判断。
static NSString *s_namespace_report(void) {
    NSString *me = [[[NSProcessInfo processInfo] arguments] firstObject];
    if (me.length) {
        if ([me hasPrefix:@"/var/jb/"])
            return [NSString stringWithFormat:@"jbroot namespace (启动路径=%@) ❌ 私有权限会被 RootHide 剥离", me];
        return [NSString stringWithFormat:@"rootfs 真实 namespace (启动路径=%@) ✅ entitlement 应保留", me];
    }
    return @"无法取得自身启动路径";
}

/// 缓存的自检报告（进程内只算一次，每次触发都打印，避免重复 popen 刷屏）
static NSString *gSelfEntitlementReport = nil;

/// 计算自身 entitlement 自检报告（进程启动时调用一次）
static void s_compute_self_entitlements(void) {
    // RootHide 下 daemon 跑在 rootfs 真实 namespace，而 ldid/codesign 装在 jbroot，
    // 不在 daemon 的 PATH 里 → popen 调不到。此时读不到 ≠ 二进制没签名
    // （已用 Mach-O 解析证明 CI 确实签上了 entitlements）。避免误报「CI 裸签」。
    BOOL toolsAvailable = s_tool_exists(@"/usr/bin/codesign") || s_tool_exists(@"codesign")
                       || s_tool_exists(@"ldid");
    if (!toolsAvailable) {
        gSelfEntitlementReport = [NSString stringWithFormat:
            @"ℹ️ 无法自检 entitlement（ldid/codesign 不在 daemon 的 rootfs PATH，属 RootHide 正常现象，不代表未签名）\n"
            @"  namespace: %@\n"
            @"  （若怀疑裸签，请用 ssh 进设备执行 `ldid -e /usr/libexec/repro-signingd` 手动确认）",
            s_namespace_report()];
        return;
    }
    NSString *xml = s_read_self_entitlements_xml();
    if (xml.length == 0) {
        gSelfEntitlementReport = [NSString stringWithFormat:
            @"⚠️ 无法读取自身 entitlement（codesign/ldid 可用但都没返回 → 确属 CI 裸签，必须 do_sign 带 entitlements）\n  namespace: %@", s_namespace_report()];
        return;
    }
    BOOL hasLaunch = [xml containsString:@"com.apple.backboardd.launchapplications"];
    BOOL hasUnlim  = [xml containsString:@"com.apple.multitasking.unlimitedassertions"];
    BOOL hasSys    = [xml containsString:@"com.apple.multitasking.systemappassertions"];
    NSMutableString *r = [NSMutableString stringWithFormat:
        @"自身 entitlement 自检: backboardd.launchapplications=%@  unlimitedassertions=%@  systemappassertions=%@\n"
        @"  namespace: %@",
        hasLaunch ? @"✅有" : @"❌缺失(被 RootHide 剥离)",
        hasUnlim  ? @"✅有" : @"❌缺失",
        hasSys    ? @"✅有" : @"❌缺失",
        s_namespace_report()];
    if (!hasLaunch) {
        [r appendString:@"\n  ❌ 致命: backboardd.launchapplications 缺失 → daemon 跑在 jbroot namespace，"
                        "SBSLaunch 必返回 7。修复: roothide postinst 必须用 jbroot 命令把 plist 转 rootfs 路径再 launchctl bootstrap。"];
    }
    gSelfEntitlementReport = r;
}

/// 每次触发都打印的自检（进程内只算一次，之后复用缓存）
static void s_report_self_entitlements(void) {
    if (!gSelfEntitlementReport) s_compute_self_entitlements();
    s_log(@"%@", gSelfEntitlementReport ?: @"⚠️ 未检测到自身 entitlement 信息");
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
//   旧版 daemon 只认 /var/mobile/Library/RePro/signingd-config.plist 这一个来源，
//   而这个文件只有 App 在前台改设置时才会被写出来。只要 App 没被打开过
//   （而 daemon 的整个存在意义恰恰就是「不用打开 App」），文件就不存在，
//   daemon 于是一路打「配置文件不存在」并用死值 120 分 / 2 天 跑，
//   跟界面上的设置完全脱节。这就是日志里刷屏的那行的真正含义。
//
//   现在按 ReProvision 原版 reprovisiond 的做法：优先直接读 App 自己的
//   UserDefaults（CFPreferences，appID=jp.soh.reprovision，user=mobile）。
//   只要用户在界面上动过设置，这份数据一定存在，且不依赖 App 主动同步。
//   读不到再依次回退到共享 plist、App 容器内的偏好文件。

typedef struct {
    BOOL enabled;
    NSInteger minutes;
    NSInteger days;
    BOOL forceResignLowPower;   // v1.1.128：低电量强制续签（默认 NO=低电量跳过）
} sd_config;

/// 本次实际生效的配置来源（--status 会打印，方便一眼确认有没有读到 App 的设置）
static NSString *gCfgSource = @"未读取";

/// 从字典解析配置（key 与 App 端 @AppStorage 完全一致）
static BOOL s_parseCfg(NSDictionary *d, sd_config *out) {
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    id rawMin = d[@"checkIntervalMin"];
    id rawDy  = d[@"resignThreshold"];
    id rawEn  = d[@"autoResign"];
    if (!rawMin && !rawDy && !rawEn) return NO;   // 三个键一个都没有 = 不是我们的配置

    NSInteger m  = rawMin ? [rawMin integerValue] : kFallbackMinutes;
    NSInteger dy = rawDy  ? [rawDy  integerValue] : kFallbackDays;
    if (m  < 1) m  = kFallbackMinutes;
    if (dy < 1) dy = kFallbackDays;

    out->minutes = m;
    out->days    = dy;
    out->enabled = rawEn ? [rawEn boolValue] : YES;
    // v1.1.128：低电量强制续签开关（App 设置「低电量强制续签」，默认关=低电量跳过）
    id rawLow = d[@"forceResignLowPower"];
    out->forceResignLowPower = rawLow ? [rawLow boolValue] : NO;
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
    sd_config cfg = (sd_config){YES, kFallbackMinutes, kFallbackDays};
    NSString *source = nil;

    if (s_parseCfg(s_readAppPreferences(), &cfg)) {
        source = @"App 设置(CFPreferences)";
    } else if (s_parseCfg([NSDictionary dictionaryWithContentsOfFile:kConfigPath], &cfg)) {
        source = @"共享 plist";
    } else if (s_parseCfg(s_readContainerPreferences(), &cfg)) {
        source = @"App 容器偏好文件";
    }

    // 只在配置值或来源发生变化时才写日志，避免像旧版那样每秒刷屏
    static NSInteger lastMin = -1, lastDays = -1;
    static int lastEn = -1;
    static NSString *lastSource = nil;
    NSString *srcName = source ?: @"内置默认值";
    gCfgSource = srcName;   // 供 --status 显示，让用户一眼看出读的是不是 App 里的设置

    if (lastMin != cfg.minutes || lastDays != cfg.days ||
        lastEn != (int)cfg.enabled || ![lastSource isEqualToString:srcName]) {
        lastMin = cfg.minutes; lastDays = cfg.days;
        lastEn = (int)cfg.enabled; lastSource = srcName;

        if (source) {
            s_log(@"读取配置[来源: %@]: 检查间隔=%ld分 提前重签=%ld天 自动续签=%@",
                  srcName, (long)cfg.minutes, (long)cfg.days, cfg.enabled ? @"开" : @"关");
        } else {
            s_log(@"⚠️ 三个来源都没读到配置，退回默认值: 检查间隔=%ld分 提前重签=%ld天",
                  (long)kFallbackMinutes, (long)kFallbackDays);
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

/// 设置系统级电源唤醒
///
/// v1.1.64 更正：之前一直以为日志里的失败码是「RootHide 权限限制」，
/// 实际 0xE00002C2 = kIOReturnBadArgument，是我们自己把 type 参数写错了
/// （见下方注释）。此功能仍属「增强体验」而非核心链路，失败不阻塞续签。
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

    // ⚠️ v1.1.64 修复：type 参数必须是 IOPMLib.h 里定义的字面量常量，
    //    kIOPMAutoWakeOrPowerOn == "wakepoweron"。
    //    旧版自己编了个 "AutoWakeOrPowerOn"，IOKit 认不出来 →
    //    直接返回 kIOReturnBadArgument(0xE00002C2)，也就是日志里那个
    //    ret=-536870206（同一个数的十进制写法）。跟权限一点关系都没有。
    int ret = schedFn((__bridge CFDateRef)wakeDate,
                       CFSTR("jp.soh.reprovision.signingd"),
                       CFSTR("wakepoweron"));
    dlclose(ioKit);

    if (ret == 0) {
        s_log(@"[Step 3/3] 已设置系统级唤醒 — %.0f 秒后 (%@)", secondsFromNow, wakeDate);
        return YES;
    }

    // 注意：全部用 %@ 拼 NSString，不要用 %s 传中文 C 字符串
    //（NSString 的 %s 按系统编码解释，中文会变成 Êú™Áü• 这种乱码，v1.1.63 日志里就是这么来的）
    unsigned int uret = (unsigned int)ret;
    NSString *reason = @"未知错误";
    if      (uret == 0xE00002C1) reason = @"kIOReturnNotPrivileged 权限不足";
    else if (uret == 0xE00002C2) reason = @"kIOReturnBadArgument 参数错误";
    else if (uret == 0xE00002C5) reason = @"kIOReturnExclusiveAccess 被独占";
    else if (uret == 0xE00002C6) reason = @"kIOReturnBadMessageID 消息 ID 错误";
    else if (uret == 0xE00002C7) reason = @"kIOReturnUnsupported 系统不支持";
    s_log(@"[Step 3/3] 系统级唤醒失败 (ret=0x%08X %@) — 非致命，定时器/解锁/亮屏触发仍可用",
          uret, reason);
    return NO;
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
                  @"→ 根因是 daemon 的后台启动权限被拒：检查上方『自身 entitlement 自检』的 namespace 行；"
                  @"若显示 jbroot namespace，说明 daemon 仍跑在 jbroot 路径下（postinst 未用 jbroot 命令转 rootfs）。",
                  regPid);
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

    // Step 3 的公共逻辑：预约下一次系统级唤醒
    void (^scheduleWake)(void) = ^{
        sd_config c = s_cfg();
        NSTimeInterval wakeInterval = ((NSTimeInterval)c.minutes * 60.0) - 30;
        if (wakeInterval > 10) s_scheduleSystemWake(wakeInterval);
    };

    if (!waitForCompletion) {
        // 异步模式：定时器触发的正常流程，用 dispatch_after 不阻塞主循环
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ acquireAssertion(); });
        scheduleWake();
        // result==7（后台内容刷新式启动）同样视为成功：App 实际已被拉起
        return (launchResult == 0 || launchResult == 7 || existingPid > 0);
    }

    // ── 同步模式：--resign-now / SIGHUP 触发，阻塞等待 ──
    sleep(2);                 // 给 App 一点启动时间
    acquireAssertion();
    scheduleWake();

    s_log(@"[完成] 唤醒流程结束 — App 将在后台静默执行续签");
    // result==7（后台内容刷新式启动）同样视为成功：App 实际已被拉起
    return (launchResult == 0 || launchResult == 7 || gAppPID > 0);
}

/// 异步版本：用于定时器/解锁/亮屏触发（不阻塞主循环）
static BOOL s_launchAppInBackground(void) {
    return s_launchAppAndWait(NO);
}

// ─── 触发 ────────────────────────────────────────────────────────

static BOOL s_consumeFixCellularRequestIfAny(void);   // v1.1.130 前置声明

static void s_fire(void) {
    sd_config c = s_cfg();
    if (!c.enabled) { s_log(@"自动续签已关闭，跳过"); return; }

    // 🔴 v1.1.130：续签前先处理待修复请求（文件轮询兜底，不依赖 notify——
    // App 续签失败时写的 fix-cellular-request，若 notify 通知丢失也能补上）。
    // 有请求 → 修复流程接管（内部 10 秒后重调度续签），本次续签让位。
    if (s_consumeFixCellularRequestIfAny()) {
        s_log(@"续签让位于联网修复（修复完成后自动重试续签）");
        return;
    }

    // v1.1.128：低电量默认跳过续签；「低电量强制续签」开启后不跳过
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled] && !c.forceResignLowPower) {
        s_log(@"低电量模式，跳过续签（设置「低电量强制续签」可强制）");
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

/// 重算 nextFireDate 并重设定时器（任何续签触发路径后调用，保证设置页时间准确）。
static void s_reschedule(NSTimeInterval sec) {
    NSDate *next = [[NSDate date] dateByAddingTimeInterval:sec];
    s_setNextFireDate(next);
    s_start_timer(sec);
    s_log(@"已重新调度 — %.0f 秒后触发 (%@)", sec, next);
}

/// 执行一次完整的重签周期，然后重新设定时器
static void s_initiateAndReschedule(void) {
    s_fire();

    sd_config c = s_cfg();
    NSTimeInterval interval = (NSTimeInterval)c.minutes * 60.0;
    s_reschedule(interval);
}

// ─── 续签失败 → daemon 修复联网 → 立即重试续签（v1.1.129）──────────────
// 用户实测痛点：App 续签因网络权限丢失失败后，旧逻辑由 App 自己调 helper 修复，
// helper killall SpringBoard 会把 App 杀掉，而 daemon 下一轮定时器要等一个完整
// 检查间隔（最长 1 小时）才触发 —— 链路断裂（SpringBoard 重启也使 IOPM 系统级
// 唤醒与 BKSProcessAssertion 失效，1 小时后的唤醒存在不确定性）。
// 本方案：修复动作移交 daemon（rootfs LaunchDaemon，SpringBoard 重启不影响自身），
// 修复完成后立即重新调度续签（10 秒后触发），续签自动接续，无需等一个完整间隔。

/// 解析 repro-helper 的绝对路径（rootfs daemon 视角，三种越狱形态）。
static NSString *s_resolveHelperPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // RootHide：jbroot 在 /var/containers/Bundle/Application/.jbroot-*/usr/libexec
    NSArray *appDirEntries = [fm contentsOfDirectoryAtPath:kBundleRoot error:nil];
    for (NSString *entry in appDirEntries) {
        if ([entry hasPrefix:@".jbroot-"]) {
            NSString *p = [NSString stringWithFormat:@"%@/%@/usr/libexec/repro-helper",
                           kBundleRoot, entry];
            if ([fm isExecutableFileAtPath:p]) return p;
        }
    }
    // rootless / rootful
    for (NSString *p in @[@"/var/jb/usr/libexec/repro-helper",
                          @"/usr/libexec/repro-helper"]) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

/// 处理 App 的「续签网络失败 → 修复并立即重试」请求（后台线程执行，不阻塞 daemon）。
static void s_handleFixCellularRequest(void) {
    NSString *helper = s_resolveHelperPath();
    if (!helper) {
        s_log(@"[联网修复] 未找到 repro-helper，无法修复");
        return;
    }
    NSString *selfBid = kAppBundleID;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1) 等 App 退出（App 发请求后还会 notifySigningComplete 并 exit(0)）。
        //    🔴 互斥检查必须放这里而不是主线程：请求到达时 App 的 signing-complete
        //    还没发（gResignInProgress 仍 YES），此刻检查会误判「续签进行中」而跳过。
        sleep(2);
        // v1.1.131：main queue 可能因 3 应用绕过等任务拥堵导致 signing-complete 通知
        // 延迟处理（gResignInProgress 悬挂），多等几轮（最长 15 秒）而不是直接跳过。
        for (int i = 0; i < 3 && gResignInProgress &&
                (time(NULL) - gResignStartTime) < 120; i++) {
            sleep(3);
        }
        time_t now = time(NULL);
        if (gResignInProgress && (now - gResignStartTime) < 120) {
            s_log(@"[联网修复] App 仍在续签，跳过修复请求（续签优先，修复可延后）");
            return;
        }

        // 2) 删除 auto-resign-trigger：续签刚结束时 trigger 的 timestamp 在 180 秒内，
        //    helper 入口的续签互斥检查会直接 exit 0 跳过修复 → 必须先清掉。
        //    （trigger 本就是 daemon 自己写的，续签已结束，删除安全）
        [[NSFileManager defaultManager] removeItemAtPath:kTriggerPath error:nil];

        // 3) exec helper 修复（rootfs daemon 直接跑，killall SpringBoard 不影响自身）
        NSString *cmd = [NSString stringWithFormat:@"'%@' fix-cellular '%@' 2>&1", helper, selfBid];
        s_log(@"[联网修复] 执行 repro-helper fix-cellular …");
        s_run_cmd(cmd);

        // 4) 修复完成（helper 内部已 killall SpringBoard），等 SpringBoard/backboardd 就绪
        s_log(@"[联网修复] 修复完成，等待 SpringBoard 重启就绪（5 秒）…");
        sleep(5);

        // 5) 立即重新调度续签：10 秒后触发（网络已修复，续签自动接续）
        dispatch_async(dispatch_get_main_queue(), ^{
            s_reschedule(10);
            s_log(@"[联网修复] 10 秒后重试续签");
        });
    });
}

// ─── 定时器管理 ─────────────────────────────────────────────────

static void s_start_timer(NSTimeInterval sec) {
    // v1.1.130：NSTimer → GCD dispatch_source timer（见 gTimerSrc 注释）
    if (gTimerSrc) { dispatch_source_cancel(gTimerSrc); gTimerSrc = nil; }
    dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    gTimerSrc = src;
    dispatch_source_set_timer(src,
        dispatch_time(DISPATCH_TIME_NOW, (uint64_t)(sec * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, (uint64_t)(2 * NSEC_PER_SEC)); // 一次性触发 + 2 秒宽松
    dispatch_source_set_event_handler(src, ^{
        time_t n = time(NULL); if (n - gLastFire < 30) return; gLastFire = n;
        s_initiateAndReschedule();
    });
    dispatch_resume(src);
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
            s_log(@"从持久化恢复 — %.0f 秒后触发 (%@)", interval, savedNextFire);
        }
    } else {
        // v1.1.64：首次启动也要把 nextFireDate 落盘。
        // 旧版这里不写，导致「亮屏」回调读不到 nextFireDate，
        // 每次点亮屏幕都把定时器重置成完整的一个间隔 →
        // 如果间隔设得比较长，用户频繁亮屏就永远等不到触发。
        NSDate *next = [NSDate dateWithTimeIntervalSinceNow:interval];
        s_setNextFireDate(next);
        s_log(@"首次调度 — %.0f 分钟后触发 (%@)", interval / 60.0, next);
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
            s_startSigningTimer();
        }
    } else {
        // v1.1.64 修复：旧版在这里 invalidate 掉定时器「省电」，
        // 但 IOPM 系统级唤醒在越狱环境下经常失败（见 s_scheduleSystemWake），
        // 一旦唤醒没排上，锁屏期间就彻底没有任何触发源，
        // 必须等用户主动点亮屏幕才会重新调度 —— 这跟「脱离 App 自动续签」的目标直接冲突。
        // 现在熄屏保留定时器：设备浅睡时它照样能到点触发，深睡则在唤醒后立刻补触发。
        NSDate *next = s_getNextFireDate();
        s_log(@"屏幕熄灭 — 定时器继续保留 (下次触发 %@)", next ?: @"未记录");
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
    // v1.1.130：续签前处理待修复请求（文件轮询兜底，修复流程接管后 10 秒重试续签）
    if (s_consumeFixCellularRequestIfAny()) {
        s_log(@"[%@] 续签让位于联网修复（修复完成后自动重试续签）", reason);
        return;
    }
    // v1.1.128：低电量默认跳过续签；「低电量强制续签」开启后不跳过
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled] && !c.forceResignLowPower) {
        s_log(@"[%@] 低电量模式，忽略本次触发（设置「低电量强制续签」可强制）", reason);
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

    // 🔴 v1.1.130：手动触发（SIGHUP / --resign-now）后也重算 nextFireDate 并重设定时器。
    // 旧逻辑这里不重调度 → nextFireDate 停留在旧值（设置页显示过去时间），
    // 且定时器未重置，下一次自动续签依赖旧的剩余间隔，行为不确定。
    sd_config c2 = s_cfg();
    NSTimeInterval interval = (NSTimeInterval)c2.minutes * 60.0;
    s_reschedule(interval);
}

/// 🔴 v1.1.130：续签前检查 fix-cellular-request 请求文件（15 分钟内新鲜）。
/// App 续签失败时写该文件并 notify daemon；notify 在 RootHide 下可能丢失，
/// 这里文件轮询兜底——任何续签触发（定时器/解锁/亮屏/SIGHUP）都会先修再签。
static BOOL s_consumeFixCellularRequestIfAny(void) {
    NSString *reqPath = @"/var/mobile/Library/RePro/fix-cellular-request";
    NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:reqPath];
    if (!req) return NO;
    NSTimeInterval ts = [req[@"timestamp"] doubleValue];
    if (ts <= 0 || (time(NULL) - (time_t)ts) > 900) {
        // 过期/非法请求：清掉，不处理
        [[NSFileManager defaultManager] removeItemAtPath:reqPath error:nil];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:reqPath error:nil];
    s_log(@"[联网修复] 检测到待处理的修复请求（文件轮询兜底）→ 先修复再续签");
    s_handleFixCellularRequest();
    return YES;
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

    // 续签重装完成 → 解除免费账号 3 应用限制（installd 会在安装时重新打上 xattr）。
    // 通过合并计时器，2 秒后执行一次（让 installd 收尾，避免刚删又被写回）。
    s_requestBypass(@"续签完成");

    // 🔴 v1.1.131：修复请求文件兜底——App 续签因网络失败时写的 fix-cellular-request，
    // 若「com.reprovision.fix-cellular-request」notify 在 RootHide 下丢失，
    // 每次续签结束（signing-complete）时检查补上，保证修复一定会执行。
    if ([[NSFileManager defaultManager] fileExistsAtPath:kFixCellularReqPath]) {
        s_log(@"[联网修复] 续签结束发现待处理的修复请求（notify 兜底）→ 执行修复");
        s_consumeFixCellularRequestIfAny();
    }
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
            NSString *bypassReason = s_bypassReason;
            // 🔴 v1.1.131：3 应用绕过枚举很重（遍历全部应用容器递归扫 xattr，
            // 实测约几十秒），在 main queue 同步跑会堵死 daemon 主线程 →
            // 续签定时器（「5 秒后立即执行」从不触发，#1 永远是 SIGHUP）与
            // fix-cellular-request 修复请求（App 已发但 daemon 不执行、一直报
            // 联不上网）全部排队瘫痪。移后台线程执行，main queue 只做轻量调度。
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                s_bypass3AppLimitIfEnabled(bypassReason);
            });
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
    printf("配置来源         : %s\n", gCfgSource.UTF8String);
    printf("自动续签开关     : %s\n", c.enabled ? "开" : "关");
    printf("检查间隔         : %ld 分钟   ← 应与 App「设置」页一致\n", (long)c.minutes);
    printf("提前重签阈值     : %ld 天     ← 应与 App「设置」页一致\n", (long)c.days);

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

    // ── 正常守护模式 ──
    s_log(@"========================================");
    s_log(@"=== 启动 pid=%d uid=%d ===", getpid(), getuid());
    s_log(@"管理命令:");
    s_log(@"  sudo /usr/libexec/repro-signingd --status      ← 查看是否真的续签了（推荐先看这个）");
    s_log(@"  sudo killall -HUP repro-signingd              ← 手动触发续签（daemon 不会退出）");
    s_log(@"  sudo /usr/libexec/repro-signingd --resign-now  ← 同步手动触发（前台看完整输出）");
    s_log(@"  sudo /usr/libexec/repro-signingd --bypass-3app ← 手动解除免费账号 3 应用限制");
    s_log(@"  sudo launchctl kickstart -k system/jp.soh.reprovision.signingd  ← 重启 daemon");
    s_log(@"========================================");
    s_setup_signal_handlers();

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
    s_log(@"配置: 自动=%@ 间隔=%ld分 阈值=%ld天",
          c.enabled ? @"是" : @"否", (long)c.minutes, (long)c.days);
    s_log(@"BundleID: %@ | 触发路径: %@", kAppBundleID, kTriggerPath);
    s_log(@"架构: Daemon(调度+唤醒+保活) → App(后台静默签名) → exit(0)");
    s_log(@"      用户无需手动打开 App");

    // 注册系统通知监听
    s_setupNotifyPosts();

    // 启动定时器
    // ⚠️ v1.1.66 修复：旧版在 s_startSigningTimer() 之外，又无条件在启动 5 秒后
    //    调一次 s_fire()，完全无视持久化的 nextFireDate。结果每次 daemon 重启
    //    （包括 deb 重装）都立刻尝试续签 → 在 RootHide 下必然 result=7 失败刷屏。
    //    s_startSigningTimer() 已经处理了「过期即 5 秒后触发」「未过期则按间隔等待」，
    //    这里绝不该再额外触发一次。删除该冗余 dispatch。
    s_startSigningTimer();

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

    // 续签因网络权限丢失失败 → daemon 修复联网 → 立即重试续签（v1.1.129）
    int t4; notify_register_dispatch("com.reprovision.fix-cellular-request", &t4,
        dispatch_get_main_queue(), ^(int _){
        s_log(@"[联网修复] 收到 App 的 fix-cellular-request（续签网络失败）");
        s_handleFixCellularRequest();
    });

    // ★ App 每完成一个应用的签名安装就发一次，daemon 立即解除 3 应用限制。
    //   前台手动签名 / IPA 导入安装 / 其它应用签名 / 后台续签 全部走这条通道。
    //   2 秒延迟让 installd 把 xattr 写完再删，避免竞态。
    int t3; notify_register_dispatch("com.reprovision.bypass-3app-request", &t3,
        dispatch_get_main_queue(), ^(int _){
        s_log(@"3应用绕过: 收到 App 的 bypass-3app-request 信号（合并后执行）");
        s_requestBypass(@"App 签名完成");
    });

    // 启动时先跑一次：覆盖 daemon 未运行期间（重启后 / 刚装完 deb）新装的应用
    s_requestBypass(@"daemon 启动");

    s_log(@"进入主循环（等待定时器/SIGHUP/解锁/亮屏触发）");
    // 🔴 v1.1.130：改 dispatch_main() 跑 GCD 主队列。旧版 [[NSRunLoop mainRunLoop] run]
    // 在越狱/RootHide daemon 环境下 NSTimer 从不触发（实测日志 5 秒定时器无动作），
    // GCD 主队列事件（dispatch timer / notify_register_dispatch / 信号 source）才可靠。
    dispatch_main();
    return 0;
}
