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

    private static let ipcDir = "/var/mobile/Library/Resign"

    /// v1.1.148: 提前重签天数上限（与 daemon 的 kMaxThresholdDays 一致）= 最多提前 6 天。
    /// 免费 profile 有效期 7 天，7 = 永远在窗口内 → 冷却一过就全量重签。
    private static let maxThresholdDays = 6

    /// v1.1.184: 检测间隔上限（与 daemon 的 kMaxCheckIntervalHours 一致）= 最多 12 小时。
    private static let maxCheckIntervalHours = 12

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

        // 自动续签统一由 daemon 定时触发（后台拉起执行），前台打开不再触发重签。
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

        // 🔴 v2.1.4：每次启动（含 daemon 后台拉起）都刷新 Anisette 缓存。
        // daemon（root）进程的 AKAppleIDSession 缺 X-Apple-I-MD → Apple 拒签
        // （"No Team ID present!"）。App 进程生成的 Anisette 完整，缓存在共享 IPC
        // 目录供 daemon 复用。v2.1.3 只在 applicationDidBecomeActive 刷，覆盖不到
        // 后台拉起等场景 → 改到 setupCommon（每次启动必跑）。
        RPVSigningdNotify.refreshAnisetteCache()

        // 🔴 v2.1.15：daemon 签名完成后由 App 进程执行安装（RootHide 下 daemon
        // 无 UI 会话调 LSApplicationWorkspace 被 installd 拒，App 进程能装）。
        // daemon 会写 pending-install 标记并后台拉起本 App；这里每次启动检查并执行。
        RPVSigningdNotify.processPendingInstallIfNeeded()

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
            forName: NSNotification.Name("cn.analy.resign.signingd-config-updated"),
            object: nil, queue: .main) { [weak self] _ in self?.syncConfigSilent() }

        // 🔴 v1.1.165：daemon 的【进程内触发路径】。App 进程已存在时（用户打开过挂后台），
        // daemon 的 SBS 后台唤醒不重走 didFinishLaunching → isDaemonTriggeredResign 永不
        // 执行 → 续签静默失败（用户实测「触发了刷新但没自动续签」）。RPVSigningdNotify
        // 收到 daemon 的 schedule-resign 信号并确认 trigger 新鲜后发本通知，这里响应并执行
        // 静默续签（与冷启动路径共用 startDaemonResign，内部有 24h 冷却 + banner）。
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("cn.analy.resign.daemon-request-resign"),
            object: nil, queue: .main) { [weak self] _ in
            self?.handleDaemonResignRequest()
        }
    }

    /// v1.1.165：daemon 请求续签的进程内入口（App 已运行时）。
    /// 冷启动路径（isDaemonTriggeredResign）已消费 trigger 后本入口不会被触发
    /// （RPVSigningdNotify 检查 trigger 新鲜度），天然防双触发。
    private func handleDaemonResignRequest() {
        // 防重入：banner 显示中 = 已有续签在跑（冷启动拉起 / 用户手动重签）
        guard !ResignProgress.shared.isResigning else {
            LogManager.shared.info("已有续签进行中，忽略 daemon 的重复触发请求", source: "AppDelegate")
            return
        }
        LogManager.shared.info("收到 daemon 进程内续签请求（App 已在运行）→ 执行静默续签", source: "AppDelegate")
        startDaemonResign()
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
        // 🔴 v1.1.184：续签后 24 小时冷却已删除（用户要求）。
        // 检测频率改由用户可配的「检测间隔」（1~12 小时）在 daemon 侧节流
        // （s_fire 里按 signingd-check-state.plist 的 lastCheckTime 判断本轮干不干活），
        // App 侧不再重复设卡。窗口内才会重签的保证来自「严格小于」阈值判定
        // （剩余有效期 < 提前重签天数才进窗口），无需冷却兜底。

        // 提示横幅：用户中途打开 App 时，明确告知这是 daemon 后台续签、无需操作
        ResignProgress.shared.show(
            title: "ReSign 后台自动续签",
            message: ""
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
            // v1.1.148: clamp 提前重签天数上限（防旧版本残留的 7 或手动改过的 UserDefaults）
            let threshold = min(d.object(forKey: "resignThreshold") as? Int ?? 2, Self.maxThresholdDays)

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
                LogManager.shared.info("══════ 静默续签结束（未登录），已回报 daemon ══════", source: "AppDelegate")
                DaemonLogStop()
                // 🔴 v1.1.188：提前中止路径必须 hide 横幅（同未联网分支的修复）
                ResignProgress.shared.hide()
                // 🔴 v1.1.163：退出前二次确认仍处于后台（用户可能已在重试期间打开 App）。
                Thread.sleep(forTimeInterval: 0.5)
                if UIApplication.shared.applicationState == .background {
                    exit(0)
                }
                return
            }

            // 后台任务保活：确保与 Apple 服务器的续签网络请求不会被系统挂起。
            // Apple 文档要求 beginBackgroundTask 在【主线程】调用，故回主线程开启。
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // v1.1.162：expirationHandler 里 endBackgroundTask——系统到期强制
                // 结束时若不配对 end，会泄漏后台断言并刷「Blocking the main thread」
                // 警告；到期 = 续签已超时，App 侧兜底逻辑（App 自行写冷却）不受影响。
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "repro-daemon-resign") {
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
                LogManager.shared.info("阈值 \(threshold) 天 → 开始扫描并重签到期应用", source: "AppDelegate")

                // 签名前自动撤销旧证书（与前台 SigningViewModel 共享同一套逻辑），
                // 防止 "You already have a current Development certificate or a pending certificate request" 错误。
                // v1.1.86 前此处直接调 resignAllExpiring 漏掉了撤销步骤 → 后台续签 CSR 冲突。
                BridgeClient.shared.autoRevokeBeforeSigning { [weak self] revokeError in
                    guard let self = self else { return }
                    // v1.1.177：签名前自动撤销因网络断开失败 → 立即停止续签，
                    // 不得误判为「所有应用剩余有效期充足」（表现为设置无描述文件、App 0xe8008015）。
                    if let err = revokeError, self.isConnectivityError(err) {
                        LogManager.shared.warning("未连接到互联网，停止续签操作", source: "AppDelegate")
                        self.writeResignReport(result: "failed", detail: "未连接到互联网、停止续签操作", elapsed: 0)
                        RPVSigningdNotify.notifySigningComplete()
                        LogManager.shared.info("══════ 续签结束（未联网已停止），已回报 daemon ══════", source: "AppDelegate")
                        DaemonLogStop()
                        // 🔴 v1.1.188：提前中止路径必须 hide 横幅——旧版漏调，App 在前台时
                        // 「ReSign 后台自动续签」横幅永远挂在界面最上方（用户实锤）。
                        ResignProgress.shared.hide()
                        Thread.sleep(forTimeInterval: 0.5)
                        if UIApplication.shared.applicationState == .background { exit(0) }
                        return
                    }
                    BridgeClient.shared.resignAllExpiring(thresholdDays: threshold) { [weak self] result in
                        guard let self = self else { return }
                        let elapsed = Date().timeIntervalSince(started)
                        self.handleResignCompletion(result: result, elapsed: elapsed)
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                    }
                }
            }
        }
    }

    /// 续签完成统一收尾：写报告、回报 daemon、发通知、按需退出。
    /// 自动续签只由 daemon 后台拉起触发（isDaemon 恒为 true 的旧参数已移除）。
    private func handleResignCompletion(result: Result<Void, Error>,
                                        elapsed: TimeInterval) {
        let success: Bool
        let errorText: String

        switch result {
        case .success:
            success = true
            errorText = ""
            LogManager.shared.info(String(format: "续签完成，耗时 %.1f 秒", elapsed), source: "AppDelegate")
            writeResignReport(result: "success",
                             detail: "阈值内的到期应用已处理完毕",
                             elapsed: elapsed, trigger: "daemon-background-launch")
        case .failure(let e):
            // v1.1.165：RPVErrorNoSigningRequired == 101（Vendor/ReProvision/Application
            // Database/RPVErrors.h）不是失败——是所有应用剩余有效期都充足、无需重签。
            // 旧版一律记 failed + 透传英文原文，用户误以为「续签失败」。
            let isNoSigningRequired = (e as NSError).code == 101
            success = isNoSigningRequired   // 视为成功（本次无需动作，冷却照常）
            errorText = isNoSigningRequired ? "所有应用剩余有效期充足，无需重签" : e.localizedDescription
            LogManager.shared.info(isNoSigningRequired
                                   ? "续签检查完成：无需重签（所有应用剩余有效期充足）"
                                   : "续签失败: \(errorText)",
                                   source: "AppDelegate")
            writeResignReport(result: isNoSigningRequired ? "skipped" : "failed",
                             detail: errorText, elapsed: elapsed, trigger: "daemon-background-launch")
        }

        sendResignNotification(success: success, errorText: errorText)

        // 🔴 v1.1.155 双保险：daemon 已改「短命模式」（每 5 分钟拉起，等 App 完成或 5 分钟
        // 超时即退出）。若 daemon 超时先退，App 的 signing-complete notify 会无人接收 →
        // lastResignTime 不被更新 → 下次拉起冷却误判。因此 App 完成续签后自己写入冷却基准文件。
        // （daemon 收到 notify 后会以完整统计覆盖此文件，两版 key 兼容。）
        let lastResult: [String: Any] = [
            "lastResignTime": Date().timeIntervalSince1970,
            "status": success ? "success" : "failed",
            "detail": errorText,
            "appReport": [
                "result": success ? "success" : "failed",
                "elapsed": elapsed,
                "detail": errorText.isEmpty ? "阈值内的到期应用已处理完毕" : errorText,
                "trigger": "daemon-background-launch",
            ],
        ]
        (lastResult as NSDictionary).write(toFile: "\(Self.ipcDir)/last-resign-result.plist", atomically: true)

        RPVSigningdNotify.notifySigningComplete()
        LogManager.shared.info("══════ 续签结束，已回报 daemon ══════", source: "AppDelegate")
        DaemonLogStop()
        ResignProgress.shared.hide()

        // daemon 后台拉起且用户全程未打开 → 干净退出，释放 daemon 侧的 BKS 断言
        if UIApplication.shared.applicationState == .background {
            // 🔴 v1.1.163 修复：sleep + exit 移到后台线程，但 exit 前必须**二次确认
            // 仍是后台**。v1.1.162 只移了线程、没加二次确认 → 用户在 1.5s 窗口内
            // 打开 App 后，exit(0) 照样执行，把**前台进程**直接杀掉 = 用户看到的
            // 「打开 App → 秒退/闪退」。二次确认后只有确认仍在后台才退出；
            // 用户已打开则保留进程正常使用。
            DispatchQueue.global(qos: .utility).async {
                Thread.sleep(forTimeInterval: 1.5)
                if UIApplication.shared.applicationState == .background {
                    exit(0)
                }
            }
            return
        }
    }

    /// 判断错误是否为「网络断开 / 无法连接」类错误（NSURLError 域的连通性错误）。
    private func isConnectivityError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                 NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return true
            default:
                break
            }
        }
        let desc = ns.localizedDescription
        if desc.contains("似乎已断开") || desc.contains("not connected") ||
           desc.contains("offline") || desc.contains("Could not connect") {
            return true
        }
        return false
    }

    /// 发送续签完成 / 失败通知
    private func sendResignNotification(success: Bool, errorText: String) {
        let title = success ? "ReSign 后台续签完成" : "ReSign 后台续签失败"
        let body = success ? "后台自动续签已成功完成" : (errorText.isEmpty ? "未知错误" : errorText)
        RPVNotificationManager.sharedInstance().sendNotification(title: title, body: body, isDebug: false, identifier: nil)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 再迁移一次（幂等）。主路径已在 setupCommon + 「保护数据可用」通知里自动完成，
        // 这里只是前台激活时的额外保险。
        RPVBridge.migrateKeychainAccessibility()

        // 🔴 v2.1.3：刷新 Anisette 缓存（daemon 签名用）。
        // daemon（root）进程的 AKAppleIDSession 缺 X-Apple-I-MD → Apple 拒绝签名请求
        // （"No Team ID present!"）。App 进程生成的 Anisette 完整，缓存在共享 IPC 目录
        // 供 daemon 复用。每次进前台刷新（Anisette 有时效，且用户可能换了 Apple ID）。
        RPVSigningdNotify.refreshAnisetteCache()

        // 🔴 v1.1.189：通知权限申请补到前台激活后调用——
        // 用户实锤「首次安装进 App 不弹权限框，杀后台重开才有」：didFinishLaunching 里
        // 同步调 requestAuthorization 时系统授权 UI 尚未就绪（RootHide 下尤其明显），
        // 弹窗被吞。becomeActive 时 UI 已就绪，弹窗可靠；
        // 已授权 / 已拒绝状态下 requestAuthorization 直接返回不再弹，无副作用。
        RPVNotificationManager.sharedInstance().registerToSendNotifications()

        // 🔴 v1.1.144：前台激活不再触发自动重签。
        // 历史设计「进入前台就重签」（applicationDidBecomeActive → tryAutoResign →
        // doAutoResign → resignAllExpiring）每次回到前台都跑一次完整 zsign 重签管线，
        // 反复前后台切换会造成内存暴涨（实测 Jetsam 中 repro-signingd 曾达 3.6GB），
        // 整机内存被压垮后 roothide 的 XPC 拦截在前后台切换时集体 fault
        // （EXC_GUARD/LIBXPC/XPC_EXIT_REASON_FAULT 杀主线程 → 冷启动即闪退）。
        // 自动续签现统一由 daemon 定时触发（后台拉起静默续签），此处不再代跑。
    }

    // MARK: - daemon 配置同步

    func syncSigningdConfig() { _syncConfig() }
    func syncConfigSilent()   { _syncConfig() }

    private func _syncConfig() {
        let d = UserDefaults.standard
        let config: [String: Any] = [
            "autoResign":         d.object(forKey: "autoResign") as? Bool ?? true,
            "resignThreshold":    d.object(forKey: "resignThreshold") as? Int ?? 2,
            // v1.1.184: 检测间隔（小时）。key 与设置页 @AppStorage("resignCheckInterval") 一致，
            // daemon 的 s_parseCfg 会 clamp 到 1...12。
            "resignCheckInterval": d.object(forKey: "resignCheckInterval") as? Int ?? 1,
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
        LogManager.shared.info("配置已同步到 plist: autoResign=\(config["autoResign"] ?? "nil")", source: "AppDelegate")
    }

    private func setupSigningdNotify() { let _ = RPVSigningdNotify.shared }
}
