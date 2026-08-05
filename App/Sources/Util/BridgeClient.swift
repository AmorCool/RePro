import Foundation
import Combine

// MARK: - 业务层入口（取代原先的 DaemonClient）
//
// 所有能力都直接来自同进程内的 RPVBridge（Vendor/ReProvision 原版实现），
// 不再有 XPC、不再有常驻守护进程。需要 root 的两个动作（写系统描述文件、
// 跨沙箱复制文件）由 Phase 3 的按需 root helper 承担，对本层透明。

final class BridgeClient: ObservableObject {

    static let shared = BridgeClient()

    private let bridge = RPVBridge.sharedInstance()

    /// 当前登录态，登录/登出后主动刷新，供界面订阅
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var username: String?
    @Published private(set) var teamID: String?

    /// 已保存的密码（gsToken），供登录前界面预填。未登录为 nil。
    var savedPassword: String? { bridge.savedPassword }

    /// bundleID → 显示名。发通知时把「com.xxx.yyy」换成用户看得懂的名字，
    /// 由 fetchInstalledApps 顺带刷新。上限 500 条（远超实际安装量），超出后清空重建。
    private var appNameCache: [String: String] = [:]
    private static let maxAppNameCacheSize = 500

    /// 界面层（SigningViewModel）注册的进度 / 错误订阅者。
    /// 桥接层的 handler 全局只有一份，统一由本类持有后再转发，
    /// 否则界面一旦订阅就会把通知逻辑覆盖掉。
    private var externalProgressHandler: ((String, Int) -> Void)?
    private var externalErrorHandler: ((String, Error) -> Void)?

    private let notifier = RPVNotificationManager.sharedInstance()

    private init() {
        refreshAccountState()
        installSigningNotificationHooks()
    }

    // MARK: - 账号状态

    func refreshAccountState() {
        isSignedIn = bridge.isSignedIn
        username = bridge.username
        teamID = bridge.teamID
    }

    // MARK: - 登录

    /// 登录流程的下一步动作
    enum LoginStep {
        /// 账号密码通过，需要用户从 teams 里选一个 Team 才算完成
        case chooseTeam([DeveloperTeam])
        /// 账号开了两步验证：需要调用 continueTwoFactorAuthentication，
        /// 由 AuthKit 拉起系统级的 Apple ID 验证界面
        case needsTwoFactor
        /// 失败
        case failed(String)
    }

    func login(appleID: String, password: String, completion: @escaping (LoginStep) -> Void) {
        bridge.login(username: appleID, password: password) { [weak self] result in
            completion(Self.step(from: result, owner: self))
        }
    }

    /// 2FA 账号：继续走两步验证。
    /// 不需要任何输入 —— 系统会弹出 Apple ID 验证界面，用户在系统弹窗里确认后本回调才返回。
    func continueTwoFactor(completion: @escaping (LoginStep) -> Void) {
        bridge.continueTwoFactorAuthentication { [weak self] result in
            completion(Self.step(from: result, owner: self))
        }
    }

    /// 选定 Team 并落库（内部会先把本机注册到该 Team）
    func selectTeam(_ team: DeveloperTeam, completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.selectTeamID(team.teamID) { [weak self] error in
            self?.refreshAccountState()
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func signOut() {
        bridge.signOut()
        refreshAccountState()
    }

    private static func step(from result: RPVLoginResult, owner: BridgeClient?) -> LoginStep {
        switch result.outcome {
        case .succeeded:
            owner?.refreshAccountState()
            return .chooseTeam(Self.teams(from: result.teams))
        case .needsTwoFactor:
            return LoginStep.needsTwoFactor
        case .failed:
            return LoginStep.failed(result.failureReason ?? "登录失败")
        @unknown default:
            return LoginStep.failed("未知的登录结果")
        }
    }

    /// Apple 返回的是原始字典数组，键为 teamId / name / memberships[0].name
    private static func teams(from raw: [[AnyHashable: Any]]?) -> [DeveloperTeam] {
        guard let raw = raw else { return [] }
        return raw.compactMap { dict in
            guard let teamID = dict["teamId"] as? String, !teamID.isEmpty else { return nil }
            let name = (dict["name"] as? String) ?? teamID
            var membership: String?
            if let memberships = dict["memberships"] as? [[AnyHashable: Any]],
               let first = memberships.first {
                membership = first["name"] as? String
            }
            return DeveloperTeam(teamID: teamID, name: name, membership: membership)
        }
    }

    // MARK: - 应用列表

    func fetchInstalledApps(completion: @escaping (Result<[InstalledApp], Error>) -> Void) {
        bridge.fetchInstalledApps { [weak self] infos, error in
            // v1.1.159：原代码在 weak 闭包里直接 self! 强解包——单例虽不会为 nil，
            // 但一旦释放就是必崩点；且失败路径必须调 completion，否则调用方
            // withCheckedContinuation 永不恢复 → 界面卡死。
            guard let self else {
                completion(.failure(NSError(domain: "com.reprovision", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "BridgeClient 已释放"])))
                return
            }
            if let error = error {
                completion(.failure(error))
                return
            }
            let apps = infos.map(InstalledApp.init(info:))
            // 顺带刷新通知用的名字表（超上限时清空重建，防止长期运行后只增不减）
            if self.appNameCache.count > BridgeClient.maxAppNameCacheSize {
                self.appNameCache.removeAll()
            }
            for app in apps {
                self.appNameCache[app.bundleIdentifier] = app.displayName
            }
            completion(.success(apps))
        }
    }

    /// 拉取「其他应用」——非当前 Apple ID 签名的已安装应用（含过期应用）
    func fetchOtherApps(completion: @escaping (Result<[InstalledApp], Error>) -> Void) {
        bridge.fetchOtherApps { infos, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            completion(.success(infos.map(InstalledApp.init(info:))))
        }
    }

    // MARK: - 重签名

    /// 单个应用的签名进度回调（0-100），由桥接层在主队列触发。
    /// 设为 nil 即取消订阅。
    func observeSigningProgress(_ handler: ((String, Int) -> Void)?) {
        externalProgressHandler = handler
    }

    /// 单个应用签名出错时的回调，在主队列触发
    func observeSigningError(_ handler: ((String, Error) -> Void)?) {
        externalErrorHandler = handler
    }

    // MARK: - 本地通知（语义对齐 test2 源码）

    private func installSigningNotificationHooks() {
        bridge.signingProgressHandler = { [weak self] bundleID, progress in
            self?.handleSigningProgress(bundleID: bundleID, progress: Int(progress))
        }
        bridge.signingErrorHandler = { [weak self] bundleID, error in
            self?.handleSigningError(bundleID: bundleID, error: error)
        }
    }

    private func displayName(for bundleID: String) -> String {
        appNameCache[bundleID] ?? bundleID
    }

    /// 进度节点与原版一一对应：10/50/60/90 为调试播报，100 为成功提示
    private func handleSigningProgress(bundleID: String, progress: Int) {
        let name = displayName(for: bundleID)
        switch progress {
        case 100:
            notifier.sendNotification(title: "重签完成",
                                      body: "已重新签名「\(name)」",
                                      isDebug: false, identifier: nil)
            RPVSigningdNotify.notifyBypass3AppRequest()
        case 10:
            notifier.sendNotification(title: "调试", body: "开始签名「\(name)」",
                                      isDebug: true, identifier: nil)
        case 50:
            notifier.sendNotification(title: "调试", body: "已写入签名：「\(name)」",
                                      isDebug: true, identifier: nil)
        case 60:
            notifier.sendNotification(title: "调试", body: "已重建 IPA：「\(name)」",
                                      isDebug: true, identifier: nil)
        case 90:
            notifier.sendNotification(title: "调试", body: "正在安装「\(name)」",
                                      isDebug: true, identifier: nil)
        default:
            break
        }
        externalProgressHandler?(bundleID, progress)
    }

    private func handleSigningError(bundleID: String, error: Error) {
        notifier.sendNotification(title: "签名失败",
                                  body: "「\(displayName(for: bundleID))」：\(error.localizedDescription)",
                                  isDebug: false, identifier: nil)
        externalErrorHandler?(bundleID, error)
    }

    /// 整条流水线结束时的提示。
    /// 成功时不再打扰用户（逐个应用已经提示过），只在出错或「无需重签」时发一条。
    private func notifyPipelineResult(_ error: Error?) {
        guard let error = error else { return }
        let nsError = error as NSError
        // RPVErrorNoSigningRequired == 101（Vendor/ReProvision/Application Database/RPVErrors.h）
        if nsError.code == 101 {
            notifier.sendNotification(title: "无需重签",
                                      body: "当前没有接近过期的应用",
                                      isDebug: false, identifier: nil)
        } else {
            notifier.sendNotification(title: "重签失败",
                                      body: error.localizedDescription,
                                      isDebug: false, identifier: nil)
        }
    }

    func resign(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.resignApplication(bundleIdentifier: bundleID) { error in
            // 会话级兜底：单点重签收口也发一次绕过请求（与逐 app progress=100 互补）
            RPVSigningdNotify.notifyBypass3AppRequest()
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func resignAllExpiring(thresholdDays: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.resignAllExpiringApplications(thresholdDays: Int32(thresholdDays)) { [weak self] error in
            self?.notifyPipelineResult(error)
            // 会话级兜底：整条流水线结束（前台/后台续签都走这）发一次绕过请求
            RPVSigningdNotify.notifyBypass3AppRequest()
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    /// 重签所有已安装应用（不按阈值过滤，手动刷新专用）
    func resignAllApplications(completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.resignAllApplications { [weak self] error in
            self?.notifyPipelineResult(error)
            // 会话级兜底：批量刷新整条流水线结束时发一次绕过请求（修复「批量签名不触发绕过」）
            RPVSigningdNotify.notifyBypass3AppRequest()
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    @discardableResult
    func remove(bundleID: String) -> Bool {
        bridge.removeApplication(bundleIdentifier: bundleID)
    }

    // MARK: - IPA 导入

    func importIPA(url: URL, completion: @escaping (Result<InstalledApp, Error>) -> Void) {
        bridge.importAndInstallIPA(url: url) { info, error in
            if let info = info {
                // IPA 安装成功 → 发一次绕过请求（与逐 app progress=100 互补）
                RPVSigningdNotify.notifyBypass3AppRequest()
                completion(.success(InstalledApp(info: info)))
            } else {
                completion(.failure(error ?? ReSignError.invalidIPA))
            }
        }
    }

    // MARK: - 环境体检

    func fetchEnvironment(completion: @escaping (EnvironmentSnapshot) -> Void) {
        bridge.fetchEnvironmentInfo { info in
            completion(EnvironmentSnapshot(
                jailbreak: JailbreakType(kind: info.jailbreakKind),
                jailbreakRoot: info.jailbreakRoot,
                zsignPath: info.zsignPath,
                certificatesBundled: info.certificatesBundled,
                rootHelperAvailable: info.rootHelperAvailable,
                rootHelperPath: info.rootHelperPath,
                signedIn: info.signedIn,
                username: info.username,
                teamID: info.teamID,
                deviceUDID: info.deviceUDID,
                sideloadedAppCount: info.sideloadedAppCount,
                nearestExpiryDate: info.nearestExpiryDate
            ))
        }
    }

    // MARK: - 已注册 AppIDs

    func fetchAppIDs(completion: @escaping (Result<[RegisteredAppID], Error>) -> Void) {
        bridge.fetchAppIDs { appIds, error in
            if let appIds = appIds {
                completion(.success(appIds.map { RegisteredAppID(from: $0) }))
            } else {
                completion(.failure(error ?? ReSignError.notSignedIn))
            }
        }
    }

    // MARK: - 证书管理

    func fetchCertificates(completion: @escaping (Result<[DevCertificate], Error>) -> Void) {
        bridge.fetchCertificates { certs, error in
            if let certs = certs {
                completion(.success(certs.map { DevCertificate(from: $0) }))
            } else {
                completion(.failure(error ?? ReSignError.notSignedIn))
            }
        }
    }

    func revokeCertificate(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.revokeCertificate(identifier: id) { error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func revokeAllCertificates(completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.revokeAllCertificates { error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    // MARK: - 签名前自动撤销证书

    /// 去重窗口：短时间内多次触发只真正撤销一次，避免重复撤销引发异常。
    private static var lastRevokeTime: Date?
    private static let revokeDedupWindow: TimeInterval = 120

    /// 签名前自动撤销所有旧证书，防止 CSR 冲突。
    /// 共享方法：AppDelegate 后台续签 / SigningViewModel 前台操作 统一调用同一套逻辑，
    /// 避免 v1.1.86 前台有撤销、后台漏撤销的不一致问题。
    func autoRevokeBeforeSigning(completion: @escaping (Error?) -> Void) {
        guard UserDefaults.standard.object(forKey: "revokeCertBeforeSigning") as? Bool ?? true else {
            LogManager.shared.info("跳过签名前自动撤销（设置已关闭）", source: "BridgeClient")
            completion(nil)
            return
        }

        let now = Date()
        if let last = BridgeClient.lastRevokeTime,
           now.timeIntervalSince(last) < BridgeClient.revokeDedupWindow {
            LogManager.shared.info("跳过重复撤销证书（\(Int(now.timeIntervalSince(last)))s 内已撤销过）", source: "BridgeClient")
            completion(nil)
            return
        }
        BridgeClient.lastRevokeTime = now

        LogManager.shared.info("签名前自动撤销：正在拉取账号下的旧证书…", source: "BridgeClient")
        fetchCertificates { [weak self] result in
            guard let self = self else { completion(nil); return }

            switch result {
            case .success(let certs):
                guard !certs.isEmpty else {
                    LogManager.shared.info("签名前自动撤销：当前账号下无旧证书，无需撤销", source: "BridgeClient")
                    completion(nil)
                    return
                }

                // 🔴 只撤销「其他设备」的证书，保留本机自己的证书。
                //
                // 旧版无差别 revokeAllCertificates 会把本机证书也撤掉，导致本机私钥对应的
                // 证书消失 → 下次签名被迫提交全新 CSR → 刚撤销完就立即申请，与 Apple
                // 服务器状态赛跑 → "submitDevelopmentCSR: There were errors in the data
                // supplied"。原版 ReProvision 的做法也是「只撤销本机相关的过期/无私钥证书」，
                // 从不无差别清空整个账号。
                let myMachineId = RPVBridge.currentMachineIdentifier() ?? ""
                let targets: [DevCertificate]

                if myMachineId.isEmpty {
                    // 本机机器标识尚未生成（从未成功签名过）→ 无法区分归属。
                    // 退回旧策略全部撤销，否则可能撞上 Apple 的证书数量上限而签不了。
                    targets = certs
                    LogManager.shared.info("签名前自动撤销：本机机器标识尚未生成，无法区分归属 → 撤销全部 \(certs.count) 个证书",
                                           source: "BridgeClient")
                } else {
                    targets = certs.filter { $0.machineId != myMachineId }
                    let keptCount = certs.count - targets.count
                    if keptCount > 0 {
                        LogManager.shared.info("签名前自动撤销：保留本机证书 \(keptCount) 个（机器标识 \(myMachineId)），避免被迫重新申请 CSR",
                                               source: "BridgeClient")
                    }
                }

                guard !targets.isEmpty else {
                    LogManager.shared.info("签名前自动撤销：账号下仅有本机证书，无需撤销，直接签名", source: "BridgeClient")
                    completion(nil)
                    return
                }

                let detail = targets.map { "· \($0.machineName)（标识 \($0.id)）" }.joined(separator: "\n")
                LogManager.shared.info("签名前自动撤销：将撤销以下 \(targets.count) 个其他设备的证书：\n\(detail)",
                                       source: "BridgeClient")

                let group = DispatchGroup()
                for cert in targets {
                    group.enter()
                    self.revokeCertificate(id: cert.id) { revokeResult in
                        if case .failure(let error) = revokeResult {
                            LogManager.shared.warning("撤销证书 \(cert.id) 失败（不阻断签名）: \(error.localizedDescription)",
                                                      source: "BridgeClient")
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    LogManager.shared.info("签名前自动撤销完成，开始签名", source: "BridgeClient")
                    completion(nil)
                }

            case .failure(let error):
                LogManager.shared.warning("拉取证书列表失败（联网异常），将上报上层停止续签: \(error.localizedDescription)", source: "BridgeClient")
                completion(error)
            }
        }
    }

    // MARK: - 系统操作

    /// 通过 sysctl 枚举进程找到 SpringBoard 并发送 SIGTERM。
    /// 参考 RebootTools / TrollStore TSUtil.m，不依赖任何外部二进制。
    /// 返回 true 表示成功找到并发送了信号。
    func respring() -> Bool {
        return bridge.respring()
    }

    /// v1.1.181 工具菜单：执行 repro-helper 子命令（uicache / userspace-reboot / reboot-device 等），返回退出码（0 成功）。
    func runRootHelper(arguments: [String]) -> Int {
        return bridge.runRootHelper(withArguments: arguments)
    }
}

// MARK: - RPVAppInfo -> InstalledApp

fileprivate extension InstalledApp {
    init(info: RPVAppInfo) {
        self.init(bundleIdentifier: info.bundleIdentifier,
                  displayName: info.displayName,
                  version: info.version,
                  iconData: info.iconPNGData,
                  certificateExpiryDate: info.expiryDate,
                  hasEmbeddedProvision: info.hasEmbeddedProvision,
                  originalTeamID: info.originalTeamID)
    }
}
