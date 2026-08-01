//
//  RZSignRunner.m
//  ReProvision Reborn (Rootless)
//
//  Spawns the zsign binary to re-sign applications. See RZSignRunner.h.
//

#import "RZSignRunner.h"
#import "RPVDiagnostics.h"
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>

@implementation RZSignResult
@end

@implementation RZSignRunner

+ (instancetype)sharedRunner {
    static RZSignRunner *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[RZSignRunner alloc] init];
    });
    return instance;
}

/// Resolves the roothide jailbreak root via the .jbroot symlink that the
/// jailbreak/ dpkg places next to every Mach-O directory (including our app
/// bundle). roothide does NOT use a fixed /var/jb; instead it installs into a
/// random, per-boot jbroot directory and exposes it through this symlink.
/// Returns nil when not running under roothide.
- (nullable NSString *)roothideJbRoot {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *jbrootLink = [bundlePath stringByAppendingPathComponent:@".jbroot"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:jbrootLink]) {
        return nil;
    }
    NSString *resolved = [jbrootLink stringByResolvingSymlinksInPath];
    if (resolved.length == 0) {
        return nil;
    }
    // Sanity: the resolved root should contain the bootstrap layout.
    if (![[NSFileManager defaultManager] fileExistsAtPath:
          [resolved stringByAppendingPathComponent:@"usr/local/bin"]]) {
        return nil;
    }
    return resolved;
}

- (nullable NSString *)zsignBinaryPath {
    // 0) roothide: each Mach-O directory carries a .jbroot symlink to the
    //    (random, per-boot) jailbreak root. Resolve it and look for zsign there.
    NSString *rhRoot = [self roothideJbRoot];
    if (rhRoot) {
        NSString *p = [rhRoot stringByAppendingPathComponent:@"usr/local/bin/zsign"];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
            return p;
        }
    }

    NSArray<NSString *> *candidates = @[
        @"/var/jb/usr/local/bin/zsign",
        @"/usr/local/bin/zsign",
        @"/var/jb/bin/zsign",
        @"/usr/bin/zsign"
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            return path;
        }
    }
    // Last resort: rely on $PATH.
    return @"zsign";
}

- (RZSignResult *)signBundleAtPath:(NSString *)inputPath
                        outputPath:(nullable NSString *)outputPath
                   certificatePath:(NSString *)certPEMPath
                           keyPath:(NSString *)keyPEMPath
                 provisioningPaths:(NSArray<NSString *> *)provisioningPaths
                  entitlementsPath:(nullable NSString *)entitlementsPath
                         useSHA256:(BOOL)useSHA256
                             error:(NSError **)error {
    RZSignResult *result = [[RZSignResult alloc] init];

    NSString *zsign = [self zsignBinaryPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:zsign]) {
        result.success = NO;
        result.standardError = @"zsign binary not found (expected /var/jb/usr/local/bin/zsign)";
        if (error) {
            *error = [NSError errorWithDomain:@"RZSign"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: result.standardError}];
        }
        return result;
    }

    // Build the argument list.
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    [args addObject:@"-k"]; [args addObject:keyPEMPath];        // private key (PEM/DER)
    [args addObject:@"-c"]; [args addObject:certPEMPath];        // certificate (PEM/DER)

    // One -m per bundle (root + every extension). zsign matches each profile to
    // a bundle by application-identifier suffix.
    for (NSString *prov in provisioningPaths) {
        if (prov.length && [[NSFileManager defaultManager] fileExistsAtPath:prov]) {
            [args addObject:@"-m"]; [args addObject:prov];
        }
    }

    if (entitlementsPath && [[NSFileManager defaultManager] fileExistsAtPath:entitlementsPath]) {
        [args addObject:@"-e"]; [args addObject:entitlementsPath];
    }
    if (useSHA256) {
        [args addObject:@"-2"];                                    // SHA-256 code directory
    }
    [args addObject:@"-f"];                                        // force (ignore cache)

    // Only pass -o when an output IPA is requested. Omitting -o makes zsign sign
    // the folder in place, which is what the ReProvision flow needs.
    if (outputPath.length && ![outputPath isEqualToString:inputPath]) {
        [args addObject:@"-o"]; [args addObject:outputPath];
    }
    [args addObject:inputPath];

    // 把真实命令行记进日志。参数传错（比如 -m 少给了某个 bundle 的描述文件、
    // -e 指到了不存在的文件）以前只能靠猜，现在直接可见。
    RPVDiagnostic(RPVDiagInfo, @"zsign", @"执行: %@ %@", zsign, [args componentsJoinedByString:@" "]);

    // Convert to a C string array for posix_spawn.
    NSUInteger count = args.count;
    const char **argv = (const char **)calloc(count + 2, sizeof(char *));
    argv[0] = [zsign UTF8String];
    for (NSUInteger i = 0; i < count; i++) {
        argv[i + 1] = [args[i] UTF8String];
    }
    argv[count + 1] = NULL;

    // Redirect stdout/stderr to a temp file so we can capture zsign's diagnostics.
    NSString *logPath = [NSString stringWithFormat:@"%@zsign_%@.log",
                         NSTemporaryDirectory(), [[NSUUID UUID] UUIDString]];

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO,
                                     [logPath fileSystemRepresentation],
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    pid_t pid = 0;
    int spawnRC = posix_spawn(&pid, [zsign UTF8String], &fileActions, &attr, (char *const *)argv, NULL);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fileActions);
    free(argv);

    if (spawnRC != 0) {
        result.exitCode = spawnRC;
        result.success = NO;
        result.standardError = [NSString stringWithFormat:@"posix_spawn failed: %d", spawnRC];
        [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"RZSign"
                                         code:spawnRC
                                     userInfo:@{NSLocalizedDescriptionKey: result.standardError}];
        }
        return result;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    result.exitCode = WEXITSTATUS(status);
    result.success = (result.exitCode == 0);

    // Read back zsign's output for diagnostics.
    NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    result.standardOutput = log ?: @"";
    result.standardError = log ?: @"";
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

    NSLog(@"*** [ReProvision] zsign exit=%d\n%@", result.exitCode, log ?: @"(no output)");

    // 关键：iOS 上 NSLog 不写 stderr，所以它永远进不了 App 的「日志」页。
    // 从 1.1.32 起把 zsign 的完整输出逐行送进 RPVDiagnostic —— 之前连续好几个
    // 版本都在猜"zsign 到底签了什么、跳过了哪个 bundle"，就是因为这段输出用户
    // 根本看不到。zsign 会打印它识别到的每一个 bundle、匹配到的描述文件，
    // 以及跳过的原因，是定位 0xe8008015 最直接的证据。
    RPVDiagnostic(result.success ? RPVDiagInfo : RPVDiagError, @"zsign",
                  @"===== zsign 输出开始（退出码 %d）=====", result.exitCode);
    if (log.length == 0) {
        RPVDiagnostic(RPVDiagWarning, @"zsign", @"(zsign 没有任何输出)");
    } else {
        for (NSString *line in [log componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length == 0) continue;
            RPVDiagnostic(RPVDiagInfo, @"zsign", @"%@", trimmed);
        }
    }
    RPVDiagnostic(RPVDiagInfo, @"zsign", @"===== zsign 输出结束 =====");

    if (!result.success && error) {
        NSString *detail = (log.length > 0)
            ? [NSString stringWithFormat:@"zsign exited with code %d:\n%@", result.exitCode, log]
            : [NSString stringWithFormat:@"zsign exited with code %d", result.exitCode];
        *error = [NSError errorWithDomain:@"RZSign"
                                     code:result.exitCode
                                 userInfo:@{NSLocalizedDescriptionKey: detail}];
    }

    return result;
}

@end
