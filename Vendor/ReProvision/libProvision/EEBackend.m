//
//  EEBackend.m
//  OpenExtenderTest
//
//  Created by Matt Clarke on 02/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "EEBackend.h"
#import "EEAppleServices.h"
#import "EEProvisioning.h"
#import "EESigning.h"
#import "RZSignRunner.h"
#import "SSZipArchive.h"
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach-o/arch.h>
#import <mach/machine.h>
#import <stdio.h>
#import <sys/stat.h>
#import "RPVDiagnostics.h"
#import "libMobileGestalt.h"

#pragma mark - ARM64e thinning (fixes SIGBUS on arm64e devices after re-sign)

// After re-signing, arm64e binaries keep their pointer-authentication (PAC) /
// chained-fixup pointers, which dyld cannot re-authenticate against the new
// signature and therefore SIGBUS (KERN_PROTECTION_FAILURE) at launch on arm64e
// hardware (e.g. iPhone 16,2 / iOS 17.2.1). Running the app as a plain arm64
// slice sidesteps pointer authentication entirely and is universally compatible,
// so we drop the arm64e slice (keeping arm64) before handing the bundle to zsign.
//
// arm64e is identified by the 0x80000000 capability bit in the Mach-O cpusubtype
// (independent of the exact low subtype value), which is robust across SDKs.
#define RZ_ARM64E_BIT 0x80000000u

// FAT/Mach-O fat_arch fields are big-endian on disk; iOS/arm64 is little-endian.
// Local swap avoids depending on <libkern/OSByteOrder.h>, which is not reliably
// exposed under this target's C99 settings.
static inline uint32_t RZSwapBigToHost32(uint32_t x) {
    return ((x & 0x000000FFu) << 24) | ((x & 0x0000FF00u) << 8) |
           ((x & 0x00FF0000u) >> 8)  | ((x & 0xFF000000u) >> 24);
}

static BOOL RZFileLooksLikeMachO(NSString *path) {
    FILE *f = fopen(path.UTF8String, "rb");
    if (!f) return NO;
    uint32_t magic = 0;
    size_t n = fread(&magic, 1, 4, f);
    fclose(f);
    if (n != 4) return NO;
    return (magic == FAT_MAGIC || magic == FAT_CIGAM ||
            magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
            magic == MH_MAGIC || magic == MH_CIGAM);
}

// Per the LiveContainer ARM64e migration guide: arm64e-only binaries must NOT be
// thinned to arm64. The re-signed arm64e app is still rejected by installd
// (0xe8008015) because the arm64e binary's chained fixups / authenticated pointers
// are incompatible with re-signing under a free provisioning profile. The correct
// fix is to PATCH the arm64e slice in place — disable chained fixups and ensure
// __TEXT is executable — while keeping it arm64e. RootHide's AMFI patches let
// arm64e load at runtime.

// Patch a single thin arm64e Mach-O slice (at base+off, length size) in place.
static void RZPatchArm64eThinSlice(uint8_t *base, size_t off, size_t size) {
    if (size < sizeof(struct mach_header_64)) return;
    struct mach_header_64 *h = (struct mach_header_64 *)(base + off);
    if (h->magic != MH_MAGIC_64) return;
    if (!(h->cpusubtype & RZ_ARM64E_BIT)) return; // not arm64e
    uint8_t *lc = (uint8_t *)h + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if ((uintptr_t)(lc - base) + 8 > off + size) break;
        struct load_command *cmd = (struct load_command *)lc;
        if (cmd->cmdsize == 0) break;
        if (cmd->cmd == 0x80000034) { // LC_DYLD_CHAINED_FIXUPS
            if ((uintptr_t)(lc - base) + cmd->cmdsize <= off + size)
                memset(lc + sizeof(struct load_command), 0,
                       cmd->cmdsize - sizeof(struct load_command));
        } else if (cmd->cmd == 0x19) { // LC_SEGMENT_64
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                if (!(seg->initprot & 0x4)) seg->initprot |= 0x4; // VM_PROT_EXECUTE
                if (!(seg->maxprot  & 0x4)) seg->maxprot  |= 0x4;
            }
        }
        lc += cmd->cmdsize;
    }
}

// Patch an arm64e Mach-O (thin or FAT) in place: disable chained fixups and ensure
// the __TEXT segment is executable. Keeps the binary arm64e. Returns YES if rewritten.
static BOOL RZPatchArm64eSliceInFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length < sizeof(uint32_t)) return NO;
    uint32_t magic = *(const uint32_t *)data.bytes;
    NSMutableData *md = [data mutableCopy];
    uint8_t *base = (uint8_t *)md.mutableBytes;
    BOOL patched = NO;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        if (md.length < sizeof(struct fat_header)) return NO;
        const struct fat_header *fh = (const struct fat_header *)base;
        uint32_t nfat = RZSwapBigToHost32(fh->nfat_arch);
        const struct fat_arch *archs = (const struct fat_arch *)(base + sizeof(struct fat_header));
        for (uint32_t i = 0; i < nfat; i++) {
            uint32_t ct = RZSwapBigToHost32(archs[i].cputype);
            uint32_t st = RZSwapBigToHost32(archs[i].cpusubtype);
            if (ct == CPU_TYPE_ARM64 && (st & RZ_ARM64E_BIT)) {
                int64_t off = RZSwapBigToHost32(archs[i].offset);
                int64_t sz  = RZSwapBigToHost32(archs[i].size);
                if (off >= 0 && sz > 0 && (int64_t)md.length >= off + sz) {
                    RZPatchArm64eThinSlice(base, (size_t)off, (size_t)sz);
                    patched = YES;
                }
            }
        }
    } else if (magic == MH_MAGIC_64) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)base;
        if ((h->cpusubtype & RZ_ARM64E_BIT)) {
            RZPatchArm64eThinSlice(base, 0, md.length);
            patched = YES;
        }
    }
    if (patched) {
        NSError *werr = nil;
        if ([md writeToFile:path options:NSDataWritingAtomic error:&werr] && !werr) {
            chmod(path.UTF8String, 0755);
            RPVDiagnostic(RPVDiagInfo, @"sign", @"patched arm64e (kept arm64e): %@", [path lastPathComponent]);
            return YES;
        } else {
            RPVDiagnostic(RPVDiagWarning, @"sign", @"arm64e patch of %@ failed: %@", [path lastPathComponent], werr.localizedDescription);
        }
    }
    return NO;
}

// For a single Mach-O file:
//  - if it is a FAT archive carrying a plain arm64 slice, thin to that arm64 slice
//    (ordinary sandboxed apps must not run as arm64e without an Apple signature);
//  - if it is arm64e-only (thin, or FAT with only arm64e), patch the arm64e slice in
//    place and KEEP arm64e (per the LiveContainer ARM64e migration guide).
// Returns YES if the file was rewritten.
static BOOL RZThinArm64eSliceInFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length < sizeof(uint32_t)) return NO;
    uint32_t magic = *(const uint32_t *)data.bytes;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // FAT archive (fields are big-endian on disk).
        if (data.length < sizeof(struct fat_header)) return NO;
        const struct fat_header *fh = (const struct fat_header *)data.bytes;
        uint32_t nfat = RZSwapBigToHost32(fh->nfat_arch);
        if (nfat == 0 || data.length < sizeof(struct fat_header) + (size_t)nfat * sizeof(struct fat_arch)) return NO;
        const struct fat_arch *archs = (const struct fat_arch *)((const char *)data.bytes + sizeof(struct fat_header));

        int64_t arm64Off = -1, arm64Size = -1;
        BOOL sawArm64e = NO;
        for (uint32_t i = 0; i < nfat; i++) {
            uint32_t ct = RZSwapBigToHost32(archs[i].cputype);
            uint32_t st = RZSwapBigToHost32(archs[i].cpusubtype);
            if (ct != CPU_TYPE_ARM64) continue;
            if (st & RZ_ARM64E_BIT) { sawArm64e = YES; continue; }  // arm64e slice
            if (arm64Off < 0) {                             // first plain arm64 slice -> keep
                arm64Off = RZSwapBigToHost32(archs[i].offset);
                arm64Size = RZSwapBigToHost32(archs[i].size);
            }
        }
        if (arm64Off >= 0 && arm64Size > 0 && (int64_t)data.length >= arm64Off + arm64Size) {
            // FAT with a plain arm64 slice -> thin to arm64 (drop arm64e).
            NSData *thin = [data subdataWithRange:NSMakeRange((NSUInteger)arm64Off, (NSUInteger)arm64Size)];
            const struct mach_header_64 *h = (const struct mach_header_64 *)thin.bytes;
            if (thin.length == (NSUInteger)arm64Size && h->magic == MH_MAGIC_64 &&
                (h->cputype == CPU_TYPE_ARM64)) {
                NSError *werr = nil;
                if ([thin writeToFile:path options:NSDataWritingAtomic error:&werr] && !werr) {
                    chmod(path.UTF8String, 0755);
                    RPVDiagnostic(RPVDiagInfo, @"sign", @"thinned arm64e -> arm64: %@", [path lastPathComponent]);
                    return YES;
                }
            }
        }
        // No plain arm64 slice (arm64e-only FAT) -> patch in place, keep arm64e.
        if (sawArm64e) {
            return RZPatchArm64eSliceInFile(path);
        }
        return NO;
    }

    if (magic == MH_MAGIC_64) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)data.bytes;
        if ((h->cpusubtype & RZ_ARM64E_BIT)) {
            // arm64e-only single slice -> patch in place, keep arm64e.
            return RZPatchArm64eSliceInFile(path);
        }
        return NO;
    }
    return NO;
}

static void RZThinArm64eInBundle(NSString *bundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        NSString *path = url.path;
        if (RZFileLooksLikeMachO(path)) {
            RZThinArm64eSliceInFile(path);
        }
    }
}

// Returns YES if the Mach-O slice at `off` within `data` contains an
// LC_CODE_SIGNATURE load command.
static BOOL RZSliceHasSig(NSData *data, uint32_t off) {
    if (data.length < off + 32) return NO;
    const char *b = data.bytes;
    uint32_t magic = *(const uint32_t *)(b + off);
    BOOL le = (magic == 0xfeedfacf || magic == 0xfeedface);
    uint32_t ncmds = le ? *(const uint32_t *)(b + off + 16)
                        : CFSwapInt32BigToHost(*(const uint32_t *)(b + off + 16));
    uint32_t co = off + 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (data.length < co + 8) break;
        uint32_t cmd, cmdsize;
        if (le) { cmd = *(const uint32_t *)(b + co); cmdsize = *(const uint32_t *)(b + co + 4); }
        else   { cmd = CFSwapInt32BigToHost(*(const uint32_t *)(b + co)); cmdsize = CFSwapInt32BigToHost(*(const uint32_t *)(b + co + 4)); }
        if (cmd == 0x1d) return YES; // LC_CODE_SIGNATURE
        if (cmdsize == 0) break;
        co += cmdsize;
    }
    return NO;
}

// Returns YES if ANY Mach-O slice in the file at `path` is code-signed.
static BOOL RZMachOHasCodeSignature(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length < 4) return NO;
    uint32_t magic = *(const uint32_t *)data.bytes;
    if (magic == 0xcafebabe) { // FAT (big-endian on disk)
        if (data.length < 8) return NO;
        uint32_t nfat = CFSwapInt32BigToHost(*(const uint32_t *)(data.bytes + 4));
        for (uint32_t i = 0; i < nfat; i++) {
            if (data.length < 8 + i * 20 + 20) break;
            uint32_t off = CFSwapInt32BigToHost(*(const uint32_t *)(data.bytes + 8 + i * 20 + 8));
            if (RZSliceHasSig(data, off)) return YES;
        }
        return NO;
    }
    if (magic == 0xfeedfacf || magic == 0xfeedface) {
        return RZSliceHasSig(data, 0);
    }
    return NO;
}

// Jailbreak / roothide apps (e.g. Relaxin) sometimes ship a .framework whose
// only contents are a dylib + a placeholder file, with NO Info.plist. A
// framework bundle without Info.plist is malformed; installd's nested-bundle
// validation rejects the whole app at install time (0xe8008015). This walks the
// bundle and writes a minimal valid Info.plist into any .framework that lacks
// one, so installd accepts it as a proper nested framework.
static void RZFixFrameworkBundles(NSString *bundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // The app's own provisioning profile (written by _provisionBundleAtPath just
    // before this runs) is copied into every nested framework so each framework
    // carries a valid embedded.mobileprovision. installd verifies nested bundles
    // independently and rejects a framework that has no profile with
    // 0xe8008015 — this is the most common cause of jailbreak-app re-sign
    // failures (Relaxin's CydiaSubstrate.framework, etc.).
    NSString *mainProfile = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    NSData *mainProfileData = [fm fileExistsAtPath:mainProfile] ? [NSData dataWithContentsOfFile:mainProfile] : nil;

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
                                          includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue) continue;
        NSString *path = url.path;
        if (![path hasSuffix:@".framework"]) continue;
        NSString *infoPlist = [path stringByAppendingPathComponent:@"Info.plist"];

        // 1) A framework with no Info.plist is malformed and rejected by installd.
        if (![fm fileExistsAtPath:infoPlist]) {
            NSString *fwName = [path lastPathComponent].stringByDeletingPathExtension;
            NSString *exePath = [path stringByAppendingPathComponent:fwName];
            NSString *exeName = fwName;
            if (![fm fileExistsAtPath:exePath]) {
                // Fall back to the first Mach-O inside the framework.
                NSDirectoryEnumerator *fe = [fm enumeratorAtURL:url
                                          includingPropertiesForKeys:nil
                                                             options:0
                                                        errorHandler:nil];
                for (NSURL *fu in fe) {
                    FILE *f = fopen(fu.path.UTF8String, "rb");
                    uint32_t m = 0; size_t rn = f ? fread(&m, 1, 4, f) : 0;
                    if (f) fclose(f);
                    if (rn == 4 && (m == 0xfeedfacf || m == 0xcafebabe || m == 0xfeedface || m == 0xcffaedfe)) {
                        exeName = [fu.path lastPathComponent];
                        break;
                    }
                }
            }
            // Nest the fixed framework's identifier under the main app's bundle id
            // (the conventional Xcode form "appid.fwname"), so it validates as
            // nested code rather than a foreign bundle.
            NSString *idPrefix = @"com.reprovision.fixedfw";
            NSString *appInfoPlist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
            if ([fm fileExistsAtPath:appInfoPlist]) {
                NSString *appId = [[NSDictionary dictionaryWithContentsOfFile:appInfoPlist] objectForKey:@"CFBundleIdentifier"];
                if (appId.length) idPrefix = [appId stringByAppendingString:@"."];
            }
            NSDictionary *info = @{
                @"CFBundleName": fwName,
                @"CFBundleExecutable": exeName,
                @"CFBundleIdentifier": [NSString stringWithFormat:@"%@%@", idPrefix, fwName],
                @"CFBundlePackageType": @"FMWK",
                @"CFBundleVersion": @"1.0",
                @"CFBundleShortVersionString": @"1.0",
                @"CFBundleSupportedPlatforms": @[@"iPhoneOS"],
                @"DTPlatformName": @"iphoneos",
                @"DTPlatformVersion": @"17.0",
                @"MinimumOSVersion": @"15.0",
                @"UIDeviceFamily": @[@1, @2],
            };
            if ([info writeToFile:infoPlist atomically:YES]) {
                RPVDiagnostic(RPVDiagInfo, @"sign", @"fixed malformed framework (added Info.plist): %@", [path lastPathComponent]);
            } else {
                RPVDiagnostic(RPVDiagError, @"sign", @"WARN: could not write Info.plist for framework %@", [path lastPathComponent]);
            }
        }

        // 2) Inject the app's profile into the framework so it has a valid
        //    embedded.mobileprovision (installd requires one for nested bundles).
        NSString *fwProfile = [path stringByAppendingPathComponent:@"embedded.mobileprovision"];
        if (mainProfileData.length && ![fm fileExistsAtPath:fwProfile]) {
            if ([mainProfileData writeToFile:fwProfile atomically:YES]) {
                RPVDiagnostic(RPVDiagInfo, @"sign", @"injected app profile into framework: %@", [path lastPathComponent]);
            } else {
                RPVDiagnostic(RPVDiagError, @"sign", @"WARN: could not inject profile into framework %@", [path lastPathComponent]);
            }
        }
    }
}

// After zsign, verify every Mach-O in the bundle actually carries a code
// signature. If zsign silently failed to sign an arm64e-only / unusual binary,
// installd rejects the whole app with 0xe8008015 — this surfaces which binary
// (if any) was left unsigned.
static void RZVerifyBundleSigned(NSString *bundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
                                          includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                             options:0
                                                        errorHandler:nil];
    int unsignedCount = 0;
    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) continue;
        NSString *path = url.path;
        FILE *f = fopen(path.UTF8String, "rb");
        uint32_t m = 0; size_t rn = f ? fread(&m, 1, 4, f) : 0;
        if (f) fclose(f);
        if (rn != 4) continue;
        if (!(m == 0xfeedfacf || m == 0xcafebabe || m == 0xfeedface || m == 0xcffaedfe)) continue;
        if (!RZMachOHasCodeSignature(path)) {
            RPVDiagnostic(RPVDiagError, @"sign", @"UNSIGNED Mach-O after zsign: %@", path);
            unsignedCount++;
        }
    }
    if (unsignedCount == 0) {
        RPVDiagnostic(RPVDiagInfo, @"sign", @"all Mach-O binaries are code-signed after zsign");
    } else {
        RPVDiagnostic(RPVDiagError, @"sign", @"%d unsigned Mach-O binaries remain (likely cause of 0xe8008015)", unsignedCount);
    }
}

// Extract the embedded plist from a .mobileprovision (CMS/PKCS#7-wrapped) by
// locating the <?xml ... </plist> markers in the raw bytes. security/CMSDecoder
// is unavailable in the iOS SDK, but the CMS eContent (the profile plist) is
// stored verbatim as the OCTET STRING value, so the ASCII plist markers are
// present in the file. This is the standard on-device trick to read a profile
// without CMSDecoder. Returns nil if no plist can be found/parsed.
static NSDictionary *RZExtractProfilePlist(NSString *provPath) {
    NSData *data = [NSData dataWithContentsOfFile:provPath];
    if (!data || data.length < 16) return nil;
    NSData *open = [@"<?xml" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *close = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange r1 = [data rangeOfData:open options:0 range:NSMakeRange(0, data.length)];
    NSRange r2 = [data rangeOfData:close options:NSBackwardsSearch range:NSMakeRange(0, data.length)];
    if (r1.location == NSNotFound || r2.location == NSNotFound) return nil;
    NSUInteger end = r2.location + r2.length;
    if (end <= r1.location) return nil;
    NSData *plistData = [data subdataWithRange:NSMakeRange(r1.location, end - r1.location)];
    return [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:nil];
}

// Dump the provisioning-profile ↔ signed-entitlements match — the actual root
// cause of install-time 0xe8008015 (per the LiveContainer/ReproVision guides:
// application-identifier exact match + device UDID registration + TeamIdentifier
// consistency + entitlements ⊆ profile whitelist). On iOS we cannot use
// CMSDecoder, so we parse the profile plist via RZExtractProfilePlist.
static void RZDumpProfileMatch(NSString *bundlePath, NSString *entitlementsPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mainProv = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];

    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== PROFILE MATCH DIAGNOSTICS (0xe8008015 root cause) ===");

    NSDictionary *prof = RZExtractProfilePlist(mainProv);
    if (!prof) {
        RPVDiagnostic(RPVDiagError, @"sign", @"! cannot parse embedded.mobileprovision (present=%@) — cannot verify profile match",
                      [fm fileExistsAtPath:mainProv] ? @"yes" : @"NO");
        RPVDiagnostic(RPVDiagInfo, @"sign", @"=== end PROFILE MATCH DIAGNOSTICS ===");
        return;
    }
    NSDictionary *pe = prof[@"Entitlements"];
    NSString *aid = pe[@"application-identifier"];
    NSArray *teams = prof[@"TeamIdentifier"];
    NSArray *devs = prof[@"ProvisionedDevices"];
    NSString *exp = [prof[@"ExpirationDate"] description] ?: @"(unknown)";

    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.application-identifier = %@", aid);
    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.TeamIdentifier = %@", teams.firstObject);
    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.ProvisionedDevices count = %lu (empty => wildcard/team profile)",
                  (unsigned long)(devs ? devs.count : 0));
    RPVDiagnostic(RPVDiagInfo, @"sign", @"profile.ExpirationDate = %@", exp);

    NSDictionary *ent = [NSDictionary dictionaryWithContentsOfFile:entitlementsPath];
    NSString *eaid = ent[@"application-identifier"];
    RPVDiagnostic(RPVDiagInfo, @"sign", @"signed entitlements.application-identifier = %@", eaid);

    // Wildcard-aware application-identifier match: profile "<Team>.*" matches
    // signed "<Team>.<bundleid>". Non-wildcard requires exact bundle id.
    BOOL aidMatch = NO;
    if (aid.length && eaid.length) {
        NSArray *pa = [aid componentsSeparatedByString:@"."];
        NSArray *ea = [eaid componentsSeparatedByString:@"."];
        if (pa.count >= 2 && ea.count >= 2) {
            NSString *pTeam = pa[0];
            NSString *pBundle = [[pa subarrayWithRange:NSMakeRange(1, pa.count - 1)] componentsJoinedByString:@"."];
            NSString *eTeam = ea[0];
            NSString *eBundle = [[ea subarrayWithRange:NSMakeRange(1, ea.count - 1)] componentsJoinedByString:@"."];
            BOOL teamOK = [pTeam isEqualToString:eTeam];
            BOOL bundleOK = [pBundle isEqualToString:@"*"] || [pBundle isEqualToString:eBundle];
            aidMatch = teamOK && bundleOK;
        }
    }
    RPVDiagnostic(aidMatch ? RPVDiagInfo : RPVDiagError, @"sign",
                  @"application-identifier MATCH = %@",
                  aidMatch ? @"YES" : @"NO (MISMATCH -> 0xe8008015)");

    // Device UDID registration (the guide's stated primary 0xe8008015 cause).
    CFStringRef udidRef = MGCopyAnswer(kMGUniqueDeviceID);
    NSString *udid = udidRef ? (__bridge_transfer NSString *)udidRef : nil;
    if (udid.length) {
        BOOL inProfile = (devs.count == 0) ? YES : [devs containsObject:udid];
        RPVDiagnostic(inProfile ? RPVDiagInfo : RPVDiagError, @"sign",
                      @"device UDID = %@ | in profile.ProvisionedDevices = %@",
                      udid, inProfile ? @"YES" : @"NO (NOT REGISTERED -> 0xe8008015)");
    } else {
        RPVDiagnostic(RPVDiagWarning, @"sign", @"! could not read device UDID via MGCopyAnswer");
    }

    // Entitlements subset check vs profile whitelist.
    if (pe && ent) {
        NSMutableArray *extra = [NSMutableArray array];
        for (NSString *k in ent) {
            if (pe[k] == nil) [extra addObject:k];
        }
        if (extra.count) {
            RPVDiagnostic(RPVDiagError, @"sign",
                          @"entitlements NOT in profile whitelist: %@ -> reject",
                          [extra componentsJoinedByString:@", "]);
        } else {
            RPVDiagnostic(RPVDiagInfo, @"sign", @"entitlements ⊆ profile whitelist: YES");
        }
    }

    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== end PROFILE MATCH DIAGNOSTICS ===");
}

// After zsign, report the on-disk code-signing artifacts so a failing re-sign
// can be debugged from the app log: whether the main app (and each nested
// framework, and each loose dylib at the app root) carries an
// embedded.mobileprovision. The app's profile embedded into a nested bundle is
// what installd requires to accept it — if any bundle lacks it, that's the
// smoking gun for 0xe8008015.
static void RZLogProfileDiagnostics(NSString *bundlePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appName = [bundlePath lastPathComponent].stringByDeletingPathExtension;
    NSString *mainProv = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];

    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== re-sign diagnostics for %@ ===", appName);
    RPVDiagnostic(RPVDiagInfo, @"sign", @"main app embedded.mobileprovision: %@",
                  [fm fileExistsAtPath:mainProv] ? @"present" : @"MISSING");

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:bundlePath]
                                      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                         options:0
                                                    errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        NSString *p = url.path;
        if ([p hasSuffix:@".framework"]) {
            NSString *ip = [p stringByAppendingPathComponent:@"Info.plist"];
            NSString *prov2 = [p stringByAppendingPathComponent:@"embedded.mobileprovision"];
            RPVDiagnostic(RPVDiagInfo, @"sign", @"framework %@ : Info.plist=%@ embedded.mobileprovision=%@",
                          [p lastPathComponent],
                          [fm fileExistsAtPath:ip] ? @"yes" : @"NO",
                          [fm fileExistsAtPath:prov2] ? @"yes" : @"NO");
        } else if (!isDir.boolValue) {
            // A loose Mach-O at the app root (e.g. libjailbreak.dylib) — report
            // whether it has its own profile (it normally shouldn't; it's covered
            // by the app's signature, but report presence for completeness).
            FILE *f = fopen(p.UTF8String, "rb");
            uint32_t m = 0; size_t rn = f ? fread(&m, 1, 4, f) : 0;
            if (f) fclose(f);
            if (rn == 4 && (m == 0xfeedfacf || m == 0xcafebabe || m == 0xfeedface || m == 0xcffaedfe)) {
                RPVDiagnostic(RPVDiagDebug, @"sign", @"loose Mach-O at root: %@ (signed=%@)",
                              [p lastPathComponent], RZMachOHasCodeSignature(p) ? @"yes" : @"NO");
            }
        }
    }
    RPVDiagnostic(RPVDiagInfo, @"sign", @"=== end diagnostics ===");
}

/* Private headers */
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
- (NSArray *)allApplications;
- (BOOL)uninstallApplication:(id)arg1 withOptions:(id)arg2;
@end

@implementation EEBackend

+ (void)provisionDevice:(NSString *)udid name:(NSString *)name identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler {
    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner provisionDevice:udid name:name withTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error) {
        completionHandler(error);
    }];
}

+ (void)revokeDevelopmentCertificatesForCurrentMachineWithIdentity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId systemType:(EESystemType)systemType withCallback:(void (^)(NSError *))completionHandler {
    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner revokeCertificatesWithTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error) {
        completionHandler(error);
    }];
}

+ (void)signBundleAtPath:(NSString *)path identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId withCompletionHandler:(void (^)(NSError *error))completionHandler {
    // Signing kernel: zsign (replaces the old ldid-based EESigning path).
    //
    // zsign re-signs a whole .app (main executable + every nested extension /
    // framework) in a SINGLE pass, matching one provisioning profile per bundle
    // by application-identifier suffix. So we can't just swap the per-bundle sign
    // call: we first walk the bundle tree to provision every bundle through the
    // Apple ID flow (download a profile, register its bundle id, write
    // embedded.mobileprovision), collecting every profile plus the shared signing
    // certificate/key AND a per-bundle entitlements plist, then invoke zsign ONCE
    // on the root bundle with all profiles as -m and the ROOT bundle's entitlements
    // as -e.
    // Why -e is required (fixes the iOS 17 re-sign launch crash): without -e,
    // zsign falls back to the provisioning profile's Entitlements. For a free /
    // wildcard account that is "application-identifier: TEAMID.*" — an INVALID
    // value inside a code signature — so iOS 17 rejects (crashes) the re-signed
    // app at launch. Passing -e with the SPECIFIC application-identifier (from
    // EEProvisioning's curated entitlements dict) fixes it. Note zsign applies the
    // one -e to every bundle, so nested extensions inherit the root
    // application-identifier; their embedded.mobileprovision is still correct from
    // the matched -m profile — the main app (the one that launches and was
    // crashing) is what gets fixed. A single pass is also required so zsign can
    // compute the main app's CodeResources consistently against the final nested
    // signatures.
    //
    // CRITICAL: -e MUST contain only entitlements authorised by the profile,
    // otherwise installd rejects the bundle at install time with 0xe8008015.
    // The free-account profile authorises exactly the 10 whitelist keys in
    // EEProvisioning.mm ~line 822. CS entitlements (allow-jit,
    // disable-library-validation, allow-unsigned-executable-memory) are NOT
    // in that whitelist and CANNOT be added to -e. They are runtime-patched
    // by libsubstitute on the jailbroken device. (v1.3.42/45 tried adding
    // them and they caused installd rejection — that's the rule this comment
    // is here to keep future maintainers from re-adding them.)
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    context[@"profiles"] = [NSMutableArray array];
    context[@"tempFiles"] = [NSMutableArray array];

    [self _provisionBundleAtPath:path identity:identity gsToken:gsToken priorChosenTeamID:teamId context:context withCompletionHandler:^(NSError *provisionError) {
        if (provisionError) {
            [self _cleanupTempFilesInContext:context];
            completionHandler(provisionError);
            return;
        }

        NSString *keyPath = context[@"keyPath"];
        NSString *certPath = context[@"certPath"];
        NSArray *profiles = context[@"profiles"];

        if (keyPath.length == 0 || certPath.length == 0 || profiles.count == 0) {
            [self _cleanupTempFilesInContext:context];
            completionHandler([self _errorFromString:@"Signing credentials were not obtained during provisioning."]);
            return;
        }

        // Sign the whole bundle tree in place with zsign (root entitlements as -e).
        // A single pass is required so zsign computes the main app's CodeResources
        // consistently against the final nested-bundle signatures. zsign applies the
        // one -e to every bundle, so nested extensions inherit the root
        // application-identifier (their own embedded.mobileprovision stays correct
        // from the matched -m profile); the main app — the one that launches and
        // was crashing — gets the specific application-identifier + cs.* safety
        // entitlements, which is what fixes the iOS 17 re-sign launch crash.
        NSString *rootEntitlementsPath = context[@"entitlementsPath"];

        // ARM64e fix (v1.1.10): drop the arm64e slice so dyld doesn't SIGBUS at
        // launch. Must run after provisioning (which reads the original binary for
        // entitlements) but before zsign signs the bundle.
        RZThinArm64eInBundle(path);

        // Relaxin / roothide jailbreak apps sometimes ship a .framework with NO
        // Info.plist (e.g. CydiaSubstrate.framework). installd rejects such a
        // malformed nested bundle with 0xe8008015, so fix it before zsign.
        RZFixFrameworkBundles(path);

        NSError *signError = nil;
        RZSignResult *result = [[RZSignRunner sharedRunner] signBundleAtPath:path
                                                                  outputPath:nil
                                                             certificatePath:certPath
                                                                     keyPath:keyPath
                                                           provisioningPaths:profiles
                                                            entitlementsPath:rootEntitlementsPath
                                                                   useSHA256:YES
                                                                       error:&signError];

        // Diagnostics for jailbreak-app re-sign failures (Relaxin etc.): surface
        // any Mach-O zsign left unsigned, and dump the profile/bundle-id match.
        RZVerifyBundleSigned(path);
        RZLogProfileDiagnostics(path);
        RZDumpProfileMatch(path, rootEntitlementsPath);

        [self _cleanupTempFilesInContext:context];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            if (!result.success) {
                error = signError ?: [self _errorFromString:@"zsign failed to sign the bundle."];
            }
            completionHandler(error);
        });
    }];
}

// Walks the bundle tree (root + PlugIns + Watch), provisioning every bundle via
// the Apple ID flow WITHOUT signing. For each bundle it downloads a provisioning
// profile, registers the (Team-ID-suffixed) bundle identifier, writes the
// bundle's embedded.mobileprovision, and collects a staged copy of that profile
// (plus, once, the shared certificate + private key) into `context` for the
// single zsign pass performed by signBundleAtPath:.
+ (void)_provisionBundleAtPath:(NSString *)path identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId context:(NSMutableDictionary *)context withCompletionHandler:(void (^)(NSError *error))completionHandler {
    dispatch_group_t dispatch_group = dispatch_group_create();
    NSMutableArray *__block subBundleErrors = [NSMutableArray array];

    if ([[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/PlugIns", path]]) {
        // Recurse through the plugins.

        for (NSString *subBundle in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@/PlugIns", path] error:nil]) {
            NSString *__block subBundlePath = [NSString stringWithFormat:@"%@/PlugIns/%@", path, subBundle];

            // Enter the dispatch group
            dispatch_group_enter(dispatch_group);

            NSLog(@"Provisioning sub-bundle: %@", subBundlePath);

            [self _provisionBundleAtPath:subBundlePath identity:identity gsToken:gsToken priorChosenTeamID:teamId context:context withCompletionHandler:^(NSError *error) {
                if (error)
                    [subBundleErrors addObject:error];

                NSLog(@"Finished provisioning sub-bundle: %@", subBundlePath);
                dispatch_group_leave(dispatch_group);
            }];
        }
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/Watch", path]]) {
        // Recurse through the watchOS stuff.

        for (NSString *subBundle in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithFormat:@"%@/Watch", path] error:nil]) {
            NSString *__block subBundlePath = [NSString stringWithFormat:@"%@/Watch/%@", path, subBundle];

            // Enter the dispatch group
            dispatch_group_enter(dispatch_group);

            NSLog(@"Provisioning sub-bundle: %@", subBundlePath);

            [self _provisionBundleAtPath:subBundlePath identity:identity gsToken:gsToken priorChosenTeamID:teamId context:context withCompletionHandler:^(NSError *error) {
                if (error)
                    [subBundleErrors addObject:error];

                NSLog(@"Finished provisioning sub-bundle: %@", subBundlePath);
                dispatch_group_leave(dispatch_group);
            }];
        }
    }

    // Wait on sub-bundles to finish, if needed.
    dispatch_group_wait(dispatch_group, DISPATCH_TIME_FOREVER);

    if (subBundleErrors.count > 0) {
        // Errors when handling sub-bundles!
        for (NSError *err in subBundleErrors) {
            NSLog(@"Error: %@", err.localizedDescription);
        }

        completionHandler([subBundleErrors lastObject]);
        return;
    }

    // 1. Read Info.plist to gain the applicationId and binaryLocation.
    // 2. Get provisioning profile and certificate info.
    NSString *plistPath = [NSString stringWithFormat:@"%@/Info.plist", path];
    NSMutableDictionary *infoplist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];

    if (!infoplist || [infoplist allKeys].count == 0) {
        NSError *error = [self _errorFromString:@"Failed to open Info.plist!"];
        completionHandler(error);
        return;
    }

    // Find the systemType for this bundle.
    NSString *platformName = [infoplist objectForKey:@"DTPlatformName"];
    EESystemType systemType = -1;
    if ([platformName isEqualToString:@"iphoneos"]) {
        systemType = EESystemTypeiOS;
    } else if ([platformName isEqualToString:@"watchos"]) {
        systemType = EESystemTypewatchOS;
    } else if ([platformName isEqualToString:@"tvos"]) {
        systemType = EESystemTypetvOS;
    } else {
        // Base case, assume iOS.
        systemType = EESystemTypeiOS;
    }

    NSLog(@"Platform: %@ for bundle: %@", platformName, [path lastPathComponent]);

    NSString *applicationId = [infoplist objectForKey:@"CFBundleIdentifier"];
    NSString *embeddedPath = [NSString stringWithFormat:@"%@/embedded.mobileprovision", path];
    BOOL isEmbeddedExists = [[NSFileManager defaultManager] fileExistsAtPath:embeddedPath];

    if (isEmbeddedExists) {
        BOOL isInstalledFromXcode = NO;
        BOOL isInstalledWithAnotherID = NO;

        NSString *profileString = [NSString stringWithContentsOfFile:embeddedPath encoding:NSISOLatin1StringEncoding error:nil];
        NSRange rangeOfTeamId = [profileString rangeOfString:teamId ?: @""];
        NSRange rangeOfXC = [profileString rangeOfString:@"XC "];
        if (rangeOfTeamId.location != NSNotFound && rangeOfXC.location != NSNotFound)
            isInstalledFromXcode = YES;
        else if (![applicationId hasSuffix:teamId]) {
            // application is installed with another apple id
            isInstalledWithAnotherID = YES;
        }

        if (isInstalledFromXcode || isInstalledWithAnotherID) {
            // This process should be done elsewhere and will be changed later
            // but i don't have enough time to understand the structure of this project.
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            [userInfo setObject:applicationId forKey:@"bundleIdentifier"];

            [[NSNotificationCenter defaultCenter] postNotificationName:@"jp.soh.reprovision/appShouldBeRemoved" object:nil userInfo:userInfo];
        }
    }

    if ([infoplist objectForKey:@"ALTBundleIdentifier"] != nil)
        applicationId = [infoplist objectForKey:@"ALTBundleIdentifier"];
    else if ([infoplist objectForKey:@"REBundleIdentifier"] != nil)
        applicationId = [infoplist objectForKey:@"REBundleIdentifier"];
    else
        [infoplist setObject:applicationId forKey:@"REBundleIdentifier"];

    // Capture the bundle id WITHOUT the .teamId suffix — used as a fallback when
    // EEProvisioning's entitlements dict lacks an explicit application-identifier.
    NSString *baseApplicationId = applicationId;

    applicationId = [applicationId stringByAppendingFormat:@".%@", teamId];
    [infoplist setObject:applicationId forKey:@"CFBundleIdentifier"];

    NSError *error = nil;
    if (@available(iOS 11.0, *)) {
        [infoplist writeToURL:[NSURL fileURLWithPath:plistPath] error:&error];
    } else {
        // Fallback on earlier versions
        [infoplist writeToURL:[NSURL fileURLWithPath:plistPath] atomically:YES];
    }

    if (error) {
        NSLog(@"%@", error);
        completionHandler(error);
        return;
    }

    NSString *applicationName = [infoplist objectForKey:@"CFBundleName"];
    NSString *binaryLocation = [path stringByAppendingFormat:@"/%@", [infoplist objectForKey:@"CFBundleExecutable"]];

    // We get entitlements from the binary using ldid::Analyze() during provisioning, updating them as needed
    // for the current Team ID.

    EEProvisioning *provisioner = [EEProvisioning provisionerWithCredentials:identity:gsToken];
    [provisioner downloadProvisioningProfileForApplicationIdentifier:applicationId applicationName:applicationName binaryLocation:(NSString *)binaryLocation withTeamIDCheck:^NSString *(NSArray *teams) {
        // If this is called, then the user is on multiple teams, and must be asked which one they want to use.
        // When integrated into an app, this backend can assume that this choice has been prior made, and so
        // we can return the result of that choice now.

        return teamId;
    } systemType:systemType andCallback:^(NSError *error, NSData *embeddedMobileProvision, NSString *privateKey, NSDictionary *certificate, NSDictionary *entitlements) {
        if (error) {
            completionHandler(error);
            return;
        }

        // We now have a valid provisioning profile for this application!
        // And, we also have a valid development codesigning certificate, with its private key!

        // Add embedded.mobileprovision to the bundle, overwriting if needed. zsign
        // will re-write this from the -m we pass, but keeping the bundle consistent
        // here is harmless.
        NSError *fileIOError;

        if (isEmbeddedExists) {
            [[NSFileManager defaultManager] removeItemAtPath:embeddedPath error:&fileIOError];

            if (fileIOError) {
                NSLog(@"%@", fileIOError);
                completionHandler(fileIOError);
                return;
            }
        }

        if (![(NSData *)embeddedMobileProvision writeToFile:embeddedPath options:NSDataWritingAtomic error:&fileIOError]) {
            NSError *writeError = fileIOError ?: [self _errorFromString:[NSString stringWithFormat:@"Failed to write '%@'.", embeddedPath]];
            NSLog(@"%@", writeError);
            completionHandler(writeError);
            return;
        }

        // Stage a standalone copy of this profile as an -m argument for zsign, and
        // (once) the shared certificate + private key.
        NSString *stagedProfile = [self _writeTempData:embeddedMobileProvision extension:@"mobileprovision" context:context];
        if (stagedProfile.length == 0) {
            completionHandler([self _errorFromString:@"Failed to stage provisioning profile for signing."]);
            return;
        }

        @synchronized(context) {
            [context[@"profiles"] addObject:stagedProfile];

            if (context[@"keyPath"] == nil) {
                NSData *certificateContent = [[NSData alloc] initWithBase64EncodedString:certificate[@"certificateContent"] options:0];
                NSString *stagedKey = [self _writeTempString:privateKey extension:@"pem" context:context];
                NSString *stagedCert = [self _writeTempData:certificateContent extension:@"cer" context:context];
                if (stagedKey.length && stagedCert.length) {
                    context[@"keyPath"] = stagedKey;
                    context[@"certPath"] = stagedCert;
                }
            }
        }

        // Build the explicit entitlements plist for zsign's -e from EEProvisioning's
// curated `entitlements` dict (which already carries the SPECIFIC
// application-identifier + team-identifier for THIS bundle and only the
// free-account whitelisted keys). Two requirements must be met simultaneously:
//   1. **The application-identifier in the code signature MUST be the SPECIFIC
//      "TEAMID.bundle.id"** — not the wildcard "TEAMID.*" the profile holds for
//      free accounts. Otherwise iOS 17 AMFI rejects and the app launch-crashes.
//      Passing -e with the specific app-id overrides zsign's profile-fallback
//      behaviour.
//   2. **Code-signature entitlements MUST be a STRICT SUBSET of the profile's
//      authorized Entitlements** — otherwise installd rejects the bundle with
//      "0xe8008015 no valid provisioning profile" at install time.
//
//      The free-account profile's whitelist is exactly the 10 keys in
//      EEProvisioning.mm ~line 822 (application-identifier,
//      com.apple.developer.team-identifier, keychain-access-groups,
//      com.apple.security.application-groups, default-data-protection,
//      healthkit, homekit, external-accessory.wireless-configuration,
//      inter-app-audio, get-task-allow). Anything else — including
//      com.apple.security.cs.allow-jit / disable-library-validation /
//      allow-unsigned-executable-memory — is NOT in the profile's whitelist,
//      and installd rejects ANY code signature that contains
//      profile-unauthorized entitlements.
//
// IMPLEMENTATION (v1.3.46, after three iterations of v1.3.42/44/45 tried
// different hypotheses about what was breaking installd):
//   - Output XML plist (NSPropertyListXMLFormat_v1_0) — _writeTempPlist:.
//     Defence-in-depth: zsign's jvalue.read_plist and the raw-bytes
//     passthrough in SlotBuildEntitlements both expect XML plist, so emitting
//     XML avoids any format ambiguity. (v1.3.41 emitted XML via zsign's own
//     style_write_plist when no -e was passed; v1.3.45 then started emitting
//     XML when -e WAS passed too — the format itself is correct.)
//   - **Pass -e with ONLY the whitelist keys** (forwarded from
//     EEProvisioning's curated dict, plus three defensive identity/debug
//     fallbacks). No CS entitlements, no other extras.
//   - Jailbreak tools (TrollFools, Relaxin, Frida, Ellekit, etc.) need
//     com.apple.security.cs.allow-jit / disable-library-validation /
//     allow-unsigned-executable-memory at RUNTIME to JIT / load unsigned
//     dylibs / mmap PROT_EXEC. These ARE NOT in the free-account profile
//     whitelist, so they CANNOT be put in code-signature entitlements
//     without breaking installd. They must instead be granted RUNTIME by the
//     jailbreak system: Dopamine ships libsubstitute (and rootless
//     distributions typically include ellekit) which patches the kernel
//     and libsystem to allow these operations WITHOUT explicit CS
//     entitlements in the app's own code signature. So on a properly
//     jailbroken device the runtime patches make the app work, and on a
//     non-jailbroken device the app is rightfully rejected anyway.
//
// HISTORY (recorded so we don't repeat the cycle):
//   v1.3.42: -e with EEProvisioning whitelist + CS entitlements + binary plist
//     → installd rejects (CS entitlement out-of-whitelist).
//   v1.3.44: -e with EEProvisioning whitelist ONLY + binary plist.
//     → STILL rejected (vl.3.44 author blamed binary plist; that was wrong).
//   v1.3.45: -e with EEProvisioning whitelist + CS entitlements + XML plist.
//     → STILL rejected (CS entitlement out-of-whitelist overrides any format fix).
//   v1.3.46 (this): -e with EEProvisioning whitelist ONLY + XML plist.
//     → expected to install cleanly. CS entitlement is a runtime concern,
//       handled by libsubstitute on the jailbroken device.
        NSMutableDictionary *rzEntitlements = [entitlements isKindOfClass:[NSDictionary class]] ? [entitlements mutableCopy] : [NSMutableDictionary dictionary];
        if (rzEntitlements[@"application-identifier"] == nil) {
            rzEntitlements[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, baseApplicationId];
        }
        if (rzEntitlements[@"com.apple.developer.team-identifier"] == nil) {
            rzEntitlements[@"com.apple.developer.team-identifier"] = teamId;
        }
        if (rzEntitlements[@"get-task-allow"] == nil) {
            rzEntitlements[@"get-task-allow"] = @YES;
        }

        NSString *stagedEntitlements = [self _writeTempPlist:rzEntitlements context:context];

        // The root bundle's entitlements also land in context[@"entitlementsPath"];
        // the root callback runs last (after the sub-bundle recursion), so it wins.
        @synchronized(context) {
            if (stagedEntitlements.length) {
                context[@"entitlementsPath"] = stagedEntitlements;
            }
        }

        completionHandler(nil);
    }];
}

// Writes `data` to a uniquely-named file in the temporary directory and records
// it in context[@"tempFiles"] for later cleanup. Returns the path, or nil on
// failure.
+ (NSString *)_writeTempData:(NSData *)data extension:(NSString *)ext context:(NSMutableDictionary *)context {
    if (data.length == 0) return nil;

    NSString *tmp = [NSString stringWithFormat:@"%@rpv_%@.%@", NSTemporaryDirectory(), [[NSUUID UUID] UUIDString], ext];
    NSError *err = nil;
    if (![data writeToFile:tmp options:NSDataWritingAtomic error:&err]) {
        NSLog(@"Failed to stage temp file '%@': %@", tmp, err);
        return nil;
    }

    @synchronized(context) {
        [context[@"tempFiles"] addObject:tmp];
    }
    return tmp;
}

+ (NSString *)_writeTempString:(NSString *)string extension:(NSString *)ext context:(NSMutableDictionary *)context {
    return [self _writeTempData:[string dataUsingEncoding:NSUTF8StringEncoding] extension:ext context:context];
}

// Serialises an entitlements dictionary to a temporary .plist and records it in
// context[@"tempFiles"] for later cleanup. Returns the path, or nil on failure.
//
// IMPORTANT: emits XML plist (NSPropertyListXMLFormat_v1_0), NOT binary plist.
// zsign's `jvalue.read_plist(strEntitlements)` in SlotBuildDerEntitlements
// (signing.cpp:322) and the raw-bytes passthrough in SlotBuildEntitlements
// (signing.cpp:297) both expect XML plist input. Passing a binary plist here
// leaves the code signature's __TEXT,__entitlements section as unreadable bytes,
// and iOS 17 installd rejects with "0xe8008015 no valid provisioning profile"
// (observed in v1.3.42–v1.3.44). v1.3.41 worked because zsign itself wrote
// the profile's Entitlements via `style_write_plist` (XML) when no -e was
// passed, so the format was always XML.
+ (NSString *)_writeTempPlist:(NSDictionary *)dict context:(NSMutableDictionary *)context {
    if (dict.count == 0) return nil;

    NSString *tmp = [NSString stringWithFormat:@"%@rpv_ent_%@.plist", NSTemporaryDirectory(), [[NSUUID UUID] UUIDString]];

    NSError *err = nil;
    NSData *xmlData = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&err];
    if (xmlData == nil) {
        NSLog(@"Failed to serialise entitlements as XML plist: %@", err);
        return nil;
    }
    if (![xmlData writeToFile:tmp options:NSDataWritingAtomic error:&err]) {
        NSLog(@"Failed to stage entitlements plist '%@': %@", tmp, err);
        return nil;
    }

    @synchronized(context) {
        [context[@"tempFiles"] addObject:tmp];
    }
    return tmp;
}

+ (void)_cleanupTempFilesInContext:(NSMutableDictionary *)context {
    @synchronized(context) {
        for (NSString *p in context[@"tempFiles"]) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
        [context[@"tempFiles"] removeAllObjects];
    }
}

+ (void)signIpaAtPath:(NSString *)ipaPath outputPath:(NSString *)outputPath identity:(NSString *)identity gsToken:(NSString *)gsToken priorChosenTeamID:(NSString *)teamId withCompletionHandler:(void (^)(NSError *))completionHandler {
    // 1. Unpack IPA to a temporary directory.
    NSError *error;
    NSString *unpackedDirectory;
    if (![self unpackIpaAtPath:ipaPath outDirectory:&unpackedDirectory error:&error]) {
        completionHandler(error);
        return;
    }

    // 2. Sign its main bundle via above method.
    // The bundle will be located at <temporarydirectory>/<zipfilename>/Payload/*.app internally

    NSString *zipFilename = [ipaPath lastPathComponent];
    zipFilename = [zipFilename stringByReplacingOccurrencesOfString:@".ipa" withString:@""];

    NSString *payloadDirectory = [NSString stringWithFormat:@"%@/Payload", unpackedDirectory];

    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDirectory error:&error];

    if (error) {
        completionHandler(error);
        return;
    } else if (files.count == 0) {
        NSError *err = [self _errorFromString:@"Payload directory of IPA has no contents"];
        completionHandler(err);
        return;
    }

    NSString *dotAppDirectory = @"";
    for (NSString *directory in files) {
        if ([directory containsString:@".app"]) {
            dotAppDirectory = directory;
            break;
        }
    }

    NSString *bundleDirectory = [NSString stringWithFormat:@"%@/%@", payloadDirectory, dotAppDirectory];

    NSLog(@"Signing bundle at path '%@'", bundleDirectory);

    [self signBundleAtPath:bundleDirectory identity:identity gsToken:gsToken priorChosenTeamID:teamId withCompletionHandler:^(NSError *err) {
        if (err) {
            completionHandler(err);
            return;
        }

        // 3. Repack IPA to output path
        NSError *error2;
        if (![self repackIpaAtPath:[NSString stringWithFormat:@"%@/%@", [self applicationTemporaryDirectory], zipFilename] toPath:outputPath error:&error2]) {
            completionHandler(error2);
        } else {
            // Success!
            completionHandler(nil);
        }
    }];
}

+ (BOOL)unpackIpaAtPath:(NSString *)ipaPath outDirectory:(NSString **)outputDirectory error:(NSError **)error {
    // Sanity checks.
    if (![ipaPath hasSuffix:@".ipa"]) {
        if (error)
            *error = [self _errorFromString:@"Input file specified is not an IPA!"];
        return NO;
    }

    if (!outputDirectory) {
        if (error)
            *error = [self _errorFromString:@"No outputDirectory; how will you know where the IPA was extracted to?"];
        return NO;
    }

    NSString *zipFilename = [ipaPath lastPathComponent];
    zipFilename = [zipFilename stringByReplacingOccurrencesOfString:@".ipa" withString:@""];

    *outputDirectory = [NSString stringWithFormat:@"%@/%@", [self applicationTemporaryDirectory], zipFilename];

    NSLog(@"Unpacking '%@' into directory '%@'", ipaPath, *outputDirectory);

    if (![SSZipArchive unzipFileAtPath:ipaPath toDestination:*outputDirectory]) {
        if (error)
            *error = [self _errorFromString:@"Failed to unpack IPA!"];
        return NO;
    }

    return YES;
}

+ (BOOL)repackIpaAtPath:(NSString *)extractedPath toPath:(NSString *)outputPath error:(NSError **)error {
    // Sanity checks.
    if (![outputPath hasSuffix:@".ipa"]) {
        if (error)
            *error = [self _errorFromString:@"Output file specified is not an IPA!"];
        return NO;
    }

    NSLog(@"Creating IPA from contents of '%@", extractedPath);

    // Ensure permissions are at least read on everyone.


    if (![SSZipArchive createZipFileAtPath:outputPath withContentsOfDirectory:extractedPath]) {
        if (error)
            *error = [self _errorFromString:@"Failed to repack IPA!"];
        return NO;
    }

    return YES;
}

+ (NSString *)applicationTemporaryDirectory {
    NSString *tempDir = NSTemporaryDirectory();
    if (!tempDir)
        tempDir = @"/tmp";

    if (![[NSFileManager defaultManager] fileExistsAtPath:tempDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:tempDir withIntermediateDirectories:NO attributes:nil error:nil];
    }

    return tempDir;
}

+ (NSError *)_errorFromString:(NSString *)string {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:-1
                                     userInfo:userInfo];

    return error;
}

@end
