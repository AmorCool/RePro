//
//  RPVProfileStore.h
//  ReSign —— 系统描述文件库（/var/Managed Preferences/mobile）的共享操作实现
//
//  v1.1.171 新增。两个 root 程序都要干同样的事，之前各写了一套，导致行为不一致：
//    - repro-profiledaemon（RootHide 专用，launchd 拉起）
//    - repro-helper（rootless/rootful 用，setuid root 按需拉起）
//
//  🔴 为什么必须共享：真机取证发现「签名后目标 App 秒退（0xe8008015）」的真因是
//     描述文件重复堆积 —— 同一个 application-identifier 在系统库里堆了 102 份
//     （目录内 163 份只对应 3 个 App）。profiled 扫描到同一 App ID 的上百份 profile
//     时会挑中旧份去校验刚重签的 App，证书对不上 → installd 拒绝 → 秒退。
//     堆积的根源是「文件名按描述文件内容 SHA1 生成」：每次重签 Apple 都返回一份新的
//     profile（UUID/CreationDate 都变），内容 SHA1 必然不同 → 每次都新增一份，
//     旧的永远不删。repro-helper 至今仍是这个老逻辑。
//
//  修法两条腿：
//    1. 文件名改成 sha1(application-identifier) —— 同一个 App 恒定同名，重签直接覆盖；
//    2. 每次安装后按 application-identifier 去重 + 删过期，把历史堆积一次性收干净。
//
//  本头文件全部是 static inline，未使用的函数不会产生 -Wunused-function 告警，
//  可以直接被两个独立编译的 .m 各自 include。
//
//  ⚠️ 这里写死的 /var/Managed Preferences/mobile 必须是真实系统路径，
//     编译时不要带任何 vroot / jbroot 路径翻译。
//

#ifndef RPVProfileStore_h
#define RPVProfileStore_h

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <signal.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <time.h>
#include <dlfcn.h>
#include <objc/runtime.h>

static inline void RPVPSLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static inline void RPVPSLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-profiles] %@", msg);
}

/// 系统描述文件库（默认路径）
static NSString *const RPVPSManagedPrefsDir = @"/var/Managed Preferences/mobile";

/// RootHide 下真实 rootfs 的描述文件库路径。
/// jbroot 命名空间里 /var/Managed Preferences/mobile 是 overlay 假目录，iOS 的
/// profiled/installd（真实 rootfs）读不到；真实库在 /rootfs/private/var/Managed
/// Preferences/mobile。若此路径存在，所有写/清/列/删操作都要同时覆盖它，确保无论
/// daemon 跑在哪个命名空间，profile 都能落到 profiled 真正读取的目录。
static NSString *const RPVPSManagedPrefsDirRealRootFS =
    @"/rootfs/private/var/Managed Preferences/mobile";

/// 返回需要操作的所有目标目录（已按 realpath 去重）。
/// 真实 rootfs 进程里 /var/... 与 /rootfs/private/var/... 指向同一 inode，
/// 去重后只处理一次，不会重复写/重复列。jbroot 命名空间里两者是不同目录，都处理。
static inline NSArray<NSString *> *RPVPSManagedPrefsDirs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *candidates = @[ RPVPSManagedPrefsDir, RPVPSManagedPrefsDirRealRootFS ];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *d in candidates) {
        if (![fm fileExistsAtPath:d]) continue;
        char rp[PATH_MAX];
        NSString *key = d;
        if (realpath(d.fileSystemRepresentation, rp) != NULL && strlen(rp) > 0) {
            key = [NSString stringWithUTF8String:rp];
        }
        if ([seen containsObject:key]) continue;  // 同一 inode 只处理一次
        [seen addObject:key];
        [dirs addObject:d];
    }
    if (dirs.count == 0) [dirs addObject:RPVPSManagedPrefsDir];
    return dirs;
}

/// 把 profile 写到所有目标目录（稳定名，先删后写覆盖），返回主目标路径用于日志。
/// 真实 rootfs 进程里两目录同源 → 只写一份；jbroot 进程里两目录不同 → 写两份，
/// 其中 /rootfs/... 那份正是 profiled 能读到的真实库。
static inline NSString *RPVPSWriteProfileToDirs(NSData *data, NSString *fileName) {
    if (data.length == 0 || fileName.length == 0) return nil;
    NSString *primary = nil;
    for (NSString *dir in RPVPSManagedPrefsDirs()) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *e = nil;
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e];
        }
        NSString *dest = [dir stringByAppendingPathComponent:fileName];
        // v1.1.171：稳定名必须「先删后写」，否则新签内容会被旧文件挡掉
        [fm removeItemAtPath:dest error:nil];
        if ([data writeToFile:dest options:NSDataWritingAtomic error:&e]) {
            chmod(dest.fileSystemRepresentation, 0644);
            if (!primary) primary = dest;
        } else {
            RPVPSLog(@"写入 %@ 失败: %@", dest, e.localizedDescription ?: @"未知错误");
        }
    }
    return primary;
}

#pragma mark - 基础工具

static inline NSString *RPVPSSha1OfData(NSData *data) {
    if (data.length == 0) return nil;
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

/// .mobileprovision 是二进制 PKCS#7，中间夹一段明文 <plist>…</plist>，切出来解析。
static inline NSDictionary *RPVPSPlistFromString(NSString *s) {
    if (s.length == 0) return nil;
    NSRange start = [s rangeOfString:@"<plist"];
    if (start.location == NSNotFound) return nil;
    NSRange searchRange = NSMakeRange(start.location, s.length - start.location);
    NSRange end = [s rangeOfString:@"</plist>" options:0 range:searchRange];
    if (end.location == NSNotFound) return nil;
    NSInteger length = (NSInteger)(end.location + end.length) - (NSInteger)start.location;
    if (length <= 0) return nil;
    NSRange slice = NSMakeRange(start.location, (NSUInteger)length);
    if (NSMaxRange(slice) > s.length) return nil;
    NSData *data = [[s substringWithRange:slice] dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return nil;
    @try {
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:nil
                                                               error:nil];
        // 一律做类型归一化，避免下游 [] 取值直接崩
        return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

static inline NSDictionary *RPVPSPlistAtPath(NSString *path) {
    NSString *s = [NSString stringWithContentsOfFile:path
                                            encoding:NSISOLatin1StringEncoding
                                               error:nil];
    return RPVPSPlistFromString(s);
}

static inline NSDictionary *RPVPSPlistOfData(NSData *data) {
    if (data.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return RPVPSPlistFromString(s);
}

/// 取 Entitlements.application-identifier（形如 TEAMID.com.x.y.TEAMID）
static inline NSString *RPVPSAppIdOfPlist(NSDictionary *plist) {
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    id ent = plist[@"Entitlements"];
    if (![ent isKindOfClass:[NSDictionary class]]) return nil;
    id ai = ((NSDictionary *)ent)[@"application-identifier"];
    return [ai isKindOfClass:[NSString class]] ? ai : nil;
}

/// 取 profile 自身的 UUID（系统信任库中用于注销的标识，区别于 application-identifier）。
/// 🔴 v1.1.185：删除功能整体移除后已无调用者，此函数不再需要。

/// 取 profile 的 ExpirationDate / CreationDate 等日期字段（inventory 用）。
static inline NSDate *RPVPSDateOfPlist(NSDictionary *plist, NSString *key) {
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    id v = plist[key];
    return [v isKindOfClass:[NSDate class]] ? v : nil;
}

/// 「稳定文件名」= sha1(application-identifier)。同一 App 重签时文件名恒定，
/// 直接覆盖旧档，从源头不再产生堆积。
static inline NSString *RPVPSStableNameForAppId(NSString *appId) {
    if (appId.length == 0) return nil;
    NSString *sha = RPVPSSha1OfData([appId dataUsingEncoding:NSUTF8StringEncoding]);
    if (sha.length == 0) return nil;
    return [sha stringByAppendingPathExtension:@"mobileprovision"];
}

static inline NSString *RPVPSStableNameForData(NSData *profileData) {
    return RPVPSStableNameForAppId(RPVPSAppIdOfPlist(RPVPSPlistOfData(profileData)));
}

#pragma mark - 通知 profiled 重新扫描

/// 真实 rootfs 里没有 killall（/bin 只有 df、ps），用 sysctl 枚举进程表再 kill()，
/// 纯系统调用，无任何外部二进制依赖。返回实际发出信号的进程数。
static inline int RPVPSSignalProcessesNamed(const char *name, int sig) {
    if (!name) return 0;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0 || size == 0) return 0;
    // 进程表可能在两次 sysctl 之间变大，多留余量
    size += size / 4 + 4096;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return 0;
    }
    int count = (int)(size / sizeof(struct kinfo_proc));
    int hit = 0;
    for (int i = 0; i < count; i++) {
        // p_comm 最长 MAXCOMLEN(16)，"profiled" 不会被截断
        if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            if (kill(procs[i].kp_proc.p_pid, sig) == 0) hit++;
        }
    }
    free(procs);
    return hit;
}

static inline void RPVPSNudgeProfiled(void) {
    // v1.1.178 修复：此前每个 App 安装完成后都向 profiled 发 SIGHUP，会触发整机信任库
    // 全量重建雪崩（一次 daemon 运行内装 N 个 App = N 次整机信任库重建，正是用户感知的
    // 「过一段时间就卡、发热」的直接成因）。profiled 本身会监视 /var/Managed Preferences/mobile
    // 目录（FSEvents / notifyd），新建/覆盖描述文件后它最终会自行重新扫描，因此无需每次都 SIGHUP。
    // 用标记文件 mtime 做「跨进程 60s 冷却去重」：同一时间窗口内只真正发送一次 SIGHUP，
    // 把一次安装潮合并成一次重建。daemon/helper 每次运行都是独立进程，static 变量无法跨进程
    // 共享，故用文件标记（位于共享 IPC 目录 /var/mobile/Library/RePro/，root 可写）。
    // 若标记文件不可写则优雅降级为「仍发送」（最坏回到旧行为），不会阻塞主流程。
    static const char *kNudgeStamp = "/var/mobile/Library/RePro/.last-profiled-nudge";
    time_t now = time(NULL);
    struct stat st;
    if (stat(kNudgeStamp, &st) == 0 && (now - st.st_mtime) < 60) {
        RPVPSLog(@"SIGHUP 冷却中（距上次 %lds < 60s），跳过本次 profiled 通知", (long)(now - st.st_mtime));
        return;
    }
    // 更新冷却标记：创建/写入文件使 mtime = now（profiled 未运行也不影响冷却判断）
    int fd = open(kNudgeStamp, O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) {
        close(fd);
        struct timeval tv[2];
        tv[0].tv_sec = now; tv[0].tv_usec = 0;
        tv[1].tv_sec = now; tv[1].tv_usec = 0;
        utimes(kNudgeStamp, tv);
    }
    int n = RPVPSSignalProcessesNamed("profiled", SIGHUP);
    RPVPSLog(@"已向 %d 个 profiled 发送 SIGHUP（60s 冷却去重后；0 表示当时未运行，下次启动自行扫描）", n);
}

#pragma mark - 清单导出

/// 把系统描述文件库的清单导出成 plist 快照，供 App「描述文件管理」界面读取。
/// App 跑在 uid 501 且受沙盒约束，直接列举系统托管目录并不可靠，统一由 root 侧导出。
/// 返回导出的条目数。
static inline NSUInteger RPVPSWriteInventory(NSString *outPath) {
    if (outPath.length == 0) return 0;
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *seenAppIds = [NSMutableSet set];  // 跨目录按 appId 去重展示
    for (NSString *dir in RPVPSManagedPrefsDirs()) {
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        for (NSString *name in files) {
            if (![name.pathExtension isEqualToString:@"mobileprovision"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            NSDictionary *plist = RPVPSPlistAtPath(path);

            NSString *appId = RPVPSAppIdOfPlist(plist) ?: @"";
            // 同一 App 在两个目录都有副本时，清单里只列一次
            if (appId.length > 0 && [seenAppIds containsObject:appId]) continue;
            if (appId.length > 0) [seenAppIds addObject:appId];

            id nameVal = plist[@"Name"];
            id uuidVal = plist[@"UUID"];
            NSDate *created = RPVPSDateOfPlist(plist, @"CreationDate");
            NSDate *expiry  = RPVPSDateOfPlist(plist, @"ExpirationDate");

            NSMutableDictionary *item = [NSMutableDictionary dictionary];
            item[@"fileName"]     = name;
            item[@"appId"]        = appId;
            item[@"displayName"]  = [nameVal isKindOfClass:[NSString class]] ? nameVal : @"";
            item[@"uuid"]         = [uuidVal isKindOfClass:[NSString class]] ? uuidVal : @"";
            item[@"sizeBytes"]    = attrs[NSFileSize] ?: @(0);
            item[@"isStableName"] = @([name isEqualToString:(RPVPSStableNameForAppId(appId) ?: @"")]);
            item[@"parsed"]       = @(plist != nil);
            if (created) item[@"creationDate"] = created;
            if (expiry)  item[@"expirationDate"] = expiry;
            if (attrs[NSFileModificationDate]) item[@"modifiedDate"] = attrs[NSFileModificationDate];
            [items addObject:item];
        }
    }

    NSDictionary *root = @{ @"generatedAt": [NSDate date],
                            @"directory"  : RPVPSManagedPrefsDir,
                            @"profiles"   : items };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data.length > 0 && [data writeToFile:outPath options:NSDataWritingAtomic error:nil]) {
        chown(outPath.fileSystemRepresentation, 501, 501);
        chmod(outPath.fileSystemRepresentation, 0644);
    }
    RPVPSLog(@"已导出描述文件清单：%lu 项 → %@", (unsigned long)items.count, outPath);
    return items.count;
}

#endif /* RPVProfileStore_h */
