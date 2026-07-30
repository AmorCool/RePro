//
//  ProfileInstaller.h/m
//  ReProvision Daemon
//
//  Provisioning Profile 安装模块：
//  - 将 .mobileprovision 写入系统 profile 仓库
//  - HUP profiled 通知刷新
//  - 兼容 RootHide / Dopamine / rootful 环境
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ProfileInstaller : NSObject

/// 安装 provisioning profile 到系统仓库
- (BOOL)installProfileAtPath:(NSString *)path error:(NSError **)error;

/// 通过 MCProfileConnection API 注册（iOS 15+）
- (BOOL)registerViaMCProfileConnection:(NSData *)profileData error:(NSError **)error;

/// 文件系统回退：直接写入 /var/Managed Preferences/mobile/
- (BOOL)registerViaFileSystem:(NSData *)profileData error:(NSError **)error;

/// HUP profiled 刷新
- (void)notifyProfiled;

@end

NS_ASSUME_NONNULL_END
