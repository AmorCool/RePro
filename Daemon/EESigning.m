//
//  EESigning.m
//  ReProvision Daemon
//
//  ldid 内嵌签名核心实现（从旧项目 EESigning.mm 精简移植）
//  核心依赖：libldid (ldid.hpp)、OpenSSL (pkcs12/pem/x509)
//

#import "EESigning.h"
#include "ldid.hpp"

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <stdio.h>

#pragma mark - ldid 链接必需的 dummy 符号

// ldid 库链接时需要此符号，否则链接失败
static auto dummy([](double) {});

#pragma mark - Entitlements 白名单工具函数

/// 从 embedded.mobileprovision 提取允许的 entitlement 键集合
/// 权威来源是 Apple 为此 app 签发的描述文件中的 Entitlements 字典
/// 超出此集合的键（iCloud/CloudKit、associated-domains、app groups、push、
/// platform-application / run-unsigned-code / com.apple.private.* 等）
/// 必须被剔除，否则 installd 拒绝安装 (0xe8008001) 或启动后立即被杀
static NSSet *RPVAllowedEntitlementKeys(NSString *bundlePath) {
    // 基础白名单：几乎所有 profile 都允许的键 + game-center（无害且被容忍）
    NSMutableSet *allowed = [NSMutableSet setWithObjects:
        @"application-identifier",
        @"com.apple.developer.team-identifier",
        @"keychain-access-groups",
        @"get-task-allow",
        @"com.apple.developer.game-center",
        nil];

    // 尝试从 bundle 中的 embedded.mobileprovision 读取额外允许的键
    NSString *profilePath = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    NSString *content = [NSString stringWithContentsOfFile:profilePath encoding:NSISOLatin1StringEncoding error:nil];
    NSRange s = [content rangeOfString:@"<plist"];
    NSRange e = [content rangeOfString:@"</plist>"];
    if (content && s.location != NSNotFound && e.location != NSNotFound) {
        NSString *plistStr = [content substringWithRange:NSMakeRange(s.location, e.location + e.length - s.location)];
        NSDictionary *prof = [NSPropertyListSerialization propertyListWithData:[plistStr dataUsingEncoding:NSUTF8StringEncoding] options:0 format:NULL error:nil];
        NSDictionary *profEnt = prof[@"Entitlements"];
        if ([profEnt isKindOfClass:[NSDictionary class]]) {
            [allowed addObjectsFromArray:[profEnt allKeys]];
        }
    }

    return allowed;
}

/// 清理 XML entitlements 字符串，移除不在白名单中的键
/// 用于嵌套 framework/dylib 的 entitlements（来自 ldid::Analyze 的 XML 格式）
static std::string RPVSanitizeEntitlementsXML(const std::string &xml, NSSet *allowed) {
    if (xml.empty()) return xml;

    // XML 字符串可能在 </plist> 后有尾随 NUL/垃圾数据，截断到 plist 结束处
    std::string trimmed = xml;
    size_t end = trimmed.rfind("</plist>");
    if (end != std::string::npos) trimmed = trimmed.substr(0, end + 8);

    NSData *data = [NSData dataWithBytes:trimmed.data() length:trimmed.size()];
    NSError *err = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:&err];
    if (![plist isKindOfClass:[NSDictionary class]]) return xml;

    NSMutableDictionary *dict = (NSMutableDictionary *)plist;
    BOOL changed = NO;
    for (NSString *key in [dict allKeys]) {
        if (![allowed containsObject:key]) {
            [dict removeObjectForKey:key];
            changed = YES;
        }
    }
    if (!changed) return xml;

    NSData *out = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
    if (out == nil) return xml;
    return std::string((const char *)out.bytes, out.length);
}

#pragma mark - 私有辅助方法（PKCS12 / CA Chain / Requirements）

@interface EESigning (Private)

/// 使用 OpenSSL 构建 PKCS12 证书（私钥 + 证书 + CA chain）
- (std::string)_createPKCS12CertificateWithKey:(NSString *)key
                                   certificate:(NSData *)certificate
                                    andCAChain:(X509 *)chain;

/// 根据证书 issuer hash 选择正确的中间 CA 证书并加载
- (X509 *)_loadCAChainFromDiskForCertificate:(NSData *)certificate;

/// 创建 Code Signing Requirements blob
/// 注意：当前返回空字符串，因为 iOS 不抱怨空的 requirements，
/// 且 SecRequirement* 系列符号在 iOS 上不存在，正确实现成本过高
- (std::string)_createRequirementsBlobWithKey:(NSString *)key
                                  certificate:(NSData *)certificate
                          andBundleIdentifier:(NSString *)identifier;

/// 从 X509 证书提取 Common Name
- (std::string)_commonNameForCert:(X509 *)cert;

@end

@implementation EESigning

#pragma mark - 公开类方法

/// 使用 ldid 对 .app bundle 进行完整内嵌签名
/// 流程：构建 PKCS12 → 过滤 entitlements → ldid::Sign() 签名整个 bundle
+ (BOOL)signAppBundle:(NSString *)appPath
       certificateData:(NSData *)certData
              keyData:(NSData *)keyData
   entitlementsString:(nullable NSString *)entitlementsString
      provisioningPaths:(NSArray<NSString *> *)provPaths
             useSHA256:(BOOL)useSHA256
                 error:(NSError **)error {

    @try {
        // 1. 将 keyData 转为 PEM 字符串格式
        NSString *privateKeyPEM = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
        if (!privateKeyPEM || privateKeyPEM.length == 0) {
            if (error) *error = [NSError errorWithDomain:@"RePro.EESigning" code:100 userInfo:@{
                NSLocalizedDescriptionKey: @"私钥数据无法解析为 UTF-8 字符串"
            }];
            return NO;
        }

        // 2. 加载 CA chain（根据证书 issuer 选择正确的中间证书）
        EESigning *signer = [[EESigning alloc] init];
        X509 *caChain = [signer _loadCAChainFromDiskForCertificate:certData];

        // 3. 构建 PKCS12 证书（私钥 + 开发者证书 + CA chain）
        std::string pkcs12 = [signer _createPKCS12CertificateWithKey:privateKeyPEM
                                                        certificate:certData
                                                         andCAChain:caChain];
        X509_free(caChain);

        if (pkcs12.size() == 0) {
            if (error) *error = [NSError errorWithDomain:@"RePro.EESigning" code:101 userInfo:@{
                NSLocalizedDescriptionKey: @"PKCS12 证书构建失败"
            }];
            return NO;
        }

        // 4. 解析传入的 entitlements（XML 或 JSON 格式）
        NSMutableDictionary *entitlements = [NSMutableDictionary dictionary];
        if (entitlementsString && entitlementsString.length > 0) {
            NSData *entData = [entitlementsString dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *parsed = [NSPropertyListSerialization propertyListWithData:entData
                                                                            options:0
                                                                             format:NULL
                                                                              error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                entitlements = [parsed mutableCopy];
            }
        }

        // 5. 基于 embedded.mobileprovision 构建白名单，过滤掉不允许的 entitlement 键
        NSSet *allowedEntitlementKeys = RPVAllowedEntitlementKeys(appPath);
        NSMutableDictionary *cleanEntitlements = [entitlements mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in [cleanEntitlements allKeys]) {
            if (![allowedEntitlementKeys containsObject:key]) {
                NSLog(@"*** [RePro] 剥离不支持的 entitlement: %@", key);
                [cleanEntitlements removeObjectForKey:key];
            }
        }

        // 6. 将清理后的 entitlements 序列化为 XML（ldid 要求的格式），追加 NUL 终止符
        NSError *serializeError;
        NSMutableData *exportedPlist = [[NSPropertyListSerialization dataWithPropertyList:cleanEntitlements
                                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                                 options:0
                                                                                   error:&serializeError] mutableCopy];
        [exportedPlist appendBytes:"\x0" length:1];
        std::string entitlementsStringStd((const char *)[exportedPlist bytes], [exportedPlist length]);

        NSLog(@"[RePro] Entitlements:\n%s", entitlementsStringStd.c_str());

        // 7. 生成 requirements blob（当前为空字符串，见方法注释）
        std::string requirementsString = [signer _createRequirementsBlobWithKey:privateKeyPEM
                                                                   certificate:certData
                                                           andBundleIdentifier:@""];

        // 8. 调用 ldid::Sign() 对整个 bundle 进行签名
        ldid::DiskFolder folder([[appPath copy] cStringUsingEncoding:NSUTF8StringEncoding]);

        // alter 回调：对 bundle 中每个 Mach-O 分别处理
        //   - path == ""          → 主执行文件：使用清理后的 app entitlements
        //   - path 包含 ".appex"  → App Extension：保留自身 entitlements 但做白名单过滤
        //   - 其他（framework/dylib）→ 不附加 entitlements（正规 app 的框架不应有 entitlements blob）
        ldid::Bundle outputBundle = Sign("", folder, pkcs12, requirementsString,
            ldid::fun([&](const std::string &path, const std::string &original) -> std::string {
                std::string result;
                if (path.empty()) {
                    // 主执行文件：使用（经过白名单过滤的）app entitlements
                    result = entitlementsStringStd;
                } else if (path.find(".appex") != std::string::npos) {
                    // App Extension：保留自身 entitlements，仅做白名单过滤
                    result = RPVSanitizeEntitlementsXML(original, allowedEntitlementKeys);
                } else {
                    // Framework / dylib：不附加任何 entitlements
                    // 正规构建的 app 中框架不含 entitlements blob；
                    // 即使只留 get-task-allow 也会导致 installd 拒绝整个 bundle (0xe8008001)
                    result = "";
                }
                return result;
            }),
            ldid::fun([&](const std::string &) {}),  // commit 回调（留空）
            ldid::fun(dummy)                          // progress 回调（ldid 链接需要）
        );

        // TODO: 检查 outputBundle 中的错误状态并填充 error

        return YES;

    } @catch (NSException *exception) {
        NSLog(@"[RePro] EESigning 异常: %@ - %@", exception.name, exception.reason);
        if (error) *error = [NSError errorWithDomain:@"RePro.EESigning" code:102 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"签名异常: %@", exception.reason ?: @"未知错误"]
        }];
        return NO;
    }
}

/// 使用 ldid::Analyze() 从二进制文件提取原始 entitlements
+ (nullable NSDictionary *)analyzeEntitlementsFromBinaryAtPath:(NSString *)binaryPath
                                                      error:(NSError **)error {
    NSLog(@"[RePro] 分析二进制 entitlements: '%@'", binaryPath);

    // 读取二进制文件数据
    NSData *binaryData = [NSData dataWithContentsOfFile:binaryPath];
    if (!binaryData || binaryData.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"RePro.EESigning" code:200 userInfo:@{
            NSLocalizedDescriptionKey: @"无法读取二进制文件或文件为空"
        }];
        return nil;
    }

    // 调用 ldid::Analyze() 提取嵌入在二进制中的 entitlements（XML 格式）
    std::string entitlements = ldid::Analyze([binaryData bytes], (size_t)[binaryData length]);

    if (entitlements.length() > 0) {
        NSLog(@"[RePro] 二进制中包含 entitlements，正在解析");
        NSData *plistData = [NSData dataWithBytes:entitlements.data() length:entitlements.length()];
        NSError *parseError;
        NSPropertyListFormat format;
        NSMutableDictionary *plist = [[NSPropertyListSerialization propertyListWithData:plistData
                                                                                options:0
                                                                                 format:&format
                                                                                  error:&parseError] mutableCopy];
        if (parseError) {
            NSLog(@"[RePro] 解析 entitlements plist 失败: %@", parseError);
            if (error) *error = parseError;
            return nil;
        }
        return plist;
    }

    // 二进制中无 entitlements（未签名或无 entitlements blob）
    return @{};
}

#pragma mark - 实例方法（内部使用）

/// 更新 entitlements 中的关键字段以匹配新的 team ID 和 bundle identifier
/// SignEngine 调用的核心方法：在原始 entitlements 基础上更新：
///   - application-identifier     → <teamId>.<bundleIdentifier>
///   - com.apple.developer.team-identifier → <teamId>
///   - keychain-access-groups      → [<teamId>.*]
+ (NSDictionary *)updateEntitlementsForBinaryAtLocation:(NSString *)binaryLocation
                                       bundleIdentifier:(NSString *)bundleIdentifier
                                                  teamID:(NSString *)teamid {
    NSMutableDictionary *plist = [self analyzeEntitlementsFromBinaryAtPath:binaryLocation error:nil];
    if (plist == nil || plist.count == 0) return [NSMutableDictionary dictionary];

    // 更新 application-identifier
    [plist setValue:[NSString stringWithFormat:@"%@.%@", teamid, bundleIdentifier]
            forKey:@"application-identifier"];

    // 更新 team identifier
    [plist setValue:teamid forKey:@"com.apple.developer.team-identifier"];

    // 重建 keychain-access-groups
    NSMutableArray *keychainAccessGroups = [NSMutableArray array];
    [keychainAccessGroups addObject:[NSString stringWithFormat:@"%@.*", teamid]];
    [plist setValue:keychainAccessGroups forKey:@"keychain-access-groups"];

    // 注意：不自动设置 get-task-allow，由调用方决定是否开启调试

    return plist;
}

#pragma mark - 私有方法实现

/// 根据 X509 证书的 issuer name hash 选择对应的中间 CA 证书
/// Apple 使用两套中间证书：
///   - 0x817d2f7a → apple-ios.pem（传统 Apple iOS 证书颁发机构）
///   - 0x9b16b75c → apple-ios-g3.pem（较新的 G3 证书颁发机构）
- (X509 *)_loadCAChainFromDiskForCertificate:(NSData *)certificate {
    // 将 DER 格式的证书加载到内存
    X509 *certForHashCheck;
    const unsigned char *input = (unsigned char *)[certificate bytes];
    certForHashCheck = d2i_X509(NULL, &input, (int)[certificate length]);
    if (!certForHashCheck) {
        NSLog(@"[RePro] 错误：无法将证书加载到内存");
        @throw [NSException exceptionWithName:@"EESigningException"
                                       reason:@"无法加载证书到内存"
                                     userInfo:nil];
    }

    // 计算证书发行者的 hash 值，用于选择正确的中间 CA
    unsigned long issuerHash = X509_issuer_name_hash(certForHashCheck);

    NSString *filepath;
    if (issuerHash == 0x817d2f7a) {
        filepath = [[NSBundle mainBundle] pathForResource:@"apple-ios" ofType:@"pem"];
    } else if (issuerHash == 0x9b16b75c) {
        filepath = [[NSBundle mainBundle] pathForResource:@"apple-ios-g3" ofType:@"pem"];
    } else {
        NSLog(@"[RePro] 错误：无法确定要使用的中间证书 (issuerHash=0x%lx)", issuerHash);
        X509_free(certForHashCheck);
        @throw [NSException exceptionWithName:@"EESigningException"
                                       reason:@"无法确定中间证书"
                                     userInfo:nil];
    }

    X509_free(certForHashCheck);

    NSLog(@"[RePro] 从 '%@' 加载 CA chain", filepath);

    // 从 PEM 文件读取 CA 证书
    NSString *contents = [NSString stringWithContentsOfFile:filepath encoding:NSUTF8StringEncoding error:nil];
    BIO *bio = BIO_new(BIO_s_mem());
    BIO_puts(bio, [contents cStringUsingEncoding:NSUTF8StringEncoding]);

    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    BIO_free_all(bio);

    if (!cert) {
        NSLog(@"[RePro] 错误：加载 CA chain 失败");
        @throw [NSException exceptionWithName:@"EESigningException"
                                       reason:@"无法从磁盘加载 CA chain"
                                     userInfo:nil];
    }

    return cert;
}

/// 使用 OpenSSL PKCS12_create 构建 PKCS#12 证书包
/// 等效命令行操作：
///   openssl pkcs12 -inkey key.pem -in cert.pem -export -out cert.p12 \
///                   -CAfile caChain.pem -chain -passout pass:
/// 参数说明：
///   - password: 空字符串（ldid 要求无密码）
///   - friendlyName: "ReProvision"
///   - nid_key/nid_cert: 0 表示使用 OpenSSL 默认值
- (std::string)_createPKCS12CertificateWithKey:(NSString *)key
                                   certificate:(NSData *)certificate
                                    andCAChain:(X509 *)chain {
    // 加载根 CA 证书（root.pem）
    NSString *rootCAFilepath = [[NSBundle mainBundle] pathForResource:@"root" ofType:@"pem"];
    NSString *rootCAContents = [NSString stringWithContentsOfFile:rootCAFilepath encoding:NSUTF8StringEncoding error:nil];

    BIO *rootCABio = BIO_new(BIO_s_mem());
    BIO_puts(rootCABio, [rootCAContents cStringUsingEncoding:NSUTF8StringEncoding]);
    X509 *rootCA = PEM_read_bio_X509(rootCABio, NULL, NULL, NULL);
    BIO_free_all(rootCABio);

    if (!rootCA) {
        NSLog(@"[RePro] 错误：加载根 CA 失败");
        @throw [NSException exceptionWithName:@"EESigningException"
                                       reason:@"无法从磁盘加载根 CA"
                                     userInfo:nil];
    }

    // 参考实现：http://fm4dd.com/openssl/pkcs12test.htm
    X509 *cert, *cacert;
    STACK_OF(X509) *cacertstack;
    PKCS12 *pkcs12bundle;
    EVP_PKEY *cert_privkey;
    BIO *bio_privkey = NULL, *bio_pkcs12 = NULL;
    int error = 0;

    // 初始化 OpenSSL 算法注册表和错误字符串
    OpenSSL_add_all_algorithms();
    ERR_load_crypto_strings();

    // 步骤 1：加载私钥（PEM 格式，无密码保护）
    bio_privkey = BIO_new(BIO_s_mem());
    BIO_puts(bio_privkey, [key cStringUsingEncoding:NSUTF8StringEncoding]);
    if (!(cert_privkey = PEM_read_bio_PrivateKey(bio_privkey, NULL, NULL, NULL))) {
        NSLog(@"[RePro] 错误：加载私钥失败");
        error = -1;
    }

    // 步骤 2：加载开发者证书（DER 格式）
    const unsigned char *certInput = (unsigned char *)[certificate bytes];
    cert = d2i_X509(NULL, &certInput, (int)[certificate length]);
    if (!cert) {
        NSLog(@"[RePro] 错误：加载证书失败");
        error = -1;
    }

    // 步骤 3：使用传入的中间 CA 证书
    cacert = chain;

    // 步骤 4：构建 CA 证书栈（根 CA + 中间 CA）
    if ((cacertstack = sk_X509_new_null()) == NULL) {
        NSLog(@"[RePro] 错误：创建 STACK_OF(X509) 失败");
        error = -1;
    }
    sk_X509_push(cacertstack, rootCA);   // 先压入根 CA
    sk_X509_push(cacertstack, cacert);   // 再压入中间 CA

    // 步骤 5：创建 PKCS#12 结构体
    pkcs12bundle = PKCS12_create(
        (char *)"",             // 密码：空字符串（ldid 要求）
        (char *)"ReProvision",  // friendly name
        cert_privkey,           // 私钥
        cert,                   // 开发者证书
        cacertstack,            // CA 证书链栈
        0,                      // nid_key（默认 3DES-CBC）
        0,                      // nid_cert（默认 RC2-40-CBC）
        0,                      // iter（默认 2048 次 PBKDF2 迭代）
        0,                      // mac_iter（默认 1）
        0                       // keytype（默认无标志）
    );
    if (pkcs12bundle == NULL) {
        NSLog(@"[RePro] 错误：生成 PKCS12 证书失败");
        error = -1;
    }

    // 步骤 6：将 PKCS#12 结构序列化为 NSData
    bio_pkcs12 = BIO_new(BIO_s_mem());
    int bytes = i2d_PKCS12_bio(bio_pkcs12, pkcs12bundle);
    if (bytes <= 0) {
        NSLog(@"[RePro] 错误：写入 PKCS12 数据失败");
        error = -1;
    }

    char *data = NULL;
    long len = BIO_get_mem_data(bio_pkcs12, &data);
    NSData *result = [NSData dataWithBytes:data length:len];

    // 步骤 7：清理所有 OpenSSL 资源
    X509_free(cert);
    X509_free(cacert);
    sk_X509_free(cacertstack);
    PKCS12_free(pkcs12bundle);
    BIO_free_all(bio_pkcs12);
    BIO_free_all(bio_privkey);
    EVP_PKEY_free(cert_privkey);

    if (error == -1) {
        return std::string("");
    } else {
        return std::string(reinterpret_cast<const char *>([result bytes]), [result length]);
    }
}

/// 创建 Code Signing Requirements blob
///
/// 重要说明：当前返回空字符串。
/// 原因：
///   1. iOS 在安装/运行时不验证 requirements blob 是否非空
///   2. SecRequirement* 系列 API（SecRequirementCreateWithString、
///      SecRequirementCopyData 等）在 iOS 上不可用（仅 macOS 有完整实现）
///   3. 正确实现需要手动构造 DER 编码的 requirements 二进制结构，
///      涉及复杂的 ASN.1 编码工作，投入产出比低
///
/// 如果未来需要支持 requirements，可以参考：
///   - Apple Code Signing 文档中的 requirements 语言语法
///   - csreq 命令行工具的输出格式
- (std::string)_createRequirementsBlobWithKey:(NSString *)key
                                  certificate:(NSData *)certificate
                          andBundleIdentifier:(NSString *)identifier {
    // 返回空字符串 — iOS 接受空的 requirements blob
    // 如需启用下方注释掉的实现，需链接 Security.framework 并确保 API 可用
    return "";

    /*
     * 以下为实现参考（当前禁用）：
     *
     * OpenSSL_add_all_algorithms();
     * ERR_load_crypto_strings();
     *
     * EVP_PKEY *cert_privkey;
     * BIO *bio_privkey;
     * X509 *cert;
     *
     * bio_privkey = BIO_new(BIO_s_mem());
     * BIO_puts(bio_privkey, [key cStringUsingEncoding:NSUTF8StringEncoding]);
     *
     * if (!(cert_privkey = PEM_read_bio_PrivateKey(bio_privkey, NULL, NULL, NULL))) {
     *     NSLog(@"Error loading certificate private key content.");
     *     return "";
     * }
     *
     * const unsigned char *input = (unsigned char *)[certificate bytes];
     * cert = d2i_X509(NULL, &input, (int)[certificate length]);
     * if (!cert) {
     *     NSLog(@"Error loading cert into memory.");
     *     return "";
     * }
     *
     * // 构造 requirements 字符串
     * NSString *requirementsString = [NSString stringWithFormat:
     *     @"identifier \"%@\" and anchor apple generic "
     *     @"and certificate leaf[subject.CN] = \"%s\" "
     *     @"and certificate 1[field.1.2.840.113635.100.6.2.1]",
     *     identifier,
     *     [self _commonNameForCert:cert].c_str()];
     *
     * SecRequirementRef requirementRef = NULL;
     * OSStatus status = SecRequirementCreateWithString(
     *     (__bridge CFStringRef)requirementsString,
     *     kSecCSDefaultFlags,
     *     &requirementRef
     * );
     *
     * if (status != noErr) {
     *     NSLog(@"Error: Failed to create requirements! %d", (int)status);
     *     return "";
     * }
     *
     * CFDataRef data;
     * status = SecRequirementCopyData(requirementRef, kSecCSDefaultFlags, &data);
     *
     * if (status != noErr) {
     *     NSLog(@"Error: Failed to copy requirements! %d", (int)status);
     *     if (requirementRef) CFRelease(requirementRef);
     *     return "";
     * }
     *
     * auto buffer = reinterpret_cast<const char*>(CFDataGetBytePtr(data));
     * auto buffer_length = static_cast<std::size_t>(CFDataGetLength(data));
     *
     * std::string result(buffer, buffer_length);
     *
     * if (requirementRef) CFRelease(requirementRef);
     * return result;
     */
}

/// 从 X509 证书的 Subject 字段提取 Common Name (CN)
- (std::string)_commonNameForCert:(X509 *)cert {
    int common_name_loc = -1;
    X509_NAME_ENTRY *common_name_entry = NULL;
    ASN1_STRING *common_name_asn1 = NULL;
    char *common_name_str = NULL;

    // 在 Subject 字段中查找 CN 的位置
    common_name_loc = X509_NAME_get_index_by_NID(X509_get_subject_name(cert), NID_commonName, -1);
    if (common_name_loc < 0) return "";

    // 提取 CN 字段条目
    common_name_entry = X509_NAME_get_entry(X509_get_subject_name(cert), common_name_loc);
    if (common_name_entry == NULL) return "";

    // 获取 ASN1 字符串值
    common_name_asn1 = X509_NAME_ENTRY_get_data(common_name_entry);
    if (common_name_asn1 == NULL) return "";

    common_name_str = (char *)ASN1_STRING_data(common_name_asn1);
    return std::string(common_name_str);
}

@end
