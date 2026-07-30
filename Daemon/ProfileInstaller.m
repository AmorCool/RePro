//
//  ProfileInstaller.m
//  ReProvision Daemon
//

#import "ProfileInstaller.h"
#import <dlfcn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonCrypto.h>

static NSString *const kProfileDir = @"/var/Managed Preferences/mobile";

@implementation ProfileInstaller

- (BOOL)installProfileAtPath:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 验证文件存在且可读
    if (![fm fileExistsAtPath:path]) {
        if (error) *error = [NSError errorWithDomain:@"RePro" code:404 userInfo:@{
            NSLocalizedDescriptionKey: @"Profile 文件不存在"
        }];
        return NO;
    }

    NSData *profileData = [NSData dataWithContentsOfFile:path];
    if (!profileData || profileData.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"RePro" code:413 userInfo:@{
            NSLocalizedDescriptionKey: @"Profile 文件为空或不可读"
        }];
        return NO;
    }

    NSLog(@"[RePro] 安装 Profile (%lu bytes)", (unsigned long)profileData.length);

    // 方法1: MCProfileConnection API（优先）
    NSError *mcError = nil;
    if ([self registerViaMCProfileConnection:profileData error:&mcError]) {
        NSLog(@"[RePro] MCProfileConnection 注册成功");
        [self notifyProfiled];
        return YES;
    }
    NSLog(@"[RePro] MCProfileConnection 失败: %@，尝试文件系统回退", mcError.localizedDescription);

    // 方法2: 文件系统回退
    NSError *fsError = nil;
    if ([self registerViaFileSystem:profileData error:&fsError]) {
        NSLog(@"[RePro] 文件系统注册成功");
        [self notifyProfiled];
        return YES;
    }

    if (error) *error = fsError;
    return NO;
}

- (BOOL)registerViaMCProfileConnection:(NSData *)profileData error:(NSError **)error {
    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration",
        RTLD_LAZY
    );
    if (!handle) {
        if (error) *error = [NSError errorWithDomain:@"RePro" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"无法加载 ManagedConfiguration 框架"
        }];
        return NO;
    }

    Class mcClass = objc_getClass("MCProfileConnection");
    if (!mcClass) {
        dlclose(handle);
        if (error) *error = [NSError errorWithDomain:@"RePro" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"MCProfileConnection 类不存在"
        }];
        return NO;
    }

    id connection = [mcClass performSelector:@selector(sharedConnection)];
    if (!connection) {
        dlclose(handle);
        if (error) *error = [NSError errorWithDomain:@"RePro" code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"无法获取 MCProfileConnection 实例"
        }];
        return NO;
    }

    SEL installSel = NSSelectorFromString(
        @"installProvisioningProfileData:managingProfileIdentifier:outError:"
    );

    if (![connection respondsToSelector:installSel]) {
        dlclose(handle);
        if (error) *error = [NSError errorWithDomain:@"RePro" code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"MCProfileConnection 不支持安装方法"
        }];
        return NO;
    }

    // 使用 IMP 直接调用以避免编译器警告
    BOOL (*installFunc)(id, SEL, NSData *, NSString *, NSError **) =
        (BOOL (*)(id, SEL, NSData *, NSString *, NSError **)) [connection methodForSelector:installSel];

    NSError *outError = nil;
    BOOL success = installFunc(connection, installSel, profileData, @"com.reprovision", &outError);

    dlclose(handle);

    if (!success && outError && error) {
        *error = outError;
    } else if (!success && error) {
        *error = [NSError errorWithDomain:@"RePro" code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"MCProfileConnection 安装失败（未知错误）"
        }];
    }

    return success;
}

- (BOOL)registerViaFileSystem:(NSData *)profileData error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 计算内容 SHA1 作为稳定文件名
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(profileData.bytes, (CC_LONG)profileData.length, digest);

    NSMutableString *fileName = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2 + 16];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [fileName appendFormat:@"%02x", digest[i]];
    }
    [fileName appendString:@".mobileprovision"];

    // 确保目录存在
    if (![fm fileExistsAtPath:kProfileDir]) {
        NSError *mkdirErr = nil;
        [fm createDirectoryAtPath:kProfileDir withIntermediateDirectories:YES attributes:nil error:&mkdirErr];
        if (mkdirErr) {
            if (error) *error = mkdirErr;
            return NO;
        }
    }

    NSString *destPath = [kProfileDir stringByAppendingPathComponent:fileName];

    // 如果已存在则跳过
    if ([fm fileExistsAtPath:destPath]) {
        NSLog(@"[RePro] Profile 已存在: %@", fileName);
        return YES;
    }

    // 写入文件
    NSError *writeErr = nil;
    BOOL success = [profileData writeToFile:destPath options:NSDataWritingAtomic error:&writeErr];

    if (!success && error) {
        *error = writeErr;
    } else if (success) {
        NSLog(@"[RePro] Profile 已写入: %@", destPath);
        // 设置权限为可读
        chmod(destPath.UTF8String, 0644);
    }

    return success;
}

- (void)notifyProfiled {
    // 向 profiled 发送 SIGHUP 通知其重新扫描 profile 目录
    // system()/NSTask 在 iOS 均不可用，使用 posix_spawn
    pid_t pid = 0;
    const char *argv[] = { "/usr/bin/killall", "-HUP", "profiled", NULL };
    posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
    waitpid(pid, NULL, 0);
    NSLog(@"[RePro] 已向 profiled 发送 SIGHUP");
}

@end
