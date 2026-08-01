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

    private init() {
        refreshAccountState()
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
        bridge.fetchInstalledApps { infos, error in
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
        guard let handler = handler else {
            bridge.signingProgressHandler = nil
            return
        }
        bridge.signingProgressHandler = { bundleID, progress in
            handler(bundleID, Int(progress))
        }
    }

    /// 单个应用签名出错时的回调，在主队列触发
    func observeSigningError(_ handler: ((String, Error) -> Void)?) {
        guard let handler = handler else {
            bridge.signingErrorHandler = nil
            return
        }
        bridge.signingErrorHandler = { bundleID, error in
            handler(bundleID, error)
        }
    }

    func resign(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.resignApplication(bundleIdentifier: bundleID) { error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func resignAllExpiring(thresholdDays: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.resignAllExpiringApplications(thresholdDays: Int32(thresholdDays)) { error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    /// 重签所有已安装应用（不按阈值过滤，手动刷新专用）
    func resignAllApplications(completion: @escaping (Result<Void, Error>) -> Void) {
        bridge.resignAllApplications { error in
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
                completion(.success(InstalledApp(info: info)))
            } else {
                completion(.failure(error ?? ReProError.invalidIPA))
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
                completion(.failure(error ?? ReProError.notSignedIn))
            }
        }
    }

    // MARK: - 证书管理

    func fetchCertificates(completion: @escaping (Result<[DevCertificate], Error>) -> Void) {
        bridge.fetchCertificates { certs, error in
            if let certs = certs {
                completion(.success(certs.map { DevCertificate(from: $0) }))
            } else {
                completion(.failure(error ?? ReProError.notSignedIn))
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

    // MARK: - 系统操作

    /// 通过 sysctl 枚举进程找到 SpringBoard 并发送 SIGTERM。
    /// 参考 RebootTools / TrollStore TSUtil.m，不依赖任何外部二进制。
    /// 返回 true 表示成功找到并发送了信号。
    func respring() -> Bool {
        return bridge.respring()
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
                  hasEmbeddedProvision: info.hasEmbeddedProvision)
    }
}
