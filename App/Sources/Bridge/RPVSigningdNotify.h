//
//  RPVSigningdNotify.h
//  RePro — 接收 repro-signingd LaunchDaemon 的 notify 信号
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RPVSigningdNotify : NSObject

+ (instancetype)shared;

@end

NS_ASSUME_NONNULL_END
