//
//  AnisetteManager.m
//  ReProvision Daemon
//
//  本地 Anisette 实现：
//  1. 从 lockdown plist 读取设备唯一标识
//  2. 生成并持久化 OTP 密钥
//  3. 基于时间窗口计算 HMAC-SHA256 OTP
//  4. 输出苹果服务器期望的请求头格式
//

#import "AnisetteManager.h"
#import <CommonCrypto/CommonHMAC.h>
#import <sys/sysctl.h>
#import <sys/stat.h>

static NSString *const kOTPKeyPath = @"/var/mobile/Library/ReProvision/otp_key.bin";
static NSString *const kLockdownPlistPath = @"/var/lockdown/device_data.plist";

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
        [self loadOrGenerateOTPKey];
    }
    return self;
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

    // 方法1: 从 lockdown plist 读取
    NSDictionary *lockdownDict = [NSDictionary dictionaryWithContentsOfFile:kLockdownPlistPath];
    if (lockdownDict) {
        info.machineID = lockdownDict[@"MLBSerialNumber"] ?: @"";
        info.deviceUDID = lockdownDict[@"UniqueDeviceID"] ?: @"";
        info.deviceSerialNumber = lockdownDict[@"SerialNumber"] ?: @"";
    }

    // 方法2: 通过 sysctl 获取设备型号
    size_t len = 0;
    sysctlbyname("hw.machine", NULL, &len, NULL, 0);
    if (len > 0) {
        char *machine = malloc(len);
        if (sysctlbyname("hw.machine", machine, &len, NULL, 0) == 0) {
            info.deviceModel = [NSString stringWithUTF8String:machine];
            free(machine);
        }
    }

    // 默认值兜底
    if (info.machineID.length == 0) info.machineID = @"D123456789ABCDEF";
    if (info.deviceUDID.length == 0) info.deviceUDID = @"00000000-0000-0000-0000-000000000000";
    if (info.deviceSerialNumber.length == 0) info.deviceSerialNumber = @"F2LXXXXXXXXX";
    if (info.deviceModel.length == 0) info.deviceModel = @"iPhone14,2";

    info.timestamp = (int64_t)[[NSDate date] timeIntervalSince1970];
    info.locale = @"en_US";
    info.timeZone = @"America/New_York";

    self.cachedInfo = info;
    self.isInitialized = YES;
}

#pragma mark - OTP 密钥管理

- (void)loadOrGenerateOTPKey {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 尝试从磁盘加载
    if ([fm fileExistsAtPath:kOTPKeyPath]) {
        self.otpKey = [NSData dataWithContentsOfFile:kOTPKeyPath];
        if (self.otpKey.length == 32) return; // 有效密钥
    }

    // 首次生成随机密钥
    uint8_t keyBytes[32];
    for (int i = 0; i < 32; i++) {
        keyBytes[i] = (uint8_t)(arc4random() & 0xFF);
    }
    self.otpKey = [NSData dataWithBytes:keyBytes length:32];

    // 持久化保存
    NSString *dir = [kOTPKeyPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [self.otpKey writeToFile:kOTPKeyPath atomically:YES];

    // 设置权限：仅 owner 可读写
    chmod(kOTPKeyPath.UTF8String, 0600);

    NSLog(@"[RePro] OTP 密钥已生成并持久化");
}

- (NSString *)generateOTP {
    if (!self.otpKey || self.otpKey.length != 32) {
        [self loadOrGenerateOTPKey];
    }

    // 时间窗口：每 30 秒一个窗口（与 TOTP 标准一致）
    int64_t now = (int64_t)[[NSDate date] timeIntervalSince1970];
    int64_t timeWindow = now / 30;

    // HMAC-SHA256 输入
    NSString *hmacInput = [NSString stringWithFormat:@"%lld:ANISETTE", (long long)timeWindow];

    uint8_t hmacOutput[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256,
           self.otpKey.bytes, (CC_LONG)self.otpKey.length,
           hmacInput.UTF8String, (CC_LONG)hmacInput.length,
           hmacOutput);

    // 编码为 hex 字符串，取前 16 位作为 OTP
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hmacOutput[i]];
    }

    NSString *otp = [hex substringToIndex:MIN(16, hex.length)];
    return otp;
}

#pragma mark - Anisette 输出

- (NSDictionary<NSString *, NSString *> *)buildAppleHeaders {
    AnisetteDeviceInfo *info = [self deviceInfo];
    NSString *otp = [self generateOTP];

    return @{
        @"X-Apple-I-Identity-Id": [NSString stringWithFormat:@"%@:%@:%lld:%@",
                                    info.machineID, otp, (long long)info.timestamp, info.locale],
        @"X-Apple-I-Client-Time": [NSString stringWithFormat:@"%lld", (long long)info.timestamp],
        @"X-Apple-I-TimeZone": info.timeZone,
        @"X-Apple-Locale": info.locale,
        @"X-Mme-Device-Id": info.deviceUDID,
        @"X-Mme-Client-Info": [NSString stringWithFormat:@"<%@> <iPhone OS;%@;19C56>",
                                   info.deviceModel, @"17.3.1"]
    };
}

- (NSString *)buildAnisetteJSON {
    AnisetteDeviceInfo *info = [self deviceInfo];
    NSString *otp = [self generateOTP];

    NSDictionary *dict = @{
        @"machineID": info.machineID ?: @"",
        @"deviceUniqueIdentifier": info.deviceUDID ?: @"",
        @"deviceSerialNumber": info.deviceSerialNumber ?: @"",
        @"deviceDescription": info.deviceDescription ?: @"Unknown iPhone",
        @"oneTimePassword": otp ?: @"",
        @"localUserID": @(info.localUserID),
        @"date": @(info.timestamp),
        @"locale": info.locale ?: @"en_US",
        @"timeZone": info.timeZone ?: @"America/New_York"
    };

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

@end
