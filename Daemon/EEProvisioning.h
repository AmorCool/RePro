//
//  EEProvisioning.h
//  ReProvision Daemon
//
//  Apple Developer Portal 交互模块（从旧项目移植的精简版）
//  功能：Apple ID 登录(SRP)、证书申请(CSR)、profile 下载
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EEProvisioning : NSObject

/// 当前 Team ID
@property (nonatomic, copy, readonly) NSString *teamID;

/// Apple ID 认证（SRP 协议，注入本地 Anisette 数据）
- (BOOL)authenticateWithAppleID:(NSString *)appleID
                         password:(NSString *)password
                            error:(NSError **)error;

/// 为指定 bundle ID 申请证书和 profile
- (BOOL)requestCertificateForBundleID:(NSString *)bundleID
                               certPathOut:(NSString * _Nullable * _Nullable)certPath
                                keyPathOut:(NSString * _Nullable * _Nullable)keyPath
                             profilePathsOut:(NSArray<NSString *> * _Nullable * _Nullable)profilePaths
                                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
