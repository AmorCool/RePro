//
//  RPVBridge.h
//  RePro
//
//  Swift <-> ReProvision 业务层桥接。
//
//  设计原则：
//  1. Swift 侧只依赖本文件里的纯数据对象（RPVAppInfo / RPVLoginResult），
//     绝不直接接触 RPVApplication / LSApplicationProxy 等私有类型。
//  2. 所有耗时操作在后台队列执行，回调统一切回主队列。
//  3. 业务实现全部复用 Vendor/ReProvision（原版 ReProvision 源码），
//     本桥接层不重新实现任何签名 / 登录逻辑。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 数据对象

/// 设备上一个已安装（旁加载）应用的快照
@interface RPVAppInfo : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, strong, nullable) NSDate *expiryDate;
/// 图标的 PNG 数据（在后台队列取好，避免 Swift 侧再触碰 UIImage 渲染）
@property (nonatomic, strong, nullable) NSData *iconPNGData;
@property (nonatomic, assign) BOOL hasEmbeddedProvision;
/// 原始签名者的 Team ID（「其他应用」中显示，用于区分非当前账户签名的应用）
@property (nonatomic, copy, nullable) NSString *originalTeamID;
@end

/// 登录结果分类
typedef NS_ENUM(NSInteger, RPVLoginOutcome) {
    /// 登录成功，teams 里是可选的开发者 Team 列表
    RPVLoginOutcomeSuccess      NS_SWIFT_NAME(succeeded)      = 0,
    /// 账号开了两步验证，需要走 App 专用密码回退流程
    RPVLoginOutcomeNeeds2FA     NS_SWIFT_NAME(needsTwoFactor) = 1,
    /// 登录失败，failureReason 为原因
    RPVLoginOutcomeFailure      NS_SWIFT_NAME(failed)         = 2,
};

@interface RPVLoginResult : NSObject
@property (nonatomic, assign) RPVLoginOutcome outcome;
@property (nonatomic, copy, nullable) NSString *failureReason;
@property (nonatomic, copy, nullable) NSString *resultCode;
/// Apple 返回的原始 Team 字典数组，元素含 teamId / name 等键
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *teams;
@end

/// 运行环境体检快照（「状态」页展示用）。
/// 全部为进程内可直接探测的事实，不依赖任何常驻服务。
@interface RPVEnvironmentInfo : NSObject
/// 越狱类型标识：dopamine / roothide / rootful / unknown
@property (nonatomic, copy) NSString *jailbreakKind;
/// 解析出的越狱根目录（rootful 为 "/"，未越狱为 nil）
@property (nonatomic, copy, nullable) NSString *jailbreakRoot;
/// zsign 可执行文件的绝对路径；只在 $PATH 兜底时为 nil
@property (nonatomic, copy, nullable) NSString *zsignPath;
/// 三张 Apple 根证书是否已随 App 打包（EESigning 依赖 mainBundle 读取）
@property (nonatomic, assign) BOOL certificatesBundled;
/// 按需 root helper 是否已安装
@property (nonatomic, assign) BOOL rootHelperAvailable;
@property (nonatomic, copy, nullable) NSString *rootHelperPath;
/// 账号信息
@property (nonatomic, assign) BOOL signedIn;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *teamID;
@property (nonatomic, copy, nullable) NSString *deviceUDID;
/// 扫描到的旁加载应用数量与最近的一个到期时间
@property (nonatomic, assign) NSInteger sideloadedAppCount;
@property (nonatomic, strong, nullable) NSDate *nearestExpiryDate;
@end

#pragma mark - 已注册 AppID

/// Apple 开发者账号下已注册的 App ID（来自 listAppIds.action）
/// 说明：本类为桥接层自定义数据模型，刻意与 Vendor/ReProvision/Support/RPVAppID 重名类区分，
/// 这里会把 expirationDate（Unix 时间戳或 ISO 8601 字符串）解析为 NSDate，供 Swift 侧 RegisteredAppID 使用。
@interface RPVRegisteredAppID : NSObject
@property (nonatomic, copy) NSString *identifier;        // bundle identifier
@property (nonatomic, copy) NSString *applicationName;   // App 名称
@property (nonatomic, strong, nullable) NSDate *applicationExpiryDate; // 已解析为 NSDate
- (instancetype)initWithDictionary:(NSDictionary *)dict;
@end

#pragma mark - 开发者证书

/// Apple 开发者账号下的开发证书（来自 certificates API）
@interface RPVCertificateInfo : NSObject
@property (nonatomic, copy) NSString *identifier;        // 证书 ID（用于撤销）
@property (nonatomic, copy) NSString *serialNumber;      // 序列号
@property (nonatomic, copy) NSString *machineName;       // 设备名
@property (nonatomic, copy) NSString *machineId;         // 机器标识（与本机 uuid 比对可判定是否本机证书）
@property (nonatomic, copy) NSString *applicationName;   // 来源应用（ReProvision / AltStore / Xcode 等）
- (instancetype)initWithDictionary:(NSDictionary *)dict;
@end

#pragma mark - 桥接主类

@interface RPVBridge : NSObject

+ (instancetype)sharedInstance;

#pragma mark 账号状态

/// 已保存的 Apple ID（未登录为 nil）
@property (nonatomic, readonly, copy, nullable) NSString *username;
/// 已保存的 Team ID（未登录为 nil）
@property (nonatomic, readonly, copy, nullable) NSString *teamID;
/// 已保存的密码（登录前预填用；未登录为 nil）。存储的是 Apple 返回的 gsToken。
@property (nonatomic, readonly, copy, nullable) NSString *savedPassword;
/// 三要素（账号 / 密码 / TeamID）齐全才算已登录
@property (nonatomic, readonly) BOOL isSignedIn;
/// 把已登录 Apple ID 密码 + 签名状态项的 Keychain accessible 升级为 AfterFirstUnlock（见 RPVResources）
+ (void)migrateKeychainAccessibility;
/// 当前设备的机器标识（machineId）。与证书的 machineId 比对可判定该证书是否属于本机。
/// 尚未生成过（从未签名）时返回 nil。
+ (nullable NSString *)currentMachineIdentifier;
/// 当前设备 UDID（供界面展示 / 排障）
@property (nonatomic, readonly, copy, nullable) NSString *deviceUDID;

#pragma mark 登录流程（照搬原版 RPVAccountViewController 的调用顺序）

/// 第一步：用 Apple ID + 密码登录。
/// 返回 Success 时 teams 非空，需要调用 -selectTeamID: 落库；
/// 返回 Needs2FA 时需要接着调用 -continueTwoFactorAuthenticationWithCompletion:。
- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(void (^)(RPVLoginResult *result))completion
    NS_SWIFT_NAME(login(username:password:completion:));

/// 第二步（仅 2FA 账号）：走原版 RPVAccount2FAViewController 的回退通道。
///
/// 注意：这里**不需要**用户在 App 里输入验证码或 App 专用密码。
/// RPVAuthentication.fallback2FACodeRequest 会复用上一步缓存的账号密码，
/// 通过 AuthKit 触发系统级的 Apple ID 验证界面，用户在系统弹窗里完成
/// 验证之后本回调才会返回。原版就是 viewWillAppear 里直接调用它的。
- (void)continueTwoFactorAuthenticationWithCompletion:(void (^)(RPVLoginResult *result))completion
    NS_SWIFT_NAME(continueTwoFactorAuthentication(completion:));

/// 第三步：选定 Team 并持久化账号信息（写入钥匙串）。
/// 内部会顺带把当前设备注册到该 Team 下（原版 RPVAccountFinalController 的行为）。
- (void)selectTeamID:(NSString *)teamID
          completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(selectTeamID(_:completion:));

/// 退出登录，清除钥匙串中的账号信息
- (void)signOut;

#pragma mark 应用列表

/// 拉取设备上的旁加载应用。
/// 已登录时优先按当前 Team ID 过滤；结果为空或未登录时回退列出全部带
/// embedded.mobileprovision 的应用，保证登录前界面也不是空白。
- (void)fetchInstalledAppsWithCompletion:(void (^)(NSArray<RPVAppInfo *> *apps,
                                                   NSError *_Nullable error))completion
    NS_SWIFT_NAME(fetchInstalledApps(completion:));

/// 拉取「其他应用」——设备上已安装但**不是**当前 Apple ID（Team ID）签名的应用。
/// 这些应用可能由其他开发者工具（Xcode / AltStore / 旧版 ReProvision 等）签名，
/// 包括已过期的应用。用户可以选择用当前账户重新签名。
- (void)fetchOtherAppsWithCompletion:(void (^)(NSArray<RPVAppInfo *> *apps,
                                                NSError *_Nullable error))completion
    NS_SWIFT_NAME(fetchOtherApps(completion:));

#pragma mark 重签名

/// 签名进度回调（0-100），在主队列触发
@property (nonatomic, copy, nullable) void (^signingProgressHandler)(NSString *bundleIdentifier, int progress);
/// 单个应用出错，在主队列触发
@property (nonatomic, copy, nullable) void (^signingErrorHandler)(NSString *bundleIdentifier, NSError *error);
/// 整条流水线结束，在主队列触发（error 为 nil 表示全部成功）
@property (nonatomic, copy, nullable) void (^signingCompletionHandler)(NSError *_Nullable error);

/// 重签指定 bundle identifier 的应用
- (void)resignApplicationWithBundleIdentifier:(NSString *)bundleIdentifier
                                   completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(resignApplication(bundleIdentifier:completion:));

/// 重签所有临近过期的应用（threshold 单位为天）
- (void)resignAllExpiringApplicationsWithThreshold:(int)thresholdDays
                                        completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(resignAllExpiringApplications(thresholdDays:completion:));

/// 重签所有应用（不按阈值过滤，用户手动触发的批量刷新）
- (void)resignAllApplicationsWithCompletion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(resignAllApplications(completion:));

/// 卸载指定应用
- (BOOL)removeApplicationWithBundleIdentifier:(NSString *)bundleIdentifier
    NS_SWIFT_NAME(removeApplication(bundleIdentifier:));

#pragma mark IPA 导入

/// 解析并安装一个 .ipa（等价于原版「导入 → 详情页点 INSTALL」两步）
- (void)importAndInstallIPAAtURL:(NSURL *)url
                      completion:(void (^)(RPVAppInfo *_Nullable info, NSError *_Nullable error))completion
    NS_SWIFT_NAME(importAndInstallIPA(url:completion:));

/// 检测 IPA 是否包含 App 扩展（Payload/*/PlugIns/*.appex）。
/// 用于导入前决定是否需要弹窗让用户选择扩展处理方式。
/// 注：RPVIpaBundleApplication._loadFileWithFormat: 只展开单个 "*" 通配目录，
/// 故这里用 "Payload/*/PlugIns/*/Info.plist" 来探测 PlugIns 下的子 bundle。
+ (BOOL)ipaContainsExtensionsAtURL:(NSURL *)url
    NS_SWIFT_NAME(ipaContainsExtensions(at:));

/// 透传本次导入的「扩展处理」选项给 EEBackend（仅影响本次导入签名，单点/批量重签不受影响）。
/// - removeExtensions: 签名前删除所有 PlugIns/*.appex（移除扩展）
/// - useMainProfile:   扩展不再各自向 Apple 注册 App ID，而是复用团队通配符 profile（TEAMID.*）签名；
///                      若该通配 profile 获取失败，自动回退为各自注册（不破坏主 App 签名）
+ (void)setExtensionImportOptionsRemoveExtensions:(BOOL)remove
                       useMainProfileForExtensions:(BOOL)useMain
    NS_SWIFT_NAME(setExtensionImportOptions(removeExtensions:useMainProfile:));

/// 修复当前插件联网问题（国行蜂窝/WiFi 数据策略重置）。设置页「修复当前插件联网问题」按钮调用，
/// 同步拉起 repro-helper fix-cellular，只把 ReSign 自身的蜂窝/WiFi 策略重置为「始终允许」并刷新 cfprefsd。
/// 仅手动触发，无 daemon 自动循环。completion 在主队列回调。
- (void)fixCellularDataWithCompletion:(void (^)(BOOL success, NSString *_Nullable message))completion
    NS_SWIFT_NAME(fixCellularData(completion:));

#pragma mark 环境体检

/// 采集运行环境快照（磁盘 IO 在后台队列，回调在主队列）
- (void)fetchEnvironmentInfoWithCompletion:(void (^)(RPVEnvironmentInfo *info))completion
    NS_SWIFT_NAME(fetchEnvironmentInfo(completion:));

#pragma mark 已注册 AppIDs

/// 拉取当前 Team 下已注册的 App ID 列表（来自 Apple listAppIds.action）
- (void)fetchAppIDsWithCompletion:(void (^)(NSArray<RPVRegisteredAppID *> *_Nullable appIds,
                                          NSError *_Nullable error))completion
    NS_SWIFT_NAME(fetchAppIDs(completion:));

#pragma mark 证书管理

/// 拉取当前 Team 下的开发证书列表（来自 Apple certificates API）
- (void)fetchCertificatesWithCompletion:(void (^)(NSArray<RPVCertificateInfo *> *_Nullable certs,
                                                  NSError *_Nullable error))completion
    NS_SWIFT_NAME(fetchCertificates(completion:));

/// 撤销指定证书
- (void)revokeCertificateWithIdentifier:(NSString *)identifier
                            completion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(revokeCertificate(identifier:completion:));

/// 撤销所有证书（逐个调用 revokeCertificateForIdentifier）
- (void)revokeAllCertificatesWithCompletion:(void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(revokeAllCertificates(completion:));

/// 重启 SpringBoard（respring）。
/// 通过 sysctl(KERN_PROC_ALL) 枚举进程，按 executable name 匹配 SpringBoard，发送 SIGTERM。
/// 参考 RebootTools / TrollStore TSUtil.m 方案，不依赖任何外部二进制。
/// 返回 YES 表示成功找到并发送了信号。
- (BOOL)respring;

#pragma mark 系统描述文件管理（v1.1.171）

/// 读取 repro-profiledaemon 导出的系统描述文件清单快照。
/// 清单来自真实的 /var/Managed Preferences/mobile（App 是 uid 501 且受沙盒约束，
/// 不能直接列举该目录，统一由 root daemon 导出 plist）。
/// 每项键：fileName / appId / displayName / uuid / sizeBytes /
///        isStableName / parsed / creationDate / expirationDate / modifiedDate。
+ (NSArray<NSDictionary<NSString *, id> *> *)managedProfilesInventory;

/// 让 daemon 重新导出一次清单（不做任何删除）。返回 YES 表示清单已刷新。
+ (BOOL)refreshManagedProfilesInventory;

/// 请求 daemon 清理系统描述文件：删除已过期/损坏的，并按 application-identifier
/// 去重（同一个 App 只保留最新一份）。返回 daemon 回写的结果描述，失败返回 nil。
+ (nullable NSString *)requestManagedProfileCleanup;

/// 请求 daemon 删除指定文件名的描述文件（只接受纯文件名，daemon 侧会再校验一次）。
+ (nullable NSString *)requestManagedProfileDeletion:(NSArray<NSString *> *)fileNames;

#pragma mark root helper 注入点

/// 注册需要 root 权限的两个回调（写系统描述文件、跨沙箱复制文件）。
/// 目前为空实现：Vendor 侧在 handler 未注册时会退回直接写 / MCProfileConnection。
/// Phase 3 会在这里 posix_spawn 按需 root helper。
+ (void)installRootHelperHandlers;

@end

NS_ASSUME_NONNULL_END
