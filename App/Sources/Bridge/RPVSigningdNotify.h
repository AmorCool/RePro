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

/// v2.1.3：App 进程生成完整 Anisette（X-Apple-I-MD 等）缓存到共享 IPC 目录，
/// 供 daemon 签名复用（root 进程 AKAppleIDSession 生成不了完整 Anisette）。
/// 每次进前台调用刷新。
+ (void)refreshAnisetteCache;

/// v2.1.18：响应 daemon 的 Anisette 刷新请求（冷启动路径调用；进程内 notify
/// 通道在 setup 里已注册）。App 只生成 Anisette 缓存，刷新后自动退出。
+ (void)processAnisetteRefreshIfNeeded;

@end

NS_ASSUME_NONNULL_END
