import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    private static let ipcDir = "/var/mobile/Library/RePro"

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

        scheduleAutoResignIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if checkSigningdRequest() {
            LogManager.shared.info("收到 repro-signingd 续签请求，触发自动重签", source: "AppDelegate")
            doAutoResign()
        } else {
            scheduleAutoResignIfNeeded()
        }
    }

    // MARK: - 自动续签

    private func scheduleAutoResignIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "autoResign") as? Bool ?? true else { return }
        guard BridgeClient.shared.isSignedIn else { return }

        let intervalHours = defaults.object(forKey: "checkInterval") as? Int ?? 6
        let last = defaults.object(forKey: Self.lastAutoResignKey) as? Date
        if let last = last,
           Date().timeIntervalSince(last) < TimeInterval(intervalHours) * 3600 {
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
            switch result {
            case .success:
                LogManager.shared.info("自动重签完成", source: "AppDelegate")
                self.postDaemonNotification(title: "自动续签完成",
                                            body: "所有临近过期的应用已成功续签 ✓")
            case .failure(let error):
                let msg = error.localizedDescription
                LogManager.shared.warning("自动重签结束: \(msg)", source: "AppDelegate")
                if msg.contains("No applications need") || msg.contains("当前无需重签") {
                    self.postDaemonNotification(title: "自动续签",
                                                body: "当前没有需要续签的应用")
                } else {
                    self.postDaemonNotification(title: "自动续签失败", body: msg)
                }
            }
        }
    }

    // MARK: - repro-signingd IPC

    func syncSigningdConfig() {
        let defaults = UserDefaults.standard
        let config: [String: Any] = [
            "autoResign":      defaults.object(forKey: "autoResign") as? Bool ?? true,
            "checkInterval":   defaults.object(forKey: "checkInterval") as? Int ?? 6,
            "resignThreshold": defaults.object(forKey: "resignThreshold") as? Int ?? 2,
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
        LogManager.shared.info("已同步 signingd 配置: autoResign=\(config["autoResign"] ?? true), "
                               + "间隔=\(config["checkInterval"] ?? 6)h, 阈值=\(config["resignThreshold"] ?? 2)d",
                               source: "AppDelegate")
    }

    private func setupSigningdNotify() {
        let _ = RPVSigningdNotify.shared
    }

    private func checkSigningdRequest() -> Bool {
        let requestPath = "\(Self.ipcDir)/auto-resign-request"
        let fm = FileManager.default
        guard fm.fileExists(atPath: requestPath) else { return false }

        guard let attrs = try? fm.attributesOfItem(atPath: requestPath),
              let mtime = attrs[.modificationDate] as? Date else { return false }

        let key = "lastSigningdRequestTime"
        let defaults = UserDefaults.standard
        let lastProcessed = defaults.object(forKey: key) as? Date ?? .distantPast

        if mtime > lastProcessed {
            defaults.set(mtime, forKey: key)
            return true
        }
        return false
    }

    // MARK: - 通过 Daemon 发通知（避免 RootHide namespace 假成功）

    /// App 不直接调 UNUserNotificationCenter（RootHide 下权限/注册可能落 overlay 假成功），
    /// 而是把通知内容写到共享路径，再由 repro-signingd 以 root 身份用 CFUserNotification 显示。
    static func postDaemonNotification(title: String, body: String) {
        let notiPath = "\(ipcDir)/auto-resign-notification.plist"
        let dict: [String: Any] = [
            "title": title,
            "body": body,
            "timestamp": Int(Date().timeIntervalSince1970),
        ]
        (dict as NSDictionary).write(toFile: notiPath, atomically: true)
        notify_post("com.reprovision.show-notification")
        LogManager.shared.info("已通知 daemon 发通知: 「\(title)」", source: "AppDelegate")
    }

    /// 实例方法，供内部 self 调用
    private func postDaemonNotification(title: String, body: String) {
        AppDelegate.postDaemonNotification(title: title, body: body)
    }
}
