//
//  repro-profiledaemon.m
//  RePro profile installation daemon (RootHide)
//
//  Runs as a launchd LaunchDaemon: launchd starts it in the REAL system
//  context, OUTSIDE the App's jbroot namespace. This is the only way to make
//  a provisioning-profile install actually reach the real profiled on RootHide:
//
//   - The App process (and any helper it spawns) is confined to the overlay
//     namespace. Its MCProfileConnection XPC call is redirected to an overlay
//     profiled instance, and its writes to /var/Managed Preferences/mobile land
//     in the overlay copy. installd runs OUTSIDE the namespace and only sees the
//     REAL library -> 0xe8008015.
//   - This daemon, started by launchd, is NOT in the App's namespace. It writes
//     the profile to the REAL /var/Managed Preferences/mobile and talks to the
//     REAL profiled, so installd can verify the app.
//
//  IPC: the App writes the profile data to a REAL shared path
//  (/var/mobile/Library/RePro/profile-to-install.mobileprovision — /var/mobile
//  is the user home and is NOT namespaced), then notify_post()s a signal. This
//  daemon receives the notify and installs the profile, writing the result back
//  to /var/mobile/Library/RePro/profile-install-result for the App to poll.
//

#include <notify.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdarg.h>
#include <spawn.h>
#include <sys/wait.h>
#include <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kProfileData = @"/var/mobile/Library/RePro/profile-to-install.mobileprovision";
static NSString *const kResultPath  = @"/var/mobile/Library/RePro/profile-install-result";
static NSString *const kNotifyName  = @"com.reprovision.profile-install-request";
static NSString *const kManagedPrefsDir = @"/var/Managed Preferences/mobile";

static void RPVProfileDaemonLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-profiledaemon] %@", msg);
}

static NSString *RPVSha1OfData(NSData *data) {
    if (data.length == 0) return nil;
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

// ─── 过期描述文件清理（v1.1.167）──────────────────────────────────
//
// profile 文件名是内容 SHA1，每次重签（UUID/有效期变化）都会产生一个新文件，
// 旧文件从不清理 → 长期堆积（用户实测 60+ 个）→ profiled 每次扫描全部 +
// 旧 profile 与重签 App 的校验记录冲突 → 签名后闪退 / 「6 天却显示已过期」。
// 过期的 profile 对任何 App 都无价值（App 的 embedded profile 过期 = App 本身
// 也过期），可安全删除；未过期的全部保留，绝不误删。

// 从 .mobileprovision（二进制 PKCS#7，取 <plist> 段）解析出 plist 字典。
static NSDictionary *ProfilePlistFromString(NSString *s) {
    if (s.length == 0) return nil;
    NSRange start = [s rangeOfString:@"<plist"];
    if (start.location == NSNotFound) return nil;
    NSRange searchRange = NSMakeRange(start.location, s.length - start.location);
    NSRange end = [s rangeOfString:@"</plist>" options:0 range:searchRange];
    if (end.location == NSNotFound) return nil;
    NSInteger length = (NSInteger)(end.location + end.length) - (NSInteger)start.location;
    if (length <= 0) return nil;
    NSRange slice = NSMakeRange(start.location, (NSUInteger)length);
    if (NSMaxRange(slice) > s.length) return nil;
    NSData *data = [[s substringWithRange:slice] dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return nil;
    @try {
        return [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:nil
                                                           error:nil];
    } @catch (NSException *e) {
        return nil;
    }
}

static NSDictionary *ProfilePlistAtPath(NSString *path) {
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil];
    return ProfilePlistFromString(s);
}

static NSDictionary *ProfilePlistOfData(NSData *data) {
    NSString *s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return ProfilePlistFromString(s);
}

// v1.1.169 根治堆积：同一 App 用 profile 自带的 application-identifier 派生「稳定文件名」，
// 而非内容 SHA1。重签同一 App 时文件名恒定 → 直接覆盖旧档，从根上不产生堆积
//（不再依赖「每次下载的 profile 内容恰好相同」）。解析不到时退回内容 SHA1，绝不阻断安装。
// 通配符 profile（TEAMID.*）多 App 共享同一名，但通配符 profile 内容本就一致，覆盖无副作用。
static NSString *StableProfileFileName(NSData *profileData) {
    NSDictionary *plist = ProfilePlistOfData(profileData);
    if (!plist) return nil;
    NSString *appId = nil;
    id ai = plist[@"Entitlements"][@"application-identifier"];
    if ([ai isKindOfClass:[NSString class]]) appId = ai;
    if (appId.length == 0) return nil;
    // application-identifier 已含 Team 前缀（TEAMID.com.x），对单 App 唯一。
    NSString *sha = RPVSha1OfData([appId dataUsingEncoding:NSUTF8StringEncoding]);
    if (sha.length == 0) return nil;
    return [sha stringByAppendingPathExtension:@"mobileprovision"];
}

/// 清理 /var/Managed Preferences/mobile 下所有已过期的 .mobileprovision。
/// 调用时机：daemon 启动时 + 每次安装新 profile 后。
/// 返回人类可读的清理摘要（即使未删除也返回，便于回写结果文件让 App 日志可见）。
static NSString *CleanupExpiredProfiles(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:kManagedPrefsDir error:nil] ?: @[];

    NSUInteger total = 0, removed = 0, valid = 0;
    NSDate *now = [NSDate date];
    for (NSString *name in files) {
        if (![name.pathExtension isEqualToString:@"mobileprovision"]) continue;
        total++;
        NSString *path = [kManagedPrefsDir stringByAppendingPathComponent:name];

        NSDictionary *plist = ProfilePlistAtPath(path);
        if (!plist) {
            // 无法解析的损坏文件：留着只会让 profiled 反复报错，删掉
            [fm removeItemAtPath:path error:nil];
            removed++;
            continue;
        }
        NSDate *expiry = plist[@"ExpirationDate"];
        if (expiry && [expiry compare:now] == NSOrderedAscending) {
            [fm removeItemAtPath:path error:nil];
            removed++;
        } else {
            valid++;
        }
    }

    return [NSString stringWithFormat:
        @"已清理 %lu 个过期/损坏描述文件，保留 %lu 个有效（目录共 %lu 个）",
        (unsigned long)removed, (unsigned long)valid, (unsigned long)total];
}

// 以「真实 rootfs 进程」身份执行一个 Apple 签名二进制（如 /bin/cp、/bin/killall）。
//
// 本 daemon 自身被 RootHide 按代码签名判定为 jbroot 进程：其 NSFileManager /
// posix_spawn 的默认写入都落入 overlay 层，真实 /var/Managed Preferences/mobile
// 收不到 → trustd 永远看不到 → App 启动闪退（0xe8008015）。
//
// 但 Apple 二进制（/bin/cp 等）以真实 rootfs 上下文运行，其落盘/信号都作用于
// 真实 rootfs。故本 daemon 只负责准备数据，真正的写盘与通知交给 Apple 二进制完成。
// （实测：launchctl 拉起 /bin/cp 能把文件写进真实 MPDir；真实 root 下
//  killall -HUP profiled 返回 0。）
static int spawn_real_root(const char *bin, const char *arg1, const char *arg2) {
    if (!bin) return -1;
    pid_t pid = 0;
    const char *argv[4];
    argv[0] = bin;
    argv[1] = arg1 ?: (const char *)"";
    argv[2] = arg2;   // 单参数命令传 NULL 即可（如不需要第 2 个参数时 caller 保证 arg2 有效）
    argv[3] = NULL;
    int rc = posix_spawn(&pid, bin, NULL, NULL, (char *const *)argv, NULL);
    if (rc == 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    return rc; // ENOENT 等
}

// 前向声明：EnsureIpcDirWritable 在文件后续才定义，InstallProfile 先调用它。
// C99 不允许隐式函数声明，必须在此处先声明（否则编译报
// "call to undeclared function 'EnsureIpcDirWritable'"）。
static void EnsureIpcDirWritable(void);

// Writes the profile to the REAL managed-preferences directory and asks the REAL
// profiled to rescan. The actual file placement is delegated to /bin/cp (an
// Apple-signed binary that runs in the real rootfs context); this daemon itself
// is jbroot-namespaced and cannot write there directly.
static NSString *InstallProfile(NSData *profileData) {
    if (profileData.length == 0) {
        return @"ERR: empty profile data";
    }

    // 1. 计算目标文件名：优先用「App 稳定名」（根治堆积），解析失败退回内容 SHA1。
    NSString *fileName = StableProfileFileName(profileData);
    if (fileName.length == 0) {
        NSString *sha = RPVSha1OfData(profileData);
        if (sha.length == 0) {
            return @"ERR: failed to compute SHA1 of profile";
        }
        fileName = [sha stringByAppendingPathExtension:@"mobileprovision"];
    }

    NSString *destPath = [kManagedPrefsDir stringByAppendingPathComponent:fileName];

    // 2. 先把数据落到 IPC 目录（/var/mobile/Library/RePro，非 overlay，App/daemon/
    //    真实 root 进程三者共享）。这是跨 namespace 的安全交接点：daemon 写、Apple
    //    二进制 /bin/cp 读，二者看到的都是同一份真实文件。
    EnsureIpcDirWritable();
    NSString *stagePath = [kIpcDir stringByAppendingPathComponent:@"pending-install.mobileprovision"];
    if (![profileData writeToFile:stagePath options:NSDataWritingAtomic error:nil]) {
        return [NSString stringWithFormat:@"ERR: stage write failed: %@", stagePath];
    }

    // 3. 用 Apple 二进制 /bin/cp 把文件拷到真实 MPDir（真实 rootfs 进程写入 → 落真实 rootfs）。
    int rc = spawn_real_root("/bin/cp", [stagePath fileSystemRepresentation], [destPath fileSystemRepresentation]);
    if (rc != 0) {
        // 回退：部分环境 cp 在 /usr/bin
        rc = spawn_real_root("/usr/bin/cp", [stagePath fileSystemRepresentation], [destPath fileSystemRepresentation]);
    }
    if (rc != 0) {
        // 兜底：直接写（非 RootHide 环境 daemon 跑真实 rootfs 时可用；
        // RootHide 下会落 overlay，仅作最后的尽力，不代表成功）
        NSError *e = nil;
        if (![profileData writeToFile:destPath options:NSDataWritingAtomic error:&e]) {
            return [NSString stringWithFormat:@"ERR: cp(%d) 与直接写入均失败: %@", rc, e];
        }
        RPVProfileDaemonLog(@"⚠️ /bin/cp 失败(%d)，已退回直接写入（RootHide 下可能落 overlay）", rc);
    } else {
        RPVProfileDaemonLog(@"profile file placed at REAL path: %@ (cp rc=%d)", destPath, rc);
    }
    spawn_real_root("/bin/chmod", "0644", [destPath fileSystemRepresentation]);
    spawn_real_root("/usr/bin/chmod", "0644", [destPath fileSystemRepresentation]);

    // 4. MC 注册：RootHide 下为 overlay 假成功，作 best-effort；真实注册依赖下方
    //    文件落盘 + profiled 重载。非 RootHide 环境这里是真实生效的。
    dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    Class mcClass = objc_getClass("MCProfileConnection");
    if (!mcClass) {
        RPVProfileDaemonLog(@"MCProfileConnection class unavailable; relying on file + profiled rescan");
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
                    RPVProfileDaemonLog(@"MC install returned %d, error: %@", ret, outError ?: @"none");
                } @catch (NSException *e) {
                    RPVProfileDaemonLog(@"MC install threw: %@", e);
                }
            }
        }
    }

    // 5. 通知真实 profiled 重新扫描 MPDir（Apple 二进制 /bin/killall，真实 rootfs
    //    上下文可信号真实 profiled；实测真实 root 下返回 0）。
    int kh = spawn_real_root("/bin/killall", "-HUP", "profiled");
    if (kh != 0) kh = spawn_real_root("/usr/bin/killall", "-HUP", "profiled");
    RPVProfileDaemonLog(@"killall -HUP profiled rc=%d", kh);

    return [NSString stringWithFormat:@"OK: profile installed to %@", destPath];
}

// Ensure the IPC directory is writable by mobile (uid 501), because the App
// (running as mobile) must drop the profile data there. The daemon runs as
// root, so it can fix ownership/permissions of the directory it created.
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

static void HandleRequest(void) {
    // Make sure the IPC directory is mobile-writable before we read from it.
    EnsureIpcDirWritable();
    NSData *profileData = [NSData dataWithContentsOfFile:kProfileData];
    if (profileData.length == 0) {
        RPVProfileDaemonLog(@"no profile data at %@", kProfileData);
        [@"ERR: no profile data" writeToFile:kResultPath
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:nil];
        return;
    }
    RPVProfileDaemonLog(@"handling profile install (%lu bytes)", (unsigned long)profileData.length);

    NSString *result = InstallProfile(profileData);
    RPVProfileDaemonLog(@"result: %@", result);

    // v1.1.169：装完新 profile 顺手清一次过期堆积，并把清理摘要回写结果文件
    //（App 侧会读 result 文件记入 repro_log，清理动作从此对用户在 App 日志可见）。
    NSString *cleanup = CleanupExpiredProfiles();
    RPVProfileDaemonLog(@"%@", cleanup);

    NSString *combined = [result stringByAppendingFormat:@"; %@", cleanup];
    [combined writeToFile:kResultPath
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        RPVProfileDaemonLog(@"daemon started (pid %d, uid %d, euid %d)",
                            getpid(), getuid(), geteuid());

        // Ensure the IPC directory exists and is writable by mobile (uid 501),
        // because the App (running as mobile) must write the profile data there.
        EnsureIpcDirWritable();
        // Clean any stale result.
        [[NSFileManager defaultManager] removeItemAtPath:kResultPath error:nil];

        // v1.1.169：启动时清一次过期 profile 堆积（覆盖 daemon 未运行期间的累积），结果记入日志。
        NSString *startupCleanup = CleanupExpiredProfiles();
        RPVProfileDaemonLog(@"%@", startupCleanup);

        int token = 0;
        notify_register_dispatch(kNotifyName.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
            RPVProfileDaemonLog(@"received notify (token %d)", t);
            HandleRequest();
        });

        // Handle a request that was already pending at launch.
        if ([[NSFileManager defaultManager] fileExistsAtPath:kProfileData]) {
            HandleRequest();
        }

        RPVProfileDaemonLog(@"entering run loop");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
