//
//  RPVNotificationManager.h
//  RePro
//
//  本地通知管理器 —— 移植自 test2 源码（ReProvision-Reborn）的
//  iOS/Notifications/RPVNotificationManager。
//
//  移植要点：
//  1. 完整保留 -[UNUserNotificationCenter initWithBundleIdentifier:] 的 Hook。
//     这是 RootHide 下通知授权能够持久化的关键：namespace 隔离会让通知中心
//     拿到被「翻译」过的 bundle id，授权因此落进 jbroot overlay 的 TCC，
//     进程退出后失效 → 每次打开 App 都重新弹授权。Hook 强制改回真实
//     mainBundle 的 bundle id，授权才会写进真实（非 jbroot）分区。
//  2. 去掉原版对 RMessage（第三方应用内横幅库）与 RPVLocalization / RPVResources
//     的依赖：RePro 没有引入 RMessage，开关改读 NSUserDefaults。
//  3. 去掉 iOS 9 的 UILocalNotification 分支：RePro 最低支持 iOS 15。
//

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

/// 通知总开关（对应设置页「重签通知」），未设置时默认开启
extern NSString *const RPVNotificationsEnabledKey;
/// 调试类通知开关（每个应用逐条播报），未设置时默认关闭
extern NSString *const RPVNotificationsDebugKey;

@interface RPVNotificationManager : NSObject <UNUserNotificationCenterDelegate>

+ (instancetype)sharedInstance;

/// 申请通知权限（仅横幅，不含角标与声音，与原版一致）。
/// 在 application:didFinishLaunchingWithOptions: 里调用一次即可。
- (void)registerToSendNotifications;

/// 查询当前授权状态，回调切回主队列。
/// status 取值同 UNAuthorizationStatus：0=未决定 1=已拒绝 2=已授权 3=临时 4=定时摘要
- (void)fetchAuthorizationStatus:(void (^)(NSInteger status))completion
    NS_SWIFT_NAME(fetchAuthorizationStatus(completion:));

/// 发送一条本地通知。
/// isDebug 为 YES 时只有打开「详细通知」开关才会真正发送。
- (void)sendNotificationWithTitle:(NSString *)title
                             body:(NSString *)body
                   isDebugMessage:(BOOL)isDebug
                andNotificationID:(nullable NSString *)identifier
    NS_SWIFT_NAME(sendNotification(title:body:isDebug:identifier:));

@end

NS_ASSUME_NONNULL_END
