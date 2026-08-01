//
//  RPVSigningdNotify.h
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RPVSigningdNotify : NSObject

+ (instancetype)shared;

/// 通知 repro-signingd LaunchDaemon 重新加载配置
+ (void)notifyConfigUpdated;

/// 通知 repro-signingd LaunchDaemon 续签已完成
+ (void)notifySigningComplete;

@end

NS_ASSUME_NONNULL_END
