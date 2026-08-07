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
#import <dlfcn.h>

@interface RPVSigningdNotify : NSObject
+ (instancetype)shared;
/// v2.1.3：App 进程生成完整 Anisette 缓存，供 daemon 复用
+ (void)refreshAnisetteCache;
@end

// v2.1.3：AuthKit 私有类声明（动态取类时编译器需要 selector 签名，与 DaemonStubs.m 一致）
@interface AKAppleIDSession : NSObject
- (id)initWithIdentifier:(id)arg1;
- (id)appleIDHeadersForRequest:(id)arg1;
@end

// v2.1.15：LSApplicationWorkspace 安装签名后的 app。
// RootHide 下 daemon（root、无 UI 会话）调 installApplication 被 installd 拒
// （"Operation not permitted"，真机 23:12 实锤）；App 进程有 UI 会话能装
// （v1.x 时代 App 侧安装一直成功）。daemon 签名 → 写 pending-install 标记 →
// 唤醒 App 后台 → 本方法执行安装 → 写结果。
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
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

// 🔴 v2.1.3：Anisette 缓存刷新。
// 背景：daemon（root、无 App 沙盒上下文）进程里 AKAppleIDSession 生成的 Anisette
// 缺 X-Apple-I-MD / X-Apple-I-MD-M（AuthKit machine data XPC 访问受限）→ Apple 拒绝
// 所有 developerservices2 请求（listTeams 返回无 teams → "No Team ID present!"，
// 真机 18:14/18:43 实锤）。App 进程有 AuthKit 上下文，生成的 Anisette 完整可用
// （App 登录成功即证明）。本方法把完整 headers 缓存到共享 IPC 目录，daemon 读取复用。
+ (void)refreshAnisetteCache {
    static Class AKAppleIDSession = nil;
    if (!AKAppleIDSession) {
        dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW | RTLD_GLOBAL);
        AKAppleIDSession = NSClassFromString(@"AKAppleIDSession");
    }
    NSDictionary *headers = nil;
    if (AKAppleIDSession) {
        id session = [[AKAppleIDSession alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"];
        if ([session respondsToSelector:@selector(appleIDHeadersForRequest:)]) {
            headers = [session appleIDHeadersForRequest:nil];
        }
    }
    NSMutableDictionary *cache = [headers isKindOfClass:[NSDictionary class]]
        ? [headers mutableCopy] : [NSMutableDictionary dictionary];
    // 与 RPVAuthentication.appleIDHeadersForRequest 一致的覆盖参数
    cache[@"X-Apple-App-Info"] = @"com.apple.gs.xcode.auth";
    cache[@"X-MMe-Client-Info"] =
        @"<MacBookPro11,5> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
    if ([cache[@"X-Apple-I-MD"] length] > 0 && [cache[@"X-Apple-I-MD-M"] length] > 0) {
        BOOL ok = [cache writeToFile:@"/var/mobile/Library/Resign/anisette.cache" atomically:YES];
        // 成功则清掉失败诊断文件（若存在）
        [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Resign/anisette-fail.log" error:nil];
        NSLog(@"[ReSign] Anisette 缓存已%@（X-Apple-I-MD=%lu 字符）",
              ok ? @"刷新" : @"写入失败", (unsigned long)[cache[@"X-Apple-I-MD"] length]);
    } else {
        // 🔴 生成失败：写诊断文件（unified log 在 RootHide 下读不到，落盘才能看到）
        NSMutableString *diag = [NSMutableString stringWithFormat:@"[%@] AKAppleIDSession 未生成完整 Anisette，headers keys: ",
                                 [NSDate date]];
        [diag appendString:[[cache allKeys] componentsJoinedByString:@","] ?: @"(空)"];
        [diag appendString:@"\nAKAppleIDSession 类可用: "];
        [diag appendString:(AKAppleIDSession ? @"是" : @"否")];
        [diag appendString:@"\n"];
        [diag writeToFile:@"/var/mobile/Library/Resign/anisette-fail.log"
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[ReSign] ⚠️ AKAppleIDSession 未生成完整 Anisette（缺 X-Apple-I-MD），已写诊断文件");
    }
}

+ (void)notifySigningComplete {
    notify_post("cn.analy.resign.signing-complete");
}

// 🔴 v2.1.15：执行 daemon 签名后的安装（App 进程有 UI 会话，RootHide 下才能装）。
// daemon 签名成功 → 复制签名结果到 /var/mobile/Library/Resign/pending-install/ →
// 写 pending-install.plist 标记 → 唤醒 App 后台（setupCommon 每次启动必跑本方法）。
// 安装完成写 install-result.plist 供 daemon 轮询读取，并删除 pending 标记。
+ (void)processPendingInstallIfNeeded {
    NSString *pendingPath = @"/var/mobile/Library/Resign/pending-install.plist";
    NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:pendingPath];
    NSString *bundleId = pending[@"bundleId"];
    NSString *appPath = pending[@"appPath"];
    if (bundleId.length == 0 || appPath.length == 0) return;

    NSLog(@"[ReSign] 检测到 daemon 待安装标记 → 执行安装 %@（%@）", bundleId, appPath);
    BOOL ok = NO;
    NSString *errMsg = @"";
    if (![[NSFileManager defaultManager] fileExistsAtPath:appPath]) {
        errMsg = @"签名结果不存在（可能已被清理）";
    } else {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) {
            errMsg = @"LSApplicationWorkspace 不可用";
        } else {
            id workspace = [wsClass performSelector:@selector(defaultWorkspace)];
            NSURL *appURL = [NSURL fileURLWithPath:appPath];
            NSDictionary *opts = @{
                @"CFBundleIdentifier": bundleId ?: @"",
                @"AllowInstallLocalProvisioned": @YES,
            };
            NSError *err = nil;
            @try {
                ok = [workspace installApplication:appURL withOptions:opts error:&err];
            } @catch (NSException *e) {
                errMsg = e.description ?: @"安装异常";
            }
            if (!ok && !errMsg.length) errMsg = err.localizedDescription ?: @"未知错误";
        }
    }
    NSLog(@"[ReSign] 安装结果: %@ %@", ok ? @"✅ 成功" : @"❌ 失败", ok ? @"" : errMsg);

    // 写结果供 daemon 轮询（不删 pending.plist——由 daemon 侧下一轮覆盖/清理，
    // 这里删除会导致 daemon 判断时序竞态：daemon 先删标记再读结果）
    NSDictionary *result = @{
        @"bundleId": bundleId,
        @"ok": @(ok),
        @"error": ok ? @"" : errMsg,
        @"ts": @([[NSDate date] timeIntervalSince1970]),
    };
    [result writeToFile:@"/var/mobile/Library/Resign/install-result.plist" atomically:YES];
    // 通知 daemon（虽然 daemon 在轮询，双保险）
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
