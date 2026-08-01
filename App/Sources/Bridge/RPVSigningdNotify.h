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

/// 通知 repro-signingd 显示系统通知
+ (void)notifyShowNotification;

@end

NS_ASSUME_NONNULL_END
