import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    private static let ipcDir = "/var/mobile/Library/RePro"

    // MARK: - UIApplicationDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.initialize()
        LogManager.shared.info("RePro 启动", source: "AppDelegate")

        // 一次性请求通知权限（系统处理去重，不会反复弹窗）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            LogManager.shared.info(granted ? "通知权限已获取" : "通知权限未授权", source: "AppDelegate")
        }
        UNUserNotificationCenter.current().delegate = self

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
        // daemon 回传通知显示请求 → App 读取共享 plist 并发送本地通知
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.show-notification-done"),
            object: nil, queue: .main) { [weak self] _ in
                self?.dispatchDaemonNotification()
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
                self.requestDaemonShow(title: "自动续签完成",
                                       body: "所有临近过期的应用已成功续签 ✓")
            case .failure(let error):
                let msg = error.localizedDescription
                LogManager.shared.warning("自动重签结束: \(msg)", source: "AppDelegate")
                if msg.contains("No applications need") || msg.contains("当前无需重签") {
                    self.requestDaemonShow(title: "自动续签",
                                           body: "当前没有需要续签的应用")
                } else {
                    self.requestDaemonShow(title: "自动续签失败", body: msg)
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

    // MARK: - 通知（App 自己发 UNUserNotificationCenter，daemon 负责协调）

    /// App 续签完成后 → 写通知内容到共享 plist → daemon 收到后回传 → App 显示。
    /// 这么做是为了让 daemon 有机会参与协调（比如去重、限流），
    /// 但实际显示通知的仍是 App 自身（daemon 在 iOS 上没有可用的通知 API）。
    private func requestDaemonShow(title: String, body: String) {
        AppDelegate.writeNotificationContent(title: title, body: body)
        RPVSigningdNotify.notifyShowNotification()
        LogManager.shared.info("已请求 daemon 协调通知: 「\(title)」", source: "AppDelegate")
    }

    /// 供设置页测试按钮直接调用
    static func postDaemonNotification(title: String, body: String) {
        writeNotificationContent(title: title, body: body)
        RPVSigningdNotify.notifyShowNotification()
        LogManager.shared.info("测试通知已请求: 「\(title)」", source: "AppDelegate")
    }

    private static func writeNotificationContent(title: String, body: String) {
        let dict: [String: Any] = [
            "title": title,
            "body": body,
            "timestamp": Int(Date().timeIntervalSince1970),
        ]
        (dict as NSDictionary).write(toFile: "\(ipcDir)/auto-resign-notification.plist", atomically: true)
    }

    /// 收到 daemon 回传的通知显示信号 → 读共享 plist → 发本地通知
    private func dispatchDaemonNotification() {
        let path = "\(Self.ipcDir)/auto-resign-notification.plist"
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return }

        let title = (dict["title"] as? String) ?? "RePro"
        let body  = (dict["body"] as? String) ?? ""

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: "resign-\(dict["timestamp"] ?? 0)",
                                             content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LogManager.shared.warning("发送本地通知失败: \(error.localizedDescription)", source: "AppDelegate")
            } else {
                LogManager.shared.info("本地通知已发出: 「\(title)」→ \(body)", source: "AppDelegate")
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
