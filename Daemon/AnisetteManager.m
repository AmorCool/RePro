//
//  AnisetteManager.m
//  ReProvision Daemon
//
//  Anisette 数据管理器：
//  优先使用 AuthKit 私有 API 获取真实数据，
//  fallback 到本地生成（仅用于演示/调试）
//

#import "AnisetteManager.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

static NSString *const kOTPKeyPath = @"/var/mobile/Library/ReProvision/otp_key.bin";
static NSString *const kLockdownPlistPath = @"/var/lockdown/device_data.plist";

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

#pragma mark - AnisetteDeviceInfo

@implementation AnisetteDeviceInfo

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.machineID forKey:@"machineID"];
    [coder encodeObject:self.deviceUDID forKey:@"deviceUDID"];
    [coder encodeObject:self.deviceSerialNumber forKey:@"deviceSerialNumber"];
    [coder encodeObject:self.deviceModel forKey:@"deviceModel"];
    [coder encodeObject:self.deviceDescription forKey:@"deviceDescription"];
    [coder encodeInteger:self.localUserID forKey:@"localUserID"];
    [coder encodeDouble:self.timestamp forKey:@"timestamp"];
    [coder encodeObject:self.locale forKey:@"locale"];
    [coder encodeObject:self.timeZone forKey:@"timeZone"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.machineID = [coder decodeObjectForKey:@"machineID"] ?: @"";
        self.deviceUDID = [coder decodeObjectForKey:@"deviceUDID"] ?: @"";
        self.deviceSerialNumber = [coder decodeObjectForKey:@"deviceSerialNumber"] ?: @"";
        self.deviceModel = [coder decodeObjectForKey:@"deviceModel"] ?: @"";
        self.deviceDescription = [coder decodeObjectForKey:@"deviceDescription"] ?: @"Unknown iPhone";
        self.localUserID = (uint32_t)[coder decodeIntegerForKey:@"localUserID"];
        self.timestamp = [coder decodeDoubleForKey:@"timestamp"];
        self.locale = [coder decodeObjectForKey:@"locale"] ?: @"en_US";
        self.timeZone = [coder decodeObjectForKey:@"timeZone"] ?: @"America/New_York";
    }
    return self;
}

@end

#pragma mark - AnisetteManager

@interface AnisetteManager ()
@property (nonatomic, strong) AnisetteDeviceInfo *cachedInfo;
@property (nonatomic, strong) NSData *otpKey;
@property (nonatomic, assign) BOOL isInitialized;
@property (nonatomic, assign) BOOL authKitAvailable;
@property (nonatomic, strong) NSDictionary *cachedAnisetteHeaders;
@end

@implementation AnisetteManager

+ (instancetype)sharedManager {
    static AnisetteManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AnisetteManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 尝试加载 AuthKit 框架
        [self _ensureAuthKitAvailable];
        // 收集设备信息
        [self collectDeviceInfo];
    }
    return self;
}

/// 确保 AuthKit 框架已加载
- (void)_ensureAuthKitAvailable {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
        if (handle) {
            self.authKitAvailable = YES;
            NSLog(@"[RePro] AuthKit 框架加载成功");
        } else {
            self.authKitAvailable = NO;
            // 尝试其他可能路径
            handle = dlopen("/System/Library/Frameworks/AuthKit.framework/AuthKit", RTLD_NOW);
            if (handle) {
                self.authKitAvailable = YES;
                NSLog(@"[RePro] AuthKit 框架加载成功（备用路径）");
            } else {
                NSLog(@"[RePro] AuthKit 框架加载失败，将使用 fallback 模式");
            }
        }
    });
}

- (BOOL)isReady {
    return self.isInitialized && self.cachedInfo != nil;
}

- (AnisetteDeviceInfo *)deviceInfo {
    if (!self.cachedInfo) {
        [self collectDeviceInfo];
    }
    // 更新时间戳为当前时间
    self.cachedInfo.timestamp = (int64_t)[[NSDate date] timeIntervalSince1970];
    return self.cachedInfo;
}

#pragma mark - 设备信息收集

- (void)collectDeviceInfo {
    AnisetteDeviceInfo *info = [[AnisetteDeviceInfo alloc] init];

    // 优先使用 AuthKit AKDevice 获取真实设备信息
    if (self.authKitAvailable) {
        [self _collectFromAuthKit:info];
    }

    // Fallback: 从 lockdown plist 读取
    if (info.machineID.length == 0) {
        [self _collectFromLockdown:info];
    }

    // Fallback: sysctl 获取设备型号
    if (info.deviceModel.length == 0) {
        [self _collectFromSysctl:info];
    }

    // 最终兜底值（仅在所有方法都失败时使用）
    [self _applyFallbacks:info];

    info.timestamp = (int64_t)[[NSDate date] timeIntervalSince1970];
    info.locale = NSLocale.currentLocale.localeIdentifier ?: @"en_US";
    info.timeZone = NSTimeZone.localTimeZone.abbreviation ?: @"UTC";

    self.cachedInfo = info;
    self.isInitialized = YES;

    NSLog(@"[RePro] 设备信息收集完成: model=%@, mlb=%@", info.deviceModel, info.machineID);
}

/// 从 AuthKit AKDevice 获取真实设备信息
- (void)_collectFromAuthKit:(AnisetteDeviceInfo *)info {
    Class AKDeviceClass = NSClassFromString(@"AKDevice");
    if (!AKDeviceClass) return;

    @try {
        id device = [AKDeviceClass currentDevice];
        if (!device) return;

        if ([device respondsToSelector:@selector(uniqueDeviceIdentifier)]) {
            NSString *uid = [device uniqueDeviceIdentifier];
            if (uid.length > 0) info.deviceUDID = uid;
        }

        if ([device respondsToSelector:@selector(MLBSerialNumber)]) {
            NSString *mlb = [device MLBSerialNumber];
            if (mlb.length > 0) info.machineID = mlb;
        }

        if ([device respondsToSelector:@selector(ROMAddress)]) {
            NSString *rom = [device ROMAddress];
            if (rom.length > 0) {
                // ROM 地址格式化
                info.deviceDescription = [NSString stringWithFormat:@"ROM:%@", rom];
            }
        }

        if ([device respondsToSelector:@selector(serialNumber)]) {
            NSString *sn = [device serialNumber];
            if (sn.length > 0) info.deviceSerialNumber = sn;
        }

        NSLog(@"[RePro] 从 AuthKit 获取到设备信息");
    } @catch (NSException *exception) {
        NSLog(@"[RePro] AuthKit 设备信息获取异常: %@", exception.reason);
    }
}

/// 从 lockdown plist 读取
- (void)_collectFromLockdown:(AnisetteDeviceInfo *)info {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kLockdownPlistPath];
    if (!dict) return;

    if (info.machineID.length == 0) {
        info.machineID = dict[@"MLBSerialNumber"] ?: @"";
    }
    if (info.deviceUDID.length == 0) {
        info.deviceUDID = dict[@"UniqueDeviceID"] ?: @"";
    }
    if (info.deviceSerialNumber.length == 0) {
        info.deviceSerialNumber = dict[@"SerialNumber"] ?: @"";
    }
}

/// 从 sysctl 获取设备型号
- (void)_collectFromSysctl:(AnisetteDeviceInfo *)info {
    size_t len = 0;
    sysctlbyname("hw.machine", NULL, &len, NULL, 0);
    if (len > 0) {
        char *machine = malloc(len);
        if (sysctlbyname("hw.machine", machine, &len, NULL, 0) == 0) {
            info.deviceModel = [NSString stringWithUTF8String:machine];
        }
        free(machine);
    }
}

/// 最终兜底值
- (void)_applyFallbacks:(AnisetteDeviceInfo *)info {
    if (info.machineID.length == 0) info.machineID = @"Unknown";
    if (info.deviceUDID.length == 0) info.deviceUDID = @"unknown";
    if (info.deviceSerialNumber.length == 0) info.deviceSerialNumber = @"Unknown";
    if (info.deviceModel.length == 0) info.deviceModel = @"iPhone";
}

#pragma mark - Anisette 数据输出

/// 构建苹果认证请求头（优先使用 AuthKit 真实数据）
- (NSDictionary<NSString *, NSString *> *)buildAppleHeaders {
    // 如果 AuthKit 可用，尝试获取真实 Anisette 头
    if (self.authKitAvailable) {
        NSDictionary *headers = [self _buildAuthKitHeaders];
        if (headers.count > 2) { // 至少包含关键字段
            return headers;
        }
    }

    // Fallback: 本地构建
    return [self _buildLocalHeaders];
}

/// 使用 AuthKit 获取真实 Anisette 头
- (NSDictionary *)_buildAuthKitHeaders {
    Class AKAppleIDSession = NSClassFromString(@"AKAppleIDSession");
    if (!AKAppleIDSession) return @{};

    @try {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";

        NSDictionary *headers = [[[AKAppleIDSession alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"]
                                  appleIDHeadersForRequest:nil];

        if (!headers || headers.count == 0) return @{};

        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:headers];
        result[@"X-Apple-I-Client-Time"] = [formatter stringFromDate:[NSDate date]];
        result[@"X-MMe-Client-Info"] = [NSString stringWithFormat:
            @"<MacBookPro11,5> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"];

        self.cachedAnisetteHeaders = result;
        NSLog(@"[RePro] AuthKit Anisette 头获取成功 (%lu 个字段)", (unsigned long)result.count);
        return result;
    } @catch (NSException *exception) {
        NSLog(@"[RePro] AuthKit Anisette 头获取异常: %@", exception.reason);
        return @{};
    }
}

/// 本地构建 Anisette 头（fallback，可能无法通过服务器验证）
- (NSDictionary *)_buildLocalHeaders {
    AnisetteDeviceInfo *info = [self deviceInfo];

    // 注意：本地生成的 OTP 无法通过苹果服务器验证
    // 仅用于 UI 显示和调试目的
    return @{
        @"X-Apple-I-Client-Time": [NSString stringWithFormat:@"%lld", (long long)info.timestamp],
        @"X-Apple-I-TimeZone": info.timeZone,
        @"X-Apple-Locale": info.locale,
        @"X-Mme-Device-Id": info.deviceUDID,
        @"X-MMe-Client-Info": [NSString stringWithFormat:
            @"<%@> <iPhone OS;%@;19C56>", info.deviceModel, @"17.3.1"],
        @"X-Apple-I-MLB": info.machineID,
        @"X-Apple-I-SRL-NO": info.deviceSerialNumber,
    };
}

- (NSString *)buildAnisetteJSON {
    AnisetteDeviceInfo *info = [self deviceInfo];
    NSDictionary *headers = [self buildAppleHeaders]; // 包含 AuthKit 真实数据

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"machineID"] = info.machineID ?: @"";
    dict[@"deviceUniqueIdentifier"] = info.deviceUDID ?: @"";
    dict[@"deviceSerialNumber"] = info.deviceSerialNumber ?: @"";
    dict[@"deviceDescription"] = info.deviceDescription ?: @"Unknown iPhone";
    dict[@"localUserID"] = @(info.localUserID);
    dict[@"date"] = @(info.timestamp);
    dict[@"locale"] = info.locale ?: @"en_US";
    dict[@"timeZone"] = info.timeZone ?: @"America/New_York";

    // 如果有 AuthKit 的 OTP，使用它
    NSString *identityId = headers[@"X-Apple-I-Identity-Id"];
    if (identityId) {
        // 解析 identityId 格式: machineID:OTP:timestamp:locale
        NSArray *parts = [identityId componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            dict[@"oneTimePassword"] = parts[1] ?: @"";
        }
    }

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (!jsonData || error) {
        NSLog(@"[RePro] Anisette JSON 构建失败: %@", error);
        return nil;
    }

    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (BOOL)initializeWithError:(NSError **)error {
    [self collectDeviceInfo];
    return self.isReady;
}

/// 检查是否有真实的 Anisette 数据（AuthKit 可用且返回有效数据）
- (BOOL)hasValidAnisetteData {
    return self.authKitAvailable && self.cachedAnisetteHeaders != nil
        && self.cachedAnisetteHeaders[@"X-Apple-I-Identity-Id"] != nil;
}

@end
