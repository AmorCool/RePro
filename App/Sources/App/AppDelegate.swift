import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    /// 上一次自动重签的时间戳（UserDefaults key）
    private static let lastAutoResignKey = "lastAutoResignTimestamp"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.initialize()
        LogManager.shared.info("RePro 启动", source: "AppDelegate")

        // 注册需要 root 的两个回调（Phase 3 的按需 root helper）。
        // 未安装 helper 时 Vendor 侧会退回直接写文件。
        RPVBridge.installRootHelperHandlers()

        // 记录一次环境体检，出问题时日志里能直接看到 zsign / 越狱形态
        BridgeClient.shared.fetchEnvironment { snapshot in
            LogManager.shared.info(
                "环境: \(snapshot.jailbreak.displayName), zsign=\(snapshot.zsignPath ?? "未找到"), "
                + "证书内置=\(snapshot.certificatesBundled), root helper=\(snapshot.rootHelperPath ?? "未安装")",
                source: "AppDelegate")
        }

        scheduleAutoResignIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        scheduleAutoResignIfNeeded()
    }

    /// 没有常驻守护进程，自动重签改为「App 进入前台时按最小间隔触发一次」。
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

        let threshold = defaults.object(forKey: "resignThreshold") as? Int ?? 2
        defaults.set(Date(), forKey: Self.lastAutoResignKey)
        LogManager.shared.info("触发自动重签（阈值 \(threshold) 天）", source: "AppDelegate")

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { result in
            switch result {
            case .success:
                LogManager.shared.info("自动重签完成", source: "AppDelegate")
            case .failure(let error):
                LogManager.shared.warning("自动重签结束: \(error.localizedDescription)", source: "AppDelegate")
            }
        }
    }
}
