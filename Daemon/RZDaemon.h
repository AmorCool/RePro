//
//  RZDaemon.h
//  ReProvision Daemon
//
//  XPC 服务协议定义与守护进程主类接口
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// XPC 协议版本
extern const uint8_t kRZDaemonProtocolVersion;

/// MachService 名称（与 LaunchDaemon plist 一致）
extern NSString *const kRZDaemonMachServiceName;

/// 日志文件路径
extern NSString *const kRZDaemonLogPath;
extern NSString *const kRZDaemonErrorLogPath;

#pragma mark - XPC 协议

/// 前端 App 与 Daemon 之间的通信协议
@protocol RZDaemonXPCProtocol <NSObject>

/// 心跳检测
- (void)pingWithReply:(void (^)(NSString *response))reply;

/// Apple ID 登录认证
- (void)loginWithAppleID:(NSString *)appleID
                  password:(NSString *)password
                     reply:(void (^)(NSDictionary<NSString *, id> * _Nullable result,
                                     NSError * _Nullable error))reply;

/// 获取已安装应用列表
- (void)getInstalledAppsWithReply:(void (^)(NSArray<NSDictionary *> *apps))reply;

/// 导入 IPA 文件
- (void)importIPAAtPath:(NSString *)path
                   reply:(void (^)(NSDictionary<NSString *, id> * _Nullable appInfo,
                                   NSError * _Nullable error))reply;

/// 重签指定应用
- (void)resignApplicationWithBundleIdentifier:(NSString *)bundleID
                                       reply:(void (^)(BOOL success, NSString * _Nullable errorMessage))reply;

/// 获取健康状态
- (void)getHealthStatusWithReply:(void (^)(NSDictionary<NSString *, id> *status))reply;

/// 重启守护进程
- (void)restartWithReply:(void (^)(BOOL success))reply;

/// 安装 Provisioning Profile
- (void)installProvisioningProfileAtPath:(NSString *)path
                                  reply:(void (^)(BOOL success, NSString * _Nullable errorMessage))reply;

/// 预签 Token
- (void)preSignTokensWithCount:(NSInteger)count
                         reply:(void (^)(NSInteger signedCount))reply;

/// Anisette 状态查询
- (void)getAnisetteStatusWithReply:(void (^)(BOOL ready))reply;

/// 重启 SpringBoard（类似 Sileo 安装完成后的功能）
- (void)respringWithReply:(void (^)(BOOL success, NSString * _Nullable message))reply;

@end

#pragma mark - 守护进程主类

@interface RZDaemon : NSObject <RZDaemonXPCProtocol>

/// 启动 XPC 监听服务
- (void)start;

/// 停止服务
- (void)stop;

/// 当前是否正在运行
@property (nonatomic, readonly) BOOL isRunning;

@end

NS_ASSUME_NONNULL_END
