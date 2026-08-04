//
//  RPVLocalization.h
//  iOS
//
//  Lightweight runtime localization helper for ReProvision Reborn (Rootless fork).
//
//  Usage:
//    #import "RPVLocalization.h"
//    self.title = RPVLS(@"Settings");
//    label.text  = [NSString stringWithFormat:RPVLS(@"Apple ID: %@"), name];
//
//  The English string is used as the lookup key. When the selected language is
//  Simplified Chinese (or the system language is Chinese while the preference is
//  "system"), the matching translation is returned; otherwise the English key is
//  returned unchanged. No .lproj / .strings resources are required, so this works
//  without modifying the Xcode project's resource phases.
//

#import <Foundation/Foundation.h>

// Preference key (stored in NSUserDefaults, same store RPVResources uses).
static NSString *const kRPVLanguagePreference = @"kRPVLanguage";

static inline NSDictionary *__rpvZhHansDictionary(void) {
    static NSDictionary *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dict = @{
            // ----- Sign-in / Account flow -----
            @"Sign in with your Apple ID" : @"使用你的 Apple ID 登录",
            @"Failure" : @"失败",
            @"Unknown error" : @"未知错误",
            @"Confirm" : @"确认",
            @"Email Address" : @"电子邮箱/手机号",
            @"Password" : @"密码",
            @"Next" : @"下一步",
            @"Done" : @"完成",
            @"Tap 'Continue Authentication' below to redirect to Settings" : @"请点击下方的“继续验证”以跳转到“设置”",
            @"Free accounts are only allowed up to two active certificates at any time.\n\nPlease remove an existing certificate to continue." : @"免费账户最多只能同时拥有两个有效证书。\n\n请移除一个现有证书以继续。",
            @"Checking Signing Certificates" : @"正在检查签名证书",
            @"Verifying..." : @"验证中…",
            @"Remove a Certificate" : @"移除证书",
            @"Checking Device Status" : @"正在检查设备状态",
            @"Checking Apple Watch Status" : @"正在检查 Apple Watch 状态",
            @"Storing Login Information" : @"正在存储登录信息",
            @"Working..." : @"处理中…",
            @"Finished" : @"已完成",
            @"Signed in successfully!" : @"登录成功！",
            @"Revoking Certificate" : @"正在撤销证书",
            @"Device: %@" : @"设备：%@",
            @"Application: %@" : @"应用：%@",

            // ----- Settings (main) -----
            @"Settings" : @"设置",
            @"Your password is only sent to Apple." : @"你的密码仅会发送给 Apple。",
            @"Sign Out" : @"退出登录",
            @"Sign In" : @"登录",
            @"Apple ID: %@" : @"Apple ID：%@",
            @"Automated Re-signing" : @"自动重签",
            @"Set how many days away from an application's expiration date a re-sign will occur." : @"设置应用在过期前多少天触发自动重签。",
            @"Automatically Re-sign" : @"自动重签",
            @"Re-sign Applications When:" : @"应用重签时机：",
            @"1 Day Left" : @"剩 1 天",
            @"2 Days Left" : @"剩 2 天",
            @"3 Days Left" : @"剩 3 天",
            @"4 Days Left" : @"剩 4 天",
            @"5 Days Left" : @"剩 5 天",
            @"6 Days Left" : @"剩 6 天",
            @"For example, setting \"2 Days Left\" will cause an application to be re-signed when it is 2 days away from expiring." : @"例如，选择“剩 2 天”将在应用距离过期还有 2 天时自动重签。",
            @"Notifications" : @"通知",
            @"Show Non-Urgent Alerts" : @"显示非紧急提醒",
            @"Show Debug Alerts" : @"显示调试提醒",
            @"Advanced" : @"高级",
            @"Credits" : @"致谢",
            @"Third-party Licenses" : @"第三方许可证",
            @"Developer of Reborn Version / New Icon Design" : @"Reborn 版本开发者 / 新图标设计",
            @"Developer of Original Version" : @"原版开发者",
            @"Developer of AltStore" : @"AltStore 开发者",
            @"Designer" : @"设计师",

            // ----- Language selector -----
            @"Language" : @"语言",
            @"Interface Language" : @"界面语言",
            @"Choose the display language for the interface. Changes apply here immediately; the sign-in screen updates after reopening the app." : @"选择界面显示语言。本页修改立即生效，登录页将在重新打开插件后生效。",
            @"System" : @"跟随系统",
            @"English" : @"English",
            @"Chinese (Simplified)" : @"简体中文",

            // ----- Advanced -----
            @"Re-signing" : @"重签",
            @"Set how often checks are made for if any applications are in need of re-signing." : @"设置检查应用是否需要重签的频率。",
            @"Next Fire Date: " : @"下次触发时间：",
            @"Re-sign in Low Power Mode" : @"低电量模式下重签",
            @"Force Re-sign" : @"强制重签",
            @"True Background Re-sign (Beta)" : @"真后台重签（测试版）",
            @"Check Expiry Times:" : @"过期检查间隔：",
            @"Every 1 Hour" : @"每 1 小时",
            @"Every 2 Hours" : @"每 2 小时",
            @"Every 6 Hours" : @"每 6 小时",
            @"Every 12 Hours" : @"每 12 小时",
            @"Every 24 Hours" : @"每 24 小时",
            @"Every Other Day" : @"每隔一天",
            @"A longer time between checks uses less battery, but has more risk that applications won't be re-signed before a reboot." : @"检查间隔越长越省电，但应用在重启前未能重签的风险也越高。",
            @"Debugging Tools" : @"调试工具",
            @"Danger! Here be dragons..." : @"危险！巨龙出没……",
            @"Initiate Background Signing" : @"立即开始后台签名",

            // ----- Troubleshooting -----
            @"Troubleshooting" : @"故障排查",
            @"This error usually occurs when running Extender on multiple devices with the same Apple ID.\n\nOne possible solution is to revoke developer certificates, which can be done below." : @"此错误通常出现在多台设备使用同一 Apple ID 运行 Extender 时。\n\n一种解决方法是撤销开发者证书，可在下方操作。",
            @"Revoke Certificates" : @"撤销证书",
            @"This error may occur when Extender attempts to create an IPA for an application.\n\nTo resolve, simply try again another time." : @"当 Extender 尝试为应用创建 IPA 时可能出现此错误。\n\n解决方法：稍后重试即可。",
            @"Could not extract archive" : @"无法解压归档文件",

            @"OK" : @"确定",
            @"Apple ID" : @"Apple ID",
            @"Your details are only sent to Apple." : @"你的信息仅会发送给 Apple.",

            // ----- Login / network errors (fully localized) -----
            @"Please accept the Apple Developer terms at https://developer.apple.com" : @"请先在 https://developer.apple.com 接受 Apple 开发者条款。",
            @"The Internet connection appears to be offline." : @"网络连接似乎已中断（离线），请检查网络后重试。",
            @"The request timed out." : @"请求超时，请稍后重试。",
            @"Could not connect to the server." : @"无法连接到服务器。",
            @"Could not find the server." : @"找不到服务器。",
            @"The network connection was lost." : @"网络连接已丢失。",
            @"A server with the specified hostname could not be found." : @"找不到指定主机名的服务器。",
            @"A secure connection to the server could not be established." : @"无法与服务器建立安全连接。",
            @"Incorrect Apple ID or password." : @"Apple ID 或密码错误。",
            @"This Apple ID has been disabled for security reasons." : @"出于安全原因，此 Apple ID 已被停用。",
            @"Verification failed." : @"验证失败。",
            @"Authentication failed." : @"认证失败。",
            @"This Apple ID is valid but is not an iCloud account." : @"该 Apple ID 有效，但不是 iCloud 账户。",

            // ----- Generic / fallback -----
            @"Unknown error" : @"未知错误",

            // ----- Apple login service errors (from the "em" field / SRP flow) -----
            @"This Apple ID is not active." : @"此 Apple ID 未激活。",
            @"Your Apple ID has been locked." : @"你的 Apple ID 已被锁定。",
            @"Your Apple ID has been locked for security reasons." : @"你的 Apple ID 因安全原因已被锁定。",
            @"Your Apple ID has been disabled." : @"你的 Apple ID 已被停用。",
            @"Your account has been disabled for security reasons." : @"你的账户出于安全原因已被停用。",
            @"Your session has expired." : @"会话已过期，请重新登录。",
            @"Session expired." : @"会话已过期。",
            @"This action could not be completed." : @"操作无法完成。",
            @"This action could not be completed. Try again." : @"操作无法完成，请重试。",
            @"Could not sign in." : @"无法登录。",
            @"Could not sign in. Your account is not permitted to sign in." : @"无法登录，你的账户未被允许登录。",
            @"Software caused connection abort" : @"网络连接被中断。",
            @"An SSL error has occurred and a secure connection to the server cannot be made." : @"SSL 错误，无法建立安全连接。",
            // SRP flow internal errors (NSCocoaErrorDomain)
            @"Could not generate password key" : @"无法生成密码密钥。",
            @"Could not process challenge" : @"无法处理验证请求。",
            @"Could not verify session" : @"无法验证会话。",
            @"Incorrect 2FA code" : @"双重认证码不正确。",

            // ----- Home page (main screen) -----
            @"Installed" : @"已安装",
            @"Expiring Soon" : @"即将过期",
            @"Recently Signed" : @"最近签名",
            @"Other Applications" : @"其他应用",
            @"No applications are expiring soon" : @"没有即将过期的应用",
            @"No applications are recently signed" : @"没有最近签名的应用",
            @"No other sideloaded applications" : @"没有其他侧载应用",
            @"%lu App IDs found" : @"已找到 %lu 个 App ID",

            // ----- Troubleshooting (Shared controller) -----
            @"Online Help" : @"在线帮助",
            @"Online help page provides the latest information about ReProvision Reboorn." : @"在线帮助页面提供 ReProvision Reborn 的最新信息。",
            @"Go to Online Help Page" : @"前往在线帮助页面",
            @"This error usually occurs when the same Apple ID is logged in more than twice to applications like Cydia Impactor and ReProvision.\n\nEach application creates a certificate to sign applications with, but free accounts are limited to only two certificates.\n\nTo resolve this, tap below to remove the extra certificates." : @"此错误通常出现在同一 Apple ID 在多个应用中登录超过两次时。\n\n每个应用都会创建签名证书，但免费账户最多只能拥有两个。\n\n要解决此问题，请点击下方移除多余证书。",
            @"Manage Certificates" : @"管理证书",
            @"Missing application on Apple Watch" : @"Apple Watch 上缺少应用",
            @"After signing an application that supports the Apple Watch, the corresponding Watch application should be automatically installed.\n\nIf this fails without an error, and you have recently paired a new Apple Watch, you may need to manually register it to your Apple ID.\n\nTo do this, please tap below." : @"签名支持 Apple Watch 的应用后，对应 Watch 应用应自动安装。\n\n如果未报错但仍失败，且你最近配对了新 Apple Watch，可能需要手动注册到你的 Apple ID。\n\n请点击下方操作。",
            @"Register Apple Watch" : @"注册 Apple Watch",

            // ----- Credits (Analytics - Chinese-only) -----
            @"Localization Work" : @"汉化工作",
            @"Rootless Support Provider" : @"为 Rootless 提供支持",

            // ----- Network fix (login screen wrench button) -----
            @"Fix Network" : @"修复网络",
            @"Network fixed successfully!" : @"网络修复成功！",

            // ----- Network fix (also available on Troubleshooting page) -----
            @"Fix Network Description" : @"可能解决一些网络问题，但作用不大。",
            @"Fix Network Now" : @"立即修复网络",

            // ----- App Detail Popup (long-press / install dialog) -----
            @"Version" : @"版本",
            @"Size" : @"大小",
            @"Expires" : @"过期时间",
            @"%d%% complete" : @"已完成 %d%%",
            @"Bundle ID: %@" : @"Bundle ID：%@",
            @"Bundle: %@" : @"路径：%@",
            @"Data: %@" : @"数据：%@",
            @"Copy Bundle ID" : @"复制 Bundle ID",
            @"Copy Bundle Location" : @"复制应用路径",
            @"Copy Data Location" : @"复制数据路径",
            @"Show Entitlements" : @"查看权限",
            @"Entitlements" : @"权限",
            @"Uninstall" : @"卸载",
            @"Successfully uninstalled %@" : @"已成功卸载 %@",
            @"Failed to uninstall %@" : @"卸载 %@ 失败",
            @"Warning" : @"警告",
            @"This will remove the current certificate of '%@', and replaces it with a new certificate from your Apple ID.\nThis may result in the loss of the app's saved settings and files.\n\nAre you sure you want to continue?" : @"这将移除「%@」的当前证书，并使用你的 Apple ID 重新签发新证书。\n此操作可能导致该应用的保存设置和文件丢失。\n\n确定要继续吗？",
            @"Continue" : @"继续",

            // ----- Certificates Page -----
            @"Certificates" : @"证书",
            @"Loading" : @"加载中…",
            @"Device: %@" : @"设备：%@",
            @"Application: %@" : @"应用：%@",
            @"No certificates" : @"无证书",
            @"Show All Certificates" : @"显示所有证书",
            @"Hide Unrelated Certificates" : @"隐藏无关证书",
            @"Revoke All Certificates" : @"撤销所有证书",
            @"By default, only the certificates required to sign the app are shown.\nBy tapping the 'Show All Certificates' button, you can show other certificates such as Xcode." : @"默认仅显示签名本应用所需的证书。\n点击「显示所有证书」可查看其他证书（如 Xcode 的）。",
            @"Free accounts are limited to two active certificates." : @"免费账户最多只能同时拥有两个有效证书。",
            @"Revoking all certificates will require applications to be re-signed.\n\nAre you sure you wish to continue?" : @"撤销所有证书后，应用需要重新签名。\n\n确定要继续吗？",
            @"Revoke" : @"撤销",

            // ----- What's App ID? Popup -----
            @"What's App ID?" : @"什么是 App ID？",
            @"App ID is the ID for each sideloaded application, issued by Apple's servers.\nWith a free account, you can only register up to 10 per 7 days.\nThis limit is on a per-account basis.\nAfter a week, it will automatically expire and you can install a new app." : @"App ID 是每个侧载应用的唯一标识，由 Apple 服务器颁发。\n免费账户每 7 天最多注册 10 个 App ID。\n此限制按账户计算。一周后 App ID 会自动过期，届时可以注册新的。",
            @"No App ID found" : @"未找到 App ID",
            @"Dismiss" : @"关闭",

            // ----- Notifications -----
            @"Error" : @"错误",
            @"Success" : @"成功",
            @"Signed '%@'" : @"已签名「%@」",
            @"For '%@':\n%@" : @"「%@」签名失败：\n%@",
            @"No applications require signing at this time" : @"当前无需重签应用",
            @"Couldn't read IPA" : @"无法读取 IPA",
            @"Failed to read this .ipa - it may not be accessible from the share sheet. Try the Add button inside ReProvision instead." : @"无法读取此 .ipa 文件——可能无法从分享菜单访问。请尝试使用 ReProvision 内的导入按钮。",
            @"Failed to read this file as an .ipa - its Info.plist could not be parsed." : @"无法将此文件识别为 .ipa——其 Info.plist 无法解析。",
            @"Signing Failed" : @"签名失败",
            @"Unknown signing error" : @"未知签名错误",
            @"Login Required" : @"需要登录",
            @"Tap to login to ReProvision. This is needed to re-sign applications." : @"点击登录 ReProvision，以便重签应用。",
            @"Re-signing Queued" : @"已排队等待重签",
            @"Unlock your device to resign applications." : @"解锁设备以进行应用重签。",

            // ----- Buttons (Sign → 签名, Add → 导入, INSTALL → 安装) -----
            @"Sign" : @"签名",
            @"Add" : @"导入",
            @"INSTALL" : @"安装",

            // ----- Apple Watch registration results -----
            @"Your Apple Watch has already been registered!" : @"你的 Apple Watch 已经注册过了！",
            @"Your Apple Watch has been registered." : @"你的 Apple Watch 已注册完成。",
            @"No Apple Watch is currently paired!" : @"当前未配对 Apple Watch！",

            // ----- Error message localization (NSError.localizedDescription patterns) -----
            @"Failed to verify code signature of" : @"验证代码签名失败",
            @"A valid provisioning profile for this executable was not found" : @"未找到有效的配置描述文件（provisioning profile）",
            @"Code signature is invalid" : @"代码签名无效",
            @"The identity used to sign this executable is no longer valid" : @"用于签名的身份已失效，请重新登录后重试",
            @"No suitable application was found" : @"未找到可用的应用程序",
            @"Could not install" : @"安装失败",
        
        };
    });
    return dict;
}

static inline NSString *__rpvSelectedLanguage(void) {
    NSString *pref = [[NSUserDefaults standardUserDefaults] stringForKey:kRPVLanguagePreference];
    if ([pref isEqualToString:@"en"]) return @"en";
    if ([pref isEqualToString:@"zh-Hans"]) return @"zh-Hans";

    // "system" (or unset): follow the device language.
    NSArray<NSString *> *preferred = [NSLocale preferredLanguages];
    NSString *systemLang = preferred.count ? preferred[0] : @"en";
    return ([systemLang hasPrefix:@"zh"] || [systemLang rangeOfString:@"Han" options:NSCaseInsensitiveSearch].location != NSNotFound) ? @"zh-Hans" : @"en";
}

static inline NSString *RPVLS(NSString *english) {
    if (english == nil) return nil;
    if ([__rpvSelectedLanguage() isEqualToString:@"zh-Hans"]) {
        NSString *translation = [__rpvZhHansDictionary() objectForKey:english];
        if (translation) return translation;
    }
    return english;
}

// Localize common NSError.localizedDescription patterns for notification bodies.
// Falls back to the original string if no pattern matches.
static inline NSString *RPVLocalizedErrorMessage(NSString *englishError) {
    if (englishError == nil || englishError.length == 0) return englishError;
    if (![__rpvSelectedLanguage() isEqualToString:@"zh-Hans"]) return englishError;

    NSDictionary *dict = __rpvZhHansDictionary();
    NSMutableString *result = [englishError mutableCopy];

    // Replace known patterns in order from longest/most-specific to shortest.
    // Use sorted keys so "Failed to verify code signature of" matches before "of".
    NSArray *sortedKeys = [[dict allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return ([b length] < [a length]) ? NSOrderedDescending : (([b length] > [a length]) ? NSOrderedAscending : NSOrderedSame);  // longest first
    }];

    for (NSString *key in sortedKeys) {
        NSString *value = [dict objectForKey:key];
        if ([result containsString:key]) {
            [result replaceOccurrencesOfString:key withString:value options:NSLiteralSearch range:NSMakeRange(0, result.length)];
        }
    }

    return result;
}
