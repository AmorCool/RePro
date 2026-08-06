//
//  EEBackend.m
//  OpenExtenderTest
//
//  Created by Matt Clarke on 02/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "EEBackend.h"
#import "EEAppleServices.h"
#import "EEProvisioning.h"
#import "EESigning.h"
#import "RZSignRunner.h"
#import "SSZipArchive.h"
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach-o/arch.h>
#import <mach/machine.h>
#import <stdio.h>
#import <sys/stat.h>
#import "RPVDiagnostics.h"
// ChOma（opa334/ChOma，MIT 许可）源码已 vendored 到 Vendor/ChOma，随 App 一起编译。
// 这里只用它的只读能力：解析 FAT / Mach-O 架构切片、读代码签名里的
// CodeDirectory（identifier / teamID）。绝不用它改写用户的二进制。
#import "Fat.h"
#import "MachO.h"
#import "CSBlob.h"
#import "CodeDirectory.h"
#import "libMobileGestalt.h"

#pragma mark - 导入 IPA 时的「扩展处理」选项（仅本次导入生效，signBundleAtPath 入口读入局部变量后立即清零）

static BOOL g_rpvRemoveExtensionsOnImport = NO;
static BOOL g_rpvUseMainProfileForExtensions = NO;

#pragma mark - ARM64e：只读侦测，绝不改动用户二进制

// 历史教训（1.1.32 一次性清算）：
//
// 1) v1.1.10 起为了绕开 arm64e 的 PAC / chained-fixup 问题，代码会把 FAT 里的
//    arm64e 切片整个丢掉、只保留 arm64。这个"瘦身"一直没删干净——v1.1.31 的
//    真机日志里 libjailbreak.dylib / libchoma.dylib / libxpf.dylib /
//    CydiaSubstrate 依然被 "thinned arm64e -> arm64"。后果很直接：Relaxin 的
//    主二进制和 RelaxinEngine 是 arm64e-only，arm64e 进程根本加载不了被瘦成
//    arm64 的依赖库。
//
// 2) v1.1.30 想改成"保留 arm64e 但就地 patch"，结果引入了一个更隐蔽的破坏源：
//    回写时把偏移算成了 `sliceOffset + (lc - base)`，而 `lc - base` 本身已经
//    包含 sliceOffset，于是 FAT 里 offset 非 0 的 arm64e 切片会被写到错误位置，
//    直接把二进制写坏。这类损坏在 installd 眼里就是签名校验失败（0xe8008015）。
//
// 所以从 1.1.32 起立下硬规矩：**任何情况下都不修改用户的 Mach-O**——不瘦身、
// 不改 segment 权限、不清 chained fixups、不写一个字节。原始二进制原样交给
// zsign 重签就好；arm64e 在 RootHide 的 AMFI 补丁下本来就能加载。
//
// 这里保留的全部逻辑只有一件事：用 ChOma（opa334/ChOma，MIT）只读解析每个
// Mach-O，把架构切片和签名信息打进 App 日志页，供定位问题使用。
#define RZ_ARM64E_BIT 0x80000000u

static BOOL RZFileLooksLikeMachO(NSString *path) {
    FILE *f = fopen(path.UTF8String, "rb");
    if (!f) return NO;
    uint32_t magic = 0;
    size_t n = fread(&magic, 1, 4, f);
    fclose(f);
    if (n != 4) return NO;
    return (magic == FAT_MAGIC || magic == FAT_CIGAM ||
            magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
            magic == MH_MAGIC || magic == MH_CIGAM);
}

// cputype/cpusubtype -> 可读架构名。mach_header 与 mach_header_64 的
// cputype/cpusubtype 字段偏移一致，所以 ChOma 返回的 32 位头也能直接读。
static NSString *RZArchName(int32_t cputype, int32_t cpusubtype) {
    uint32_t sub = (uint32_t)cpusubtype & ~RZ_ARM64E_BIT;
    if (cputype == CPU_TYPE_ARM64) {
        if ((uint32_t)cpusubtype & RZ_ARM64E_BIT) return @"arm64e";
        return (sub == CPU_SUBTYPE_ARM64E) ? @"arm64e" : @"arm64";
    }
    if (cputype == CPU_TYPE_ARM) return @"armv7";
    return [NSString stringWithFormat:@"cpu%d/%u", cputype, sub];
}

// 用 ChOma 只读列出一个 Mach-O 的每个切片指纹，形如
//   "arm64e(cs=0x80000002,PAC-versioned,unsigned)+arm64(cs=0x00000000,adhoc)"
// 解析不了就返回 nil（不是我们认识的 Mach-O，直接放过）。
//
// 为什么要打这么细：离线拆 Relaxin-v0.3.8.ipa 得到的事实是——主二进制
// Relaxin 与 Frameworks/RelaxinEngine.framework/RelaxinEngine 都是
// **arm64e-only 且完全没有 LC_CODE_SIGNATURE**（出厂就没签名），
// cpusubtype = 0x80000002（arm64e 且置了 CPU_SUBTYPE_PTRAUTH_ABI 位）；
// 而根目录那几个 dylib 是 arm64+arm64e 的 FAT、带 ad-hoc 签名（有
// identifier 无 teamID）。这些指纹决定了 zsign 要不要新建签名槽、
// installd 会不会因为架构/签名状态拒绝，必须在日志里一眼可见。
static NSString *RZDescribeArchs(NSString *path) {
    Fat *fat = fat_init_from_path(path.UTF8String);
    if (!fat) return nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    fat_enumerate_slices(fat, ^(MachO *macho, bool *stop) {
        struct mach_header *h = macho_get_mach_header(macho);
        if (!h) return;
        uint32_t cs = (uint32_t)h->cpusubtype;
        NSMutableString *desc = [NSMutableString stringWithFormat:@"%@(cs=0x%08x",
                                 RZArchName(h->cputype, h->cpusubtype), cs];
        // arm64e 的 0x80000000 位是 CPU_SUBTYPE_PTRAUTH_ABI（带版本的 PAC ABI）。
        if (h->cputype == CPU_TYPE_ARM64 && (cs & RZ_ARM64E_BIT)) {
            [desc appendFormat:@",PAC-versioned-v%u", (cs >> 24) & 0x3f];
        }
        // 出厂有没有签名槽，决定 zsign 是否需要 ReallocCodeSignSpace 新建
        // LC_CODE_SIGNATURE —— 这一步失败是"重签后仍未签名"的典型原因。
        CS_SuperBlob *sb = macho_read_code_signature(macho);
        [desc appendString:sb ? @",presigned" : @",NO-SIGSLOT"];
        if (sb) free(sb);
        [desc appendString:@")"];
        [names addObject:desc];
    });
    fat_free(fat);
    return names.count ? [names componentsJoinedByString:@"+"] : nil;
}

// 把 Info.plist 里对安装校验有决定性影响的键打进日志。
// Relaxin 的 Info.plist 里 UIRequiredDeviceCapabilities = ["arm64e"]，
// 而 Apple 官方允许的 capability 取值里并没有 "arm64e"（只有 arm64 / armv7
// 这类）。这类非法值是否被 installd 接受，只能靠真机日志确认，所以先如实
// 打印出来，不擅自改用户 App 的 Info.plist。
static void RZLogInstallCriticalInfoPlistKeys(NSString *bundlePath) {
    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info) return;
    id caps = info[@"UIRequiredDeviceCapabilities"];
    if (caps) {
        BOOL suspicious = [caps isKindOfClass:[NSArray class]] && [(NSArray *)caps containsObject:@"arm64e"];
        RPVDiagnostic(suspicious ? RPVDiagWarning : RPVDiagInfo, @"sign",
                      @"Info.plist UIRequiredDeviceCapabilities = %@%@", caps,
                      suspicious ? @"（含 arm64e —— 非 Apple 标准取值，留意 installd 是否因此拒绝）" : @"");
    }
    RPVDiagnostic(RPVDiagInfo, @"sign", @"Info.plist MinimumOSVersion=%@ CFBundleIdentifier=%@",
                  info[@"MinimumOSVersion"] ?: @"(none)", info[@"CFBundleIdentifier"] ?: @"(none)");
}

// 用 ChOma 只读解析代码签名，返回每个切片的 "arch:identifier/teamID" 描述。
// 这比原来那句 "signed=yes" 有用得多：Relaxin 的 dylib 出厂就带作者签名，
// 光看"有没有签名"永远分不清 zsign 到底重签成功没有——只有 identifier 和
// teamID 变成我们这次用的 Apple ID 团队，才说明真的重签上了。
static NSString *RZDescribeSignature(NSString *path) {
    Fat *fat = fat_init_from_path(path.UTF8String);
    if (!fat) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    fat_enumerate_slices(fat, ^(MachO *macho, bool *stop) {
        struct mach_header *h = macho_get_mach_header(macho);
        NSString *arch = h ? RZArchName(h->cputype, h->cpusubtype) : @"?";
        CS_SuperBlob *sb = macho_read_code_signature(macho);
        if (!sb) {
            [parts addObject:[NSString stringWithFormat:@"%@:UNSIGNED", arch]];
            return;
        }
        NSString *ident = nil, *team = nil;
        CS_DecodedSuperBlob *dec = csd_superblob_decode(sb);
        if (dec) {
            CS_DecodedBlob *cd = csd_superblob_find_blob(dec, CSSLOT_CODEDIRECTORY, NULL);
            if (cd) {
                char *i = csd_code_directory_copy_identifier(cd, NULL);
                char *t = csd_code_directory_copy_team_id(cd, NULL);
                if (i) { ident = [NSString stringWithUTF8String:i]; free(i); }
                if (t) { team  = [NSString stringWithUTF8String:t]; free(t); }
            }
            csd_superblob_free(dec);   // 先放解码结构，它引用的是 sb 里的数据
        }
        free(sb);
        [parts addObject:[NSString stringWithFormat:@"%@:%@/%@", arch,
                          ident.length ? ident : @"(no-id)",
                          team.length ? team : @"(no-team)"]];
    });
    fat_free(fat);
    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}

// 重签前把 bundle 里每个 Mach-O 的架构打进日志。纯只读，不改任何文件。
// 目的是让"arm64e 有没有被保住"这件事在日志里一眼可见，杜绝再出现
// 悄悄瘦身却没人发现的情况。
static void RZInspectArchsInBundle(NSString *bundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:nil];
    int count = 0;
    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        NSString *path = url.path;
        if (!RZFileLooksLikeMachO(path)) continue;
        NSString *archs = RZDescribeArchs(path);
        if (archs) {
            RPVDiagnostic(RPVDiagInfo, @"sign", @"重签前指纹 %@ : %@", [path lastPathComponent], archs);
            count++;
        }
    }
    RPVDiagnostic(RPVDiagInfo, @"sign", @"共 %d 个 Mach-O，保留架构原样", count);
    RZLogInstallCriticalInfoPlistKeys(bundlePath);
}

// 越狱 / roothide App（如 Relaxin）有时会带一个只有 dylib、没有 Info.plist 的
// .framework。没有 Info.plist，zsign 不会把它识别为嵌套 bundle，里面的 Mach-O
// 就会带着原作者的旧签名一路进到 installd。这里给缺失的补一个最小 Info.plist，
// 并清掉历史版本误注入的 embedded.mobileprovision。
static void RZFixFrameworkBundles(NSString *bundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1.1.28 曾往每个嵌套 framework 里塞一份主 App 的 embedded.mobileprovision，
    // 理由是"installd 会独立校验嵌套 bundle"。这个理由是错的：按 Apple 的规则，
    // 只有 .app 和 .appex 这种可执行 bundle 才允许带描述文件，framework 带
    // embedded.mobileprovision 反而会被当成一个独立的可执行 bundle 去校验，
    // 而它并没有配套的 application-identifier —— 这本身就足以触发 0xe8008015。
    // 1.1.32 起彻底移除这段注入；同时把历史遗留的注入文件清掉，避免用户上次
    // 重签留下的 embedded.mobileprovision 继续在 framework 里作祟。

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
                                          includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue) continue;
        NSString *path = url.path;
        if (![path hasSuffix:@".framework"]) continue;
        NSString *infoPlist = [path stringByAppendingPathComponent:@"Info.plist"];

        // 1) A framework with no Info.plist is malformed and rejected by installd.
        if (![fm fileExistsAtPath:infoPlist]) {
            NSString *fwName = [path lastPathComponent].stringByDeletingPathExtension;
            NSString *exePath = [path stringByAppendingPathComponent:fwName];
            NSString *exeName = fwName;
            if (![fm fileExistsAtPath:exePath]) {
                // Fall back to the first Mach-O inside the framework.
                NSDirectoryEnumerator *fe = [fm enumeratorAtURL:url
                                          includingPropertiesForKeys:nil
                                                             options:0
                                                        errorHandler:nil];
                for (NSURL *fu in fe) {
                    FILE *f = fopen(fu.path.UTF8String, "rb");
                    uint32_t m = 0; size_t rn = f ? fread(&m, 1, 4, f) : 0;
                    if (f) fclose(f);
                    if (rn == 4 && (m == 0xfeedfacf || m == 0xcafebabe || m == 0xfeedface || m == 0xcffaedfe)) {
                        exeName = [fu.path lastPathComponent];
                        break;
                    }
                }
            }
            // Nest the fixed framework's identifier under the main app's bundle id
            // (the conventional Xcode form "appid.fwname"), so it validates as
            // nested code rather than a foreign bundle.
            NSString *idPrefix = @"cn.analy.resign.fixedfw";
            NSString *appInfoPlist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
            if ([fm fileExistsAtPath:appInfoPlist]) {
                NSString *appId = [[NSDictionary dictionaryWithContentsOfFile:appInfoPlist] objectForKey:@"CFBundleIdentifier"];
                if (appId.length) idPrefix = [appId stringByAppendingString:@"."];
            }
            NSDictionary *info = @{
                @"CFBundleName": fwName,
                @"CFBundleExecutable": exeName,
                @"CFBundleIdentifier": [NSString stringWithFormat:@"%@%@", idPrefix, fwName],
                @"CFBundlePackageType": @"FMWK",
                @"CFBundleVersion": @"1.0",
                @"CFBundleShortVersionString": @"1.0",
                @"CFBundleSupportedPlatforms": @[@"iPhoneOS"],
                @"DTPlatformName": @"iphoneos",
                @"DTPlatformVersion": @"17.0",
                @"MinimumOSVersion": @"15.0",
                @"UIDeviceFamily": @[@1, @2],
            };
            if ([info writeToFile:infoPlist atomically:YES]) {
                RPVDiagnostic(RPVDiagInfo, @"sign", @"fixed malformed framework (added Info.plist): %@", [path lastPathComponent]);
            } else {
                RPVDiagnostic(RPVDiagError, @"sign", @"WARN: could not write Info.plist for framework %@", [path lastPathComponent]);
            }
        }

        // 2) framework 里不该有描述文件。清掉历史版本注入的那份，避免它被
        //    installd 当成独立可执行 bundle 校验。
        NSString *fwProfile = [path stringByAppendingPathComponent:@"embedded.mobileprovision"];
        if ([fm fileExistsAtPath:fwProfile]) {
            NSError *rmErr = nil;
            if ([fm removeItemAtPath:fwProfile error:&rmErr]) {
                RPVDiagnostic(RPVDiagInfo, @"sign", @"已移除 framework 内非法的 embedded.mobileprovision: %@", [path lastPathComponent]);
            } else {
                RPVDiagnostic(RPVDiagWarning, @"sign", @"framework %@ 内的 embedded.mobileprovision 删除失败: %@",
                              [path lastPathComponent], rmErr.localizedDescription);
            }
        }
    }
}

// After zsign, verify every Mach-O in the bundle actually carries a code
// signature. If zsign silently failed to sign an arm64e-only / unusual binary,
// installd rejects the whole app with 0xe8008015 — this surfaces which binary
// (if any) was left unsigned.
// expectedTeamID 是本次重签用的 Apple ID 团队。凡是 CodeDirectory 里 teamID
// 对不上的，就说明 zsign 压根没碰这个二进制（它还带着原作者的签名），
// 这类"漏签"正是 installd 报 0xe8008015 的典型原因。
static void RZVerifyBundleSigned(NSString *bundlePath, NSString *expectedTeamID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
                                          includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                             options:0
                                                        errorHandler:nil];
    int unsignedCount = 0, staleCount = 0, okCount = 0;
    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        NSString *path = url.path;
        if (!RZFileLooksLikeMachO(path)) continue;

        NSString *desc = RZDescribeSignature(path);
        if (!desc) continue;   // ChOma 解析不了，跳过
        NSString *name = [path lastPathComponent];

        if ([desc containsString:@"UNSIGNED"]) {
            RPVDiagnostic(RPVDiagError, @"sign", @"zsign 后仍未签名: %@ [%@]", name, desc);
            unsignedCount++;
        } else if (expectedTeamID.length && ![desc containsString:expectedTeamID]) {
            // teamID 不是本次用的团队 —— 还是旧签名，zsign 没重签它。
            RPVDiagnostic(RPVDiagError, @"sign", @"仍是旧签名（teamID 非 %@）: %@ [%@]",
                          expectedTeamID, name, desc);
            staleCount++;
        } else {
            RPVDiagnostic(RPVDiagDebug, @"sign", @"重签成功 %@ [%@]", name, desc);
            okCount++;
        }
    }
    if (unsignedCount == 0 && staleCount == 0) {
        RPVDiagnostic(RPVDiagInfo, @"sign", @"全部 %d 个 Mach-O 都已用本次证书重签（teamID=%@）",
                      okCount, expectedTeamID.length ? expectedTeamID : @"?");
    } else {
        RPVDiagnostic(RPVDiagError, @"sign",
                      @"重签不完整：%d 个未签名 + %d 个仍是旧签名（%d 个正常）——这就是 0xe8008015 的直接原因",
                      unsignedCount, staleCount, okCount);
    }
}

// Extract the embedded plist from a .mobileprovision (CMS/PKCS#7-wrapped) by
// locating the <?xml ... </plist> markers in the raw bytes. security/CMSDecoder
// is unavailable in the iOS SDK, but the CMS eContent (the profile plist) is
// stored verbatim as the OCTET STRING value, so the ASCII plist markers are
// present in the file. This is the standard on-device trick to read a profile
// without CMSDecoder. Returns nil if no plist can be found/parsed.
static NSDictionary *RZExtractProfilePlist(NSString *provPath) {
    NSData *data = [NSData dataWithContentsOfFile:provPath];
    if (!data || data.length < 16) return nil;
    NSData *open = [@"<?xml" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *close = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange r1 = [data rangeOfData:open options:0 range:NSMakeRange(0, data.length)];
    NSRange r2 = [data rangeOfData:close options:NSBackwardsSearch range:NSMakeRange(0, data.length)];
    if (r1.location == NSNotFound || r2.location == NSNotFound) return nil;
    NSUInteger end = r2.location + r2.length;
    if (end <= r1.location) return nil;
    NSData *plistData = [data subdataWithRange:NSMakeRange(r1.location, end - r1.location)];
    return [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:nil];
}

// 读取 .app 的 CFBundleIdentifier（用于 Profile↔BundleID 一致性闸门）。
static NSString *RZBundleIdentifierAtPath(NSString *bundlePath) {
    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    return info[@"CFBundleIdentifier"];
}

// v1.1.101: lara 类工具习惯把 CFBundleIdentifier 写成 `<bundle>.<TEAMID>`（把 team id 拼在后面），
// 而 profile 的 application-identifier 也可能写成 `<TEAMID>.<bundle>.<TEAMID>` 的怪形式。
// 比对仍必须用原始字符串（避免遮蔽「不同 app」错误），但展示给用户前剥掉末尾的 .<TEAMID> 后缀
// 看起来更干净。
static NSString *RZStripTeamIDSuffix(NSString *str, NSString *teamID) {
    if (str.length == 0 || teamID.length == 0) return str;
    NSString *suffix = [@"." stringByAppendingString:teamID];
    if ([str hasSuffix:suffix] && str.length > suffix.length) {
        return [str substringToIndex:str.length - suffix.length];
    }
    return str;
}

// Dump the provisioning-profile ↔ signed-entitlements match — the actual root
// cause of install-time 0xe8008015 (per the LiveContainer/ReproVision guides:
// application-identifier exact match + device UDID registration + TeamIdentifier
// consistency + entitlements ⊆ profile whitelist). On iOS we cannot use
// CMSDecoder, so we parse the profile plist via RZExtractProfilePlist.
static void RZDumpProfileMatch(NSString *bundlePath, NSString *entitlementsPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mainProv = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];

    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== PROFILE MATCH DIAGNOSTICS (0xe8008015 root cause) ===");

    NSDictionary *prof = RZExtractProfilePlist(mainProv);
    if (!prof) {
        RPVDiagnostic(RPVDiagError, @"sign", @"! cannot parse embedded.mobileprovision (present=%@) — cannot verify profile match",
                      [fm fileExistsAtPath:mainProv] ? @"yes" : @"NO");
        RPVDiagnostic(RPVDiagInfo, @"sign", @"=== end PROFILE MATCH DIAGNOSTICS ===");
        return;
    }
    NSDictionary *pe = prof[@"Entitlements"];
    NSString *aid = pe[@"application-identifier"];
    NSArray *teams = prof[@"TeamIdentifier"];
    NSArray *devs = prof[@"ProvisionedDevices"];
    NSString *exp = [prof[@"ExpirationDate"] description] ?: @"(unknown)";

    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.application-identifier = %@", aid);
    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.TeamIdentifier = %@", teams.firstObject);
    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.ProvisionedDevices count = %lu (empty => wildcard/team profile)",
                  (unsigned long)(devs ? devs.count : 0));
    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.ExpirationDate = %@", exp);

    NSDictionary *ent = [NSDictionary dictionaryWithContentsOfFile:entitlementsPath];
    NSString *eaid = ent[@"application-identifier"];
    RPVDiagnostic(RPVDiagInfo, @"sign", @"signed entitlements.application-identifier = %@", eaid);

    // Wildcard-aware application-identifier match: profile "<Team>.*" matches
    // signed "<Team>.<bundleid>". Non-wildcard requires exact bundle id.
    BOOL aidMatch = NO;
    if (aid.length && eaid.length) {
        NSArray *pa = [aid componentsSeparatedByString:@"."];
        NSArray *ea = [eaid componentsSeparatedByString:@"."];
        if (pa.count >= 2 && ea.count >= 2) {
            NSString *pTeam = pa[0];
            NSString *pBundle = [[pa subarrayWithRange:NSMakeRange(1, pa.count - 1)] componentsJoinedByString:@"."];
            NSString *eTeam = ea[0];
            NSString *eBundle = [[ea subarrayWithRange:NSMakeRange(1, ea.count - 1)] componentsJoinedByString:@"."];
            BOOL teamOK = [pTeam isEqualToString:eTeam];
            BOOL bundleOK = [pBundle isEqualToString:@"*"] || [pBundle isEqualToString:eBundle];
            aidMatch = teamOK && bundleOK;
        }
    }
    RPVDiagnostic(aidMatch ? RPVDiagInfo : RPVDiagError, @"sign",
                  @"application-identifier MATCH = %@",
                  aidMatch ? @"YES" : @"NO (MISMATCH -> 0xe8008015)");

    // Device UDID registration (the guide's stated primary 0xe8008015 cause).
    CFStringRef udidRef = MGCopyAnswer(kMGUniqueDeviceID);
    NSString *udid = udidRef ? (__bridge_transfer NSString *)udidRef : nil;
    if (udid.length) {
        BOOL inProfile = (devs.count == 0) ? YES : [devs containsObject:udid];
        RPVDiagnostic(inProfile ? RPVDiagInfo : RPVDiagError, @"sign",
                      @"device UDID = %@ | in profile.ProvisionedDevices = %@",
                      udid, inProfile ? @"YES" : @"NO (NOT REGISTERED -> 0xe8008015)");
    } else {
        RPVDiagnostic(RPVDiagWarning, @"sign", @"! could not read device UDID via MGCopyAnswer");
    }

    // Entitlements subset check vs profile whitelist.
    if (pe && ent) {
        NSMutableArray *extra = [NSMutableArray array];
        for (NSString *k in ent) {
            if (pe[k] == nil) [extra addObject:k];
        }
        if (extra.count) {
            RPVDiagnostic(RPVDiagError, @"sign",
                          @"entitlements NOT in profile whitelist: %@ -> reject",
                          [extra componentsJoinedByString:@", "]);
        } else {
            RPVDiagnostic(RPVDiagInfo, @"sign", @"entitlements ⊆ profile whitelist: YES");
        }
    }

    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== end PROFILE MATCH DIAGNOSTICS ===");
}

// zsign 之后报告磁盘上的描述文件布局：主 App 必须有 embedded.mobileprovision，
// 嵌套 framework 必须**没有**（1.1.32 修正——framework 带描述文件是非法的，
// 会被 installd 当成独立可执行 bundle 校验从而失败）。每个 Mach-O 的签名细节
// 由 RZVerifyBundleSigned 用 ChOma 单独打印，这里不再重复。
static void RZLogProfileDiagnostics(NSString *bundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appName = [bundlePath lastPathComponent].stringByDeletingPathExtension;
    NSString *mainProv = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];

    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== re-sign diagnostics for %@ ===", appName);
    RPVDiagnostic(RPVDiagInfo, @"sign", @"main app embedded.mobileprovision: %@",
                  [fm fileExistsAtPath:mainProv] ? @"present" : @"MISSING");

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
                                      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                         options:0
                                                    errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSString *p = url.path;
        if ([p hasSuffix:@".framework"]) {
            NSString *ip = [p stringByAppendingPathComponent:@"Info.plist"];
            NSString *prov2 = [p stringByAppendingPathComponent:@"embedded.mobileprovision"];
            BOOL hasProv = [fm fileExistsAtPath:prov2];
            RPVDiagnostic(hasProv ? RPVDiagError : RPVDiagInfo, @"sign",
                          @"framework %@ : Info.plist=%@ embedded.mobileprovision=%@",
                          [p lastPathComponent],
                          [fm fileExistsAtPath:ip] ? @"yes" : @"NO",
                          hasProv ? @"yes（非法，应为 no）" : @"no（正确）");
        }
    }
    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== end diagnostics ===");
}

/* Private headers */
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
- (NSArray *)allApplications;
- (BOOL)uninstallApplication:(id)arg1 withOptions:(id)arg2;
@end

@implementation EEBackend

#pragma mark - 导入 IPA「扩展处理」选项透传

+ (void)setExtensionImportOptionsRemoveExtensions:(BOOL)removeExtensions useMainProfileForExtensions:(BOOL)useMainProfileForExtensions {
    g_rpvRemoveExtensionsOnImport = removeExtensions;
    g_rpvUseMainProfileForExtensions = useMainProfileForExtensions;
}

// 签名前删除 path 下所有 PlugIns/*.appex（App 扩展）。仅删扩展目录本身，不动主程序。
+ (void)_removeAppExtensionsAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plugIns = [path stringByAppendingPathComponent:@"PlugIns"];
    NSArray *entries = [fm contentsOfDirectoryAtPath:plugIns error:nil];
    NSInteger removed = 0;
    for (NSString *entry in entries) {
        if ([[entry pathExtension] isEqualToString:@"appex"]) {
            NSString *extPath = [plugIns stringByAppendingPathComponent:entry];
            if ([fm removeItemAtPath:extPath error:nil]) removed++;
        }
    }
    if (removed > 0) {
        NSLog(@"[ReSign] 按用户选择移除扩展：已删除 %ld 个 PlugIns/*.appex", (long)removed);
        // PlugIns 空了就一并删掉，避免 installd 因残留空目录报错。
        if ([fm contentsOfDirectoryAtPath:plugIns error:nil].count == 0) {
            [fm removeItemAtPath:plugIns error:nil];
        }
    }
}

+ (void)provisionDevice:(NSString *)udid name:(NSString *)name identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler {
    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner provisionDevice:udid name:name withTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error) {
        completionHandler(error);
    }];
}

+ (void)revokeDevelopmentCertificatesForCurrentMachineWithIdentity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler {
    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner revokeCertificatesWithTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error) {
        completionHandler(error);
    }];
}

+ (void)signBundleAtPath:(NSString *)path identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId withCompletionHandler:(void (^)(NSError *error))completionHandler {
    // 读入本次导入的「扩展处理」选项后立即清零，避免泄漏到后续批量/单点重签。
    BOOL removeExtensions = g_rpvRemoveExtensionsOnImport;
    BOOL useMainProfileForExtensions = g_rpvUseMainProfileForExtensions;
    g_rpvRemoveExtensionsOnImport = NO;
    g_rpvUseMainProfileForExtensions = NO;

    // 用户选择「移除扩展」：签名前先把所有 PlugIns/*.appex 删掉。
    if (removeExtensions) {
        [self _removeAppExtensionsAtPath:path];
    }

    // Signing kernel: zsign (replaces the old ldid-based EESigning path).
    //
    // zsign re-signs a whole .app (main executable + every nested extension /
    // framework) in a SINGLE pass, matching one provisioning profile per bundle
    // by application-identifier suffix. So we can't just swap the per-bundle sign
    // call: we first walk the bundle tree to provision every bundle through the
    // Apple ID flow (download a profile, register its bundle id, write
    // embedded.mobileprovision), collecting every profile plus the shared signing
    // certificate/key AND a per-bundle entitlements plist, then invoke zsign ONCE
    // on the root bundle with all profiles as -m and the ROOT bundle's entitlements
    // as -e.
    // Why -e is required (fixes the iOS 17 re-sign launch crash): without -e,
    // zsign falls back to the provisioning profile's Entitlements. For a free /
    // wildcard account that is "application-identifier: TEAMID.*" — an INVALID
    // value inside a code signature — so iOS 17 rejects (crashes) the re-signed
    // app at launch. Passing -e with the SPECIFIC application-identifier (from
    // EEProvisioning's curated entitlements dict) fixes it. Note zsign applies the
    // one -e to every bundle, so nested extensions inherit the root
    // application-identifier; their embedded.mobileprovision is still correct from
    // the matched -m profile — the main app (the one that launches and was
    // crashing) is what gets fixed. A single pass is also required so zsign can
    // compute the main app's CodeResources consistently against the final nested
    // signatures.
    //
    // CRITICAL: -e MUST contain only entitlements authorised by the profile,
    // otherwise installd rejects the bundle at install time with 0xe8008015.
    // The free-account profile authorises exactly the 10 whitelist keys in
    // EEProvisioning.mm ~line 822. CS entitlements (allow-jit,
    // disable-library-validation, allow-unsigned-executable-memory) are NOT
    // in that whitelist and CANNOT be added to -e. They are runtime-patched
    // by libsubstitute on the jailbroken device. (v1.3.42/45 tried adding
    // them and they caused installd rejection — that's the rule this comment
    // is here to keep future maintainers from re-adding them.)
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    context[@"profiles"] = [NSMutableArray array];
    context[@"tempFiles"] = [NSMutableArray array];
    // 把「扩展用主 profile 签名」选项透传给 _provisionBundleAtPath（经 context，避免改动递归签名接口签名）。
    context[@"useMainProfileForExtensions"] = @(useMainProfileForExtensions);

    [self _provisionBundleAtPath:path identity:identity gsToken:gsToken priorChosenTeamID:teamId context:context isExtension:NO withCompletionHandler:^(NSError *provisionError) {
        if (provisionError) {
            [self _cleanupTempFilesInContext:context];
            completionHandler(provisionError);
            return;
        }

        NSString *keyPath = context[@"keyPath"];
        NSString *certPath = context[@"certPath"];
        NSArray *profiles = context[@"profiles"];

        // 逆序 -m：确保宿主 profile 排在第一个。zsign 对「没有任何 -m 匹配」的嵌套 bundle
        // （如 id 与宿主无关的 framework）取第一个 -m 的 entitlements 来签（zhlynn/zsign@d6e929c
        // src/bundle.cpp:449-477，rbegin 循环结束时 m_pSignAsset 停留在第一个 -m）。framework
        // 没有自己的 App ID，签名 application-identifier 复用宿主 app id 是被宿主 embedded
        // profile 授权的（Relaxin 的 CydiaSubstrate.framework / RelaxinEngine.framework 即如此，
        // 实机安装正常）。
        profiles = [[profiles reverseObjectEnumerator] allObjects];

        if (keyPath.length == 0 || certPath.length == 0 || profiles.count == 0) {
            [self _cleanupTempFilesInContext:context];
            completionHandler([self _errorFromString:@"Signing credentials were not obtained during provisioning."]);
            return;
        }

        // Sign the whole bundle tree in place with zsign (root entitlements as -e).
        // A single pass is required so zsign computes the main app's CodeResources
        // consistently against the final nested-bundle signatures. zsign applies the
        // one -e to every bundle, so nested extensions inherit the root
        // application-identifier (their own embedded.mobileprovision stays correct
        // from the matched -m profile); the main app — the one that launches and
        // was crashing — gets the specific application-identifier + cs.* safety
        // entitlements, which is what fixes the iOS 17 re-sign launch crash.
        NSString *rootEntitlementsPath = context[@"entitlementsPath"];

        // ── Profile ↔ BundleID 一致性闸门（签名前拦截，避免 0xe8008015 闪退）──
        // 用 provisioning 刚写入 .app 的 embedded.mobileprovision 来比对（那是 zsign 真正会用的 profile）。
        // 非通配且不一致 → 直接中止。不同 bundle id 视为不同应用，不再改写其一去迁就对方，
        // 而是清晰报错，提示改用「通配符」或与该安装包 bundle id 一致的 profile。
        {
            NSString *appBundle = RZBundleIdentifierAtPath(path);
            NSDictionary *emb = RZExtractProfilePlist([path stringByAppendingPathComponent:@"embedded.mobileprovision"]);
            NSString *aid = emb[@"Entitlements"][@"application-identifier"];
            NSString *profBundle = nil;
            if (aid.length) {
                NSArray *pa = [aid componentsSeparatedByString:@"."];
                if (pa.count >= 2) {
                    profBundle = [[pa subarrayWithRange:NSMakeRange(1, pa.count - 1)] componentsJoinedByString:@"."];
                }
            }
            // v1.1.103: lara 类工具常把 Team ID 拼到 bundle id 两端
            // （CFBundleIdentifier = <bundle>.<TEAMID>，application-identifier = <TEAMID>.<bundle>.<TEAMID>）。
            // 比对前先把两端的「<TEAMID>.」前缀 / 「.<TEAMID>」后缀剥掉，只比较真正的 core bundle id，
            // 避免把「同一个 app」误判成「不同 app」。若剥完两端后 core 仍不一致，才是真的不同 app → 中止。
            id teamIDRaw = emb[@"TeamIdentifier"];
            NSString *profileTeamID = nil;
            if ([teamIDRaw isKindOfClass:[NSArray class]]) {
                profileTeamID = [(NSArray *)teamIDRaw firstObject];
            } else if ([teamIDRaw isKindOfClass:[NSString class]]) {
                profileTeamID = (NSString *)teamIDRaw;
            }
            NSString *(^stripTeamID)(NSString *) = ^NSString *(NSString *s){
                if (s.length == 0 || profileTeamID.length == 0) return s;
                // 剥前缀 "<TEAMID>."
                NSString *prefix = [profileTeamID stringByAppendingString:@"."];
                if ([s hasPrefix:prefix] && s.length > prefix.length) {
                    s = [s substringFromIndex:prefix.length];
                }
                // 剥后缀 ".<TEAMID>"
                NSString *suffix = [@"." stringByAppendingString:profileTeamID];
                if ([s hasSuffix:suffix] && s.length > suffix.length) {
                    s = [s substringToIndex:s.length - suffix.length];
                }
                return s;
            };
            NSString *appCore  = stripTeamID(appBundle);
            NSString *profCore = stripTeamID(profBundle);

            if (appBundle.length && profBundle.length && ![profBundle isEqualToString:@"*"] && ![profCore isEqualToString:appCore]) {
                NSError *mismatch = [NSError errorWithDomain:@"ReSignError" code:9876 userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"IPA 的 bundle id 是「%@」，与当前 profile 的 bundle id「%@」不匹配。\n\n"
                        @"这两个是不同的应用，profile 不能跨 app 通用。请用「通配符 profile（TEAMID.*）」"
                        @"或与该 IPA bundle id 一致的 profile 重新导入后再试。\n\n"
                        @"提示：若该应用是别人签名后出现闪退（0xe8008015），签名本身未损坏，"
                        @"重新导入原始 IPA 用匹配 profile 签名即可恢复。",
                        appCore, profCore],
                    @"appBundle": appBundle,
                    @"profBundle": profBundle,
                }];
                [self _cleanupTempFilesInContext:context];
                completionHandler(mismatch);
                return;
            }
        }

        // 只读侦测：把每个 Mach-O 的架构打进日志，确认 arm64e 被原样保留。
        // 1.1.32 起这里不再对二进制做任何写操作（不瘦身、不 patch）。
        RZInspectArchsInBundle(path);

        // Relaxin / roothide 这类越狱 App 会带一个没有 Info.plist 的 .framework
        // （CydiaSubstrate.framework 其实是 ElleKit 的壳）。没有 Info.plist 的
        // 目录 zsign 不会当作嵌套 bundle 去签，里面的 Mach-O 就会带着旧签名进
        // installd。这里只补一个最小 Info.plist，不再往 framework 里塞
        // embedded.mobileprovision（见 RZFixFrameworkBundles 里的说明）。
        RZFixFrameworkBundles(path);

        NSError *signError = nil;
        // -e 只传给「单 profile」场景（无扩展）——此时 -e=宿主自己的 app id，与 profile 一致，无害。
        // 多 profile（含扩展）时绝不传 -e：zsign 会把同一个 -e 应用到所有 bundle
        // （src/archo.cpp:342: SlotBuildEntitlements(IsExecute() ? pSignAsset->m_strEntitleData : ...)，
        // 而每个 ZSignAsset 的 m_strEntitleData 都来自同一个 strEntitleFile），导致扩展的代码签名
        // application-identifier = 宿主的 id，而扩展自己嵌入的 profile（匹配到的 -m）是扩展自己的
        // id → installd 校验扩展时签名 app-id 不被其 profile 授权 → 0xe8008017（Via.app 实测，
        // 对比 Relaxin 无扩展同参数安装正常）。
        // 不传 -e 时每个 bundle 用「自己匹配到的 -m」的 entitlements：扩展得到自己的 app-id ✓；
        // framework 无匹配则回退第一个 -m（=宿主，见上）得到宿主 app-id ✓，与 Relaxin 行为一致。
        NSString *entitlementsToPass = (profiles.count > 1) ? nil : rootEntitlementsPath;
        RZSignResult *result = [[RZSignRunner sharedRunner] signBundleAtPath:path
                                                                  outputPath:nil
                                                             certificatePath:certPath
                                                                     keyPath:keyPath
                                                           provisioningPaths:profiles
                                                            entitlementsPath:entitlementsToPass
                                                                   useSHA256:YES
                                                                       error:&signError];

        // 越狱 App（Relaxin 等）重签失败的诊断。先从主 App 的描述文件里取出本次
        // 使用的 TeamID，再逐个核对每个 Mach-O 的 CodeDirectory —— 只有 teamID
        // 换成了本次的团队，才算真的重签上了。
        NSDictionary *mainProfilePlist =
            RZExtractProfilePlist([path stringByAppendingPathComponent:@"embedded.mobileprovision"]);
        NSString *expectedTeamID = [mainProfilePlist[@"TeamIdentifier"] firstObject];

        RZVerifyBundleSigned(path, expectedTeamID);
        RZLogProfileDiagnostics(path);
        RZDumpProfileMatch(path, rootEntitlementsPath);

        [self _cleanupTempFilesInContext:context];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            if (!result.success) {
                error = signError ?: [self _errorFromString:@"zsign failed to sign the bundle."];
            }
            completionHandler(error);
        });
    }];
}

// Walks the bundle tree (root + PlugIns + Watch), provisioning every bundle via
// the Apple ID flow WITHOUT signing. For each bundle it downloads a provisioning
// profile, registers the (Team-ID-suffixed) bundle identifier, writes the
// bundle's embedded.mobileprovision, and collects a staged copy of that profile
// (plus, once, the shared certificate + private key) into `context` for the
// single zsign pass performed by signBundleAtPath:.
+ (void)_provisionBundleAtPath:(NSString *)path identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId context:(NSMutableDictionary *)context isExtension:(BOOL)isExtension withCompletionHandler:(void (^)(NSError *error))completionHandler {
    // 从 context 取回「扩展用主 profile 签名」选项（由 signBundleAtPath 透传，避免改动递归签名接口签名）。
    BOOL useMainProfileForExtensions = [context[@"useMainProfileForExtensions"] boolValue];
    if (useMainProfileForExtensions && isExtension) {
        NSLog(@"[ReSign] 「扩展用主 profile」选项对扩展无效：iOS 要求扩展代码签名必须是具体 application-identifier，"
              @"通配符 profile 无法为扩展产出合法 app-id，故该扩展改走各自注册具体 profile（保证安装成功）。");
    }

    dispatch_group_t dispatch_group = dispatch_group_create();
    NSMutableArray *__block subBundleErrors = [NSMutableArray array];

    if ([[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/PlugIns", path]]) {
        // Recurse through the plugins.

        for (NSString *subBundle in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@/PlugIns", path] error:nil]) {
            NSString *__block subBundlePath = [NSString stringWithFormat:@"%@/PlugIns/%@", path, subBundle];

            // Enter the dispatch group
            dispatch_group_enter(dispatch_group);

            NSLog(@"Provisioning sub-bundle: %@", subBundlePath);

            [self _provisionBundleAtPath:subBundlePath identity:identity gsToken:gsToken priorChosenTeamID:teamId context:context isExtension:YES withCompletionHandler:^(NSError *error) {
                if (error)
                    [subBundleErrors addObject:error];

                NSLog(@"Finished provisioning sub-bundle: %@", subBundlePath);
                dispatch_group_leave(dispatch_group);
            }];
        }
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/Watch", path]]) {
        // Recurse through the watchOS stuff.

        for (NSString *subBundle in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@/Watch", path] error:nil]) {
            NSString *__block subBundlePath = [NSString stringWithFormat:@"%@/Watch/%@", path, subBundle];

            // Enter the dispatch group
            dispatch_group_enter(dispatch_group);

            NSLog(@"Provisioning sub-bundle: %@", subBundlePath);

            [self _provisionBundleAtPath:subBundlePath identity:identity gsToken:gsToken priorChosenTeamID:teamId context:context isExtension:YES withCompletionHandler:^(NSError *error) {
                if (error)
                    [subBundleErrors addObject:error];

                NSLog(@"Finished provisioning sub-bundle: %@", subBundlePath);
                dispatch_group_leave(dispatch_group);
            }];
        }
    }

    // 内嵌 framework 处理：唯一化 CFBundleIdentifier，防止 installd 报 code=57 DuplicateIdentifier。
    //
    // 背景（已精确定位到 zsign zhlynn/zsign @d6e929c 的 src/bundle.cpp:449-477）：
    //   zsign 用 `endsWith(profile.application-identifier, bundle.CFBundleIdentifier)` 把每个 -m 描述文件
    //   匹配到 bundle，无匹配则回退第一个 -m 的 entitlements 签名该 bundle。v1.1.110 曾把 framework id
    //   直接改成「宿主最终 id」以命中宿主 -m，结果撞了 installd 预检 code=57（父与子同 id）。
    //
    // 正确做法：framework 不注册自己的 App ID，签名 application-identifier 复用宿主 app id
    // （无 -m 命中 → 回退第一个 -m=宿主 asset，已被宿主 embedded profile 授权；Relaxin 的
    // CydiaSubstrate.framework / RelaxinEngine.framework 实测同机制安装正常）。这里只把 framework id
    // 唯一化（宿主base.fwName），与宿主/扩展/其他 framework 都不重复，避免 code=57。
    // 只对宿主（isExtension==NO）做一次，避免递归重复。
    if (!isExtension) {
        NSString *frameworkDir = [path stringByAppendingPathComponent:@"Frameworks"];
        NSArray *fwList = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frameworkDir error:nil];
        for (NSString *fwDir in fwList) {
            if (![fwDir hasSuffix:@".framework"]) continue;
            NSString *fwPath = [frameworkDir stringByAppendingPathComponent:fwDir];
            NSString *fwInfoPath = [fwPath stringByAppendingPathComponent:@"Info.plist"];
            NSMutableDictionary *fwInfo = [NSMutableDictionary dictionaryWithContentsOfFile:fwInfoPath];
            if (fwInfo) {
                // 宿主最终 id 与 base（剥离已存在的 team 后缀）——与下方 App 自身重写逻辑一致。
                NSMutableDictionary *hostInfo = [NSMutableDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
                NSString *hostId = hostInfo[@"CFBundleIdentifier"] ?: @"";
                NSString *teamSuffix = [NSString stringWithFormat:@".%@", teamId];
                NSString *hostBase = hostId;
                while ([hostBase hasSuffix:teamSuffix]) {
                    hostBase = [hostBase substringToIndex:hostBase.length - teamSuffix.length];
                }
                // framework 不注册自己的 App ID，签名时复用宿主 app id（zsign 无 -m 命中则回退第一个
                // -m=宿主 asset）。CFBundleIdentifier 写成「宿主base.fwName」：唯一（多 framework 不重名）、
                // 与宿主/扩展都不重复（避免 installd code=57 DuplicateIdentifier）、且不参与任何 -m 匹配
                //（保持与 Relaxin 一样的"宿主 app id 签名"行为）。
                NSString *fwName = [fwDir stringByDeletingPathExtension];
                NSString *newFwId = [NSString stringWithFormat:@"%@.%@", hostBase, fwName];
                NSString *oldFwId = [fwInfo objectForKey:@"CFBundleIdentifier"] ?: @"";
                if (![oldFwId isEqualToString:newFwId]) {
                    NSLog(@"[ReSign] framework CFBundleIdentifier 改写: %@ -> %@（唯一化，防 code=57 重名；签名复用宿主 app id）",
                          oldFwId, newFwId);
                    [fwInfo setObject:newFwId forKey:@"CFBundleIdentifier"];
                    [fwInfo writeToFile:fwInfoPath atomically:YES];
                }
            }
            // framework 不该带 embedded.mobileprovision（会干扰 installd 校验），历史遗留的清掉。
            NSString *fwProv = [fwPath stringByAppendingPathComponent:@"embedded.mobileprovision"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:fwProv]) {
                [[NSFileManager defaultManager] removeItemAtPath:fwProv error:nil];
                NSLog(@"[ReSign] 已移除 framework 内非法的 embedded.mobileprovision: %@", fwDir);
            }
        }
    }

    // Wait on sub-bundles to finish, if needed.
    dispatch_group_wait(dispatch_group, DISPATCH_TIME_FOREVER);

    if (subBundleErrors.count > 0) {
        // Errors when handling sub-bundles!
        for (NSError *err in subBundleErrors) {
            NSLog(@"Error: %@", err.localizedDescription);
        }

        completionHandler([subBundleErrors lastObject]);
        return;
    }

    // 1. Read Info.plist to gain the applicationId and binaryLocation.
    // 2. Get provisioning profile and certificate info.
    NSString *plistPath = [NSString stringWithFormat:@"%@/Info.plist", path];
    NSMutableDictionary *infoplist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];

    if (!infoplist || [infoplist allKeys].count == 0) {
        NSError *error = [self _errorFromString:@"Failed to open Info.plist!"];
        completionHandler(error);
        return;
    }

    // Find the systemType for this bundle.
    NSString *platformName = [infoplist objectForKey:@"DTPlatformName"];
    EESystemType systemType = -1;
    if ([platformName isEqualToString:@"iphoneos"]) {
        systemType = EESystemTypeiOS;
    } else if ([platformName isEqualToString:@"watchos"]) {
        systemType = EESystemTypewatchOS;
    } else if ([platformName isEqualToString:@"tvos"]) {
        systemType = EESystemTypetvOS;
    } else {
        // Base case, assume iOS.
        systemType = EESystemTypeiOS;
    }

    NSLog(@"Platform: %@ for bundle: %@", platformName, [path lastPathComponent]);

    NSString *applicationId = [infoplist objectForKey:@"CFBundleIdentifier"];
    NSString *embeddedPath = [NSString stringWithFormat:@"%@/embedded.mobileprovision", path];
    BOOL isEmbeddedExists = [[NSFileManager defaultManager] fileExistsAtPath:embeddedPath];

    if (isEmbeddedExists) {
        BOOL isInstalledFromXcode = NO;
        BOOL isInstalledWithAnotherID = NO;

        NSString *profileString = [NSString stringWithContentsOfFile:embeddedPath encoding:NSISOLatin1StringEncoding error:nil];
        NSRange rangeOfTeamId = [profileString rangeOfString:teamId ?: @""];
        NSRange rangeOfXC = [profileString rangeOfString:@"XC "];
        if (rangeOfTeamId.location != NSNotFound && rangeOfXC.location != NSNotFound)
            isInstalledFromXcode = YES;
        else if (![applicationId hasSuffix:teamId]) {
            // application is installed with another apple id
            isInstalledWithAnotherID = YES;
        }

        if (isInstalledFromXcode || isInstalledWithAnotherID) {
            // This process should be done elsewhere and will be changed later
            // but i don't have enough time to understand the structure of this project.
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            [userInfo setObject:applicationId forKey:@"bundleIdentifier"];

            [[NSNotificationCenter defaultCenter] postNotificationName:@"cn.analy.resign/appShouldBeRemoved" object:nil userInfo:userInfo];
        }
    }

    if ([infoplist objectForKey:@"ALTBundleIdentifier"] != nil)
        applicationId = [infoplist objectForKey:@"ALTBundleIdentifier"];
    else if ([infoplist objectForKey:@"REBundleIdentifier"] != nil)
        applicationId = [infoplist objectForKey:@"REBundleIdentifier"];
    else
        [infoplist setObject:applicationId forKey:@"REBundleIdentifier"];

    // 扩展（含 Watch App）必须满足 iOS 硬性规则：CFBundleIdentifier 必须以「宿主 App 的 CFBundleIdentifier + 点」为前缀，
    // 否则 installd 报 MIInstallerErrorDomain code=37 (AppexBundleIDNotPrefixed)。
    // 许多被外部工具加了 Team 后缀的 IPA（lara 类）其扩展 id 形如 com.x.Share.L7KYGKFQ5N，
    // 不以宿主 App 的 com.x.L7KYGKFQ5N. 为前缀 → 安装失败。这里统一改写为「宿主App最终id.扩展目录名」。
    if (isExtension && teamId.length > 0) {
        NSString *containingAppPath = [[path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *containingAppPlist = [containingAppPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *containingInfo = [NSDictionary dictionaryWithContentsOfFile:containingAppPlist];
        NSString *containingAppOriginalId = [containingInfo objectForKey:@"CFBundleIdentifier"];
        if (containingAppOriginalId.length > 0) {
            // 宿主 App 最终 id：与下方 App 自身重写逻辑一致（剥离 team 后缀再追加），避免双后缀。
            NSString *rzTeamSuffix = [NSString stringWithFormat:@".%@", teamId];
            NSString *containingBase = containingAppOriginalId;
            while ([containingBase hasSuffix:rzTeamSuffix]) {
                containingBase = [containingBase substringToIndex:containingBase.length - rzTeamSuffix.length];
            }
            NSString *containingAppFinalId = [containingBase stringByAppendingString:rzTeamSuffix];
            NSString *requiredPrefix = [containingAppFinalId stringByAppendingString:@"."];
            if (![applicationId hasPrefix:requiredPrefix]) {
                NSString *extLocalName = [[path lastPathComponent] stringByDeletingPathExtension];
                NSString *prefixedId = [NSString stringWithFormat:@"%@.%@", containingAppFinalId, extLocalName];
                NSLog(@"[ReSign] 扩展 CFBundleIdentifier 不以宿主 App 前缀，已改写: %@ -> %@（防止 installd AppexBundleIDNotPrefixed）", applicationId, prefixedId);
                [infoplist setObject:prefixedId forKey:@"CFBundleIdentifier"];
                applicationId = prefixedId;
            }
        }
    }

    // 通用规则：剥除 TeamID 后缀再追加，保持 lara 风格宿主 App 的 idempotent（防止双后缀→0xe8008015）。
    // 重要：扩展（isExtension）绝不追加 Team 后缀。扩展 id 形如 hostFinalId.extName，
    // 一旦被追加 ".TEAMID" 会变成 hostFinalId.extName.TEAMID，而扩展的代码签名 application-identifier
    // 必须 == 自身 CFBundleIdentifier 后缀，多出来的 TEAMID 会让二者错位 →
    // installd 报 0xe8008017（A signed resource has been added/modified/deleted）。
    // 这也是「别人用普通 IPA（不含 Team 后缀）带扩展安装失败」的通用根因。
    NSString *teamIdSuffix = [NSString stringWithFormat:@".%@", teamId];
    NSString *baseApplicationId = nil;

    if (isExtension) {
        // 扩展：保持前缀重写后的 id 不变（含 Team 后缀的宿主前缀 + 扩展名，无扩展级 Team 后缀）。
        baseApplicationId = applicationId;
    } else {
        while ([applicationId hasSuffix:teamIdSuffix]) {
            applicationId = [applicationId substringToIndex:applicationId.length - teamIdSuffix.length];
        }
        baseApplicationId = applicationId;
        applicationId = [applicationId stringByAppendingString:teamIdSuffix];
    }
    [infoplist setObject:applicationId forKey:@"CFBundleIdentifier"];

    // ── fix-sign：旧 embedded.mobileprovision 与改写后 bundleID 不匹配时强制刷新 ──
    // 现象（用户实报，repro_log_1785833481）：应用被别人用 lara 类工具签过，其自带的
    // embedded.mobileprovision 的 App ID 带双 Team 后缀（TEAMID.com.x.TEAMID.TEAMID），
    // 而本次签名已把 CFBundleIdentifier 改写为单后缀（TEAMID.com.x.TEAMID）→ 签名后的
    // application-identifier 与旧 profile 不一致 → installd 0xe8008015 → 应用闪退。
    // 这里在下载 profile 前检测到不匹配 → 删除旧 profile 并记日志，让下方流程按改写后的
    // applicationId 重新下载匹配 profile（重签即修复，无需任何手动操作）。
    if (!isExtension && isEmbeddedExists && teamId.length > 0) {
        NSDictionary *oldProf = RZExtractProfilePlist(embeddedPath);
        NSString *oldAid = oldProf[@"Entitlements"][@"application-identifier"];
        NSString *oldTeam = [oldProf[@"TeamIdentifier"] isKindOfClass:[NSArray class]]
            ? [(NSArray *)oldProf[@"TeamIdentifier"] firstObject] : nil;
        BOOL needRefresh = NO;
        if (oldAid.length > 0 && oldTeam.length > 0) {
            NSString *(^stripTeam)(NSString *) = ^NSString *(NSString *s){
                NSString *prefix = [oldTeam stringByAppendingString:@"."];
                if ([s hasPrefix:prefix]) s = [s substringFromIndex:prefix.length];
                NSString *suffix = [@"." stringByAppendingString:oldTeam];
                while ([s hasSuffix:suffix]) s = [s substringToIndex:s.length - suffix.length];
                return s;
            };
            NSString *oldCore = stripTeam(oldAid);          // 旧 profile 的 bundle core
            NSString *newCore = stripTeam(applicationId);   // 本次改写后的 bundle core
            // 注意：oldCore 可能比 newCore 多一个 Team 后缀层（lara 双后缀），
            // 剥完后 oldCore 仍以「newCore.TEAM」结尾时视为同一 app 但 profile 过期 → 刷新。
            needRefresh = ![oldCore isEqualToString:newCore];
        }
        if (needRefresh) {
            NSLog(@"[fix-sign] 旧 embedded.mobileprovision 的 App ID(%@) 与本次 bundleID(%@) 不匹配"
                  @" → 删除旧 profile，按新 id 强制重新下载匹配 profile", oldAid, applicationId);
            [[NSFileManager defaultManager] removeItemAtPath:embeddedPath error:nil];
            isEmbeddedExists = NO;
        }
    }

    NSError *error = nil;
    if (@available(iOS 11.0, *)) {
        [infoplist writeToURL:[NSURL fileURLWithPath:plistPath] error:&error];
    } else {
        // Fallback on earlier versions
        [infoplist writeToURL:[NSURL fileURLWithPath:plistPath] atomically:YES];
    }

    if (error) {
        NSLog(@"%@", error);
        completionHandler(error);
        return;
    }

    NSString *applicationName = [infoplist objectForKey:@"CFBundleName"];
    NSString *binaryLocation = [path stringByAppendingFormat:@"/%@", [infoplist objectForKey:@"CFBundleExecutable"]];

    // 扩展「用主 profile 签名」选项在此对扩展恒为 NO：iOS 硬性要求扩展的代码签名
    // application-identifier 必须是具体值（非通配符 *），通配符 profile（TEAMID.*）无法为扩展
    // 产出合法的具体 app-id，会导致 installd 拒绝（0xe8008017）。故扩展一律走各自注册具体
    // profile 的路径（已修复 id，可正常安装）。该选项对宿主 App 本就不生效（宿主也用各自 profile），
    // 所以实际等价于「标准签名」——保证了安装成功，但无法为扩展省 App ID 配额
    //（免费账号本就拿不到 TEAMID.* 通配符；付费团队需另行评估 zsign 对 * 的替换行为）。
    BOOL useWildcardForExtension = NO;

    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];

    // 通配符 profile 只获取一次，缓存到 context 供多个扩展复用（避免每个扩展重复注册）。
    if (useWildcardForExtension && context[@"wildcardProfile"]) {
        NSData *wp = context[@"wildcardProfile"];
        [wp writeToFile:embeddedPath options:NSDataWritingAtomic error:nil];
        NSString *staged = [self _writeTempData:wp extension:@"mobileprovision" context:context];
        if (staged.length) {
            @synchronized(context) { [context[@"profiles"] addObject:staged]; }
        }
        completionHandler(nil);
        return;
    }

    NSString *provisioningAppId = useWildcardForExtension ? [teamId stringByAppendingString:@".*"] : applicationId;

    [provisioner downloadProvisioningProfileForApplicationIdentifier:provisioningAppId applicationName:applicationName binaryLocation:(NSString *)binaryLocation withTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error, NSData *embeddedMobileProvision, NSString *privateKey, NSDictionary *certificate, NSDictionary *entitlements) {
        if (error) {
            if (useWildcardForExtension) {
                // 通配符获取失败：回退为扩展各自注册（当前行为），不破坏主 App 签名。
                NSLog(@"[ReSign] 扩展通配符 profile 获取失败，回退各自注册: %@", error.localizedDescription);
                [provisioner downloadProvisioningProfileForApplicationIdentifier:applicationId applicationName:applicationName binaryLocation:binaryLocation withTeamIDCheck:^NSString *(NSArray *teams){ return teamId; } systemType:systemType andCallback:^(NSError *error2, NSData *embeddedMobileProvision2, NSString *privateKey2, NSDictionary *certificate2, NSDictionary *entitlements2) {
                    if (error2) { completionHandler(error2); return; }
                    [self _finalizeProvisioningForPath:path embeddedPath:embeddedPath isEmbeddedExists:isEmbeddedExists embeddedMobileProvision:embeddedMobileProvision2 privateKey:privateKey2 certificate:certificate2 entitlements:entitlements2 teamId:teamId baseApplicationId:baseApplicationId context:context completionHandler:completionHandler];
                }];
                return;
            }
            completionHandler(error);
            return;
        }

        if (useWildcardForExtension) {
            context[@"wildcardProfile"] = embeddedMobileProvision; // 缓存供其它扩展复用
        }

        // 主路径（正常 / 通配符成功）继续走下面的 inline finalize。

        // We now have a valid provisioning profile for this application!
        // And, we also have a valid development codesigning certificate, with its private key!

        // Add embedded.mobileprovision to the bundle, overwriting if needed. zsign
        // will re-write this from the -m we pass, but keeping the bundle consistent
        // here is harmless.
        NSError *fileIOError;

        if (isEmbeddedExists) {
            [[NSFileManager defaultManager] removeItemAtPath:embeddedPath error:&fileIOError];

            if (fileIOError) {
                NSLog(@"%@", fileIOError);
                completionHandler(fileIOError);
                return;
            }
        }

        if (![(NSData *)embeddedMobileProvision writeToFile:embeddedPath options:NSDataWritingAtomic error:&fileIOError]) {
            NSError *writeError = fileIOError ?: [self _errorFromString:[NSString stringWithFormat:@"Failed to write '%@'.", embeddedPath]];
            NSLog(@"%@", writeError);
            completionHandler(writeError);
            return;
        }

        // Stage a standalone copy of this profile as an -m argument for zsign, and
        // (once) the shared certificate + private key.
        NSString *stagedProfile = [self _writeTempData:embeddedMobileProvision extension:@"mobileprovision" context:context];
        if (stagedProfile.length == 0) {
            completionHandler([self _errorFromString:@"Failed to stage provisioning profile for signing."]);
            return;
        }

        @synchronized(context) {
            [context[@"profiles"] addObject:stagedProfile];

            if (context[@"keyPath"] == nil) {
                NSData *certificateContent = [[NSData alloc] initWithBase64EncodedString:certificate[@"certificateContent"] options:0];
                NSString *stagedKey = [self _writeTempString:privateKey extension:@"pem" context:context];
                NSString *stagedCert = [self _writeTempData:certificateContent extension:@"cer" context:context];
                if (stagedKey.length && stagedCert.length) {
                    context[@"keyPath"] = stagedKey;
                    context[@"certPath"] = stagedCert;
                }
            }
        }

        // Build the explicit entitlements plist for zsign's -e from EEProvisioning's
// curated `entitlements` dict (which already carries the SPECIFIC
// application-identifier + team-identifier for THIS bundle and only the
// free-account whitelisted keys). Two requirements must be met simultaneously:
//   1. **The application-identifier in the code signature MUST be the SPECIFIC
//      "TEAMID.bundle.id"** — not the wildcard "TEAMID.*" the profile holds for
//      free accounts. Otherwise iOS 17 AMFI rejects and the app launch-crashes.
//      Passing -e with the specific app-id overrides zsign's profile-fallback
//      behaviour.
//   2. **Code-signature entitlements MUST be a STRICT SUBSET of the profile's
//      authorized Entitlements** — otherwise installd rejects the bundle with
//      "0xe8008015 no valid provisioning profile" at install time.
//
//      The free-account profile's whitelist is exactly the 10 keys in
//      EEProvisioning.mm ~line 822 (application-identifier,
//      com.apple.developer.team-identifier, keychain-access-groups,
//      com.apple.security.application-groups, default-data-protection,
//      healthkit, homekit, external-accessory.wireless-configuration,
//      inter-app-audio, get-task-allow). Anything else — including
//      com.apple.security.cs.allow-jit / disable-library-validation /
//      allow-unsigned-executable-memory — is NOT in the profile's whitelist,
//      and installd rejects ANY code signature that contains
//      profile-unauthorized entitlements.
//
// IMPLEMENTATION (v1.3.46, after three iterations of v1.3.42/44/45 tried
// different hypotheses about what was breaking installd):
//   - Output XML plist (NSPropertyListXMLFormat_v1_0) — _writeTempPlist:.
//     Defence-in-depth: zsign's jvalue.read_plist and the raw-bytes
//     passthrough in SlotBuildEntitlements both expect XML plist, so emitting
//     XML avoids any format ambiguity. (v1.3.41 emitted XML via zsign's own
//     style_write_plist when no -e was passed; v1.3.45 then started emitting
//     XML when -e WAS passed too — the format itself is correct.)
//   - **Pass -e with ONLY the whitelist keys** (forwarded from
//     EEProvisioning's curated dict, plus three defensive identity/debug
//     fallbacks). No CS entitlements, no other extras.
//   - Jailbreak tools (TrollFools, Relaxin, Frida, Ellekit, etc.) need
//     com.apple.security.cs.allow-jit / disable-library-validation /
//     allow-unsigned-executable-memory at RUNTIME to JIT / load unsigned
//     dylibs / mmap PROT_EXEC. These ARE NOT in the free-account profile
//     whitelist, so they CANNOT be put in code-signature entitlements
//     without breaking installd. They must instead be granted RUNTIME by the
//     jailbreak system: Dopamine ships libsubstitute (and rootless
//     distributions typically include ellekit) which patches the kernel
//     and libsystem to allow these operations WITHOUT explicit CS
//     entitlements in the app's own code signature. So on a properly
//     jailbroken device the runtime patches make the app work, and on a
//     non-jailbroken device the app is rightfully rejected anyway.
//
// HISTORY (recorded so we don't repeat the cycle):
//   v1.3.42: -e with EEProvisioning whitelist + CS entitlements + binary plist
//     → installd rejects (CS entitlement out-of-whitelist).
//   v1.3.44: -e with EEProvisioning whitelist ONLY + binary plist.
//     → STILL rejected (vl.3.44 author blamed binary plist; that was wrong).
//   v1.3.45: -e with EEProvisioning whitelist + CS entitlements + XML plist.
//     → STILL rejected (CS entitlement out-of-whitelist overrides any format fix).
//   v1.3.46 (this): -e with EEProvisioning whitelist ONLY + XML plist.
//     → expected to install cleanly. CS entitlement is a runtime concern,
//       handled by libsubstitute on the jailbroken device.
        NSMutableDictionary *rzEntitlements = [entitlements isKindOfClass:[NSDictionary class]] ? [entitlements mutableCopy] : [NSMutableDictionary dictionary];
        if (useWildcardForExtension) {
            // 通配符 profile 的 entitlements 里 application-identifier 是 "TEAMID.*"，
            // 但扩展自身真正的 bundle id 是 TEAMID.<baseApplicationId>。这里强制写成具体值：
            // 扩展的实际签名 application-identifier 必须是自身 bundle id，而通配 profile
            // （TEAMID.*）恰好授权任意 TEAMID.* 子项，所以是合法的子集（与根 -e 一致）。
            rzEntitlements[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, baseApplicationId];
        }
        if (rzEntitlements[@"application-identifier"] == nil) {
            rzEntitlements[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, baseApplicationId];
        }
        if (rzEntitlements[@"com.apple.developer.team-identifier"] == nil) {
            rzEntitlements[@"com.apple.developer.team-identifier"] = teamId;
        }
        if (rzEntitlements[@"get-task-allow"] == nil) {
            rzEntitlements[@"get-task-allow"] = @YES;
        }

        NSString *stagedEntitlements = [self _writeTempPlist:rzEntitlements context:context];

        // The root bundle's entitlements also land in context[@"entitlementsPath"];
        // the root callback runs last (after the sub-bundle recursion), so it wins.
        @synchronized(context) {
            if (stagedEntitlements.length) {
                context[@"entitlementsPath"] = stagedEntitlements;
            }
        }

        completionHandler(nil);
    }];
}

// 把已获取到的 profile/证书/entitlements 写入 bundle 并暂存供 zsign 使用。
// 单一收口，供正常流程与「扩展用主 profile（通配符）」回退流程共用，避免重复实现导致签名不一致。
+ (void)_finalizeProvisioningForPath:(NSString *)path
                       embeddedPath:(NSString *)embeddedPath
                   isEmbeddedExists:(BOOL)isEmbeddedExists
           embeddedMobileProvision:(NSData *)embeddedMobileProvision
                        privateKey:(NSString *)privateKey
                        certificate:(NSDictionary *)certificate
                       entitlements:(NSDictionary *)entitlements
                            teamId:(NSString *)teamId
                   baseApplicationId:(NSString *)baseApplicationId
                            context:(NSMutableDictionary *)context
                  completionHandler:(void (^)(NSError *))completionHandler {
    NSError *fileIOError;

    if (isEmbeddedExists) {
        [[NSFileManager defaultManager] removeItemAtPath:embeddedPath error:&fileIOError];
        if (fileIOError) {
            NSLog(@"%@", fileIOError);
            completionHandler(fileIOError);
            return;
        }
    }

    if (![(NSData *)embeddedMobileProvision writeToFile:embeddedPath options:NSDataWritingAtomic error:&fileIOError]) {
        NSError *writeError = fileIOError ?: [self _errorFromString:[NSString stringWithFormat:@"Failed to write '%@'.", embeddedPath]];
        NSLog(@"%@", writeError);
        completionHandler(writeError);
        return;
    }

    NSString *stagedProfile = [self _writeTempData:embeddedMobileProvision extension:@"mobileprovision" context:context];
    if (stagedProfile.length == 0) {
        completionHandler([self _errorFromString:@"Failed to stage provisioning profile for signing."]);
        return;
    }

    @synchronized(context) {
        [context[@"profiles"] addObject:stagedProfile];
        if (context[@"keyPath"] == nil) {
            NSData *certificateContent = [[NSData alloc] initWithBase64EncodedString:certificate[@"certificateContent"] options:0];
            NSString *stagedKey = [self _writeTempString:privateKey extension:@"pem" context:context];
            NSString *stagedCert = [self _writeTempData:certificateContent extension:@"cer" context:context];
            if (stagedKey.length && stagedCert.length) {
                context[@"keyPath"] = stagedKey;
                context[@"certPath"] = stagedCert;
            }
        }
    }

    NSMutableDictionary *rzEntitlements = [entitlements isKindOfClass:[NSDictionary class]] ? [entitlements mutableCopy] : [NSMutableDictionary dictionary];
    if (rzEntitlements[@"application-identifier"] == nil) {
        rzEntitlements[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, baseApplicationId];
    }
    if (rzEntitlements[@"com.apple.developer.team-identifier"] == nil) {
        rzEntitlements[@"com.apple.developer.team-identifier"] = teamId;
    }
    if (rzEntitlements[@"get-task-allow"] == nil) {
        rzEntitlements[@"get-task-allow"] = @YES;
    }

    NSString *stagedEntitlements = [self _writeTempPlist:rzEntitlements context:context];
    @synchronized(context) {
        if (stagedEntitlements.length) {
            context[@"entitlementsPath"] = stagedEntitlements;
        }
    }

    completionHandler(nil);
}

// Writes `data` to a uniquely-named file in the temporary directory and records
// it in context[@"tempFiles"] for later cleanup. Returns the path, or nil on
// failure.
+ (NSString *)_writeTempData:(NSData *)data extension:(NSString *)ext context:(NSMutableDictionary *)context {
    if (data.length == 0) return nil;

    NSString *tmp = [NSString stringWithFormat:@"%@rpv_%@.%@", NSTemporaryDirectory(), [[NSUUID UUID] UUIDString], ext];
    NSError *err = nil;
    if (![data writeToFile:tmp options:NSDataWritingAtomic error:&err]) {
        NSLog(@"Failed to stage temp file '%@': %@", tmp, err);
        return nil;
    }

    @synchronized(context) {
        [context[@"tempFiles"] addObject:tmp];
    }
    return tmp;
}

+ (NSString *)_writeTempString:(NSString *)string extension:(NSString *)ext context:(NSMutableDictionary *)context {
    return [self _writeTempData:[string dataUsingEncoding:NSUTF8StringEncoding] extension:ext context:context];
}

// Serialises an entitlements dictionary to a temporary .plist and records it in
// context[@"tempFiles"] for later cleanup. Returns the path, or nil on failure.
//
// IMPORTANT: emits XML plist (NSPropertyListXMLFormat_v1_0), NOT binary plist.
// zsign's `jvalue.read_plist(strEntitlements)` in SlotBuildDerEntitlements
// (signing.cpp:322) and the raw-bytes passthrough in SlotBuildEntitlements
// (signing.cpp:297) both expect XML plist input. Passing a binary plist here
// leaves the code signature's __TEXT,__entitlements section as unreadable bytes,
// and iOS 17 installd rejects with "0xe8008015 no valid provisioning profile"
// (observed in v1.3.42–v1.3.44). v1.3.41 worked because zsign itself wrote
// the profile's Entitlements via `style_write_plist` (XML) when no -e was
// passed, so the format was always XML.
+ (NSString *)_writeTempPlist:(NSDictionary *)dict context:(NSMutableDictionary *)context {
    if (dict.count == 0) return nil;

    NSString *tmp = [NSString stringWithFormat:@"%@rpv_ent_%@.plist", NSTemporaryDirectory(), [[NSUUID UUID] UUIDString]];

    NSError *err = nil;
    NSData *xmlData = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&err];
    if (xmlData == nil) {
        NSLog(@"Failed to serialise entitlements as XML plist: %@", err);
        return nil;
    }
    if (![xmlData writeToFile:tmp options:NSDataWritingAtomic error:&err]) {
        NSLog(@"Failed to stage entitlements plist '%@': %@", tmp, err);
        return nil;
    }

    @synchronized(context) {
        [context[@"tempFiles"] addObject:tmp];
    }
    return tmp;
}

+ (void)_cleanupTempFilesInContext:(NSMutableDictionary *)context {
    @synchronized(context) {
        for (NSString *p in context[@"tempFiles"]) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
        [context[@"tempFiles"] removeAllObjects];
    }
}

+ (void)signIpaAtPath:(NSString *)ipaPath outputPath:(NSString *)outputPath identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId withCompletionHandler:(void (^)(NSError *))completionHandler {
    // 1. Unpack IPA to a temporary directory.
    NSError *error;
    NSString *unpackedDirectory;
    if (![self unpackIpaAtPath:ipaPath outDirectory:&unpackedDirectory error:&error]) {
        completionHandler(error);
        return;
    }

    // 2. Sign its main bundle via above method.
    // The bundle will be located at <temporarydirectory>/<zipfilename>/Payload/*.app internally

    NSString *zipFilename = [ipaPath lastPathComponent];
    zipFilename = [zipFilename stringByReplacingOccurrencesOfString:@".ipa" withString:@""];

    NSString *payloadDirectory = [NSString stringWithFormat:@"%@/Payload", unpackedDirectory];

    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDirectory error:&error];

    if (error) {
        completionHandler(error);
        return;
    } else if (files.count == 0) {
        NSError *err = [self _errorFromString:@"Payload directory of IPA has no contents"];
        completionHandler(err);
        return;
    }

    NSString *dotAppDirectory = @"";
    for (NSString *directory in files) {
        if ([directory containsString:@".app"]) {
            dotAppDirectory = directory;
            break;
        }
    }

    NSString *bundleDirectory = [NSString stringWithFormat:@"%@/%@", payloadDirectory, dotAppDirectory];

    NSLog(@"Signing bundle at path '%@'", bundleDirectory);

    [self signBundleAtPath:bundleDirectory identity:identity gsToken:gsToken priorChosenTeamID:teamId withCompletionHandler:^(NSError *err) {
        if (err) {
            completionHandler(err);
            return;
        }

        // 3. Repack IPA to output path
        NSError *error2;
        if (![self repackIpaAtPath:[NSString stringWithFormat:@"%@/%@", [self applicationTemporaryDirectory], zipFilename] toPath:outputPath error:&error2]) {
            completionHandler(error2);
        } else {
            // Success!
            completionHandler(nil);
        }
    }];
}

+ (BOOL)unpackIpaAtPath:(NSString *)ipaPath outDirectory:(NSString **)outputDirectory error:(NSError **)error {
    // Sanity checks.
    if (![ipaPath hasSuffix:@".ipa"]) {
        if (error)
            *error = [self _errorFromString:@"Input file specified is not an IPA!"];
        return NO;
    }

    if (!outputDirectory) {
        if (error)
            *error = [self _errorFromString:@"No outputDirectory; how will you know where the IPA was extracted to?"];
        return NO;
    }

    NSString *zipFilename = [ipaPath lastPathComponent];
    zipFilename = [zipFilename stringByReplacingOccurrencesOfString:@".ipa" withString:@""];

    *outputDirectory = [NSString stringWithFormat:@"%@/%@", [self applicationTemporaryDirectory], zipFilename];

    NSLog(@"Unpacking '%@' into directory '%@'", ipaPath, *outputDirectory);

    if (![SSZipArchive unzipFileAtPath:ipaPath toDestination:*outputDirectory]) {
        if (error)
            *error = [self _errorFromString:@"Failed to unpack IPA!"];
        return NO;
    }

    return YES;
}

+ (BOOL)repackIpaAtPath:(NSString *)extractedPath toPath:(NSString *)outputPath error:(NSError **)error {
    // Sanity checks.
    if (![outputPath hasSuffix:@".ipa"]) {
        if (error)
            *error = [self _errorFromString:@"Output file specified is not an IPA!"];
        return NO;
    }

    NSLog(@"Creating IPA from contents of '%@", extractedPath);

    // Ensure permissions are at least read on everyone.


    if (![SSZipArchive createZipFileAtPath:outputPath withContentsOfDirectory:extractedPath]) {
        if (error)
            *error = [self _errorFromString:@"Failed to repack IPA!"];
        return NO;
    }

    return YES;
}

+ (NSString *)applicationTemporaryDirectory {
    NSString *tempDir = NSTemporaryDirectory();
    if (!tempDir)
        tempDir = @"/tmp";

    if (![[NSFileManager defaultManager] fileExistsAtPath:tempDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:tempDir withIntermediateDirectories:NO attributes:nil error:nil];
    }

    return tempDir;
}

+ (NSError *)_errorFromString:(NSString *)string {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:-1
                                     userInfo:userInfo];

    return error;
}

@end
