//
//  RPVOpenSSLInit.h
//  RePro
//
//  OpenSSL 3.x 静态链接（本项目 CI 从源码编译 OpenSSL 3.4.1，no-shared）时，
//  default provider 不会在 App 进程里自动激活，导致 EVP_sha1() 返回 NULL、
//  RSA_generate_key_ex() 静默失败，表现为 CSR 生成报
//  "Failed to generate a code signing request"，签名也可能失败。
//
//  原版 ReProvision-Reborn 链接的是预编译的 OpenSSL 1.1.x（tvOS/lib/），
//  1.1.x 里 OpenSSL_add_all_algorithms() 会自动激活一切，所以原版无此问题。
//
//  修复：与 zsign 一致 —— zsign 显式调用 OSSL_PROVIDER_load(NULL, "default")，
//  该 provider 已被 no-shared 编进 libcrypto.a。这里同样显式加载一次。
//

#ifndef RPVOpenSSLInit_h
#define RPVOpenSSLInit_h

#include <openssl/provider.h>
#include <openssl/evp.h>
#include <openssl/err.h>
#include <dispatch/dispatch.h>

static inline void RPVEnsureOpenSSLInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 激活 default provider（RSA/SHA1 等算法来自此 provider）。
        OSSL_PROVIDER_load(NULL, "default");
        // 兼容旧式算法表初始化（无副作用，OpenSSL 3.x 下为宏）。
        OpenSSL_add_all_algorithms();
    });
}

#endif /* RPVOpenSSLInit_h */
