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
// Renet 反汇编确认三时代 API：
//   iOS 11/12：PSAppDataUsagePolicyCache -setUsagePoliciesForBundle:cellular:wifi:（传 1,1）
//   iOS 17+ ：PSAppDataUsagePolicyCache -setPolicies:completion:
//   🔴 底层通用：CoreTelephony 私有 C 函数
//       _CTServerConnectionCreateOnTargetQueue / _CTServerConnectionSetCellularUsagePolicy
//       —— Settings 里每个 App 的蜂窝开关底层就是它，全 iOS 版本存在。
//   Renet 的 __LINKEDIT 也导入了 _CTServerConnectionSetCellularUsagePolicy。
// 本 helper 路径：①CoreTelephony C 函数（主，全版本通用）②SettingsCellular ObjC（备）。
// 在 root helper 里做：无需 App entitlements，root 权限直接调私有框架。

typedef CFTypeRef (*CTServerConnectionCreateIMP)(CFAllocatorRef, NSString *,
                                                 dispatch_queue_t, void *);
typedef int (*CTServerConnectionSetPolicyIMP)(CFTypeRef, NSString *, NSDictionary *);

/// 主路径：CoreTelephony 私有 C 函数（全 iOS 版本通用）
/// 参考 ZIKCellularAuthorization 实测：字典固定 @{@"kCTCellularUsagePolicyDataAllowed": @YES}
static int RPVHelperFixCellularViaCTServer(NSArray<NSString *> *bundleIDs) {
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

    // 逐条调用，统计返回码分布（避免刷屏：只打印异常码，正常码汇总）
    int okCount = 0;
    NSMutableDictionary<NSNumber *, NSNumber *> *retCount = [NSMutableDictionary dictionary];
    NSDictionary *allow = @{ @"kCTCellularUsagePolicyDataAllowed": @YES };
    for (NSString *bid in bundleIDs) {
        @try {
            int r = setPolicy(conn, bid, allow);
            okCount++;
            NSNumber *key = @(r);
            retCount[key] = @([retCount[key] intValue] + 1);
            // 只打印异常返回码（0=成功；2=常见"无策略条目/系统应用忽略"；其余才值得看）
            if (r != 0 && r != 1 && r != 2) {
                RPVHelperLog(@"fix-cellular(CT): %@ 返回 %d", bid, r);
            }
        } @catch (NSException *e) {
            RPVHelperLog(@"fix-cellular(CT): %@ 设置异常: %@", bid, e.reason);
        }
    }
    // 汇总返回码分布
    for (NSNumber *key in [retCount.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        RPVHelperLog(@"fix-cellular(CT): 返回码 %@ 共 %@ 个", key, retCount[key]);
    }
    RPVHelperLog(@"fix-cellular(CT): 成功设置 %d/%lu 个应用", okCount,
                 (unsigned long)bundleIDs.count);

    // v1.1.124：写共享修复时间戳（与 signingd 开机自动修复共用防抖文件）。
    // 手动/自动修复成功后，下次设备重启前不再重复触发。
    NSDictionary *stamp = @{ @"timestamp": @((double)time(NULL)) };
    [stamp writeToFile:@"/var/mobile/Library/RePro/fix-cellular-last.plist" atomically:YES];

    if (conn) CFRelease(conn);
    dlclose(ctHandle);
    return 0;
}

/// 另一条 Renet 路径：AppWirelessDataUsageManager（Preferences.framework，iOS 11 官方方案）。
/// Undecimus issue #1112：setAppWirelessDataOption:@(3)（3=WLAN与蜂窝全允许）+
/// setAppCellularDataEnabled:@(1)。iOS 17 若类仍在则有效，否则跳过。
static void RPVHelperFixCellularViaAppWirelessDataUsageManager(NSArray<NSString *> *bundleIDs) {
    void *prefsHandle = dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
                               RTLD_NOW);
    Class mgr = NSClassFromString(@"AppWirelessDataUsageManager");
    if (!mgr && prefsHandle) {
        mgr = NSClassFromString(@"AppWirelessDataUsageManager");
    }
    if (!mgr) {
        RPVHelperLog(@"fix-cellular(awdum): AppWirelessDataUsageManager 不存在（iOS 17 可能已移除），跳过");
        return;
    }

    SEL setWireless = NSSelectorFromString(@"setAppWirelessDataOption:forBundleIdentifier:completionHandler:");
    SEL setCellular = NSSelectorFromString(@"setAppCellularDataEnabled:forBundleIdentifier:completionHandler:");
    if (![mgr respondsToSelector:setWireless] || ![mgr respondsToSelector:setCellular]) {
        RPVHelperLog(@"fix-cellular(awdum): 方法缺失 setWireless=%d setCellular=%d",
                     [mgr respondsToSelector:setWireless], [mgr respondsToSelector:setCellular]);
        return;
    }

    NSNumber *optionAll = @(3);  // 3 = WLAN 与蜂窝（全允许）
    NSNumber *enabled = @(1);    // 1 = 蜂窝启用
    int okWireless = 0, okCellular = 0;
    for (NSString *bid in bundleIDs) {
        @try {
            // 类方法：AppWirelessDataUsageManager 是类方法调用
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                [mgr methodSignatureForSelector:setWireless]];
            [inv setTarget:mgr];
            [inv setSelector:setWireless];
            [inv setArgument:&optionAll atIndex:2];
            [inv setArgument:&bid atIndex:3];
            dispatch_block_t done = ^{};
            [inv setArgument:&done atIndex:4];
            [inv retainArguments];
            [inv invoke];
            okWireless++;
        } @catch (NSException *e) {
            RPVHelperLog(@"fix-cellular(awdum): %@ wireless 异常: %@", bid, e.reason);
        }
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                [mgr methodSignatureForSelector:setCellular]];
            [inv setTarget:mgr];
            [inv setSelector:setCellular];
            [inv setArgument:&enabled atIndex:2];
            [inv setArgument:&bid atIndex:3];
            dispatch_block_t done = ^{};
            [inv setArgument:&done atIndex:4];
            [inv retainArguments];
            [inv invoke];
            okCellular++;
        } @catch (NSException *e) {
            RPVHelperLog(@"fix-cellular(awdum): %@ cellular 异常: %@", bid, e.reason);
        }
    }
    RPVHelperLog(@"fix-cellular(awdum): setAppWirelessDataOption %d/%lu, setAppCellularDataEnabled %d/%lu",
                 okWireless, (unsigned long)bundleIDs.count,
                 okCellular, (unsigned long)bundleIDs.count);
}

/// 枚举已安装应用 bundle id：多路径尝试安装记录 + 容器 metadata 兜底 + /Applications 兜底。
/// 注意：iOS 15+ com.apple.mobile.installation.plist 已不存在；容器真实路径是
/// /var/containers/Bundle/Application（小写 containers，无 mobile 段）。
static NSArray<NSString *> *RPVHelperEnumerateBundleIDs(void) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];

    // ── 方法1：系统安装记录 plist（各版本路径逐一尝试）──
    NSArray<NSString *> *plistPaths = @[
        @"/private/var/mobile/Library/Caches/com.apple.mobile.installation.plist",
        @"/var/mobile/Library/Caches/com.apple.mobile.installation.plist",
        @"/var/Library/Caches/com.apple.mobile.installation.plist",
    ];
    for (NSString *pp in plistPaths) {
        NSDictionary *install = [NSDictionary dictionaryWithContentsOfFile:pp];
        if (!install) continue;
        for (NSString *section in @[@"User", @"System"]) {
            NSDictionary *apps = install[section];
            for (NSString *bid in apps) {
                if (bid.length && ![ids containsObject:bid])
                    [ids addObject:bid];
            }
        }
        if (ids.count > 0) break; // 命中即止
    }

    // ── 方法2：扫容器目录 .com.apple.mobile_container_manager.metadata.plist ──
    if (ids.count == 0) {
        NSArray<NSString *> *bases = @[
            @"/var/containers/Bundle/Application",       // 标准 iOS 路径（正确）
            @"/var/mobile/Containers/Bundle/Application", // 某些 JB 环境可能存在
            @"/private/var/containers/Bundle/Application",
        ];
        for (NSString *base in bases) {
            NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
            for (NSString *dir in dirs) {
                NSString *meta = [NSString stringWithFormat:
                    @"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, dir];
                NSString *bid = [NSDictionary dictionaryWithContentsOfFile:meta]
                                    [@"MCMMetadataIdentifier"];
                if (bid.length && ![ids containsObject:bid])
                    [ids addObject:bid];
            }
            if (ids.count > 0) break;
        }
    }

    // ── 方法3：扫系统应用目录（始终执行，不短路）──
    // 🔴 之前被 ids.count==0 短路：ReSign 自身装在 jbroot/Applications（rootless=/var/jb/Applications、
    //    roothide=jbroot overlay 内的 /Applications），容器扫描扫不到它 → 永远无法修复自身！
    //    故这里无条件追加，把系统应用与越狱工具自身（ReSign/Filza/TrollStore 等）都纳入。
    NSArray<NSString *> *appDirs = @[
        @"/Applications",              // roothide: jbroot overlay 内的 Applications（含 ReSign 自身）
        @"/var/jb/Applications",       // rootless: jbroot 真实路径
        @"/System/Applications",       // iOS 10+ 系统应用
        @"/System/Applications/AppStore.app/../../../Applications", // 备用（一般无效，无害）
    ];
    for (NSString *base in appDirs) {
        NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
        for (NSString *dir in dirs) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [NSString stringWithFormat:@"%@/%@/Info.plist", base, dir]];
            NSString *bid = info[@"CFBundleIdentifier"];
            if (bid.length && ![ids containsObject:bid])
                [ids addObject:bid];
        }
    }

    return ids;
}

/// 重启 SpringBoard 使策略生效（root 直接 killall；先试 rootfs 路径再试 /var/jb）
static void RPVHelperRestartSpringBoard(void) {
    RPVHelperLog(@"fix-cellular: 重启 SpringBoard 使策略生效");
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/killall", "killall", "SpringBoard", (char *)NULL);
        execl("/var/jb/usr/bin/killall", "killall", "SpringBoard", (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        waitpid(pid, NULL, 0);
    }
}

/// 备路径：SettingsCellular 私有框架 PSAppDataUsagePolicyCache（iOS 17 方法 setPolicies:completion:）
static int RPVHelperFixCellularViaSettingsCellular(NSArray<NSString *> *bundleIDs) {
    // 加载 SettingsCellular 私有框架，拿 PSAppDataUsagePolicyCache
    Class cacheClass = NSClassFromString(@"PSAppDataUsagePolicyCache");
    if (!cacheClass) {
        void *h = dlopen("/System/Library/PrivateFrameworks/SettingsCellular.framework/SettingsCellular", RTLD_NOW);
        if (h) {
            cacheClass = NSClassFromString(@"PSAppDataUsagePolicyCache");
        }
    }
    if (!cacheClass) {
        RPVHelperLog(@"fix-cellular(ObjC): 找不到 PSAppDataUsagePolicyCache（SettingsCellular 私有框架未加载）");
        return 4;
    }

    id cache = [cacheClass performSelector:NSSelectorFromString(@"sharedInstance")];
    if (!cache) {
        cache = [[cacheClass alloc] init];
    }
    if (!cache) {
        RPVHelperLog(@"fix-cellular(ObjC): PSAppDataUsagePolicyCache 实例化失败");
        return 5;
    }

    // 运行时自省：dump 类全部实例方法，自动匹配策略设置方法。
    // roothide/jbroot 的 SettingsCellular 框架版本不同，选择器名与参数签名会变。
    // 🔴 v1.1.122 重大发现（用户日志 repro_log_1785823244 铁证）：
    //    setPolicies:completion: 签名 = 返回 v，arg0=@(self) arg1=:(sel) arg2=@ arg3=@?(block)。
    //    但 arg2 不是 NSDictionary——传字典后系统在异步 completion 里对它调
    //    `bundleId` 选择器 → `-[__NSFrozenDictionaryM bundleId]: unrecognized selector`
    //    → helper 崩溃 exit=-1。arg2 必须是**带 bundleId 属性的策略对象数组**。
    //    🔴 故 v1.1.122 起本路径**只探查策略对象结构，不再调用 setPolicies:completion:**，
    //    修复主力是 CoreTelephony C 函数（v1.1.120 补 fine-grained 后已返回 0 全成功）。
    SEL setPolicy = NULL;
    SEL fetchPolicy = NULL; // 用于探查策略对象格式

    // 第一轮：优先 roothide 实际存在的方法，再试其他候选
    NSArray<NSString *> *candidates = @[
        @"setPolicies:completion:",      // roothide iOS 17 实测方法
        @"addPoliciesToCache:",          // roothide 备选
        @"setUsagePoliciesForBundle:cellular:wifi:", // 旧版/iOS 14-16
        @"setUsagePolicyForBundle:cellular:wifi:",
        @"setUsagePoliciesForBundle:cellularPolicy:wifiPolicy:",
        @"setUsagePolicies:forBundle:",
        @"setUsagePolicy:forBundle:",
        @"setCellularDataUsagePolicy:forBundle:",
        @"setAppCellularDataUsagePolicy:forBundleID:",
        @"_setUsagePoliciesForBundle:cellular:wifi:",
    ];
    for (NSString *selName in candidates) {
        SEL s = NSSelectorFromString(selName);
        if ([cache respondsToSelector:s]) {
            setPolicy = s;
            RPVHelperLog(@"fix-cellular(ObjC): 命中候选选择器 %@", selName);

            // 🔴 铁证诊断：打印方法签名的 type encoding，确定参数类型。
            NSMethodSignature *sigDiag = [cache methodSignatureForSelector:s];
            if (sigDiag) {
                NSMutableString *desc = [NSMutableString string];
                for (NSUInteger ai = 0; ai < [sigDiag numberOfArguments]; ai++) {
                    [desc appendFormat:@" arg%lu=%s", (unsigned long)ai,
                        [sigDiag getArgumentTypeAtIndex:ai]];
                }
                RPVHelperLog(@"fix-cellular(ObjC): %@ 签名: 返回=%s%@",
                    selName, [sigDiag methodReturnType], desc);
            }
            break;
        }
    }

    // 🔴 探查方法必须在第一轮就找（原代码只在 dump 分支赋值，导致命中候选后
    //     fetchPolicy 一直为 NULL、探查从未执行——v1.1.121 日志印证）
    for (NSString *selName in @[@"fetchUsagePoliciesFor:", @"fetchUsagePolicyFor:",
                                @"policiesFor:", @"addPoliciesToCache:"]) {
        SEL s = NSSelectorFromString(selName);
        if ([cache respondsToSelector:s]) {
            fetchPolicy = s;
            RPVHelperLog(@"fix-cellular(ObjC): 探查方法可用 %@", selName);
            break;
        }
    }

    // ── 只探查策略对象格式，不调用 setPolicies:completion:（防崩溃）──
    // 拿一个真实策略对象样本，打印其 class / description / 是否响应 bundleId，
    // 为下一版构造正确参数提供铁证。
    id samplePolicy = nil;
    if (fetchPolicy && bundleIDs.count > 0) {
        @try {
            NSString *testBid = bundleIDs.firstObject;
            NSMethodSignature *fsig = [cache methodSignatureForSelector:fetchPolicy];
            NSInvocation *finv = [NSInvocation invocationWithMethodSignature:fsig];
            [finv setTarget:cache];
            [finv setSelector:fetchPolicy];
            if ([fsig numberOfArguments] > 2) [finv setArgument:&testBid atIndex:2];
            [finv retainArguments];
            [finv invoke];
            if (strcmp([fsig methodReturnType], "@") == 0) {
                void *ret = NULL;
                [finv getReturnValue:&ret];
                samplePolicy = (__bridge id)ret;
            }
            RPVHelperLog(@"fix-cellular(ObjC): %s(%@) 返回 %@ (类型:%@)",
                sel_getName(fetchPolicy), testBid, samplePolicy, [samplePolicy class]);

            // 打印策略对象结构：class 名、description、是否响应 bundleId、全部实例方法
            if (samplePolicy) {
                RPVHelperLog(@"fix-cellular(ObjC): 策略对象描述: %@", samplePolicy);
                RPVHelperLog(@"fix-cellular(ObjC): 响应 bundleId=%d cellular=%d wifi=%d",
                    [samplePolicy respondsToSelector:NSSelectorFromString(@"bundleId")],
                    [samplePolicy respondsToSelector:NSSelectorFromString(@"cellular")],
                    [samplePolicy respondsToSelector:NSSelectorFromString(@"wifi")]);
                unsigned int mc = 0;
                Method *methods = class_copyMethodList([samplePolicy class], &mc);
                for (unsigned int i = 0; i < mc && i < 20; i++) {
                    RPVHelperLog(@"fix-cellular(ObjC):   策略对象方法: %s",
                        sel_getName(method_getName(methods[i])));
                }
                free(methods);
            }
        } @catch (NSException *e) {
            RPVHelperLog(@"fix-cellular(ObjC): 探查策略格式异常: %@", e.reason);
        }
    }

    if (!setPolicy) {
        RPVHelperLog(@"fix-cellular(ObjC): PSAppDataUsagePolicyCache 无可用策略设置方法（见上方 dump）");
        return 6;
    }

    RPVHelperLog(@"fix-cellular(ObjC): 🔴 v1.1.122 起不调用 setPolicies:completion:（参数需带 bundleId 的策略对象，字典会崩溃），修复主力为 CoreTelephony C 函数路径");
    return 0;
}

static int RPVHelperFixCellular(NSString *selfBid) {
    RPVHelperLog(@"fix-cellular 开始：枚举应用并重置蜂窝/WiFi 数据策略");

    NSMutableArray<NSString *> *bundleIDs = [NSMutableArray arrayWithArray:RPVHelperEnumerateBundleIDs()];

    // 🔴 自身修复：App 侧显式传入的 bundle id 无条件加入列表并优先处理。
    //    roothide 下 ReSign 装在 jbroot Applications 目录，枚举在 namespace 里
    //    看不到自身（v1.1.122 实测 246 个里没有 com.reprovision.repro）。
    if (selfBid.length > 0) {
        BOOL alreadyIn = [bundleIDs containsObject:selfBid];
        RPVHelperLog(@"fix-cellular: 自身 %@ 枚举到=%d（App 显式传入，无条件加入并优先）",
                     selfBid, alreadyIn);
        [bundleIDs removeObject:selfBid];
        [bundleIDs insertObject:selfBid atIndex:0]; // 放最前，CT 路径第一个设置
    }

    RPVHelperLog(@"fix-cellular: 共 %lu 个应用", (unsigned long)bundleIDs.count);
    if (bundleIDs.count == 0) {
        RPVHelperLog(@"fix-cellular 失败：枚举不到任何应用");
        return 3;
    }

    // ── 三路径都执行（不短路）──
    // ①CoreTelephony C 函数：主路径，v1.1.120 补 fine-grained entitlement 后
    //   246/246 返回码 0（CommCenter 接受），用户实测开关可恢复。
    // ②SettingsCellular setPolicies:completion:：v1.1.122 起只探查不调用（参数需
    //   带 bundleId 的策略对象，字典会崩 -[__NSFrozenDictionaryM bundleId]）。
    // ③AppWirelessDataUsageManager（Preferences.framework）：Renet/Undecimus iOS 11
    //   官方方案，setAppWirelessDataOption:@(3)；iOS 17 已移除该类则自动跳过。
    int ctRet = RPVHelperFixCellularViaCTServer(bundleIDs);
    if (ctRet != 0) {
        RPVHelperLog(@"fix-cellular: CoreTelephony 路径失败(code=%d)", ctRet);
    }
    int objcRet = RPVHelperFixCellularViaSettingsCellular(bundleIDs);
    if (objcRet != 0) {
        RPVHelperLog(@"fix-cellular: SettingsCellular 路径失败(code=%d)", objcRet);
    }
    RPVHelperFixCellularViaAppWirelessDataUsageManager(bundleIDs);

    RPVHelperRestartSpringBoard();
    RPVHelperLog(@"fix-cellular 完成");
    return 0;
}

#pragma mark - 入口

static void RPVHelperPrintUsage(void) {
    fprintf(stderr,
            "repro-helper —— ReSign 按需 root 助手\n"
            "用法:\n"
            "  repro-helper copy <源路径> <目标路径>\n"
            "  repro-helper install-profile <描述文件路径>\n");
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

        // fix-cellular = App「设置」里「修复越狱联网问题」手动入口（仅手动，无 daemon 自动循环）。
        // 重置全部应用蜂窝/WiFi 数据策略为「始终允许」并重启 SpringBoard 生效。
        if ([command isEqualToString:@"fix-cellular"]) {
            if (argc < 2 || argc > 3) {
                RPVHelperPrintUsage();
                return 64;
            }
            // v1.1.126：用户要求隐藏修复联网日志（不美观）→ 全程静默，只留退出码。
            gHelperSilent = YES;

            // 🔴 续签互斥兜底：若续签 trigger 文件新鲜（180 秒内刚发起过续签，
            // 说明 App 正在后台签名），直接跳过修复（exit 0）——killall SpringBoard
            // 会杀掉正在签名的 App，续签半途而废甚至损坏。App 上层已判断过，这里兜底防
            // 手动点击/时序竞态。修复可延后，续签中断不可恢复。
            {
                NSDictionary *trigger = [NSDictionary dictionaryWithContentsOfFile:
                    @"/var/mobile/Library/RePro/auto-resign-trigger"];
                NSTimeInterval ts = trigger ? [trigger[@"timestamp"] doubleValue] : 0;
                if (ts > 0 && (time(NULL) - (time_t)ts) < 180) {
                    return 0; // 🔇 静默跳过（不写时间戳，后续仍可触发修复）
                }
            }

            // argv[2] = ReSign 自身 bundle id（App 侧传入）。roothide 下 ReSign 装在
            // jbroot Applications 目录，枚举在 namespace 里看不到自身 → 由 App 显式
            // 传入，helper 无条件加入修复列表并优先处理。
            NSString *selfBid = (argc == 3) ? [NSString stringWithUTF8String:argv[2]] : nil;
            return RPVHelperFixCellular(selfBid);
        }

        RPVHelperLog(@"未知命令: %@", command);
        RPVHelperPrintUsage();
        return 64;
    }
}
