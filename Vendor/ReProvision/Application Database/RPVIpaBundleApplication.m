//
//  RPVIpaBundleApplication.m
//  iOS
//
//  Created by Matt Clarke on 21/07/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVIpaBundleApplication.h"

// 声明 App 侧的 RootHide 环境探测（定义在 RPVBridge.m，App 二进制内可链接）。
extern BOOL RPVIsRootHideEnvironment(void);

#define IS_IPAD (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)

@interface UIImage (Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface RPVIpaBundleApplication ()

@property (nonatomic, strong) NSDictionary *cachedInfoPlist;
@property (nonatomic, strong) UIImage *cachedIconImage;
@property (nonatomic, strong) NSNumber *uncompressedSize;

@property (nonatomic, strong) NSString *_tmp_zipFileRequested;
@property (nonatomic, readwrite) BOOL _tmp_zipUncompressedSizeRequested;
@property (nonatomic, readwrite) int _tmp_zipUncompressedSize;

@end

static BOOL (^_rpvDaemonFileCopyHandler)(NSString *srcPath, NSString *dstPath) = nil;

@implementation RPVIpaBundleApplication

+ (void)setDaemonFileCopyHandler:(BOOL (^)(NSString *srcPath, NSString *dstPath))handler {
    _rpvDaemonFileCopyHandler = [handler copy];
}

- (instancetype)initWithIpaURL:(NSURL *)url {
    self = [super init];

    if (self) {
        // URLs handed to us from the Files app / "Open in" / document picker are
        // security-scoped: they can't be read without startAccessingSecurityScopedResource,
        // and the scope is only valid briefly. Copy the .ipa into our own tmp dir up
        // front so every later read (Info.plist parse here, and the unzip during the
        // actual signing) works regardless of the source. Without this the Info.plist
        // comes back empty -> nil bundleIdentifier/name/icon and a crash on install.
        NSURL *localURL = [self _importToLocalCopy:url];
        if (!localURL) localURL = url;

        // Initialise by pre-loading information from the .ipa file.
        self.cachedInfoPlist = [self _loadInfoPlistFromURL:localURL];
        self.cachedIconImage = [self _loadApplicationIconFromURL:localURL withInfoPlist:self.cachedInfoPlist];
        self.uncompressedSize = [self _loadUncompressedFileSizeFromURL:localURL];

        self.cachedURL = localURL;
    }

    return self;
}

- (NSURL *)_importToLocalCopy:(NSURL *)url {
    if (!url) return nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];

    // iCloud Drive / 第三方 File Provider 上的文件在下载前只是 .icloud 占位符。
    // 下面 coordinateReadingItemAtURL: 的访问器会触发下载，但提前显式 startDownloading
    // 能让快路径的 copyItemAtURL: 直接拿到真实文件而非 stub，避免复制到一个空占位符。
    if (scoped && [url isFileURL]) {
        if ([[NSFileManager defaultManager] respondsToSelector:@selector(startDownloadingUbiquitousItemAtURL:error:)]) {
            NSError *dlErr = nil;
            [[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:url error:&dlErr];
        }
    }

    NSString *tmp = NSTemporaryDirectory();
    if (!tmp) tmp = @"/tmp";

    // RootHide：App 的 NSTemporaryDirectory() 落在 jbroot overlay namespace，
    // 而拷贝兜底（repro-importdaemon）跑在真实 rootfs 命名空间，两边看不到对方的
    // 路径。统一落到真实共享路径 /var/mobile/Library/RePro/imports/<uuid>（App 与
    // rootfs daemon 都能读写，正是 profiledaemon 用的 IPC 目录），避免路径对不上。
    BOOL isRootHide = RPVIsRootHideEnvironment();
    NSString *baseDir = isRootHide ? @"/var/mobile/Library/RePro/imports" : tmp;

    // Namespace the copy so concurrent imports don't clash, but keep the original
    // filename so the .ipa extension (checked downstream) is preserved.
    NSString *destDir = [baseDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [destDir stringByAppendingPathComponent:[url lastPathComponent]];

    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&err];

    // copyItemAtURL: can fail for files handed over by other processes (e.g. the
    // share extension's container). Fall back to a coordinated NSData read+write,
    // which works when we have broad file access but the path-level copy is denied.
    if (!ok) {
        NSError *readErr = nil;
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readErr];
        if (!data) {
            NSError *coordErr = nil;
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            __block NSData *coordinated = nil;
            [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordErr byAccessor:^(NSURL *newURL) {
                coordinated = [NSData dataWithContentsOfURL:newURL options:0 error:nil];
            }];
            data = coordinated;
        }
        if (data) {
            ok = [data writeToFile:dest options:NSDataWritingAtomic error:&err];
        }
    }

    // Final fallback: hand the raw path to the daemon copy handler. On rootless/rootful
    // this is repro-helper (setuid root) doing the copy. On RootHide it's repro-importdaemon
    // (launchd 在系统级 rootfs 命名空间拉起) —— 因为 App 及其 posix_spawn 出的
    // helper 都在 jbroot overlay namespace 内，读不到 iCloud 真实路径；只有跑在真实
    // rootfs 的 LaunchDaemon 能读真实 /var/mobile/Library/Mobile Documents 下的文件，
    // 把它拷到真实共享路径 /var/mobile/Library/RePro/imports/（App 也能读回）。
    if (!ok && _rpvDaemonFileCopyHandler && [url isFileURL] && [url path].length > 0) {
        ok = _rpvDaemonFileCopyHandler([url path], dest);
    }

    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!ok) {
        NSLog(@"*** [ReProvision] :: failed to import IPA to local copy: %@", err);
        return nil;
    }

    return [NSURL fileURLWithPath:dest];
}

- (NSNumber *)_loadUncompressedFileSizeFromURL:(NSURL *)url {
    self._tmp_zipUncompressedSizeRequested = YES;
    self._tmp_zipUncompressedSize = 0;
    BOOL success = [SSZipArchive unzipFileAtPath:[url path] toDestination:NSTemporaryDirectory() delegate:self];
    self._tmp_zipUncompressedSizeRequested = NO;

    if (success) {
        return [NSNumber numberWithInt:self._tmp_zipUncompressedSize];
    } else {
        return @0;
    }
}

- (NSDictionary *)_loadInfoPlistFromURL:(NSURL *)url {
    NSData *data = [self _loadFileWithFormat:@"Payload/*/Info.plist" fromIPA:url multipleCandiateChooser:^NSString *(NSArray *candidates) {
        return [candidates firstObject];
    }];

    NSDictionary *dict = @{};
    if (data) dict = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];

    return dict;
}

- (UIImage *)_loadApplicationIconFromURL:(NSURL *)url withInfoPlist:(NSDictionary *)infoPlist {
    // Check if this Info.plist has any icons.
    if (![infoPlist.allKeys containsObject:@"CFBundleIcons"] && ![infoPlist.allKeys containsObject:@"CFBundleIcons~ipad"]) {
        return [UIImage _applicationIconImageForBundleIdentifier:@"" format:2 scale:[UIScreen mainScreen].scale];
    } else {
        NSDictionary *icons;
        BOOL usingIpadIcons = NO;
        if (!IS_IPAD)
            icons = [infoPlist objectForKey:@"CFBundleIcons"];
        else {
            // Prefer iPad icons, but fallback to iPhone if needed.
            if ([infoPlist.allKeys containsObject:@"CFBundleIcons~ipad"]) {
                icons = [infoPlist objectForKey:@"CFBundleIcons~ipad"];
                usingIpadIcons = YES;
            } else
                icons = [infoPlist objectForKey:@"CFBundleIcons"];
        }

        BOOL iconExists = [icons.allKeys containsObject:@"CFBundlePrimaryIcon"] &&  [[[icons objectForKey:@"CFBundlePrimaryIcon"] allKeys] containsObject:@"CFBundleIconFiles"];
        NSData *data = nil;

        if (iconExists) {
            NSString *iconFileName = [[[icons objectForKey:@"CFBundlePrimaryIcon"] objectForKey:@"CFBundleIconFiles"] lastObject];

            // Add suffix as needed.

            // Now load this from the .ipa file
            NSString *fileFormat = [NSString stringWithFormat:@"Payload/*/%@", iconFileName];

            data = [self _loadFileWithFormat:fileFormat fromIPA:url multipleCandiateChooser:^NSString *(NSArray *candidates) {
                NSArray *suffixPreferences = @[@"@3x", @"@2x", @""];

                // Choose which candidate is best for the current device, and fallback as needed.
                NSString *currentBest = @"";
                int currentBestRank = 2;

                BOOL anyHaveIpadSuffix = NO;
                for (NSString *item in candidates) {
                    if ([item containsString:@"~ipad"]) {
                        anyHaveIpadSuffix = YES;
                        break;
                    }
                }

                for (NSString *item in candidates) {
                    if (IS_IPAD && anyHaveIpadSuffix && ![item containsString:@"~ipad"])
                        continue;

                    // Alright, maybe this one.

                    // Base case
                    if ([currentBest isEqualToString:@""]) {
                        currentBest = item;
                        currentBestRank = [self _rankItem:item forSuffixes:suffixPreferences];
                    }

                    // Go through the suffix preferences, and rank the currentBest and the new item.
                    int itemRank = [self _rankItem:item forSuffixes:suffixPreferences];

                    if (itemRank < currentBestRank) {
                        currentBest = item;
                        currentBestRank = itemRank;
                    }
                }

                return currentBest;
            }];
        }

        if (data)
            return [self _maskApplicationIcon:[UIImage imageWithData:data]];
        else
            return [UIImage _applicationIconImageForBundleIdentifier:@"" format:2 scale:[UIScreen mainScreen].scale];
    }
}

- (int)_rankItem:(NSString *)item forSuffixes:(NSArray *)suffixes {
    int rank = (int)suffixes.count - 1;

    for (int i = 0; i < suffixes.count; i++) {
        NSString *suffix = [suffixes objectAtIndex:i];

        if ([item containsString:suffix]) {
            rank = i;
            break;
        }
    }

    return rank;
}

- (UIImage *)_maskApplicationIcon:(UIImage *)icon {
    UIImage *maskImage;
    @try {
        NSBundle *mobileIconsBundle = [NSBundle bundleWithIdentifier:@"com.apple.mobileicons.framework"];
        if (mobileIconsBundle) {
            if (IS_IPAD)
                maskImage = [UIImage imageNamed:@"AppIconMask~ipad" inBundle:mobileIconsBundle compatibleWithTraitCollection:nil];
            else
                maskImage = [UIImage imageNamed:@"AppIconMask~iphone" inBundle:mobileIconsBundle compatibleWithTraitCollection:nil];
        }
    } @catch (NSException *e) {
        // Really?! This is usually caused by AnemoneIcons.dylib
    }

    // See: https://stackoverflow.com/a/8127762
    CGImageRef maskRef = maskImage.CGImage;

#define ROUND_UP(N, S) ((((N) + (S)-1) / (S)) * (S))

    float width = CGImageGetWidth(maskRef);
    float height = CGImageGetHeight(maskRef);

    // Make a bitmap context that's only 1 alpha channel
    // WARNING: the bytes per row probably needs to be a multiple of 4
    int strideLength = ROUND_UP(width * 1, 4);
    unsigned char *alphaData = calloc(strideLength * height, sizeof(unsigned char));
    CGContextRef alphaOnlyContext = CGBitmapContextCreate(alphaData,
                                                          width,
                                                          height,
                                                          8,
                                                          strideLength,
                                                          NULL,
                                                          kCGImageAlphaOnly);

    // Draw the RGBA image into the alpha-only context.
    CGContextDrawImage(alphaOnlyContext, CGRectMake(0, 0, width, height), maskRef);

    // Walk the pixels and invert the alpha value. This lets you colorize the opaque shapes in the original image.
    // If you want to do a traditional mask (where the opaque values block) just get rid of these loops.
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            unsigned char val = alphaData[y * strideLength + x];
            val = 255 - val;
            alphaData[y * strideLength + x] = val;
        }
    }

    CGImageRef alphaMaskImage = CGBitmapContextCreateImage(alphaOnlyContext);
    CGContextRelease(alphaOnlyContext);
    free(alphaData);

    // Make a mask
    CGImageRef finalMaskImage = CGImageMaskCreate(CGImageGetWidth(alphaMaskImage),
                                                  CGImageGetHeight(alphaMaskImage),
                                                  CGImageGetBitsPerComponent(alphaMaskImage),
                                                  CGImageGetBitsPerPixel(alphaMaskImage),
                                                  CGImageGetBytesPerRow(alphaMaskImage),
                                                  CGImageGetDataProvider(alphaMaskImage), NULL, false);
    CGImageRelease(alphaMaskImage);

    CGImageRef masked = CGImageCreateWithMask([icon CGImage], finalMaskImage);

    CGImageRelease(finalMaskImage);

    return [UIImage imageWithCGImage:masked];
}

- (NSData *)_loadFileWithFormat:(NSString *)fileFormat fromIPA:(NSURL *)url multipleCandiateChooser:(NSString * (^)(NSArray *candidates))candidateChooser {
    NSString *destinationPath = NSTemporaryDirectory();
    if (!destinationPath)
        destinationPath = @"/tmp";

    NSString *uniquePath = [[NSUUID UUID] UUIDString];

    destinationPath = [destinationPath stringByAppendingString:uniquePath];

    // Load this file only from the zip.
    self._tmp_zipFileRequested = fileFormat;
    BOOL success = [SSZipArchive unzipFileAtPath:[url path] toDestination:destinationPath delegate:self];
    self._tmp_zipFileRequested = nil;

    if (success) {
        // Extracted the Info.plist file.
        for (NSString *pathComponent in [fileFormat pathComponents]) {
            if ([pathComponent isEqualToString:@"*"]) {
                // Expand the wildcard directory out.
                NSString *wildcardDirectory = nil;
                NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:destinationPath error:nil];
                for (NSString *file in contents) {
                    if (![file isEqualToString:@".DS_Store"]) {
                        wildcardDirectory = file;
                        break;
                    }
                }

                destinationPath = [destinationPath stringByAppendingFormat:@"/%@", wildcardDirectory];
            } else {
                destinationPath = [destinationPath stringByAppendingFormat:@"/%@", pathComponent];
            }
        }

        // We now have a fully qualified path. However, we also allow the usage of prefixes as the final path component.
        // In that situation, return the last file.

        NSArray *destinationContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[destinationPath stringByDeletingLastPathComponent] error:nil];

        if (destinationContents.count > 1) {
            destinationPath = [NSString stringWithFormat:@"%@/%@", [destinationPath stringByDeletingLastPathComponent], candidateChooser(destinationContents)];
        } else {
            destinationPath = [NSString stringWithFormat:@"%@/%@", [destinationPath stringByDeletingLastPathComponent], [destinationContents lastObject]];
        }

        NSData *data = [NSData dataWithContentsOfFile:destinationPath];

        // Delete directory structure from disk.
        NSString *tempDir = NSTemporaryDirectory();
        if (!tempDir)
            tempDir = @"/tmp";

        destinationPath = [tempDir stringByAppendingFormat:@"/%@", uniquePath];
        [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];

        return data;
    } else {
        return [NSData data];
    }
}

- (NSString *)bundleIdentifier {
    return [self.cachedInfoPlist objectForKey:@"CFBundleIdentifier"];
}
- (NSString *)applicationName {
    return [self.cachedInfoPlist objectForKey:@"CFBundleDisplayName"] != nil ? [self.cachedInfoPlist objectForKey:@"CFBundleDisplayName"] : [self.cachedInfoPlist objectForKey:@"CFBundleName"];
}

- (NSString *)applicationVersion {
    return [self.cachedInfoPlist objectForKey:@"CFBundleShortVersionString"];
}
- (NSNumber *)applicationInstalledSize {
    return self.uncompressedSize;
}

- (UIImage *)applicationIcon {
    return self.cachedIconImage;
}

- (NSDate *)applicationExpiryDate {
    return [NSDate date];
}

- (NSURL *)locationOfApplicationOnFilesystem {
    return self.cachedURL;
}

// SSZipArchive delegate
- (BOOL)zipArchiveShouldUnzipFileWithName:(NSString *)name fileInfo:(unz_file_info)fileInfo {
    // Update uncompressedSize if needed.
    if (self._tmp_zipUncompressedSizeRequested) {
        self._tmp_zipUncompressedSize += fileInfo.uncompressed_size;

        return NO;
    }

    int tmpPathComponentCount = (int)[self._tmp_zipFileRequested pathComponents].count;
    int givenCount = (int)[name pathComponents].count;

    if (tmpPathComponentCount != givenCount) {
        return NO;
    }

    if ([[name lastPathComponent] isEqualToString:[self._tmp_zipFileRequested lastPathComponent]] ||
        [[name lastPathComponent] hasPrefix:[self._tmp_zipFileRequested lastPathComponent]])
        return YES;

    return NO;
}

@end
