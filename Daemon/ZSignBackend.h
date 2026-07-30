//
//  ZSignBackend.h
//  ReProvision Daemon
//

#import <Foundation/Foundation.h>

@class RZSignOptions;

/// zsign 外部进程签名后端
@interface ZSignBackend : NSObject

- (NSString *)backendName;
- (BOOL)isAvailable;
- (nullable NSString *)findZsignBinary;
- (id)signWithOptions:(RZSignOptions *)options error:(NSError **)error;

@end
