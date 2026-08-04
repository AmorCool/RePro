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

// 签名状态缓存路径（uuid / privateKey / privateKeyTeamID 的锁屏 fallback）
static NSString *kProvisioningCachePath = @"/var/mobile/Library/RePro/provisioning.cache";

// 签名状态 Keychain 的 service 名（与 EEProvisioning 保持一致）
#define PROVISIONING_SERVICENAME @"jp.soh.reprovision"

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

/// 把 Apple ID 密码 + 签名状态项（uuid / privateKey / privateKeyTeamID）的
/// Keychain accessible 升级为 AfterFirstUnlock，并镜像到本地缓存文件。
///
/// 旧版未指定 accessible（默认 WhenUnlocked），锁屏时后台自动续签读不到这些值：
///   · 读不到密码 → isSignedIn 为假 → 静默续签直接中止；
///   · 读不到 uuid → 生成新 UUID 覆盖写回 → machineId 漂移 → 误判本机无证书
///     → 不撤销就提交新 CSR → 被 Apple 拒绝。
///
/// 本方法是幂等的，可以反复调用。调用时机（v1.1.91 起全自动，用户无需手动打开 App）：
///   1. AppDelegate.setupCommon —— 每次启动（含 daemon 后台拉起）；
///   2. protectedDataDidBecomeAvailable 通知 —— 设备解锁瞬间；
///   3. applicationDidBecomeActive —— 前台激活时的额外保险。
///
/// 注意：必须用「删后重建」而非 setPassword:（后者走 SecItemUpdate，无法改变
/// kSecAttrAccessible）。详见 storeUsername: 的注释。
+ (void)migrateKeychainAccessibility {
    // 全局设定：此后所有 SAMKeychain 写入（含 EEProvisioning 内部的 setPassword）
    // 都带 accessible=AfterFirstUnlock。必须尽早调用，且与下面的迁移是否执行无关。
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlock];

    // 仅在「保护数据可用」（设备至少解锁过一次）时才执行删后重建。
    // 否则 Keychain 处于不可写状态，delete 可能成功而随后的 add 失败，
    // 反而把原本存在的项弄丢。此时直接返回，等 AppDelegate 监听的
    // protectedDataDidBecomeAvailable 通知在解锁瞬间再自动重试。
    if (![[UIApplication sharedApplication] isProtectedDataAvailable]) {
        return;
    }

    // 🔴 v1.1.164：60 秒去重窗口。migrate 是幂等但**每次执行都删后重建 Keychain 项**
    // + 写缓存文件；用户在「前台打开→上滑退出」循环里，applicationDidBecomeActive
    // 每次激活都会触发一次 → 反复切换 = 反复 delete+add，中间态窗口被反复打开。
    // 若恰好在「已 delete 未 add」瞬间被用户划掉杀后台，密码项丢失（缓存文件可兜底，
    // 但没必要制造风险）。迁移只需成功一次，60s 内跳过后续重复执行。
    static NSTimeInterval lastMigrate = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastMigrate < 60) {
        return;
    }
    lastMigrate = now;

    // ---- 1. 迁移 Apple ID 密码项 ----
    NSString *username = [self getUsername];
    NSString *teamID = [[NSUserDefaults standardUserDefaults] objectForKey:@"cachedTeamID"];
    if (username.length > 0 && teamID.length > 0) {
        // 用 getPassword（含缓存 fallback）而不是直接读 Keychain：
        // 这样即便此刻 Keychain 锁着，只要缓存文件里有密码，也能把 Keychain 项重建出来。
        NSString *pwd = [self getPassword];
        if (pwd.length > 0) {
            // 关键：SecItemUpdate 无法改变已存在项的 accessible，必须删后重建才能真正升级。
            [SAMKeychain deletePasswordForService:SERVICENAME account:username];
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
    }

    // ---- 2. 迁移签名状态项（uuid / privateKey / privateKeyTeamID）----
    // 这三项此前完全没有 fallback，锁屏读不到会导致 machineId 漂移和私钥丢失，
    // 进而误判「本机无证书」→ 不撤销就提交新 CSR → Apple 拒绝。
    for (NSString *account in @[@"uuid", @"privateKey", @"privateKeyTeamID"]) {
        NSString *value = [self provisioningValueForAccount:account];
        if (value.length > 0) {
            // 删后重建，让 accessible=AfterFirstUnlock 生效，并同步镜像到缓存文件
            [self setProvisioningValue:value forAccount:account];
        }
    }
}

#pragma mark - 签名状态 Keychain（带锁屏 fallback）

+ (NSString *)provisioningValueForAccount:(NSString *)account {
    if (account.length == 0) return nil;

    // 优先 Keychain
    NSString *value = [SAMKeychain passwordForService:PROVISIONING_SERVICENAME account:account];
    if (value.length > 0) {
        return value;
    }

    // Keychain 读不到（锁屏/后台）→ 回退本地缓存文件
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:kProvisioningCachePath];
    NSString *cached = cache[account];
    return cached.length > 0 ? cached : nil;
}

+ (void)setProvisioningValue:(NSString *)value forAccount:(NSString *)account {
    if (account.length == 0 || value.length == 0) return;

    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlock];

    // 删后重建：SecItemUpdate 改不了已存在项的 kSecAttrAccessible
    [SAMKeychain deletePasswordForService:PROVISIONING_SERVICENAME account:account];
    [SAMKeychain setPassword:value forService:PROVISIONING_SERVICENAME account:account];

    // 镜像到本地缓存文件（锁屏时的唯一可靠来源）
    NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:kProvisioningCachePath];
    if (!cache) cache = [NSMutableDictionary dictionary];
    cache[account] = value;
    [cache writeToFile:kProvisioningCachePath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                     ofItemAtPath:kProvisioningCachePath
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
