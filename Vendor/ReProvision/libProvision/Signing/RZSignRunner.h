//
//  RZSignRunner.h
//  ReProvision Reborn (Rootless)
//
//  zsign call layer. Replaces the old ldid-based signing in EESigning.
//  zsign is spawned as a separate process (process isolation). zsign is MIT
//  licensed, so there is no GPL contamination.
//
//  Signing model (verified against zsign's src/bundle.cpp):
//  * When given a .app FOLDER, zsign recursively re-signs every nested
//    .appex / .framework in one pass.
//  * For each nested bundle it does NOT read that bundle's own
//    embedded.mobileprovision. Instead it matches, by application-identifier
//    suffix, one of the provisioning profiles passed on the command line
//    (multiple -m) against the bundle's CFBundleIdentifier, and writes that
//    profile in. A bundle with no matching profile is signed invalidly.
//  * Therefore the caller MUST pass one provisioning profile per bundle
//    (root app + every extension) via `provisioningPaths`.
//  * Entitlements are taken from each matched provisioning profile
//    automatically, so no explicit -e is required (and passing an over-broad
//    -e is what previously caused installd rejection / iOS 17 crashes).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RZSignResult : NSObject
@property (nonatomic, assign) int exitCode;
@property (nonatomic, copy, nullable) NSString *standardOutput;
@property (nonatomic, copy, nullable) NSString *standardError;
@property (nonatomic, assign) BOOL success;
@end

@interface RZSignRunner : NSObject

+ (instancetype)sharedRunner;

/// Locates the zsign binary. RootHide is detected first via the .jbroot symlink
/// next to the app bundle (roothide installs into a random per-boot jbroot, not
/// the fixed /var/jb). Then:
///   Rootless (Dopamine): /var/jb/usr/local/bin/zsign
///   Rootful / RootHide:  /usr/local/bin/zsign
/// Falls back to $PATH.
- (nullable NSString *)zsignBinaryPath;

/// Re-signs a .app bundle (or Mach-O) at `inputPath`.
///
/// @param inputPath         bundle or binary to sign
/// @param outputPath        where to write the signed .ipa. Pass nil to sign
///                          the folder IN PLACE (no -o) — this is what the
///                          ReProvision flow uses.
/// @param certPEMPath       certificate file path (PEM or DER)
/// @param keyPEMPath        private key file path (PEM or DER)
/// @param provisioningPaths one provisioning profile per bundle (root + every
///                          extension). Passed as repeated -m arguments.
/// @param entitlementsPath  explicit entitlements plist path, or nil to let
///                          zsign use each profile's own entitlements
///                          (recommended).
/// @param useSHA256         pass -2 (SHA-256 only) — recommended on iOS 16+
/// @param error             populated on spawn / non-zero exit
- (RZSignResult *)signBundleAtPath:(NSString *)inputPath
                        outputPath:(nullable NSString *)outputPath
                   certificatePath:(NSString *)certPEMPath
                           keyPath:(NSString *)keyPEMPath
                 provisioningPaths:(NSArray<NSString *> *)provisioningPaths
                  entitlementsPath:(nullable NSString *)entitlementsPath
                         useSHA256:(BOOL)useSHA256
                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
