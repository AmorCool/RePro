import UIKit

/// Daemon（repro-signingd）定时触发续签：写触发标记 → notify_post。
/// App 检测触发标记后执行续签，LogManager 所有详细日志（哪个应用、进度、
/// 成功/失败）实时写入 <jbroot>/var/log/reprorefresh_at.log。
/// daemon 不拉 App，App 未运行时触发标记保留，下次打开自动处理。
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    private static let ipcDir = "/var/mobile/Library/RePro"

    /// 从 App bundle 路径推导 jbroot（与 daemon 一致）
    static func daemonLogPath() -> String {
        let bundlePath = Bundle.main.bundlePath
        if let r = bundlePath.range(of: "/Applications/", options: .backwards) {
            return "\(bundlePath[..<r.lowerBound])/var/log/reprorefresh_at.log"
        }
        return "/var/jb/var/log/reprorefresh_at.log"
    }

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

        if checkDaemonTrigger() {
            LogManager.shared.info("检测到 daemon 触发标记，即将执行自动续签", source: "AppDelegate")
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

        // 开启 daemon 日志转发：续签期间所有 LogManager 详细日志实时写入 reprorefresh_at.log
        LogManager.shared.daemonLogPath = Self.daemonLogPath()
        LogManager.shared.info("══════ 自动续签开始（阈值 \(threshold) 天）══════", source: "AppDelegate")

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { [weak self] result in
            guard let self = self else { return }

            RPVSigningdNotify.notifySigningComplete()

            switch result {
            case .success:
                LogManager.shared.info("自动续签完成", source: "AppDelegate")
            case .failure(let error):
                LogManager.shared.warning("自动续签结束: \(error.localizedDescription)", source: "AppDelegate")
            }

            // 关闭 daemon 日志转发
            LogManager.shared.daemonLogPath = nil
        }
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
