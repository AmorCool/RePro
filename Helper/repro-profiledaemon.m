//
//  repro-profiledaemon.m
//  RePro profile installation daemon (RootHide)
//
//  Runs as a launchd LaunchDaemon: launchd starts it in the REAL system
//  context, OUTSIDE the App's jbroot namespace. This is the only way to make
//  a provisioning-profile install actually reach the real profiled on RootHide:
//
//   - The App process (and any helper it spawns) is confined to the overlay
//     namespace. Its MCProfileConnection XPC call is redirected to an overlay
//     profiled instance, and its writes to /var/Managed Preferences/mobile land
//     in the overlay copy. installd runs OUTSIDE the namespace and only sees the
//     REAL library -> 0xe8008015.
//   - This daemon, started by launchd, is NOT in the App's namespace. It writes
//     the profile to the REAL /var/Managed Preferences/mobile and talks to the
//     REAL profiled, so installd can verify the app.
//
//  IPC: the App writes the profile data to a REAL shared path
//  (/var/mobile/Library/RePro/profile-to-install.mobileprovision — /var/mobile
//  is the user home and is NOT namespaced), then notify_post()s a signal. This
//  daemon receives the notify and installs the profile, writing the result back
//  to /var/mobile/Library/RePro/profile-install-result for the App to poll.
//

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
#include <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

static NSString *const kIpcDir      = @"/var/mobile/Library/RePro";
static NSString *const kProfileData = @"/var/mobile/Library/RePro/profile-to-install.mobileprovision";
static NSString *const kResultPath  = @"/var/mobile/Library/RePro/profile-install-result";
static NSString *const kNotifyName  = @"com.reprovision.profile-install-request";
static NSString *const kManagedPrefsDir = @"/var/Managed Preferences/mobile";

static void RPVProfileDaemonLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[repro-profiledaemon] %@", msg);
}

static NSString *RPVSha1OfData(NSData *data) {
    if (data.length == 0) return nil;
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

// Writes the profile to the REAL managed-preferences directory and registers it
// with the REAL profiled. Runs in the daemon's (non-namespaced) context.
static NSString *InstallProfile(NSData *profileData) {
    if (profileData.length == 0) {
        return @"ERR: empty profile data";
    }

    // 1. Write to the real managed-preferences directory.
    NSString *sha = RPVSha1OfData(profileData);
    if (sha.length == 0) {
        return @"ERR: failed to compute SHA1 of profile";
    }

    NSString *destDir = kManagedPrefsDir;
    NSString *destPath = [destDir stringByAppendingPathComponent:
        [sha stringByAppendingPathExtension:@"mobileprovision"]];

    NSError *writeErr = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    if (![profileData writeToFile:destPath options:NSDataWritingAtomic error:&writeErr]) {
        return [NSString stringWithFormat:@"ERR: write to %@ failed: %@", destPath, writeErr];
    }
    chmod([destPath fileSystemRepresentation], 0644);
    RPVProfileDaemonLog(@"wrote profile to REAL path: %@", destPath);

    // 2. Register with the real profiled via MCProfileConnection.
    dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    Class mcClass = objc_getClass("MCProfileConnection");
    if (!mcClass) {
        RPVProfileDaemonLog(@"MCProfileConnection class unavailable; relying on file + SIGHUP");
    } else {
        id connection = [(id)mcClass performSelector:@selector(sharedConnection)];
        if (connection) {
            SEL sel = NSSelectorFromString(@"installProvisioningProfileData:managingProfileIdentifier:outError:");
            if ([connection respondsToSelector:sel]) {
                NSMethodSignature *sig = [connection methodSignatureForSelector:sel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:connection];
                [inv setSelector:sel];
                [inv setArgument:&profileData atIndex:2];
                NSString *managing = nil;
                [inv setArgument:&managing atIndex:3];
                NSError *__autoreleasing outError = nil;
                NSError *__autoreleasing *outPtr = &outError;
                [inv setArgument:&outPtr atIndex:4];
                BOOL ret = NO;
                @try {
                    [inv invoke];
                    if (sig.methodReturnLength == sizeof(BOOL)) [inv getReturnValue:&ret];
                    RPVProfileDaemonLog(@"MC install returned %d, error: %@", ret, outError ?: @"none");
                } @catch (NSException *e) {
                    RPVProfileDaemonLog(@"MC install threw: %@", e);
                }
            }
        }
    }

    // 3. Nudge the real profiled to reload so installd sees the new profile.
    //    system() is unavailable on iOS; use posix_spawn to run killall -HUP.
    @try {
        pid_t pid = 0;
        const char *argv[] = { "/usr/bin/killall", "-HUP", "profiled", NULL };
        int rc = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL,
                             (char *const *)argv, NULL);
        if (rc == 0) {
            int status = 0;
            waitpid(pid, &status, 0);
            RPVProfileDaemonLog(@"killall -HUP profiled done (status %d)", status);
        } else {
            RPVProfileDaemonLog(@"posix_spawn killall failed: %d", rc);
        }
    } @catch (NSException *e) {
        RPVProfileDaemonLog(@"SIGHUP threw: %@", e);
    }

    return [NSString stringWithFormat:@"OK: profile installed to %@", destPath];
}

// Ensure the IPC directory is writable by mobile (uid 501), because the App
// (running as mobile) must drop the profile data there. The daemon runs as
// root, so it can fix ownership/permissions of the directory it created.
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

static void HandleRequest(void) {
    // Make sure the IPC directory is mobile-writable before we read from it.
    EnsureIpcDirWritable();
    NSData *profileData = [NSData dataWithContentsOfFile:kProfileData];
    if (profileData.length == 0) {
        RPVProfileDaemonLog(@"no profile data at %@", kProfileData);
        [@"ERR: no profile data" writeToFile:kResultPath
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:nil];
        return;
    }
    RPVProfileDaemonLog(@"handling profile install (%lu bytes)", (unsigned long)profileData.length);

    NSString *result = InstallProfile(profileData);
    [result writeToFile:kResultPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
    RPVProfileDaemonLog(@"result: %@", result);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        RPVProfileDaemonLog(@"daemon started (pid %d, uid %d, euid %d)",
                            getpid(), getuid(), geteuid());

        // Ensure the IPC directory exists and is writable by mobile (uid 501),
        // because the App (running as mobile) must write the profile data there.
        EnsureIpcDirWritable();
        // Clean any stale result.
        [[NSFileManager defaultManager] removeItemAtPath:kResultPath error:nil];

        int token = 0;
        notify_register_dispatch(kNotifyName.UTF8String, &token,
                                 dispatch_get_main_queue(), ^(int t) {
            RPVProfileDaemonLog(@"received notify (token %d)", t);
            HandleRequest();
        });

        // Handle a request that was already pending at launch.
        if ([[NSFileManager defaultManager] fileExistsAtPath:kProfileData]) {
            HandleRequest();
        }

        RPVProfileDaemonLog(@"entering run loop");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
