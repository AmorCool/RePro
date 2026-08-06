// v2.1.0：signingd daemon 编译时的符号占位桩。
// 签名管线源码（EEBackend/EEProvisioning/RPVResources 等）依赖 UIKit/AuthKit/
// libMobileGestalt/RPVDiagnostics 等 daemon 永远用不上的符号。提供空桩实现让链接器满意。
// daemon 的签名流程不会调用这些桩 (git gc 清洗链路保证)，仅解决链接依赖。

#import <Foundation/Foundation.h>

// CGRect/CGSize/CGPoint 手动定义（避免链接 CoreGraphics/UIKit）
typedef struct CGPoint { double x, y; } CGPoint;
typedef struct CGSize  { double width, height; } CGSize;
typedef struct CGRect  { CGPoint origin; CGSize size; } CGRect;
static inline CGRect CGRectMake(double x, double y, double w, double h) {
    return (CGRect){{x, y}, {w, h}};
}
#define CGRectZero CGRectMake(0, 0, 0, 0)

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
