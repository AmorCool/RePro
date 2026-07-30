//
//  EntitlementsGen.h/m
//  ReProvision Daemon
//
//  Entitlements 生成器：
//  - 基于免费账户白名单过滤 entitlements
//  - 输出 XML plist 格式（zsign 要求）
//  - 自动注入 application-identifier、team-identifier、get-task-allow
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EntitlementsGen : NSObject

/// 为指定 bundle ID 和 Team ID 生成 entitlements plist 文件路径
/// 返回临时文件路径，调用者负责清理
- (nullable NSString *)generateForBundleID:(NSString *)bundleID
                                       teamID:(NSString *)teamID
                                         error:(NSError **)error;

/// 从原始 entitlements 字典中过滤出免费账户允许的键
- (NSDictionary<NSString *, id> *)filteredEntitlementsFromOriginal:(NSDictionary<NSString *, id> *)original
                                                            teamID:(NSString *)teamID
                                                       baseAppID:(NSString *)baseAppID;

@end

NS_ASSUME_NONNULL_END
