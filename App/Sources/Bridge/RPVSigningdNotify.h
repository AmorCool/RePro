//
//  RPVSigningdNotify.h
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RPVSigningdNotify : NSObject

+ (instancetype)shared;

/// 通知 repro-signingd LaunchDaemon 重新加载配置（设置页保存后调用）
+ (void)notifyConfigUpdated;

/// 通知 repro-signingd LaunchDaemon 续签已完成（匹配原项目 applicationDidFinishTask）
+ (void)notifySigningComplete;

/// 通知 repro-signingd 确保真实 TCC.db 中的通知权限
/// RootHide 下 App 的 requestAuthorization 写 overlay → 真系统不认。
/// daemon 在 namespace 外用 sqlite3 直接写真实 TCC.db 授权。
+ (void)notifyEnsureNotificationPermission;

@end

NS_ASSUME_NONNULL_END
