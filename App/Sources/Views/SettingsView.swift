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
                    SecureField("Apple ID", text: $appleID)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("密码", text: $password)
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
                        Text("已启用")
                            .foregroundColor(.green)
                    }
                    HStack {
                        Text("Token 缓存")
                        Spacer()
                        Text("查看详情")
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
