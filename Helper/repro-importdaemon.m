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

    // Best-effort trigger iCloud download of the source, in case it's a stub.
    if ([src hasPrefix:@"/var/mobile/Library/Mobile Documents"]) {
        NSError *dlErr = nil;
        [fm startDownloadingUbiquitousItemAtURL:[NSURL fileURLWithPath:src] error:&dlErr];
        if (dlErr) RPVImportDaemonLog(@"startDownloadingUbiquitousItem: %@", dlErr);
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
            HandleRequest();
        }

        int token = 0;
        notify_register_dispatch(kNotifyName.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
            RPVImportDaemonLog(@"received notify (token %d)", t);
            HandleRequest();
        });

        RPVImportDaemonLog(@"entering run loop");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
