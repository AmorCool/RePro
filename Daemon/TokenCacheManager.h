//
//  TokenCacheManager.h/m
//  ReProvision Daemon
//
//  Token 缓存与预签管理：
//  - 预签多个 7 天有效证书
//  - 磁盘持久化
//  - 离线可用
//

#import <Foundation/Foundation.h>

#define MAX_CACHED_TOKENS 10
#define TOKEN_VALIDITY_SECONDS (7 * 24 * 3600) // 7 天

NS_ASSUME_NONNULL_BEGIN

/// 缓存的 Token 条目
@interface CachedToken : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) NSData *certData;
@property (nonatomic, strong) NSData *profileData;
@property (nonatomic, assign) int64_t expiresAt;
@property (nonatomic, assign) BOOL isValid;
@end

/// Token 缓存管理器
@interface TokenCacheManager : NSObject

+ (instancetype)sharedManager;

/// 获取指定 bundle ID 的有效 Token
- (nullable CachedToken *)validTokenForBundleID:(NSString *)bundleID;

/// 预签 N 个 Token
- (NSInteger)preSignTokens:(NSInteger)count;

/// 获取所有有效 Token 数量
- (NSUInteger)validTokenCount;

/// 刷新过期 Token
- (NSInteger)refreshExpiredTokens;

/// 清除所有缓存
- (void)clearAll;

/// 持久化到磁盘
- (void)saveToDisk;

/// 从磁盘加载
- (void)loadFromDisk;

@end

NS_ASSUME_NONNULL_END
