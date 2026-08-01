import UIKit

/// Daemon（repro-signingd）定时触发续签：写触发标记 → notify_post/后台拉起 App
/// → App 执行续签 → 结果写入 /tmp/reprorefresh_at.log。
/// App 未运行时 daemon 仍独立完成检查并记录。
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    private static let ipcDir = "/var/mobile/Library/RePro"
    private static let daemonLogPath = "/tmp/reprorefresh_at.log"

    // MARK: - UIApplicationDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.initialize()
        LogManager.shared.info("RePro 启动", source: "AppDelegate")

        RPVBridge.installRootHelperHandlers()

        BridgeClient.shared.fetchEnvironment { snapshot in
            LogManager.shared.info(
                "环境: \(snapshot.jailbreak.displayName), zsign=\(snapshot.zsignPath ?? "未找到"), "
                + "证书内置=\(snapshot.certificatesBundled), root helper=\(snapshot.rootHelperPath ?? "未安装")",
                source: "AppDelegate")
        }

        syncSigningdConfig()
        setupSigningdNotify()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-foreground-resign"),
            object: nil, queue: .main) { [weak self] _ in
                self?.doAutoResign()
            }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-config-updated"),
            object: nil, queue: .main) { [weak self] _ in
                self?.syncSigningdConfig()
            }

        // daemon 后台拉起 App → 检测触发标记 → 直接执行续签
        if checkDaemonTrigger() {
            LogManager.shared.info("检测到 daemon 触发标记，即将执行后台续签", source: "AppDelegate")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.doAutoResign()
            }
            return true
        }

        scheduleAutoResignIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if checkDaemonTrigger() {
            LogManager.shared.info("检测到 daemon 触发标记，执行自动续签", source: "AppDelegate")
            doAutoResign()
        } else {
            scheduleAutoResignIfNeeded()
        }
    }

    // MARK: - daemon 触发检测

    /// 检查 daemon 是否写入了触发标记
    private func checkDaemonTrigger() -> Bool {
        let triggerPath = "\(Self.ipcDir)/auto-resign-trigger"
        let fm = FileManager.default
        guard fm.fileExists(atPath: triggerPath) else { return false }

        guard let attrs = try? fm.attributesOfItem(atPath: triggerPath),
              let mtime = attrs[.modificationDate] as? Date else { return false }

        let key = "lastDaemonTriggerTime"
        let defaults = UserDefaults.standard
        let lastProcessed = defaults.object(forKey: key) as? Date ?? .distantPast

        if mtime > lastProcessed {
            defaults.set(mtime, forKey: key)
            return true
        }
        return false
    }

    // MARK: - 自动续签

    private func scheduleAutoResignIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "autoResign") as? Bool ?? true else { return }
        guard BridgeClient.shared.isSignedIn else { return }

        let intervalMin = defaults.object(forKey: "checkIntervalMin") as? Int ?? 360
        let last = defaults.object(forKey: Self.lastAutoResignKey) as? Date
        if let last = last,
           Date().timeIntervalSince(last) < TimeInterval(intervalMin) * 60 {
            return
        }

        doAutoResign()
    }

    private func doAutoResign() {
        let defaults = UserDefaults.standard
        let threshold = defaults.object(forKey: "resignThreshold") as? Int ?? 2
        defaults.set(Date(), forKey: Self.lastAutoResignKey)
        LogManager.shared.info("触发自动重签（阈值 \(threshold) 天）", source: "AppDelegate")

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { [weak self] result in
            guard let self = self else { return }

            RPVSigningdNotify.notifySigningComplete()

            let message: String
            switch result {
            case .success:
                message = "续签成功"
                LogManager.shared.info("自动重签完成", source: "AppDelegate")
            case .failure(let error):
                message = error.localizedDescription
                LogManager.shared.warning("自动重签结束: \(message)", source: "AppDelegate")
            }

            // 写入 daemon 共享日志（/tmp/reprorefresh_at.log）
            self.appendDaemonLog("续签结果 — \(message)")
        }
    }

    // MARK: - /tmp/reprorefresh_at.log 写入

    private func appendDaemonLog(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = df.string(from: Date())
        let line = "[\(ts)] [App] \(msg)\n"

        guard let data = line.data(using: .utf8) else { return }
        let path = Self.daemonLogPath

        if FileManager.default.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        chmod(path, 0o644)
    }

    // MARK: - repro-signingd IPC

    func syncSigningdConfig() {
        let defaults = UserDefaults.standard
        let intervalMin = defaults.object(forKey: "checkIntervalMin") as? Int ?? 360

        let config: [String: Any] = [
            "autoResign":       defaults.object(forKey: "autoResign") as? Bool ?? true,
            "checkIntervalMin": intervalMin,
            "resignThreshold":  defaults.object(forKey: "resignThreshold") as? Int ?? 2,
        ]

        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.ipcDir) {
            try? fm.createDirectory(atPath: Self.ipcDir,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        }

        let configPath = "\(Self.ipcDir)/signingd-config.plist"
        (config as NSDictionary).write(toFile: configPath, atomically: true)

        RPVSigningdNotify.notifyConfigUpdated()
        LogManager.shared.info("已同步 signingd 配置（间隔 \(intervalMin) 分钟）", source: "AppDelegate")
    }

    private func setupSigningdNotify() {
        let _ = RPVSigningdNotify.shared
    }
}
