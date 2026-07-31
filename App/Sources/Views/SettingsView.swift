import SwiftUI

// MARK: - 设置页面

struct SettingsView: View {
    @AppStorage("signMethod") private var signMethod: SignMethod = .zsign
    @AppStorage("autoResign") private var autoResign: Bool = true
    @AppStorage("resignThreshold") private var resignThreshold: Int = 2
    @AppStorage("checkInterval") private var checkInterval: Int = 6
    @AppStorage("proxyURL") private var proxyURL: String = ""
    @AppStorage("networkTimeout") private var networkTimeout: Int = 60

    @State private var appleID: String = ""
    @State private var password: String = ""
    @State private var isLoggingIn = false
    @State private var loginMessage: String?
    @State private var showingRespringAlert = false
    @State private var anisetteReady: Bool = false
    @State private var validTokenCount: Int = 0

    var body: some View {
        NavigationView {
            Form {
                // MARK: 签名方式
                Section("签名方式") {
                    Picker("签名工具", selection: $signMethod) {
                        Text("zsign (推荐)").tag(SignMethod.zsign)
                        Text("ldid (传统)").tag(SignMethod.ldid)
                    }
                    .pickerStyle(.segmented)
                    Text(signMethod == .zsign ?
                         "使用 zsign 外部进程签名，兼容性更好" :
                         "使用 ldid 内嵌签名，原版方式")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: Apple ID 账户
                Section("Apple ID 账户") {
                    TextField("Apple ID", text: $appleID)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("密码", text: $password)
                        .textContentType(.password)

                    if isLoggingIn {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在登录...")
                                .foregroundColor(.secondary)
                        }
                    }

                    if let message = loginMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundColor(message.contains("成功") ? .green : .red)
                    }

                    Button(isLoggingIn ? "登录中..." : "登录") {
                        performLogin()
                    }
                    .disabled(isLoggingIn || appleID.isEmpty || password.isEmpty)
                }

                // MARK: 自动重签
                Section("自动重签") {
                    Toggle("启用自动重签", isOn: $autoResign)
                    Stepper("提前 \(resignThreshold) 天重签",
                            value: $resignThreshold,
                            in: 1...7)
                    Stepper("每 \(checkInterval) 小时检查",
                            value: $checkInterval,
                            in: 1...24)
                }

                // MARK: Anisette 与 Token 缓存
                Section("高级选项") {
                    HStack {
                        Text("Anisette 本地生成")
                        Spacer()
                        Text(anisetteReady ? "已启用" : "未就绪")
                            .foregroundColor(anisetteReady ? .green : .orange)
                    }
                    HStack {
                        Text("Token 缓存")
                        Spacer()
                        Text("\(validTokenCount) 个有效")
                            .foregroundColor(.blue)
                    }
                }

                // MARK: 网络
                Section("网络设置") {
                    TextField("代理地址 (可选)", text: $proxyURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Stepper("超时: \(networkTimeout) 秒",
                            value: $networkTimeout,
                            in: 10...300,
                            step: 10)
                }

                // MARK: 系统操作
                Section("系统操作") {
                    Button(action: performRespring) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("重启 SpringBoard")
                            Spacer()
                            Text("Respring")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.red)
                }

                // MARK: 关于
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundColor(.secondary)
                    }
                    if let url = URL(string: "https://github.com/AmorCool/RePro") {
                        Link("开源项目", destination: url)
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear { refreshStatus() }
            .alert("确认重启 SpringBoard", isPresented: $showingRespringAlert) {
                Button("取消", role: .cancel) {}
                Button("重启", role: .destructive) {
                    performRespringNow()
                }
            } message: {
                Text("这将关闭所有应用并重新加载 SpringBoard。正在运行的进程将会被终止。")
            }
        }
    }

    private func performLogin() {
        isLoggingIn = true
        loginMessage = nil

        DaemonClient.shared.login(appleID: appleID, password: password) { result in
            DispatchQueue.main.async {
                self.isLoggingIn = false
                switch result {
                case .success:
                    self.loginMessage = "登录成功"
                    LogManager.shared.info("Apple ID 登录成功", source: "SettingsView")
                case .failure(let error):
                    self.loginMessage = "登录失败: \(error.localizedDescription)"
                    LogManager.shared.error("Apple ID 登录失败: \(error)", source: "SettingsView")
                }
            }
        }
    }

    private func performRespring() {
        showingRespringAlert = true
    }

    private func refreshStatus() {
        DaemonClient.shared.getHealth { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let status):
                    self.anisetteReady = status.anisetteReady
                    self.validTokenCount = status.validTokenCount
                case .failure:
                    self.anisetteReady = false
                    self.validTokenCount = 0
                }
            }
        }
    }

    private func performRespringNow() {
        // 先尝试通过 daemon 执行（推荐方式）
        DaemonClient.shared.respring { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    LogManager.shared.info("SpringBoard 重启中...", source: "SettingsView")
                case .failure:
                    // daemon 不可用时，直接调用 killall（降级方案）
                    LogManager.shared.info("daemon 不可用，使用降级方案重启 SpringBoard", source: "SettingsView")
                    self.fallbackRespring()
                }
            }
        }
    }

    /// 降级方案：不依赖 daemon，直接执行 killall SpringBoard
    private func fallbackRespring() {
        let killallPath = "/usr/bin/killall"
        let processName = "SpringBoard"

        // 使用 NSTask/Process 执行（iOS 15+ 可用）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: killallPath)
        task.arguments = [processName]

        do {
            try task.run()
            LogManager.shared.info("已发送 killall SpringBoard 命令", source: "SettingsView")
        } catch {
            // 最后的兜底：尝试 launchctl kickstart
            let fallbackTask = Process()
            fallbackTask.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            fallbackTask.arguments = ["kickstart", "gui/\(getuid())/com.apple.SpringBoard"]
            do {
                try fallbackTask.run()
                LogManager.shared.info("使用 launchctl kickstart 重启 SpringBoard", source: "SettingsView")
            } catch {
                self.loginMessage = "重启失败: \(error.localizedDescription)"
                LogManager.shared.error("所有重启方案均失败: \(error)", source: "SettingsView")
            }
        }
    }
}

// MARK: - 签名方式枚举

enum SignMethod: String, CaseIterable, Identifiable {
    case ldid
    case zsign

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ldid: return "ldid"
        case .zsign: return "zsign"
        }
    }
}
