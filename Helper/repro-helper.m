//
//  repro-helper.m
//  RePro —— 按需 root 助手（setuid root 小工具，非常驻）
//
//  取代原版 ReProvision 的常驻守护进程 reprovisiond：
//  App（mobile）在需要 root 权限时用 posix_spawn 同步拉起本工具，做完一件事就退出。
//  没有 launchd plist、没有 XPC、没有 mach service，也就没有守护进程那一堆
//  「起不来 / 不是 root / 域搞错」的坑。
//
//  两个动作的逻辑逐行照搬原版 Shared/Daemon/RPVDaemonListener.m：
//    copy <src> <dst>        <- copyFileAtPath:toPath:withReply:
//    install-profile <src>   <- installProvisioningProfileAtPath:withReply:
//
//  退出码：0 成功，非 0 失败（App 侧只看 0/非 0）。
//
//  安装要求：/usr/libexec/repro-helper，owner root:wheel，权限 4755（setuid 位必须有）。
//  编译要求：普通 clang，**不要**带任何 vroot / jbroot 路径翻译——本工具里写死的
//  /var/Managed Preferences/mobile 必须是真实系统路径。
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>

#pragma mark - 日志

/// v1.1.126：fix-cellular 命令开启 gHelperSilent 后全部静默（用户要求隐藏修复联网日志）。
static BOOL gHelperSilent = NO;

/// NSLog 在 iOS 命令行工具里同时写 stderr 和系统日志，
/// App 侧把 stderr 重定向到临时文件即可拿到完整诊断。
static void RPVHelperLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RPVHelperLog(NSString *format, ...) {
    if (gHelperSilent) return; // 🔇 静默模式：fix-cellular 不输出任何日志
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSLog(@"*** [repro-helper] %@", message);
}

#pragma mark - copy

/// 跨沙箱复制文件（对应原 daemon 的 copyFileAtPath:toPath:withReply:）。
/// 用途：App 从「文件」App 的安全域拿不到读权限时，让 root 把 IPA 搬到 App 的 tmp。
static int RPVHelperCopyFile(NSString *srcPath, NSString *dstPath) {
    RPVHelperLog(@"copy: %@ -> %@", srcPath, dstPath);

    if (srcPath.length == 0 || dstPath.length == 0) {
        RPVHelperLog(@"copy 参数为空");
        return 2;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];

    // App 通常已经在自己的 tmp 里建好目标目录了，这里再兜一次底。
    NSString *destinationDirectory = [dstPath stringByDeletingLastPathComponent];
    [fileManager createDirectoryAtPath:destinationDirectory
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];

    // 清掉上一次失败留下的残余文件。
    if ([fileManager fileExistsAtPath:dstPath]) {
        [fileManager removeItemAtPath:dstPath error:nil];
    }

    NSError *error = nil;
    if (![fileManager copyItemAtPath:srcPath toPath:dstPath error:&error]) {
        RPVHelperLog(@"copy 失败: %@", error);
        return 3;
    }

    // 文件是 root 写的，得让 mobile 身份的 App 能读回去。
    [fileManager setAttributes:@{NSFilePosixPermissions : @(0644)}
                  ofItemAtPath:dstPath
                         error:nil];

    RPVHelperLog(@"copy 完成: %@", dstPath);
    return 0;
}

#pragma mark - 刷新 profiled

/// 让 profiled 立刻重新扫描 /var/Managed Preferences/mobile/ 库。
/// 优先用 killall（若存在）；RootHide 等没有 killall 的环境回退到 sysctl 枚举进程，
/// 直接给 profiled 发 SIGHUP（纯系统调用，不依赖任何外部二进制，root 进程可用）。
/// 发送后短暂等待，给 profiled 完成重新加载的时间。
static void RPVHelperRefreshProfiled(void) {
    // 1) 优先 killall（部分环境提供）
    static const char *killallCandidates[] = {
        "/var/jb/usr/bin/killall",
        "/var/jb/bin/killall",
        "/usr/bin/killall",
        "/usr/local/bin/killall",
        NULL
    };
    const char *killallPath = NULL;
    for (int i = 0; killallCandidates[i]; i++) {
        if (access(killallCandidates[i], X_OK) == 0) {
            killallPath = killallCandidates[i];
            break;
        }
    }
    if (killallPath) {
        pid_t pid = 0;
        char *const kaArgv[] = { (char *)killallPath, (char *)"-HUP", (char *)"profiled", NULL };
        if (posix_spawn(&pid, killallPath, NULL, NULL, kaArgv, NULL) == 0 && pid > 0) {
            int status = 0;
            waitpid(pid, &status, 0);
        }
        RPVHelperLog(@"已通过 killall 发送 SIGHUP 给 profiled");
        usleep(400000);
        return;
    }

    // 2) 回退：sysctl(KERN_PROC_ALL) 枚举，直接给名为 profiled 的进程发 SIGHUP
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
        RPVHelperLog(@"profiled 刷新失败：sysctl 取进程表大小失败");
        return;
    }
    struct kinfo_proc *procs = malloc(size);
    if (!procs) {
        RPVHelperLog(@"profiled 刷新失败：无法分配内存");
        return;
    }
    if (sysctl(mib, 3, procs, &size, NULL, 0) != 0) {
        RPVHelperLog(@"profiled 刷新失败：sysctl 取进程表失败");
        free(procs);
        return;
    }
    int count = (int)(size / sizeof(struct kinfo_proc));
    int signalled = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "profiled") == 0) {
            pid_t pid = procs[i].kp_proc.p_pid;
            if (pid > 0 && kill(pid, SIGHUP) == 0) {
                signalled++;
            }
        }
    }
    free(procs);
    if (signalled > 0) {
        RPVHelperLog(@"已通过 sysctl 向 %d 个 profiled 进程发送 SIGHUP", signalled);
    } else {
        RPVHelperLog(@"警告：未找到 profiled 进程，无法发送 SIGHUP（描述文件已写入，但 profiled 可能未加载）");
    }
    usleep(400000);
}

#pragma mark - 写描述文件到指定目录

/// 把 profile 写到 dir/<sha1>.mobileprovision（dir 不存在则创建），返回是否成功。
static BOOL RPVHelperWriteProfileToDir(NSData *data, NSString *fileName, NSString *dir, NSString *profilePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            RPVHelperLog(@"创建目录失败 %@: %@", dir, error);
            return NO;
        }
    }
    NSString *dest = [dir stringByAppendingPathComponent:fileName];
    if (![fm fileExistsAtPath:dest]) {
        if (![fm copyItemAtPath:profilePath toPath:dest error:&error]) {
            RPVHelperLog(@"描述文件复制失败 %@: %@", dest, error);
            return NO;
        }
        [fm setAttributes:@{NSFilePosixPermissions          : @(0644),
                            NSFileOwnerAccountName          : @"root",
                            NSFileGroupOwnerAccountName     : @"wheel"}
                 ofItemAtPath:dest
                        error:nil];
    }
    return YES;
}

/// 解析本 helper 所在 jbroot 的物理真实目录下的 profile 库路径。
/// helper 自身路径形如 /var/containers/Bundle/Application/.jbroot-XXXX/usr/libexec/repro-helper，
/// 去掉末尾 /usr/libexec/repro-helper 即得 jbroot 根，拼 var/Managed Preferences/mobile。
/// 在 RootHide 下 profiled 读的是「jbroot 内的这份」（被 overlay 重定向），
/// 而本 helper 若因 entitlement 脱离了 overlay、写的是真实 /var/Managed Preferences/mobile/，
/// 两者就不一致；双写 jbroot 物理目录即可命中 profiled 实际读取的位置。
static NSString *RPVHelperJbrootProfileDir(void) {
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    NSString *argv0 = args.count ? args[0] : @"";
    NSString *p = [argv0 stringByDeletingLastPathComponent]; // .../usr/libexec
    p = [p stringByDeletingLastPathComponent];               // .../usr
    p = [p stringByDeletingLastPathComponent];               // .../.jbroot-XXXX
    if (p.length == 0) return nil;
    return [p stringByAppendingPathComponent:@"var/Managed Preferences/mobile"];
}

#pragma mark - install-profile

/// 把描述文件装进系统 profile 库（对应原 daemon 的 installProvisioningProfileAtPath:withReply:）。
static int RPVHelperInstallProvisioningProfile(NSString *profilePath) {
    RPVHelperLog(@"install-profile: %@", profilePath);

    if (profilePath.length == 0) {
        RPVHelperLog(@"install-profile 参数为空");
        return 2;
    }

    NSData *data = [NSData dataWithContentsOfFile:profilePath];
    if (data.length == 0) {
        RPVHelperLog(@"描述文件读不到内容: %@", profilePath);
        return 4;
    }

    // 用内容 SHA1 做文件名，保证同一份 profile 不会重复堆积。
    // profiled/MIS 会把库里每个 *.mobileprovision 都解析一遍，文件名本身无所谓。
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    NSString *fileName = [hex stringByAppendingPathExtension:@"mobileprovision"];

    // 双写两个视图，覆盖 RootHide 下 helper 与 profiled 命名空间不一致的问题：
    //  - 视图A：本进程看到的 /var/Managed Preferences/mobile/（若 helper 因 entitlement
    //    脱离了 overlay，这就是真实 rootfs；若仍在 overlay，则底层是 jbroot 内）
    //  - 视图B：helper 所在 jbroot 的物理真实目录下的同名路径（profiled 在 RootHide 下
    //    被 overlay 重定向，读的就是 jbroot 内的这份）—— 双写 B 即可命中 profiled 实际读取位置。
    NSString *directory = @"/var/Managed Preferences/mobile";
    NSString *destination = [directory stringByAppendingPathComponent:fileName];
    NSString *jbrootDir = RPVHelperJbrootProfileDir();
    NSString *jbrootDest = jbrootDir ? [jbrootDir stringByAppendingPathComponent:fileName] : nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];

    BOOL okMain = RPVHelperWriteProfileToDir(data, fileName, directory, profilePath);
    BOOL okJbroot = jbrootDest ? RPVHelperWriteProfileToDir(data, fileName, jbrootDir, profilePath) : NO;
    RPVHelperLog(@"写入视图A(/var/Managed Preferences/mobile): %@；写入视图B(jbroot 物理): %@",
                 okMain ? @"成功" : @"失败",
                 jbrootDest ? (okJbroot ? @"成功" : @"失败") : @"跳过(无法解析 jbroot)");

    // 注意：RootHide 下描述文件的主注册已由 App 进程自身经 MCProfileConnection 完成
    // （App 带 profiled-access，以 mobile 身份调 MC 落【本地库】，与能正常工作的 test2源码
    //  完全一致；installd 的 AllowInstallLocalProvisioned 查的正是本地库）。
    // 本 helper 不再自己调 MC：早期版本让 root+no-sandbox 的 helper 调 MC，结果同一份
    //  profile 被注册进 managed(MSM) 库（installd 不认）→ 0xe8008015；且 managed 注册会
    //  覆盖 App 在本地库的注册，反而把 installd 能读到的副本抹掉。故 helper 只做文件兜底层。
    // 兜底：把 profile 文件写入真实 /var/Managed Preferences/mobile 并踢一下 profiled，
    // 覆盖「某些 RootHide 版本把 App 的 MC XPC 也重定向到 overlay」的边界情况。

    // 踢一下 profiled 让它立刻重新扫描（优先 killall，RootHide 无 killall 时回退 sysctl 直发 SIGHUP）。
    RPVHelperRefreshProfiled();

    // 取证诊断：列出两个视图的目录内 profile 数，确认是否写入成功
    // （若两视图都写入成功但 installd 仍报 0xe8008015，则说明 profiled 读的是第三处路径，
    //  需改为 root LaunchDaemon 注册）。
    NSError *lsErr = nil;
    NSArray *existingA = [fileManager contentsOfDirectoryAtPath:directory error:&lsErr];
    if (lsErr) {
        RPVHelperLog(@"读取视图A目录失败 %@: %@", directory, lsErr);
    } else {
        RPVHelperLog(@"视图A 目录现有 %lu 个描述文件；本文件已写入：%@",
                     (unsigned long)existingA.count,
                     [fileManager fileExistsAtPath:destination] ? @"是" : @"否");
    }
    if (jbrootDest) {
        NSError *lsErrB = nil;
        NSArray *existingB = [fileManager contentsOfDirectoryAtPath:jbrootDir error:&lsErrB];
        if (lsErrB) {
            RPVHelperLog(@"读取视图B目录失败 %@: %@", jbrootDir, lsErrB);
        } else {
            RPVHelperLog(@"视图B 目录现有 %lu 个描述文件；本文件已写入：%@",
                         (unsigned long)existingB.count,
                         [fileManager fileExistsAtPath:jbrootDest] ? @"是" : @"否");
        }
    }

    RPVHelperLog(@"描述文件已安装（视图A: %@ 视图B: %@）",
                 destination, jbrootDest ? jbrootDest : @"(无)");

    // 文件写入任一视图成功即视为兜底成功（主注册已由 App 完成）。
    if (okMain || okJbroot) {
        return 0;
    }
    RPVHelperLog(@"警告：文件写入失败，描述文件未能注册（App MC 也未成功时请检查 App 日志）");
    return 7;
}

#pragma mark - fix-cellular（国行越狱后修复蜂窝数据无法联网）

// 原理（重新逆向 cn.tinyapps.Renet v1.2.2 + ZIKCellularAuthorization 实测）：
// 国行越狱后蜂窝失效 = iOS 的 App 蜂窝/WiFi 数据使用策略被重置。
// 底层通用：CoreTelephony 私有 C 函数
//     _CTServerConnectionCreateOnTargetQueue / _CTServerConnectionSetCellularUsagePolicy
//     —— Settings 里每个 App 的蜂窝开关底层就是它，全 iOS 版本存在。
// 在 root helper 里做：无需 App entitlements，root 权限直接调私有框架。
// 🔴 v1.1.146：只修复当前插件（ReSign）自身——批量对全部应用/系统守护调该私有
//    函数会污染 CoreTelephony 内部状态、在 roothide 下引发 XPC 拦截 fault
//    （修复联网→前后台切换→杀后台→冷启动 EXC_GUARD 闪退）。

typedef CFTypeRef (*CTServerConnectionCreateIMP)(CFAllocatorRef, NSString *,
                                                 dispatch_queue_t, void *);
typedef int (*CTServerConnectionSetPolicyIMP)(CFTypeRef, NSString *, NSDictionary *);

/// 主路径：CoreTelephony 私有 C 函数（全 iOS 版本通用），只修复单个 bundle id。
/// 参考 ZIKCellularAuthorization 实测：字典固定 @{@"kCTCellularUsagePolicyDataAllowed": @YES}
static int RPVHelperFixCellularViaCTServer(NSString *bid) {
    if (bid.length == 0) return 14;

    void *ctHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
                            RTLD_NOW);
    if (!ctHandle) {
        RPVHelperLog(@"fix-cellular(CT): 无法加载 CoreTelephony.framework");
        return 11;
    }

    // dlsym 两个私有 C 函数（Mach-O 导出符号带前导下划线）
    CTServerConnectionCreateIMP createConn =
        (CTServerConnectionCreateIMP)dlsym(ctHandle, "_CTServerConnectionCreateOnTargetQueue");
    CTServerConnectionSetPolicyIMP setPolicy =
        (CTServerConnectionSetPolicyIMP)dlsym(ctHandle, "_CTServerConnectionSetCellularUsagePolicy");
    if (!createConn || !setPolicy) {
        RPVHelperLog(@"fix-cellular(CT): dlsym 失败 createConn=%p setPolicy=%p",
                     createConn, setPolicy);
        return 12;
    }

    // 伪装成「设置」App 创建连接（ZIK 实测技巧）
    CFTypeRef conn = createConn(kCFAllocatorDefault, @"com.apple.Preferences",
                                dispatch_get_main_queue(), NULL);
    if (!conn) {
        RPVHelperLog(@"fix-cellular(CT): _CTServerConnectionCreateOnTargetQueue 返回空");
        return 13;
    }

    // 只对当前插件自身设置蜂窝策略（0=成功；2=无策略条目/系统应用忽略）
    NSDictionary *allow = @{ @"kCTCellularUsagePolicyDataAllowed": @YES };
    int r = -1;
    @try {
        r = setPolicy(conn, bid, allow);
    } @catch (NSException *e) {
        RPVHelperLog(@"fix-cellular(CT): %@ 设置异常: %@", bid, e.reason);
    }
    RPVHelperLog(@"fix-cellular(CT): %@ 返回 %d（0=成功）", bid, r);

    if (conn) CFRelease(conn);
    dlclose(ctHandle);

    // v1.1.124：写共享修复时间戳（与 signingd 开机自动修复共用防抖文件）。
    // 手动/自动修复成功后，下次设备重启前不再重复触发。
    NSDictionary *stamp = @{ @"timestamp": @((double)time(NULL)) };
    [stamp writeToFile:@"/var/mobile/Library/RePro/fix-cellular-last.plist" atomically:YES];

    return 0;
}

/// 温和刷新偏好缓存（killall cfprefsd），使设置 UI 立即反映刚写入的策略。
/// 🔴 v1.1.143：原 killall SpringBoard 会令 launchd 重拉 SpringBoard 时走 roothide
///   的 posix_spawn 钩子 abort → 内核 panic → 整机重启（iOS16/roothide 实测 panic-full）。
///   改用 killall cfprefsd（非 jbroot 系统守护，重拉不触发该钩子），仅刷新偏好缓存；
///   已在同环境实机验证 killall cfprefsd 不触发重启。
static void RPVHelperFlushPreferences(void) {
    RPVHelperLog(@"fix-cellular: 刷新偏好缓存（killall cfprefsd）以更新设置 UI");
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/killall", "killall", "cfprefsd", (char *)NULL);
        execl("/var/jb/usr/bin/killall", "killall", "cfprefsd", (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        waitpid(pid, NULL, 0);
    }
}


static int RPVHelperFixCellular(NSString *selfBid) {
    // 🔴 v1.1.146：只修复当前插件自身（App 侧传入 bundle id），不再枚举/批量修复其他应用。
    // 批量对系统守护/应用调 CoreTelephony 私有 C 函数会污染 CT 内部状态、在 roothide 下
    // 引发 XPC 拦截 fault（修复联网→前后台切换→杀后台→冷启动 EXC_GUARD 闪退）。
    // 其他应用如需修复，请到系统「设置 → 蜂窝网络」手动开启。
    if (selfBid.length == 0) {
        RPVHelperLog(@"fix-cellular 失败：未传入当前插件 bundle id");
        return 3;
    }
    RPVHelperLog(@"fix-cellular 开始：修复当前插件 %@ 的蜂窝/WiFi 数据策略", selfBid);

    int ctRet = RPVHelperFixCellularViaCTServer(selfBid);
    if (ctRet != 0) {
        RPVHelperLog(@"fix-cellular: CoreTelephony 路径失败(code=%d)", ctRet);
        return ctRet;
    }

    RPVHelperFlushPreferences();
    RPVHelperLog(@"fix-cellular 完成（%@）", selfBid);
    return 0;
}

#pragma mark - 入口

static void RPVHelperPrintUsage(void) {
    fprintf(stderr,
            "repro-helper —— ReSign 按需 root 助手\n"
            "用法:\n"
            "  repro-helper copy <源路径> <目标路径>\n"
            "  repro-helper install-profile <描述文件路径>\n"
            "  repro-helper fix-cellular <当前插件 bundle id>\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // setuid root 二进制启动时 euid=0 但 ruid 还是调用方（mobile）。
        // 部分文件 API 与 killall 按真实 uid 判权限，这里先把 ruid 也提成 0。
        if (geteuid() == 0) {
            setgid(0);
            setuid(0);
        }

        // 诊断：把 setuid 之后的真实 uid/euid 打出来，确认 RootHide 下 setuid 是否生效
        //（jbroot 分区若 nosuid 挂载，这里 euid 仍是 mobile，会直接导致 0xe8008015）。
        RPVHelperLog(@"start getuid=%d geteuid=%d", getuid(), geteuid());

        if (geteuid() != 0 || getuid() != 0) {
            RPVHelperLog(@"必须以 root 运行（uid=%d euid=%d），请检查安装权限是否为 root:wheel 4755",
                         getuid(), geteuid());
            return 1;
        }

        if (argc < 2) {
            RPVHelperPrintUsage();
            return 64;
        }

        NSString *command = [NSString stringWithUTF8String:argv[1]];

        if ([command isEqualToString:@"copy"]) {
            if (argc != 4) {
                RPVHelperPrintUsage();
                return 64;
            }
            return RPVHelperCopyFile([NSString stringWithUTF8String:argv[2]],
                                     [NSString stringWithUTF8String:argv[3]]);
        }

        if ([command isEqualToString:@"install-profile"]) {
            if (argc != 3) {
                RPVHelperPrintUsage();
                return 64;
            }
            return RPVHelperInstallProvisioningProfile([NSString stringWithUTF8String:argv[2]]);
        }

        // fix-cellular = App「设置」里「修复当前插件联网」手动入口（仅手动，无 daemon 自动循环）。
        // v1.1.146：只把当前插件（ReSign）自身送进 CoreTelephony 私有 API 修复，
        // 刷新偏好缓存（killall cfprefsd）生效。不再批量处理其他应用。
        if ([command isEqualToString:@"fix-cellular"]) {
            if (argc != 3) {   // fix-cellular <当前插件 bundle id>
                RPVHelperPrintUsage();
                return 64;
            }
            // v1.1.126：用户要求隐藏修复联网日志（不美观）→ 全程静默，只留退出码。
            gHelperSilent = YES;

            // 🔴 续签互斥兜底：若续签 trigger 文件新鲜（180 秒内刚发起过续签，
            // 说明 App 正在后台签名），直接跳过修复（exit 0）。现已改为 killall cfprefsd、
            // 不再误杀签名中的 App，但仍保留 180s 互斥防手动点击/时序竞态。
            // 修复可延后，续签中断不可恢复。
            {
                NSDictionary *trigger = [NSDictionary dictionaryWithContentsOfFile:
                    @"/var/mobile/Library/RePro/auto-resign-trigger"];
                NSTimeInterval ts = trigger ? [trigger[@"timestamp"] doubleValue] : 0;
                if (ts > 0 && (time(NULL) - (time_t)ts) < 180) {
                    return 0; // 🔇 静默跳过（不写时间戳，后续仍可触发修复）
                }
            }

            // argv[2] = 当前插件自身 bundle id（App 侧传入，v1.1.146 必传）
            NSString *selfBid = [NSString stringWithUTF8String:argv[2]];
            return RPVHelperFixCellular(selfBid);
        }

        RPVHelperLog(@"未知命令: %@", command);
        RPVHelperPrintUsage();
        return 64;
    }
}
