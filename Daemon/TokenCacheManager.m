//
//  TokenCacheManager.m
//  ReProvision Daemon
//

#import "TokenCacheManager.h"

static NSString *const kTokenCachePath = @"/var/mobile/Library/ReProvision/token_cache.bin";

@implementation CachedToken

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.bundleID forKey:@"bundleID"];
    [coder encodeObject:self.certData forKey:@"certData"];
    [coder encodeObject:self.profileData forKey:@"profileData"];
    [coder encodeInt64:self.expiresAt forKey:@"expiresAt"];
    [coder encodeBool:self.isValid forKey:@"isValid"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.bundleID = [coder decodeObjectForKey:@"bundleID"] ?: @"";
        self.certData = [coder decodeObjectForKey:@"certData"];
        self.profileData = [coder decodeObjectForKey:@"profileData"];
        self.expiresAt = [coder decodeInt64ForKey:@"expiresAt"];
        self.isValid = [coder decodeBoolForKey:@"isValid"];
    }
    return self;
}

@end

#pragma mark -

@interface TokenCacheManager ()
@property (nonatomic, strong) NSMutableArray<CachedToken *> *tokens;
@end

@implementation TokenCacheManager

+ (instancetype)sharedManager {
    static TokenCacheManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TokenCacheManager alloc] init];
        [instance loadFromDisk];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tokens = [NSMutableArray arrayWithCapacity:MAX_CACHED_TOKENS];
    }
    return self;
}

- (CachedToken *)validTokenForBundleID:(NSString *)bundleID {
    int64_t now = (int64_t)[[NSDate date] timeIntervalSince1970];

    for (CachedToken *token in self.tokens) {
        if ([token.bundleID isEqualToString:bundleID] &&
            token.isValid &&
            token.expiresAt > now) {
            return token;
        }
    }
    return nil;
}

- (NSUInteger)validTokenCount {
    int64_t now = (int64_t)[[NSDate date] timeIntervalSince1970];
    NSUInteger count = 0;
    for (CachedToken *token in self.tokens) {
        if (token.isValid && token.expiresAt > now) count++;
    }
    return count;
}

- (NSInteger)preSignTokens:(NSInteger)count {
    NSInteger signedCount = 0;
    int64_t now = (int64_t)[[NSDate date] timeIntervalSince1970];

    for (CachedToken *token in self.tokens) {
        if (!token.isValid || token.expiresAt <= now) {
            // 复用这个槽位申请新证书
            // TODO: 调用 EEProvisioning 申请新证书
            // 这里先模拟成功
            token.expiresAt = now + TOKEN_VALIDITY_SECONDS;
            token.isValid = YES;
            signedCount++;

            if (signedCount >= count) break;
        }
    }

    // 如果还有空位，创建新条目
    while (signedCount < count && self.tokens.count < MAX_CACHED_TOKENS) {
        CachedToken *token = [[CachedToken alloc] init];
        token.bundleID = [NSString stringWithFormat:@"presigned_%ld", (long)self.tokens.count];
        token.expiresAt = now + TOKEN_VALIDITY_SECONDS;
        token.isValid = YES;
        [self.tokens addObject:token];
        signedCount++;
    }

    [self saveToDisk];
    NSLog(@"[RePro] 预签完成: %ld 个新 Token", (long)signedCount);
    return signedCount;
}

- (NSInteger)refreshExpiredTokens {
    int64_t now = (int64_t)[[NSDate date] timeIntervalSince1970];
    NSInteger refreshed = 0;

    for (CachedToken *token in self.tokens) {
        if (token.isValid && token.expiresAt <= now) {
            // TODO: 用缓存的认证会话刷新 Token
            token.expiresAt = now + TOKEN_VALIDITY_SECONDS;
            refreshed++;
        }
    }

    if (refreshed > 0) [self saveToDisk];
    return refreshed;
}

- (void)clearAll {
    [self.tokens removeAllObjects];
    [self saveToDisk];
}

- (void)saveToDisk {
    NSString *dir = [kTokenCachePath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                          withIntermediateDirectories:YES attributes:nil error:nil];
    [NSKeyedArchiver archiveRootObject:self.tokens toFile:kTokenCachePath];
}

- (void)loadFromDisk {
    NSArray *loaded = [NSKeyedUnarchiver unarchiveObjectWithFile:kTokenCachePath];
    if ([loaded isKindOfClass:[NSArray class]]) {
        self.tokens = [loaded mutableCopy];
    }
}

@end
