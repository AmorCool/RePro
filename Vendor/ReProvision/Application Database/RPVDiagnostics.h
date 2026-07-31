//
//  RPVDiagnostics.h
//  RePro
//
//  把 Vendor 业务层（RPVApplicationSigning / RPVBridge）的关键诊断，
//  通过 NSNotification 转发给 Swift 侧的 LogManager，使其出现在 App「日志」页，
//  用户无需连接电脑即可在重签后导出日志发给开发者定位问题。
//
//  注：iOS 上 NSLog 不会可靠地写入 stderr，因此不能用「重定向 stderr」的方式来
//  捕获诊断；这里用进程内通知做中转，保证 100% 进日志页。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RPVDiagLevel) {
    RPVDiagInfo    = 0,
    RPVDiagWarning = 1,
    RPVDiagError   = 2,
    RPVDiagDebug   = 3,
};

/// LogManager（Swift）订阅此通知名以接收诊断。
extern NSString *const RPVDiagnosticNotification;

/// 同时打印到系统日志（NSLog）并转发给 App 日志页。
/// 用法：RPVDiagnostic(RPVDiagError, @"repro-helper", @"exit=%d", code);
void RPVDiagnostic(RPVDiagLevel level, NSString * _Nonnull source, NSString * _Nonnull format, ...) NS_FORMAT_FUNCTION(3, 4);

/// 当前是否为 RootHide 环境（App bundle 旁存在 .jbroot 符号链接）。
/// 由 RPVBridge.m 实现。RootHide 下 sandbox 内的 App 直接写
/// /var/Managed Preferences/mobile 会落入 jbroot overlay（installd/profiled 看不见），
/// 因此描述文件注册必须走 repro-helper（setuid root）而不能直接写。
BOOL RPVIsRootHideEnvironment(void);

NS_ASSUME_NONNULL_END
