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
#import <MobileCoreServices/LSApplicationWorkspace.h>

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
    }
}

#pragma mark - Apple ID 登录

- (NSDictionary<NSString *, id> *)loginWithAppleID:(NSString *)appleID
                                          password:(NSString *)password
                                             error:(NSError **)error {
    // 通过 EEProvisioning 执行 SRP 认证
    // 注入本地生成的 Anisette 数据以减少对远程服务器的依赖
    BOOL success = [self.provisioning authenticateWithAppleID:appleID password:password error:error];

    if (success && *error == nil) {
        return @{
            @"status": @"success",
            @"appleID": appleID,
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };
    }
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

    // 解压 IPA
    NSTask *unzipTask = [[NSTask alloc] init];
    unzipTask.launchPath = @"/usr/bin/unzip";
    unzipTask.arguments = @[@"-qo", path, @"-d", tempDir];
    [unzipTask launch];
    [unzipTask waitUntilExit];

    if (unzipTask.terminationStatus != 0) {
        if (error) *error = [NSError errorWithDomain:@"RePro"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"IPA 解压失败"}];
        return nil;
    }

    // 查找 .app 目录
    NSString *payloadDir = [tempDir stringByAppendingPathComponent:@"Payload"];
    NSArray *contents = [fm contentsOfDirectoryAtPath:payloadDir error:nil];
    NSString *appDirName = [contents firstObjectPassingTest:^BOOL(NSString *obj, NSUInteger idx, BOOL *stop) {
        return [obj hasSuffix:@".app"];
    }];

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
        // 如果不是通过导入的，尝试从已安装列表中查找并重新处理
        // TODO: 实现对非导入应用的重签逻辑
        if (error) *error = [NSError errorWithDomain:@"RePro"
                                                 code:404
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithFormat:@"未找到应用: %@", bundleIdentifier]}];
        return NO;
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
    // ... (打包 + LSApplicationWorkspace 安装)

    NSLog(@"[RePro] 重签完成: %@", bundleIdentifier);
    return YES;
}

@end
