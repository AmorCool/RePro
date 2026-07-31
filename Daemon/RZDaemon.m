//
//  RZDaemon.m
//  ReProvision Daemon
//
//  守护进程核心实现：
//  1. NSXPCListener 监听前端连接
//  2. 协调各子模块（签名引擎、Anisette、Token 缓存、健康检查）
//  3. root 权限运行，无沙盒限制
//

#import "RZDaemon.h"
#import "SignEngine.h"
#import "AnisetteManager.h"
#import "TokenCacheManager.h"
#import "HealthCheck.h"
#import "ProfileInstaller.h"
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>

const uint8_t kRZDaemonProtocolVersion = 1;
NSString *const kRZDaemonMachServiceName = @"com.reprovision.daemon";
NSString *const kRZDaemonLogPath = @"/var/mobile/Library/Logs/RePro/daemon.log";
NSString *const kRZDaemonErrorLogPath = @"/var/mobile/Library/Logs/RePro/daemon.err";
// daemon 版本号（与 PackageVersion.plist 保持同步）
NSString *const kRZDaemonVersion = @"1.0.44";

@interface RZDaemon ()
@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic, strong) SignEngine *signEngine;
@property (nonatomic, strong) AnisetteManager *anisetteManager;
@property (nonatomic, strong) TokenCacheManager *tokenCache;
@property (nonatomic, strong) HealthCheck *healthCheck;
@property (nonatomic, strong) ProfileInstaller *profileInstaller;
@property (nonatomic, readwrite) BOOL isRunning;
@end

@implementation RZDaemon

- (instancetype)init {
    self = [super init];
    if (self) {
        // NSXPCListener initWithMachServiceName: 在 iOS 标记为 unavailable
        // 使用 ObjC 运行时 performSelector: 绕过编译器检查（daemon 实际运行在 root 环境）
        SEL initSel = NSSelectorFromString(@"initWithMachServiceName:");
        _listener = [[NSXPCListener alloc] performSelector:initSel withObject:kRZDaemonMachServiceName];
        _listener.delegate = self;

        // 初始化各子模块
        _signEngine = [[SignEngine alloc] init];
        _anisetteManager = [[AnisetteManager alloc] init];
        _tokenCache = [[TokenCacheManager alloc] init];
        _healthCheck = [[HealthCheck alloc] init];
        _profileInstaller = [[ProfileInstaller alloc] init];

        // 确保日志目录存在
        [self ensureLogDirectory];
    }
    return self;
}

- (void)start {
    [self.listener resume];
    self.isRunning = YES;
    NSLog(@"[RePro] Daemon 已启动 (protocol v%u)", kRZDaemonProtocolVersion);
}

- (void)stop {
    [self.listener invalidate];
    self.isRunning = NO;
    NSLog(@"[RePro] Daemon 已停止");
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RZDaemonXPCProtocol)];
    newConnection.exportedObject = self;
    newConnection.invalidationHandler = ^{
        NSLog(@"[RePro] 前端连接断开");
    };
    [newConnection resume];
    NSLog(@"[RePro] 新的前端连接已接受");
    return YES;
}

#pragma mark - RZDaemonXPCProtocol 实现

- (void)pingWithReply:(void (^)(NSString *))reply {
    reply([NSString stringWithFormat:@"pong v%u", kRZDaemonProtocolVersion]);
}

- (void)loginWithAppleID:(NSString *)appleID
                  password:(NSString *)password
                     reply:(void (^)(NSDictionary<NSString *,id> * _Nullable, NSError * _Nullable))reply {
    NSLog(@"[RePro] 收到登录请求: %@", appleID);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSDictionary *result = [self.signEngine loginWithAppleID:appleID password:password error:&error];

        if (error) {
            NSLog(@"[RePro] 登录失败: %@", error);
            reply(nil, error);
        } else {
            NSLog(@"[RePro] 登录成功");
            reply(result, nil);
        }
    });
}

- (void)getInstalledAppsWithReply:(void (^)(NSArray<NSDictionary *> *))reply {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *apps = [self.signEngine listInstalledApps];
        reply(apps ?: @[]);
    });
}

- (void)importIPAAtPath:(NSString *)path
                   reply:(void (^)(NSDictionary<NSString *,id> * _Nullable, NSError * _Nullable))reply {
    NSLog(@"[RePro] 收到导入请求: %@", path);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSDictionary *appInfo = [self.signEngine importIPAAtPath:path error:&error];
        reply(appInfo, error);
    });
}

- (void)resignApplicationWithBundleIdentifier:(NSString *)bundleID
                                       reply:(void (^)(BOOL, NSString * _Nullable))reply {
    NSLog(@"[RePro] 收到重签请求: %@", bundleID);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL success = [self.signEngine resignApplication:bundleID error:&error];

        if (!success) {
            NSLog(@"[RePro] 重签失败 [%@]: %@", bundleID, error);
            reply(NO, error.localizedDescription);
        } else {
            NSLog(@"[RePro] 重签成功: %@", bundleID);
            reply(YES, nil);
        }
    });
}

- (void)getHealthStatusWithReply:(void (^)(NSDictionary<NSString *,id> *))reply {
    NSDictionary *status = [self.healthCheck currentStatus];
    // 添加 daemon 版本号
    NSMutableDictionary *mutableStatus = [status mutableCopy];
    mutableStatus[@"daemonVersion"] = kRZDaemonVersion;
    reply(mutableStatus);
}

- (void)restartWithReply:(void (^)(BOOL))reply {
    NSLog(@"[RePro] 收到重启请求");
    // 通过 launchctl kickstart 重启自己（system() 在 iOS 不可用）
    // 注意：kickstart 参数格式是 system/<Label>，Label 来自 plist
    pid_t pid = 0;
    const char *argv[] = { "/bin/launchctl", "kickstart", "system/jp.soh.reprovisiond", NULL };
    int status = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
    if (status == 0) waitpid(pid, NULL, 0);
    reply(status == 0);
}

- (void)installProvisioningProfileAtPath:(NSString *)path
                                  reply:(void (^)(BOOL, NSString * _Nullable))reply {
    NSLog(@"[RePro] 收到 profile 安装请求: %@", path);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL success = [self.profileInstaller installProfileAtPath:path error:&error];
        reply(success, error.localizedDescription);
    });
}

- (void)preSignTokensWithCount:(NSInteger)count
                         reply:(void (^)(NSInteger))reply {
    NSLog(@"[RePro] 收到预签 Token 请求: %ld", (long)count);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger signedCount = [self.tokenCache preSignTokens:count];
        reply(signedCount);
    });
}

- (void)getAnisetteStatusWithReply:(void (^)(BOOL))reply {
    BOOL ready = [self.anisetteManager isReady];
    reply(ready);
}

- (void)respringWithReply:(void (^)(BOOL, NSString * _Nullable))reply {
    NSLog(@"[RePro] 收到重启 SpringBoard 请求");

    // 使用 killall 重启 SpringBoard（越狱环境可用）
    pid_t pid = 0;
    const char *argv[] = { "/usr/bin/killall", "SpringBoard", NULL };
    int status = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, NULL);
    if (status == 0) {
        waitpid(pid, NULL, 0);
        reply(YES, nil);
    } else {
        // fallback: launchctl 方式
        const char *argv2[] = { "/bin/launchctl", "kickstart", "gui/$(id -u)/com.apple.SpringBoard", NULL };
        status = posix_spawn(&pid, argv2[0], NULL, NULL, (char *const *)argv2, NULL);
        if (status == 0) {
            waitpid(pid, NULL, 0);
            reply(YES, @"使用 kickstart 重启");
        } else {
            reply(NO, @"重启失败: 权限不足或命令不可用");
        }
    }
}

#pragma mark - 内部方法

- (void)ensureLogDirectory {
    NSString *logDir = [kRZDaemonLogPath stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:logDir]) {
        [fm createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // 设置日志目录权限为 mobile 可读
    chmod(logDir.UTF8String, 0755);
}

@end
