import Foundation
import Combine

// MARK: - 签名逻辑协调 ViewModel

class SigningViewModel: ObservableObject {
    @Published var installedApps: [InstalledApp] = []
    @Published var isSigningAll: Bool = false
    @Published var progressMessage: String = ""
    @Published var currentSigningBundleID: String?

    private let daemonClient = DaemonClient.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadInstalledApps()
    }

    // MARK: 加载已安装应用
    func loadInstalledApps() {
        // 通过 Daemon 获取已安装应用（异步加载）
        Task {
            await refreshApps()
        }
    }

    func refreshApps() async {
        daemonClient.getInstalledApps { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let apps):
                    self?.installedApps = apps.sorted { ($0.daysUntilExpiry) < ($1.daysUntilExpiry) }
                case .failure(let error):
                    LogManager.shared.error("获取应用列表失败: \(error)", source: "SigningViewModel")
                }
            }
        }
    }

    // MARK: 导入 IPA
    func importIPA(url: URL) {
        LogManager.shared.info("导入 IPA: \(url.lastPathComponent)", source: "SigningViewModel")

        // 复制到临时目录，然后发送给 Daemon 处理
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent(url.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)

            daemonClient.importIPA(path: destURL.path) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let app):
                        self?.installedApps.insert(app, at: 0)
                        LogManager.shared.info("IPA 导入成功: \(app.bundleIdentifier)", source: "SigningViewModel")
                    case .failure(let error):
                        LogManager.shared.error("IPA 导入失败: \(error)", source: "SigningViewModel")
                    }
                }
            }
        } catch {
            LogManager.shared.error("复制 IPA 失败: \(error)", source: "SigningViewModel")
        }
    }

    // MARK: 重签单个应用
    func resign(app: InstalledApp) {
        guard !app.isSigning else { return }

        // 更新本地状态
        if let index = installedApps.firstIndex(where: { $0.id == app.id }) {
            installedApps[index].isSigning = true
        }
        currentSigningBundleID = app.bundleIdentifier
        progressMessage = "正在签名 \(app.displayName)..."

        LogManager.shared.info("开始重签: \(app.bundleIdentifier)", source: "SigningViewModel")

        daemonClient.resign(bundleID: app.bundleIdentifier) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // 重置状态
                if let index = self.installedApps.firstIndex(where: { $0.id == app.id }) {
                    self.installedApps[index].isSigning = false
                }
                self.currentSigningBundleID = nil

                switch result {
                case .success:
                    self.progressMessage = "签名完成"
                    LogManager.shared.info("重签成功: \(app.bundleIdentifier)", source: "SigningViewModel")
                    // 刷新应用列表以更新过期时间
                    Task { await self.refreshApps() }
                case .failure(let error):
                    self.progressMessage = "签名失败"
                    LogManager.shared.error("重签失败 [\(app.bundleIdentifier)]: \(error)", source: "SigningViewModel")
                }
            }
        }
    }

    // MARK: 全部重签
    func resignAll() {
        guard !isSigningAll else { return }
        isSigningAll = true

        LogManager.shared.info("开始全部重签 (\(installedApps.count) 个应用)", source: "SigningViewModel")

        let appsToSign = installedApps.filter { !$0.isSigning && $0.daysUntilExpiry <= 7 }

        for app in appsToSign {
            resign(app: app)
        }

        isSigningAll = false
    }

    // MARK: 删除应用记录
    func removeApp(app: InstalledApp) {
        installedApps.removeAll { $0.id == app.id }
        LogManager.shared.info("移除应用记录: \(app.bundleIdentifier)", source: "SigningViewModel")
    }
}
