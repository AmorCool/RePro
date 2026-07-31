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

/// NSLog 在 iOS 命令行工具里同时写 stderr 和系统日志，
/// App 侧把 stderr 重定向到临时文件即可拿到完整诊断。
static void RPVHelperLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RPVHelperLog(NSString *format, ...) {
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

#pragma mark - 经 MCProfileConnection 注册到真实 profiled

/// 通过 ManagedConfiguration 的 MCProfileConnection XPC 把描述文件注册进系统 profile 库。
/// 关键：本工具以 root 运行且 entitlement 含 platform-application+no-sandbox，
/// 因此它的 MCProfileConnection 调用走的是「真实系统 profiled」（未被 RootHide 的沙箱
/// 重定向到 overlay）；注册成功后 installd 的 MIS 在代码签名校验时就能查到这份 profile。
/// 相比之下 App 进程是 sandboxed mobile，其 MCProfileConnection 会被 RootHide 拦截重定向
/// 到 overlay 库 —— 这就是之前「注册成功却仍 0xe8008015」的根因。
/// 返回：注册是否成功（YES 表示 installd 能认到）。
static BOOL RPVHelperRegisterViaMCProfileConnection(NSData *data) {
    if (data.length == 0) return NO;

    dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    Class cls = objc_getClass("MCProfileConnection");
    if (!cls) {
        RPVHelperLog(@"[MC] MCProfileConnection class 不可用");
        return NO;
    }
    id connection = [cls sharedConnection];
    if (!connection) {
        RPVHelperLog(@"[MC] MCProfileConnection sharedConnection 为 nil");
        return NO;
    }

    SEL sel = NSSelectorFromString(@"installProvisioningProfileData:managingProfileIdentifier:outError:");
    if (![connection respondsToSelector:sel]) {
        RPVHelperLog(@"[MC] installProvisioningProfileData:managingProfileIdentifier:outError: 不可用");
        return NO;
    }

    NSMethodSignature *sig = [connection methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:connection];
    [inv setSelector:sel];
    [inv setArgument:&data atIndex:2];
    NSString *managing = nil;
    [inv setArgument:&managing atIndex:3];
    NSError *__autoreleasing outError = nil;
    NSError *__autoreleasing *outPtr = &outError;
    [inv setArgument:&outPtr atIndex:4];

    BOOL ret = NO;
    @try {
        [inv invoke];
        if (sig.methodReturnLength == sizeof(BOOL)) [inv getReturnValue:&ret];
        RPVHelperLog(@"[MC] installProvisioningProfileData: returned %d, error: %@",
                     ret, outError ?: @"none");
    } @catch (NSException *e) {
        RPVHelperLog(@"[MC] install 抛异常: %@", e);
        return NO;
    }
    return ret && (outError == nil);
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

    // 主路径：经 MCProfileConnection XPC 把描述文件注册进真实 profiled 数据库。
    // 这才是 installd 的 MIS 在校验代码签名时真正查询的 profile 库；
    // 仅写文件目录 + SIGHUP 在较新 iOS 上不可靠（profiled 不保证重扫目录）。
    BOOL mcOK = RPVHelperRegisterViaMCProfileConnection(data);
    RPVHelperLog(@"MCProfileConnection 注册: %@ （这是 installd 真正读取的库）",
                 mcOK ? @"成功" : @"失败");

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

    RPVHelperLog(@"描述文件已安装（视图A: %@ 视图B: %@ MC注册: %@）",
                 destination, jbrootDest ? jbrootDest : @"(无)",
                 mcOK ? @"成功" : @"失败");

    // 任一注册路径成功即视为整体成功：MC 注册（installd 真正读取的库）或文件写入（兜底）。
    if (mcOK || okMain || okJbroot) {
        return 0;
    }
    RPVHelperLog(@"警告：MC 注册与文件写入均失败，描述文件未能注册");
    return 7;
}

#pragma mark - 入口

static void RPVHelperPrintUsage(void) {
    fprintf(stderr,
            "repro-helper —— RePro 按需 root 助手\n"
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

        RPVHelperLog(@"未知命令: %@", command);
        RPVHelperPrintUsage();
        return 64;
    }
}
