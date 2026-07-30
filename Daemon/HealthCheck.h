//
//  HealthCheck.h/m
//  ReProvision Daemon
//
//  健康检查模块：
//  - 检测守护进程运行状态
//  - 检查二进制权限（root / sandbox）
//  - 检查 zsign 可用性
//  - 报告 Token 和 Anisette 状态
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HealthCheck : NSObject

/// 获取当前完整健康状态字典
- (NSDictionary<NSString *, id> *)currentStatus;

/// 守护进程是否正在运行（始终 YES，因为就是自己）
- (BOOL)isDaemonRunning;

/// 是否具有 root 权限
- (BOOL)hasRootPrivileges;

/// 是否被沙盒限制
- (BOOL)isSandboxed;

/// zsign 二进制路径（如果找到）
- (nullable NSString *)zsignPath;

/// 上次重签时间
- (nullable NSDate *)lastResignTime;

/// 进程运行时间（秒）
- (NSTimeInterval)uptime;

@end

NS_ASSUME_NONNULL_END
