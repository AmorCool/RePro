//
//  EEAppleServices.h
//  RePro Daemon
//
//  Apple 开发者服务接口 - 精简移植版
//

#import <Foundation/Foundation.h>

#pragma mark - 系统类型枚举

typedef NS_ENUM(NSUInteger, EESystemType) {
    EESystemTypeUndefined,   // 未定义
    EESystemTypeiOS,         // iOS
    EESystemTypewatchOS,     // watchOS
    EESystemTypetvOS         // tvOS
};

#pragma mark - EEAppleServices 接口

@interface EEAppleServices : NSObject

/// 单例实例
+ (instancetype)sharedInstance;

/// 获取当前 Team ID
- (NSString *)currentTeamID;

/// 使用外部凭证建立会话（从 AnisetteManager 获取 identity 和 gsToken）
- (void)ensureSessionWithIdentity:(NSString *)identity
                          gsToken:(NSString *)token
              andCompletionHandler:(void (^)(NSError *error, NSDictionary *plist))completionHandler;

/// 使用用户名密码登录（保留兼容性，建议使用 ensureSessionWithIdentity）
- (void)signInWithUsername:(NSString *)email
                  password:(NSString *)password
       andCompletionHandler:(void (^)(NSError *, NSDictionary *, NSURLCredential *))completionHandler;

/// 请求双因素认证代码
- (void)requestTwoFactorLoginCodeWithCompletionHandler:(void (^)(NSError *))completion;

/// 验证登录代码
- (void)validateLoginCode:(NSString *)code
      andCompletionHandler:(void (^)(NSError *, NSDictionary *, NSURLCredential *))completionHandler;

/// 双因素认证备用请求
- (void)fallback2FACodeRequest:(void (^)(NSError *, NSDictionary *, NSURLCredential *))completionHandler;

/// 更新当前 Team ID（支持多团队选择）
- (void)updateCurrentTeamIDWithTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
                                andCallback:(void (^)(NSError *, NSString *))completionHandler;

/// 列出所有团队
- (void)listTeamsWithCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 添加设备到团队
- (void)addDevice:(NSString *)udid
       deviceName:(NSString *)name
         forTeamID:(NSString *)teamID
        systemType:(EESystemType)systemType
withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 列出团队中的设备
- (void)listDevicesForTeamID:(NSString *)teamID
                  systemType:(EESystemType)systemType
      withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 列出所有 App ID
- (void)listAllApplicationsForTeamID:(NSString *)teamID
                          systemType:(EESystemType)systemType
              withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 添加 App ID
- (void)addApplicationId:(NSString *)applicationIdentifier
                    name:(NSString *)applicationName
          enabledFeatures:(NSDictionary *)enabledFeatures
                   teamID:(NSString *)teamID
             entitlements:(NSDictionary *)entitlements
               systemType:(EESystemType)systemType
     withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 更新 App ID
- (void)updateApplicationIdId:(NSString *)appIdId
              enabledFeatures:(NSDictionary *)enabledFeatures
                       teamID:(NSString *)teamID
                 entitlements:(NSDictionary *)entitlements
                   systemType:(EESystemType)systemType
       withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 删除 App ID
- (void)deleteApplicationIdId:(NSString *)appIdId
                       teamID:(NSString *)teamID
                   systemType:(EESystemType)systemType
       withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 列出所有 App Group
- (void)listAllApplicationGroupsForTeamID:(NSString *)teamID
                               systemType:(EESystemType)systemType
                   withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 添加 App Group
- (void)addApplicationGroupWithIdentifier:(NSString *)identifier
                                  andName:(NSString *)groupName
                                forTeamID:(NSString *)teamID
                               systemType:(EESystemType)systemType
                   withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 分配 App Group 到 App ID
- (void)assignApplicationGroup:(NSString *)applicationGroup
              toApplicationIdId:(NSString *)appIdId
                         teamID:(NSString *)teamID
                     systemType:(EESystemType)systemType
           withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 列出开发证书（带过滤选项）
- (void)listAllDevelopmentCertificatesWithFiltering:(BOOL)useFilter
                                            teamID:(NSString *)teamID
                                         systemType:(EESystemType)systemType
                             withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 列出所有开发证书
- (void)listAllDevelopmentCertificatesForTeamID:(NSString *)teamID
                                     systemType:(EESystemType)systemType
                         withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 查看开发者信息
- (void)viewDeveloperWithCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 列出所有描述文件
- (void)listAllProvisioningProfilesForTeamID:(NSString *)teamID
                                 systemType:(EESystemType)systemType
                     withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 下载描述文件
- (void)getProvisioningProfileForAppIdId:(NSString *)appIdId
                              withTeamID:(NSString *)teamId
                              systemType:(EESystemType)systemType
                  andCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 删除描述文件
- (void)deleteProvisioningProfileForApplication:(NSString *)applicationId
                                      andTeamID:(NSString *)teamID
                                      systemType:(EESystemType)systemType
                          withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 按序列号吊销证书
- (void)revokeCertificateForSerialNumber:(NSString *)serialNumber
                              andTeamID:(NSString *)teamID
                              systemType:(EESystemType)systemType
                  withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 按标识符吊销证书
- (void)revokeCertificateForIdentifier:(NSString *)identifier
                            andTeamID:(NSString *)teamID
                            systemType:(EESystemType)systemType
                withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

/// 提交代码签名请求（CSR）
- (void)submitCodeSigningRequestForTeamID:(NSString *)teamId
                             machineName:(NSString *)machineName
                               machineID:(NSString *)machineID
                      codeSigningRequest:(NSData *)csr
                              systemType:(EESystemType)systemType
                  withCompletionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;

@end
