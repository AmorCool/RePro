//
//  ZSignBackend.h/m
//  ReProvision Daemon
//
//  方案二：zsign 外部进程签名
//  通过 posix_spawn 调用 /usr/local/bin/zsign 二进制文件
//  GPL 合规：进程隔离，Daemon 本身不受 GPL 传染
//

#import "SignEngine.h"
#import <spawn.h>

@interface ZSignBackend : NSObject <RZSignBackend>
- (nullable NSString *)findZsignBinary;
@end

@implementation ZSignBackend

- (NSString *)backendName { return @"zsign"; }

- (BOOL)isAvailable {
    return [self findZsignBinary] != nil;
}

- (nullable NSString *)findZsignBinary {
    // 候选路径列表（按优先级排序）
    NSArray<NSString *> *candidates = @[
        @"/usr/local/bin/zsign",           // RootHide / rootful 标准路径
        @"/var/jb/usr/local/bin/zsign",    // Dopamine / rootless 路径
        @"/var/jb/bin/zsign",
        @"/usr/bin/zsign"
    ];

    NSFileManager *fm = [NSFileManager defaultManager];

    // 优先检测 .jbroot 符号链接（RootHide 环境）
    NSString *jbrootLink = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@".jbroot"];
    if ([fm fileExistsAtPath:jbrootLink]) {
        NSString *resolved = [jbrootLink stringByResolvingSymlinksInPath];
        if ([fm fileExistsAtPath:[resolved stringByAppendingPathComponent:@"usr/local/bin/zsign"]]) {
            return [resolved stringByAppendingPathComponent:@"usr/local/bin/zsign"];
        }
    }

    // 遍历候选路径
    for (NSString *candidate in candidates) {
        if ([fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }

    // 最后回退到 $PATH 搜索
    return @"zsign";
}

- (RZSignResult *)signWithOptions:(RZSignOptions *)options error:(NSError **)error {
    RZSignResult *result = [[RZSignResult alloc] init];
    NSString *zsignPath = [self findZsignBinary];

    if (![self isAvailable]) {
        result.success = NO;
        result.errorMessage = @"未找到 zsign 二进制文件";
        if (error) *error = [NSError errorWithDomain:@"RePro" code:503 userInfo:@{
            NSLocalizedDescriptionKey: result.errorMessage
        }];
        return result;
    }

    // 构建 zsign 参数
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        @"-f",                    // 强制重签
        @"-k", options.keyPath,  // 私钥
        @"-c", options.certificatePath, // 证书
    ]];

    // 添加 provisioning profile（支持多个）
    for (NSString *prov in options.provisioningPaths) {
        if (prov.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:prov]) {
            [args addObject:@"-m"];
            [args addObject:prov];
        }
    }

    // 添加 entitlements（必须 XML 格式）
    if (options.entitlementsPath &&
        [[NSFileManager defaultManager] fileExistsAtPath:options.entitlementsPath]) {
        [args addObject:@"-e"];
        [args addObject:options.entitlementsPath];
    }

    // SHA-256
    if (options.useSHA256) {
        [args addObject:@"-2"];
    }

    // 输入 .app 路径
    [args addObject:options.appPath];

    // 构建 C 字符串数组
    const char *argv[args.count + 2]; // +2 for program name and NULL terminator
    argv[0] = zsignPath.UTF8String;
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i + 1] = [args[i] UTF8String];
    }
    argv[args.count + 1] = NULL;

    // 重定向 stdout/stderr 到日志文件
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"zsign_%@.log", [[NSUUID UUID] UUIDString]]];
    int logFD = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDERR_FILENO);
    }

    // 启动 zsign 子进程
    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, zsignPath.UTF8String, &fileActions, NULL,
                                (char *const *)argv, NULL);
    posix_spawn_file_actions_destroy(&fileActions);
    if (logFD >= 0) close(logFD);

    if (spawnErr != 0) {
        result.success = NO;
        result.exitCode = spawnErr;
        result.errorMessage = [NSString stringWithFormat:@"posix_spawn 失败: %s", strerror(spawnErr)];
        if (error) *error = [NSError errorWithDomain:@"RePro" code:spawnErr userInfo:@{
            NSLocalizedDescriptionKey: result.errorMessage
        }];
        return result;
    }

    // 等待子进程完成
    int status = 0;
    waitpid(pid, &status, 0);

    // 读取日志
    NSData *logData = [NSData dataWithContentsOfFile:logPath];
    NSString *logOutput = logData ? [[NSString alloc] initWithData:logData encoding:NSUTF8StringEncoding] : @"";
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

    if (WIFEXITED(status)) {
        result.exitCode = WEXITSTATUS(status);
        result.success = (result.exitCode == 0);

        if (!result.success) {
            result.errorMessage = [NSString stringWithFormat:@"zsign 退出码 %d\n%@", result.exitCode, logOutput];
        } else {
            result.signedAppPath = options.outputPath ?: options.appPath;
            NSLog(@"[RePro] zsign 签名成功: %@", options.bundleIdentifier);
        }
    } else {
        result.success = NO;
        result.errorMessage = [NSString stringWithFormat:@"zsign 异常终止 (signal %d)", WTERMSIG(status)];
    }

    return result;
}

@end
