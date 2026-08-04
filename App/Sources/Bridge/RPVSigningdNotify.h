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

/// 续签因网络权限丢失失败 → 请求 repro-signingd 执行「修复越狱联网并立即重试续签」。
/// 修复动作必须由 daemon（rootfs LaunchDaemon）做：App 自己调 helper 的话，
/// killall SpringBoard 会杀掉 App，而 daemon 下一轮定时器要等一个完整检查间隔才触发，
/// 链路断裂（v1.1.129）。
+ (void)notifyFixCellularRequest;

@end

NS_ASSUME_NONNULL_END
