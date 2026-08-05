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
#import "EEBackend.h"
#import <sys/sysctl.h>   // respring: sysctl 枚举进程
#import <signal.h>       // respring: kill(SIGTERM)

#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>

#import "RPVDiagnostics.h"
#include <notify.h>       // profiledaemon IPC: notify_post / notify_register_dispatch

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

#pragma mark - 诊断转发（给 App 日志页）

NSString *const RPVDiagnosticNotification = @"com.reprovision.diagnostic";

/// 既保留系统日志输出，又通过通知把诊断送进 LogManager（App「日志」页）。
void RPVDiagnostic(RPVDiagLevel level, NSString *source, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // 原行为：打到系统日志（接电脑时能在控制台看到）。
    NSLog(@"*** [ReProvision-Diag] %@: %@", source ?: @"?", message);

    // 新增：转发给 App 日志页，用户无需电脑即可导出。
    NSDictionary *userInfo = @{
        @"source": (source ?: @"Vendor"),
        @"message": message,
        @"level": @(level),
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:RPVDiagnosticNotification
                                                        object:nil
                                                      userInfo:userInfo];
}

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

/// 已保存的密码（登录前预填用；未登录为 nil）。
/// 注意：存储的是 Apple 返回的 gsToken 而非明文 Apple ID 密码，
/// 原版 ReProvision 的自动登录正是复用这个值，因此预填它即可直接重登。
- (NSString *)savedPassword {
    NSString *value = [RPVResources getPassword];
    return value.length > 0 ? value : nil;
}

- (BOOL)isSignedIn {
    return [RPVResources getUsername].length > 0
        && [RPVResources getPassword].length > 0
        && [RPVResources getTeamID].length > 0;
}

+ (void)migrateKeychainAccessibility {
    [RPVResources migrateKeychainAccessibility];
}

+ (NSString *)currentMachineIdentifier {
    // 与 EEProvisioning 的 _identifierForCurrentMachine 同源（jp.soh.reprovision / uuid），
    // 走 RPVResources 以便锁屏时回退本地缓存，避免读不到导致误判。
    NSString *uuid = [RPVResources provisioningValueForAccount:@"uuid"];
    return uuid.length > 0 ? uuid : nil;
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

- (void)fetchOtherAppsWithCompletion:(void (^)(NSArray<RPVAppInfo *> *, NSError *_Nullable))completion {
    dispatch_async(self.workQueue, ^{
        NSString *teamID = [RPVResources getTeamID];

        // 未登录时无法区分"其他应用"，返回空
        if (teamID.length == 0) {
            RPVBridgeCallOnMain(^{
                if (completion) completion(@[], nil);
            });
            return;
        }

        NSArray *applications = [[RPVApplicationDatabase sharedInstance] getAllSideloadedApplicationsNotMatchingTeamID:teamID];

        NSMutableArray<RPVAppInfo *> *results = [NSMutableArray arrayWithCapacity:applications.count];
        for (RPVApplication *application in applications) {
            RPVAppInfo *info = [RPVBridge _infoFromApplication:application];
            if (info.bundleIdentifier.length > 0) {
                // 从 embedded.mobileprovision 提取原始签名者的 Team ID
                NSString *appPath = [[application locationOfApplicationOnFilesystem] path];
                if (appPath) {
                    NSString *provPath = [appPath stringByAppendingString:@"/embedded.mobileprovision"];
                    NSDictionary *plist = [RPVApplication provisioningProfileAtPath:provPath];
                    // v1.1.159：TeamIdentifier 类型不可信（正常是 NSArray，异常时可能是
                    // NSString/NSDictionary），强转后调用 firstObject 会 unrecognized selector 闪退。
                    NSArray *teamIds = [plist[@"TeamIdentifier"] isKindOfClass:[NSArray class]]
                        ? plist[@"TeamIdentifier"] : nil;
                    info.originalTeamID = [teamIds firstObject] ?: @"未知";
                }
                [results addObject:info];
            }
        }

        // 按到期时间升序排列
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

- (void)resignAllApplicationsWithCompletion:(void (^)(NSError *_Nullable))completion {
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
        // resignApplications:NO → 不按阈值过滤，重签所有已安装的应用
        [[RPVApplicationSigning sharedInstance] resignApplications:NO
                                            thresholdForExpiration:0
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

#pragma mark - 导入前扩展检测 / 选项透传

+ (BOOL)ipaContainsExtensionsAtURL:(NSURL *)url {
    if (!url || ![url isFileURL]) return NO;

    // security-scoped 的 URL 必须先 startAccessing… 才能读取其磁盘内容。
    BOOL scoped = [url startAccessingSecurityScopedResource];

    // RPVIpaBundleApplication._loadFileWithFormat: 只会展开单个 "*" 通配目录，
    // 故用 "Payload/*/PlugIns/*/Info.plist" 来探测 PlugIns 下的任意子 bundle。
    // 只抽取匹配到的那一个 Info.plist（SSZipArchive delegate 对非匹配项返回 NO），开销很小。
    RPVIpaBundleApplication *detector = [[RPVIpaBundleApplication alloc] init];
    NSData *data = [detector _loadFileWithFormat:@"Payload/*/PlugIns/*/Info.plist"
                                         fromIPA:url
                       multipleCandiateChooser:^NSString *(NSArray *candidates) {
                           return [candidates firstObject];
                       }];

    if (scoped) [url stopAccessingSecurityScopedResource];

    return data != nil && data.length > 0;
}

+ (void)setExtensionImportOptionsRemoveExtensions:(BOOL)remove
                       useMainProfileForExtensions:(BOOL)useMain {
    // 透传给 EEBackend 的静态开关；signBundleAtPath 入口读入后立即清零，
    // 因此只影响紧随其后的那一次导入签名。
    [EEBackend setExtensionImportOptionsRemoveExtensions:remove useMainProfileForExtensions:useMain];
}

#pragma mark - 越狱联网修复（国行蜂窝/WiFi 权限重置，手动入口）

/// 设置里「修复当前插件联网」按钮调用：同步拉起 repro-helper fix-cellular（CoreTelephony 路径），
/// 只把当前插件（ReSign）自身的蜂窝/WiFi 数据策略重置为「始终允许」，刷新偏好缓存（killall cfprefsd）生效。
/// 仅手动触发，无 daemon 自动循环。
- (void)fixCellularDataWithCompletion:(void (^)(BOOL success, NSString *_Nullable message))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *helperPath = RPVResolvedRootHelperPath();
        if (helperPath.length == 0) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, @"未找到 repro-helper（root 助手），无法执行修复");
                });
            }
            return;
        }

        // 把 ReSign 自身的 bundle id 传给 helper：v1.1.146 起 helper 只修复这一个应用
        // （不再枚举批量处理，避免对系统守护调 CoreTelephony 私有 API 污染 CT 状态）。
        NSString *selfBid = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.reprovision.repro";
        BOOL ok = RPVRunRootHelper(helperPath, @[@"fix-cellular", selfBid]);
        NSString *message = ok
            ? @"已修复当前插件联网"
            : @"修复失败，请稍后重试。";
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, message);
            });
        }
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

BOOL RPVIsRootHideEnvironment(void) {
    return RPVResolvedRootHideRoot() != nil;
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
        RPVDiagnostic(RPVDiagError, @"repro-helper", @"repro-helper 启动失败: %d (%@)", spawnRC, helperPath);
        [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
        return NO;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

    NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

    RPVDiagnostic(exitCode == 0 ? RPVDiagInfo : RPVDiagError,
                  @"repro-helper",
                  @"repro-helper %@ exit=%d\n%@",
                  [arguments componentsJoinedByString:@" "], exitCode, log.length ? log : @"(无输出)");

    return exitCode == 0;
}

// 描述文件安装已对齐 test2：统一走 App 进程内 MCProfileConnection（见
// RPVApplicationSigning._registerProvisioningProfileAtPath:），不再需要 notify/daemon IPC。

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
/// 通过 notify(3) + 共享路径触发 repro-profiledaemon（LaunchDaemon）安装描述文件。
///
/// v1.1.171 实测更正：App 与 daemon 其实都运行在真实 rootfs 域，
/// /var/mobile/Library/RePro 是同一个真实目录，IPC 完全可靠。
/// 之所以仍必须由 daemon 落盘，是因为写 /var/Managed Preferences/mobile
/// 需要 root，而 App 是 uid 501 且受沙盒约束。
/// App 把描述文件数据写入 /var/mobile/Library/RePro/，发 notify 信号，
/// 再轮询结果文件（最多 60 秒）。

/// 尽力把短命的 profiledaemon 拉起来（best-effort）。
///
/// 🔴 v1.1.171 真机实测：真实 rootfs 的 /bin 只有 df、ps，/sbin 只有 launchd，
///    系统里压根没有 launchctl —— 只有越狱 bootstrap（jbroot）里才有一份。
///    所以这里 spawn 成功与否都不能当作前提，真正的保底是 daemon plist 里的
///    LaunchEvents(com.apple.notifyd.matching)：只要 notify_post，launchd 自己会拉起。
///    这个函数只是让唤醒更快一点（省掉 notifyd 事件流的调度延迟）。
static void RPVKickstartProfileDaemon(void) {
    // roothide 把 jbroot 下的 LaunchDaemons 加载在 user/501 域（真机 launchctl print 已确认），
    // rootless/rootful 则在 system 域，两个都试一次。
    static const char *kLaunchctlPaths[] = { "/bin/launchctl", "/usr/bin/launchctl" };
    static const char *kDomains[] = { "user/501/jp.soh.reprovision.profiledaemon",
                                      "system/jp.soh.reprovision.profiledaemon" };

    for (int p = 0; p < 2; p++) {
        for (int d = 0; d < 2; d++) {
            pid_t kp = 0;
            const char *argv[] = { kLaunchctlPaths[p], "kickstart", "-k", kDomains[d], NULL };
            if (posix_spawn(&kp, kLaunchctlPaths[p], NULL, NULL,
                            (char *const *)argv, NULL) != 0) {
                break; // 这个 launchctl 路径不存在，换下一个
            }
            int st = 0;
            if (waitpid(kp, &st, 0) == kp && WIFEXITED(st) && WEXITSTATUS(st) == 0) {
                return; // 拉起成功
            }
        }
    }
}

static BOOL RPVTriggerProfileDaemon(NSString *profilePath) {
    if (profilePath.length == 0) return NO;

    static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
    static NSString *const kProfileData = @"/var/mobile/Library/RePro/profile-to-install.mobileprovision";
    static NSString *const kResultPath  = @"/var/mobile/Library/RePro/profile-install-result";

    // 确保共享目录存在（App 是 mobile，/var/mobile 下真实可读写）。
    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // 把描述文件数据写到真实共享路径（daemon 在真实上下文读得到）。
    NSData *profileData = [NSData dataWithContentsOfFile:profilePath];
    if (profileData.length == 0) {
        RPVDiagnostic(RPVDiagError, @"profiledaemon", @"读取描述文件失败: %@", profilePath);
        return NO;
    }
    NSError *writeErr = nil;
    if (![profileData writeToFile:kProfileData options:NSDataWritingAtomic error:&writeErr]) {
        RPVDiagnostic(RPVDiagError, @"profiledaemon", @"写共享描述文件失败: %@", writeErr);
        return NO;
    }

    [[NSFileManager defaultManager] removeItemAtPath:kResultPath error:nil];

    // v1.1.170：profiledaemon 已去 KeepAlive（iOS 17 短命化），不再常驻。
    // v1.1.171：kickstart 只是加速，真正保底的是 plist 里的 notifyd LaunchEvents。
    RPVKickstartProfileDaemon();

    // 发 notify 信号
    uint32_t status = notify_post("com.reprovision.profile-install-request");
    if (status != NOTIFY_STATUS_OK) {
        RPVDiagnostic(RPVDiagError, @"profiledaemon", @"notify_post 失败: 0x%x", status);
        return NO;
    }
    RPVDiagnostic(RPVDiagInfo, @"profiledaemon", @"已触发 profiledaemon (notify 已发)，等待结果...");

    // 轮询结果文件（最多等 60 秒）。
    // v1.1.171：daemon 启动时会先做一次全量清理（解析目录内每个 .mobileprovision，
    // 真机上曾有 163 个文件），首次唤醒可能十几秒才轮到安装，15 秒明显不够。
    for (int i = 0; i < 600; i++) {
        usleep(100000); // 100ms
        NSString *result = [NSString stringWithContentsOfFile:kResultPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
        if (result.length > 0) {
            result = [result stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            BOOL ok = [result hasPrefix:@"OK"];
            RPVDiagnostic(ok ? RPVDiagInfo : RPVDiagError,
                          @"profiledaemon",
                          @"repro-profiledaemon 结果: %@ (耗时 %.1fs)",
                          result, (i + 1) * 0.1);
            [[NSFileManager defaultManager] removeItemAtPath:kResultPath error:nil];
            return ok;
        }
    }

    RPVDiagnostic(RPVDiagError, @"profiledaemon",
                  @"repro-profiledaemon 60 秒内未返回结果（daemon 可能未运行或未加载）");
    return NO;
}

#pragma mark - 系统描述文件管理（v1.1.171）

static NSString *const kRPVProfileIpcDir        = @"/var/mobile/Library/RePro";
static NSString *const kRPVInventoryPath        = @"/var/mobile/Library/RePro/profiles-inventory.plist";
static NSString *const kRPVDeleteRequestPath    = @"/var/mobile/Library/RePro/profile-delete-request";
static NSString *const kRPVCleanupRequestPath   = @"/var/mobile/Library/RePro/profile-cleanup-request";
static NSString *const kRPVManageResultPath     = @"/var/mobile/Library/RePro/profile-manage-result";
static NSString *const kRPVManageNotifyName     = @"com.reprovision.profile-manage-request";

/// rootless / rootful 分支：没有 repro-profiledaemon（它只装在 RootHide 包里），
/// 直接同步拉起 setuid root 的 repro-helper 做同样的事。helper 与 daemon 调的是
/// RPVProfileStore.h 里同一份实现，结果也写到同一个 result 文件，行为完全一致。
/// 返回结果串；纯刷新返回 @""；失败返回 nil。
static NSString *RPVRunProfileManageViaHelper(NSArray<NSString *> *deleteNames, BOOL cleanup) {
    NSString *helperPath = RPVResolvedRootHelperPath();
    if (helperPath.length == 0) {
        RPVDiagnostic(RPVDiagError, @"profiles", @"未找到 repro-helper，无法管理描述文件");
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kRPVProfileIpcDir
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:kRPVManageResultPath error:nil];

    BOOL hasWork = NO;
    BOOL ok = YES;

    if (deleteNames.count > 0) {
        // 文件名清单写到 App 自己的 tmp（helper 是 root，读得到）
        NSString *listPath = [NSTemporaryDirectory()
                              stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"repro-profile-delete_%@.txt",
                               [[NSUUID UUID] UUIDString]]];
        NSString *body = [deleteNames componentsJoinedByString:@"\n"];
        if ([body writeToFile:listPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            ok = RPVRunRootHelper(helperPath, @[@"profiles-delete", listPath]);
            hasWork = YES;
            [fm removeItemAtPath:listPath error:nil];
        } else {
            ok = NO;
        }
    }

    if (ok && cleanup) {
        ok = RPVRunRootHelper(helperPath, @[@"profiles-cleanup"]);
        hasWork = YES;
    }

    // 无论做没做事，最后都刷新一次清单，保证 UI 拿到的是最新状态
    BOOL invOK = RPVRunRootHelper(helperPath, @[@"profiles-inventory", kRPVInventoryPath]);
    if (!ok || !invOK) return nil;

    if (!hasWork) return @"";

    NSString *result = [NSString stringWithContentsOfFile:kRPVManageResultPath
                                                 encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:kRPVManageResultPath error:nil];
    return result.length ? [result stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         : @"";
}

/// 投递一次管理请求并等待 daemon 处理完成。
/// deleteNames 非空 → 删除指定文件；cleanup=YES → 过期+重复清理；两者都空 → 仅刷新清单。
/// 返回 daemon 回写的结果串；纯刷新时返回 @"" 表示清单已更新；超时返回 nil。
static NSString *RPVRunProfileManageRequest(NSArray<NSString *> *deleteNames, BOOL cleanup) {
    // 🔴 只有 RootHide 才需要绕 daemon：那里 App 进程在 jbroot namespace 内，
    // 直接（或经 helper）访问 /var/Managed Preferences/mobile 会被 overlay 重定向到假目录，
    // 必须由 rootfs LaunchDaemon 代劳。rootless/rootful 没有这层隔离，helper 同步做完更快。
    if (!RPVIsRootHideEnvironment()) {
        return RPVRunProfileManageViaHelper(deleteNames, cleanup);
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kRPVProfileIpcDir
  withIntermediateDirectories:YES attributes:nil error:nil];

    // 记录清单原有时间戳，用于「纯刷新」场景判断 daemon 是否已经处理过
    NSDate *beforeStamp = [[fm attributesOfItemAtPath:kRPVInventoryPath error:nil]
                           fileModificationDate];

    [fm removeItemAtPath:kRPVManageResultPath error:nil];

    BOOL hasWork = NO;
    if (deleteNames.count > 0) {
        NSString *body = [deleteNames componentsJoinedByString:@"\n"];
        if ([body writeToFile:kRPVDeleteRequestPath atomically:YES
                     encoding:NSUTF8StringEncoding error:nil]) {
            hasWork = YES;
        }
    }
    if (cleanup) {
        if ([@"1" writeToFile:kRPVCleanupRequestPath atomically:YES
                     encoding:NSUTF8StringEncoding error:nil]) {
            hasWork = YES;
        }
    }

    RPVKickstartProfileDaemon();
    notify_post(kRPVManageNotifyName.UTF8String);

    // 最多等 60 秒：daemon 启动时要解析目录内每个描述文件，首轮可能十几秒
    for (int i = 0; i < 600; i++) {
        usleep(100000); // 100ms

        if (hasWork) {
            NSString *result = [NSString stringWithContentsOfFile:kRPVManageResultPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
            if (result.length > 0) {
                [fm removeItemAtPath:kRPVManageResultPath error:nil];
                return [result stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        } else {
            NSDate *now = [[fm attributesOfItemAtPath:kRPVInventoryPath error:nil]
                           fileModificationDate];
            if (now && (!beforeStamp || [now compare:beforeStamp] == NSOrderedDescending)) {
                return @"";
            }
        }
    }
    return nil;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)managedProfilesInventory {
    NSData *data = [NSData dataWithContentsOfFile:kRPVInventoryPath];
    if (data.length == 0) return @[];
    id root = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListImmutable
                                                         format:nil
                                                          error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return @[];
    id list = ((NSDictionary *)root)[@"profiles"];
    if (![list isKindOfClass:[NSArray class]]) return @[];

    // 逐项做类型归一化，避免下游取值直接崩
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id item in (NSArray *)list) {
        if ([item isKindOfClass:[NSDictionary class]]) [out addObject:item];
    }
    return out;
}

+ (BOOL)refreshManagedProfilesInventory {
    return RPVRunProfileManageRequest(nil, NO) != nil;
}

+ (NSString *)requestManagedProfileCleanup {
    NSString *r = RPVRunProfileManageRequest(nil, YES);
    RPVDiagnostic(r ? RPVDiagInfo : RPVDiagError, @"profiledaemon",
                  @"描述文件清理结果: %@", r ?: @"超时未返回");
    return r;
}

+ (NSString *)requestManagedProfileDeletion:(NSArray<NSString *> *)fileNames {
    if (fileNames.count == 0) return nil;
    NSString *r = RPVRunProfileManageRequest(fileNames, NO);
    RPVDiagnostic(r ? RPVDiagInfo : RPVDiagError, @"profiledaemon",
                  @"描述文件删除结果: %@", r ?: @"超时未返回");
    return r;
}

/// rootful 环境下本来就能写成功。
+ (void)installRootHelperHandlers {
    NSString *helperPath = RPVResolvedRootHelperPath();
    if (helperPath.length == 0) {
        RPVDiagnostic(RPVDiagWarning, @"repro-helper", @"未找到 repro-helper，需要 root 的操作将由 App 自己尝试");
        return;
    }

    RPVDiagnostic(RPVDiagInfo, @"repro-helper", @"已挂载 root helper: %@", helperPath);

    // 1) 从「文件」App 的安全域读不到 IPA 时，把文件搬到 App 能读到的位置。
    //    🔴 v1.1.157：repro-importdaemon 已删除（RootHide 下 iCloud 导入场景实际
    //    无人使用，App 及其 posix_spawn 出的 helper 在 overlay 内本就拷不了 iCloud），
    //    文件拷贝兜底统一走 repro-helper（setuid root）。
    [RPVIpaBundleApplication setDaemonFileCopyHandler:^BOOL(NSString *srcPath, NSString *dstPath) {
        if (srcPath.length == 0 || dstPath.length == 0) return NO;
        return RPVRunRootHelper(helperPath, @[@"copy", srcPath, dstPath]);
    }];

    // 2) 描述文件安装：
    //    RootHide：/var/Managed Preferences/mobile 需要 root 才能写，App 是 uid 501
    //             且受沙盒约束，直接写不可靠 → 交给 LaunchDaemon（repro-profiledaemon），
    //             由 launchd 以 root 拉起，负责落盘 + MC 注册 + 通知 profiled 重扫 +
    //             按 App ID 去重清理。App 经 notify IPC 触发（RPVTriggerProfileDaemon）。
    //    非 RootHide（rootless/rootful）：对齐 test2，纯 App MC 即可（无 namespace 隔离）。
    if (RPVIsRootHideEnvironment()) {
        [RPVApplicationSigning setDaemonProfileInstallHandler:^BOOL(NSString *profilePath) {
            if (profilePath.length == 0) return NO;
            return RPVTriggerProfileDaemon(profilePath);
        }];
    } else {
        [RPVApplicationSigning setDaemonProfileInstallHandler:^BOOL(NSString *profilePath) {
            if (profilePath.length == 0) return NO;
            return RPVRunRootHelper(helperPath, @[@"install-profile", profilePath]);
        }];
    }
}

- (void)fetchAppIDsWithCompletion:(void (^)(NSArray<RPVRegisteredAppID *> *_Nullable, NSError *_Nullable))completion {
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

                // v1.1.159：Apple 响应结构不可信（代理返回 HTML、会话过期等会让 appIds
                // 缺失或变成其它类型），for-in 快速枚举非 NSArray 会
                // countByEnumeratingWithState: unrecognized selector 闪退。
                NSArray *rawApps = [dict[@"appIds"] isKindOfClass:[NSArray class]] ? dict[@"appIds"] : nil;
                NSMutableArray<RPVRegisteredAppID *> *result = [NSMutableArray array];
                for (NSDictionary *appDict in rawApps) {
                    if (![appDict isKindOfClass:[NSDictionary class]]) continue;
                    RPVRegisteredAppID *appId = [[RPVRegisteredAppID alloc] initWithDictionary:appDict];
                    [result addObject:appId];
                }

                // 按过期时间升序排列（nil 日期排最后，避免 [NSDate compare:nil] 崩溃）
                [result sortUsingComparator:^NSComparisonResult(RPVRegisteredAppID *a, RPVRegisteredAppID *b) {
                    NSDate *da = a.applicationExpiryDate, *db = b.applicationExpiryDate;
                    if (!da && !db) return NSOrderedSame;
                    if (!da) return NSOrderedDescending; // 无日期的排最后
                    if (!db) return NSOrderedAscending;
                    return [da compare:db];
                }];

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

                // v1.1.159：同 fetchAppIDs —— data 缺失/非数组时快速枚举会闪退。
                NSArray *dataArray = [dict[@"data"] isKindOfClass:[NSArray class]] ? dict[@"data"] : nil;
                NSMutableArray<RPVCertificateInfo *> *result = [NSMutableArray array];
                for (NSDictionary *certDict in dataArray) {
                    if (![certDict isKindOfClass:[NSDictionary class]]) continue;
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

// MARK: - Respring（sysctl 枚举进程方案）
//
// 参考 RebootTools / TrollStore TSUtil.m：
//   通过 sysctl(KERN_PROC_ALL) 获取所有进程列表，
//   用 KERN_PROCARGS2 取出每个进程的 executable path，
//   匹配 "SpringBoard" 后直接 kill(pid, SIGTERM)。
// 不依赖 killall / sbreload / notify_post 等任何外部二进制或 API。

- (BOOL)respring {
    // 1. 获取 KERN_ARGMAX
    int maxArgumentSize = 0;
    size_t size = sizeof(maxArgumentSize);
    if (sysctl((int[]){ CTL_KERN, KERN_ARGMAX }, 2, &maxArgumentSize, &size, NULL, 0) == -1) {
        maxArgumentSize = 4096; // 默认值
    }

    // 2. 枚举所有进程（KERN_PROC_ALL）
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    struct kinfo_proc *info = NULL;
    size_t length = 0;

    if (sysctl(mib, 3, NULL, &length, NULL, 0) < 0) return NO;
    if (!(info = malloc(length))) return NO;
    if (sysctl(mib, 3, info, &length, NULL, 0) < 0) {
        free(info);
        return NO;
    }

    int count = (int)(length / sizeof(struct kinfo_proc));
    BOOL found = NO;

    for (int i = 0; i < count; i++) {
        pid_t pid = info[i].kp_proc.p_pid;
        if (pid == 0) continue;

        size_t argSize = maxArgumentSize;
        char *buffer = malloc(maxArgumentSize);
        if (!buffer) continue;

        if (sysctl((int[]){ CTL_KERN, KERN_PROCARGS2, pid }, 3, buffer, &argSize, NULL, 0) == 0) {
            // KERN_PROCARGS2: 前 sizeof(int) 是 argc，之后是 executable path（以 \0 结尾）
            NSString *executablePath = [NSString stringWithUTF8String:(buffer + sizeof(int))];
            if ([executablePath.lastPathComponent isEqualToString:@"SpringBoard"]) {
                kill(pid, SIGTERM);
                found = YES;
                free(buffer);
                break; // 找到一个就够了
            }
        }
        free(buffer);
    }

    free(info);
    return found;
}

@end

#pragma mark - 已注册 AppID 实现

@implementation RPVRegisteredAppID

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _identifier = [dict[@"identifier"] isKindOfClass:[NSString class]] ? [dict[@"identifier"] copy] : @"";
        _applicationName = [dict[@"name"] isKindOfClass:[NSString class]] ? [dict[@"name"] copy] : _identifier;

        // ⚠️ Apple 的 listAppIds.action 通过 NSPropertyListSerialization 反序列化，
        //   <date> 节点会变成 NSDate 对象（不是 NSString！）。
        //   对 NSDate 调用 -length 会触发 unrecognized selector → 闪退（用户实机已验证）。
        //   必须用 isKindOfClass 做类型自适应。
        id expiry = dict[@"expirationDate"];
        if ([expiry isKindOfClass:[NSDate class]]) {
            // plist 反序列化的 <date> → 直接使用
            _applicationExpiryDate = expiry;
        } else if ([expiry isKindOfClass:[NSNumber class]]) {
            // Unix 时间戳（数字格式）
            double ts = [expiry doubleValue];
            if (ts > 0) _applicationExpiryDate = [NSDate dateWithTimeIntervalSince1970:ts];
        } else if ([expiry isKindOfClass:[NSString class]] && [(NSString *)expiry length] > 0) {
            // ISO 8601 字符串（罕见但兼容）
            double ts = [(NSString *)expiry doubleValue];
            if (ts > 0) {
                _applicationExpiryDate = [NSDate dateWithTimeIntervalSince1970:ts];
            } else {
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
                _applicationExpiryDate = [fmt dateFromString:(NSString *)expiry];
            }
        }
        // else: nil / NSNull → _applicationExpiryDate 保持 nil
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

        // v1.1.159：attributes 缺失/非字典时强转调用下标会 unrecognized selector 闪退
        // （Apple 证书列表字段结构异常时实测过崩溃）。
        NSDictionary *attrs = [dict[@"attributes"] isKindOfClass:[NSDictionary class]]
            ? dict[@"attributes"] : nil;
        _machineName = [attrs[@"machineName"] copy] ?: @"Unknown";

        // machineId：与本机 uuid 比对可判定这张证书是不是本机签发的。
        // Apple 返回的字段可能是 NSNull，需要显式过滤。
        id rawMachineId = attrs[@"machineId"];
        _machineId = ([rawMachineId isKindOfClass:[NSString class]] ? [rawMachineId copy] : @"");

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
