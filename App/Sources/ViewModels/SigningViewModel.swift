import Foundation
import Combine

// 导入含扩展的 IPA 时，用户对扩展的处理选择
enum ExtensionChoice {
    case useMainProfile    // 扩展复用主 App 的通配符 profile 签名
    case removeExtensions  // 移除所有 PlugIns/*.appex
    case cancel            // 取消导入
}

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
    @Published var otherApps: [InstalledApp] = []
    /// 小黑屋：被拉黑的应用（自动续签/批量签名会跳过，但单点「重签」仍可签）。
    @Published var blacklistedApps: [InstalledApp] = []

    /// 全量列表（未过滤黑名单），用于派生上面三个分区。
    private var allInstalled: [InstalledApp] = []
    private var allOther: [InstalledApp] = []

    @Published var isBusy: Bool = false
    @Published var progressMessage: String = ""
    @Published var lastError: String?

    /// 导入含扩展的 IPA 时弹出的「扩展处理方式」选择弹窗状态
    @Published var showExtensionChoice = false
    /// 待用户确认处理方式的 IPA（含扩展）：URL 与文件名
    private var pendingExtensionIPA: (url: URL, fileName: String)?

    private let client = BridgeClient.shared

    /// 监听小黑屋变化通知（如设置页清空），及时重新分区。
    private var blacklistObserver: NSObjectProtocol?

    init() {
        bindSigningCallbacks()
        blacklistObserver = NotificationCenter.default.addObserver(
            forName: BlacklistStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.recomputeLists()
        }
        Task {
            await refreshApps()
            await refreshOtherApps()
        }
    }

    deinit {
        if let obs = blacklistObserver {
            NotificationCenter.default.removeObserver(obs)
        }
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
        func update(_ arr: inout [InstalledApp]) {
            if let index = arr.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
                arr[index].isSigning = progress < 100
                arr[index].signingProgress = progress
            }
        }
        update(&installedApps)
        update(&otherApps)
        update(&blacklistedApps)
        progressMessage = "\(bundleID) \(progress)%"
    }

    // MARK: - 应用列表

    /// 把全量列表按小黑屋重新划分成 installedApps / otherApps / blacklistedApps 三个分区。
    private func recomputeLists() {
        let store = BlacklistStore.shared
        var visibleInstalled: [InstalledApp] = []
        var visibleOther: [InstalledApp] = []
        var blacklisted: [InstalledApp] = []

        for var app in allInstalled {
            if store.isBlacklisted(app.bundleIdentifier) {
                app.source = .installed
                blacklisted.append(app)
            } else {
                visibleInstalled.append(app)
            }
        }
        for var app in allOther {
            if store.isBlacklisted(app.bundleIdentifier) {
                app.source = .other
                blacklisted.append(app)
            } else {
                visibleOther.append(app)
            }
        }
        // 小黑屋按显示名排序，列表更稳定
        blacklisted.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        self.installedApps = visibleInstalled
        self.otherApps = visibleOther
        self.blacklistedApps = blacklisted
    }

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
                    // 🔴 v1.1.163：uniqueKeysWithValues 遇到重复 bundleIdentifier（杀进程
                    // 残留的半安装应用偶发）会 fatalError 崩溃 → 改 uniquingKeysWith 保留
                    // 第一个，重复键只是进度取早期值，绝不崩。
                    let signing = Dictionary(
                        self.allInstalled.filter { $0.isSigning }
                            .map { ($0.bundleIdentifier, $0.signingProgress) },
                        uniquingKeysWith: { first, _ in first })
                    self.allInstalled = apps.map { app in
                        var app = app
                        if let progress = signing[app.bundleIdentifier] {
                            app.isSigning = true
                            app.signingProgress = progress
                        }
                        return app
                    }
                    self.recomputeLists()
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    LogManager.shared.error("获取应用列表失败: \(error.localizedDescription)",
                                            source: "SigningViewModel")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - 其他应用（非当前 Apple ID 签名的应用）

    /// 拉取「其他应用」列表——设备上已安装但不是当前账户签名的应用
    func refreshOtherApps() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.fetchOtherApps { [weak self] result in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                switch result {
                case .success(let apps):
                    // 保留正在签名的 UI 状态（v1.1.163：uniquingKeysWith 防重复 key 崩溃）
                    let signing = Dictionary(
                        self.allOther.filter { $0.isSigning }
                            .map { ($0.bundleIdentifier, $0.signingProgress) },
                        uniquingKeysWith: { first, _ in first })
                    self.allOther = apps.map { app in
                        var app = app
                        if let progress = signing[app.bundleIdentifier] {
                            app.isSigning = true
                            app.signingProgress = progress
                        }
                        return app
                    }
                    self.recomputeLists()
                case .failure(let error):
                    LogManager.shared.error("获取其他应用列表失败: \(error.localizedDescription)",
                                            source: "SigningViewModel")
                }
                continuation.resume()
            }
        }
    }

    /// 重签一个「其他应用」（非当前 Apple ID 签名的应用）。
    /// 与普通 resign 相同流程，但 autoRevoke 逻辑已在调用方处理。
    func resignOtherApp(_ app: InstalledApp) {
        guard !app.isSigning else { return }
        guard beginWork("正在重签 \(app.displayName)…") else { return }

        markSigning(true, for: app.bundleIdentifier)
        LogManager.shared.info("重签其他应用: \(app.bundleIdentifier)（原签名 TeamID: \(app.originalTeamID ?? "未知")）",
                               source: "SigningViewModel")

        autoRevokeBeforeSigning { _ in
            self.client.resign(bundleID: app.bundleIdentifier) { result in
                self.markSigning(false, for: app.bundleIdentifier)
                switch result {
                case .success:
                    LogManager.shared.info("其他应用重签成功: \(app.bundleIdentifier)", source: "SigningViewModel")
                    self.endWork(message: "签名完成")
                case .failure(let error):
                    LogManager.shared.error("其他应用重签失败 [\(app.bundleIdentifier)]: \(error.localizedDescription)",
                                            source: "SigningViewModel")
                    self.endWork(message: "签名失败", error: error)
                }
                Task {
                    await self.refreshApps()
                    await self.refreshOtherApps()
                }
            }
        }
    }

    // MARK: - 导入 IPA

    /// url 来自 fileImporter，是 security-scoped 的；
    /// Vendor 侧 RPVIpaBundleApplication 会自己 startAccessingSecurityScopedResource,
    /// 所以这里不再手动往 tmp 复制一份。
    func importIPA(url: URL) {
        LogManager.shared.info("导入 IPA: \(url.lastPathComponent)", source: "SigningViewModel")

        // 检测是否含 App 扩展；含则先弹窗让用户决定处理方式，不直接开始导入。
        if RPVBridge.ipaContainsExtensions(at: url) {
            LogManager.shared.info("导入 IPA 检测到扩展（PlugIns/*.appex）: \(url.lastPathComponent)", source: "SigningViewModel")
            pendingExtensionIPA = (url: url, fileName: url.lastPathComponent)
            showExtensionChoice = true
            return
        }

        performImport(url: url, removeExtensions: false, useMainProfile: false)
    }

    /// 真正发起导入（含扩展选项的透传）。
    private func performImport(url: URL, removeExtensions: Bool, useMainProfile: Bool) {
        guard beginWork("正在导入 \(url.lastPathComponent)…") else { return }
        // 透传扩展处理选项给 EEBackend（仅影响本次导入；signBundleAtPath 入口读入后立即清零）。
        RPVBridge.setExtensionImportOptions(removeExtensions: removeExtensions, useMainProfile: useMainProfile)
        LogManager.shared.info("开始导入 IPA（扩展选项 remove=\(removeExtensions) useMain=\(useMainProfile)）: \(url.lastPathComponent)", source: "SigningViewModel")

        // 导入 IPA 不在此处撤销证书：导入后本就会重新签名安装，
        // 撤销证书反而可能打断其签名流程，属多余操作。
        self.client.importIPA(url: url) { [weak self] result in
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

    /// 弹窗里用户对扩展处理方式的确认回调（由 AppsView 的 confirmationDialog 调用）。
    func confirmExtensionChoice(_ choice: ExtensionChoice) {
        showExtensionChoice = false
        guard let pending = pendingExtensionIPA else { return }
        pendingExtensionIPA = nil
        let fileName = pending.fileName
        switch choice {
        case .useMainProfile:
            LogManager.shared.info("导入 IPA 扩展处理: 用户选择=扩展用主 profile 签名 | IPA=\(fileName)", source: "SigningViewModel")
            performImport(url: pending.url, removeExtensions: false, useMainProfile: true)
        case .removeExtensions:
            LogManager.shared.info("导入 IPA 扩展处理: 用户选择=移除所有扩展 | IPA=\(fileName)", source: "SigningViewModel")
            performImport(url: pending.url, removeExtensions: true, useMainProfile: false)
        case .cancel:
            LogManager.shared.info("导入 IPA 扩展处理: 用户取消导入 | IPA=\(fileName)", source: "SigningViewModel")
            // 取消：不导入，也不设置任何扩展选项。
        }
    }

    // MARK: - 重签

    // MARK: - 签名前自动撤销证书

    /// 委托给 BridgeClient.shared.autoRevokeBeforeSigning（共享逻辑含去重、开关、日志）。
    private func autoRevokeBeforeSigning(completion: @escaping (Error?) -> Void) {
        client.autoRevokeBeforeSigning(completion: completion)
    }

    func resign(app: InstalledApp) {
        guard !app.isSigning else { return }
        guard beginWork("正在签名 \(app.displayName)…") else { return }

        markSigning(true, for: app.bundleIdentifier)
        LogManager.shared.info("开始重签: \(app.bundleIdentifier)", source: "SigningViewModel")

        autoRevokeBeforeSigning { _ in
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
        // v1.1.148: clamp 提前重签天数上限（与 daemon kMaxThresholdDays 一致，最多 6 天）
        let threshold = min(UserDefaults.standard.object(forKey: "resignThreshold") as? Int ?? 2, 6)
        guard beginWork("正在批量重签…") else { return }

        LogManager.shared.info("开始批量重签（阈值 \(threshold) 天）", source: "SigningViewModel")

        autoRevokeBeforeSigning { [weak self] _ in
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

        autoRevokeBeforeSigning { [weak self] _ in
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

    // MARK: - 小黑屋（黑名单）

    /// 把应用加入小黑屋；source 记录它来自哪个原始列表。
    /// 加入后自动续签/批量签名会跳过它，但单点「重签」仍可手动触发。
    ///
    /// 只调 `recomputeLists()` 即可——黑名单只是个 UserDefaults 集合，**不会**
    /// 改变设备上已装应用列表，所以无需重新从 installd 拉取。
    /// 旧版本会再 `refreshApps()/refreshOtherApps()`，造成连续 2~3 次渲染，
    /// 加上异步拉取延迟，用户会看到「割裂感→约 1 秒后恢复」的鬼影。
    func addToBlacklist(_ app: InstalledApp, source: BlacklistSource) {
        BlacklistStore.shared.add(app.bundleIdentifier, source: source)
        recomputeLists()
        LogManager.shared.info("已加入小黑屋: \(app.bundleIdentifier)（来源: \(source.label)）", source: "SigningViewModel")
    }

    /// 把应用移出小黑屋。
    func removeFromBlacklist(_ app: InstalledApp) {
        BlacklistStore.shared.remove(app.bundleIdentifier)
        recomputeLists()
        LogManager.shared.info("已移出小黑屋: \(app.bundleIdentifier)", source: "SigningViewModel")
    }

    /// 清空小黑屋（设置页调用）。
    func clearBlacklist() {
        BlacklistStore.shared.clear()
        recomputeLists()
        LogManager.shared.info("已清空小黑屋", source: "SigningViewModel")
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
        func update(_ arr: inout [InstalledApp]) {
            guard let index = arr.firstIndex(where: { $0.bundleIdentifier == bundleID }) else { return }
            arr[index].isSigning = signing
            if !signing { arr[index].signingProgress = 0 }
        }
        update(&installedApps)
        update(&otherApps)
        update(&blacklistedApps)
    }
}
