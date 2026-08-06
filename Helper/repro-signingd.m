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
//      → App 完成时 notify("com.reprovision.signing-complete") → daemon 写 lastResignTime → 退出
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
#import <mach/mach.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kConfigPath  = @"/var/mobile/Library/RePro/signingd-config.plist";
static NSString *const kTriggerPath = @"/var/mobile/Library/RePro/auto-resign-trigger";
static NSString *const kResultPath  = @"/var/mobile/Library/RePro/last-resign-result.plist";
static NSString *const kPidPath     = @"/var/mobile/Library/RePro/signingd.pid";
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
static NSString *const kCheckStatePath = @"/var/mobile/Library/RePro/signingd-check-state.plist";

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

// ─── 内存看门狗（v1.1.150+：RootHide 拦截器泄漏自救，方案A）────────────────
// 背景：RootHide 的 systemhook/XPC 拦截器在常驻进程里持续泄漏内存，本 daemon
// 曾被实测涨到 3.6~5.1GB（Jetsam physicalPages.internal 实锤）。daemon 自身
// 代码无大分配点，无法从代码层面止住泄漏 → 只能「定期自检、超限主动重启」：
// launchd 配了 KeepAlive=true，退出后立刻拉起新进程，泄漏随旧进程一起释放。
// 🔴 v1.1.151 阈值 1.5GB → 400MB：用户实测「装完过一段时间设备慢慢变卡」——
// 根因是触发线太高：泄漏从 <100MB 涨到 1.5GB 的整个过程都在白白占用物理内存
// （iPhone 12 仅 4GB RAM，1GB 泄漏已让系统负重 → Jetsam 杀后台 → 卡顿），
// 等涨到 1.5GB 才动手已经太晚。400MB = 正常常驻（<100MB）的 4 倍余量；
// daemon 只负责拉起 App 调度（zsign 是 App 子进程），自身峰值远低于此。
// 签名进行中（gResignInProgress）不退出，避免打断签名。
// 前向声明：s_log 定义在下方（C99 要求先声明后使用）
static void s_log(NSString *fmt, ...);
static const uint64_t kMemWatchdogLimit = 400ULL * 1024 * 1024;  // 400 MB

static void s_memWatchdogTick(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&info, &cnt);
    if (kr != KERN_SUCCESS) {
        // ★ v1.1.152：task_info 失败也记 NSLog（防止"静默失败"——之前 2.87GB 时
        // 看门狗日志 0 字节，可能就是 task_info 失败且 s_log 写文件失败导致完全无感）
        NSLog(@"[repro-signingd] 内存看门狗: task_info 失败 kr=%d（不会主动退出）", kr);
        return;
    }
    double mb = (double)info.phys_footprint / (1024.0 * 1024.0);
    double internalMb = (double)info.internal / (1024.0 * 1024.0);
    if (info.phys_footprint <= kMemWatchdogLimit) {
        // 日常每 6 个 tick（约 30 分钟）记录一次水位，便于在日志里观察泄漏曲线
        static int quiet = 0;
        if (++quiet >= 6) { quiet = 0;
            s_log(@"内存看门狗: phys_footprint=%.0fMB internal=%.0fMB（上限 400MB）",
                  mb, internalMb);
        }
        return;
    }
    if (gResignInProgress) {
        s_log(@"内存看门狗: %.0f MB 已超上限，但续签进行中，下轮再检查", mb);
        return;
    }
    s_log(@"⚠️ 内存看门狗: daemon 内存 %.0f MB (internal=%.0f) 超 400MB 上限 → 主动退出，launchd 将立即重新拉起",
          mb, internalMb);
    s_log(@"   （针对 RootHide 容器内拦截器/资源句柄累积的自救：旧进程释放后泄漏清零）");
    if (gLogFile) { fflush(gLogFile); fclose(gLogFile); gLogFile = NULL; }
    exit(0);
}

static void s_startMemWatchdog(void) {
    static dispatch_source_t wd = NULL;
    if (wd) return;
    wd = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // ★ v1.1.152：首次触发从 5 分钟改成 30 秒。
    // 根因：iOS 17 launchd 对 LaunchDaemon 判 "inefficient" 主动 SIGTERM，
    // daemon 生命周期可能 < 5 分钟（exponential throttling 越拉越慢），
    // 原 5 分钟首次检查根本来不及触发；30 秒首次能让短生命周期 daemon 也有早期保护。
    // 后续保持 5 分钟间隔（任务轻，CPU 影响可忽略）。
    dispatch_source_set_timer(wd, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                              5 * 60 * NSEC_PER_SEC, 10 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(wd, ^{ s_memWatchdogTick(); });
    dispatch_resume(wd);
    s_log(@"内存看门狗已启动（30 秒首次自检，之后每 5 分钟；超 400MB 主动重启，签名中不退出）");
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
static void *s_runWatchdogMain(void *arg) {
    (void)arg;
    sleep(10 * 60);
    // 无条件终止进程——NSLog 放在 _exit 之后（不可达），避免 logd 阻塞拖死看门狗
    _exit(0);
    return NULL;
}
static void s_startRunWatchdog(void) {
    pthread_t t;
    if (pthread_create(&t, NULL, s_runWatchdogMain, NULL) == 0) {
        pthread_detach(t);
        s_log(@"超时看门狗已启动（独立线程，超 10 分钟强制退出防僵尸）");
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
        s_log(@"   疑似 RootHide hook 环境问题 —— 建议更新 RootHide/roothide，或重装本 deb；");
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
    // 而 /var/mobile/Library/RePro 是 RootHide 明确的「豁免 overlay 共享 IPC 目录」，
    // daemon 写它 = 真实 rootfs（pid/check-state/crash-count 都写在这里），
    // App 也是 mobile 可读 → 日志放这里，App 日志页与 SSH 都能直接看到。
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/Library/RePro/reprorefresh_at.log",               // ★ 豁免目录=真实 rootfs（v1.1.186 首选）
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
        s_log(@"触发续签 — 阈值 %ld 天（降级为 notify_post）", (long)c.days);
    }

    // 🔴 v1.1.165：无论唤醒成败都 notify_post。根因：App 进程已存在时（用户打开过
    // 挂后台），SBS 后台唤醒不会重走 didFinishLaunching → App 侧的 isDaemonTriggeredResign
    // 永不执行 → 续签静默失败（用户实测「触发了刷新但没自动续签」）。
    // 现在 notify 作为进程内触发通道：App 收到后检查本 trigger 文件的新鲜度（180s）决定
    // 是否执行静默续签；冷启动路径已消费 trigger 时新鲜度检查自然失败，不会双触发。
    notify_post("com.reprovision.schedule-resign");
    return YES;
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
        printf("                   判断健康请用下方「最近一次续签完成」；手动拉起: launchctl kickstart -k system/jp.soh.reprovision.signingd\n");
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
    s_log(@"  sudo launchctl kickstart -k system/jp.soh.reprovision.signingd  ← 立即拉起一轮");
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
    int t2; notify_register_dispatch("com.reprovision.signing-complete", &t2,
        dispatch_get_main_queue(), ^(int _){
        s_onSigningComplete();
    });

    // ★ App 每完成一个应用的签名安装就发一次，daemon 立即解除 3 应用限制。
    //   前台手动签名 / IPA 导入安装 / 其它应用签名 / 后台续签 全部走这条通道。
    //   2 秒延迟让 installd 把 xattr 写完再删，避免竞态。
    int t3; notify_register_dispatch("com.reprovision.bypass-3app-request", &t3,
        dispatch_get_main_queue(), ^(int _){
        s_log(@"3应用绕过: 收到 App 的 bypass-3app-request 信号（合并后执行）");
        s_requestBypass(@"App 签名完成");
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
