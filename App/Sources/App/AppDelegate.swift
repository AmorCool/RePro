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
        BridgeClient.shared.fetchEnvironment { _ in }

        syncSigningdConfig()
        setupSigningdNotify()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-foreground-resign"),
            object: nil, queue: .main) { [weak self] _ in self?.doAutoResign() }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-config-updated"),
            object: nil, queue: .main) { [weak self] _ in self?.syncConfigSilent() }

        if checkDaemonTrigger() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.doAutoResign() }
            return true
        }
        scheduleAutoResignIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if checkDaemonTrigger() { doAutoResign() }
        else { scheduleAutoResignIfNeeded() }
    }

    // MARK: - 触发检测

    private func checkDaemonTrigger() -> Bool {
        let p = "\(Self.ipcDir)/auto-resign-trigger"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        let last = UserDefaults.standard.object(forKey: "lastDaemonTriggerTime") as? Date ?? .distantPast
        if mtime > last { UserDefaults.standard.set(mtime, forKey: "lastDaemonTriggerTime"); return true }
        return false
    }

    // MARK: - 自动续签

    private func scheduleAutoResignIfNeeded() {
        let d = UserDefaults.standard
        guard (d.object(forKey: "autoResign") as? Bool ?? true), BridgeClient.shared.isSignedIn else { return }
        let interval = d.object(forKey: "checkIntervalMin") as? Int ?? 360
        if let last = d.object(forKey: Self.lastAutoResignKey) as? Date,
           Date().timeIntervalSince(last) < TimeInterval(interval) * 60 { return }
        doAutoResign()
    }

    private func doAutoResign() {
        let d = UserDefaults.standard
        let threshold = d.object(forKey: "resignThreshold") as? Int ?? 2
        d.set(Date(), forKey: Self.lastAutoResignKey)

        // 开启 daemon 日志：后续所有 LogManager 日志同步写入 reprorefresh_at.log
        DaemonLogStart(DaemonLogDefaultPath())
        LogManager.shared.info("══════ 自动续签（阈值 \(threshold) 天）══════", source: "AppDelegate")

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { _ in
            RPVSigningdNotify.notifySigningComplete()
            LogManager.shared.info("自动续签结束", source: "AppDelegate")
            DaemonLogStop()
        }
    }

    // MARK: - daemon 配置同步

    func syncSigningdConfig()   { _syncConfig(log: true) }
    func syncConfigSilent()     { _syncConfig(log: false) }

    private func _syncConfig(log: Bool) {
        let d = UserDefaults.standard
        let config: [String: Any] = [
            "autoResign":       d.object(forKey: "autoResign") as? Bool ?? true,
            "checkIntervalMin": d.object(forKey: "checkIntervalMin") as? Int ?? 360,
            "resignThreshold":  d.object(forKey: "resignThreshold") as? Int ?? 2,
        ]
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.ipcDir) {
            try? fm.createDirectory(atPath: Self.ipcDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        (config as NSDictionary).write(toFile: "\(Self.ipcDir)/signingd-config.plist", atomically: true)
        RPVSigningdNotify.notifyConfigUpdated()
        if log { LogManager.shared.info("配置已同步到 daemon", source: "AppDelegate") }
    }

    private func setupSigningdNotify() { let _ = RPVSigningdNotify.shared }
}
