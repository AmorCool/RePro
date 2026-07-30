//
//  SignEngine.h
//  ReProvision Daemon
//
//  双后端签名引擎抽象：
//  - 方案一: ldid 内嵌签名（传统方式）
//  - 方案二: zsign 外部进程签名（推荐）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 签名方式枚举
typedef NS_ENUM(NSInteger, RZSignMethod) {
    RZSignMethodLdid = 0,   // ldid 内嵌签名
    RZSignMethodZsign = 1   // zsign 外部进程签名
};

/// 签名选项
@interface RZSignOptions : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *appPath;
@property (nonatomic, copy) NSString *outputPath;       // nil = 原地签名
@property (nonatomic, copy) NSString *certificatePath;
@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, strong) NSArray<NSString *> *provisioningPaths;
@property (nonatomic, copy) NSString *entitlementsPath;
@property (nonatomic, assign) BOOL useSHA256;
@end

/// 签名结果
@interface RZSignResult : NSObject
@property (nonatomic, assign) BOOL success;
@property (nonatomic, copy) NSString * _Nullable errorMessage;
@property (nonatomic, copy) NSString * _Nullable signedAppPath;
@property (nonatomic, assign) NSInteger exitCode;
@end

/// 签名引擎协议（双后端抽象）
@protocol RZSignBackend <NSObject>
- (RZSignResult *)signWithOptions:(RZSignOptions *)options error:(NSError **)error;
- (BOOL)isAvailable;
- (NSString *)backendName;
@end

/// 签名引擎主类
@interface SignEngine : NSObject

/// 当前选择的签名方式
@property (nonatomic, assign) RZSignMethod currentMethod;

/// Apple ID 登录认证
- (NSDictionary<NSString *, id> * _Nullable)loginWithAppleID:(NSString *)appleID
                                                    password:(NSString *)password
                                                       error:(NSError **)error;

/// 获取已安装应用列表
- (NSArray<NSDictionary *> *)listInstalledApps;

/// 导入 IPA 文件
- (NSDictionary<NSString *, id> * _Nullable)importIPAAtPath:(NSString *)path
                                                   error:(NSError **)error;

/// 重签指定应用
- (BOOL)resignApplication:(NSString *)bundleIdentifier error:(NSError **)error;

/// 获取当前后端实例
- (id<RZSignBackend>)currentBackend;

@end

NS_ASSUME_NONNULL_END
