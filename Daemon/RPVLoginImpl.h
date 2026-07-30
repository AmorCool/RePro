//
//  RPVLoginImpl.h
//  RePro Daemon
//
//  基于 AuthKit 私有 API 的 Apple ID 认证
//  使用 dlopen 运行时加载，避免编译时依赖私有框架
//

#import <Foundation/Foundation.h>

// Error definitions
#define RPVInternalLoginError 5000
#define RPVInternalLogin2FARequiredTrustedDeviceError 4010
#define RPVInternalLogin2FARequiredSecondaryAuthError 4011
#define RPVInternalLoginIncorrect2FACodeError 4012

// Block definitions
typedef void (^RPVLoginResultBlock)(NSError *error, NSString *userIdentity, NSString *gsToken, NSString *idmsToken);
typedef void (^RPVTwoFactorResultBlock)(NSError *error);

@interface RPVLoginImpl : NSObject

@property (nonatomic, strong) NSString *clientInfoOverride;
@property (nonatomic, strong) NSDictionary *lookupURLs;  // 端点查找结果缓存

- (void)loginWithUsername:(NSString*)username password:(NSString*)password completion:(RPVLoginResultBlock)completionHandler;
- (void)requestTwoFactorCodeWithUserIdentity:(NSString*)userIdentity idmsToken:(NSString*)token mode:(int)mode andCompletion:(void (^)(NSError *error))completionHandler;
- (void)submitTwoFactorCode:(NSString*)code withUserIdentity:(NSString*)userIdentity idmsToken:(NSString*)token andCompletion:(RPVTwoFactorResultBlock)completionHandler;

// 获取 Anisette 数据（用于其他模块）
- (NSDictionary *)anisetteData;
- (NSDictionary *)deviceData;

@end
