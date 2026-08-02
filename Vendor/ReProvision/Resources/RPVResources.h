//
//  RPVResources.h
//
//
//  Created by Matt Clarke on 09/01/2018.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define CURRENT_CREDENTIALS_VERSION @"2"

@interface RPVResources : NSObject

/////////////////////////////////////////////////////////////////////////////////////////////////
// User Settings
/////////////////////////////////////////////////////////////////////////////////////////////////

+ (BOOL)shouldShowDebugAlerts;
+ (BOOL)shouldShowAlerts;
+ (BOOL)shouldShowNonUrgentAlerts;
+ (int)thresholdForResigning;
+ (BOOL)shouldAutomaticallyResign;
+ (BOOL)shouldResignInLowPowerMode;
+ (BOOL)shouldForceResign;
+ (BOOL)shouldAutoRevokeIfNeeded;
+ (NSTimeInterval)heartbeatTimerInterval;

+ (id)preferenceValueForKey:(NSString *)key;
+ (void)setPreferenceValue:(id)value forKey:(NSString *)key withNotification:(NSString *)notification;

/////////////////////////////////////////////////////////////////////////////////////////////////
// User Account
/////////////////////////////////////////////////////////////////////////////////////////////////

+ (NSString *)getUsername;
+ (NSString *)getPassword;
+ (NSString *)getTeamID;
+ (NSString *)getCredentialsVersion;
+ (void)storeUsername:(NSString *)username password:(NSString *)password andTeamID:(NSString *)teamId;
+ (void)migrateKeychainAccessibility;

/////////////////////////////////////////////////////////////////////////////////////////////////
// 签名状态 Keychain（service = jp.soh.reprovision）
//
// 这些项（uuid / privateKey / privateKeyTeamID）是签名流程的核心状态：
//   · uuid              —— machineId，用于判定「Apple 账号下某张证书是不是本机的」
//   · privateKey        —— 本机开发证书对应的私钥
//   · privateKeyTeamID  —— 私钥关联的 Team ID（用于检测账号切换）
//
// 🔴 它们原本直接走 SAMKeychain（默认 WhenUnlocked），设备锁屏时读不到，后果严重：
//   _identifierForCurrentMachine 读不到 uuid 会「生成一个新 UUID 并覆盖写回」，
//   导致 machineId 永久漂移 → 遍历 Apple 证书列表时永远匹配不上本机证书 →
//   误判「本机没有证书」→ 不撤销就直接提交新 CSR → Apple 报
//   "You already have a current Development certificate" 或
//   "There were errors in the data supplied"。
//
// 因此统一收口到下面两个方法：写入时 accessible=AfterFirstUnlock 并镜像到本地
// 缓存文件；读取时 Keychain 读不到就回退读缓存文件，彻底消除锁屏漂移。
/////////////////////////////////////////////////////////////////////////////////////////////////

/// 读取签名状态项（Keychain 优先，锁屏读不到时回退本地缓存文件）
+ (NSString *)provisioningValueForAccount:(NSString *)account;
/// 写入签名状态项（Keychain 删后重建为 AfterFirstUnlock + 同步镜像到本地缓存文件）
+ (void)setProvisioningValue:(NSString *)value forAccount:(NSString *)account;

+ (void)userDidRequestAccountSignIn;
+ (void)userDidRequestAccountSignOut;

/////////////////////////////////////////////////////////////////////////////////////////////////
// Apple Watch
/////////////////////////////////////////////////////////////////////////////////////////////////

+ (BOOL)hasActivePairedWatch;
+ (NSString *)activePairedWatchUDID;
+ (NSString *)activePairedWatchName;

//////////////////////////////////////////////////////////////////////////////////
// Helper methods.
//////////////////////////////////////////////////////////////////////////////////

+ (NSString *)getFormattedTimeRemainingForExpirationDate:(NSDate *)expirationDate;
+ (CGRect)boundedRectForFont:(UIFont *)font andText:(NSString *)text width:(CGFloat)width;

@end
