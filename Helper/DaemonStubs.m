// v2.1.0：signingd daemon 编译时的符号占位桩。
// 签名管线源码依赖 UIKit/CoreGraphics/AuthKit 等 daemon 不需要的符号。
// 提供空桩实现（匹配 SDK extern 声明，确保链接通过）。
// daemon 运行时不调用这些桩——签名流程使用独立路径。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// ─── CoreGraphics/UIKit 全局常量 ──────────────────────────────────────────
const CGRect CGRectZero = {{0,0},{0,0}};
NSString *NSFontAttributeName = @"NSFont";

// ─── UIKit 桩（daemon 无 UI，全部 nil 空壳）───────────────────────────────

@interface UIDevice : NSObject
+ (instancetype)currentDevice;
- (NSString *)systemVersion;
- (NSString *)model;
- (NSString *)uniqueIdentifier;
@end
@implementation UIDevice
+ (instancetype)currentDevice { static id d; if (!d) d = [[self alloc] init]; return d; }
- (NSString *)systemVersion { return @"17.0"; }
- (NSString *)model { return @"iPhone"; }
- (NSString *)uniqueIdentifier { return @""; }
@end

@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { return nil; }
@end

@interface UIScreen : NSObject
+ (instancetype)mainScreen;
- (CGRect)bounds;
@end
@implementation UIScreen
+ (instancetype)mainScreen { return nil; }
- (CGRect)bounds { return CGRectZero; }
@end

@interface UIImage : NSObject
@end
@implementation UIImage
@end

// ─── AuthKit 桩（daemon 用 dlopen AuthKit 生成 Anisette，这里只占坑）────────

@interface AKDevice : NSObject
@end
@implementation AKDevice
@end

// ─── 签名管线内部桩 ──────────────────────────────────────────────────────

@interface EESigning : NSObject
@end
@implementation EESigning
@end

@interface RPVAuthentication : NSObject
@end
@implementation RPVAuthentication
@end

// ─── RPVDiagnostic ──────────────────────────────────────────────────────

void RPVDiagnostic(int level, NSString *tag, NSString *fmt, ...) {
    // daemon 用 s_log 写自己的日志，不吃 RPVDiagnostic。桩实现空。
}

// ─── libMobileGestalt ───────────────────────────────────────────────────

CFTypeRef MGCopyAnswer(CFStringRef question) {
    return NULL;  // daemon 不需要设备信息查询
}
