# RePro 项目长期记忆

## 项目概况
- **仓库**: `https://github.com/AmorCool/RePro` (新仓库，非 AmorCool/test)
- **基于**: `https://github.com/SoulRune/ReProvision-Reborn_Rootless` (参考源码)
- **技术栈**: SwiftUI (App) + ObjC (Daemon) + XPC (通信) + OpenSSL (签名)
- **语言**: 全中文（zh-Hans 为主），预留 en/zh-Hant

## 架构决策
- **双后端签名**: ldid (方案一, 内嵌) + zsign (方案二, 外部进程)，设置页 SegmentedControl 切换
- **XPC 通信**: App <-> Daemon 通过 `com.reprovision.daemon` MachService
- **三套 deb 包**: roothide (标准根路径, arm64e) / rootless (/var/jb/, arm64) / rootful (标准根路径, arm)
- **Anisette 本地生成**: 从 lockdown 设备信息 + HMAC-SHA256 OTP，减少对苹果服务器依赖
- **Token 缓存预签**: 7 天有效期证书持久化，离线可用

## 核心模块移植状态 (2026-07-30)
| 模块 | 状态 | 行数 | 说明 |
|------|------|------|------|
| EEAppleServices | 已移植 | 976 | Portal API 客户端，内置 GZIP |
| EEProvisioning | 已移植 | 1407 | 4 阶段流程，文件存储 |
| EESigning | 已移植 | 605 | ldid 签名核心 |
| SignEngine | 骨架完成 | - | 双后端协调器 |
| ZSignBackend | 已实现 | - | posix_spawn 调用 zsign |
| LdidBackend | 占位 | - | 调用 EESigning 接口 |
| AnisetteManager | 基础实现 | - | 本地 Anisette 生成 |
| TokenCacheManager | 已实现 | - | Token 缓存预签 |

## 关键铁律（从旧项目继承）
1. **entitlements 白名单**: 免费账户仅 10 键，CS entitlements 不在白名单（由越狱工具运行时补丁提供）
2. **-e 必须 XML plist**: zsign v1.3.45 起，binary plist 解析不了
3. **单次 pass 签名**: 绝不能主 pass 后再对嵌套 bundle 二次重签
4. **RootHide 三要素**: 标准根路径 + Architecture: iphoneos-arm64e + postinst 用 jbroot 工具
5. **application-identifier 双重前缀修复**: 检测已有 TeamID 前缀则直接使用
6. **Daemon 证书路径不能用 NSBundle**: reprovisiond 是 CLI 二进制，用 `RZCertificatePath()` 按固定绝对路径查找 (`/usr/share/reprovision/certificates/` 或 `/var/jb/usr/share/...`)
7. **CI Daemon 编译必须用 clang++**: ldid.cpp 是 C++，需要 `-std=c++17` + 链接 OpenSSL + libplist 全部源码

## 已解决问题 (2026-07-30)
- [x] ldid 库集成 — 源码编译（ldid 5 文件 + libplist 43 文件）
- [x] CA 证书资源 — 三套 deb 包各含 apple-ios/apple-ios-g3/root.pem
- [x] CocoaPods — 当前无外部依赖（纯 Foundation/Security）
- [x] 接口对接修复 — 6 CRITICAL + 1 WARN 已修复
- [x] CI 脚本完整化 — 补全所有源文件 + OpenSSL + 证书复制

## 待验证
- [x] CI 构建通过（截至 v1.1.57 全绿；通知移植已发版）
- [ ] RootHide 真机验证通知授权持久化（杀后台重开是否还弹授权）—— CI 无法覆盖

## 沙箱 git 推送注意事项
- git 全局 `http.proxy/https.proxy` = `127.0.0.1:31180/31181`，但该端口**未监听**，直接 push 报「Failed to connect to 127.0.0.1 port 31180」。
- 绕过：命令前加 `GIT_HTTP_PROXY= GIT_HTTPS_PROXY= HTTPS_PROXY= HTTP_PROXY=` 并追加 `git -c http.proxy= -c https.proxy=`。`gh` CLI 同样要清 `HTTPS_PROXY/HTTP_PROXY`。不动全局配置。
