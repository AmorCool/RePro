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
#include <fcntl.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <sys/utsname.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <mach-o/dyld.h>   // _NSGetExecutablePath：v1.1.183 推算自身所在越狱根

// 系统描述文件库的命名/去重/清单/删除，与 repro-profiledaemon 共用同一份实现。
// v1.1.171：helper 过去用「描述文件内容 SHA1」当文件名，每次重签内容都变 → 每次都新增
// 一份 → 同一个 application-identifier 在库里堆几十上百份，profiled 挑中旧的那份去校验
// 新签的 App → installd 报 0xe8008015、App 秒退（实测一台设备堆到 163 份只对应 3 个 App）。
// 改用 sha1(application-identifier) 稳定名覆盖写，并在安装后跑一次去重清理，从源头杜绝堆积。
#import "RPVProfileStore.h"

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
/// v1.1.171：不再找 killall——真实 rootfs（RootHide 的 /rootfs）里根本没有这个二进制，
/// killall 只存在于 jbroot，helper 若脱离 overlay 就永远命中不到。统一走 RPVPSNudgeProfiled：
/// sysctl(KERN_PROC_ALL) 枚举进程后直接 kill(pid, SIGHUP)，纯系统调用、零外部依赖。
/// 发送后短暂等待，给 profiled 完成重新加载的时间。
static void RPVHelperRefreshProfiled(void) {
    RPVPSNudgeProfiled();
    usleep(400000);
}

#pragma mark - 写描述文件到指定目录

/// 把 profile 写到 dir/<稳定名>.mobileprovision（dir 不存在则创建），返回是否成功。
/// v1.1.171：文件名改成按 application-identifier 派生的稳定名后，同一个 App 每次重签都是
/// **同一个文件名**，因此这里必须「先删后写」覆盖旧内容——原来的 `if (!fileExists)` 会把
/// 新签的描述文件直接丢掉，留下过期的旧内容，照样 0xe8008015。
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
    if ([fm fileExistsAtPath:dest]) {
        [fm removeItemAtPath:dest error:nil];
    }
    if (![fm copyItemAtPath:profilePath toPath:dest error:&error]) {
        RPVHelperLog(@"描述文件复制失败 %@: %@", dest, error);
        return NO;
    }
    [fm setAttributes:@{NSFilePosixPermissions          : @(0644),
                        NSFileOwnerAccountName          : @"root",
                        NSFileGroupOwnerAccountName     : @"wheel"}
             ofItemAtPath:dest
                    error:nil];
    return YES;
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

    // 文件名 = sha1(application-identifier)，同一个 App 无论重签多少次都落到同一个文件名，
    // 直接覆盖旧内容 → 库里每个 App ID 永远只有一份。解析不出 App ID 时（理论上不会）
    // 退回内容 SHA1，至少保证能写进去。
    NSString *appId = RPVPSAppIdOfPlist(RPVPSPlistOfData(data));
    NSString *fileName = RPVPSStableNameForData(data);
    if (fileName.length == 0) {
        RPVHelperLog(@"警告：解析不出 application-identifier，回退用内容 SHA1 命名");
        fileName = [RPVPSSha1OfData(data) stringByAppendingPathExtension:@"mobileprovision"];
    }
    if (fileName.length == 0) {
        RPVHelperLog(@"描述文件命名失败");
        return 4;
    }

    // v1.1.173：重新启用「写入真实 rootfs 路径」——但本次走的是明确的
    // /rootfs/private/var/Managed Preferences/mobile（不是含糊的「jbroot 物理视图」），
    // 并由 RPVPSManagedPrefsDirs() 按 realpath 去重。原因：v1.1.171 删掉双写是基于
    // 「profiledaemon 永远跑真实 rootfs」的假设；实测有设备 daemon 跑在 jbroot 命名空间，
    // 其 /var/Managed Preferences/mobile 是 overlay 假目录，真实 rootfs 那份永远空着 →
    // profiled/installd 读不到 → 设置无描述文件、目标 App 0xe8008015 秒退。明确写真实
    // rootfs 路径即可根治，且配合稳定名 + 去重绝不会堆积。
    // 注意：rootless/rootful 下 /rootfs/... 不存在，RPVPSManagedPrefsDirs 只会返回
    // /var/... 一个目录，行为与 v1.1.171 一致，无副作用。
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL okMain = YES;
    NSMutableString *writtenTo = [NSMutableString string];
    for (NSString *directory in RPVPSManagedPrefsDirs()) {
        NSString *destination = [directory stringByAppendingPathComponent:fileName];
        if (RPVHelperWriteProfileToDir(data, fileName, directory, profilePath)) {
            [writtenTo appendFormat:@" %@", destination];
        } else {
            okMain = NO;
        }
    }
    RPVHelperLog(@"写入（App ID: %@）：%@ %@", appId ?: @"(未知)", writtenTo, okMain ? @"成功" : @"部分失败");

    // 注意：RootHide 下描述文件的主注册已由 App 进程自身经 MCProfileConnection 完成
    // （App 带 profiled-access，以 mobile 身份调 MC 落【本地库】，与能正常工作的 test2源码
    //  完全一致；installd 的 AllowInstallLocalProvisioned 查的正是本地库）。
    // 本 helper 不再自己调 MC：早期版本让 root+no-sandbox 的 helper 调 MC，结果同一份
    //  profile 被注册进 managed(MSM) 库（installd 不认）→ 0xe8008015；且 managed 注册会
    //  覆盖 App 在本地库的注册，反而把 installd 能读到的副本抹掉。故 helper 只做文件兜底层。

    // 安装后立刻去重：删掉过期/损坏的，以及同一个 App ID 的历史重复份
    //（老版本留下的内容 SHA1 命名文件就是在这一步被清掉的）。
    // 只处理 *.mobileprovision，系统自带的 com.apple.*.plist 一律不碰。
    NSString *cleanupSummary = RPVPSCleanup();
    if (cleanupSummary.length > 0) {
        RPVHelperLog(@"描述文件库清理：%@", cleanupSummary);
    }

    // 踢一下 profiled 让它立刻重新扫描（sysctl 枚举后直发 SIGHUP，不依赖任何外部二进制）。
    RPVHelperRefreshProfiled();

    // 取证诊断：清理后目录里还剩多少份，以及本文件是否确实在位。
    NSString *primaryDir = RPVPSManagedPrefsDir;
    NSString *primaryDest = [primaryDir stringByAppendingPathComponent:fileName];
    NSError *lsErr = nil;
    NSArray *existing = [fileManager contentsOfDirectoryAtPath:primaryDir error:&lsErr];
    if (lsErr) {
        RPVHelperLog(@"读取描述文件目录失败 %@: %@", primaryDir, lsErr);
    } else {
        NSUInteger profileCount = 0;
        for (NSString *n in existing) {
            if ([n.pathExtension isEqualToString:@"mobileprovision"]) profileCount++;
        }
        RPVHelperLog(@"清理后目录现有 %lu 份描述文件；本文件在位：%@",
                     (unsigned long)profileCount,
                     [fileManager fileExistsAtPath:primaryDest] ? @"是" : @"否");
    }

    if (okMain) {
        RPVHelperLog(@"描述文件已安装：%@", writtenTo);
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

#pragma mark - 描述文件管理（App「管理描述文件」界面用）

/// v1.1.171：rootless / rootful 下没有 repro-profiledaemon（它只在 RootHide 包里装），
/// App 的「管理描述文件」界面不能只靠 daemon IPC，否则这两套包上界面永远转圈。
/// 这三个子命令让 App 直接同步拉起 setuid root 的 helper 完成同样的事——
/// 逻辑与 daemon 完全一致（都调 RPVProfileStore.h 里的同一份实现），不会出现行为分歧。

/// 结果文件路径与 daemon 用的是同一个，App 侧读取逻辑因此完全一致，不必分两套。
static NSString *const kRPVHelperManageResultPath =
    @"/var/mobile/Library/RePro/profile-manage-result";

/// 把一次管理操作的结果串写给 App（root 写出的文件要 chown 回 mobile，App 才好读/删）。
static void RPVHelperWriteManageResult(NSString *summary) {
    if (summary.length == 0) summary = @"无操作";
    NSString *dir = [kRPVHelperManageResultPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    [summary writeToFile:kRPVHelperManageResultPath atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @(0644),
                                                    NSFileOwnerAccountID   : @(501),
                                                    NSFileGroupOwnerAccountID : @(501)}
                                     ofItemAtPath:kRPVHelperManageResultPath
                                            error:nil];
}

/// 导出描述文件库清单到 outPath（plist）。
static int RPVHelperProfilesInventory(NSString *outPath) {
    if (outPath.length == 0) {
        RPVHelperLog(@"profiles-inventory 缺少输出路径");
        return 2;
    }
    NSUInteger n = RPVPSWriteInventory(outPath);
    RPVHelperLog(@"profiles-inventory: 已导出 %lu 项 → %@", (unsigned long)n, outPath);
    return 0;
}

/// 去重清理：删过期/损坏的，以及同一 application-identifier 的历史重复份。
static int RPVHelperProfilesCleanup(void) {
    NSString *summary = RPVPSCleanup();
    RPVHelperLog(@"profiles-cleanup: %@", summary.length ? summary : @"无可清理项");
    RPVHelperWriteManageResult(summary);
    RPVHelperRefreshProfiled();
    return 0;
}

/// 按文件名删除。listPath 是一个文本文件，每行一个文件名（不含路径）。
/// 文件名合法性由 RPVPSDeleteNames 统一校验（不含 /、非 . 开头、必须 .mobileprovision 后缀），
/// 防路径穿越，也保证系统自带的 com.apple.*.plist 绝不会被误删。
static int RPVHelperProfilesDelete(NSString *listPath) {
    if (listPath.length == 0) {
        RPVHelperLog(@"profiles-delete 缺少清单路径");
        return 2;
    }
    NSString *content = [NSString stringWithContentsOfFile:listPath encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) {
        RPVHelperLog(@"profiles-delete 清单为空: %@", listPath);
        return 3;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) [names addObject:t];
    }
    NSString *summary = RPVPSDeleteNames(names);
    RPVHelperLog(@"profiles-delete: %@", summary.length ? summary : @"无操作");
    RPVHelperWriteManageResult(summary);
    RPVHelperRefreshProfiled();
    return 0;
}

#pragma mark - 入口

static void RPVHelperPrintUsage(void) {
    fprintf(stderr,
            "repro-helper —— ReSign 按需 root 助手\n"
            "用法:\n"
            "  repro-helper copy <源路径> <目标路径>\n"
            "  repro-helper install-profile <描述文件路径>\n"
            "  repro-helper fix-cellular <当前插件 bundle id>\n"
            "  repro-helper profiles-inventory <输出 plist 路径>\n"
            "  repro-helper profiles-cleanup\n"
            "  repro-helper profiles-delete <文件名清单路径，每行一个>\n"
            "  repro-helper reboot-device\n"
            "  repro-helper userspace-reboot\n"
            "  repro-helper kickstart-lsd\n"
            "  repro-helper rebuild-icon-cache [App 包路径]\n"
            "  repro-helper kickstart-profiledaemon [-k]\n"
            "  repro-helper uicache <uicache 原生参数…>\n");
}

#pragma mark - 重启 / 用户空间重启 / uicache（v1.1.181 工具菜单）

/// XPC 类型（xpc_connection_t / xpc_object_t / xpc_handler_t）由 SDK 的 xpc/xpc.h 提供
/// （经 Foundation 引入），此处不再重复定义；函数一律经 dlsym 取指针，避免链接期耦合。

#pragma mark - 越狱工具路径解析（v1.1.183）

/// 🔴 v1.1.183 真机日志实证（repro_log_1785977443）：
///   `launchctl kickstart spawn 失败: 2`（2 = ENOENT）。
///   同一份日志里 helper 自身的路径是
///   /var/containers/Bundle/Application/.jbroot-D625DCA8D846BAA3/usr/libexec/repro-helper
///   —— **带完整 jbroot 前缀**。这说明 RootHide 进程内并没有把 /usr/bin 透明重定向到
///   jbroot，所以代码里写死的 "/usr/bin/launchctl"、"/usr/bin/uicache" 在 RootHide 下
///   指向的是真实 rootfs，而真实 rootfs 根本没有这些越狱工具，必然 ENOENT。
///
/// 本函数取 helper 自身所在的「越狱根」。helper 的安装位置固定为
/// <root>/usr/libexec/repro-helper，把自身绝对路径去掉三级即得 <root>：
///   RootHide → /var/containers/Bundle/Application/.jbroot-XXXX
///   Dopamine → /var/jb
///   rootful  → /
static NSString *RPVHelperSelfRoot(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char buf[PATH_MAX] = {0};
        uint32_t size = (uint32_t)sizeof(buf);
        if (_NSGetExecutablePath(buf, &size) != 0) return;
        char resolved[PATH_MAX] = {0};
        const char *use = realpath(buf, resolved) ? resolved : buf;
        NSString *path = [NSString stringWithUTF8String:use];
        if (path.length == 0) return;
        // .../usr/libexec/repro-helper → 依次去掉 repro-helper、libexec、usr
        NSString *root = path.stringByDeletingLastPathComponent
                             .stringByDeletingLastPathComponent
                             .stringByDeletingLastPathComponent;
        if (root.length > 0) cached = [root copy];
    });
    return cached;
}

/// 在所有可能的 bootstrap 位置里找一个可执行的越狱工具，找不到返回 nil。
/// 探测顺序：自身越狱根（RootHide 随机 jbroot / Dopamine /var/jb / rootful /）
/// → /var/jb → 真实根。用 access(X_OK) 而不是 NSFileManager，RootHide 下更可靠。
static NSString *RPVHelperResolveTool(NSString *name) {
    if (name.length == 0) return nil;

    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *selfRoot = RPVHelperSelfRoot();
    if (selfRoot.length > 0) [roots addObject:selfRoot];
    for (NSString *r in @[ @"/var/jb", @"/" ]) {
        if (![roots containsObject:r]) [roots addObject:r];
    }

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *root in roots) {
        for (NSString *sub in @[ @"usr/bin", @"bin", @"usr/sbin", @"sbin", @"usr/local/bin" ]) {
            NSString *p = [[root stringByAppendingPathComponent:sub]
                           stringByAppendingPathComponent:name];
            if (![candidates containsObject:p]) [candidates addObject:p];
        }
    }

    for (NSString *p in candidates) {
        if (access([p fileSystemRepresentation], X_OK) == 0) {
            RPVHelperLog(@"工具 %@ → %@", name, p);
            return p;
        }
    }
    RPVHelperLog(@"未找到工具 %@（已尝试：%@）", name,
                 [candidates componentsJoinedByString:@", "]);
    return nil;
}

/// 重启设备（移植自 RebootTools/RebootRootHelper）。
/// 必须在 root 下执行（本工具已是 setuid 4755），reboot(0) 一句即可。
static int RPVHelperRebootDevice(void) {
    RPVHelperLog(@"reboot device");
    sync();
    reboot(0);
    return 0; // 不会到达
}

/// 重启用户空间（移植自 RebootTools/RebootUserSpaceHelper）。
/// 步骤：①unlink MemoryMaintenance 状态文件（否则不会重启）；②动态加载 libxpc，
/// 向 com.apple.mmaintenanced 发 {cmd:5} XPC 消息触发用户态重启。
static int RPVHelperRebootUserSpace(void) {
    RPVHelperLog(@"reboot userspace");

    struct utsname uts;
    uname(&uts);
    if (atoi(uts.release) >= 21) {
        unlink("/private/var/mobile/Library/MemoryMaintenance/mmaintenanced");
    } else {
        unlink("/private/var/db/mmaintenanced");
    }

    void *lib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY);
    if (!lib) {
        RPVHelperLog(@"userspace-reboot: dlopen libxpc 失败: %s", dlerror());
        return -1;
    }

    xpc_connection_t (*p_xpc_connection_create_mach_service)(const char *, dispatch_queue_t, uint64_t) =
        dlsym(lib, "xpc_connection_create_mach_service");
    xpc_object_t (*p_xpc_dictionary_create)(const char *const *, const xpc_object_t *, size_t) =
        dlsym(lib, "xpc_dictionary_create");
    void (*p_xpc_dictionary_set_uint64)(xpc_object_t, const char *, uint64_t) =
        dlsym(lib, "xpc_dictionary_set_uint64");
    void (*p_xpc_connection_set_event_handler)(xpc_connection_t, xpc_handler_t) =
        dlsym(lib, "xpc_connection_set_event_handler");
    void (*p_xpc_connection_resume)(xpc_connection_t) =
        dlsym(lib, "xpc_connection_resume");
    xpc_object_t (*p_xpc_connection_send_message_with_reply_sync)(xpc_connection_t, xpc_object_t) =
        dlsym(lib, "xpc_connection_send_message_with_reply_sync");

    if (!p_xpc_connection_create_mach_service ||
        !p_xpc_dictionary_create ||
        !p_xpc_dictionary_set_uint64 ||
        !p_xpc_connection_set_event_handler ||
        !p_xpc_connection_resume ||
        !p_xpc_connection_send_message_with_reply_sync) {
        RPVHelperLog(@"userspace-reboot: dlsym 缺失符号");
        dlclose(lib);
        return -1;
    }

    xpc_connection_t conn = p_xpc_connection_create_mach_service("com.apple.mmaintenanced", NULL, 0);
    if (!conn) {
        RPVHelperLog(@"userspace-reboot: 创建 mmaintenanced 连接失败");
        dlclose(lib);
        return -1;
    }

    p_xpc_connection_set_event_handler(conn, ^(xpc_object_t event){});
    p_xpc_connection_resume(conn);

    xpc_object_t msg = p_xpc_dictionary_create(NULL, NULL, 0);
    p_xpc_dictionary_set_uint64(msg, "cmd", 5);
    p_xpc_connection_send_message_with_reply_sync(conn, msg);

    dlclose(lib);
    return 0; // 发送后即触发重启，通常不再返回
}

/// 透传参数调用设备端 uicache 重建/注册图标。
/// 用法：repro-helper uicache <uicache 的原生参数…>
///   uicache -a                           重建全部图标缓存
///   uicache -p /Applications/ReSign.app  重新注册单个 App
///
/// v1.1.182：RootHide 下 uicache 退出码 1 是已知问题（命令内部读 /var/containers
/// 受 namespace 限制）。App 侧「重建图标缓存」改用 kickstart-lsd；uicache 子命令
/// 仍保留给「重新注册 App」用，但 stderr 重定向到 /var/mobile/Library/RePro/uicache.stderr.log
/// —— 失败时用户能在 RePro 日志面板看到真因。
static int RPVHelperRunUicache(int argc, char *argv[]) {
    // v1.1.183：改用统一的越狱工具解析（含 RootHide 随机 jbroot），
    // 旧版只试 /usr/bin 与 /var/jb/usr/bin，RootHide 下两处都没有 → 直接 2。
    NSString *uicache = RPVHelperResolveTool(@"uicache");
    if (uicache.length == 0) {
        return 2;
    }

    // 收集 uicache 的原生参数（跳过 argv[0]=repro-helper、argv[1]=uicache）
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 2; i < argc; i++) {
        [args addObject:[NSString stringWithUTF8String:argv[i]]];
    }

    NSUInteger count = args.count;
    const char **cargs = (const char **)calloc(count + 2, sizeof(char *));
    if (!cargs) return -1;
    cargs[0] = [uicache UTF8String];
    for (NSUInteger i = 0; i < count; i++) {
        cargs[i + 1] = [args[i] UTF8String];
    }
    cargs[count + 1] = NULL;

    pid_t pid = 0;

    // 重定向 stderr 到日志文件以便诊断
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 2,
        "/var/mobile/Library/RePro/uicache.stderr.log",
        O_WRONLY | O_CREAT | O_TRUNC, 0644);

    int rc = posix_spawn(&pid, [uicache UTF8String], &actions, NULL, (char *const *)cargs, NULL);
    posix_spawn_file_actions_destroy(&actions);
    free(cargs);
    if (rc != 0) {
        RPVHelperLog(@"uicache 启动失败: %d", rc);
        return rc;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    RPVHelperLog(@"uicache exit=%d (%@)，stderr 已写入 /var/mobile/Library/RePro/uicache.stderr.log",
                 exitCode, [args componentsJoinedByString:@" "]);
    return exitCode;
}

/// v1.1.184：在指定服务标识上跑一次 `launchctl kickstart [-k] <target>`，返回退出码。
/// stderr 落到 uicache.stderr.log，方便真机上看到 launchctl 的真实抱怨。
static int RPVHelperLaunchctlKickstart(NSString *launchctlPath,
                                       const char *serviceTarget,
                                       BOOL forceKill) {
    const char *lc = [launchctlPath fileSystemRepresentation];

    // 透传 PATH 给 launchctl，免得 launchctl 自己找不到 PATH 下的工具。
    char *env[] = {
        "PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin",
        "HOME=/var/root",
        NULL
    };
    const char *argvKill[] = { lc, "kickstart", "-k", serviceTarget, NULL };
    const char *argvSoft[] = { lc, "kickstart", serviceTarget, NULL };
    const char **args = forceKill ? argvKill : argvSoft;

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 2,
        "/var/mobile/Library/RePro/uicache.stderr.log",
        O_WRONLY | O_CREAT | O_APPEND, 0644);
    int rc = posix_spawn(&pid, lc, &actions, NULL, (char *const *)args, env);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        RPVHelperLog(@"launchctl kickstart %s spawn 失败: %d", serviceTarget, rc);
        return -1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/// v1.1.184：重启 com.apple.lsd（图标/UTI 数据库服务）。
///
/// 🔴 真机实测（iPhone12,1 / iOS 17.2 / RootHide）——这就是「重建图标缓存显示成功却没反应」的真因：
///   `launchctl kickstart -k system/com.apple.lsd`
///     → 输出 "Please switch to user/foreground/com.apple.lsd service identifier"
///     → **退出码仍然是 0**！所以旧代码一路报「成功」，lsd 却从来没被重启过。
///   `launchctl kickstart -k user/foreground/com.apple.lsd`  → 退出码 0 且真的重启。
///
/// iOS 17 起 lsd 从 system 域搬到了 user/foreground 域，因此候选顺序必须是
/// user/foreground → user/501 → system（最后一个只为兼容老系统）。
static int RPVHelperKickstartLSD(void) {
    NSString *launchctl = RPVHelperResolveTool(@"launchctl");
    if (launchctl.length == 0) {
        RPVHelperLog(@"kickstart-lsd: 找不到 launchctl");
        return 2;
    }

    // ⚠️ system 域放最后：它在 iOS 17+ 上返回 0 却什么也没干，先试会误判成功。
    const char *targets[] = {
        "user/foreground/com.apple.lsd",
        "user/501/com.apple.lsd",
        "system/com.apple.lsd",
    };
    for (int i = 0; i < 3; i++) {
        int code = RPVHelperLaunchctlKickstart(launchctl, targets[i], YES);
        RPVHelperLog(@"kickstart %s exit=%d", targets[i], code);
        if (code == 0) {
            // user/foreground 与 user/501 成功即可确信真的重启了；
            // system 域成功属于老系统路径，同样认可。
            return 0;
        }
    }
    RPVHelperLog(@"kickstart-lsd: 三个域全部失败");
    return 1;
}

/// v1.1.184：结束 SpringBoard 进程（respring）。
/// 不依赖 killall（真实 rootfs 没有这个二进制），走 sysctl(KERN_PROC_ALL)+KERN_PROCARGS2
/// 枚举进程再 kill(SIGTERM)，与 App 侧 RPVBridge -respring 同一套实现。
static BOOL RPVHelperKillSpringBoard(void) {
    int maxArgumentSize = 0;
    size_t size = sizeof(maxArgumentSize);
    if (sysctl((int[]){ CTL_KERN, KERN_ARGMAX }, 2, &maxArgumentSize, &size, NULL, 0) == -1) {
        maxArgumentSize = 4096;
    }

    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    struct kinfo_proc *info = NULL;
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) < 0) return NO;
    if (!(info = malloc(length))) return NO;
    if (sysctl(mib, 3, info, &length, NULL, 0) < 0) {
        free(info);
        return NO;
    }

    int count = (int)(length / sizeof(struct kinfo_proc));
    BOOL found = NO;
    for (int i = 0; i < count && !found; i++) {
        pid_t pid = info[i].kp_proc.p_pid;
        if (pid <= 0) continue;

        size_t argSize = (size_t)maxArgumentSize;
        char *buffer = malloc((size_t)maxArgumentSize);
        if (!buffer) continue;
        if (sysctl((int[]){ CTL_KERN, KERN_PROCARGS2, pid }, 3, buffer, &argSize, NULL, 0) == 0) {
            NSString *exe = [NSString stringWithUTF8String:(buffer + sizeof(int))];
            if ([exe.lastPathComponent isEqualToString:@"SpringBoard"]) {
                kill(pid, SIGTERM);
                RPVHelperLog(@"respring: 已向 SpringBoard(pid=%d) 发送 SIGTERM", pid);
                found = YES;
            }
        }
        free(buffer);
    }
    free(info);
    if (!found) RPVHelperLog(@"respring: 未找到 SpringBoard 进程");
    return found;
}

/// v1.1.184：真正能看到效果的「重建图标缓存」。
///
/// 之前失败的两种做法各自的问题：
///   ① `uicache -a` —— 退出码 0，但真机上 /var/mobile/Library/Caches/com.apple.springboard/
///      连 Cache.db 都没有重新生成，桌面毫无变化（用户原话「显示操作成功是骗人的」）。
///   ② `kickstart -k system/com.apple.lsd` —— iOS 17+ 直接被 launchctl 拒绝（见上）。
///
/// 正确顺序（缺一不可）：
///   1. uicache -a       让 lsd 重新扫描所有 .app 并写入数据库
///   2. kickstart -k lsd 强制 lsd 重启并落盘（user/foreground 域）
///   3. respring         SpringBoard 重启后才会从 lsd 重新拉图标 —— 桌面这时才变
///
/// bundlePath 为空 → `uicache -a`（重建全部）；非空 → `uicache -p <path>`（只重注册一个 App）。
static int RPVHelperRebuildIconCache(NSString *bundlePath) {
    BOOL single = (bundlePath.length > 0);
    RPVHelperLog(@"rebuild-icon-cache: 开始（uicache %@ → kickstart lsd → respring）",
                 single ? [@"-p " stringByAppendingString:bundlePath] : @"-a");

    // 1. uicache
    NSString *uicache = RPVHelperResolveTool(@"uicache");
    if (uicache.length > 0) {
        const char *uc = [uicache fileSystemRepresentation];
        const char *args[] = { uc,
                               single ? "-p" : "-a",
                               single ? [bundlePath fileSystemRepresentation] : NULL,
                               NULL };
        pid_t pid = 0;
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addopen(&actions, 2,
            "/var/mobile/Library/RePro/uicache.stderr.log",
            O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (posix_spawn(&pid, uc, &actions, NULL, (char *const *)args, NULL) == 0) {
            int status = 0;
            waitpid(pid, &status, 0);
            RPVHelperLog(@"uicache %@ exit=%d", single ? @"-p" : @"-a",
                         WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        } else {
            RPVHelperLog(@"uicache spawn 失败");
        }
        posix_spawn_file_actions_destroy(&actions);
    } else {
        RPVHelperLog(@"rebuild-icon-cache: 找不到 uicache，跳过第 1 步");
    }

    // 2. 重启 lsd
    int lsd = RPVHelperKickstartLSD();

    // 3. respring —— 桌面视觉变化只在这一步之后才会出现
    sleep(1);
    BOOL sb = RPVHelperKillSpringBoard();

    RPVHelperLog(@"rebuild-icon-cache: 完成（lsd=%d respring=%@）", lsd, sb ? @"YES" : @"NO");
    // lsd 重启成功或 SpringBoard 已重启，任一成立就算成功
    return (lsd == 0 || sb) ? 0 : 1;
}

/// v1.1.183：以 root 身份唤醒 repro-profiledaemon。
///
/// 🔴 为什么必须由 helper 来做，而不是 App 自己 spawn launchctl：
///   ① 路径：App/helper 都看不到「真实 rootfs 的 launchctl」，只有越狱 bootstrap
///      里才有一份，RootHide 下还带随机 jbroot 前缀 —— 必须探测（同 kickstart-lsd）。
///   ② 权限：profiledaemon 由 postinst 用 `bootstrap system` 加载在 **system 域**，
///      而 App 是 uid 501(mobile)，`launchctl kickstart system/...` 会被拒（EPERM）。
///      helper 是 setuid root，才真正有资格 kickstart 系统域的 job。
///   这两点叠加，导致 App 侧的 RPVKickstartProfileDaemonEx() 从引入起就是个静默空操作，
///   描述文件安装/删除全靠 plist 里的 notifyd LaunchEvents 兜底 —— 一旦通知投递
///   落在 daemon「即将退出」的窗口里，就表现为 App 干等 60 秒报「root 侧未响应」。
///
/// force=YES 用 `kickstart -k`（先杀再拉，仅用于确认 daemon 已卡死的兜底）；
/// force=NO 是软唤醒（活着就不动它，让它把活干完）——见 v1.1.180 的血泪教训。
static int RPVHelperKickstartProfileDaemon(BOOL force) {
    NSString *launchctl = RPVHelperResolveTool(@"launchctl");
    if (launchctl.length == 0) {
        return 2;
    }
    const char *lc = [launchctl fileSystemRepresentation];

    // roothide 把 jbroot 下的 LaunchDaemons 加载在 system 域（postinst 用的是
    // `bootstrap system`）；历史上也出现过挂在 user/501 的情况，两个域都试一次。
    const char *domains[] = { "system/jp.soh.reprovision.profiledaemon",
                              "user/501/jp.soh.reprovision.profiledaemon" };
    for (int d = 0; d < 2; d++) {
        const char *argvKill[] = { lc, "kickstart", "-k", domains[d], NULL };
        const char *argvSoft[] = { lc, "kickstart", domains[d], NULL };
        const char **args = force ? argvKill : argvSoft;

        pid_t pid = 0;
        if (posix_spawn(&pid, lc, NULL, NULL, (char *const *)args, NULL) != 0) {
            continue;
        }
        int status = 0;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
            RPVHelperLog(@"kickstart profiledaemon 成功（%s%@）",
                         domains[d], force ? @", 强制重启" : @"");
            return 0;
        }
    }
    RPVHelperLog(@"kickstart profiledaemon 失败（system 与 user/501 两个域均未成功）");
    return 1;
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

        // 描述文件管理三件套（App「设置 → 管理描述文件」界面在 rootless/rootful 下走这里）
        if ([command isEqualToString:@"profiles-inventory"]) {
            if (argc != 3) {
                RPVHelperPrintUsage();
                return 64;
            }
            return RPVHelperProfilesInventory([NSString stringWithUTF8String:argv[2]]);
        }

        if ([command isEqualToString:@"profiles-cleanup"]) {
            if (argc != 2) {
                RPVHelperPrintUsage();
                return 64;
            }
            return RPVHelperProfilesCleanup();
        }

        if ([command isEqualToString:@"profiles-delete"]) {
            if (argc != 3) {
                RPVHelperPrintUsage();
                return 64;
            }
            return RPVHelperProfilesDelete([NSString stringWithUTF8String:argv[2]]);
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

        // v1.1.181：系统状态页工具菜单用。reboot/userspace-reboot 来自 RebootTools，
        // uicache 来自 TrollStoreLite 系用法（重建图标缓存 / 重新注册 App）。
        // v1.1.182：加 kickstart-lsd，替代 uicache -a（RootHide 下后者退出码 1）。
        if ([command isEqualToString:@"reboot-device"]) {
            return RPVHelperRebootDevice();
        }

        if ([command isEqualToString:@"userspace-reboot"]) {
            return RPVHelperRebootUserSpace();
        }

        if ([command isEqualToString:@"uicache"]) {
            return RPVHelperRunUicache(argc, argv);
        }

        if ([command isEqualToString:@"kickstart-lsd"]) {
            return RPVHelperKickstartLSD();
        }

        // v1.1.184：真正生效的「重建图标缓存 / 重新注册 App」。
        //   rebuild-icon-cache                 → uicache -a  + 重启 lsd + respring
        //   rebuild-icon-cache /path/to/X.app  → uicache -p X + 重启 lsd + respring
        if ([command isEqualToString:@"rebuild-icon-cache"]) {
            NSString *bundlePath = (argc >= 3) ? [NSString stringWithUTF8String:argv[2]] : nil;
            return RPVHelperRebuildIconCache(bundlePath);
        }

        // v1.1.183：以 root 唤醒 profiledaemon（App 是 mobile，kickstart 系统域会被拒）。
        if ([command isEqualToString:@"kickstart-profiledaemon"]) {
            BOOL force = (argc >= 3 && strcmp(argv[2], "-k") == 0);
            return RPVHelperKickstartProfileDaemon(force);
        }

        RPVHelperLog(@"未知命令: %@", command);
        RPVHelperPrintUsage();
        return 64;
    }
}
