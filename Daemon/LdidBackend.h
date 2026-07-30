//
//  LdidBackend.h
//  ReProvision Daemon
//

#import <Foundation/Foundation.h>

@class RZSignOptions;

/// ldid 内嵌签名后端
@interface LdidBackend : NSObject

- (NSString *)backendName;
- (BOOL)isAvailable;
- (id)signWithOptions:(RZSignOptions *)options error:(NSError **)error;

@end
