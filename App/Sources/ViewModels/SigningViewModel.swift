import Foundation
import Combine

// MARK: - 签名逻辑协调 ViewModel
//
// 所有实际工作都交给 BridgeClient -> RPVBridge -> Vendor/ReProvision，
// 这里只负责维护界面状态。桥接层同一时间只允许一条签名流水线，
// 所以「全部重签」走 resignAllExpiring，而不是在这里循环发起多次请求。
//
// 线程约定：RPVBridge 的所有回调都已经切回主队列（RPVBridgeCallOnMain），
// 因此本类里对 @Published 的写入不再额外 dispatch。

final class SigningViewModel: ObservableObject {

    @Published var installedApps: [InstalledApp] = []
    @Published var isBusy: Bool = false
    @Published var progressMessage: String = ""
    @Published var lastError: String?

    private let client = BridgeClient.shared

    init() {
        bindSigningCallbacks()
        Task { await refreshApps() }
    }

    // MARK: - 进度订阅

    private func bindSigningCallbacks() {
        client.observeSigningProgress { [weak self] bundleID, progress in
            guard let self = self else { return }
            self.applyProgress(progress, to: bundleID)
        }
        client.observeSigningError { [weak self] bundleID, error in
            guard let self = self else { return }
            LogManager.shared.error("签名出错 [\(bundleID)]: \(error.localizedDescription)",
                                    source: "SigningViewModel")
        }
    }

    private func applyProgress(_ progress: Int, to bundleID: String) {
        if let index = installedApps.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
            installedApps[index].isSigning = progress < 100
            installedApps[index].signingProgress = progress
            progressMessage = "\(installedApps[index].displayName) \(progress)%"
        } else {
            progressMessage = "\(bundleID) \(progress)%"
        }
    }

    // MARK: - 应用列表

    func refreshApps() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.fetchInstalledApps { [weak self] result in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                switch result {
                case .success(let apps):
                    // 保留正在签名的 UI 状态，避免刷新时进度条被清掉
                    let signing = Dictionary(uniqueKeysWithValues:
                        self.installedApps.filter { $0.isSigning }
                            .map { ($0.bundleIdentifier, $0.signingProgress) })
                    self.installedApps = apps.map { app in
                        var app = app
                        if let progress = signing[app.bundleIdentifier] {
                            app.isSigning = true
                            app.signingProgress = progress
                        }
                        return app
                    }
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    LogManager.shared.error("获取应用列表失败: \(error.localizedDescription)",
                                            source: "SigningViewModel")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - 导入 IPA

    /// url 来自 fileImporter，是 security-scoped 的；
    /// Vendor 侧 RPVIpaBundleApplication 会自己 startAccessingSecurityScopedResource,
    /// 所以这里不再手动往 tmp 复制一份。
    func importIPA(url: URL) {
        guard beginWork("正在导入 \(url.lastPathComponent)…") else { return }
        LogManager.shared.info("导入 IPA: \(url.lastPathComponent)", source: "SigningViewModel")

        // 导入 IPA 不在此处撤销证书：导入后本就会重新签名安装，
        // 撤销证书反而可能打断其签名流程，属多余操作。
        client.importIPA(url: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let app):
                LogManager.shared.info("IPA 安装成功: \(app.bundleIdentifier)", source: "SigningViewModel")
                self.endWork(message: "\(app.displayName) 安装完成")
            case .failure(let error):
                LogManager.shared.error("IPA 安装失败: \(error.localizedDescription)", source: "SigningViewModel")
                self.endWork(message: "导入失败", error: error)
            }
            Task { await self.refreshApps() }
        }
    }

    // MARK: - 重签

    // MARK: - 签名前自动撤销证书

    /// 委托给 BridgeClient.shared.autoRevokeBeforeSigning（共享逻辑含去重、开关、日志）。
    private func autoRevokeBeforeSigning(completion: @escaping () -> Void) {
        client.autoRevokeBeforeSigning(completion: completion)
    }

    func resign(app: InstalledApp) {
        guard !app.isSigning else { return }
        guard beginWork("正在签名 \(app.displayName)…") else { return }

        markSigning(true, for: app.bundleIdentifier)
        LogManager.shared.info("开始重签: \(app.bundleIdentifier)", source: "SigningViewModel")

        autoRevokeBeforeSigning { [weak self] in
            guard let self = self else { return }
            self.client.resign(bundleID: app.bundleIdentifier) { result in
                self.markSigning(false, for: app.bundleIdentifier)
                switch result {
                case .success:
                    LogManager.shared.info("重签成功: \(app.bundleIdentifier)", source: "SigningViewModel")
                    self.endWork(message: "签名完成")
                case .failure(let error):
                    LogManager.shared.error("重签失败 [\(app.bundleIdentifier)]: \(error.localizedDescription)",
                                            source: "SigningViewModel")
                    self.endWork(message: "签名失败", error: error)
                }
                Task { await self.refreshApps() }
            }
        }
    }

    /// 重签所有临近过期的应用。阈值取设置页里的「提前 N 天重签」。
    func resignAllExpiring() {
        let threshold = UserDefaults.standard.object(forKey: "resignThreshold") as? Int ?? 2
        guard beginWork("正在批量重签…") else { return }

        LogManager.shared.info("开始批量重签（阈值 \(threshold) 天）", source: "SigningViewModel")

        autoRevokeBeforeSigning { [weak self] in
            guard let self = self else { return }
            self.client.resignAllExpiring(thresholdDays: threshold) { result in
                switch result {
                case .success:
                    LogManager.shared.info("批量重签完成", source: "SigningViewModel")
                    self.endWork(message: "批量重签完成")
                case .failure(let error):
                    LogManager.shared.error("批量重签失败: \(error.localizedDescription)", source: "SigningViewModel")
                    self.endWork(message: "批量重签失败", error: error)
                }
                Task { await self.refreshApps() }
            }
        }
    }

    /// 重签所有已安装应用（不按阈值过滤）。用户点击刷新按钮时调用。
    func resignAllApplications() {
        guard beginWork("正在批量刷新签名…") else { return }

        LogManager.shared.info("手动批量刷新签名（全部应用）", source: "SigningViewModel")

        autoRevokeBeforeSigning { [weak self] in
            guard let self = self else { return }
            self.client.resignAllApplications { result in
                switch result {
                case .success:
                    LogManager.shared.info("手动批量刷新完成", source: "SigningViewModel")
                    self.endWork(message: "批量刷新完成")
                case .failure(let error):
                    LogManager.shared.error("手动批量刷新失败: \(error.localizedDescription)", source: "SigningViewModel")
                    self.endWork(message: "批量刷新失败", error: error)
                }
                Task { await self.refreshApps() }
            }
        }
    }

    // MARK: - 卸载

    func uninstall(app: InstalledApp) {
        let ok = client.remove(bundleID: app.bundleIdentifier)
        if ok {
            installedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
            LogManager.shared.info("已卸载: \(app.bundleIdentifier)", source: "SigningViewModel")
        } else {
            lastError = "卸载失败: \(app.displayName)"
            LogManager.shared.error("卸载失败: \(app.bundleIdentifier)", source: "SigningViewModel")
        }
        Task { await refreshApps() }
    }

    // MARK: - 状态小工具

    /// 桥接层同一时间只跑一条流水线，这里先在 UI 层挡一道，减少无谓的报错弹窗
    private func beginWork(_ message: String) -> Bool {
        guard !isBusy else {
            lastError = ReSignError.busy.errorDescription
            return false
        }
        isBusy = true
        lastError = nil
        progressMessage = message
        return true
    }

    private func endWork(message: String, error: Error? = nil) {
        isBusy = false
        progressMessage = message
        lastError = error?.localizedDescription
    }

    private func markSigning(_ signing: Bool, for bundleID: String) {
        guard let index = installedApps.firstIndex(where: { $0.bundleIdentifier == bundleID }) else { return }
        installedApps[index].isSigning = signing
        if !signing { installedApps[index].signingProgress = 0 }
    }
}
