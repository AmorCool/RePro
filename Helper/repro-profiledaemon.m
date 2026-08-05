//
//  repro-profiledaemon.m
//  RePro/ReSign 描述文件安装守护进程（RootHide）
//
//  ─────────────────────────────────────────────────────────────────────
//  v1.1.171 重写。以下三条结论全部来自 iPhone 11 / iOS 17.2 / RootHide
//  真机 SSH 实测，不是推断，改代码前务必先读：
//
//  【实测一】本 daemon 由 launchd 拉起，运行在「真实 rootfs 域」。
//    NSData writeToFile 到 /var/Managed Preferences/mobile 落的就是
//    profiled / trustd / installd 真正读取的那个目录（已用 daemon 自己写的
//    profile-install-result 与该目录 mtime 双向核对一致）。
//    此前怀疑的「daemon 写入落 overlay、真实目录收不到」不成立。
//    注意：SSH 会话反而是在 jbroot 域（/ 即 jbroot，真实根在 /rootfs，
//    jbroot 的 /var 是指向 AppGroup 的假 var）。用 SSH 查 /var/... 会看错目录。
//
//  【实测二】真实 rootfs 里根本没有 /bin/cp、/bin/chmod、/usr/bin/killall
//    （真实 /bin 下只有 df 和 ps）。旧版本 posix_spawn 这些 Apple 二进制
//    必然 ENOENT(2)，属于纯粹无效代码，而且它的失败日志把排查方向带偏过。
//    本版全部删除，改用 libc 系统调用完成同样的事：
//      · 落盘        → NSData writeToFile
//      · 权限        → chmod()
//      · 通知 profiled → sysctl 枚举进程 + kill(pid, SIGHUP)
//
//  【实测三 = 签名后闪退真因】真实目录里 163 个 .mobileprovision 只对应
//    3 个 application-identifier：com.aapl.relaxin 102 份、Pocket-Poster
//    36 份、esign 25 份。旧的清理逻辑只删「已过期」，对「未过期但重复」
//    一份都不删，于是每重签一次就多留一份垃圾。profiled 扫描到同一个
//    application-identifier 的上百份 profile 时会挑中旧份去校验刚重签的
//    App → 证书/UUID 对不上 → 0xe8008015 → 闪退。
//    本版新增「按 application-identifier 去重」：同一 App 只保留最新一份。
//  ─────────────────────────────────────────────────────────────────────
//
//  IPC：App（同样跑在真实域，uid 501）把 profile 数据写到
//  /var/mobile/Library/RePro/profile-to-install.mobileprovision 并 notify_post，
//  daemon 安装后把结果写回 /var/mobile/Library/RePro/profile-install-result 供
//  App 轮询。
//
//  生命周期：短命化。启动 → 处理挂起请求 → 空闲 60 秒 → 自行退出。
//  iOS 17 launchd 会把「长驻但几乎无 IPC」的守护判为 inefficient 并 SIGKILL，
//  常驻 run loop 只会被反复杀，没有意义（详见 signingd 的同类改造）。
//

#include <notify.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
#include <xpc/xpc.h>
#import <Foundation/Foundation.h>

// 系统描述文件库的解析/去重/清单/删除，与 repro-helper 共用同一份实现
#import "RPVProfileStore.h"

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kProfileData = @"/var/mobile/Library/RePro/profile-to-install.mobileprovision";
static NSString *const kResultPath  = @"/var/mobile/Library/RePro/profile-install-result";
static NSString *const kNotifyName  = @"com.reprovision.profile-install-request";
static NSString *const kManagedPrefsDir = @"/var/Managed Preferences/mobile";

// 空闲多久后自行退出（秒）。App 触发后最长等待这么久就收工。
static const NSTimeInterval kIdleExitSeconds = 60.0;

static volatile int32_t g_busy = 0;               // >0 表示正在处理请求，期间不退出
static NSTimeInterval    g_lastActivity = 0;      // 最后一次活动时间

static void RPVProfileDaemonLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-profiledaemon] %@", msg);
}

#pragma mark - 描述文件库操作（实现见 RPVProfileStore.h，与 repro-helper 共用）

static NSString *const kInventoryPath      = @"/var/mobile/Library/RePro/profiles-inventory.plist";
static NSString *const kDeleteRequestPath  = @"/var/mobile/Library/RePro/profile-delete-request";
static NSString *const kCleanupRequestPath = @"/var/mobile/Library/RePro/profile-cleanup-request";
static NSString *const kManageResultPath   = @"/var/mobile/Library/RePro/profile-manage-result";
static NSString *const kManageNotifyName   = @"com.reprovision.profile-manage-request";

/// 清理系统描述文件库：删过期/损坏 + 按 application-identifier 去重。
/// 这一步是修复「签名后目标 App 秒退」的关键，详见 RPVProfileStore.h 顶部说明。
static NSString *CleanupProfiles(void) {
    return RPVPSCleanup();
}

/// 导出清单快照供 App 的「描述文件管理」界面读取。
static void WriteInventory(void) {
    RPVPSWriteInventory(kInventoryPath);
}

/// 处理 App 投递的「删除指定描述文件」请求（每行一个文件名）。
static NSString *HandleDeleteRequest(void) {
    NSString *content = [NSString stringWithContentsOfFile:kDeleteRequestPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:kDeleteRequestPath error:nil];
    if (content.length == 0) return nil;
    NSArray<NSString *> *names = [content componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];
    return RPVPSDeleteNames(names);
}

#pragma mark - 安装

// 确保 IPC 目录存在且 mobile(uid 501) 可写：App 以 mobile 身份往里投递 profile。
static void EnsureIpcDirWritable(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    const char *p = kIpcDir.fileSystemRepresentation;
    if (chown(p, 501, 501) != 0) {
        chmod(p, 0777);
    } else {
        chmod(p, 0755);
    }
}

// 把 profile 写进真实 /var/Managed Preferences/mobile 并让真实 profiled 重扫。
// daemon 本身就在真实域（实测），直接写即可，不需要也不可能借助外部二进制。
static NSString *InstallProfile(NSData *profileData) {
    if (profileData.length == 0) {
        return @"ERR: 描述文件数据为空";
    }

    // 目标文件名优先用「App 稳定名」（同 App 覆盖，杜绝堆积），解析失败退回内容 SHA1。
    NSString *fileName = RPVPSStableNameForData(profileData);
    if (fileName.length == 0) {
        NSString *sha = RPVPSSha1OfData(profileData);
        if (sha.length == 0) {
            return @"ERR: 无法计算描述文件 SHA1";
        }
        fileName = [sha stringByAppendingPathExtension:@"mobileprovision"];
        RPVProfileDaemonLog(@"⚠️ 解析不出 application-identifier，退回内容 SHA1 命名：%@", fileName);
    }

    NSString *destPath = [RPVPSManagedPrefsDir stringByAppendingPathComponent:fileName];

    NSError *writeError = nil;
    if (![profileData writeToFile:destPath options:NSDataWritingAtomic error:&writeError]) {
        return [NSString stringWithFormat:@"ERR: 写入 %@ 失败: %@", destPath, writeError.localizedDescription ?: @"未知错误"];
    }
    chmod(destPath.fileSystemRepresentation, 0644);
    RPVProfileDaemonLog(@"描述文件已写入真实路径：%@", destPath);

    // MC 注册：daemon 在真实域，这里连的是真实 profiled，属于正规注册路径。
    // 即使失败也不致命，文件落盘 + profiled 重扫同样能生效。
    dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    Class mcClass = objc_getClass("MCProfileConnection");
    if (!mcClass) {
        RPVProfileDaemonLog(@"MCProfileConnection 不可用，改由文件 + profiled 重扫生效");
    } else {
        id connection = [(id)mcClass performSelector:@selector(sharedConnection)];
        if (connection) {
            SEL sel = NSSelectorFromString(@"installProvisioningProfileData:managingProfileIdentifier:outError:");
            if ([connection respondsToSelector:sel]) {
                NSMethodSignature *sig = [connection methodSignatureForSelector:sel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:connection];
                [inv setSelector:sel];
                [inv setArgument:&profileData atIndex:2];
                NSString *managing = nil;
                [inv setArgument:&managing atIndex:3];
                NSError *__autoreleasing outError = nil;
                NSError *__autoreleasing *outPtr = &outError;
                [inv setArgument:&outPtr atIndex:4];
                BOOL ret = NO;
                @try {
                    [inv invoke];
                    if (sig.methodReturnLength == sizeof(BOOL)) [inv getReturnValue:&ret];
                    RPVProfileDaemonLog(@"MC 注册返回 %d，错误：%@", ret, outError ?: @"无");
                } @catch (NSException *e) {
                    RPVProfileDaemonLog(@"MC 注册抛异常：%@", e);
                }
            }
        }
    }

    RPVPSNudgeProfiled();

    return [NSString stringWithFormat:@"OK: 描述文件已安装到 %@", destPath];
}

static void HandleRequest(void) {
    __sync_fetch_and_add(&g_busy, 1);

    EnsureIpcDirWritable();
    NSData *profileData = [NSData dataWithContentsOfFile:kProfileData];
    if (profileData.length == 0) {
        RPVProfileDaemonLog(@"%@ 无数据", kProfileData);
        [@"ERR: 没有待安装的描述文件数据" writeToFile:kResultPath
                                          atomically:YES
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
        g_lastActivity = [NSDate timeIntervalSinceReferenceDate];
        __sync_fetch_and_sub(&g_busy, 1);
        return;
    }
    RPVProfileDaemonLog(@"开始处理描述文件安装（%lu 字节）", (unsigned long)profileData.length);

    NSString *result = InstallProfile(profileData);
    RPVProfileDaemonLog(@"结果：%@", result);

    // 装完顺手清一次：删过期 + 按 App ID 去重（这一步才是防闪退的关键）
    NSString *cleanup = CleanupProfiles();
    RPVProfileDaemonLog(@"%@", cleanup);

    NSString *combined = [result stringByAppendingFormat:@"; %@", cleanup];
    [combined writeToFile:kResultPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];

    // 请求已消费，删掉投递文件，避免 daemon 下次启动重复安装同一份旧 profile
    [[NSFileManager defaultManager] removeItemAtPath:kProfileData error:nil];

    WriteInventory();

    g_lastActivity = [NSDate timeIntervalSinceReferenceDate];
    __sync_fetch_and_sub(&g_busy, 1);
}

/// 处理「描述文件管理」类请求：删除指定文件 / 手动清理 / 仅刷新清单。
static void HandleManageRequests(void) {
    __sync_fetch_and_add(&g_busy, 1);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if ([fm fileExistsAtPath:kDeleteRequestPath]) {
        NSString *r = HandleDeleteRequest();
        if (r.length) [parts addObject:r];
    }
    if ([fm fileExistsAtPath:kCleanupRequestPath]) {
        [fm removeItemAtPath:kCleanupRequestPath error:nil];
        [parts addObject:[@"OK: " stringByAppendingString:CleanupProfiles()]];
    }

    if (parts.count > 0) {
        RPVPSNudgeProfiled();
        NSString *combined = [parts componentsJoinedByString:@"; "];
        RPVProfileDaemonLog(@"管理请求结果：%@", combined);
        [combined writeToFile:kManageResultPath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
        chown(kManageResultPath.fileSystemRepresentation, 501, 501);
    }

    WriteInventory();

    g_lastActivity = [NSDate timeIntervalSinceReferenceDate];
    __sync_fetch_and_sub(&g_busy, 1);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        RPVProfileDaemonLog(@"daemon 启动（pid %d, uid %d, euid %d）",
                            getpid(), getuid(), geteuid());

        EnsureIpcDirWritable();
        [[NSFileManager defaultManager] removeItemAtPath:kResultPath error:nil];

        // 启动即清一次，覆盖 daemon 未运行期间累积的过期与重复文件
        NSString *startupCleanup = CleanupProfiles();
        RPVProfileDaemonLog(@"启动清理 → %@", startupCleanup);

        g_lastActivity = [NSDate timeIntervalSinceReferenceDate];

        int token = 0;
        notify_register_dispatch(kNotifyName.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
            RPVProfileDaemonLog(@"收到安装通知（token %d）", t);
            HandleRequest();
        });

        int manageToken = 0;
        notify_register_dispatch(kManageNotifyName.UTF8String, &manageToken,
                                 dispatch_get_main_queue(), ^(int t) {
            RPVProfileDaemonLog(@"收到管理通知（token %d）", t);
            HandleManageRequests();
        });

        // 🔴 v1.1.171：消费 launchd 的 notifyd 事件流。
        // plist 里配了 LaunchEvents(com.apple.notifyd.matching)，launchd 会在收到
        // 通知时把本 job 拉起并把事件排进这个流。如果一直不取，事件会堆在流里，
        // launchd 可能反复重启 job。这里取出来顺带按名字直接处理一次，
        // 比等 notify_register_dispatch 回调更早（进程刚起来时通知已经发过了）。
        xpc_set_event_stream_handler("com.apple.notifyd.matching", dispatch_get_main_queue(),
                                     ^(xpc_object_t _Nonnull event) {
            const char *name = xpc_dictionary_get_string(event, "Notification");
            RPVProfileDaemonLog(@"launchd 事件流唤醒：%s", name ?: "(未知)");
            if (name && strcmp(name, kNotifyName.UTF8String) == 0) {
                HandleRequest();
            } else {
                HandleManageRequests();
            }
        });

        // 启动时若已有挂起请求（App 先写文件再 kickstart 的常见顺序），立刻处理
        if ([[NSFileManager defaultManager] fileExistsAtPath:kProfileData]) {
            HandleRequest();
        }
        // 无论有没有安装请求，启动都刷新一次清单并消费管理请求
        HandleManageRequests();

        // 短命化：空闲满 kIdleExitSeconds 就退出。iOS 17 launchd 会把长驻低 IPC
        // 守护判为 inefficient 直接 SIGKILL，常驻毫无意义（详见 signingd 改造）。
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                                  (uint64_t)(5 * NSEC_PER_SEC),
                                  (uint64_t)(1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            if (g_busy > 0) return;                       // 正在装，别退
            NSTimeInterval idle = [NSDate timeIntervalSinceReferenceDate] - g_lastActivity;
            if (idle >= kIdleExitSeconds) {
                RPVProfileDaemonLog(@"空闲 %.0f 秒，正常退出", idle);
                _exit(0);
            }
        });
        dispatch_resume(timer);

        RPVProfileDaemonLog(@"进入运行循环（空闲 %.0f 秒后自动退出）", kIdleExitSeconds);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
