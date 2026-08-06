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
//  /var/mobile/Library/Resign/profile-to-install.mobileprovision 并 notify_post，
//  daemon 安装后把结果写回 /var/mobile/Library/Resign/profile-install-result 供
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

static NSString *const kIpcDir      = @"/var/mobile/Library/Resign";
static NSString *const kProfileData = @"/var/mobile/Library/Resign/profile-to-install.mobileprovision";
static NSString *const kResultPath  = @"/var/mobile/Library/Resign/profile-install-result";
static NSString *const kNotifyName  = @"cn.analy.resign.profile-install-request";
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

static NSString *const kInventoryPath      = @"/var/mobile/Library/Resign/profiles-inventory.plist";
static NSString *const kManageResultPath   = @"/var/mobile/Library/Resign/profile-manage-result";
static NSString *const kManageNotifyName   = @"cn.analy.resign.profile-manage-request";

// 🔴 v1.1.185：删除/清理功能整体移除（MC 注销在 RootHide 下 SIGSEGV，见 main 顶部说明）。
// 不再有 kDeleteRequestPath / kCleanupRequestPath，管理请求只剩「刷新清单」。

/// 导出清单快照供 App 的「描述文件管理」界面读取。
static void WriteInventory(void) {
    RPVPSWriteInventory(kInventoryPath);
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

    NSString *destPath = RPVPSWriteProfileToDirs(profileData, fileName);
    if (destPath.length == 0) {
        return [NSString stringWithFormat:@"ERR: 写入 %@ 失败（所有目标目录均不可写）", fileName];
    }
    RPVProfileDaemonLog(@"描述文件已写入：%@", destPath);

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

    // 🔴 v1.1.172 修复：同一个 notify 会同时触发 notify_register_dispatch 回调、
    //    xpc_set_event_stream_handler 回调，外加 main() 启动时的 fileExists 检查，
    //    可能一前一后调用 HandleRequest 两次。第一次读到 profile 并「原子消费」
    //    （改名移走原始文件），第二次看到文件已空；此时若结果文件里已经是成功，
    //    说明安装其实已完成，绝不能拿 ERR 覆盖成功结果——否则 App 会误判安装失败、
    //    用户手动撤销刚装好的 profile，目标 App 打开即 0xe8008015 秒退。
    NSString *consumedPath = [kProfileData stringByAppendingPathExtension:@"consumed"];
    NSData *profileData = [NSData dataWithContentsOfFile:kProfileData];

    if (profileData.length > 0) {
        // 原子消费：移走原始文件，后续触发读到的是空，不会重复安装同一份
        [[NSFileManager defaultManager] removeItemAtPath:consumedPath error:nil];
        if (![[NSFileManager defaultManager] moveItemAtPath:kProfileData
                                                     toPath:consumedPath
                                                      error:nil]) {
            RPVProfileDaemonLog(@"⚠️ 消费 %@ 失败，原地处理", kProfileData);
        } else {
            NSData *moved = [NSData dataWithContentsOfFile:consumedPath];
            if (moved.length > 0) profileData = moved;
        }
    } else {
        // 没有数据。可能是（a）App 真的没写；或（b）已被上一次触发消费走。
        // 若结果文件里已经是成功，说明安装其实已完成，直接返回，绝不覆盖。
        NSString *existing = [NSString stringWithContentsOfFile:kResultPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (existing.length > 0 && [existing hasPrefix:@"OK"]) {
            RPVProfileDaemonLog(@"%@ 无数据，但已有成功结果，跳过（防竞态覆盖）", kProfileData);
            g_lastActivity = [NSDate timeIntervalSinceReferenceDate];
            __sync_fetch_and_sub(&g_busy, 1);
            return;
        }
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
    // 🔴 v1.1.185：装完不再自动清理（删除功能整体移除，见 main 顶部说明）。
    // 防堆积靠稳定名覆盖写 + profiled 重扫，无需删文件。

    [result writeToFile:kResultPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];

    // 请求已消费，删掉 .consumed 暂存，避免残留
    [[NSFileManager defaultManager] removeItemAtPath:consumedPath error:nil];

    WriteInventory();

    g_lastActivity = [NSDate timeIntervalSinceReferenceDate];
    __sync_fetch_and_sub(&g_busy, 1);
}

/// 处理「描述文件管理」类请求：🔴 v1.1.185 起只剩「刷新清单」。
/// 删除指定文件 / 手动清理已整体移除（MC 注销在 RootHide 下 SIGSEGV 崩溃，
/// @try 接不住信号 → daemon 崩溃 → App 等 60s「root 侧未响应」，见 main 顶部说明）。
static void HandleManageRequests(void) {
    __sync_fetch_and_add(&g_busy, 1);

    // 刷新清单（App「描述文件管理」的「刷新清单」按钮走这里）。
    // 清单先写、结果后回，保证 App 轮询到结果时清单已是最新。
    WriteInventory();

    NSString *done = @"OK: 清单已刷新";
    RPVProfileDaemonLog(@"管理请求结果：%@", done);
    [done writeToFile:kManageResultPath
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    chown(kManageResultPath.fileSystemRepresentation, 501, 501);

    g_lastActivity = [NSDate timeIntervalSinceReferenceDate];
    __sync_fetch_and_sub(&g_busy, 1);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        RPVProfileDaemonLog(@"daemon 启动（pid %d, uid %d, euid %d）",
                            getpid(), getuid(), geteuid());

        EnsureIpcDirWritable();
        [[NSFileManager defaultManager] removeItemAtPath:kResultPath error:nil];

        // 🔴 v1.1.185：删除/清理功能整体移除（MC 注销在 RootHide 下 SIGSEGV 崩溃，
        // @try 接不住信号 → daemon 崩溃 → App 等 60s「root 侧未响应」）。
        // 不再有任何「启动即清理 / 删除请求」逻辑；profile 堆积由「稳定名覆盖写」
        // （sha1(application-identifier) 恒定同名，重签直接覆盖）从源头杜绝。
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
        //
        // ⚠️ CI 实锤：iOS SDK 把 xpc_set_event_stream_handler 标了
        // 「unavailable: not available on iOS」，直接调用编译不过。
        // 但该符号在 iOS 的 libxpc 里确实存在（launchd 自己就在用），
        // 所以改成 dlsym 运行时取——取到就用，取不到就退化成只靠
        // notify_register_dispatch + 启动时全量扫描，主流程不受影响。
        {
            // 形参这里不用 xpc_handler_t（它同样可能被 SDK 在 iOS 上屏蔽），
            // 直接写等价的 block 类型 void(^)(xpc_object_t)。
            typedef void (*RPVXPCSetEventStreamHandler)(const char *stream,
                                                        dispatch_queue_t queue,
                                                        void (^handler)(xpc_object_t));
            RPVXPCSetEventStreamHandler setStream =
                (RPVXPCSetEventStreamHandler)dlsym(RTLD_DEFAULT, "xpc_set_event_stream_handler");
            if (setStream) {
                setStream("com.apple.notifyd.matching", dispatch_get_main_queue(),
                          ^(xpc_object_t _Nonnull event) {
                    const char *name = xpc_dictionary_get_string(event, "Notification");
                    RPVProfileDaemonLog(@"launchd 事件流唤醒：%s", name ?: "(未知)");
                    if (name && strcmp(name, kNotifyName.UTF8String) == 0) {
                        HandleRequest();
                    } else {
                        HandleManageRequests();
                    }
                });
            } else {
                RPVProfileDaemonLog(@"xpc_set_event_stream_handler 不可用，"
                                    @"退化为 notify 回调 + 启动全量扫描");
            }
        }

        // 启动时若已有挂起请求（App 先写文件再 kickstart 的常见顺序），立刻处理
        if ([[NSFileManager defaultManager] fileExistsAtPath:kProfileData]) {
            HandleRequest();
        }
        // 启动都刷新一次清单（🔴 v1.1.185：删除/清理已移除，管理请求只剩刷新清单）
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

            // 🔴 v1.1.179：每轮先兜底扫一遍盘上的挂起请求，再考虑退出。
            //
            // 竞态实录（用户日志 18:02:47「超时未返回」就是它）：App 恰好在 daemon
            // 「空闲已满 60 秒、马上要退」的窗口里投递请求并 notify_post，通知被这个
            // 正在死掉的进程收下 —— launchd 认为已有实例消费过事件，不会再拉起新实例，
            // 请求就那样悬在磁盘上没人管，App 只能干等满 60 秒报超时。
            //
            // 加上这层轮询后：只要 daemon 还活着就一定会看到请求文件；
            // 即使通知彻底丢失，最多 5 秒也会被捞起来处理，不再依赖通知可靠送达。
            NSFileManager *tickFM = [NSFileManager defaultManager];
            if ([tickFM fileExistsAtPath:kProfileData]) {
                RPVProfileDaemonLog(@"轮询发现挂起的安装请求，立即处理");
                HandleRequest();
                return;
            }
            // 🔴 v1.1.185：删除/清理请求文件已不存在（功能移除），无需轮询。

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
