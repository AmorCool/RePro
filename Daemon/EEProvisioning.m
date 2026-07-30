//
//  EEProvisioning.m
//  ReProvision Daemon
//
//  Apple Developer Portal 交互模块完整实现（从旧项目 ReProvision-Reborn 精简移植）
//
//  核心功能：
//  1. Apple ID 登录认证（SRP 协议）
//  2. 开发证书申请（CSR 生成 + 提交）
//  3. App ID 注册/更新 + Entitlements 处理
//  4. Provisioning Profile 下载
//
//  移植改动：
//  - SAMKeychain → 文件存储（/var/mobile/Library/Preferences/jp.soh.reprovision/）
//  - EEAppleServices 单例 → 属性注入
//  - 去掉 watchOS/tvOS 分支，仅支持 iOS
//  - 全中文注释
//

#import "EEProvisioning.h"
#import "EEAppleServices.h"
#import "EESigning.h"
#import "RPVLoginImpl.h"

#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <unistd.h>

/// 文件存储根目录（daemon root 权限下可写）
static NSString * const kStorageDirectory = @"/var/mobile/Library/Preferences/jp.soh.reprovision";

@implementation EEProvisioning

#pragma mark - 初始化方法

+ (instancetype)provisionerWithCredentials:(NSString *)identity gsToken:(NSString *)gsToken {
    return [[self alloc] initWithCredentials:identity gsToken:gsToken];
}

- (instancetype)initWithCredentials:(NSString *)identity gsToken:(NSString *)gsToken {
    self = [super init];
    if (self) {
        _identity = identity;
        _gsToken = gsToken;

        // 确保存储目录存在
        [self _ensureStorageDirectoryExists];
    }
    return self;
}

#pragma mark - 兼容性存根（.h 声明但现代流程不使用）

- (BOOL)authenticateWithAppleID:(NSString *)appleID
                         password:(NSString *)password
                            error:(NSError **)error {
    // 使用 RPVLoginImpl 执行完整的 SRP 认证
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
        if (error) *error = authError;
        return NO;
    }

    if (userIdentity && gsToken) {
        self.identity = userIdentity;
        self.gsToken = gsToken;

        // 使用获取的凭证初始化 appleServices 会话
        if (!self.appleServices) {
            self.appleServices = [[EEAppleServices alloc] init];
        }
        [self.appleServices ensureSessionWithIdentity:userIdentity
                                              gsToken:gsToken
                                andCompletionHandler:^(NSError *e, NSDictionary *plist) {
            if (e) {
                NSLog(@"[RePro] 会话初始化失败: %@", e);
            }
        }];

        return YES;
    }

    if (error) *error = [NSError errorWithDomain:@"EEProvisioning"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"登录失败：未返回有效凭证"}];
    return NO;
}

- (BOOL)requestCertificateForBundleID:(NSString *)bundleID
                           certPathOut:(NSString *_Nullable *_Nullable)certPath
                            keyPathOut:(NSString *_Nullable *_Nullable)keyPath
                         profilePathsOut:(NSArray<NSString *> *_Nullable *_Nullable)profilePaths
                                  error:(NSError **)error {
    // 确保 appleServices 已初始化
    if (!self.appleServices) {
        self.appleServices = [[EEAppleServices alloc] init];
    }
    if (!self.identity || !self.gsToken) {
        if (error) *error = [NSError errorWithDomain:@"EEProvisioning"
                                                 code:-2
                                             userInfo:@{NSLocalizedDescriptionKey: @"请先登录 Apple ID"}];
        return NO;
    }

    // 通过 semaphore 桥接异步 downloadProvisioningProfileForApplicationIdentifier 到同步 API
    __block NSError *resultError = nil;
    __block NSData *profileData = nil;
    __block NSString *privateKeyResult = nil;
    __block NSDictionary *certificateResult = nil;
    __block NSDictionary *entitlementsResult = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [self downloadProvisioningProfileForApplicationIdentifier:bundleID
                                             applicationName:bundleID
                                             binaryLocation:@""
                                            withTeamIDCheck:^NSString *(NSArray *teams) {
        // 自动选择第一个可用团队
        return teams.firstObject[@"teamId"];
    }
                                                 andCallback:^(NSError *e, NSData *p, NSString *k, NSDictionary *c, NSDictionary *en) {
        resultError = e;
        profileData = p;
        privateKeyResult = k;
        certificateResult = c;
        entitlementsResult = en;
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (resultError) {
        if (error) *error = resultError;
        return NO;
    }

    // 将证书、私钥、profile 写入临时文件
    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"RePro_%@_%d", bundleID, getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];

    // 写入私钥
    NSString *keyFilePath = [tmpDir stringByAppendingPathComponent:@"key.p12"];
    if (privateKeyResult && keyPathOut) {
        [privateKeyResult writeToFile:keyFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        *keyPathOut = keyFilePath;
    }

    // 写入 profile
    NSString *profilePath = nil;
    if (profileData && profilePathsOut) {
        profilePath = [tmpDir stringByAppendingPathComponent:@"embedded.mobileprovision"];
        [profileData writeToFile:profilePath atomically:YES];
        *profilePathsOut = @[profilePath];
    }

    // 证书信息已通过 certificateResult 返回，调用方可以使用
    // certPath 暂不填充（证书路径需要额外的 PEM 格式化）

    NSLog(@"[RePro] 证书/Profile 申请完成: bundleID=%@, key=%@, profile=%@",
          bundleID, keyFilePath, profilePath);

    return YES;
}

#pragma mark - 错误处理工具方法

/// 从字符串创建 NSError 对象
+ (NSError *)_errorFromString:(NSString *)string {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: string,
        NSLocalizedFailureReasonErrorKey: string,
        NSLocalizedRecoverySuggestionErrorKey: @""
    };

    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:-1
                           userInfo:userInfo];
}

#pragma mark - 文件存储工具方法（替代 SAMKeychain）

/// 确保存储目录存在
- (void)_ensureStorageDirectoryExists {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kStorageDirectory]) {
        NSError *error;
        [fm createDirectoryAtPath:kStorageDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error];
        if (error) {
            NSLog(@"[RePro] 创建存储目录失败: %@", error.localizedDescription);
        }
    }
}

/// 向文件系统存储字符串值
- (void)_storeString:(NSString *)value forKey:(NSString *)key {
    NSString *filePath = [kStorageDirectory stringByAppendingPathComponent:key];
    NSError *error;
    [value writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        NSLog(@"[RePro] 存储失败 [%@]: %@", key, error.localizedDescription);
    }
}

/// 从文件系统读取字符串值
- (NSString *)_loadStringForKey:(NSString *)key {
    NSString *filePath = [kStorageDirectory stringByAppendingPathComponent:key];
    return [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - 公开方法

/// 注册设备到 Developer Portal
- (void)provisionDevice:(NSString *)udid
                   name:(NSString *)name
       withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
            andCallback:(void (^)(NSError *))completionHandler {

    // 先执行 Stage 1 登录
    [self _provisioningStageOneWithIdentifier:@"" withTeamIDCheck:teamIDCallback andCallback:^(NSError *error) {
        if (error) {
            completionHandler(error);
            return;
        }

        // 添加设备到团队
        [self.appleServices addDevice:udid
                          deviceName:name
                           forTeamID:[self.appleServices currentTeamID]
                         systemType:EESystemTypeUndefined
                         withCompletionHandler:^(NSError *error, NSDictionary *plist) {
            if (error) {
                completionHandler(error);
                return;
            }

            // 检查返回结果
            int resultCode = [[plist objectForKey:@"resultCode"] intValue];
            if (resultCode != 0) {
                NSError *deviceError = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
                completionHandler(deviceError);
                return;
            }

            completionHandler(nil);
        }];
    }];
}

/// 撤销当前机器的开发证书
- (void)revokeCertificatesWithTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
                              andCallback:(void (^)(NSError *))completionHandler {

    // 先执行 Stage 1 登录
    [self _provisioningStageOneWithIdentifier:@"" withTeamIDCheck:teamIDCallback andCallback:^(NSError *error) {
        if (error) {
            completionHandler(error);
            return;
        }

        // 列出所有开发证书
        [self.appleServices listAllDevelopmentCertificatesForTeamID:[self.appleServices currentTeamID]
                                             systemType:EESystemTypeUndefined
                                             withCompletionHandler:^(NSError *error, NSDictionary *plist) {
            if (error) {
                completionHandler(error);
                return;
            }

            // 查找当前机器的证书
            NSString *deviceID = [self _identifierForCurrentMachine];
            NSString *certId = nil;

            for (NSDictionary *dict in [plist objectForKey:@"data"]) {
                NSString *machineId = dict[@"attributes"][@"machineId"];
                if ([machineId isEqualToString:deviceID]) {
                    certId = dict[@"id"];
                    break;
                }
            }

            if (certId) {
                // 找到了，撤销它
                [self.appleServices revokeCertificateForIdentifier:certId
                                                         andTeamID:[self.appleServices currentTeamID]
                                                      systemType:EESystemTypeUndefined
                                                   withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        completionHandler(error);
                        return;
                    }

                    completionHandler(nil);
                }];
            } else {
                // 未找到当前机器的证书，视为成功
                completionHandler(nil);
            }
        }];
    }];
}

#pragma mark - 主入口：下载 Provisioning Profile

/**
 * 主入口方法：执行完整的4阶段流程下载 Provisioning Profile
 *
 * 流程说明：
 * Stage 1: 登录 Apple ID + 获取/更新 Team ID
 * Stage 2: 检查或创建开发证书（CSR 生成 + 提交）
 * Stage 3: 添加或更新 App ID + 配置 Entitlements
 * Stage 4: 删除旧 Profile + 下载新 Profile
 */
- (void)downloadProvisioningProfileForApplicationIdentifier:(NSString *)identifier
                                           applicationName:(NSString *)applicationName
                                           binaryLocation:(NSString *)binaryLocation
                                          withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
                                               andCallback:(void (^)(NSError *,
                                                                    NSData *,
                                                                    NSString *,
                                                                    NSDictionary *,
                                                                    NSDictionary *))completionHandler {

    // Stage 1: 登录 + 获取 Team ID
    [self _provisioningStageOneWithIdentifier:identifier withTeamIDCheck:teamIDCallback andCallback:^(NSError *error) {
        if (error) {
            completionHandler(error, nil, nil, nil, nil);
            return;
        }

        // Stage 2: 检查/创建开发证书
        [self _provisioningStageTwoWithIdentifier:identifier andCallback:^(NSError *error, NSString *privateKey, NSDictionary *certificate) {
            if (error) {
                completionHandler(error, nil, nil, nil, nil);
                return;
            }

            // Stage 3: 添加/更新 App ID + entitlements
            [self _provisioningStageThreeWithIdentifier:identifier
                                       applicationName:applicationName
                                        binaryLocation:binaryLocation
                                           andCallback:^(NSError *error, NSString *appIdId, NSDictionary *entitlements) {
                if (error) {
                    completionHandler(error, nil, nil, nil, nil);
                    return;
                }

                // Stage 4: 删除旧 profile + 下载新 profile
                [self _provisioningStageFourWithIdentifier:identifier appIdId:appIdId andCallback:^(NSError *error, NSData *embeddedMobileprovision) {
                    // 全部完成，返回结果给调用者
                    completionHandler(error, embeddedMobileprovision, privateKey, certificate, entitlements);
                }];
            }];
        }];
    }];
}

#pragma mark - Stage 1: 登录 + 获取 Team ID

/**
 * Stage 1: 登录 Apple ID 并获取 Team ID
 *
 * 步骤：
 * 1. 使用 identity 和 gsToken 进行 SRP 认证
 * 2. 调用 teamIDCallback 获取正确的 Team ID
 * 3. 更新本地缓存的 Team ID
 */
- (void)_provisioningStageOneWithIdentifier:(NSString *)identifier
                          withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
                               andCallback:(void (^)(NSError *))completionHandler {

    // 执行登录
    [self _signIn:self.identity gsToken:self.gsToken withCallback:^(NSError *error) {
        if (!error) {
            NSLog(@"[RePro] 认证成功！");

            // 更新 Team ID
            [self.appleServices updateCurrentTeamIDWithTeamIDCheck:teamIDCallback andCallback:^(NSError *error, NSString *teamid) {
                if (error) {
                    NSError *teamError = [EEProvisioning _errorFromString:
                        [NSString stringWithFormat:@"updateCurrentTeamIDWithCompletionHandler: %@", error.localizedDescription]];
                    completionHandler(teamError);
                    return;
                }

                NSLog(@"[RePro] 当前 Team ID: %@", teamid);

                if ([teamid isEqualToString:@""]) {
                    // 不应该到达这里，但保留防御性逻辑
                    NSError *noTeamError = [EEProvisioning _errorFromString:
                        @"updateCurrentTeamIDWithCompletionHandler: 没有 Team ID！这是严重错误。"];
                    completionHandler(noTeamError);
                } else {
                    completionHandler(nil);
                }
            }];
        } else {
            completionHandler(error);
        }
    }];
}

/// 使用 SRP 协议登录 Apple ID
- (void)_signIn:(NSString *)identity gsToken:(NSString *)gsToken withCallback:(void (^)(NSError *))completionHandler {
    [self.appleServices ensureSessionWithIdentity:identity
                                         gsToken:gsToken
                           andCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error);
            return;
        }

        // 验证认证状态
        NSString *reason = [plist objectForKey:@"reason"];
        NSString *userString = [plist objectForKey:@"userString"];
        BOOL authenticated = [reason isEqualToString:@"authenticated"];

        NSError *authError = [EEProvisioning _errorFromString:
            [NSString stringWithFormat:@"%@ %@", reason, userString]];

        completionHandler(authenticated ? nil : authError);
    }];
}

#pragma mark - Stage 2: 开发证书管理

/**
 * Stage 2: 检查并确保存在有效的开发证书
 *
 * 逻辑：
 * 1. 列出当前团队的所有开发证书
 * 2. 查找属于本机的证书（通过 machineId 匹配）
 * 3. 检查证书是否过期、私钥是否存在、Team ID 是否匹配
 * 4. 如果任何条件不满足，撤销旧证书并申请新的
 */
- (void)_provisioningStageTwoWithIdentifier:(NSString *)identifier
                                andCallback:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {

    [self _handleDevelopmentCodesigningRequestIfNecessary:^(NSError *error, NSString *privateKey, NSDictionary *certificate) {
        if (!error) {
            NSLog(@"[RePro] 已获取可用的开发证书！");
        }
        completionHandler(error, privateKey, certificate);
    }];
}

/**
 * 处理开发证书请求的核心逻辑
 *
 * 关键点：
 * - 使用持久化 UUID 作为机器标识（而非 UDID）
 * - 证书名称使用 "RPV-" 前缀 + 设备名（避免多设备冲突）
 * - 存储 Team ID 以检测账户切换
 * - 私钥丢失或证书过期时自动撤销并重新申请
 */
- (void)_handleDevelopmentCodesigningRequestIfNecessary:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {

    [self.appleServices listAllDevelopmentCertificatesForTeamID:[self.appleServices currentTeamID]
                                             systemType:EESystemTypeUndefined
                                             withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            NSError *listError = [EEProvisioning _errorFromString:
                [NSString stringWithFormat:@"listAllDevelopmentCertificatesForTeamID: %@", error.localizedDescription]];
            completionHandler(listError, nil, nil);
            return;
        }

        /*
         * 需要为当前机器生成开发证书的情况：
         * 1. 本机没有对应的开发证书
         * 2. 本地缺少该证书的私钥
         * 3. 证书已过期
         * 4. 用户切换了账户（Team ID 不匹配）
         *
         * 重要设计决策：
         * - 不再使用 "Cydia" 作为证书名称（会导致多设备冲突）
         * - 每台设备使用唯一的 machineId 和 machineName
         * - 存储 Team ID 以便在账户切换时重新生成 CSR
         */

        // 从文件存储读取私钥和关联的 Team ID
        NSString *privateKey = [self _loadStringForKey:@"privateKey"];
        NSString *privateKeyAssociatedTeamID = [self _loadStringForKey:@"privateKeyTeamID"];

        BOOL hasValidCertificate = NO;
        NSDate *now = [NSDate date];
        NSDictionary *certificate = nil;
        NSString *certId = nil;

        // 遍历所有开发证书，查找本机的
        for (NSDictionary *dict in [plist objectForKey:@"data"]) {
            NSString *machineId = dict[@"attributes"][@"machineId"];
            NSString *machineName = dict[@"attributes"][@"machineName"];

            if (machineName != [NSNull null] && [machineName length] > 0) {
                // 匹配本机的证书（或 AltStore 特殊处理）
                if ([machineId isEqualToString:[self _identifierForCurrentMachine]]) {
                    certificate = dict[@"attributes"];
                    certId = dict[@"id"];
                    hasValidCertificate = YES;

                    // 检查证书是否过期
                    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                    dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                    dateFormatter.dateFormat = @"yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'";
                    dateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];

                    NSDate *certificateExpiryDate = [dateFormatter dateFromString:dict[@"attributes"][@"expirationDate"]];
                    if ([now compare:certificateExpiryDate] == NSOrderedDescending) {
                        // 证书已过期
                        hasValidCertificate = NO;
                    }

                    break;
                }
            }
        }

        // 检查当前 Team ID 是否与存储的一致
        BOOL currentTeamIDMatchesStored = [[self.appleServices currentTeamID] isEqualToString:privateKeyAssociatedTeamID];

        // 判断是否需要重新申请证书
        if (!hasValidCertificate || [privateKey isEqualToString:@""] || privateKey == nil || !currentTeamIDMatchesStored) {
            BOOL shouldRevokeFirst = (certificate != nil); // 是否需要先撤销旧证书

            if (shouldRevokeFirst) {
                // 先撤销旧证书
                NSString *reason = @"";
                if ([privateKey isEqualToString:@""] || privateKey == nil || !currentTeamIDMatchesStored)
                    reason = @"本地没有该证书的私钥";
                else
                    reason = @"证书已过期";

                NSLog(@"[RePro] 正在撤销证书 '%@'，原因：%@", certId, reason);

                [self.appleServices revokeCertificateForIdentifier:certId
                                                         andTeamID:[self.appleServices currentTeamID]
                                                      systemType:EESystemTypeUndefined
                                                   withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        completionHandler(error, nil, nil);
                        return;
                    }

                    // 提交新的 CSR
                    [self _submitNewCodeSigningRequestForTeamID:[self.appleServices currentTeamID]
                                                   machineName:[self _nameForCurrentMachine]
                                                     machineId:[self _identifierForCurrentMachine]
                                                  withCallback:^(NSError *error, NSString *newPrivateKey, NSDictionary *newCertificate) {
                        if (error) {
                            completionHandler(error, nil, nil);
                            return;
                        }

                        // 存储新的私钥和 Team ID
                        [self _storeString:newPrivateKey forKey:@"privateKey"];
                        [self _storeString:[self.appleServices currentTeamID] forKey:@"privateKeyTeamID"];

                        completionHandler(nil, newPrivateKey, newCertificate);
                    }];
                }];

                return;
            }

            // 直接提交新的 CSR（无需先撤销）
            [self _submitNewCodeSigningRequestForTeamID:[self.appleServices currentTeamID]
                                           machineName:[self _nameForCurrentMachine]
                                             machineId:[self _identifierForCurrentMachine]
                                          withCallback:^(NSError *error, NSString *newPrivateKey, NSDictionary *newCertificate) {
                if (error) {
                    completionHandler(error, nil, nil);
                    return;
                }

                // 存储新的私钥和 Team ID
                [self _storeString:newPrivateKey forKey:@"privateKey"];
                [self _storeString:[self.appleServices currentTeamID] forKey:@"privateKeyTeamID"];

                completionHandler(nil, newPrivateKey, newCertificate);
            }];

        } else {
            // 证书有效且私钥存在，直接返回
            completionHandler(nil, privateKey, certificate);
        }
    }];
}

#pragma mark - 机器标识相关

/// 获取当前设备名称
- (NSString *)_nameForCurrentMachine {
#if TARGET_OS_SIMULATOR
    return @"Simulator";
#elif TARGET_OS_IPHONE
    // daemon 不链接 UIKit，使用 BSD 主机名代替 UIDevice.currentDevice.name
    char hostnameBuf[256];
    if (gethostname(hostnameBuf, sizeof(hostnameBuf)) == 0) {
        return [NSString stringWithUTF8String:hostnameBuf];
    }
    return @"iOS Device";
#else
    return @"Unknown Device";
#endif
}

/// 获取当前机器的唯一标识符（持久化 UUID）
///
/// 使用文件存储而非 Keychain，因为 daemon 运行在 root 权限下
/// 该 UUID 在设备上持久保存，用于关联开发证书
- (NSString *)_identifierForCurrentMachine {
    NSString *uuid = [self _loadStringForKey:@"uuid"];
    if (!uuid || [uuid isEqualToString:@""]) {
        uuid = [[NSUUID UUID] UUIDString];
        [self _storeString:uuid forKey:@"uuid"];
    }
    return uuid;
}

#pragma mark - CSR 生成与提交

/**
 * 提交新的代码签名请求
 *
 * 流程：
 * 1. 使用 OpenSSL 生成 RSA 2048 密钥对
 * 2. 创建 CSR（证书签名请求）
 * 3. 提交到 Apple Developer Portal
 * 4. 等待审批后获取证书
 */
- (void)_submitNewCodeSigningRequestForTeamID:(NSString *)teamid
                                  machineName:(NSString *)machineName
                                    machineId:(NSString *)machineId
                                 withCallback:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {

    // 生成 CSR 和私钥
    NSData *privateKey = nil;
    NSData *codeSigningRequest = nil;

    int ret = [self _generateCodeSigningRequest:&privateKey csrOut:&codeSigningRequest];
    if (ret != 1 || !codeSigningRequest) {
        NSError *csrError = [EEProvisioning _errorFromString:
            @"submitDevelopmentCSR: 无法生成代码签名请求"];
        completionHandler(csrError, nil, nil);
        return;
    }

    NSLog(@"[RePro] 已生成代码签名请求，正在提交...");

    // 给机器名添加前缀以区分
    machineName = [NSString stringWithFormat:@"RPV- %@", machineName];

    // 提交 CSR 到 Apple
    [self.appleServices submitCodeSigningRequestForTeamID:teamid
                                             machineName:machineName
                                               machineID:machineId
                                      codeSigningRequest:codeSigningRequest
                                              systemType:EESystemTypeUndefined
                                     withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error, nil, nil);
            return;
        }

        // 检查是否有错误
        NSArray *errors = [plist objectForKey:@"errors"];
        if (errors != nil) {
            NSString *resultString = [errors[0] objectForKey:@"detail"];
            NSString *desc = [NSString stringWithFormat:@"submitDevelopmentCSR: %@", resultString];

            NSError *submitError = [EEProvisioning _errorFromString:desc];
            completionHandler(submitError, nil, nil);
            return;
        }

        // 获取新证书的序列号
        NSDictionary *data = [plist objectForKey:@"data"];
        NSString *certificateSerialID = data[@"attributes"][@"serialNumber"];

        // 再次查询证书列表以获取完整的证书信息
        [self.appleServices listAllDevelopmentCertificatesForTeamID:[self.appleServices currentTeamID]
                                             systemType:EESystemTypeUndefined
                                             withCompletionHandler:^(NSError *error, NSDictionary *plist) {
            if (error) {
                completionHandler(error, nil, nil);
                return;
            }

            NSDictionary *certificate = nil;
            for (NSDictionary *dict in [plist objectForKey:@"data"]) {
                NSString *certSerialNumber = dict[@"attributes"][@"serialNumber"];
                if ([certSerialNumber isEqualToString:certificateSerialID]) {
                    certificate = dict[@"attributes"];
                    break;
                }
            }

            // 返回结果
            if (certificate) {
                NSString *stringifiedPrivateKey = [[NSString alloc] initWithData:privateKey encoding:NSUTF8StringEncoding];
                completionHandler(nil, stringifiedPrivateKey, certificate);
            } else {
                NSString *desc = [NSString stringWithFormat:
                    @"submitDevelopmentCSR: 无法找到序列号为 '%@' 的证书", certificateSerialID];
                NSError *notFoundError = [EEProvisioning _errorFromString:desc];
                completionHandler(notFoundError, nil, nil);
            }
        }];
    }];
}

/**
 * 使用 OpenSSL 生成代码签名请求（CSR）
 *
 * 技术细节：
 * - RSA 2048 位密钥
 * - SHA-1 签名（Apple 要求）
 * - PEM 格式输出
 * - 证书主题：C=UK, ST=London, L=London, O=ReProvision, CN=ReProvision
 *
 * @param privateKeyOut 输出参数：生成的私钥（PEM 格式 NSData）
 * @param csrOut 输出参数：生成的 CSR（PEM 格式 NSData）
 * @return 成功返回 1，失败返回 0
 */
- (int)_generateCodeSigningRequest:(NSData **)privateKeyOut csrOut:(NSData **)csrOut {
    int ret = 0;
    RSA *r = NULL;
    BIGNUM *bne = NULL;

    int bits = 2048;  // RSA 密钥长度
    unsigned long e = RSA_F4;  // 公钥指数（65537）

    X509_REQ *x509_req = NULL;
    X509_NAME *x509_name = NULL;
    EVP_PKEY *pKey = NULL;
    BIO *csr = NULL;
    BIO *privKey = NULL;
    char *data = NULL;
    long len = 0;

    // 证书主题信息
    const char *szCountry = "UK";           // 国家
    const char *szCommon = "ReProvision";   // 通用名称
    const char *szProvince = "London";      // 省/州
    const char *szCity = "London";          // 城市
    const char *szOrganization = "ReProvision";  // 组织

    // 步骤 1: 生成 RSA 密钥对
    bne = BN_new();
    ret = BN_set_word(bne, (unsigned int)e);
    if (ret != 1) goto free_all;

    r = RSA_new();
    ret = RSA_generate_key_ex(r, bits, bne, NULL);
    if (ret != 1) goto free_all;

    // 步骤 2: 设置 X509 请求版本
    x509_req = X509_REQ_new();
    ret = X509_REQ_set_version(x509_req, 1);  // 版本 1
    if (ret != 1) goto free_all;

    // 步骤 3: 设置证书主题（Subject）
    x509_name = X509_REQ_get_subject_name(x509_req);

    ret = X509_NAME_add_entry_by_txt(x509_name, "C", MBSTRING_ASC,
                                     (const unsigned char *)szCountry, -1, -1, 0);
    if (ret != 1) goto free_all;

    ret = X509_NAME_add_entry_by_txt(x509_name, "ST", MBSTRING_ASC,
                                     (const unsigned char *)szProvince, -1, -1, 0);
    if (ret != 1) goto free_all;

    ret = X509_NAME_add_entry_by_txt(x509_name, "L", MBSTRING_ASC,
                                     (const unsigned char *)szCity, -1, -1, 0);
    if (ret != 1) goto free_all;

    ret = X509_NAME_add_entry_by_txt(x509_name, "O", MBSTRING_ASC,
                                     (const unsigned char *)szOrganization, -1, -1, 0);
    if (ret != 1) goto free_all;

    ret = X509_NAME_add_entry_by_txt(x509_name, "CN", MBSTRING_ASC,
                                     (const unsigned char *)szCommon, -1, -1, 0);
    if (ret != 1) goto free_all;

    // 步骤 4: 设置公钥
    pKey = EVP_PKEY_new();
    EVP_PKEY_assign_RSA(pKey, r);

    ret = X509_REQ_set_pubkey(x509_req, pKey);
    if (ret != 1) goto free_all;

    // 步骤 5: 使用 SHA-1 签名（Apple Portal 要求）
    ret = X509_REQ_sign(x509_req, pKey, EVP_sha1());
    if (ret <= 0) goto free_all;

    // 步骤 6: 导出 CSR 和私钥为 PEM 格式
    csr = BIO_new(BIO_s_mem());
    ret = PEM_write_bio_X509_REQ(csr, x509_req);

    privKey = BIO_new(BIO_s_mem());
    ret = PEM_write_bio_RSAPrivateKey(privKey, r, NULL, NULL, 0, NULL, NULL);

    // 将数据复制到输出参数
    len = BIO_get_mem_data(csr, &data);
    *csrOut = [NSData dataWithBytes:data length:len];

    len = BIO_get_mem_data(privKey, &data);
    *privateKeyOut = [NSData dataWithBytes:data length:len];

    // 步骤 7: 清理资源
free_all:
    r = NULL;  // EVP_PKEY_free 会释放 RSA

    X509_REQ_free(x509_req);
    BIO_free_all(csr);
    BIO_free_all(privKey);

    EVP_PKEY_free(pKey);
    BN_free(bne);

    return (ret == 1);
}

#pragma mark - Stage 3: App ID 管理 + Entitlements 配置

/**
 * Stage 3: 添加或更新 App ID，配置 Entitlements
 *
 * 功能：
 * 1. 检查 App ID 是否已存在
 * 2. 从二进制文件提取 entitlements
 * 3. 根据账户类型（免费/付费）过滤可用权限
 * 4. 创建或更新 App ID
 * 5. 处理 App Groups 分配
 */
- (void)_provisioningStageThreeWithIdentifier:(NSString *)identifier
                             applicationName:(NSString *)applicationName
                              binaryLocation:(NSString *)binaryLocation
                                 andCallback:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {

    [self _addOrUpdateApplicationID:identifier
                     applicationName:applicationName
                      binaryLocation:binaryLocation
                 withCompletionHandler:^(NSError *error, NSString *appIdId, NSDictionary *entitlements) {
        completionHandler(error, appIdId, entitlements);
    }];
}

/**
 * 添加或更新 App ID 的核心逻辑
 *
 * 这是 iOS17 签名的关键环节：
 * - 免费账户只能使用有限的 10 个 entitlement 键
 * - 付费账户可以使用更多高级权限
 * - application-identifier 必须正确设置 TeamID 前缀
 */
- (void)_addOrUpdateApplicationID:(NSString *)applicationIdentifier
                  applicationName:(NSString *)applicationName
                   binaryLocation:(NSString *)binaryLocation
              withCompletionHandler:(void (^)(NSError *, NSString *, NSDictionary *))completionHandler {

    [self.appleServices listAllApplicationsForTeamID:[self.appleServices currentTeamID]
                                         systemType:EESystemTypeUndefined
                                 withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            NSError *listError = [EEProvisioning _errorFromString:
                [NSString stringWithFormat:@"listAllApplicationsForTeamID: %@", error.localizedDescription]];
            completionHandler(listError, @"", nil);
            return;
        }

        int resultCode = [[plist objectForKey:@"resultCode"] intValue];
        if (resultCode != 0) {
            NSError *resultError = [EEProvisioning _errorFromString:
                [NSString stringWithFormat:@"listAllApplicationsForTeamID: %@", [plist objectForKey:@"resultString"]]];
            completionHandler(resultError, @"", nil);
            return;
        }

        // 检查 App ID 是否已存在
        BOOL appIdExists = NO;
        NSString *appIdIdIfExists = @"";
        NSString *fullIdentifier = @"";

        for (NSDictionary *appIdDictionary in plist[@"appIds"]) {
            if ([(NSString *)[appIdDictionary objectForKey:@"name"] isEqualToString:applicationName] ||
                [(NSString *)[appIdDictionary objectForKey:@"identifier"] isEqualToString:applicationIdentifier]) {
                appIdExists = YES;
                appIdIdIfExists = [appIdDictionary objectForKey:@"appIdId"];
                fullIdentifier = [appIdDictionary objectForKey:@"identifier"];
                break;
            }
        }

        // 准备应用信息
        NSString *name = applicationName;
        // 移除非字母数字字符
        NSCharacterSet *charactersToRemove = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        name = [[name componentsSeparatedByCharactersInSet:charactersToRemove] componentsJoinedByString:@" "];

        NSString *identifier = applicationIdentifier;
        NSMutableDictionary *enabledFeatures = [NSMutableDictionary dictionary];

        // 从二进制文件提取并更新 entitlements
        NSMutableDictionary *entitlements = [[EESigning updateEntitlementsForBinaryAtLocation:binaryLocation
                                                                             bundleIdentifier:identifier
                                                                                       teamID:[self.appleServices currentTeamID]] mutableCopy];

        // ★★★ 双重 TeamID 前缀修复 ★★★
        // 如果 identifier 已经包含 TeamID 前缀（如 "TEAMID.com.app"），直接使用
        // 否则添加前缀（如 "com.app" → "TEAMID.com.app"）
        NSString *currentTeamID = [self.appleServices currentTeamID];
        NSString *teamIdPrefix = [NSString stringWithFormat:@"%@.", currentTeamID];
        NSString *applicationId;

        if ([identifier hasPrefix:teamIdPrefix]) {
            // 已有前缀，直接使用
            applicationId = identifier;
        } else {
            // 无前缀，添加 TeamID
            applicationId = [NSString stringWithFormat:@"%@.%@", currentTeamID, identifier];
        }
        [entitlements setObject:applicationId forKey:@"application-identifier"];

        // 查询用户账户类型（免费 or 付费）
        [self.appleServices listTeamsWithCompletionHandler:^(NSError *error, NSDictionary *dictionary) {
            // 出错时默认为免费用户，避免死锁
            BOOL isFreeUser = YES;
            NSArray *teams = nil;

            if (error) {
                NSLog(@"[RePro] listTeamsWithCompletionHandler 错误: %@。默认使用免费用户模式。", error.localizedDescription);
            } else {
                // 检查当前 Team ID 是否来自免费账户
                teams = [dictionary objectForKey:@"teams"];
                isFreeUser = YES;

                for (NSDictionary *team in teams) {
                    NSString *teamIdToCheck = [team objectForKey:@"teamId"];

                    if ([teamIdToCheck isEqualToString:[self.appleServices currentTeamID]]) {
                        NSArray *memberships = [team objectForKey:@"memberships"];

                        for (NSDictionary *membership in memberships) {
                            NSString *name = [membership objectForKey:@"name"];
                            NSString *platform = [membership objectForKey:@"platform"];
                            // 检查是否是付费开发者计划成员
                            if ([name containsString:@"Apple Developer Program"] && [platform isEqualToString:@"ios"]) {
                                isFreeUser = NO;
                                break;
                            }
                        }

                        if (!isFreeUser) break;
                    }
                }
            }

            // ★★★ 付费账户专属 entitlements ★★★
            if (!isFreeUser) {
                // 以下功能仅付费账户可用
                NSDictionary *paidEntitlementsToFeatures = @{
                    @"com.apple.developer.networking.networkextension": @"NWEXT04537",
                    @"com.apple.developer.networking.multipath": @"MP49FN762P",
                    @"com.apple.networking.vpn.configuration": @"V66P55NK2I",
                    @"com.apple.developer.siri": @"SI015DKUHP"
                };

                for (NSString *key in [paidEntitlementsToFeatures allKeys]) {
                    if ([[entitlements allKeys] containsObject:key]) {
                        NSString *feature = [paidEntitlementsToFeatures objectForKey:key];
                        [enabledFeatures setObject:@"on" forKey:feature];
                    }
                }
            }

            // ★★★ 免费和付费账户都可用的 entitlements ★★★
            NSDictionary *freeAndPaidEntitlementsToFeatures = @{
                @"inter-app-audio": @"IAD53UNK2F",
                @"com.apple.external-accessory.wireless-configuration": @"WC421J6T7P",
                @"com.apple.developer.homekit": @"homeKit",
                @"com.apple.developer.healthkit": @"HK421J6T7P",
                @"com.apple.developer.default-data-protection": @"dataProtection"
            };

            for (NSString *key in [freeAndPaidEntitlementsToFeatures allKeys]) {
                if ([[entitlements allKeys] containsObject:key]) {
                    NSString *feature = [freeAndPaidEntitlementsToFeatures objectForKey:key];

                    // 特殊处理 dataProtection 权限级别
                    if ([feature isEqualToString:@"dataProtection"]) {
                        NSString *entitlementValue = [entitlements objectForKey:key];
                        NSString *featureValue = @"";

                        if ([entitlementValue isEqualToString:@"NSFileProtectionComplete"])
                            featureValue = @"complete";
                        else if ([entitlementValue isEqualToString:@"NSFileProtectionCompleteUnlessOpen"])
                            featureValue = @"unlessopen";
                        else if ([entitlementValue isEqualToString:@"NSFileProtectionCompleteUntilFirstUserAuthentication"])
                            featureValue = @"untilfirstauth";

                        [enabledFeatures setObject:featureValue forKey:feature];
                    } else {
                        [enabledFeatures setObject:@"on" forKey:feature];
                    }
                }
            }

            /*
             * 免费和付费开发账户都允许使用的 entitlements（隐式）：
             * - com.apple.security.application-groups （稍后单独处理）
             * - keychain-access-groups （隐式）
             * - application-identifier （隐式）
             * - com.apple.developer.team-identifier （隐式）
             * - get-task-allow （稍后移除）
             */

            // ★★★ 免费账户白名单过滤（iOS17 签名铁律）★★★
            if (isFreeUser) {
                // 只允许这 10 个 entitlement 键（iOS17 强制限制）
                NSArray *freeCertificateAllowableEntitlements = @[
                    @"application-identifier",
                    @"com.apple.developer.team-identifier",
                    @"keychain-access-groups",
                    @"com.apple.security.application-groups",
                    @"com.apple.developer.default-data-protection",
                    @"com.apple.developer.healthkit",
                    @"com.apple.developer.homekit",
                    @"com.apple.external-accessory.wireless-configuration",
                    @"inter-app-audio",
                    @"get-task-allow"
                ];

                // 移除不在白名单中的 entitlements
                for (NSString *key in [[entitlements allKeys] copy]) {
                    if (![freeCertificateAllowableEntitlements containsObject:key]) {
                        [entitlements removeObjectForKey:key];
                    }
                }
            }

            // ★★★ App Groups 处理 ★★★
            // APG3427HIY 是 Apple Developer Portal 中 App Groups 的 feature ID
            BOOL wantsApplicationGroups = NO;
            NSMutableArray *applicationGroups = nil;

            if ([[entitlements allKeys] containsObject:@"com.apple.security.application-groups"]) {
                [enabledFeatures setObject:@"on" forKey:@"APG3427HIY"];
                wantsApplicationGroups = YES;
                applicationGroups = [[entitlements objectForKey:@"com.apple.security.application-groups"] mutableCopy];
            }

            if (!appIdExists) {
                // 创建新的 App ID
                NSLog(@"[RePro] App ID 不存在，创建新的...");

                [self.appleServices addApplicationId:identifier
                                               name:name
                                    enabledFeatures:enabledFeatures
                                            teamID:[self.appleServices currentTeamID]
                                        entitlements:entitlements
                                          systemType:EESystemTypeUndefined
                                 withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        NSError *addError = [EEProvisioning _errorFromString:
                            [NSString stringWithFormat:@"addApplicationId: %@", error.localizedDescription]];
                        completionHandler(addError, @"", nil);
                        return;
                    }

                    int resultCode = [[plist objectForKey:@"resultCode"] intValue];
                    if (resultCode != 0) {
                        NSError *addResultError = [EEProvisioning _errorFromString:
                            [NSString stringWithFormat:@"addApplicationId: %@", [plist objectForKey:@"userString"]]];
                        completionHandler(addResultError, @"", nil);
                        return;
                    }

                    // 获取新创建的 App ID
                    NSString *newAppIdId;
                    @try {
                        newAppIdId = [[plist objectForKey:@"appId"] objectForKey:@"appIdId"];
                    } @catch (NSException *e) {
                        newAppIdId = @"";
                    }

                    // 如果需要，分配 App Groups
                    if (wantsApplicationGroups) {
                        [self _recursivelyAssignApplicationIdId:newAppIdId
                                            toApplicationGroups:applicationGroups
                                               interimAppGroups:[NSMutableArray array]
                                                withCompletionHandler:^(NSError *error, NSArray *output) {
                            if (error) {
                                completionHandler(error, nil, nil);
                                return;
                            }

                            // 更新 entitlements 中的 App Groups
                            [entitlements setObject:output forKey:@"com.apple.security.application-groups"];
                            completionHandler(nil, newAppIdId, entitlements);
                        }];
                    } else {
                        completionHandler(nil, newAppIdId, entitlements);
                    }
                }];

            } else {
                // 更新现有 App ID
                NSLog(@"[RePro] App ID 已存在，更新中...");

                [self.appleServices updateApplicationIdId:appIdIdIfExists
                                         enabledFeatures:enabledFeatures
                                                 teamID:[self.appleServices currentTeamID]
                                             entitlements:entitlements
                                               systemType:EESystemTypeUndefined
                                      withCompletionHandler:^(NSError *error, NSDictionary *plist) {
                    if (error) {
                        NSError *updateError = [EEProvisioning _errorFromString:
                            [NSString stringWithFormat:@"updateApplicationIdId: %@", error.localizedDescription]];
                        completionHandler(updateError, @"", nil);
                        return;
                    }

                    int resultCode = [[plist objectForKey:@"resultCode"] intValue];
                    if (resultCode != 0) {
                        NSError *updateResultError = [EEProvisioning _errorFromString:
                            [NSString stringWithFormat:@"updateApplicationIdId: %@", [plist objectForKey:@"userString"]]];
                        completionHandler(updateResultError, @"", nil);
                        return;
                    }

                    // 获取更新的 App ID
                    NSString *newAppIdId;
                    @try {
                        newAppIdId = [[plist objectForKey:@"appId"] objectForKey:@"appIdId"];
                    } @catch (NSException *e) {
                        newAppIdId = @"";
                    }

                    // 如果需要，分配 App Groups
                    if (wantsApplicationGroups) {
                        [self _recursivelyAssignApplicationIdId:newAppIdId
                                            toApplicationGroups:applicationGroups
                                               interimAppGroups:[NSMutableArray array]
                                                withCompletionHandler:^(NSError *error, NSArray *output) {
                            if (error) {
                                completionHandler(error, nil, nil);
                                return;
                            }

                            // 更新 entitlements 中的 App Groups
                            [entitlements setObject:output forKey:@"com.apple.security.application-groups"];
                            completionHandler(nil, newAppIdId, entitlements);
                        }];
                    } else {
                        completionHandler(nil, newAppIdId, entitlements);
                    }
                }];
            }
        }];
    }];
}

#pragma mark - App Groups 递归分配

/**
 * 递归分配 App Groups 到 App ID
 *
 * 由于每个 Group 需要单独调用 API，这里采用递归方式逐个处理
 * 避免嵌套回调过深导致代码难以维护
 *
 * @param applicationIdId 要分配的 App ID
 * @param applicationGroups 待分配的 Group 列表
 * @param interimAppGroups 已完成的 Group 列表（累积结果）
 * @param completionHandler 完成回调，返回最终的 Group 标识符列表
 */
- (void)_recursivelyAssignApplicationIdId:(NSString *)applicationIdId
                      toApplicationGroups:(NSMutableArray *)applicationGroups
                         interimAppGroups:(NSMutableArray *)interimAppGroups
                      withCompletionHandler:(void (^)(NSError *, NSArray *))completionHandler {
    // 递归终止条件：所有 Group 都已处理完毕
    if (applicationGroups.count == 0) {
        completionHandler(nil, interimAppGroups);
        return;
    }

    // 取出下一个待处理的 Group
    NSString *nextApplicationGroup = [applicationGroups firstObject];

    [self _assignApplicationIdId:applicationIdId
              toGroupIfNecessary:nextApplicationGroup
               withCompletionHandler:^(NSError *error, NSString *groupIdentifier) {
        if (error) {
            completionHandler(error, nil);
            return;
        }

        // 从待处理列表中移除
        [applicationGroups removeObjectAtIndex:0];

        // 添加到已完成列表
        [interimAppGroups addObject:groupIdentifier];

        // 递归处理剩余的 Groups
        [self _recursivelyAssignApplicationIdId:applicationIdId
                            toApplicationGroups:applicationGroups
                               interimAppGroups:interimAppGroups
                            withCompletionHandler:completionHandler];
    }];
}

/**
 * 为 App ID 分配单个 Application Group
 *
 * 逻辑：
 * 1. 查询现有的 Groups 列表
 * 2. 检查是否已存在匹配的 Group（通过标识符模糊匹配）
 * 3. 如果存在，直接分配
 * 4. 如果不存在，创建新的 Group 再分配
 */
- (void)_assignApplicationIdId:(NSString *)applicationIdId
            toGroupIfNecessary:(NSString *)applicationGroupIdentifier
             withCompletionHandler:(void (^)(NSError *, NSString *))completionHandler {

    [self.appleServices listAllApplicationGroupsForTeamID:[self.appleServices currentTeamID]
                                             systemType:EESystemTypeUndefined
                                     withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error, nil);
            return;
        }

        if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
            NSError *listError = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
            completionHandler(listError, nil);
            return;
        }

        /*
         * 匹配逻辑：
         * 检查是否已存在包含 applicationGroupIdentifier 的 Group（去掉 "group." 前缀后匹配）
         * 如果存在，直接使用其完整标识符
         * 如果不存在，创建新的 Group
         */

        BOOL groupExists = NO;

        // 去掉 "group." 前缀
        NSString *callerGroupIDNoPrefix = [applicationGroupIdentifier stringByReplacingOccurrencesOfString:@"group." withString:@""];

        // 可能还有 UUID 前缀（如 "EE-xxx.identifier" 或 "AltStore-xxx.identifier"），需要去除
        if ([callerGroupIDNoPrefix hasPrefix:@"EE-"] || [callerGroupIDNoPrefix hasPrefix:@"AltStore"]) {
            NSRange range = [callerGroupIDNoPrefix rangeOfString:@"."];
            if (range.location != NSNotFound) {
                callerGroupIDNoPrefix = [callerGroupIDNoPrefix substringFromIndex:range.location + 1];
            }
        }

        NSString *groupIdentifierIfExists = @"";
        NSString *applicationGroupEntryIfExists = @"";

        // 遍历现有 Groups 查找匹配项
        for (NSDictionary *groupDictionary in plist[@"applicationGroupList"]) {
            if ([(NSString *)[groupDictionary objectForKey:@"identifier"] containsString:callerGroupIDNoPrefix]) {
                groupExists = YES;
                groupIdentifierIfExists = [groupDictionary objectForKey:@"identifier"];
                applicationGroupEntryIfExists = [groupDictionary objectForKey:@"applicationGroup"];
                break;
            }
        }

        if (groupExists) {
            // Group 已存在，直接分配
            [self _assignAppIdId:applicationIdId
        toApplicationGroupIdentifier:applicationGroupEntryIfExists
                 withCompletionHandler:^(NSError *error) {
                if (error) {
                    completionHandler(error, nil);
                    return;
                }

                completionHandler(nil, groupIdentifierIfExists);
            }];

        } else {
            // Group 不存在，创建新的
            NSString *newGroupIdentifier = [NSString stringWithFormat:@"group.%@.%@", callerGroupIDNoPrefix, [self.appleServices currentTeamID]];
            NSString *newGroupName = [NSString stringWithFormat:@"EE- group %@", [callerGroupIDNoPrefix stringByReplacingOccurrencesOfString:@"." withString:@" "]];

            [self.appleServices addApplicationGroupWithIdentifier:newGroupIdentifier
                                                        andName:newGroupName
                                                       forTeamID:[self.appleServices currentTeamID]
                                                      systemType:EESystemTypeUndefined
                                          withCompletionHandler:^(NSError *error,NSDictionary *plist) {
                if (error) {
                    completionHandler(error, nil);
                    return;
                }

                if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
                    NSError *addGroupError = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
                    completionHandler(addGroupError, nil);
                    return;
                }

                // 获取新创建的 Group 的 applicationGroup 标识
                NSString *newGroupName = [[plist objectForKey:@"applicationGroup"] objectForKey:@"applicationGroup"];

                // 将 App ID 分配到新创建的 Group
                [self _assignAppIdId:applicationIdId toApplicationGroupIdentifier:newGroupName withCompletionHandler:^(NSError *error) {
                    if (error) {
                        completionHandler(error, nil);
                        return;
                    }

                    completionHandler(nil, newGroupIdentifier);
                }];
            }];
        }
    }];
}

/// 执行实际的 App ID → Group 分配操作
- (void)_assignAppIdId:(NSString *)appIdId
toApplicationGroupIdentifier:(NSString *)groupIdentifier
     withCompletionHandler:(void (^)(NSError *))completionHandler {

    NSLog(@"[RePro] 正在将 appIdId '%@' 分配到应用组 '%@'", appIdId, groupIdentifier);

    [self.appleServices assignApplicationGroup:groupIdentifier
                              toApplicationIdId:appIdId
                                         teamID:[self.appleServices currentTeamID]
                                     systemType:EESystemTypeUndefined
                          withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error);
            return;
        }

        if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
            NSError *assignError = [EEProvisioning _errorFromString:[plist objectForKey:@"resultString"]];
            completionHandler(assignError);
            return;
        }

        completionHandler(nil);
    }];
}

#pragma mark - Stage 4: Provisioning Profile 管理

/**
 * Stage 4: 删除旧的 Provisioning Profile 并下载新的
 *
 * 步骤：
 * 1. 尝试删除该应用的旧 Profile（忽略错误）
 * 2. 下载新的 Development Provisioning Profile
 */
- (void)_provisioningStageFourWithIdentifier:(NSString *)identifier
                                     appIdId:(NSString *)appIdId
                                 andCallback:(void (^)(NSError *, NSData *))completionHandler {

    // 先删除旧 Profile（即使失败也继续）
    [self _removeExistingProvisioningProfileForApplication:identifier withCallback:^(NSError *error) {
        // 忽略删除结果

        NSLog(@"[RePro] 正在为 '%@' 获取新的 provisioning profile...", identifier);

        // 下载新 Profile
        [self _downloadTeamProvisioningProfileForAppIdId:appIdId withCallback:^(NSError *error, NSData *result) {
            completionHandler(error, result);
        }];
    }];
}

/**
 * 从 Apple Developer Portal 下载 Provisioning Profile
 */
- (void)_downloadTeamProvisioningProfileForAppIdId:(NSString *)appIdId
                                      withCallback:(void (^)(NSError *, NSData *))completionHandler {

    [self.appleServices getProvisioningProfileForAppIdId:appIdId
                                               withTeamID:[self.appleServices currentTeamID]
                                              systemType:EESystemTypeUndefined
                                             andCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            NSError *downloadError = [EEProvisioning _errorFromString:
                [NSString stringWithFormat:@"getProvisioningProfileForAppIdId: %@", error.localizedDescription]];
            completionHandler(downloadError, nil);
            return;
        }

        if ([[plist objectForKey:@"resultCode"] intValue] != 0) {
            NSError *resultError = [EEProvisioning _errorFromString:
                [NSString stringWithFormat:@"getProvisioningProfileForAppIdId: %@", [plist objectForKey:@"resultString"]]];
            completionHandler(resultError, nil);
            return;
        }

        @try {
            NSDictionary *profile = [plist objectForKey:@"provisioningProfile"];
            NSData *encodedProfile = [profile objectForKey:@"encodedProfile"];

            completionHandler(nil, encodedProfile);
        } @catch (NSException *e) {
            NSError *exceptionError = [EEProvisioning _errorFromString:
                [NSString stringWithFormat:@"getProvisioningProfileForAppIdId: %@", e.reason]];
            completionHandler(exceptionError, nil);
        }
    }];
}

/**
 * 删除指定应用的旧 Provisioning Profile
 *
 * 注意：这里会尝试删除，但不会因为删除失败而中断流程
 */
- (void)_removeExistingProvisioningProfileForApplication:(NSString *)bundleIdentifier
                                            withCallback:(void (^)(NSError *))completionHandler {

    NSLog(@"[RePro] 尝试撤销 '%@' 的旧 provisioning profile...", bundleIdentifier);

    // 构造完整的 application-identifier（带 TeamID 前缀）
    NSString *_actualIdentifier = [NSString stringWithFormat:@"%@.%@", [self.appleServices currentTeamID], bundleIdentifier];

    [self.appleServices deleteProvisioningProfileForApplication:_actualIdentifier
                                                      andTeamID:[self.appleServices currentTeamID]
                                                      systemType:EESystemTypeUndefined
                                           withCompletionHandler:^(NSError *error, NSDictionary *plist) {
        if (error) {
            completionHandler(error);
            return;
        }

        // 完成（无论是否真的删除了）
        completionHandler(nil);
    }];
}

@end
