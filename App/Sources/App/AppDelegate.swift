import UIKit
import Darwin

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    private static let ipcDir = "/var/mobile/Library/RePro"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.initialize()

        // 检测到 daemon 触发标记且 App 被后台拉起 → 静默续签不显示 UI
        if isDaemonTriggeredResign() {
            return silentResignAndExit()
        }

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

        tryAutoResign()
        return true
    }

    // MARK: - 静默续签（无 UI，完成后退出）

    /// daemon 后台拉起：触发标记在过去 10 秒内写入
    private func isDaemonTriggeredResign() -> Bool {
        let p = "\(Self.ipcDir)/auto-resign-trigger"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mtime) < 10
    }

    /// 执行续签，不创建窗口，完成后 exit(0)
    private func silentResignAndExit() -> Bool {
        RPVBridge.installRootHelperHandlers()
        DaemonLogStart(DaemonLogDefaultPath())
        LogManager.shared.info("══════ 静默续签 ══════", source: "AppDelegate")

        let d = UserDefaults.standard
        let threshold = d.object(forKey: "resignThreshold") as? Int ?? 2
        let sema = DispatchSemaphore(value: 0)

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { result in
            switch result {
            case .success: LogManager.shared.info("静默续签完成", source: "AppDelegate")
            case .failure(let e): LogManager.shared.warning("静默续签失败: \(e.localizedDescription)", source: "AppDelegate")
            }
            DaemonLogStop()
            sema.signal()
        }

        sema.wait()
        exit(0)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if checkDaemonTrigger() { doAutoResign() }
        else { tryAutoResign() }
    }

    // MARK: - 快捷指令入口（从 ReProApp.onOpenURL 调用）

    /// URL scheme / 快捷指令触发静默续签，完成后 exit(0)
    static func sharedSilentResign() -> Bool {
        RPVBridge.installRootHelperHandlers()
        DaemonLogStart(DaemonLogDefaultPath())
        LogManager.shared.info("══════ 快捷指令静默续签 ══════", source: "AppDelegate")

        let d = UserDefaults.standard
        let threshold = d.object(forKey: "resignThreshold") as? Int ?? 2
        let sema = DispatchSemaphore(value: 0)

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { result in
            switch result {
            case .success: LogManager.shared.info("静默续签完成", source: "AppDelegate")
            case .failure(let e): LogManager.shared.warning("静默续签失败: \(e.localizedDescription)", source: "AppDelegate")
            }
            DaemonLogStop()
            sema.signal()
        }

        sema.wait()
        exit(0)
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

    /// 每次 App 激活时检查：已登录 + 开启自动 = 执行续签
    /// resignAllExpiring 内部会按阈值过滤，没有到期应用会快速返回
    private func tryAutoResign() {
        let d = UserDefaults.standard
        guard (d.object(forKey: "autoResign") as? Bool ?? true), BridgeClient.shared.isSignedIn else { return }
        doAutoResign()
    }

    private func doAutoResign() {
        let d = UserDefaults.standard
        let threshold = d.object(forKey: "resignThreshold") as? Int ?? 2
        d.set(Date(), forKey: Self.lastAutoResignKey)

        DaemonLogStart(DaemonLogDefaultPath())
        LogManager.shared.info("══════ 自动续签（阈值 \(threshold) 天）══════", source: "AppDelegate")

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { _ in
            RPVSigningdNotify.notifySigningComplete()
            LogManager.shared.info("自动续签结束", source: "AppDelegate")
            DaemonLogStop()
        }
    }

    // MARK: - daemon 配置同步

    func syncSigningdConfig() { _syncConfig() }
    func syncConfigSilent()   { _syncConfig() }

    private func _syncConfig() {
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
    }

    private func setupSigningdNotify() { let _ = RPVSigningdNotify.shared }
}
