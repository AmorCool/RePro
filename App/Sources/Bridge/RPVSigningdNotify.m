//
//  RPVSigningdNotify.m
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//
//  repro-signingd 定时检查是否需要续签，触发时优先 BKS 后台拉起 App 静默续签
// （App 侧 isDaemonTriggeredResign → startDaemonResign）；拉起失败才降级
// notify_post("com.reprovision.schedule-resign")。
// 🔴 v1.1.144：收到该信号不再让前台 App 代跑重签（历史「进前台就重签」设计，
// 反复前后台切换会反复跑 zsign 导致内存暴涨 → 整机 Jetsam → roothide XPC 拦截
// fault → EXC_GUARD/LIBXPC 杀主线程闪退）。daemon 下个周期会自动重试。
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
            NSLog(@"[ReSign] 收到 repro-signingd 续签信号（daemon 后台拉起失败降级路径）→ 忽略，由 daemon 下个周期重试");
        });
}

+ (void)notifyConfigUpdated {
    notify_post("com.reprovision.signingd-config-updated");
}

+ (void)notifySigningComplete {
    notify_post("com.reprovision.signing-complete");
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
