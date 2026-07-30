// main.m - ReProvision Daemon 入口
// 极简入口：启动 XPC 监听器，进入 RunLoop
//
// 运行身份：root (uid 0)
// 沙盒状态：无沙盒 (no-sandbox entitlement)
// 进程类型：MachService (launchd 管理)

#import <Foundation/Foundation.h>
#import "RZDaemon.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 初始化日志
        RZDaemon *daemon = [[RZDaemon alloc] init];

        // 启动 XPC 服务
        [daemon start];

        NSLog(@"[RePro] 守护进程启动完成，等待连接...");

        // 进入主循环
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
