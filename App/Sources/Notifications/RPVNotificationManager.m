//
//  RPVNotificationManager.m
//  RePro
//
//  见 RPVNotificationManager.h 顶部的移植说明。
//

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

#import "HookUtil.h"
#import "RPVNotificationManager.h"
#import "RPVDiagnostics.h"

NSString *const RPVNotificationsEnabledKey = @"notificationsEnabled";
NSString *const RPVNotificationsDebugKey   = @"notificationsDebug";

#pragma mark - RootHide 授权持久化关键 Hook
//
// 原版注释写的是「Fix for crashing when using stashing」，但它在 RootHide 下
// 的真正意义是把 bundle id 钉回真实值：
//
//   UNUserNotificationCenter 在内部初始化时会带一个 bundleIdentifier 去问系统
//   要授权记录。RootHide 用随机 jbroot + 完整 namespace 隔离，这个 bundleID
//   可能为 nil 或被翻译过，导致授权落进 jbroot overlay 的 TCC —— overlay 不保证
//   持久，App 杀掉重开后系统认为「从未授权」，于是再次弹窗。
//
//   这里强制回落到 [[NSBundle mainBundle] bundleIdentifier]（真实 bundle id），
//   授权请求便打到真实分区，一次授权长期有效。
//
// HOOK_MESSAGE 由 HookUtil.h 提供，__attribute__((constructor)) 在 main() 之前
// 自动安装，无需手工调用。方法名里的 '_' 代表 ':'。
//
HOOK_MESSAGE(id, UNUserNotificationCenter, initWithBundleIdentifier_, NSString *bundleID) {
    if (!bundleID) {
        bundleID = [[NSBundle mainBundle] bundleIdentifier];
    }

    id result;
    @try {
        result = _UNUserNotificationCenter_initWithBundleIdentifier_(self, sel, bundleID);
    } @catch (NSException *e) {
        result = _UNUserNotificationCenter_initWithBundleIdentifier_(self, sel, [[NSBundle mainBundle] bundleIdentifier]);
    }

    return result;
}

#pragma mark -

@implementation RPVNotificationManager

+ (instancetype)sharedInstance {
    static RPVNotificationManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[RPVNotificationManager alloc] init];
    });
    return sharedInstance;
}

#pragma mark - 开关

/// 未写过的键按默认值处理，不用 boolForKey 的「缺省即 NO」语义
+ (BOOL)_boolForKey:(NSString *)key defaultValue:(BOOL)fallback {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id value = [defaults objectForKey:key];
    return value ? [value boolValue] : fallback;
}

#pragma mark - 授权

- (void)registerToSendNotifications {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;

    // 与原版保持一致：只申请横幅，不要角标和声音。
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                          completionHandler:^(BOOL granted, NSError *_Nullable error) {
        if (error) {
            RPVDiagnostic(RPVDiagWarning, @"通知", @"申请通知权限出错: %@", error.localizedDescription);
        } else if (!granted) {
            RPVDiagnostic(RPVDiagWarning, @"通知", @"用户未授予通知权限，续签结果将不会以横幅提示");
        } else {
            RPVDiagnostic(RPVDiagInfo, @"通知", @"通知权限已授予");
        }
    }];
}

- (void)fetchAuthorizationStatus:(void (^)(NSInteger status))completion {
    if (!completion) return;

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        NSInteger status = (NSInteger)settings.authorizationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(status);
        });
    }];
}

#pragma mark - 发送

- (void)sendNotificationWithTitle:(NSString *)title
                             body:(NSString *)body
                   isDebugMessage:(BOOL)isDebug
                andNotificationID:(NSString *_Nullable)identifier {

    if (![[self class] _boolForKey:RPVNotificationsEnabledKey defaultValue:YES]) {
        return;
    }
    if (isDebug && ![[self class] _boolForKey:RPVNotificationsDebugKey defaultValue:NO]) {
        return;
    }

    if (!identifier) {
        identifier = [NSString stringWithFormat:@"repro_%f", [[NSDate date] timeIntervalSince1970]];
    }

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title ?: @"RePro";
    content.body  = body ?: @"";
    content.sound = nil;

    // 与原版一致：1 秒后触发，不重复。立即触发在部分系统版本上会被丢弃。
    UNTimeIntervalNotificationTrigger *trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO];

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:trigger];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center addNotificationRequest:request withCompletionHandler:^(NSError *_Nullable error) {
        if (error) {
            RPVDiagnostic(RPVDiagWarning, @"通知", @"发送通知失败: %@", error.localizedDescription);
        }
    }];
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    // App 在前台时同样弹横幅，否则续签过程中用户看不到任何反馈。
    completionHandler(UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    // RePro 的通知点击后只需要打开 App 本身，无额外跳转。
    completionHandler();
}

@end
