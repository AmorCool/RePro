//
//  RPVLoginImpl.m
//  RePro Daemon
//
//  Apple ID 登录认证实现
//  使用 AuthKit (dlopen) 获取 Anisette + NSURLSession 发送 HTTP 认证请求
//
//  所有依赖均为 iOS 系统框架（Foundation/Security），无需编译时私有头文件
//

#import "RPVLoginImpl.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// 错误码定义
#define RPVInternalLoginError 5000
#define RPVInternalLogin2FARequiredTrustedDeviceError 4010
#define RPVInternalLogin2FARequiredSecondaryAuthError 4011
#define RPVInternalLoginIncorrect2FACodeError 4012

// ============================================================
// AuthKit dlopen
// ============================================================
static void *authkit_handle = NULL;
static BOOL authkit_available = NO;

static void ensure_authkit_loaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        authkit_handle = dlopen(
            "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
        if (authkit_handle) authkit_available = YES;
    });
}

// ============================================================
// RPVLoginImpl
// ============================================================
@interface RPVLoginImpl () {
    NSDictionary *_lookupURLs;
}
@end

@implementation RPVLoginImpl

@synthesize clientInfoOverride;

- (instancetype)init {
    self = [super init];
    if (self) {
        ensure_authkit_loaded();
    }
    return self;
}

// MARK: - 工具方法

- (NSError *)createError:(NSString *)string :(int)code {
    return [NSError errorWithDomain:@"RePro.RPVLogin"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: string}];
}

// MARK: - Anisette 数据获取

- (NSDictionary *)anisetteData {
    ensure_authkit_loaded();

    if (authkit_available) {
        NSMutableURLRequest *req = [[NSMutableURLRequest alloc]
            initWithURL:[NSURL URLWithString:@"https://gsa.apple.com/grandslam/GsService2/lookup"]];
        req.HTTPMethod = @"POST";

        Class sessionClass = NSClassFromString(@"AKAppleIDSession");
        id session = [[sessionClass alloc]
            performSelector:NSSelectorFromString(@"initWithIdentifier:")
            withObject:@"com.apple.gs.auth"];

        NSDictionary *headers = [session
            performSelector:NSSelectorFromString(@"appleIDHeadersForRequest:")
            withObject:req];

        if (headers && headers.count > 0) return headers;
    }

    // Fallback Anisette 头（无 AuthKit 时使用）
    return @{
        @"X-Apple-I-MD-M": @"00000000-0000-0000-0000-000000000000",
        @"X-Apple-I-MD": @"AAAAAAAAAAAAAA",
        @"X-Apple-I-MD-LU": @"AAAAAAAAAAAAAA",
        @"X-Apple-I-MD-RINFO": @"17106176",
        @"X-Apple-I-Client-Time": [NSString stringWithFormat:@"%lld",
            (long long)[[NSDate date] timeIntervalSince1970] * 1000],
        @"X-Apple-I-TimeZone": @"UTC",
        @"X-MMe-Client-Info": @"<MacBookPro> <Mac OS X;10.15.7;19H2> <com.apple.AuthKit/1>"
    };
}

- (NSDictionary *)deviceData {
    return @{
        @"machineSerial": @"unknown",
        @"deviceUDID": @"unknown",
        @"osVersion": [[NSProcessInfo processInfo] operatingSystemVersionString] ?: @"unknown"
    };
}

// MARK: - Stage 1: Lookup

- (void)initialiseLookup:(void (^)(NSError *))completion {
    NSDictionary *anisette = [self anisetteData];
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://gsa.apple.com/grandslam/GsService2/lookup"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    [req setValue:@"application/x-apple-plist" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/x-apple-plist" forHTTPHeaderField:@"Accept"];
    [req setValue:@"Xcode" forHTTPHeaderField:@"User-Agent"];
    for (NSString *key in anisette) {
        [req setValue:anisette[key] forHTTPHeaderField:key];
    }
    req.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:
        @{@"urls": @[@"https://gsa.apple.com/grandslam/GsService2"]}
        format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];

    [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || !data) {
            completion(error ?: [self createError:@"Lookup 失败" :RPVInternalLoginError]);
            return;
        }
        NSDictionary *plist = [NSPropertyListSerialization
            propertyListWithData:data options:0 format:NULL error:nil];
        _lookupURLs = plist[@"urls"];
        completion(nil);
    }] resume];
}

// MARK: - 核心：登录认证

- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
              completion:(RPVLoginResultBlock)completionHandler {

    NSLog(@"[RePro] 登录请求: %@ (AuthKit: %@)",
          username ?: @"(nil)", authkit_available ? @"可用" : @"不可用");

    [self initialiseLookup:^(NSError *lookupError) {
        if (lookupError) {
            completionHandler(lookupError, nil, nil, nil);
            return;
        }

        // 获取认证端点 URL
        NSString *baseURL = _lookupURLs[@"https://gsa.apple.com/grandslam/GsService2"];
        if (!baseURL) {
            completionHandler([self createError:@"GSA 端点未找到" :RPVInternalLoginError],
                              nil, nil, nil);
            return;
        }

        // 准备 Anisette
        NSDictionary *anisette = [self anisetteData];

        // 构建认证请求
        NSMutableURLRequest *req = [NSMutableURLRequest
            requestWithURL:[NSURL URLWithString:
                [baseURL stringByAppendingString:@"/authenticate"]]];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 30;
        [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Accept"];
        [req setValue:@"Xcode" forHTTPHeaderField:@"User-Agent"];
        for (NSString *key in anisette) {
            [req setValue:anisette[key] forHTTPHeaderField:key];
        }

        NSDictionary *authBody = @{
            @"appleID": username ?: @"",
            @"password": password ?: @"",
            @"appIDKey": @"3b356c1bac5ad9735ad62f25d434c21c9420d3c2",
            @"extended_login": @YES
        };
        req.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:authBody
                         format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];

        [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {

            if (error || !data) {
                completionHandler(error ?: [self createError:@"认证请求失败"
                                              :RPVInternalLoginError],
                                  nil, nil, nil);
                return;
            }

            NSDictionary *plist = [NSPropertyListSerialization
                propertyListWithData:data options:0 format:NULL error:nil];

            if (![plist isKindOfClass:[NSDictionary class]]) {
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                completionHandler([self createError:
                    [NSString stringWithFormat:@"认证响应格式错误: %@",
                     raw ?: @"(非 UTF-8)"] :RPVInternalLoginError],
                    nil, nil, nil);
                return;
            }

            // 2FA 检测
            if (plist[@"au"] || plist[@"TrustedDeviceRequired"] ||
                [plist[@"message"] containsString:@"verification"]) {
                NSString *dsid = plist[@"dsid"] ?: plist[@"adsid"];
                NSString *idmsToken = plist[@"idmsToken"];
                NSError *err = [self createError:@"需要二次验证"
                                    :RPVInternalLogin2FARequiredTrustedDeviceError];
                completionHandler(err, dsid, nil, idmsToken);
                return;
            }

            // 提取凭证
            NSString *dsid = plist[@"dsid"] ?: plist[@"adsid"];
            NSString *token = plist[@"mmeAuthToken"] ?: plist[@"passwordToken"];

            if (!dsid) {
                NSString *msg = plist[@"message"] ?:
                    plist[@"dialogText"] ?: plist[@"errorMessage"] ?: @"认证失败";
                completionHandler([self createError:msg :RPVInternalLoginError],
                                  nil, nil, nil);
                return;
            }

            NSLog(@"[RePro] 登录成功: dsid=%@", dsid);
            completionHandler(nil, dsid, token, plist[@"idmsToken"]);
        }] resume];
    }];
}

// MARK: - 2FA

- (void)requestTwoFactorCodeWithUserIdentity:(NSString *)userIdentity
                                    idmsToken:(NSString *)token
                                         mode:(int)mode
                                andCompletion:(void (^)(NSError *))completionHandler {
    completionHandler(nil);
}

- (void)submitTwoFactorCode:(NSString *)code
            withUserIdentity:(NSString *)userIdentity
                  idmsToken:(NSString *)token
              andCompletion:(RPVTwoFactorResultBlock)completionHandler {
    completionHandler(nil);
}

@end
