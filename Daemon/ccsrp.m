//
//  ccsrp.m
//  RePro Daemon
//
//  SRP 内存布局桥接（iOS 15+ 专用）
//  原版 AltSign 的代码包含 iOS 13/14 兼容分支，但我们只需 iOS 15+
//

#import <corecrypto/ccsrp.h>
#import <Foundation/Foundation.h>

cc_unit *srp_ccn(ccsrp_ctx_t srp)
{
    // 目标 iOS 15+，直接使用透明联合体路径
    return SRP_CCN(srp);
}
