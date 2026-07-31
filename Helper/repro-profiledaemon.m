//
//  repro-profiledaemon.m
//  RePro —— 描述文件安装守护进程（LaunchDaemon）
//
//  由 launchd 以 root 身份在系统级上下文启动，完全在 RootHide App 的
//  namespace（jbroot overlay）外面运行。能看到真实 rootfs、能写真实
//  /var/Managed Preferences/mobile、MCProfileConnection 直连真实 profiled。
//
//  这是解决 RootHide 下 0xe8008015 的最终方案：
//    App 的 MC 被 RootHide 重定向到 overlay（假成功），
//    App spawn 的 helper 继承 App namespace（写的也是 overlay），
//    只有 launchd 拉起的进程才在系统级上下文，不受 namespace 影响。
//
//  IPC：notify(3) + 文件
//    App 写 /tmp/repro-profile-request（内容 = 描述文件绝对路径）
//    App post notify("com.reprovision.profile-install-request")
//    本 daemon 收到 notify → 读路径 → 安装 → 写结果到 /tmp/repro-profile-result
//
//  退出码无意义（daemon 常驻），所有状态通过 result 文件通信。
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <signal.h>
#include <notify.h>

#pragma mark - 日志

static void RPVProfileDaemonLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RPVProfileDaemonLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"*** [repro-profiledaemon] %@", message);
}

#pragma mark - 刷新 profiled

/// 优先 killall -HUP profiled；回退 sysctl 枚举发 SIGHUP。
static void RefreshProfiled(void) {
    static const char *killallCandidates[] = {
        "/var/jb/usr/bin/killall", "/var/jb/bin/killall",
        "/usr/bin/killall", "/usr/local/bin/killall", NULL
    };
    const char *killallPath = NULL;
    for (int i = 0; killallCandidates[i]; i++) {
        if (access(killallCandidates[i], X_OK) == 0) { killallPath = killallCandidates[i]; break; }
    }
    if (killallPath) {
        pid_t pid = 0;
        char *const kaArgv[] = { (char *)killallPath, (char *)"-HUP", (char *)"profiled", NULL };
        if (posix_spawn(&pid, killallPath, NULL, NULL, kaArgv, NULL) == 0 && pid > 0) {
            int status = 0; waitpid(pid, &status, 0);
        }
        RPVProfileDaemonLog(@"已通过 killall 发送 SIGHUP 给 profiled");
        usleep(400000);
        return;
    }

    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return;
    if (sysctl(mib, 3, procs, &size, NULL, 0) != 0) { free(procs); return; }
    int count = (int)(size / sizeof(struct kinfo_proc));
    int signalled = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "profiled") == 0) {
            if (kill(procs[i].kp_proc.p_pid, SIGHUP) == 0) signalled++;
        }
    }
    free(procs);
    if (signalled > 0) {
        RPVProfileDaemonLog(@"已通过 sysctl 向 %d 个 profiled 进程发送 SIGHUP", signalled);
    } else {
        RPVProfileDaemonLog(@"警告：未找到 profiled 进程");
    }
    usleep(400000);
}

#pragma mark - 安装描述文件

static NSString *const kRequestPath  = @"/tmp/repro-profile-request";
static NSString *const kResultPath   = @"/tmp/repro-profile-result";

/// 把描述文件写入真实 /var/Managed Preferences/mobile/ 并刷新 profiled。
/// 返回格式字符串："OK" 或 "FAIL: <原因>"。
static NSString *InstallProfile(NSString *profilePath) {
    RPVProfileDaemonLog(@"收到安装请求: %@", profilePath);

    // 读描述文件
    NSData *data = [NSData dataWithContentsOfFile:profilePath];
    if (data.length == 0) {
        return [NSString stringWithFormat:@"FAIL: 描述文件读不到内容 (%@)", profilePath];
    }

    // SHA1 文件名
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    NSString *fileName = [hex stringByAppendingPathExtension:@"mobileprovision"];

    NSString *dir = @"/var/Managed Preferences/mobile";
    NSString *dest = [dir stringByAppendingPathComponent:fileName];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    // 创建目录
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            return [NSString stringWithFormat:@"FAIL: 创建目录失败 %@: %@", dir, error];
        }
    }

    // 清除旧副本
    if ([fm fileExistsAtPath:dest]) {
        [fm removeItemAtPath:dest error:nil];
    }

    // 复制
    if (![fm copyItemAtPath:profilePath toPath:dest error:&error]) {
        return [NSString stringWithFormat:@"FAIL: 复制失败 %@: %@", dest, error];
    }

    // 设权限
    [fm setAttributes:@{
        NSFilePosixPermissions : @(0644),
        NSFileOwnerAccountName   : @"root",
        NSFileGroupOwnerAccountName : @"wheel"
    } ofItemAtPath:dest error:nil];

    RPVProfileDaemonLog(@"描述文件已写入真实路径: %@ (大小: %lu bytes)", dest, (unsigned long)data.length);

    // 尝试 MCProfileConnection 注册（root + 系统上下文 → 直连真实 profiled）
    dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    Class mcClass = objc_getClass("MCProfileConnection");
    if (mcClass) {
        id connection = [mcClass sharedConnection];
        if (connection) {
            SEL sel = NSSelectorFromString(@"installProvisioningProfileData:managingProfileIdentifier:outError:");
            if ([connection respondsToSelector:sel]) {
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
                    RPVProfileDaemonLog(@"MCProfileConnection 注册结果: returned=%d, error=%@",
                                       ret, outError ?: @"none");
                } @catch (NSException *e) {
                    RPVProfileDaemonLog(@"MCProfileConnection 异常: %@", e);
                }
            }
        }
    } else {
        RPVProfileDaemonLog(@"MCProfileConnection 不可用，跳过 MC 注册（文件写入已成功）");
    }

    // 刷新 profiled
    RefreshProfiled();

    // 验证
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
    RPVProfileDaemonLog(@"/var/Managed Preferences/mobile 现有 %lu 个描述文件", (unsigned long)files.count);

    return @"OK";
}

#pragma mark - 入口

int main(int argc, char *argv[]) {
    @autoreleasepool {

        // 确认是 root
        if (getuid() != 0) {
            RPVProfileDaemonLog(@"FATAL: 必须以 root 运行 (uid=%d)", getuid());
            return 1;
        }

        RPVProfileDaemonLog(@"启动 (uid=%d euid=%d pid=%d)", getuid(), geteuid(), getpid());

        // 注册 notify 监听
        int token = 0;
        uint32_t status = notify_register_dispatch(
            "com.reprovision.profile-install-request",
            &token,
            dispatch_get_main_queue(),
            ^(int info) {
                // 收到通知：读取请求文件并处理
                NSString *request = [NSString stringWithContentsOfFile:kRequestPath
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
                if (request.length == 0) {
                    RPVProfileDaemonLog(@"收到 notify 但请求文件为空或不存在");
                    return;
                }

                NSString *profilePath = [request stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (profilePath.length == 0) return;

                RPVProfileDaemonLog(@"--- 开始处理安装请求 ---");

                NSString *result = InstallProfile(profilePath);

                // 写回结果
                [result writeToFile:kResultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                RPVProfileDaemonLog(@"结果已写入: %@", result);

                // 清除请求文件（防止重复处理）
                [[NSFileManager defaultManager] removeItemAtPath:kRequestPath error:nil];

                RPVProfileDaemonLog(@"--- 请求处理完毕 ---");
            }
        );

        if (status != NOTIFY_STATUS_OK) {
            RPVProfileDaemonLog(@"FATAL: notify_register_dispatch 失败 (status=0x%x)", status);
            return 1;
        }

        RPVProfileDaemonLog(@"notify 已注册 (token=%d)，等待安装请求...", token);

        // 进入 runloop（常驻）
        [[NSRunLoop currentRunLoop] run];

        RPVProfileDaemonLog(@"runloop 退出，daemon 结束");
    }
    return 0;
}
