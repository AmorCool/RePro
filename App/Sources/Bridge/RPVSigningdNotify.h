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

/// 请求 repro-signingd 解除免费账号「同一设备最多 3 个自签应用」限制。
/// App 自身没有权限改其它 App 目录的扩展属性，必须交给 root daemon 执行。
/// daemon 侧仍会再判断一次设置开关（bypassFreeAppLimit），关着就不动。
+ (void)notifyBypass3AppRequest;

@end

NS_ASSUME_NONNULL_END
