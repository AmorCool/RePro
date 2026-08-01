import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    /// 上一次自动重签的时间戳（UserDefaults key）
    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    /// IPC 共享目录
    private static let ipcDir = "/var/mobile/Library/RePro"

    // MARK: - UIApplicationDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.initialize()
        LogManager.shared.info("RePro 启动", source: "AppDelegate")

        // 请求本地通知权限（后台自动续签结果通知）
        requestNotificationPermission()
        UNUserNotificationCenter.current().delegate = self

        // 注册需要 root 的两个回调
        RPVBridge.installRootHelperHandlers()

        // 环境体检
        BridgeClient.shared.fetchEnvironment { snapshot in
            LogManager.shared.info(
                "环境: \(snapshot.jailbreak.displayName), zsign=\(snapshot.zsignPath ?? "未找到"), "
                + "证书内置=\(snapshot.certificatesBundled), root helper=\(snapshot.rootHelperPath ?? "未安装")",
                source: "AppDelegate")
        }

        // 把当前自动续签设置同步到共享 plist（供 repro-signingd LaunchDaemon 读取）
        syncSigningdConfig()
        // 注册 notify 监听（Daemon 每小时发一次信号）
        setupSigningdNotify()
        // 前台收到 daemon 的 notify 时直接跑自动续签
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-foreground-resign"),
            object: nil, queue: .main) { [weak self] _ in
                self?.doAutoResign()
            }
        // 设置页保存时通知 daemon 重读配置
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-config-updated"),
            object: nil, queue: .main) { [weak self] _ in
                self?.syncSigningdConfig()
            }

        scheduleAutoResignIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 检查 daemon 是否发了续签请求（daemon 写时间戳文件 → 比上次执行更新则触发）
        if checkSigningdRequest() {
            LogManager.shared.info("收到 repro-signingd 续签请求，触发自动重签", source: "AppDelegate")
            doAutoResign()
        } else {
            scheduleAutoResignIfNeeded()
        }
    }

    // MARK: - 自动续签（App 前台时按间隔触发）

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
                self.sendResignNotification(title: "自动续签完成",
                                            body: "所有临近过期的应用已成功续签")
            case .failure(let error):
                let msg = error.localizedDescription
                LogManager.shared.warning("自动重签结束: \(msg)", source: "AppDelegate")
                if msg.contains("No applications need") || msg.contains("当前无需重签") {
                    self.sendResignNotification(title: "自动续签",
                                                body: "当前没有需要续签的应用")
                } else {
                    self.sendResignNotification(title: "自动续签失败",
                                                body: msg)
                }
            }
        }
    }

    // MARK: - repro-signingd IPC（后台定时续签守护进程）

    /// 同步当前自动续签设置到共享 plist，供 repro-signingd LaunchDaemon 读取。
    /// 调用时机：App 启动、设置页保存时（通过 notify_post 通知 daemon 重读）。
    func syncSigningdConfig() {
        let defaults = UserDefaults.standard
        let config: [String: Any] = [
            "autoResign":      defaults.object(forKey: "autoResign") as? Bool ?? true,
            "checkInterval":   defaults.object(forKey: "checkInterval") as? Int ?? 6,
            "resignThreshold": defaults.object(forKey: "resignThreshold") as? Int ?? 2,
        ]

        // 确保 IPC 目录存在
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.ipcDir) {
            try? fm.createDirectory(atPath: Self.ipcDir,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        }

        let configPath = "\(Self.ipcDir)/signingd-config.plist"
        (config as NSDictionary).write(toFile: configPath, atomically: true)

        // 通知 daemon 重新加载配置
        RPVSigningdNotify.notifyConfigUpdated()
        LogManager.shared.info("已同步 signingd 配置: autoResign=\(config["autoResign"] ?? true), "
                               + "间隔=\(config["checkInterval"] ?? 6)h, 阈值=\(config["resignThreshold"] ?? 2)d",
                               source: "AppDelegate")
    }

    /// 注册 notify 监听：当 repro-signingd 触发续签时，如果 App 正在前台，
    /// 直接跑自动续签。
    private func setupSigningdNotify() {
        let _ = RPVSigningdNotify.shared
    }

    /// 检查 daemon 是否发了续签请求：
    /// 读 /var/mobile/Library/RePro/auto-resign-request 的 mtime，
    /// 比 UserDefaults 里记录的「上次处理时间」更新 → 返回 true。
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

    // MARK: - 本地通知（后台自动续签结果）

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                LogManager.shared.info("本地通知权限已获取", source: "AppDelegate")
            } else if let error = error {
                LogManager.shared.warning("本地通知权限请求失败: \(error.localizedDescription)", source: "AppDelegate")
            }
        }
    }

    /// 发送一条本地通知，让用户知道后台自动续签的結果。
    /// 如果 App 正在前台运行，通知会无声地出现在通知中心（不会弹出横幅干扰操作）。
    private func sendResignNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "auto-resign-\(Date().timeIntervalSince1970)",
                                             content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LogManager.shared.warning("发送本地通知失败: \(error.localizedDescription)", source: "AppDelegate")
            } else {
                LogManager.shared.info("已发送本地通知: \(title) - \(body)", source: "AppDelegate")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也显示通知（banner 形式），不静默丢掉
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
