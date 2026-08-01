import UIKit
import UserNotifications

/// RootHide 适配：daemon（repro-signingd）在 namespace 外直接写真实 TCC.db
/// 授权通知权限。App 不再调 requestAuthorization（避免 RootHide overlay 假写入
/// 导致权限状态丢失、每次启动都弹窗）。
///
/// 通知发送仍用 UNUserNotificationCenter.add() —— 这个 XPC 走真实的 bulletinboard
/// （RootHide 不拦截通知 XPC），真实 TCC.db 有权限即可正常显示。
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    private static let ipcDir = "/var/mobile/Library/RePro"

    // MARK: - UIApplicationDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.initialize()
        LogManager.shared.info("RePro 启动", source: "AppDelegate")

        // 设置 UNUserNotificationCenter delegate（前台也显示横幅）
        // 不调 requestAuthorization —— 权限由 daemon 写入真实 TCC.db
        UNUserNotificationCenter.current().delegate = self

        // 通知 daemon 确保真实 TCC 权限（daemon 已启动或即将启动）
        RPVSigningdNotify.notifyEnsureNotificationPermission()

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

            RPVSigningdNotify.notifySigningComplete()

            switch result {
            case .success:
                LogManager.shared.info("自动重签完成", source: "AppDelegate")
                self.sendNotification(title: "自动续签完成",
                                      body: "所有临近过期的应用已成功续签 ✓")
            case .failure(let error):
                let msg = error.localizedDescription
                LogManager.shared.warning("自动重签结束: \(msg)", source: "AppDelegate")
                if msg.contains("No applications need") || msg.contains("当前无需重签") {
                    self.sendNotification(title: "自动续签",
                                          body: "当前没有需要续签的应用")
                } else {
                    self.sendNotification(title: "自动续签失败", body: msg)
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
        LogManager.shared.info("已同步 signingd 配置", source: "AppDelegate")
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

    // MARK: - 本地通知

    /// 发送本地通知。TCC 权限由 daemon 直接写入真实 TCC.db（绕过 RootHide overlay），
    /// addNotificationRequest 的 XPC 走真实 bulletinboard，不受 namespace 影响。
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let identifier = "resign-\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier,
                                             content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LogManager.shared.warning("发送通知失败: \(error.localizedDescription)", source: "AppDelegate")
            } else {
                LogManager.shared.info("已发送本地通知: 「\(title)」", source: "AppDelegate")
            }
        }
    }

    /// 供设置页「测试发送通知」按钮调用。
    /// 先请求 daemon 确保真实 TCC 权限，然后直接发通知。
    static func testSendNotification(title: String, body: String) {
        // 确保真实 TCC 权限（daemon 在 namespace 外写入）
        RPVSigningdNotify.notifyEnsureNotificationPermission()

        // 给 daemon 一点时间写 TCC
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
            let request = UNNotificationRequest(identifier: "test-\(Int(Date().timeIntervalSince1970))",
                                                 content: content, trigger: trigger)

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    LogManager.shared.warning("测试通知发送失败: \(error.localizedDescription)", source: "AppDelegate")
                } else {
                    LogManager.shared.info("测试通知已发送", source: "AppDelegate")
                }
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
