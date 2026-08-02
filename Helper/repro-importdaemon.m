//
//  repro-importdaemon.m
//  RePro IPA import daemon (RootHide)
//
//  Why this exists:
//  On RootHide the App process (and any helper it posix_spawns) is confined to the
//  jbroot overlay namespace. iCloud Drive files live under
//  /var/mobile/Library/Mobile Documents, which the namespace redirects to an EMPTY
//  overlay — so the App literally cannot read an iCloud .ipa even with a valid
//  security-scoped URL. repro-helper is spawned from the App and INHERITS that
//  namespace, so it can't read the file either.
//
//  The only process that can reach the real on-disk iCloud file is a LaunchDaemon
//  started by launchd in the REAL system (rootfs) context — exactly like
//  repro-profiledaemon. So the import path mirrors the profile path:
//
//   1. App writes a request {src, dst, reqId} to the REAL shared path
//      /var/mobile/Library/RePro/import-request.plist  (App can write this dir;
//      it's the same IPC dir used by repro-profiledaemon).
//   2. App notify_post("com.reprovision.import-request").
//   3. This daemon (rootfs context, root, outside the App namespace) reads the
//      real iCloud file from /var/mobile/Library/Mobile Documents/... and copies
//      it to dst (under /var/mobile/Library/RePro/imports/<uuid>/<name>.ipa, also
//      real rootfs — readable back by the App).
//   4. Daemon writes /var/mobile/Library/RePro/import-result-<reqId>.plist and the
//      App polls for it.
//
//  Security: dst is only honoured if it is under /var/mobile/Library/RePro/, so a
//  malicious app can't make this daemon write elsewhere.

#include <notify.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdarg.h>
#include <spawn.h>
#include <sys/wait.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kRequestPath = @"/var/mobile/Library/RePro/import-request.plist";
static NSString *const kNotifyName  = @"com.reprovision.import-request";
// Result file is per-request (import-result-<reqId>.plist) to avoid races when
// two imports happen back to back.

static void RPVImportDaemonLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-importdaemon] %@", msg);
}

// Copy src -> dst. src is a REAL rootfs path (iCloud file or any on-disk file the
// App itself couldn't read because of the namespace). Returns YES on success.
static BOOL CopyFile(NSString *src, NSString *dst) {
    if (src.length == 0 || dst.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];

    // Make sure the destination directory exists.
    NSString *dstDir = [dst stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSError *err = nil;
    if ([fm copyItemAtPath:src toPath:dst error:&err]) {
        RPVImportDaemonLog(@"copied %@ -> %@", src, dst);
        return YES;
    }
    RPVImportDaemonLog(@"copyItemAtPath failed (%@), falling back to NSData read", err);

    // Fallback: read the whole file in memory and write it out. Works for iCloud
    // files that the kernel has materialised but that copyItem (which also copies
    // xattrs/quarantine) chokes on.
    NSData *data = [NSData dataWithContentsOfFile:src options:0 error:&err];
    if (data && [data writeToFile:dst options:NSDataWritingAtomic error:&err]) {
        RPVImportDaemonLog(@"copied via NSData (%lu bytes) %@ -> %@", (unsigned long)data.length, src, dst);
        return YES;
    }
    RPVImportDaemonLog(@"NSData copy also failed: %@", err);
    return NO;
}

// Block until an iCloud/ubiquitous item is fully downloaded locally (status ==
// Current / Downloaded), or until `timeout` seconds elapse. Without this, CopyFile
// below would grab a 0-byte stub and the IPA import would fail with
// "needs to be cached, then errors out". Mirrors what the Files app does when you
// tap an iCloud file: it downloads first, then opens.
static void RPVWaitForUbiquitousDownload(NSURL *url, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL everDownloading = NO;

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        NSError *err = nil;
        NSDictionary *vals = [url resourceValuesForKeys:@[
            NSURLUbiquitousItemDownloadingStatusKey,
            NSURLUbiquitousItemIsDownloadingKey
        ] error:&err];
        if (err) {
            RPVImportDaemonLog(@"ubiquitous status query failed (retry): %@", err);
        } else if (vals) {
            NSString *status = vals[NSURLUbiquitousItemDownloadingStatusKey];
            NSNumber *downloading = vals[NSURLUbiquitousItemIsDownloadingKey];
            if (downloading.boolValue) everDownloading = YES;
            if ([status isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent] ||
                [status isEqualToString:NSURLUbiquitousItemDownloadingStatusDownloaded]) {
                RPVImportDaemonLog(@"iCloud item ready (status=%@)", status);
                return;
            }
            RPVImportDaemonLog(@"waiting for iCloud download (status=%@, downloading=%@)", status, downloading);
        }
        usleep(500000); // 0.5s
    }
    RPVImportDaemonLog(@"timed out (%.0fs) waiting for iCloud download%@",
                       timeout, everDownloading ? @" — download started but did not finish" : @"");
}

// Validate that dst is safely inside the IPC dir, then perform the copy and write
// the per-request result file.
static void HandleRequest(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:kRequestPath];
    if (req.count == 0) {
        RPVImportDaemonLog(@"no/invalid request plist at %@", kRequestPath);
        return;
    }
    NSString *src   = req[@"src"];
    NSString *dst   = req[@"dst"];
    NSString *reqId = req[@"reqId"];
    if (src.length == 0 || dst.length == 0 || reqId.length == 0) {
        RPVImportDaemonLog(@"request missing src/dst/reqId");
        return;
    }

    // Only honour destinations under the IPC dir (defence against arbitrary writes).
    if (![dst hasPrefix:kIpcDir] || [dst isEqualToString:kIpcDir]) {
        NSString *resPath = [kIpcDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"import-result-%@.plist", reqId]];
        [@"ERR: dst not under IPC dir" writeToFile:resPath
                                           atomically:YES
                                             encoding:NSUTF8StringEncoding error:nil];
        RPVImportDaemonLog(@"refused dst outside IPC dir: %@", dst);
        return;
    }

    RPVImportDaemonLog(@"handling import (reqId=%@) src=%@", reqId, src);

    // iCloud / File Provider 文件在下载前只是占位符（stub）。CopyFile 之前必须先把
    // 文件真正下载（缓存）到本地，否则只会拷到 0 字节占位符，导致上游 initWithIpaURL
    // 读不到 Info.plist → “无法读取这个 .ipa”。这里触发下载并**轮询等待**到下载完成
    // （最多 120s），与 iOS 文件 App 点开 iCloud 文件“先下载缓存再打开”的行为一致。
    NSURL *srcURL = [NSURL fileURLWithPath:src];
    NSNumber *isUbiquitous = nil;
    [srcURL getResourceValue:&isUbiquitous forKey:NSURLIsUbiquitousItemKey error:nil];
    if (isUbiquitous.boolValue) {
        NSError *dlErr = nil;
        [fm startDownloadingUbiquitousItemAtURL:srcURL error:&dlErr];
        if (dlErr) RPVImportDaemonLog(@"startDownloadingUbiquitousItem: %@", dlErr);
        RPVWaitForUbiquitousDownload(srcURL, 120.0);
    }

    BOOL ok = CopyFile(src, dst);
    NSString *resPath = [kIpcDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"import-result-%@.plist", reqId]];
    NSString *result = ok ? [NSString stringWithFormat:@"OK: %@", dst]
                          : [NSString stringWithFormat:@"ERR: failed to copy %@", src];
    [result writeToFile:resPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    RPVImportDaemonLog(@"result: %@", result);
}

static void EnsureIpcDirWritable(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:kIpcDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    const char *p = kIpcDir.fileSystemRepresentation;
    if (chown(p, 501, 501) != 0) {
        chmod(p, 0777);
    } else {
        chmod(p, 0755);
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        RPVImportDaemonLog(@"daemon started (pid %d, uid %d, euid %d)",
                            getpid(), getuid(), geteuid());
        EnsureIpcDirWritable();

        // Handle a request that was already pending at launch.
        if ([[NSFileManager defaultManager] fileExistsAtPath:kRequestPath]) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                HandleRequest();
            });
        }

        int token = 0;
        notify_register_dispatch(kNotifyName.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
            RPVImportDaemonLog(@"received notify (token %d)", t);
            // 在后台队列处理，避免下载等待期间阻塞 daemon 的 run loop。
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                HandleRequest();
            });
        });

        RPVImportDaemonLog(@"entering run loop");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
