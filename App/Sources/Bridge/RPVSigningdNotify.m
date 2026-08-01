//
//  RPVSigningdNotify.m
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//
//  repro-signingd 每小时 fire 一次 NSTimer，如果自动续签已开启，
//  就 notify_post("com.reprovision.schedule-resign") 通知 App。
//  本类用 notify_register_dispatch 监听这个信号：
//    - App 在前台时直接跑自动续签
//    - App 不在前台时信号被忽略，但下次 didBecomeActive 会检查
//      /var/mobile/Library/RePro/auto-resign-request 发现
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
            NSLog(@"[RePro] 收到 repro-signingd 的 notify，检查自动续签");
            // 读共享 plist 确认自动续签仍开启
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
                // 走 AppDelegate 的逻辑（通过检查 request 文件触发）
                // 简单方式：写一个时间戳到共享路径让 didBecomeActive 能读到
                NSString *ts = [NSString stringWithFormat:@"%lld", (long long)time(NULL)];
                [ts writeToFile:@"/var/mobile/Library/RePro/auto-resign-request"
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];
                // 模拟 didBecomeActive 检查
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"com.reprovision.signingd-foreground-resign"
                                          object:nil];
                    });
            }
        });
}

- (void)dealloc {
    if (_token > 0) notify_cancel(_token);
}

@end
