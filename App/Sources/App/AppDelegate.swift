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
        if isDaemonTriggeredResign(application) {
            return silentResignAndExit()
        }

        LogManager.shared.info("RePro 启动", source: "AppDelegate")
        RPVBridge.installRootHelperHandlers()

        // 申请通知权限。只在有界面的正常启动里申请：
        // 静默续签分支没有 UI，不该在那里把系统授权弹窗推给用户。
        // RootHide 下授权能否持久，取决于 RPVNotificationManager.m 里
        // -[UNUserNotificationCenter initWithBundleIdentifier:] 的 Hook。
        RPVNotificationManager.sharedInstance().registerToSendNotifications()

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

    /// 是否为 daemon 后台拉起的静默续签
    ///
    /// v1.1.63 修复：旧版只看 trigger 文件 10 秒内的 mtime。越狱设备冷启动 +
    /// 各种注入耗时经常超过 10 秒，判定失败后 App 就以完整 UI 启动，
    /// 于是「daemon 独立续签」看起来完全没生效。
    ///
    /// 新判定 = 后台启动 + trigger 文件在 180 秒内。
    /// applicationState 在 didFinishLaunching 时：
    ///   用户点图标启动 → .inactive
    ///   SBSLaunchApplication 后台拉起 → .background
    /// 用它区分，就能安全放宽时间窗口而不会让用户点开 App 时闪退。
    private func isDaemonTriggeredResign(_ application: UIApplication) -> Bool {
        guard application.applicationState == .background else { return false }
        let p = "\(Self.ipcDir)/auto-resign-trigger"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mtime) < 180
    }

    /// 写详细续签报告，供 daemon 的 --status 读取
    /// 这是用户判断「到底有没有真的续签」的唯一可靠依据
    private func writeResignReport(result: String, detail: String,
                                   elapsed: TimeInterval,
                                   trigger: String = "daemon-background-launch") {
        let report: [String: Any] = [
            "result":    result,
            "detail":    detail,
            "elapsed":   elapsed,
            "timestamp": Date().timeIntervalSince1970,
            "trigger":   trigger,
        ]
        (report as NSDictionary).write(toFile: "\(Self.ipcDir)/app-resign-report.plist", atomically: true)
    }

    /// 执行续签，不创建窗口，完成后 exit(0)
    private func silentResignAndExit() -> Bool {
        RPVBridge.installRootHelperHandlers()
        DaemonLogStart(DaemonLogDefaultPath())

        let started = Date()

        // 消费触发标记：避免用户随后手动打开 App 时又被判定成静默续签而闪退
        try? FileManager.default.removeItem(atPath: "\(Self.ipcDir)/auto-resign-trigger")

        LogManager.shared.info("══════ 静默续签开始（daemon 后台拉起 pid=\(getpid())）══════", source: "AppDelegate")

        let d = UserDefaults.standard
        let threshold = d.object(forKey: "resignThreshold") as? Int ?? 2

        // 未登录时直接回报失败，否则 daemon 会一直等不到完成信号
        guard BridgeClient.shared.isSignedIn else {
            LogManager.shared.warning("未登录 Apple ID → 静默续签中止", source: "AppDelegate")
            writeResignReport(result: "failed", detail: "未登录 Apple ID，无法续签", elapsed: 0)
            RPVSigningdNotify.notifySigningComplete()
            LogManager.shared.info("══════ 静默续签结束（未登录），已回报 daemon ══════", source: "AppDelegate")
            DaemonLogStop()
            Thread.sleep(forTimeInterval: 0.5)
            exit(0)
        }

        LogManager.shared.info("阈值 \(threshold) 天 → 开始扫描并重签到期应用", source: "AppDelegate")
        let sema = DispatchSemaphore(value: 0)

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { result in
            let elapsed = Date().timeIntervalSince(started)
            switch result {
            case .success:
                LogManager.shared.info(String(format: "静默续签完成，耗时 %.1f 秒", elapsed), source: "AppDelegate")
                self.writeResignReport(result: "success",
                                       detail: "阈值 \(threshold) 天内的到期应用已处理完毕",
                                       elapsed: elapsed)
            case .failure(let e):
                LogManager.shared.warning("静默续签失败: \(e.localizedDescription)", source: "AppDelegate")
                self.writeResignReport(result: "failed",
                                       detail: e.localizedDescription,
                                       elapsed: elapsed)
            }

            // ★ v1.1.63 关键修复：回报 daemon「续签已结束」
            // 旧版静默路径从不调用它，导致 daemon 永远收不到完成信号：
            //   · BKSProcessAssertion 不释放
            //   · last-resign-result.plist 不写
            //   · 用户完全无法判断到底有没有续签
            // 只有前台的 doAutoResign() 会回报，所以看上去「必须打开 App 才行」。
            RPVSigningdNotify.notifySigningComplete()
            LogManager.shared.info("══════ 静默续签结束，已回报 daemon ══════", source: "AppDelegate")
            DaemonLogStop()
            sema.signal()
        }

        sema.wait()
        // addNotificationRequest 是异步 XPC，立刻 exit(0) 有可能让最后一条
        // 续签结果通知还没提交到 usernoted 就被丢掉，这里留出提交窗口。
        Thread.sleep(forTimeInterval: 0.8)
        exit(0)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if checkDaemonTrigger() { doAutoResign() }
        else { tryAutoResign() }
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

        let started = Date()
        DaemonLogStart(DaemonLogDefaultPath())
        LogManager.shared.info("══════ 自动续签（阈值 \(threshold) 天）══════", source: "AppDelegate")

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { result in
            let elapsed = Date().timeIntervalSince(started)
            switch result {
            case .success:
                self.writeResignReport(result: "success",
                                       detail: "App 激活时触发，阈值 \(threshold) 天",
                                       elapsed: elapsed, trigger: "app-foreground")
            case .failure(let e):
                self.writeResignReport(result: "failed", detail: e.localizedDescription,
                                       elapsed: elapsed, trigger: "app-foreground")
            }
            RPVSigningdNotify.notifySigningComplete()
            LogManager.shared.info(String(format: "自动续签结束，耗时 %.1f 秒", elapsed), source: "AppDelegate")
            DaemonLogStop()
        }
    }

    // MARK: - daemon 配置同步

    func syncSigningdConfig() { _syncConfig() }
    func syncConfigSilent()   { _syncConfig() }

    private func _syncConfig() {
        let d = UserDefaults.standard
        let intervalMin = d.object(forKey: "checkIntervalMin") as? Int ?? 120
        let config: [String: Any] = [
            "autoResign":       d.object(forKey: "autoResign") as? Bool ?? true,
            "checkIntervalMin": intervalMin,
            "resignThreshold":  d.object(forKey: "resignThreshold") as? Int ?? 2,
        ]
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.ipcDir) {
            try? fm.createDirectory(atPath: Self.ipcDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let plistPath = "\(Self.ipcDir)/signingd-config.plist"
        (config as NSDictionary).write(toFile: plistPath, atomically: true)
        RPVSigningdNotify.notifyConfigUpdated()
        LogManager.shared.info("配置已同步到 plist: autoResign=\(config["autoResign"] ?? "nil") checkIntervalMin=\(intervalMin)min", source: "AppDelegate")
    }

    private func setupSigningdNotify() { let _ = RPVSigningdNotify.shared }
}
