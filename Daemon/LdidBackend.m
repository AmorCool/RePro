//
//  LdidBackend.m
//  ReProvision Daemon
//
//  方案一：ldid 内嵌签名（原版 SoulRune 方式）
//  直接调用 ldid 库进行签名，无需外部二进制
//

#import "SignEngine.h"
#import "EESigning.h" // 从旧项目移植的 ldid 签名接口

@interface LdidBackend : NSObject <RZSignBackend>
@end

@implementation LldidBackend

- (NSString *)backendName { return @"ldid"; }

- (BOOL)isAvailable {
    // ldid 是静态链接的库，始终可用
    return YES;
}

- (RZSignResult *)signWithOptions:(RZSignOptions *)options error:(NSError **)error {
    RZSignResult *result = [[RZSignResult alloc] init];

    // 读取证书和私钥数据
    NSData *certData = [NSData dataWithContentsOfFile:options.certificatePath];
    NSData *keyData = [NSData dataWithContentsOfFile:options.keyPath];

    if (!certData || !keyData) {
        result.success = NO;
        result.errorMessage = @"无法读取证书或私钥文件";
        if (error) *error = [NSError errorWithDomain:@"RePro" code:404 userInfo:@{
            NSLocalizedDescriptionKey: result.errorMessage
        }];
        return result;
    }

    // 读取 entitlements
    NSString *entitlementsString = nil;
    if (options.entitlementsPath &&
        [[NSFileManager defaultManager] fileExistsAtPath:options.entitlementsPath]) {
        NSData *entData = [NSData dataWithContentsOfFile:options.entitlementsPath];
        entitlementsString = [[NSString alloc] initWithData:entData encoding:NSUTF8StringEncoding];
    }

    // 调用 EESigning 的 ldid 签名接口
    // （从旧项目 EESigning.mm 移植的核心逻辑）
    NSError *signError = nil;
    BOOL success = [EESigning signAppBundle:options.appPath
                              certificateData:certData
                                   keyData:keyData
                            entitlementsString:entitlementsString
                             provisioningPaths:options.provisioningPaths
                                    useSHA256:options.useSHA256
                                       error:&signError];

    result.success = success;

    if (!success) {
        result.errorMessage = signError.localizedDescription;
        if (error) *error = signError;
    } else {
        NSLog(@"[RePro] ldid 签名成功: %@", options.bundleIdentifier);
    }

    return result;
}

@end
