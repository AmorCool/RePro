//
//  RPVApplication.m
//  iOS
//
//  Created by Matt Clarke on 09/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVApplication.h"

#pragma mark - 系统描述文件库兜底（仅 rootless/rootful；roothide 不查，保持原行为）

// 系统库 profile(application-identifier) → 到期日 的缓存，按目录 mtime 失效。
static NSDictionary<NSString *, NSDate *> *gSystemStoreCache = nil;
static NSTimeInterval gSystemStoreCacheMtime = 0;
static dispatch_queue_t gSystemStoreQueue = NULL;

@interface _LSDiskUsage : NSObject
@property (nonatomic, readonly) NSNumber *dynamicUsage;
@property (nonatomic, readonly) NSNumber *onDemandResourcesUsage;
@property (nonatomic, readonly) NSNumber *sharedUsage;
@property (nonatomic, readonly) NSNumber *staticUsage;
@end

@interface LSApplicationProxy : NSObject

@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) _LSDiskUsage *diskUsage;
@property (nonatomic, readonly) NSString *shortVersionString;
@property (nonatomic, readonly) NSNumber *staticDiskUsage;

+ (instancetype)applicationProxyForIdentifier:(NSString *)arg1;

- (id)localizedName;
- (id)primaryIconDataForVariant:(int)arg1;
- (id)iconDataForVariant:(int)arg1;
@end

@interface UIImage (Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface RPVApplication ()
@property (nonatomic, strong) LSApplicationProxy *proxy;
@end

@implementation RPVApplication

- (instancetype)initWithApplicationProxy:(LSApplicationProxy *)proxy {
    self = [super init];

    if (self) {
        self.proxy = proxy;
    }

    return self;
}

- (NSString *)bundleIdentifier {
    return self.proxy != nil ? self.proxy.applicationIdentifier : @"com.mycompany.example";
}

- (NSString *)applicationName {
    return self.proxy != nil ? [self.proxy localizedName] : @"Example";
}

- (NSString *)applicationVersion {
    return self.proxy != nil ? [self.proxy shortVersionString] : @"1.0";
}

- (NSNumber *)applicationInstalledSize {
    if (!self.proxy) {
        return @0;
    }

    if ([self.proxy respondsToSelector:@selector(diskUsage)])
        return [self.proxy.diskUsage staticUsage];
    else
        return self.proxy.staticDiskUsage;
}

- (UIImage *)applicationIcon {
    UIImage *icon;

    if (self.proxy != nil) {
        icon = [UIImage _applicationIconImageForBundleIdentifier:[self bundleIdentifier] format:2 scale:[UIScreen mainScreen].scale];
    } else {
        icon = [UIImage imageNamed:@"AppIcon40x40"];
    }

    return icon;
}

- (UIImage *)tvOSApplicationIcon {
    return [UIImage _applicationIconImageForBundleIdentifier:[self bundleIdentifier] format:2 scale:[UIScreen mainScreen].scale];
}

- (BOOL)_provisioningProfileReallyExists {
    // Get provisioning file from app
    NSString *appProvisioningPath = [[self.proxy.bundleURL path] stringByAppendingString:@"/embedded.mobileprovision"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:appProvisioningPath]) return NO;

    NSDictionary *appProvisioningFile = [RPVApplication provisioningProfileAtPath:appProvisioningPath];
    if (![appProvisioningFile isKindOfClass:[NSDictionary class]] || appProvisioningFile.count == 0) return NO;

    // Historically we cross-checked the embedded profile against the system store at
    // /var/MobileDevice/ProvisioningProfiles to make sure it is still installed.
    // On iOS 15+/rootless that directory typically can't be enumerated from here, so
    // the strict isEqualToDictionary check failed for EVERY app and made even
    // perfectly valid apps report as "expired". Match by the profile UUID when we can
    // read the store, and otherwise trust the app's own embedded profile.
    NSString *profilesFolderPath = @"/var/MobileDevice/ProvisioningProfiles";
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:profilesFolderPath error:nil];

    if (contents.count == 0) {
        // Can't verify against the system store - trust the embedded profile.
        return YES;
    }

    NSString *appUUID = [appProvisioningFile objectForKey:@"UUID"];
    for (NSString *file in contents) {
        NSString *filePath = [profilesFolderPath stringByAppendingPathComponent:file];
        NSDictionary *provisioningProfile = [RPVApplication provisioningProfileAtPath:filePath];
        if (![provisioningProfile isKindOfClass:[NSDictionary class]]) continue;

        NSString *uuid = [provisioningProfile objectForKey:@"UUID"];
        if (appUUID.length > 0 && [appUUID isEqualToString:uuid]) return YES;
        if ([appProvisioningFile isEqualToDictionary:provisioningProfile]) return YES;
    }

    // We could read the store but found no match. The profile may live elsewhere on
    // this OS; be lenient and trust the embedded profile's own ExpirationDate rather
    // than forcing an incorrect "expired" state.
    return YES;
}

- (NSDate *)applicationExpiryDate {
    NSString *provisionPath = [[self.proxy.bundleURL path] stringByAppendingString:@"/embedded.mobileprovision"];

    // 无 proxy 或根本没有 embedded.mobileprovision：尝试用系统描述文件库兜底，
    // 已安装且系统库里仍有有效 profile 的应用不应被误判为过期。
    if (!self.proxy || ![[NSFileManager defaultManager] fileExistsAtPath:provisionPath]) {
        NSDate *sys = [self _systemStoreExpiryDateForBundle:[self bundleIdentifier]];
        return sys ?: [NSDate date];
    }

    NSDictionary *provision = [RPVApplication provisioningProfileAtPath:provisionPath];
    if (!provision || !self._provisioningProfileReallyExists) {
        NSDate *sys = [self _systemStoreExpiryDateForBundle:[self bundleIdentifier]];
        return sys ?: [NSDate date];
    }

    NSDate *embedded = [provision objectForKey:@"ExpirationDate"];
    if (embedded && [embedded isKindOfClass:[NSDate class]] && [embedded compare:[NSDate date]] == NSOrderedDescending) {
        return embedded; // 内嵌 profile 仍有效，直接用
    }

    // 内嵌已过期（或缺失日期）：看系统描述文件库里是否有匹配本 bundle 的有效 profile。
    // 例如用户用本机 Apple ID 重签后系统库已写入有效 profile，但 bundle 内 embedded 未更新，
    // 此时应用实际仍可运行，应按系统库的有效日期显示，避免「明明在有效期却显示已过期」。
    NSDate *sys = [self _systemStoreExpiryDateForBundle:[self bundleIdentifier]];
    if (sys && [sys compare:[NSDate date]] == NSOrderedDescending) {
        return sys;
    }

    return embedded ?: [NSDate date];
}

/// 在系统描述文件库（/var/Managed Preferences/mobile）中查找匹配本 bundle 且仍有效的 profile 到期日。
/// 命中返回最晚的有效到期日；无匹配 / 全部过期 / 无法读取返回 nil。
/// 🔀 v2.1.29：原 RootHide 规避分支（.jbroot 存在则直接返回 nil）已移除 ——
/// main 只出 rootless/rootful，两者都能直接看到真实的系统描述文件库。
- (NSDate *)_systemStoreExpiryDateForBundle:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;

    NSDictionary<NSString *, NSDate *> *map = [self _systemStoreMapForDir:@"/var/Managed Preferences/mobile"];
    if (map.count == 0) return nil;

    NSString *suffix = [@"." stringByAppendingString:bundleID];
    NSDate *best = nil;
    NSDate *now = [NSDate date];
    for (NSString *appID in map) {
        // 匹配：appID 以 .<bundleID> 结尾（teamID.bundleID），或为通配符 teamID.*
        BOOL match = [appID hasSuffix:suffix] || [appID hasSuffix:@".*"];
        if (!match) continue;
        NSDate *exp = map[appID];
        if ([exp compare:now] == NSOrderedDescending &&
            (!best || [exp compare:best] == NSOrderedDescending)) {
            best = exp;
        }
    }
    return best;
}

/// 解析系统描述文件库为 {application-identifier: ExpirationDate}，带按目录 mtime 失效的缓存。
- (NSDictionary<NSString *, NSDate *> *)_systemStoreMapForDir:(NSString *)dir {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gSystemStoreQueue = dispatch_queue_create("com.reprovision.systemstore", DISPATCH_QUEUE_SERIAL);
    });

    __block NSDictionary *result = nil;
    dispatch_sync(gSystemStoreQueue, ^{
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:dir error:nil];
        NSTimeInterval mtime = attrs ? [attrs[NSFileModificationDate] timeIntervalSince1970] : 0;
        if (gSystemStoreCache && mtime == gSystemStoreCacheMtime) {
            result = gSystemStoreCache;
            return;
        }
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            if (![file hasSuffix:@".mobileprovision"] && ![file hasSuffix:@".provisionprofile"]) continue;
            NSDictionary *plist = [RPVApplication provisioningProfileAtPath:[dir stringByAppendingPathComponent:file]];
            if (![plist isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *ents = plist[@"Entitlements"];
            NSString *appID = ents[@"application-identifier"];
            NSDate *exp = plist[@"ExpirationDate"];
            if ([appID isKindOfClass:[NSString class]] && [exp isKindOfClass:[NSDate class]]) {
                map[appID] = exp;
            }
        }
        gSystemStoreCache = [map copy];
        gSystemStoreCacheMtime = mtime;
        result = gSystemStoreCache;
    });
    return result;
}

- (BOOL)hasEmbeddedMobileprovision {
    if (!self.proxy) {
        return NO;
    }

    NSString *provisionPath = [[self.proxy.bundleURL path] stringByAppendingString:@"/embedded.mobileprovision"];
    return [[NSFileManager defaultManager] fileExistsAtPath:provisionPath];
}

- (NSURL *)locationOfApplicationOnFilesystem {
    return self.proxy.bundleURL;
}

+ (NSDictionary *)provisioningProfileAtPath:(NSString *)path {
    NSError *err;
    // A .mobileprovision is a PKCS#7/CMS container with bytes > 127, so reading it as
    // strict ASCII returns nil and the whole parse silently fails (making every app
    // look "expired"). ISO Latin-1 maps all 256 byte values and never fails; the
    // <plist> payload itself is ASCII XML, so extraction stays correct.
    NSString *stringContent = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:&err];
    if (stringContent.length == 0) {
        return @{};
    }

    NSString *startMarker = @"<plist";
    NSString *endMarker = @"</plist>";

    NSRange startRange = [stringContent rangeOfString:startMarker];
    if (startRange.location == NSNotFound) {
        return @{};
    }

    // 关键修复：只在 <plist> 之后搜索闭合标签。.mobileprovision 是二进制 CMS 容器，
    // 其二进制前缀里常有「碰巧」长得像 </plist> 的字节序列，排在真正的 XML payload 之前。
    // 若对整个字符串取第一个 </plist>，会得到 end < start，算出的 length 为负，
    // 传给 substringWithRange: 会让 CoreFoundation 触发
    // "CFString cannot be created from a negative number of bytes" 直接 trap（首次启动必崩）。
    NSRange searchRange = NSMakeRange(startRange.location, stringContent.length - startRange.location);
    NSRange endRange = [stringContent rangeOfString:endMarker options:0 range:searchRange];
    if (endRange.location == NSNotFound) {
        return @{};
    }

    NSInteger length = (NSInteger)(endRange.location + endMarker.length) - (NSInteger)startRange.location;
    if (length <= 0) {
        return @{};
    }
    NSRange sliceRange = NSMakeRange(startRange.location, (NSUInteger)length);
    if (NSMaxRange(sliceRange) > stringContent.length) {
        return @{};
    }

    stringContent = [stringContent substringWithRange:sliceRange];

    NSData *stringData = [stringContent dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error;
    NSPropertyListFormat format;

    @try {
        id plist = [NSPropertyListSerialization propertyListWithData:stringData options:NSPropertyListImmutable format:&format error:&error];
        return plist;
    } @catch (NSException *e) {
        NSLog(@"*** ReProvision :: Failed to parse plist: %@, %@", e, stringData);
        return @{};
    }
}

@end
