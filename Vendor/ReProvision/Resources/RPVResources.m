//
//  RPVResources.m
//
//
//  Created by Matt Clarke on 09/01/2018.
//

#import "RPVResources.h"
#import "SAMKeychain.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <dlfcn.h>
#include <notify.h>

// For Apple Watch support
@interface NRDevice : NSObject
- (id)valueForProperty:(id)arg1;
@end

@interface NRPairedDeviceRegistry : NSObject
+ (instancetype)sharedInstance;
- (NRDevice *)getActivePairedDevice;
- (bool)isPaired;
@end

static dispatch_once_t nanoRegistryOnceToken;

#define SERVICENAME @"com.matchstic.ReProvision"

// 本地凭证缓存路径（锁屏 Keychain 不可读时的 fallback）
// 权限 600（仅 owner 可读），存储在 RePro 私有目录。
static NSString *kCredentialsCachePath = @"/var/mobile/Library/RePro/credentials.cache";

@implementation RPVResources

/////////////////////////////////////////////////////////////////////////////////////////////////
// User Settings
/////////////////////////////////////////////////////////////////////////////////////////////////

+ (BOOL)shouldShowDebugAlerts {
    id value = [self preferenceValueForKey:@"showDebugAlerts"];
    return value ? [value boolValue] : NO;
}

+ (BOOL)shouldShowAlerts {
    id value = [self preferenceValueForKey:@"showAlerts"];
    return value ? [value boolValue] : YES;
}

+ (BOOL)shouldShowNonUrgentAlerts {
    id value = [self preferenceValueForKey:@"showNonUrgentAlerts"];
    return value ? [value boolValue] : NO;
}

// How many days left until expiry.
+ (int)thresholdForResigning {
    id value = [self preferenceValueForKey:@"thresholdForResigning"];
    return value ? [value intValue] : 2;
}

+ (BOOL)shouldAutomaticallyResign {
    id value = [self preferenceValueForKey:@"resign"];
    return value ? [value boolValue] : YES;
}

+ (BOOL)shouldResignInLowPowerMode {
    id value = [self preferenceValueForKey:@"resignInLowPowerMode"];
    return value ? [value boolValue] : NO;
}

+ (BOOL)shouldForceResign {
    id value = [self preferenceValueForKey:@"shouldForceResign"];
    return value ? [value boolValue] : YES;
}


+ (BOOL)shouldAutoRevokeIfNeeded {
    id value = [self preferenceValueForKey:@"shouldAutoRevokeIfNeeded"];
    return value ? [value boolValue] : NO;
}

+ (NSTimeInterval)heartbeatTimerInterval {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"heartbeatTimerInterval"];
    int time = value ? [value intValue] : 2;

    NSTimeInterval interval = 3600;
    interval *= time;

    return interval;
}

+ (id)preferenceValueForKey:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] objectForKey:key];
}

+ (void)setPreferenceValue:(id)value forKey:(NSString *)key withNotification:(NSString *)notification {
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:key];

    // 写入 CFPreferences（RePro 自己的域；已无守护进程需要同步）
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR("com.reprovision.repro"), kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    CFPreferencesAppSynchronize(CFSTR("com.reprovision.repro"));

    // Broadcast notification as Darwin
    if (notification)
        [self _broadcastNotification:notification withUserInfo:nil];
}

+ (void)_broadcastNotification:(NSString *)notifiation withUserInfo:(NSDictionary *)userInfo {
    [[NSNotificationCenter defaultCenter] postNotificationName:notifiation object:nil userInfo:userInfo];
}

/////////////////////////////////////////////////////////////////////////////////////////////////
// User Account
/////////////////////////////////////////////////////////////////////////////////////////////////

+ (NSString *)getUsername {
    NSString *username = [[NSUserDefaults standardUserDefaults] objectForKey:@"cachedUsername"];
    NSArray *components = [username componentsSeparatedByString:@"|"];
    if ([components count] < 2) return nil;
    return username;
}

+ (NSString *)getPassword {
    // 优先从 Keychain 读取
    NSString *password = [SAMKeychain passwordForService:SERVICENAME account:[self getUsername]];
    if (password && password.length > 0) {
        return password;
    }

    // Keychain 读不到（锁屏/后台等场景）→ 回退读本地缓存文件
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:kCredentialsCachePath];
    if (cache) {
        NSString *cachedPwd = cache[@"password"];
        if (cachedPwd && cachedPwd.length > 0) {
            return cachedPwd;
        }
    }
    return nil;
}

+ (NSString *)getTeamID {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"cachedTeamID"];
}

+ (NSString *)getCredentialsVersion {
    NSString *version = [[NSUserDefaults standardUserDefaults] objectForKey:@"credentialsVersion"];
    return version ? version : @"0";
}

+ (void)storeUsername:(NSString *)username password:(NSString *)password andTeamID:(NSString *)teamId {
    // 关键修复：把 Apple ID 密码项的 accessible 设为 AfterFirstUnlock。
    // 默认 SAMKeychain 不指定 accessible，系统按 kSecAttrAccessibleWhenUnlocked 处理 —
    // 设备锁屏/未解锁时 Keychain 不可读，导致 isSignedIn 为假、后台自动续签被中止。
    //
    // ⚠️ 关键坑（v1.1.74 修复无效的真因）：iOS 的 SecItemUpdate 无法修改「已存在
    // Keychain 项」的 kSecAttrAccessible，该属性只能在 SecItemAdd 创建时设定。
    // SAMKeychain 的 save: 对已有项走的是 Update 分支，所以即便先 setAccessibilityType:
    // 再 setPassword:，旧项的 accessible 也不会变（永远停留在首次创建时的 WhenUnlocked）。
    // 因此此处改为「先删除再写入」，确保新项的 accessible=AfterFirstUnlock 真正生效。
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlock];

    [[NSUserDefaults standardUserDefaults] setObject:username forKey:@"cachedUsername"];

    [SAMKeychain deletePasswordForService:SERVICENAME account:username];
    [SAMKeychain setPassword:password forService:SERVICENAME account:username];

    [[NSUserDefaults standardUserDefaults] setObject:teamId forKey:@"cachedTeamID"];
    [[NSUserDefaults standardUserDefaults] setObject:CURRENT_CREDENTIALS_VERSION forKey:@"credentialsVersion"];

    // 同步写入本地凭证缓存文件（锁屏 Keychain 不可读时的 fallback）
    NSDictionary *cache = @{
        @"username": username ?: @"",
        @"password": password ?: @"",
        @"teamID": teamId ?: @""
    };
    [cache writeToFile:kCredentialsCachePath atomically:YES];

    // 设置权限 600（仅 owner 可读）
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                     ofItemAtPath:kCredentialsCachePath
                                            error:nil];
}

/// 把已存在的 Apple ID 密码 Keychain 项升级为 AfterFirstUnlock。
/// 旧版未指定 accessible（默认 WhenUnlocked），锁屏时后台自动续签读不到密码而失败。
/// 本方法应在 App 已解锁、处于前台时调用（此时密码可读），删后重建一次即可升级其 accessible。
/// 升级后即使设备再次锁屏，只要解锁过一次，后台自动续签也能读到密码。
///
/// 注意：必须用「删后重建」而非 setPassword:（后者走 SecItemUpdate，无法改变
/// kSecAttrAccessible）。详见 storeUsername: 的注释。
+ (void)migrateKeychainAccessibility {
    NSString *username = [self getUsername];
    NSString *teamID = [[NSUserDefaults standardUserDefaults] objectForKey:@"cachedTeamID"];
    if (username.length == 0 || teamID.length == 0) {
        return; // 未登录，无需迁移
    }
    // 仅在当前能读到密码时重写（调用方需已解锁）
    NSString *pwd = [SAMKeychain passwordForService:SERVICENAME account:username];
    if (pwd.length == 0) {
        return;
    }
    // 关键：SecItemUpdate 无法改变已存在项的 accessible，必须删后重建才能真正升级。
    [SAMKeychain deletePasswordForService:SERVICENAME account:username];
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlock];
    [SAMKeychain setPassword:pwd forService:SERVICENAME account:username];

    // 同时刷新本地凭证缓存文件，确保后台 Keychain 不可读时仍有 fallback
    // （老用户登录早于缓存逻辑、缓存文件缺失时，这一步补齐）。
    NSDictionary *cache = @{
        @"username": username ?: @"",
        @"password": pwd ?: @"",
        @"teamID": teamID ?: @""
    };
    [cache writeToFile:kCredentialsCachePath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                     ofItemAtPath:kCredentialsCachePath
                                            error:nil];
}

+ (void)userDidRequestAccountSignIn {
    [self _broadcastNotification:@"RPVDisplayAccountSignInController" withUserInfo:nil];
}

+ (void)userDidRequestAccountSignOut {
    NSString *username = [self getUsername];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cachedUsername"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cachedTeamID"];

    // Remove password from Keychain
    [SAMKeychain deletePasswordForService:SERVICENAME account:username];

    // 删除本地凭证缓存文件
    [[NSFileManager defaultManager] removeItemAtPath:kCredentialsCachePath error:nil];

    [self _broadcastNotification:@"RPVDisplayAccountSignInController" withUserInfo:nil];
}

/////////////////////////////////////////////////////////////////////////////////////////////////
// Apple Watch
/////////////////////////////////////////////////////////////////////////////////////////////////

+ (BOOL)hasActivePairedWatch {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    // Load NanoRegistry if needed.
    dispatch_once(&nanoRegistryOnceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/NanoRegistry.framework/NanoRegistry", RTLD_NOW);
    });

    NRPairedDeviceRegistry *sharedRegistry = [objc_getClass("NRPairedDeviceRegistry") sharedInstance];
    return [sharedRegistry isPaired];
#endif
}

+ (NSString *)activePairedWatchUDID {
    return [self _valueForActivePairedWatchWithProperty:@"UDID"];
}

+ (NSString *)activePairedWatchName {
    return [self _valueForActivePairedWatchWithProperty:@"name"];
}

+ (id)_valueForActivePairedWatchWithProperty:(NSString *)property {
#if TARGET_OS_SIMULATOR
    return @"";
#else
    // Load NanoRegistry if needed.
    dispatch_once(&nanoRegistryOnceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/NanoRegistry.framework/NanoRegistry", RTLD_NOW);
    });

    NRPairedDeviceRegistry *sharedRegistry = [objc_getClass("NRPairedDeviceRegistry") sharedInstance];
    NRDevice *currentWatchDevice = [sharedRegistry getActivePairedDevice];
    return [currentWatchDevice valueForProperty:property];
#endif
}

//////////////////////////////////////////////////////////////////////////////////
// Helper methods.
//////////////////////////////////////////////////////////////////////////////////

+ (NSString *)getFormattedTimeRemainingForExpirationDate:(NSDate *)expirationDate {
    NSDate *now = [NSDate date];

    NSTimeInterval distanceBetweenDates = [expirationDate timeIntervalSinceDate:now];
    double secondsInAnHour = 3600;
    NSInteger hoursBetweenDates = distanceBetweenDates / secondsInAnHour;

    int days = (int)floor((CGFloat)hoursBetweenDates / 24.0);
    int minutes = distanceBetweenDates / 60;

    if (days > 0) {
        // round up days to make more sense to the user
        return [NSString stringWithFormat:@"%d day%@, %d hour%@", days, days == 1 ? @"" : @"s", (int)hoursBetweenDates - (days * 24), hoursBetweenDates == 1 ? @"" : @"s"];
    } else if (hoursBetweenDates > 0) {
        // less than 24 hours, warning time.
        return [NSString stringWithFormat:@"%d hour%@", (int)hoursBetweenDates, hoursBetweenDates == 1 ? @"" : @"s"];
    } else if (minutes > 0) {
        // less than 1 hour, warning time. (!!)
        return [NSString stringWithFormat:@"%d minute%@", minutes, minutes == 1 ? @"" : @"s"];
    } else {
        return @"Expired";
    }
}

+ (CGRect)boundedRectForFont:(UIFont *)font andText:(NSString *)text width:(CGFloat)width {
    if (!text || !font) {
        return CGRectZero;
    }

    if (![text isKindOfClass:[NSAttributedString class]]) {
        NSAttributedString *attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{ NSFontAttributeName: font }];
        CGRect rect = [attributedText boundingRectWithSize:(CGSize){ width, CGFLOAT_MAX }
                                                   options:NSStringDrawingUsesLineFragmentOrigin
                                                   context:nil];
        return rect;
    } else {
        return [(NSAttributedString *)text boundingRectWithSize:(CGSize){ width, CGFLOAT_MAX }
                                                        options:NSStringDrawingUsesLineFragmentOrigin
                                                        context:nil];
    }
}

@end
