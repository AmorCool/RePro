//
//  AnisetteManager.h/m
//  ReProvision Daemon
//
//  本地 Anisette 数据生成模块
//  从 /var/lockdown/device_data.plist 收集设备信息
//  基于 HMAC-SHA256 生成 OTP（一次性密码）
//  完全本地化，不依赖远程服务器
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Anisette 设备信息结构
@interface AnisetteDeviceInfo : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *machineID;
@property (nonatomic, copy) NSString *deviceUDID;
@property (nonatomic, copy) NSString *deviceSerialNumber;
@property (nonatomic, copy) NSString *deviceModel;        // 如 "iPhone14,2"
@property (nonatomic, copy) NSString *deviceDescription;
@property (nonatomic, assign) uint32_t localUserID;
@property (nonatomic, assign) int64_t timestamp;
@property (nonatomic, copy) NSString *locale;              // "en_US"
@property (nonatomic, copy) NSString *timeZone;           // "America/New_York"
@end

/// Anisette 管理器
@interface AnisetteManager : NSObject

/// 单例
+ (instancetype)sharedManager;

/// 是否已初始化并就绪
- (BOOL)isReady;

/// 获取当前设备信息
- (AnisetteDeviceInfo *)deviceInfo;

/// 生成当前 OTP
- (NSString *)generateOTP;

/// 构造完整的 Anisette HTTP 请求头字典
- (NSDictionary<NSString *, NSString *> *)buildAppleHeaders;

/// 构造 Anisette JSON 请求体
- (nullable NSString *)buildAnisetteJSON;

/// 初始化/重新收集设备信息
- (BOOL)initializeWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
