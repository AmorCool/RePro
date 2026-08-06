// v2.1.0：signingd daemon 编译时的 SSZipArchive 占位桩。
// EEBackend.m 引用了 SSZipArchive 用于 IPA 解压/打包（daemon 不需要），
// 但 Objective-C 类引用会生成链接符号——必须提供空的桩实现让链接器满意。
// daemon 永远不会调用这些 IPA 函数，所以桩实现为 no-op 即可。

#import <Foundation/Foundation.h>

@interface SSZipArchive : NSObject
+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination;
+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath;
@end

@implementation SSZipArchive
+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination { return NO; }
+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath { return NO; }
@end
