//
//  RPVSigningdNotify.m
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//
//  复刻原 ReProvision-Reborn 的 notify + XPC 通信模式：
//  - Daemon 通过 NSTimer 定时检查，触发时 notify_post("com.reprovision.schedule-resign")
//  - App 收到后通过共享文件确认是否有待处理的续签请求
//  - App 在前台时直接触发续签，不在前台时等下次 didBecomeActive 检查
//  - 续签完成后 App 直接发 UNUserNotificationCenter 通知 + notify daemon 完成
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
    // 监听 daemon 的续签触发信号
    notify_register_dispatch("com.reprovision.schedule-resign",
        &_token,
        dispatch_get_main_queue(),
        ^(int unused) {
            NSLog(@"[RePro] 收到 repro-signingd 的 notify，检查自动续签");

            // 读共享配置确认自动续签仍开启
            NSString *configPath = @"/var/mobile/Library/RePro/signingd-config.plist";
            NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:configPath];
            BOOL autoResign = cfg ? [cfg[@"autoResign"] boolValue] : YES;
            if (!autoResign) {
                NSLog(@"[RePro] 自动续签已关闭，跳过");
                return;
            }

            // App 在前台时直接触发自动续签
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                NSLog(@"[RePro] App 在前台，直接触发自动续签");
                // 写时间戳让 didBecomeActive 能读到
                NSString *ts = [NSString stringWithFormat:@"%lld", (long long)time(NULL)];
                [ts writeToFile:@"/var/mobile/Library/RePro/auto-resign-request"
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"com.reprovision.signingd-foreground-resign"
                                          object:nil];
                    });
            }
        });
}

+ (void)notifyConfigUpdated {
    notify_post("com.reprovision.signingd-config-updated");
}

+ (void)notifySigningComplete {
    notify_post("com.reprovision.signing-complete");
}

- (void)dealloc {
    if (_token > 0) notify_cancel(_token);
}

@end
