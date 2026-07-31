//
//  RPVBridge.m
//  RePro
//
//  Swift <-> ReProvision 业务层桥接的实现。
//
//  这里所有流程都严格按原版 ReProvision 的调用顺序照搬：
//    登录      -> RPVAccountViewController.didTapConfirmButton
//    2FA 回退  -> RPVAccount2FAViewController
//    选 Team   -> RPVAccountTeamIDViewController + RPVAccountFinalController
//    重签      -> RPVApplicationDetailController._initiateSigningForCurrentApplication
//    导入 IPA  -> AppDelegate._showApplicationDetailControllerFromFileURL
//  不在此处发明任何新的签名 / 鉴权逻辑。
//

#import "RPVBridge.h"

#import "RPVApplication.h"
#import "RPVApplicationDatabase.h"
#import "RPVApplicationSigning.h"
#import "RPVIpaBundleApplication.h"
#import "RPVAccountChecker.h"
#import "RPVResources.h"
#import "RZSignRunner.h"
#import "EEAppleServices.h"

#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>

#pragma mark - 数据对象

@implementation RPVAppInfo
@end

@implementation RPVLoginResult
@end

@implementation RPVEnvironmentInfo
@end

#pragma mark - 桥接主类

static NSString *const RPVBridgeErrorDomain = @"com.reprovision.repro.bridge";

typedef NS_ENUM(NSInteger, RPVBridgeErrorCode) {
    RPVBridgeErrorNotSignedIn      = 1,
    RPVBridgeErrorAppNotFound      = 2,
    RPVBridgeErrorBusy             = 3,
    RPVBridgeErrorIPAUnreadable    = 4,
    RPVBridgeErrorNoTeamSelected   = 5,
};

@interface RPVBridge () <RPVApplicationSigningProtocol>

/// 登录过程中 Apple 返回的凭据（user = identity，password = gsToken），
/// 供后续 selectTeamID: 注册设备时使用。
@property (nonatomic, strong, nullable) NSURLCredential *pendingCredential;
/// 登录返回的 Team 列表，selectTeamID: 时用来校验
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *pendingTeams;

/// 当前这一轮重签的完成回调（同一时间只允许一轮，和原版流水线一致）
@property (nonatomic, copy, nullable) void (^pendingSigningCompletion)(NSError *_Nullable error);
/// 本轮重签过程中记录到的第一个错误
@property (nonatomic, strong, nullable) NSError *pendingSigningError;

@property (nonatomic, strong) dispatch_queue_t workQueue;

@end

@implementation RPVBridge

+ (instancetype)sharedInstance {
    static RPVBridge *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[RPVBridge alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("com.reprovision.repro.bridge", DISPATCH_QUEUE_SERIAL);
        // 只注册一次观察者，之后所有重签进度都从这里分发出去
        [[RPVApplicationSigning sharedInstance] addSigningUpdatesObserver:self];
    }
    return self;
}

- (void)dealloc {
    [[RPVApplicationSigning sharedInstance] removeSigningUpdatesObserver:self];
}

#pragma mark - 小工具

+ (NSError *)errorWithCode:(RPVBridgeErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:RPVBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"未知错误"}];
}

static void RPVBridgeCallOnMain(dispatch_block_t block) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

#pragma mark - 账号状态

- (NSString *)username {
    NSString *value = [RPVResources getUsername];
    return value.length > 0 ? value : nil;
}

- (NSString *)teamID {
    NSString *value = [RPVResources getTeamID];
    return value.length > 0 ? value : nil;
}

- (BOOL)isSignedIn {
    return [RPVResources getUsername].length > 0
        && [RPVResources getPassword].length > 0
        && [RPVResources getTeamID].length > 0;
}

- (NSString *)deviceUDID {
    NSString *udid = [[RPVAccountChecker sharedInstance] UDIDForCurrentDevice];
    return udid.length > 0 ? udid : nil;
}

#pragma mark - 登录流程

/// 把原版那个 4 参数回调统一翻译成 RPVLoginResult。
/// 分支顺序和 RPVAccountViewController.didTapConfirmButton 完全一致：
/// 先看 teamIDArray，再看 appSpecificRequired，最后才算失败。
- (void)_handleLoginCallbackWithFailureReason:(NSString *)failureReason
                                   resultCode:(NSString *)resultCode
                                  teamIDArray:(NSArray *)teamIDArray
                                   credential:(NSURLCredential *)credential
                                   completion:(void (^)(RPVLoginResult *))completion {
    RPVLoginResult *result = [[RPVLoginResult alloc] init];
    result.failureReason = failureReason;
    result.resultCode = resultCode;

    if (teamIDArray) {
        result.outcome = RPVLoginOutcomeSuccess;
        result.teams = teamIDArray;
        self.pendingCredential = credential;
        self.pendingTeams = teamIDArray;
    } else if ([resultCode isEqualToString:@"appSpecificRequired"]) {
        result.outcome = RPVLoginOutcomeNeeds2FA;
    } else {
        result.outcome = RPVLoginOutcomeFailure;
        if (result.failureReason.length == 0) {
            result.failureReason = @"账号或密码不正确";
        }
    }

    RPVBridgeCallOnMain(^{
        if (completion) completion(result);
    });
}

- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(void (^)(RPVLoginResult *))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workQueue, ^{
        [[RPVAccountChecker sharedInstance] checkUsername:username
                                             withPassword:password
                                     andCompletionHandler:^(NSString *failureReason,
                                                            NSString *resultCode,
                                                            NSArray *teamIDArray,
                                                            NSURLCredential *credentials) {
            [weakSelf _handleLoginCallbackWithFailureReason:failureReason
                                                 resultCode:resultCode
                                                teamIDArray:teamIDArray
                                                 credential:credentials
                                                 completion:completion];
        }];
    });
}

- (void)continueTwoFactorAuthenticationWithCompletion:(void (^)(RPVLoginResult *))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workQueue, ^{
        // 原版 RPVAccount2FAViewController 就是无参调用这个接口：
        // RPVAuthentication 里缓存了 cachedUserIdentityFor2FA / cachedUserPasswordFor2FA，
        // fallbackImpl 走 AuthKit 拉起系统验证界面，用户在系统弹窗里确认后才回调。
        [[RPVAccountChecker sharedInstance] request2FAFallbackWithCompletionHandler:^(NSString *failureReason,
                                                                                     NSString *resultCode,
                                                                                     NSArray *teamIDArray,
                                                                                     NSURLCredential *credential) {
            [weakSelf _handleLoginCallbackWithFailureReason:failureReason
                                                 resultCode:resultCode
                                                teamIDArray:teamIDArray
                                                 credential:credential
                                                 completion:completion];
        }];
    });
}

- (void)selectTeamID:(NSString *)teamID
          completion:(void (^)(NSError *_Nullable))completion {
    NSURLCredential *credential = self.pendingCredential;
    if (!credential || teamID.length == 0) {
        RPVBridgeCallOnMain(^{
            if (completion) {
                completion([RPVBridge errorWithCode:RPVBridgeErrorNoTeamSelected
                                            message:@"登录状态已失效，请重新登录"]);
            }
        });
        return;
    }

    NSString *identity = credential.user;
    NSString *gsToken = credential.password;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workQueue, ^{
        // 与 RPVAccountFinalController 一致：先注册设备，再落库。
        // 注册返回的 error 只代表「本机已注册过」，原版同样忽略它继续往下走。
        [[RPVAccountChecker sharedInstance] registerCurrentDeviceForTeamID:teamID
                                                             withIdentity:identity
                                                                  gsToken:gsToken
                                                     andCompletionHandler:^(NSError *error) {
            [RPVResources storeUsername:identity password:gsToken andTeamID:teamID];

            __strong typeof(weakSelf) strongSelf = weakSelf;
            strongSelf.pendingCredential = nil;
            strongSelf.pendingTeams = nil;

            RPVBridgeCallOnMain(^{
                if (completion) completion(nil);
            });
        }];
    });
}

- (void)signOut {
    [RPVResources storeUsername:@"" password:@"" andTeamID:@""];
    [RPVResources userDidRequestAccountSignOut];
    self.pendingCredential = nil;
    self.pendingTeams = nil;
}

#pragma mark - 应用列表

/// 把 RPVApplication 转成 Swift 能直接消费的快照。
/// 图标在这里就渲染成 PNG，避免 Swift 侧再碰 UIImage 的懒加载。
+ (RPVAppInfo *)_infoFromApplication:(RPVApplication *)application {
    RPVAppInfo *info = [[RPVAppInfo alloc] init];
    info.bundleIdentifier = [application bundleIdentifier] ?: @"";
    info.displayName = [application applicationName] ?: info.bundleIdentifier;
    info.version = [application applicationVersion] ?: @"";
    info.expiryDate = [application applicationExpiryDate];
    info.hasEmbeddedProvision = [application hasEmbeddedMobileprovision];

    UIImage *icon = [application applicationIcon];
    if (icon) {
        info.iconPNGData = UIImagePNGRepresentation(icon);
    }
    return info;
}

- (void)fetchInstalledAppsWithCompletion:(void (^)(NSArray<RPVAppInfo *> *, NSError *_Nullable))completion {
    dispatch_async(self.workQueue, ^{
        NSString *teamID = [RPVResources getTeamID];

        NSArray *applications = nil;
        if (teamID.length > 0) {
            applications = [[RPVApplicationDatabase sharedInstance] getAllApplicationsForTeamID:teamID];
        }

        // 未登录、或当前 Team 下没有应用时，退回列出所有带 embedded.mobileprovision
        // 的旁加载应用，保证界面不是一片空白。
        if (applications.count == 0) {
            applications = [[RPVApplicationDatabase sharedInstance] getAllSideloadedApplicationsNotMatchingTeamID:@""];
        }

        NSMutableArray<RPVAppInfo *> *results = [NSMutableArray arrayWithCapacity:applications.count];
        for (RPVApplication *application in applications) {
            RPVAppInfo *info = [RPVBridge _infoFromApplication:application];
            if (info.bundleIdentifier.length > 0) {
                [results addObject:info];
            }
        }

        // 按到期时间升序，最快过期的排最前；没有到期日的排最后。
        [results sortUsingComparator:^NSComparisonResult(RPVAppInfo *lhs, RPVAppInfo *rhs) {
            if (!lhs.expiryDate && !rhs.expiryDate) {
                return [lhs.displayName localizedCaseInsensitiveCompare:rhs.displayName];
            }
            if (!lhs.expiryDate) return NSOrderedDescending;
            if (!rhs.expiryDate) return NSOrderedAscending;
            return [lhs.expiryDate compare:rhs.expiryDate];
        }];

        RPVBridgeCallOnMain(^{
            if (completion) completion(results, nil);
        });
    });
}

#pragma mark - 重签名

/// 开一轮新的重签流水线。已有一轮在跑时直接拒绝，和原版的
/// RPVErrorAlreadyUndertakingPipeline 行为保持一致。
- (BOOL)_beginPipelineWithCompletion:(void (^)(NSError *_Nullable))completion {
    @synchronized (self) {
        if (self.pendingSigningCompletion) {
            RPVBridgeCallOnMain(^{
                if (completion) {
                    completion([RPVBridge errorWithCode:RPVBridgeErrorBusy
                                                message:@"已有签名任务正在进行"]);
                }
            });
            return NO;
        }
        self.pendingSigningCompletion = completion;
        self.pendingSigningError = nil;
    }
    return YES;
}

- (void)_finishPipelineWithError:(NSError *)error {
    void (^completion)(NSError *_Nullable) = nil;
    @synchronized (self) {
        completion = self.pendingSigningCompletion;
        self.pendingSigningCompletion = nil;
        if (!error) error = self.pendingSigningError;
        self.pendingSigningError = nil;
    }
    if (completion) {
        RPVBridgeCallOnMain(^{
            completion(error);
        });
    }
}

- (void)resignApplicationWithBundleIdentifier:(NSString *)bundleIdentifier
                                   completion:(void (^)(NSError *_Nullable))completion {
    if (!self.isSignedIn) {
        RPVBridgeCallOnMain(^{
            if (completion) {
                completion([RPVBridge errorWithCode:RPVBridgeErrorNotSignedIn
                                            message:@"请先登录 Apple ID"]);
            }
        });
        return;
    }

    RPVApplication *application =
        [[RPVApplicationDatabase sharedInstance] getApplicationWithBundleIdentifier:bundleIdentifier];
    if (!application) {
        RPVBridgeCallOnMain(^{
            if (completion) {
                completion([RPVBridge errorWithCode:RPVBridgeErrorAppNotFound
                                            message:@"找不到该应用"]);
            }
        });
        return;
    }

    if (![self _beginPipelineWithCompletion:completion]) return;

    dispatch_async(self.workQueue, ^{
        [[RPVApplicationSigning sharedInstance] resignSpecificApplications:@[application]
                                                                withTeamID:[RPVResources getTeamID]
                                                                  username:[RPVResources getUsername]
                                                                  password:[RPVResources getPassword]];
    });
}

- (void)resignAllExpiringApplicationsWithThreshold:(int)thresholdDays
                                        completion:(void (^)(NSError *_Nullable))completion {
    if (!self.isSignedIn) {
        RPVBridgeCallOnMain(^{
            if (completion) {
                completion([RPVBridge errorWithCode:RPVBridgeErrorNotSignedIn
                                            message:@"请先登录 Apple ID"]);
            }
        });
        return;
    }

    if (![self _beginPipelineWithCompletion:completion]) return;

    dispatch_async(self.workQueue, ^{
        [[RPVApplicationSigning sharedInstance] resignApplications:YES
                                            thresholdForExpiration:thresholdDays
                                                        withTeamID:[RPVResources getTeamID]
                                                          username:[RPVResources getUsername]
                                                          password:[RPVResources getPassword]];
    });
}

- (BOOL)removeApplicationWithBundleIdentifier:(NSString *)bundleIdentifier {
    return [[RPVApplicationSigning sharedInstance] removeApplicationWithBundleIdentifier:bundleIdentifier];
}

#pragma mark - IPA 导入

- (void)importAndInstallIPAAtURL:(NSURL *)url
                      completion:(void (^)(RPVAppInfo *_Nullable, NSError *_Nullable))completion {
    if (!self.isSignedIn) {
        RPVBridgeCallOnMain(^{
            if (completion) {
                completion(nil, [RPVBridge errorWithCode:RPVBridgeErrorNotSignedIn
                                                 message:@"请先登录 Apple ID"]);
            }
        });
        return;
    }

    dispatch_async(self.workQueue, ^{
        // initWithIpaURL: 内部完成 security-scoped 读取 + 复制到 tmp + 解析 Info.plist
        RPVIpaBundleApplication *ipaApplication = [[RPVIpaBundleApplication alloc] initWithIpaURL:url];

        if ([[ipaApplication bundleIdentifier] length] == 0) {
            RPVBridgeCallOnMain(^{
                if (completion) {
                    completion(nil, [RPVBridge errorWithCode:RPVBridgeErrorIPAUnreadable
                                                     message:@"无法读取这个 .ipa，可能是文件损坏或无访问权限"]);
                }
            });
            return;
        }

        RPVAppInfo *info = [RPVBridge _infoFromApplication:ipaApplication];

        BOOL started = [self _beginPipelineWithCompletion:^(NSError *_Nullable error) {
            if (completion) completion(error ? nil : info, error);
        }];
        if (!started) return;

        [[RPVApplicationSigning sharedInstance] resignSpecificApplications:@[ipaApplication]
                                                                withTeamID:[RPVResources getTeamID]
                                                                  username:[RPVResources getUsername]
                                                                  password:[RPVResources getPassword]];
    });
}

#pragma mark - RPVApplicationSigningProtocol

- (void)applicationSigningDidStart {
    // 进度会通过 applicationSigningUpdateProgress:forBundleIdentifier: 陆续到达，这里不需要额外处理。
}

- (void)applicationSigningUpdateProgress:(int)progress forBundleIdentifier:(NSString *)bundleIdentifier {
    void (^handler)(NSString *, int) = self.signingProgressHandler;
    if (!handler) return;
    RPVBridgeCallOnMain(^{
        handler(bundleIdentifier ?: @"", progress);
    });
}

- (void)applicationSigningDidEncounterError:(NSError *)error forBundleIdentifier:(NSString *)bundleIdentifier {
    @synchronized (self) {
        if (!self.pendingSigningError) self.pendingSigningError = error;
    }

    void (^handler)(NSString *, NSError *) = self.signingErrorHandler;
    if (handler && error) {
        RPVBridgeCallOnMain(^{
            handler(bundleIdentifier ?: @"", error);
        });
    }
}

- (void)applicationSigningCompleteWithError:(NSError *)error {
    void (^handler)(NSError *_Nullable) = self.signingCompletionHandler;
    if (handler) {
        RPVBridgeCallOnMain(^{
            handler(error);
        });
    }
    [self _finishPipelineWithError:error];
}

#pragma mark - 环境体检

/// RootHide 的根目录是每次开机随机生成的，只能通过 App bundle 旁边的
/// .jbroot 符号链接解析出来（与 RZSignRunner.roothideJbRoot 同一套判据）。
static NSString *RPVResolvedRootHideRoot(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *link = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@".jbroot"];
    if (![fileManager fileExistsAtPath:link]) return nil;

    NSString *resolved = [link stringByResolvingSymlinksInPath];
    if (resolved.length == 0) return nil;
    if (![fileManager fileExistsAtPath:[resolved stringByAppendingPathComponent:@"usr/local/bin"]]) {
        return nil;
    }
    return resolved;
}

/// 找到按需 root helper（repro-helper）的绝对路径，找不到返回 nil。
/// 三种越狱形态的安装位置不同：RootHide 在随机 jbroot 下，Dopamine 在 /var/jb，
/// rootful 就是标准根路径。
static NSString *RPVResolvedRootHelperPath(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *rootHideRoot = RPVResolvedRootHideRoot();
    if (rootHideRoot) {
        [candidates addObject:[rootHideRoot stringByAppendingPathComponent:@"usr/libexec/repro-helper"]];
    }
    [candidates addObjectsFromArray:@[
        @"/var/jb/usr/libexec/repro-helper",
        @"/usr/libexec/repro-helper"
    ]];

    for (NSString *candidate in candidates) {
        if ([fileManager isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

/// 同步拉起 repro-helper 干一件需要 root 的活，退出码 0 视为成功。
/// 用 posix_spawn 而不是 XPC —— helper 是 setuid root 的一次性进程，做完就退出。
static BOOL RPVRunRootHelper(NSString *helperPath, NSArray<NSString *> *arguments) {
    if (helperPath.length == 0) return NO;

    NSUInteger count = arguments.count;
    const char **argv = (const char **)calloc(count + 2, sizeof(char *));
    if (!argv) return NO;
    argv[0] = [helperPath UTF8String];
    for (NSUInteger i = 0; i < count; i++) {
        argv[i + 1] = [arguments[i] UTF8String];
    }
    argv[count + 1] = NULL;

    // 把 helper 的 stdout/stderr 收到临时文件里，失败时能看到它到底卡在哪。
    NSString *logPath = [NSString stringWithFormat:@"%@repro-helper_%@.log",
                         NSTemporaryDirectory(), [[NSUUID UUID] UUIDString]];

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO,
                                     [logPath fileSystemRepresentation],
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO);

    pid_t pid = 0;
    int spawnRC = posix_spawn(&pid, [helperPath UTF8String], &fileActions, NULL, (char *const *)argv, NULL);
    posix_spawn_file_actions_destroy(&fileActions);
    free(argv);

    if (spawnRC != 0) {
        NSLog(@"*** [RePro] repro-helper 启动失败: %d (%@)", spawnRC, helperPath);
        [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
        return NO;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

    NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

    NSLog(@"*** [RePro] repro-helper %@ exit=%d\n%@",
          [arguments componentsJoinedByString:@" "], exitCode, log.length ? log : @"(无输出)");

    return exitCode == 0;
}

- (void)fetchEnvironmentInfoWithCompletion:(void (^)(RPVEnvironmentInfo *))completion {
    dispatch_async(self.workQueue, ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        RPVEnvironmentInfo *info = [[RPVEnvironmentInfo alloc] init];

        // 1) 越狱形态：RootHide 优先（有 .jbroot），其次 Dopamine（/var/jb），最后 rootful。
        NSString *rootHideRoot = RPVResolvedRootHideRoot();
        if (rootHideRoot) {
            info.jailbreakKind = @"roothide";
            info.jailbreakRoot = rootHideRoot;
        } else if ([fileManager fileExistsAtPath:@"/var/jb"]) {
            info.jailbreakKind = @"dopamine";
            info.jailbreakRoot = @"/var/jb";
        } else if ([fileManager fileExistsAtPath:@"/Library/dpkg"] ||
                   [fileManager fileExistsAtPath:@"/var/lib/dpkg"]) {
            info.jailbreakKind = @"rootful";
            info.jailbreakRoot = @"/";
        } else {
            info.jailbreakKind = @"unknown";
            info.jailbreakRoot = nil;
        }

        // 2) zsign：zsignBinaryPath 找不到时会兜底返回相对名 "zsign"，
        //    这里只认绝对路径，避免界面上显示一个假的「已就绪」。
        NSString *zsign = [[RZSignRunner sharedRunner] zsignBinaryPath];
        info.zsignPath = [zsign hasPrefix:@"/"] ? zsign : nil;

        // 3) Apple 根证书必须随 App 打包，EESigning 用 mainBundle 读取它们。
        info.certificatesBundled =
            [[NSBundle mainBundle] pathForResource:@"apple-ios" ofType:@"pem"] != nil &&
            [[NSBundle mainBundle] pathForResource:@"apple-ios-g3" ofType:@"pem"] != nil;

        // 4) 按需 root helper：找不到不算致命，Vendor 侧会退回直接写文件。
        NSString *helperPath = RPVResolvedRootHelperPath();
        info.rootHelperAvailable = (helperPath != nil);
        info.rootHelperPath = helperPath;

        // 5) 账号
        info.signedIn = self.isSignedIn;
        info.username = self.username;
        info.teamID = self.teamID;
        info.deviceUDID = self.deviceUDID;

        // 6) 旁加载应用概况
        NSString *teamID = [RPVResources getTeamID];
        NSArray *applications = nil;
        if (teamID.length > 0) {
            applications = [[RPVApplicationDatabase sharedInstance] getAllApplicationsForTeamID:teamID];
        }
        if (applications.count == 0) {
            applications = [[RPVApplicationDatabase sharedInstance] getAllSideloadedApplicationsNotMatchingTeamID:@""];
        }
        info.sideloadedAppCount = (NSInteger)applications.count;

        NSDate *nearest = nil;
        for (RPVApplication *application in applications) {
            NSDate *expiry = [application applicationExpiryDate];
            if (!expiry) continue;
            if (!nearest || [expiry compare:nearest] == NSOrderedAscending) {
                nearest = expiry;
            }
        }
        info.nearestExpiryDate = nearest;

        RPVBridgeCallOnMain(^{
            if (completion) completion(info);
        });
    });
}

#pragma mark - root helper 注入点

/// 把 Vendor 里两个需要 root 的回调接到 repro-helper 上。
/// 原版这两件事是走 XPC 找常驻守护进程做的，现在改成一次性 setuid root 进程。
/// helper 不存在时干脆不注册 —— Vendor 会走「自己直接写文件」的分支，
/// rootful 环境下本来就能写成功。
+ (void)installRootHelperHandlers {
    NSString *helperPath = RPVResolvedRootHelperPath();
    if (helperPath.length == 0) {
        NSLog(@"*** [RePro] 未找到 repro-helper，需要 root 的操作将由 App 自己尝试");
        return;
    }

    NSLog(@"*** [RePro] 已挂载 root helper: %@", helperPath);

    // 1) 从「文件」App 的安全域读不到 IPA 时，让 root 把它搬进 App 的 tmp。
    [RPVIpaBundleApplication setDaemonFileCopyHandler:^BOOL(NSString *srcPath, NSString *dstPath) {
        if (srcPath.length == 0 || dstPath.length == 0) return NO;
        return RPVRunRootHelper(helperPath, @[@"copy", srcPath, dstPath]);
    }];

    // 2) 描述文件必须落到真实的 /var/Managed Preferences/mobile，App（mobile）写不进去。
    [RPVApplicationSigning setDaemonProfileInstallHandler:^BOOL(NSString *profilePath) {
        if (profilePath.length == 0) return NO;
        return RPVRunRootHelper(helperPath, @[@"install-profile", profilePath]);
    }];
}

- (void)fetchAppIDsWithCompletion:(void (^)(NSArray<RPVAppID *> *_Nullable, NSError *_Nullable))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *teamID = [self teamID];
        if (!teamID || teamID.length == 0) {
            RPVBridgeCallOnMain(^{
                if (completion) completion(nil, [RPVBridge errorWithCode:RPVBridgeErrorNotSignedIn
                                                         message:@"请先登录 Apple ID"]);
            });
            return;
        }

        [[EEAppleServices sharedInstance] ensureSessionWithIdentity:[self username]
                                                            gsToken:[RPVResources getPassword]
                                                 andCompletionHandler:^(NSError *sessionError, NSDictionary *sessionPlist) {
            if (sessionError) {
                RPVBridgeCallOnMain(^{ if (completion) completion(nil, sessionError); });
                return;
            }

            [[EEAppleServices sharedInstance] listAllApplicationsForTeamID:teamID
                                                                 systemType:EESystemTypeiOS
                                                      withCompletionHandler:^(NSError *error, NSDictionary *dict) {
                if (error) {
                    RPVBridgeCallOnMain(^{ if (completion) completion(nil, error); });
                    return;
                }

                NSArray *rawApps = dict[@"appIds"];
                NSMutableArray<RPVAppID *> *result = [NSMutableArray array];
                for (NSDictionary *appDict in rawApps) {
                    RPVAppID *appId = [[RPVAppID alloc] initWithDictionary:appDict];
                    [result addObject:appId];
                }

                // 按过期时间升序排列（与原版一致）
                NSSortDescriptor *sortByDate = [NSSortDescriptor sortDescriptorWithKey:@"applicationExpiryDate"
                                                                         ascending:YES];
                [result sortUsingDescriptors:@[sortByDate]];

                RPVBridgeCallOnMain(^{ if (completion) completion([result copy], nil); });
            }];
        }];
    });
}

- (void)fetchCertificatesWithCompletion:(void (^)(NSArray<RPVCertificateInfo *> *_Nullable, NSError *_Nullable))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *teamID = [self teamID];
        if (!teamID || teamID.length == 0) {
            RPVBridgeCallOnMain(^{
                if (completion) completion(nil, [RPVBridge errorWithCode:RPVBridgeErrorNotSignedIn
                                                         message:@"请先登录 Apple ID"]);
            });
            return;
        }

        [[EEAppleServices sharedInstance] ensureSessionWithIdentity:[self username]
                                                            gsToken:[RPVResources getPassword]
                                                 andCompletionHandler:^(NSError *sessionError, NSDictionary *sessionPlist) {
            if (sessionError) {
                RPVBridgeCallOnMain(^{ if (completion) completion(nil, sessionError); });
                return;
            }

            [[EEAppleServices sharedInstance] listAllDevelopmentCertificatesForTeamID:teamID
                                                                          systemType:EESystemTypeiOS
                                                               withCompletionHandler:^(NSError *error, NSDictionary *dict) {
                if (error) {
                    RPVBridgeCallOnMain(^{ if (completion) completion(nil, error); });
                    return;
                }

                NSArray *dataArray = dict[@"data"];
                NSMutableArray<RPVCertificateInfo *> *result = [NSMutableArray array];
                for (NSDictionary *certDict in dataArray) {
                    RPVCertificateInfo *cert = [[RPVCertificateInfo alloc] initWithDictionary:certDict];
                    [result addObject:cert];
                }

                RPVBridgeCallOnMain(^{ if (completion) completion([result copy], nil); });
            }];
        }];
    });
}

- (void)revokeCertificateWithIdentifier:(NSString *)identifier
                            completion:(void (^)(NSError *_Nullable))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *teamID = [self teamID];
        [[EEAppleServices sharedInstance] ensureSessionWithIdentity:[self username]
                                                            gsToken:[RPVResources getPassword]
                                                 andCompletionHandler:^(NSError *sessionError, NSDictionary *plist) {
            if (sessionError) {
                RPVBridgeCallOnMain(^{ if (completion) completion(sessionError); });
                return;
            }

            [[EEAppleServices sharedInstance] revokeCertificateForIdentifier:identifier
                                                                   andTeamID:teamID
                                                                  systemType:EESystemTypeiOS
                                                       withCompletionHandler:^(NSError *error, NSDictionary *resp) {
                RPVBridgeCallOnMain(^{ if (completion) completion(error); });
            }];
        }];
    });
}

- (void)revokeAllCertificatesWithCompletion:(void (^)(NSError *_Nullable))completion {
    // 先拉取证书列表，再逐个撤销
    [self fetchCertificatesWithCompletion:^(NSArray<RPVCertificateInfo *> *certs, NSError *error) {
        if (error) {
            if (completion) completion(error);
            return;
        }
        if (certs.count == 0) {
            if (completion) completion(nil);
            return;
        }

        // 用 dispatch_group 等待所有撤销完成
        dispatch_group_t group = dispatch_group_create();
        __block NSError *firstError = nil;

        for (RPVCertificateInfo *cert in certs) {
            dispatch_group_enter(group);
            [self revokeCertificateWithIdentifier:cert.identifier completion:^(NSError *err) {
                if (!firstError && err) firstError = err;
                dispatch_group_leave(group);
            }];
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (completion) completion(firstError);
        });
    }];
}

@end



@implementation RPVAppID

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _identifier = [dict[@"identifier"] copy] ?: @"";
        _applicationName = [dict[@"name"] copy] ?: _identifier;

        NSString *expiryStr = dict[@"expirationDate"];
        if (expiryStr && [expiryStr length] > 0) {
            // Apple API 返回的日期可能是 Unix 时间戳或 ISO 格式
            double timestamp = [expiryStr doubleValue];
            if (timestamp > 0) {
                _applicationExpiryDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
            } else {
                // 尝试 ISO 8601 解析
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
                _applicationExpiryDate = [fmt dateFromString:expiryStr];
            }
        }
    }
    return self;
}

@end

#pragma mark - RPVCertificateInfo 实现

@implementation RPVCertificateInfo

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _identifier = [dict[@"id"] copy] ?: @"";

        NSDictionary *attrs = dict[@"attributes"];
        _machineName = [attrs[@"machineName"] copy] ?: @"Unknown";

        // 根据机器名推断来源应用（与原版 RPVTroubleshootingCertificatesViewController 一致）
        NSString *mn = _machineName;
        if ([mn containsString:@"RPV"]) {
            _applicationName = @"ReProvision";
        } else if ([mn containsString:@"AltStore"]) {
            _applicationName = @"AltStore";
        } else if ([mn containsString:@"Cydia"]) {
            _applicationName = @"Cydia Impactor or Extender";
        } else {
            _applicationName = @"Xcode";
        }

        _serialNumber = attrs[@"serialNumber"] ?: @"";
    }
    return self;
}

@end
