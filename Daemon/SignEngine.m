//
//  SignEngine.m
//  ReProvision Daemon
//
//  签名引擎实现：
//  协调 ldid/zsign 后端，管理证书申请、profile 下载、签名执行、IPA 安装全流程
//

#import "SignEngine.h"
#import "LdidBackend.h"
#import "ZSignBackend.h"
#import "EntitlementsGen.h"
#import "EEProvisioning.h" // 从旧项目移植的证书/profile 申请模块
#import "RPVLoginImpl.h"  // 原版 SRP 认证实现
#import <spawn.h>
#import <sys/wait.h>
// 注：LSApplicationWorkspace 仅通过 NSClassFromString/performSelector 动态调用，
// 不 import 私有头文件（现代 iOS SDK 不含该头，会导致编译失败）。

@implementation RZSignOptions
@end

@implementation RZSignResult
@end

@interface SignEngine ()
@property (nonatomic, strong) LdidBackend *ldidBackend;
@property (nonatomic, strong) ZSignBackend *zsignBackend;
@property (nonatomic, strong) EntitlementsGen *entitlementsGen;
@property (nonatomic, strong) EEProvisioning *provisioning; // Apple Developer Portal 交互
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *importedApps;
@end

@implementation SignEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentMethod = RZSignMethodZsign; // 默认使用 zsign
        _ldidBackend = [[LdidBackend alloc] init];
        _zsignBackend = [[ZSignBackend alloc] init];
        _entitlementsGen = [[EntitlementsGen alloc] init];
        _provisioning = [[EEProvisioning alloc] init];
        _importedApps = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 后端选择

- (id<RZSignBackend>)currentBackend {
    switch (self.currentMethod) {
    case RZSignMethodLdid:
        return self.ldidBackend;
    case RZSignMethodZsign:
        return self.zsignBackend;
    default:
        return self.zsignBackend; // 默认 fallback 到 zsign
    }
}

#pragma mark - Apple ID 登录

- (NSDictionary<NSString *, id> *)loginWithAppleID:(NSString *)appleID
                                          password:(NSString *)password
                                             error:(NSError **)error {
    // 使用原版 SRP 认证实现（RPVLoginImpl）
    RPVLoginImpl *loginImpl = [[RPVLoginImpl alloc] init];

    __block NSError *authError = nil;
    __block NSString *userIdentity = nil;
    __block NSString *gsToken = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [loginImpl loginWithUsername:appleID
                         password:password
                      completion:^(NSError *err, NSString *identity, NSString *token, NSString *idmsToken) {
        authError = err;
        userIdentity = identity;
        gsToken = token;
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (authError) {
        // 检查是否是 2FA 错误（需要特殊处理）
        if (authError.code == RPVInternalLogin2FARequiredTrustedDeviceError ||
            authError.code == RPVInternalLogin2FARequiredSecondaryAuthError) {
            if (error) *error = [NSError errorWithDomain:@"RePro"
                                                     code:authError.code
                                                 userInfo:@{
                NSLocalizedDescriptionKey: @"需要双因素认证，请使用支持 2FA 的登录流程",
                @"requires2FA": @YES,
                @"originalError": authError
            }];
        } else {
            if (error) *error = authError;
        }
        return nil;
    }

    // 登录成功，使用获取到的凭证初始化 provisioning
    if (userIdentity && gsToken) {
        self.provisioning = [EEProvisioning provisionerWithCredentials:userIdentity gsToken:gsToken];

        return @{
            @"status": @"success",
            @"appleID": appleID,
            @"identity": userIdentity,
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };
    }

    if (error) *error = [NSError errorWithDomain:@"RePro"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"登录失败：未返回有效凭证"}];
    return nil;
}

#pragma mark - 应用管理

- (NSArray<NSDictionary *> *)listInstalledApps {
    // 使用 LSApplicationWorkspace 私有 API 枚举已安装应用
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [wsClass performSelector:@selector(defaultWorkspace)];

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    SEL allAppsSel = NSSelectorFromString(@"allInstalledApplications");
    if ([workspace respondsToSelector:allAppsSel]) {
        NSArray *allApps = [workspace performSelector:allAppsSel];
        for (id app in allApps) {
            NSString *bid = [app performSelector:@selector(bundleIdentifier)];
            NSString *name = [app performSelector:@selector(localizedName)];
            NSString *version = [app performSelector:@selector(bundleVersion)];
            NSURL *iconURL = [app performSelector:@selector(bundleURL)];
            NSData *iconData = nil;

            // 尝试读取图标
            NSString *iconPath = [[iconURL path] stringByAppendingPathComponent:@"AppIcon60x60@2x.png"];
            iconData = [NSData dataWithContentsOfFile:iconPath];

            [result addObject:@{
                @"bundleIdentifier": bid ?: @"",
                @"displayName": name ?: @"",
                @"version": version ?: @"",
                @"iconData": iconData ?: [NSData data],
                @"id": [[NSUUID UUID] UUIDString]
            }];
        }
    }

    return result;
}

- (NSDictionary<NSString *, id> *)importIPAAtPath:(NSString *)path error:(NSError **)error {
    // 解压 IPA -> 提取信息 -> 存储到 importedApps
    NSFileManager *fm = [NSFileManager defaultManager];

    // 验证文件存在
    if (![fm fileExistsAtPath:path]) {
        if (error) *error = [NSError errorWithDomain:@"RePro"
                                                 code:404
                                             userInfo:@{NSLocalizedDescriptionKey: @"IPA 文件不存在"}];
        return nil;
    }

    // 创建临时解压目录
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"repro_import_%@", [[NSUUID UUID] UUIDString]]];
    [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 解压 IPA（NSTask 在 iOS 不可用，使用 posix_spawn）
    pid_t unzipPid = 0;
    const char *unzipArgv[] = { "/usr/bin/unzip", "-qo", path.UTF8String, "-d", tempDir.UTF8String, NULL };
    int unzipStatus = posix_spawn(&unzipPid, unzipArgv[0], NULL, NULL, (char *const *)unzipArgv, NULL);
    if (unzipStatus == 0) {
        int st = 0;
        waitpid(unzipPid, &st, 0);
        if (WIFEXITED(st) && WEXITSTATUS(st) != 0) {
            if (error) *error = [NSError errorWithDomain:@"RePro"
                                                     code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"IPA 解压失败"}];
            return nil;
        }
    } else {
        if (error) *error = [NSError errorWithDomain:@"RePro"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"IPA 解压失败"}];
        return nil;
    }

    // 查找 .app 目录
    NSString *payloadDir = [tempDir stringByAppendingPathComponent:@"Payload"];
    NSArray *contents = [fm contentsOfDirectoryAtPath:payloadDir error:nil];
    NSString *appDirName = nil;
    for (NSString *obj in contents) {
        if ([obj hasSuffix:@".app"]) { appDirName = obj; break; }
    }

    if (!appDirName) {
        if (error) *error = [NSError errorWithDomain:@"RePro"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"IPA 中未找到 .app"}];
        return nil;
    }

    NSString *appDir = [payloadDir stringByAppendingPathComponent:appDirName];

    // 读取 Info.plist
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                           [appDir stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleID = info[@"CFBundleIdentifier"] ?: @"unknown";
    NSString *displayName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: appDirName;

    // 读取图标
    NSArray *iconFiles = info[@"CFBundleIconFiles"];
    NSData *iconData = nil;
    for (NSString *iconFile in iconFiles) {
        for (NSString *scale in @[@"@3x", @"@2x", @""]) {
            NSString *iconPath = [appDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"%@%@.png", iconFile, scale]];
            iconData = [NSData dataWithContentsOfFile:iconPath];
            if (iconData) break;
        }
        if (iconData) break;
    }

    // 存储导入记录
    NSDictionary *appInfo = @{
        @"bundleIdentifier": bundleID,
        @"displayName": displayName,
        @"version": info[@"CFBundleShortVersionString"] ?: @"1.0",
        @"iconData": iconData ?: [NSData data],
        @"ipaPath": path,
        @"extractedPath": appDir,
        @"id": [[NSUUID UUID] UUIDString]
    };

    self.importedApps[bundleID] = appInfo;

    NSLog(@"[RePro] 导入成功: %@ (%@)", displayName, bundleID);
    return appInfo;
}

#pragma mark - 签名流程

- (BOOL)resignApplication:(NSString *)bundleIdentifier error:(NSError **)error {
    NSLog(@"[RePro] 开始重签: %@", bundleIdentifier);

    NSDictionary *appInfo = self.importedApps[bundleIdentifier];
    if (!appInfo) {
        // 尝试从已安装应用列表中查找路径
        NSString *fallbackPath = nil;
        NSArray<NSDictionary *> *allApps = [self listInstalledApps];
        for (NSDictionary *app in allApps) {
            if ([app[@"bundleIdentifier"] isEqualToString:bundleIdentifier]) {
                fallbackPath = app[@"path"];
                break;
            }
        }

        if (!fallbackPath) {
            if (error) *error = [NSError errorWithDomain:@"RePro"
                                                     code:404
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"未找到应用: %@", bundleIdentifier]}];
            return NO;
        }

        // 为系统应用创建临时导入记录
        self.importedApps[bundleIdentifier] = @{
            @"bundleIdentifier": bundleIdentifier,
            @"extractedPath": fallbackPath,
            @"installedPath": fallbackPath,
            @"imported": @NO
        };
        appInfo = self.importedApps[bundleIdentifier];
    }

    NSString *appPath = appInfo[@"extractedPath"];

    // 步骤1: 申请/获取证书和 profile
    NSString *certPath = nil;
    NSString *keyPath = nil;
    NSArray<NSString *> *profilePaths = nil;

    BOOL provisioned = [self.provisioning requestCertificateForBundleID:bundleIdentifier
                                                           certPathOut:&certPath
                                                            keyPathOut:&keyPath
                                                         profilePathsOut:&profilePaths
                                                               error:error];
    if (!provisioned || !certPath || !keyPath) {
        NSLog(@"[RePro] 证书/profile 申请失败: %@", *error);
        return NO;
    }

    // 步骤2: 生成 entitlements
    NSString *entitlementsPath = [self.entitlementsGen generateForBundleID:bundleIdentifier
                                                                     teamID:self.provisioning.teamID
                                                                       error:error];
    if (!entitlementsPath) {
        NSLog(@"[RePro] entitlements 生成失败: %@", *error);
        return NO;
    }

    // 步骤3: 执行签名
    RZSignOptions *options = [[RZSignOptions alloc] init];
    options.bundleIdentifier = bundleIdentifier;
    options.appPath = appPath;
    options.certificatePath = certPath;
    options.keyPath = keyPath;
    options.provisioningPaths = profilePaths;
    options.entitlementsPath = entitlementsPath;
    options.useSHA256 = YES;

    id<RZSignBackend> backend = [self currentBackend];
    if (![backend isAvailable]) {
        if (error) *error = [NSError errorWithDomain:@"RePro"
                                                 code:503
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithFormat:@"%@ 不可用", backend.backendName]}];
        return NO;
    }

    RZSignResult *result = [backend signWithOptions:options error:error];
    if (!result.success) {
        NSLog(@"[RePro] 签名失败: %@", result.errorMessage);
        return NO;
    }

    // 步骤4: 打包 IPA 并安装
    NSError *installError = nil;
    BOOL installed = [self installSignedApp:result.outputPath
                          bundleIdentifier:bundleIdentifier
                                     error:&installError];
    if (!installed) {
        NSLog(@"[RePro] 安装失败: %@", installError);
        if (error) *error = [NSError errorWithDomain:@"RePro"
                                                 code:510
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithFormat:@"签名成功但安装失败: %@", installError.localizedDescription]}];
        return NO;
    }

    NSLog(@"[RePro] 重签并安装完成: %@", bundleIdentifier);
    return YES;
}

/// 安装签名后的应用（通过 posix_spawn 调用 ipainstaller 或直接替换 .app）
- (BOOL)installSignedApp:(NSString *)signedAppPath
       bundleIdentifier:(NSString *)bundleIdentifier
                  error:(NSError **)error {
    NSDictionary *appInfo = self.importedApps[bundleIdentifier];
    NSString *targetPath = appInfo[@"installedPath"];
    if (!targetPath) {
        targetPath = [NSString stringWithFormat:@"/Applications/%@.app",
                      [bundleIdentifier pathExtension].length > 0 ?
                      [[bundleIdentifier componentsSeparatedByString:@"."] lastObject] :
                      bundleIdentifier];
    }

    // 方式1: 直接复制 .app 目录到 Applications
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:targetPath]) {
        [fm removeItemAtPath:targetPath error:nil];
    }

    BOOL copied = [fm copyItemAtPath:signedAppPath toPath:targetPath error:error];
    if (!copied) {
        return NO;
    }

    // 方式2: 尝试通过 ipainstaller 安装（如果有）
    // 或者直接调用 uicache 刷新
    pid_t pid = 0;
    const char *argv[] = { "/usr/bin/uicache", "-p", [targetPath UTF8String], NULL };
    int status = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
    if (status == 0) waitpid(pid, NULL, 0);

    NSLog(@"[RePro] 应用已安装到: %@", targetPath);
    return YES;
}

@end
