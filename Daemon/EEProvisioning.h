//
//  EEProvisioning.h
//  ReProvision Daemon
//
//  Apple Developer Portal 交互模块（从旧项目 ReProvision-Reborn 精简移植）
//  功能：Apple ID 登录、证书申请(CSR)、App ID 管理、Provisioning Profile 下载
//
//  移植说明：
//  - 原项目使用 SAMKeychain 做存储 → 改为文件存储（/var/mobile/Library/Preferences/）
//  - 原项目依赖 EEAppleServices 单例 → 改为实例属性注入
//  - 去掉 watchOS/tvOS 分支，仅支持 iOS
//

#import <Foundation/Foundation.h>

@class EEAppleServices;

NS_ASSUME_NONNULL_BEGIN

@interface EEProvisioning : NSObject

/// Apple Services 实例（外部注入，不再使用单例）
@property (nonatomic, strong) EEAppleServices *appleServices;

/// Apple ID 身份标识
@property (nonatomic, copy) NSString *identity;

/// Apple ID 认证令牌（GS Token）
@property (nonatomic, copy) NSString *gsToken;

/**
 * 使用指定凭据创建 provisioning 实例
 *
 * @param identity Apple ID 的 DSIS 身份标识
 * @param gsToken 关联的 GS 认证令牌
 * @return 配置好的 EEProvisioning 实例
 *
 * 注意：如果使用双重认证，请确保已生成 App-Specific 密码
 */
+ (instancetype)provisionerWithCredentials:(NSString *)identity
                                  gsToken:(NSString *)gsToken;

/**
 * 将当前设备注册到 Apple Developer Portal 的团队中
 * 通常只需调用一次，例如在验证用户凭据时
 *
 * @param udid 设备 UDID
 * @param name 设备名称
 * @param teamIDCallback 用于从团队列表中选择 Team ID 的回调
 * @param completionHandler 完成回调，error 为 nil 表示成功
 */
- (void)provisionDevice:(NSString *)udid
                   name:(NSString *)name
       withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
            andCallback:(void (^)(NSError *))completionHandler;

/**
 * 撤销当前机器的开发证书
 *
 * @param teamIDCallback 用于从团队列表中选择 Team ID 的回调
 * @param completionHandler 完成回调，error 为 nil 表示成功
 */
- (void)revokeCertificatesWithTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
                              andCallback:(void (^)(NSError *))completionHandler;

/**
 * 主入口方法：为指定应用下载完整的 Provisioning Profile
 *
 * 执行完整的4阶段流程：
 * Stage 1: 登录 + 获取 Team ID
 * Stage 2: 检查/创建开发证书（CSR + 提交）
 * Stage 3: 添加/更新 App ID + entitlements
 * Stage 4: 删除旧 profile + 下载新 profile
 *
 * @param identifier 应用的 bundle identifier
 * @param applicationName 应用名称
 * @param binaryLocation 二进制文件路径（用于提取 entitlements）
 * @param teamIDCallback 用于从团队列表中选择 Team ID 的回调
 * @param completionHandler 完成回调
 *        - error: 错误信息，nil 表示成功
 *        - embeddedMobileprovision: 下载的 provisioning profile 数据
 *        - privateKey: 开发证书的私钥（PEM 格式字符串）
 *        - certificate: 证书信息字典
 *        - entitlements: 最终的 entitlements 字典
 */
- (void)downloadProvisioningProfileForApplicationIdentifier:(NSString *)identifier
                                           applicationName:(NSString *)applicationName
                                           binaryLocation:(NSString *)binaryLocation
                                          withTeamIDCheck:(NSString * (^)(NSArray *))teamIDCallback
                                               andCallback:(void (^)(NSError *_Nullable,
                                                                    NSData *_Nullable,
                                                                    NSString *_Nullable,
                                                                    NSDictionary *_Nullable,
                                                                    NSDictionary *_Nullable))completionHandler;

@end

NS_ASSUME_NONNULL_END
