//
//  HealthCheck.m
//  ReProvision Daemon
//

#import "HealthCheck.h"
#import "AnisetteManager.h"
#import "TokenCacheManager.h"
#import <unistd.h>
#import <sys/stat.h>

@implementation HealthCheck

- (NSDictionary<NSString *, id> *)currentStatus {
    NSMutableDictionary *status = [NSMutableDictionary dictionary];

    status[@"daemonRunning"] = @([self isDaemonRunning]);
    status[@"hasRootPrivileges"] = @([self hasRootPrivileges]);
    status[@"isSandboxed"] = @([self isSandboxed]);
    status[@"zsignPath"] = [self zsignPath] ?: [NSNull null];

    NSDate *lastResign = [self lastResignTime];
    status[@"lastResignTime"] = lastResign ? @([lastResign timeIntervalSince1970]) : [NSNull null];

    status[@"validTokenCount"] = @([[TokenCacheManager sharedManager] validTokenCount]);
    status[@"anisetteReady"] = @([[AnisetteManager sharedManager] isReady]);
    status[@"uptimeSeconds"] = @([self uptime]);
    status[@"pid"] = @(getpid());

    // 越狱环境检测
    NSString *jbType = @"unknown";
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/.roothide_version"]) {
        jbType = @"roothide";
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/dopamine"]) {
        jbType = @"dopamine";
    } else if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        jbType = @"rootful";
    }
    status[@"jailbreakType"] = jbType;

    return status;
}

- (BOOL)isDaemonRunning {
    return YES; // 如果这个方法能被调用，说明 daemon 肯定在跑
}

- (BOOL)hasRootPrivileges {
    return getuid() == 0;
}

- (BOOL)isSandboxed {
    // 检查是否能访问 root-only 路径
    struct stat st;
    int ret = stat("/var/Managed Preferences/mobile", &st);
    if (ret == 0) {
        // 能 stat 不代表能写，但至少能看到
        return NO; // 假设有 no-sandbox entitlement
    }
    // 另一种检查：看能否读取其他 app 的数据
    return YES; // 默认保守判断
}

- (NSString *)zsignPath {
    NSArray<NSString *> *candidates = @[
        @"/usr/local/bin/zsign",
        @"/var/jb/usr/local/bin/zsign",
        @"/var/jb/bin/zsign",
        @"/usr/bin/zsign"
    ];

    NSFileManager *fm = [NSFileManager defaultManager];

    // RootHide .jbroot 检测
    NSString *jbrootLink = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@".jbroot"];
    if ([fm fileExistsAtPath:jbrootLink]) {
        NSString *resolved = [jbrootLink stringByResolvingSymlinksInPath];
        NSString *path = [resolved stringByAppendingPathComponent:@"usr/local/bin/zsign"];
        if ([fm isExecutableFileAtPath:path]) return path;
    }

    for (NSString *candidate in candidates) {
        if ([fm isExecutableFileAtPath:candidate]) return candidate;
    }

    return nil;
}

- (NSDate *)lastResignTime {
    // 从 UserDefaults 或持久化文件读取上次重签时间
    NSString *path = @"/var/mobile/Library/ReProvision/last_resign_time";
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (dict) {
        double timestamp = [dict[@"timestamp"] doubleValue];
        if (timestamp > 0) {
            return [NSDate dateWithTimeIntervalSince1970:timestamp];
        }
    }
    return nil;
}

- (NSTimeInterval)uptime {
    // 通过 pid 启动时间计算
    int pid = getpid();
    NSString *procPath = [NSString stringWithFormat:@"/proc/%d", pid];
    struct stat st;
    if (stat(procPath.UTF8String, &st) == 0) {
        return [[NSDate date] timeIntervalSinceDate:[NSDate dateWithTimeIntervalSinceNow:-st.st_mtime]];
    }
    // 回退：无法精确获取，返回进程启动后的时间估算
    return [[NSProcessInfo processInfo] systemUptime;
}

@end
