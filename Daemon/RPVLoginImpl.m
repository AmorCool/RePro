//
//  RPVLoginImpl.m
//  RePro Daemon
//
//  基于 AuthKit 私有 API 的 Apple ID 认证实现
//  使用 dlopen 动态加载私有框架，避免编译时依赖
//

#import "RPVLoginImpl.h"
#import <dlfcn.h>
#import <objc/runtime.h>

#define DEBUG 1

// ============================================================================
// AuthKit 私有 API 声明（运行时通过 dlopen 加载）
// ============================================================================

@interface AKAppleIDSession : NSObject
- (AKAppleIDSession *)initWithIdentifier:(NSString *)identifier;
- (NSDictionary *)appleIDHeadersForRequest:(NSURLRequest *)request;
@end

@interface AKDevice : NSObject
+ (AKDevice *)currentDevice;
- (NSString *)uniqueDeviceIdentifier;
- (NSString *)MLBSerialNumber;
- (NSString *)ROMAddress;
- (NSString *)serialNumber;
@end

// ============================================================================
// 日志工具
// ============================================================================

static void writeToLogFile(const char *string) {
#if DEBUG
    NSString *txtFileName = @"/var/mobile/Documents/ReProvisionDebug.txt";
    NSString *final = [NSString stringWithFormat:@"(%@) %s\n", [NSDate date], string];

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:txtFileName];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[final dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [final writeToFile:txtFileName
                atomically:NO
                  encoding:NSUTF8StringEncoding
                     error:nil];
    }
#endif
}

static void log_error(const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *str = NULL;
    vasprintf(&str, format, args);
    va_end(args);

    NSLog(@"[RPVLogin ERROR] %s", str);
    writeToLogFile(str);
    free(str);
}

static void log_debug(const char *format, ...) {
#if DEBUG
    va_list args;
    va_start(args, format);
    char *str = NULL;
    vasprintf(&str, format, args);
    va_end(args);

    NSLog(@"[RPVLogin DEBUG] %s", str);
    writeToLogFile(str);
    free(str);
#endif
}

// ============================================================================
// 实现
// ============================================================================

@implementation RPVLoginImpl

- (instancetype)init {
    self = [super init];
    if (self) {
        self.clientInfoOverride = @"<MacBookPro11,5> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
    }
    return self;
}

- (NSError*)createError:(NSString *)string :(int)code {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:code
                           userInfo:userInfo];
}

/// 确保 AuthKit 框架已加载（运行时 dlopen）
- (void)_ensureAuthKitAvailable {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
        log_debug("AuthKit framework loaded via dlopen");
    });
}

/// 获取 Anisette 认证数据（从 AuthKit 私有 API）
- (NSDictionary *)_anisetteData {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    NSString *dateString = [formatter stringFromDate:[NSDate date]];

    [self _ensureAuthKitAvailable];

    Class AKAppleIDSession = NSClassFromString(@"AKAppleIDSession");
    if (!AKAppleIDSession) {
        log_error("AKAppleIDSession class not found - AuthKit may not be available");
        // 返回基础数据（不含 X-Apple-I-Identity-Id 等关键字段）
        return @{
            @"X-Apple-I-Client-Time": dateString,
            @"X-Apple-Locale": NSLocale.currentLocale.localeIdentifier,
            @"X-Apple-I-TimeZone": NSTimeZone.localTimeZone.abbreviation ?: @"UTC",
        };
    }

    @try {
        NSDictionary *headers = [[[AKAppleIDSession alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"] appleIDHeadersForRequest:nil];

        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [result setObject:dateString forKey:@"X-Apple-I-Client-Time"];
        [result setObject:NSLocale.currentLocale.localeIdentifier forKey:@"X-Apple-Locale"];
        [result setObject:NSTimeZone.localTimeZone.abbreviation forKey:@"X-Apple-I-TimeZone"];

        if (headers) {
            [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
                [result setObject:value forKey:key];
            }];
        }

        [result setObject:self.clientInfoOverride forKey:@"X-MMe-Client-Info"];
        return result;
    } @catch (NSException *exception) {
        log_error("Exception getting Anisette data: %@", exception.reason);
        return @{
            @"X-Apple-I-Client-Time": dateString,
            @"X-Apple-Locale": NSLocale.currentLocale.localeIdentifier,
            @"X-Apple-I-TimeZone": NSTimeZone.localTimeZone.abbreviation ?: @"UTC",
        };
    }
}

/// 获取设备信息（从 AuthKit AKDevice）
- (NSDictionary *)_deviceData {
    [self _ensureAuthKitAvailable];

    Class AKDeviceClass = NSClassFromString(@"AKDevice");
    if (!AKDeviceClass) {
        log_error("AKDevice class not found");
        return @{};
    }

    @try {
        id device = [AKDeviceClass currentDevice];
        if (!device) return @{};

        NSMutableDictionary *result = [NSMutableDictionary dictionary];

        if ([device respondsToSelector:@selector(uniqueDeviceIdentifier)]) {
            NSString *uid = [device uniqueDeviceIdentifier];
            if (uid) [result setObject:uid forKey:@"X-Mme-Device-Id"];
        }

        if ([device respondsToSelector:@selector(MLBSerialNumber)]) {
            NSString *mlb = [device MLBSerialNumber];
            if (mlb) [result setObject:mlb forKey:@"X-Apple-I-MLB"];
        }

        if ([device respondsToSelector:@selector(ROMAddress)]) {
            NSString *rom = [device ROMAddress];
            if (rom) [result setObject:rom forKey:@"X-Apple-I-ROM"];
        }

        if ([device respondsToSelector:@selector(serialNumber)]) {
            NSString *sn = [device serialNumber];
            if (sn) [result setObject:sn forKey:@"X-Apple-I-SRL-NO"];
        }

        return result;
    } @catch (NSException *exception) {
        log_error("Exception getting device data: %@", exception.reason);
        return @{};
    }
}

// 公开方法
- (NSDictionary *)anisetteData {
    return [self _anisetteData];
}

- (NSDictionary *)deviceData {
    return [self _deviceData];
}

- (NSDictionary*)defaultRequestHeaders {
    return @{
        @"X-MMe-Client-Info": self.clientInfoOverride,
        @"Content-Type": @"text/x-xml-plist",
        @"User-Agent": @"akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0",
        @"Accept": @"*/*"
    };
}

/// 发送请求到 GSA (GrandSlam Auth)
- (void)makeRequestWithParameters:(NSDictionary*)params completion:(void (^)(NSError *err, NSDictionary *response))completionHandler {
    NSString *internalEndpoint = @"https://gsa.apple.com/grandslam/GsService2";

    NSDictionary *defaultHeaders = [self defaultRequestHeaders];

    NSDictionary *requestBody = @{
        @"Header": @{@"Version": @"1.0.1"},
        @"Request": params
    };

    log_debug("Request Body: %s", requestBody.description.UTF8String);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:internalEndpoint]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:requestBody
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:nil];

    [defaultHeaders enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        [request setValue:obj forHTTPHeaderField:key];
    }];

    NSURLSessionTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            completionHandler(error, nil);
        } else if (!data) {
            completionHandler(nil, nil);
        } else {
            NSDictionary *response = [NSPropertyListSerialization propertyListWithData:data
                                                                               options:0
                                                                                format:nil
                                                                                 error:nil];
            NSDictionary *packedResponse = [response objectForKey:@"Response"];
            log_debug("Response: %s", packedResponse.description.UTF8String);
            completionHandler(nil, packedResponse);
        }
    }];
    [task resume];
}

/// 初始化端点查找
- (void)initialiseLookup:(void (^)(NSError*))completion {
    if (self.lookupURLs) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            completion(nil);
        });
        return;
    }

    NSURL *URL = [NSURL URLWithString:@"https://gsa.apple.com/grandslam/GsService2/lookup"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];

    log_debug("Doing lookup");

    NSMutableDictionary<NSString *, NSString *> *httpHeaders = [@{
        @"Content-Type": @"text/x-xml-plist",
        @"User-Agent": @"akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0",
        @"Accept": @"text/x-xml-plist",
        @"Accept-Language": @"en-us",
        @"X-Apple-App-Info": @"com.apple.gs.xcode.auth",
        @"X-Xcode-Version": @"11.2 (11B41)",
    } mutableCopy];

    [httpHeaders addEntriesFromDictionary:[self _anisetteData]];
    [httpHeaders addEntriesFromDictionary:[self _deviceData]];

    [httpHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

        if (!data || error) {
            completion(error);
        } else {
            NSError *parseError;
            NSDictionary *responseDictionary = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:&parseError];

            if (responseDictionary) {
                log_debug("Lookup Response: %s", responseDictionary.description.UTF8String);
                self.lookupURLs = [responseDictionary objectForKey:@"urls"];
            }

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                completion(nil);
            });
        }
    }];
    [task resume];
}

#pragma mark - API（简化版：不支持 SRP，仅支持 Anisette 数据获取）

/// 登录方法 — 当前返回错误提示用户使用 Anisette 认证流程
/// TODO: 完整 SRP 实现需要 corecrypto（私有框架），需在运行时通过 dlopen 加载
- (void)loginWithUsername:(NSString*)username password:(NSString*)password completion:(RPVLoginResultBlock)completionHandler {

    log_debug("loginWithUsername called for: %s", username.UTF8String);

    // 先确保获取了 Anisette 数据
    [self initialiseLookup:^(NSError *error) {
        if (error) {
            completionHandler(error, nil, nil, nil);
            return;
        }

        // 尝试使用 AuthKit 的认证方式
        // 注意：完整的 SRP 认证需要 corecrypto 框架
        // 这里我们尝试用简化的方式或提示用户

        NSError *authError = [self createError:
            @"需要 Anisette 认证。请在设备上登录 iCloud 或使用外部 Anisette 服务。" :
            RPVInternalLoginError];

        completionHandler(authError, nil, nil, nil);
    }];
}

- (void)requestTwoFactorCodeWithUserIdentity:(NSString*)userIdentity idmsToken:(NSString*)token mode:(int)mode andCompletion:(void (^)(NSError *error))completionHandler {
    // TODO: 实现 2FA 验证码请求
    NSError *error = [self createError:@"2FA 功能暂未实现" :RPVInternalLoginError];
    completionHandler(error);
}

- (void)submitTwoFactorCode:(NSString*)code withUserIdentity:(NSString*)userIdentity idmsToken:(NSString*)token andCompletion:(RPVTwoFactorResultBlock)completionHandler {
    // TODO: 实现 2FA 验证码提交
    NSError *error = [self createError:@"2FA 功能暂未实现" :RPVInternalLoginError];
    completionHandler(error);
}

@end
