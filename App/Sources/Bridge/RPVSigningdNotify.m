//
//  RPVSigningdNotify.m
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//
//  repro-signingd 定时检查是否需要续签，触发时优先 BKS 后台拉起 App 静默续签
// （App 侧 isDaemonTriggeredResign → startDaemonResign）；拉起失败才降级
// notify_post("cn.analy.resign.schedule-resign")。
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
    notify_register_dispatch("cn.analy.resign.schedule-resign",
        &_token,
        dispatch_get_main_queue(),
        ^(int unused) {
            // 🔴 v1.1.165：不再忽略。根因：App 进程已存在时（用户打开过挂后台），daemon 的
            // SBS 后台唤醒不会重走 didFinishLaunching → App 侧 isDaemonTriggeredResign
            // 永不执行 → 续签静默失败（用户实测「触发了刷新但没自动续签」）。
            // 这里作为【进程内触发路径】：检查 daemon 本轮写的 auto-resign-trigger 是否
            // 新鲜（180s 窗口）。新鲜 → 通知 AppDelegate 走静默续签（AppDelegate 内部有
            // 24h 冷却 + 防重入）；不新鲜（trigger 已被冷启动路径消费/删除）→ 忽略，
            // 天然防双触发。
            //
            // ⚠️ v1.1.144 曾为避免「进前台就重签」的内存暴涨而整条砍掉本通道；现在触发源
            // 是 daemon 周期（24h 冷却 + 每 5 分钟最多一轮），频率完全可控，不会重蹈覆辙。
            NSDictionary *trigger = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Resign/auto-resign-trigger"];
            NSNumber *ts = trigger[@"timestamp"];
            if (ts && [[NSDate date] timeIntervalSince1970] - [ts doubleValue] < 180.0) {
                NSLog(@"[ReSign] daemon 续签信号 + trigger 新鲜 → 请求 AppDelegate 执行静默续签");
                [[NSNotificationCenter defaultCenter] postNotificationName:@"cn.analy.resign.daemon-request-resign"
                                                                    object:nil];
            } else {
                NSLog(@"[ReSign] 收到 daemon 续签信号但 trigger 缺失/已过期（可能已被冷启动路径消费），忽略");
            }
        });
}

+ (void)notifyConfigUpdated {
    notify_post("cn.analy.resign.signingd-config-updated");
}

+ (void)notifySigningComplete {
    notify_post("cn.analy.resign.signing-complete");
}

+ (void)notifyBypass3AppRequest {
    BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"bypassFreeAppLimit"];
    if (!enabled) {
        // 开关关着：直接说明，避免用户去日志里找不到任何痕迹
        NSLog(@"[ReSign] 3 应用绕过未启用（设置 → 免费账号限制 → 「自动绕过 3 应用限制」开关为关闭），跳过请求 daemon");
        return;
    }
    uint32_t status = notify_post("cn.analy.resign.bypass-3app-request");
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
