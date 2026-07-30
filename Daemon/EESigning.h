//
//  EESigning.h/m
//  ReProvision Daemon
//
//  ldid 内嵌签名接口（从旧项目 EESigning.mm 移植）
//  方案一（ldid 模式）使用此接口进行签名
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EESigning : NSObject

/// 使用 ldid 对 .app bundle 进行内嵌签名
+ (BOOL)signAppBundle:(NSString *)appPath
       certificateData:(NSData *)certData
              keyData:(NSData *)keyData
   entitlementsString:(nullable NSString *)entitlementsString
      provisioningPaths:(NSArray<NSString *> *)provPaths
             useSHA256:(BOOL)useSHA256
                 error:(NSError **)error;

/// 使用 ldid::Analyze() 分析二进制的原始 entitlements
+ (nullable NSDictionary *)analyzeEntitlementsFromBinaryAtPath:(NSString *)binaryPath
                                                      error:(NSError **)error;

/// 从二进制提取 entitlements 并更新 application-identifier / team-identifier
+ (NSDictionary *)updateEntitlementsForBinaryAtLocation:(NSString *)binaryLocation
                                       bundleIdentifier:(NSString *)bundleIdentifier
                                                  teamID:(NSString *)teamid;

@end

NS_ASSUME_NONNULL_END
