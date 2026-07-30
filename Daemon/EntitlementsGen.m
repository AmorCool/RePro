//
//  EntitlementsGen.m
//  ReProvision Daemon
//
//  免费账户白名单 entitlements（10 项）：
//  installd 校验：code signature 中的 entitlement 必须是 profile 授权子集
//  超出白名单的键 → 0xe8008015 未找到有效的配置描述文件
//

#import "EntitlementsGen.h"

@implementation EntitlementsGen

/// 免费账户允许的 entitlement 键白名单
static NSArray<NSString *> *freeAccountAllowedEntitlements(void) {
    static NSArray *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"application-identifier",
            @"com.apple.developer.team-identifier",
            @"keychain-access-groups",
            @"com.apple.security.application-groups",
            @"com.apple.developer.default-data-protection",
            @"com.apple.developer.healthkit",
            @"com.apple.developer.homekit",
            @"com.apple.external-accessory.wireless-configuration",
            @"inter-app-audio",
            @"get-task-allow"
        ];
    });
    return keys;
}

- (NSString *)generateForBundleID:(NSString *)bundleID
                               teamID:(NSString *)teamID
                                 error:(NSError **)error {
    // 构建基础 entitlements 字典
    NSMutableDictionary *ents = [NSMutableDictionary dictionary];

    // 核心身份 entitlements（必须存在）
    ents[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamID, bundleID];
    ents[@"com.apple.developer.team-identifier"] = teamID;
    ents[@"get-task-allow"] = @YES;

    // 序列化为 XML plist（zsign 要求 XML 格式，不接受 binary plist）
    NSError *serializeError = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:ents
                                                                        format:NSPropertyListXMLFormat_v1_0
                                                                       options:0
                                                                         error:&serializeError];
    if (!plistData || serializeError) {
        if (error) *error = serializeError;
        return nil;
    }

    // 写入临时文件
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"repro_ent_%@.plist", [[NSUUID UUID] UUIDString]]];
    BOOL success = [plistData writeToFile:tempPath atomically:YES];
    if (!success) {
        if (error) *error = [NSError errorWithDomain:@"RePro" code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"无法写入 entitlements 临时文件"
        }];
        return nil;
    }

    return tempPath;
}

- (NSDictionary<NSString *, id> *)filteredEntitlementsFromOriginal:(NSDictionary<NSString *, id> *)original
                                                           teamID:(NSString *)teamID
                                                      baseAppID:(NSString *)baseAppID {
    NSMutableArray<NSString *> *allowedKeys = [freeAccountAllowedEntitlements() mutableCopy];

    NSMutableDictionary *filtered = [NSMutableDictionary dictionary];

    for (NSString *key in original) {
        if ([allowedKeys containsObject:key]) {
            filtered[key] = original[key];
        }
        // 其他键静默丢弃（不在白名单中）
    }

    // 确保核心身份字段存在
    if (!filtered[@"application-identifier"]) {
        filtered[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamID, baseAppID];
    }
    if (!filtered[@"com.apple.developer.team-identifier"]) {
        filtered[@"com.apple.developer.team-identifier"] = teamID;
    }
    if (!filtered[@"get-task-allow"]) {
        filtered[@"get-task-allow"] = @YES;
    }

    return filtered;
}

@end
