//
//  RPVSigningdNotify.m
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//
//  repro-signingd 定时检查是否需要续签，触发时 notify_post("com.reprovision.schedule-resign")。
//  本类用 notify_register_dispatch 监听该信号，转发给 AppDelegate 执行自动续签。
//

#include <notify.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface RPVSigningdNotify : NSObject
+ (instancetype)shared;
@end

@implementation RPVSigningdNotify {
    int _token;
}

+ (instancetype)shared {
    static RPVSigningdNotify *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
        [instance setup];
    });
    return instance;
}

- (void)setup {
    notify_register_dispatch("com.reprovision.schedule-resign",
        &_token,
        dispatch_get_main_queue(),
        ^(int unused) {
            NSLog(@"[ReSign] 收到 repro-signingd 续签信号");

            // 读共享配置确认自动续签仍开启
            NSString *configPath = @"/var/mobile/Library/RePro/signingd-config.plist";
            NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:configPath];
            if (cfg && ![cfg[@"autoResign"] boolValue]) {
                NSLog(@"[ReSign] 自动续签已关闭，跳过");
                return;
            }

            // App 在前台时直接触发
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                NSLog(@"[ReSign] App 在前台，直接触发自动续签");

                NSString *ts = [NSString stringWithFormat:@"%lld", (long long)time(NULL)];
                NSString *triggerPath = @"/var/mobile/Library/RePro/auto-resign-trigger";
                NSDictionary *trigger = @{@"timestamp": @(time(NULL)), @"threshold": @(2)};
                [trigger writeToFile:triggerPath atomically:YES];

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"com.reprovision.signingd-foreground-resign"
                                          object:nil];
                    });
            }
            // App 不在前台 → notify 被忽略，但请求文件已由 daemon 写入，
            // App 下次 didBecomeActive 时检查并执行续签。
        });
}

+ (void)notifyConfigUpdated {
    notify_post("com.reprovision.signingd-config-updated");
}

+ (void)notifySigningComplete {
    notify_post("com.reprovision.signing-complete");
}

+ (void)notifyFixCellularRequest {
    uint32_t status = notify_post("com.reprovision.fix-cellular-request");
    if (status != 0) {
        NSLog(@"[ReSign] 请求 daemon 修复联网失败: notify_post 0x%x", status);
    }
}

+ (void)notifyBypass3AppRequest {
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"bypassFreeAppLimit"];
    if (!enabled) {
        // 开关关着：直接说明，避免用户去日志里找不到任何痕迹
        NSLog(@"[ReSign] 3 应用绕过未启用（设置 → 免费账号限制 → 「自动绕过 3 应用限制」开关为关闭），跳过请求 daemon");
        return;
    }
    uint32_t status = notify_post("com.reprovision.bypass-3app-request");
    if (status != 0) {
        NSLog(@"[ReSign] 请求 3 应用绕过失败: notify_post 0x%x", status);
    } else {
        NSLog(@"[ReSign] 已向 repro-signingd 发送 3 应用绕过请求（daemon 约 2 秒后执行，详见 daemon 日志 reprorefresh_at.log）");
    }
}

- (void)dealloc {
    if (_token > 0) notify_cancel(_token);
}

@end
