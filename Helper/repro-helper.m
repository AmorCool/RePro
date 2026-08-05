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
#include <sys/utsname.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>

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
            "  repro-helper uicache <uicache 原生参数…>\n");
}

#pragma mark - 重启 / 用户空间重启 / uicache（v1.1.181 工具菜单）

/// XPC 私有类型自前向声明，避免引入 xpc.h 的可用性告警；函数一律经 dlsym 取指针。
typedef struct _xpc_connection_s *xpc_connection_t;
typedef struct _xpc_object_s *xpc_object_t;
typedef void (^xpc_handler_t)(xpc_object_t);

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
static int RPVHelperRunUicache(int argc, char *argv[]) {
    static NSString *const kCandidatePaths[] = {
        @"/usr/bin/uicache", @"/var/jb/usr/bin/uicache", nil
    };
    NSString *uicache = nil;
    for (NSString *p in kCandidatePaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { uicache = p; break; }
    }
    if (uicache.length == 0) {
        RPVHelperLog(@"uicache 未找到（已尝试 /usr/bin、/var/jb/usr/bin）");
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
    int rc = posix_spawn(&pid, [uicache UTF8String], NULL, NULL, (char *const *)cargs, NULL);
    free(cargs);
    if (rc != 0) {
        RPVHelperLog(@"uicache 启动失败: %d", rc);
        return rc;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    RPVHelperLog(@"uicache exit=%d (%@)", exitCode, [args componentsJoinedByString:@" "]);
    return exitCode;
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
        if ([command isEqualToString:@"reboot-device"]) {
            return RPVHelperRebootDevice();
        }

        if ([command isEqualToString:@"userspace-reboot"]) {
            return RPVHelperRebootUserSpace();
        }

        if ([command isEqualToString:@"uicache"]) {
            return RPVHelperRunUicache(argc, argv);
        }

        RPVHelperLog(@"未知命令: %@", command);
        RPVHelperPrintUsage();
        return 64;
    }
}
