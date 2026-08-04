import UIKit
import Darwin
import Combine

/// 全局续签进度提示。
/// daemon 后台静默续签进行中时，用户从主屏打开 App 会看到一条横幅，
/// 明确告知「这是正常行为、无需操作」，避免被误以为是 BUG（白屏/卡死）。
final class ResignProgress: ObservableObject {
    static let shared = ResignProgress()
    @Published var isResigning = false
    @Published var title: String = ""
    @Published var message: String = ""

    func show(title: String, message: String) {
        self.title = title
        self.message = message
        self.isResigning = true
    }
    func hide() {
        self.isResigning = false
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private static let lastAutoResignKey = "lastAutoResignTimestamp"
    private static let ipcDir = "/var/mobile/Library/RePro"

    /// 标记 daemon 后台静默续签是否正在进行。
    /// 用于防止用户在续签期间打开 App 时，applicationDidBecomeActive
    /// 又触发一次前台续签（重复签名）。
    private var daemonResignInProgress = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.initialize()

        // 公共初始化：根助手回调、通知代理、配置同步、通知监听。
        // 无论前台打开还是 daemon 后台拉起都执行，保证 UI / 回调始终就绪（修复白屏）。
        setupCommon()

        // daemon 后台拉起的静默续签：不弹权限框、不触发前台重复续签
        if isDaemonTriggeredResign(application) {
            startDaemonResign()
            return true
        }

        LogManager.shared.info("ReSign 启动", source: "AppDelegate")

        // 申请通知权限（仅正常启动路径；静默续签无 UI，不该弹系统授权窗）。
        // RootHide 下授权能否持久，取决于 RPVNotificationManager.m 里
        // -[UNUserNotificationCenter initWithBundleIdentifier:] 的 Hook。
        RPVNotificationManager.sharedInstance().registerToSendNotifications()

        BridgeClient.shared.fetchEnvironment { _ in }

        // 冷启动时的自动续签交给 applicationDidBecomeActive 统一触发，避免重复。
        return true
    }

    // MARK: - 公共初始化

    private func setupCommon() {
        RPVBridge.installRootHelperHandlers()

        // 🔴 Keychain accessible 迁移（v1.1.91 起自动化，无需用户手动打开 App）。
        //
        // 迁移内容：把 Apple ID 密码 + 签名状态项（uuid / privateKey / privateKeyTeamID）
        // 全部「删后重建」为 accessible=AfterFirstUnlock，并镜像到本地缓存文件。
        //
        // 放在 setupCommon 而不是 applicationDidBecomeActive：后者只有用户「手动前台
        // 打开 App」才会触发；而 setupCommon 在 daemon 后台拉起时同样执行，
        // 因此只要设备当时是解锁的，迁移就会自动完成。
        RPVBridge.migrateKeychainAccessibility()

        // 兜底：若 App 是在「锁屏状态」下被 daemon 拉起的，上面那次迁移读不到 Keychain
        // 而无法完成。此时注册系统的「保护数据可用」通知 —— 用户下次解锁设备的瞬间
        // 系统会发出它，那一刻 Keychain 可读，迁移即自动完成。全程无需用户打开 App。
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main) { _ in
            RPVBridge.migrateKeychainAccessibility()
            LogManager.shared.info("设备已解锁（保护数据可用）→ 自动执行 Keychain accessible 迁移",
                                   source: "AppDelegate")
        }

        // 确保前台时续签 / 安装的横幅能正常弹出（delegate 只影响「App 在前台时」的展示，
        // 不影响后台时系统照常弹横幅）。不在此处申请权限，避免 daemon 后台路径弹系统授权窗。
        UNUserNotificationCenter.current().delegate = RPVNotificationManager.sharedInstance()

        syncSigningdConfig()
        setupSigningdNotify()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-foreground-resign"),
            object: nil, queue: .main) { [weak self] _ in self?.doAutoResign() }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.reprovision.signingd-config-updated"),
            object: nil, queue: .main) { [weak self] _ in self?.syncConfigSilent() }
    }

    // MARK: - 静默续签（daemon 后台拉起，可能无 UI）

    /// 是否为 daemon 后台拉起的静默续签
    ///
    /// 判定 = 后台启动 + trigger 文件在 180 秒内。
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

    /// daemon 后台拉起时执行静默续签。
    /// 与旧版区别：
    ///  · 不再在主线程 sema.wait() 阻塞、也不在 didFinishLaunching 里直接 exit(0)，
    ///    而是异步跑续签，UI 始终会初始化 → 用户在续签期间点开 App 不再是白屏。
    ///  · 续签完成后，若 App 仍处在后台（用户没打开），才干净退出；
    ///    若用户中途打开（已转到前台），则保留进程、正常显示 UI。
    private func startDaemonResign() {
        daemonResignInProgress = true
        // 提示横幅：用户中途打开 App 时，明确告知这是 daemon 后台续签、无需操作
        ResignProgress.shared.show(
            title: "ReSign 后台自动续签",
            message: "Daemon 后台自动续签流程已开始，无需任何操作！请勿杀掉后台，但您可以退出此程序。"
        )
        DaemonLogStart(DaemonLogDefaultPath())

        let started = Date()

        // 消费触发标记：避免用户随后手动打开 App 时又被判定成静默续签而闪退
        try? FileManager.default.removeItem(atPath: "\(Self.ipcDir)/auto-resign-trigger")

        LogManager.shared.info("══════ 静默续签开始（daemon 后台拉起 pid=\(getpid())）══════", source: "AppDelegate")

        // 🔴 v1.1.112: 账号刷新重试循环搬到后台线程执行。
        // 原实现把 Thread.sleep(forTimeInterval: 5) ×最多 2 次直接放在【主线程】上：
        // 网络抖动 / 锁屏 Keychain 不可读时 refreshAccountState 连续失败，主线程被阻塞
        // 10s+（期间 didFinishLaunching 尚未返回），daemon 后台拉起场景下 iOS 看门狗
        // 判定主线程无响应 → ExcUserFault（EXC_GUARD / GUARD_TYPE_USER / LIBXPC
        // XPC_EXIT_REASON_FAULT，is_simulated=1）直接杀 App。
        // 实据：设备 8/3 13:17 / 13:51 / 13:52 / 13:53 连续 4 份同型崩溃（1.1.92/1.1.94），
        // 且用户日志同时段出现「拉取证书列表失败…似乎已断开与互联网的连接」。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let d = UserDefaults.standard
            let threshold = d.object(forKey: "resignThreshold") as? Int ?? 2

            // 锁屏/刚唤醒（锁屏界面尚未解锁）时 SAMKeychain 可能暂时读不到密码，导致 isSignedIn 为假。
            // 重试最多 3 次（每次间隔 5 秒）兜底；但真正的修复在 v1.1.90：
            // 旧版 migrateKeychainAccessibility 走 SecItemUpdate，根本改不了 kSecAttrAccessible
            // （该属性只能在 SecItemAdd 创建时设定），所以密码项一直停留在 WhenUnlocked；
            // v1.1.90 改为「删后重建」+ 刷新本地凭证缓存文件，后台锁屏也能读到密码。
            let maxRetry = 3
            var signedIn = false
            for attempt in 1...maxRetry {
                BridgeClient.shared.refreshAccountState()
                if BridgeClient.shared.isSignedIn { signedIn = true; break }
                if attempt < maxRetry {
                    LogManager.shared.info("未登录 Apple ID（锁屏 Keychain 不可读？网络抖动？），5s 后重试 \(attempt)/\(maxRetry - 1)…", source: "AppDelegate")
                    Thread.sleep(forTimeInterval: 5)   // 后台线程 sleep，不再阻塞主线程
                }
            }

            guard signedIn else {
                LogManager.shared.warning("未登录 Apple ID → 静默续签中止（重试 \(maxRetry) 次仍失败，请确认设备已解锁过一次）", source: "AppDelegate")
                self.writeResignReport(result: "failed", detail: "未登录 Apple ID，无法续签", elapsed: 0)
                RPVSigningdNotify.notifySigningComplete()
                self.daemonResignInProgress = false
                LogManager.shared.info("══════ 静默续签结束（未登录），已回报 daemon ══════", source: "AppDelegate")
                DaemonLogStop()
                Thread.sleep(forTimeInterval: 0.5)     // 后台线程 sleep，不影响主线程
                exit(0)
                return
            }

            // 后台任务保活：确保与 Apple 服务器的续签网络请求不会被系统挂起。
            // Apple 文档要求 beginBackgroundTask 在【主线程】调用，故回主线程开启。
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let bgTask = UIApplication.shared.beginBackgroundTask(withName: "repro-daemon-resign") { }
                LogManager.shared.info("阈值 \(threshold) 天 → 开始扫描并重签到期应用", source: "AppDelegate")

                // 签名前自动撤销旧证书（与前台 SigningViewModel 共享同一套逻辑），
                // 防止 "You already have a current Development certificate or a pending certificate request" 错误。
                // v1.1.86 前此处直接调 resignAllExpiring 漏掉了撤销步骤 → 后台续签 CSR 冲突。
                BridgeClient.shared.autoRevokeBeforeSigning { [weak self] in
                    guard let self = self else { return }
                    BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { [weak self] result in
                        guard let self = self else { return }
                        let elapsed = Date().timeIntervalSince(started)
                        self.handleResignCompletion(result: result, elapsed: elapsed, isDaemon: true)
                        UIApplication.shared.endBackgroundTask(bgTask)
                    }
                }
            }
        }
    }

    /// 续签完成统一收尾：写报告、回报 daemon、发通知、按需退出。
    /// isDaemon=true 表示 daemon 后台拉起；false 表示前台激活触发。
    private func handleResignCompletion(result: Result<Void, Error>,
                                        elapsed: TimeInterval,
                                        isDaemon: Bool) {
        let trigger = isDaemon ? "daemon-background-launch" : "app-foreground"
        let success: Bool
        let errorText: String

        switch result {
        case .success:
            success = true
            errorText = ""
            LogManager.shared.info(String(format: "续签完成，耗时 %.1f 秒", elapsed), source: "AppDelegate")
            writeResignReport(result: "success",
                             detail: "阈值内的到期应用已处理完毕",
                             elapsed: elapsed, trigger: trigger)
        case .failure(let e):
            success = false
            errorText = e.localizedDescription
            LogManager.shared.warning("续签失败: \(errorText)", source: "AppDelegate")
            writeResignReport(result: "failed", detail: errorText, elapsed: elapsed, trigger: trigger)
        }

        // 续签完成通知：daemon 路径无论成败都通知；前台路径仅在失败时补一条总览
        // （前台成功由 BridgeClient 逐应用「重签完成」通知覆盖，避免重复打扰）。
        // notificationsEnabled 关闭时 RPVNotificationManager 内部自动 no-op。
        if isDaemon || !success {
            sendResignNotification(success: success, errorText: errorText, isDaemon: isDaemon)
        }

        RPVSigningdNotify.notifySigningComplete()
        LogManager.shared.info("══════ 续签结束，已回报 daemon ══════", source: "AppDelegate")
        DaemonLogStop()
        daemonResignInProgress = false
        ResignProgress.shared.hide()

        // daemon 后台拉起且用户全程未打开 → 干净退出，释放 daemon 侧的 BKS 断言
        if isDaemon && UIApplication.shared.applicationState == .background {
            // 留出本地通知提交窗口（usernoted 异步 XPC），确保续签结果横幅能送达
            Thread.sleep(forTimeInterval: 1.5)
            exit(0)
        }
    }

    /// 发送续签完成 / 失败通知
    private func sendResignNotification(success: Bool, errorText: String, isDaemon: Bool) {
        let title: String
        let body: String
        if success {
            title = isDaemon ? "ReSign 后台续签完成" : "ReSign 续签完成"
            body  = isDaemon ? "后台自动续签已成功完成" : "应用续签已成功完成"
        } else {
            title = isDaemon ? "ReSign 后台续签失败" : "ReSign 续签失败"
            body  = errorText.isEmpty ? "未知错误" : errorText
        }
        RPVNotificationManager.sharedInstance().sendNotification(title: title, body: body, isDebug: false, identifier: nil)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 再迁移一次（幂等）。主路径已在 setupCommon + 「保护数据可用」通知里自动完成，
        // 这里只是前台激活时的额外保险。
        RPVBridge.migrateKeychainAccessibility()

        // v1.1.124：前台激活时若设备重启过且未修复过 → 自动修复越狱联网
        // （daemon 开机已自动修一次，这里是用户手动打开 App 时的兜底，共享时间戳防抖）
        autoFixCellularIfNeeded()

        // daemon 静默续签正在进行时，不要重复触发前台续签
        if daemonResignInProgress { return }
        if checkDaemonTrigger() { doAutoResign() }
        else { tryAutoResign() }
    }

    // MARK: - 自动修复越狱联网（v1.1.124）

    /// 设备开机时间（epoch 秒），失败返回 0。
    private func systemBootTime() -> TimeInterval {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(boottime.tv_sec)
    }

    /// 上次修复时间戳（与 signingd 共享 plist，防抖）。
    private var lastFixCellularTime: TimeInterval {
        let p = "\(Self.ipcDir)/fix-cellular-last.plist"
        guard let d = NSDictionary(contentsOfFile: p),
              let ts = d["timestamp"] as? Double else { return 0 }
        return ts
    }

    /// 写修复时间戳。
    private func markFixCellularDone() {
        let p = "\(Self.ipcDir)/fix-cellular-last.plist"
        (["timestamp": Date().timeIntervalSince1970] as NSDictionary)
            .write(toFile: p, atomically: true)
    }

    /// 前台激活时自动修复：仅当「设备重启时间 > 上次修复时间」（重启越狱后授权丢失）。
    /// v1.1.126：加 lastFix > 0 门槛——首次安装（从未修复过）不自动触发，
    /// 避免 SpringBoard 重启打断首次登录；日志静默（用户要求隐藏修复联网日志）。
    private func autoFixCellularIfNeeded() {
        let boot = systemBootTime()
        let lastFix = lastFixCellularTime
        // 必须修复过（lastFix > 0）且设备重启晚于上次修复才自动补修
        guard boot > 0, lastFix > 0, boot > lastFix else { return }
        RPVBridge.sharedInstance().fixCellularData { _, _ in
            // 🔇 静默：无日志、无提示
        }
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
        // 前台手动续签也给出进度提示，避免界面看似无响应
        ResignProgress.shared.show(title: "ReSign 正在重签", message: "正在检查并重签即将到期的应用…")
        LogManager.shared.info("══════ 自动续签（阈值 \(threshold) 天）══════", source: "AppDelegate")

        BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { [weak self] result in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(started)
            self.handleResignCompletion(result: result, elapsed: elapsed, isDaemon: false)
        }
    }

    // MARK: - daemon 配置同步

    func syncSigningdConfig() { _syncConfig() }
    func syncConfigSilent()   { _syncConfig() }

    private func _syncConfig() {
        let d = UserDefaults.standard
        let intervalMin = d.object(forKey: "checkIntervalMin") as? Int ?? 120
        let config: [String: Any] = [
            "autoResign":         d.object(forKey: "autoResign") as? Bool ?? true,
            "checkIntervalMin":   intervalMin,
            "resignThreshold":    d.object(forKey: "resignThreshold") as? Int ?? 2,
            // daemon 的 s_bypassEnabled() 会按 CFPreferences → 本 plist → 容器偏好 三级回退，
            // 这里同步一份，保证 RootHide 下 cfprefsd 跨 namespace 读不到时仍能生效。
            "bypassFreeAppLimit": d.object(forKey: "bypassFreeAppLimit") as? Bool ?? false,
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
