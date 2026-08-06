// v2.1.0：signingd daemon 编译时的符号占位桩 + 真实运行时实现。
//
// 编译层：签名管线源码依赖 UIKit/CoreGraphics/AuthKit 等 daemon 不需要链接的符号，
// 这里提供空桩满足链接器。
//
// 运行层（关键）：daemon 自己执行签名管线时，以下方法会被真实调用，必须可用：
//   1. RPVAuthentication.appleIDHeadersForRequest:  —— Anisette headers（EEAppleServices
//      每个 HTTP 请求都调它）。真实实现：dlopen AuthKit → AKAppleIDSession。
//   2. RPVAuthentication.authenticateWithUsername:... —— daemon 不重新登录，直接读
//      /var/mobile/Library/Resign/credentials.cache 拿 gsToken 回调成功（凭据已缓存）。
//   3. EESigning.updateEntitlementsForBinaryAtLocation:... —— Stage 3 注册 App ID 时用，
//      返回构造的 entitlements（application-identifier / team-identifier / keychain-access-groups），
//      不读二进制（daemon 无 ldid C++ 库）。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

// ─── CoreGraphics/UIKit 全局常量（匹配 SDK extern 声明，避免链接 UIKit）───────
const CGRect CGRectZero = {{0,0},{0,0}};
NSString *NSFontAttributeName = @"NSFont";

// ─── 凭据缓存直读（RPVResources 的 getUsername/getTeamID 走 NSUserDefaults 域隔离，
//      daemon 读不到 App 容器偏好，必须直接读共享 IPC 目录的缓存文件）─────────────
static NSDictionary *RPVDaemonCredentials(void) {
    return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Resign/credentials.cache"];
}

// ─── UIKit 桩（daemon 无 UI，全部 nil 空壳）───────────────────────────────

@interface UIDevice : NSObject
+ (instancetype)currentDevice;
- (NSString *)systemVersion;
- (NSString *)model;
- (NSString *)uniqueIdentifier;
@end
@implementation UIDevice
+ (instancetype)currentDevice { static id d; if (!d) d = [[self alloc] init]; return d; }
- (NSString *)systemVersion { return @"17.0"; }
- (NSString *)model { return @"iPhone"; }
- (NSString *)uniqueIdentifier { return @""; }
@end

@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { return nil; }
@end

@interface UIScreen : NSObject
+ (instancetype)mainScreen;
- (CGRect)bounds;
@end
@implementation UIScreen
+ (instancetype)mainScreen { return nil; }
- (CGRect)bounds { return CGRectZero; }
@end

@interface UIImage : NSObject
@end
@implementation UIImage
@end

// ─── AuthKit 桩（AKDevice 仅 EEAppleServices 静态引用占坑；Anisette 走动态取类）──

@interface AKDevice : NSObject
+ (instancetype)currentDevice;
- (NSString *)uniqueDeviceIdentifier;
- (NSString *)serialNumber;
- (NSString *)uniqueGlobalDeviceIdentifier;
@end
@implementation AKDevice
+ (instancetype)currentDevice { return nil; }
- (NSString *)uniqueDeviceIdentifier { return @""; }
- (NSString *)serialNumber { return @""; }
- (NSString *)uniqueGlobalDeviceIdentifier { return @""; }
@end

// ─── RPVAuthentication 桩（真实 Anisette + 缓存直通登录）────────────────────

// AuthKit 私有框架声明（动态取类时编译器需要 selector 签名）
@interface AKAppleIDSession : NSObject
- (id)initWithIdentifier:(id)arg1;
- (id)appleIDHeadersForRequest:(id)arg1;
@end

@interface RPVAuthentication : NSObject
@property (nonatomic, strong) NSString *clientInfoOverride;
- (NSDictionary *)appleIDHeadersForRequest:(NSURLRequest *)request;
- (void)authenticateWithUsername:(NSString *)username password:(NSString *)password
                  withCompletion:(void (^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion;
- (void)requestLoginCodeWithCompletion:(void (^)(NSError *))completionHandler;
- (void)validateLoginCode:(NSString *)code withCompletion:(void (^)(NSError *, NSString *, NSString *))completion;
- (void)fallback2FACodeRequest:(void (^)(NSError *, NSString *, NSString *))completionHandler;
@end
@implementation RPVAuthentication

// 真实 Anisette：dlopen AuthKit → AKAppleIDSession 生成 headers（与 App 侧完全一致）
- (NSDictionary *)appleIDHeadersForRequest:(NSURLRequest *)request {
    // 动态取类（daemon 不静态链接 AuthKit 私有框架）
    static Class AKAppleIDSession = nil;
    if (!AKAppleIDSession) {
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW | RTLD_GLOBAL);
        AKAppleIDSession = NSClassFromString(@"AKAppleIDSession");
    }
    NSDictionary *headers = nil;
    if (AKAppleIDSession) {
        id session = [[AKAppleIDSession alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"];
        if ([session respondsToSelector:@selector(appleIDHeadersForRequest:)]) {
            headers = [session appleIDHeadersForRequest:request];
        }
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if ([headers isKindOfClass:[NSDictionary class]]) {
        [result addEntriesFromDictionary:headers];
    }
    // 与 RPVLoginImpl._anisetteData 相同的覆盖参数
    result[@"X-Apple-App-Info"] = @"com.apple.gs.xcode.auth";
    result[@"X-MMe-Client-Info"] =
        @"<MacBookPro11,5> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
    return result;
}

// daemon 不重新登录：凭据已由 App 登录时缓存在 /var/mobile/Library/Resign/credentials.cache
- (void)authenticateWithUsername:(NSString *)username password:(NSString *)password
                  withCompletion:(void (^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion {
    NSDictionary *cred = RPVDaemonCredentials();
    NSString *gsToken = cred[@"password"];
    NSString *identity = cred[@"username"];
    if (gsToken.length > 0 && identity.length > 0) {
        // 缓存直通：username 格式为 "apple_id|DSID"，取后段作为 identity
        NSArray *parts = [identity componentsSeparatedByString:@"|"];
        NSString *dsid = parts.count >= 2 ? parts[1] : identity;
        if (completion) completion(nil, dsid, gsToken);
        return;
    }
    if (completion) completion([NSError errorWithDomain:@"RPVDaemon" code:-1
                                               userInfo:@{NSLocalizedDescriptionKey:@"daemon 无凭据缓存"}], nil, nil);
}

- (void)requestLoginCodeWithCompletion:(void (^)(NSError *))completionHandler {
    if (completionHandler) completionHandler([NSError errorWithDomain:@"RPVDaemon" code:-2
                                                             userInfo:@{NSLocalizedDescriptionKey:@"daemon 不走 2FA 登录"}]);
}
- (void)validateLoginCode:(NSString *)code withCompletion:(void (^)(NSError *, NSString *, NSString *))completion {
    if (completion) completion([NSError errorWithDomain:@"RPVDaemon" code:-2
                                               userInfo:@{NSLocalizedDescriptionKey:@"daemon 不走 2FA 登录"}], nil, nil);
}
- (void)fallback2FACodeRequest:(void (^)(NSError *, NSString *, NSString *))completionHandler {
    if (completionHandler) completionHandler([NSError errorWithDomain:@"RPVDaemon" code:-2
                                                              userInfo:@{NSLocalizedDescriptionKey:@"daemon 不走 2FA 登录"}], nil, nil);
}
@end

// ─── EESigning 桩（Stage 3 App ID 注册用的 entitlements 构造）──────────────

@interface EESigning : NSObject
+ (NSMutableDictionary *)getEntitlementsForBinaryAtLocation:(NSString *)binaryLocation;
+ (NSDictionary *)updateEntitlementsForBinaryAtLocation:(NSString *)binaryLocation
                                      bundleIdentifier:(NSString *)bundleIdentifier
                                                teamID:(NSString *)teamid;
@end
@implementation EESigning

// daemon 无 ldid C++ 库，不读二进制；返回空 dict 由调用方补 application-identifier。
+ (NSMutableDictionary *)getEntitlementsForBinaryAtLocation:(NSString *)binaryLocation {
    return [NSMutableDictionary dictionary];
}

// 与 EESigning.mm 原实现等价：构造 application-identifier / team-identifier / keychain-access-groups
+ (NSDictionary *)updateEntitlementsForBinaryAtLocation:(NSString *)binaryLocation
                                      bundleIdentifier:(NSString *)bundleIdentifier
                                                teamID:(NSString *)teamid {
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    NSString *applicationId = bundleIdentifier;
    // 处理 identifier 已含 TeamID 前缀的情况
    NSString *teamPrefix = [NSString stringWithFormat:@"%@.", teamid];
    if (![applicationId hasPrefix:teamPrefix]) {
        applicationId = [NSString stringWithFormat:@"%@%@", teamPrefix, applicationId];
    }
    plist[@"application-identifier"] = applicationId;
    plist[@"com.apple.developer.team-identifier"] = teamid;
    plist[@"keychain-access-groups"] = @[ [NSString stringWithFormat:@"%@.*", teamid] ];
    return plist;
}
@end

// ─── RPVDiagnostic（daemon 用 s_log 自记，桩空实现）────────────────────────

void RPVDiagnostic(int level, NSString *tag, NSString *fmt, ...) {
    // 空：daemon 的日志走 s_log
}

// ─── libMobileGestalt（daemon 不需要设备信息查询）──────────────────────────

CFTypeRef MGCopyAnswer(CFStringRef question) {
    return NULL;
}
