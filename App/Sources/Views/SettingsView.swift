import SwiftUI
import UIKit
import Darwin

// MARK: - 设置页面

struct SettingsView: View {
    @AppStorage("autoResign") private var autoResign: Bool = true
    @AppStorage("resignThreshold") private var resignThreshold: Int = 2
    // checkIntervalMin: 检查间隔，单位分钟，默认 120（2小时），最少 1 分钟
    @AppStorage("checkIntervalMin") private var checkIntervalMin: Int = 120

    // 免费账号「同一设备最多 3 个自签应用」限制绕过。
    // 键名必须与 repro-signingd.m 的 s_bypassEnabled() 读取的键一致。
    @AppStorage("bypassFreeAppLimit") private var bypassFreeAppLimit: Bool = false

    // 通知开关。键名必须与 RPVNotificationManager.h 里的常量一致。
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("notificationsDebug") private var notificationsDebug: Bool = false
    /// 系统授权状态描述，onAppear 时刷新
    @State private var notifyStatusText: String = "检查中…"
    @State private var notifyNeedsSystemSettings = false

    /// 从分钟数拆出的小时和分钟（纯展示用，不绑定 @AppStorage）
    @State private var intervalHours: Int = 2
    @State private var intervalMins: Int = 0
    @State private var showIntervalPicker: Bool = false

    /// 日志文件大小（onAppear 时更新）
    @State private var logFileSize: String = "—"
    @State private var showingClearLogAlert = false
    @State private var needsConfigSync = false

    @ObservedObject private var account = BridgeClient.shared

    @State private var appleID: String = ""
    @State private var password: String = ""
    @State private var isLoggingIn = false
    @State private var loginMessage: String?
    @State private var loginSucceeded = false

    @State private var availableTeams: [DeveloperTeam] = []
    @State private var showingTeamSheet = false

    @State private var showingRespringAlert = false
    @State private var showingSignOutAlert = false
    @State private var showingCertificates = false
    @State private var zsignPath: String?

    var body: some View {
        NavigationView {
            Form {
                accountSection
                autoResignSection
                freeLimitSection
                notificationSection
                signingBackendSection
                systemSection
                aboutSection
            }
            .navigationTitle("设置")
            .onAppear {
                refreshEnvironment()
                intervalHours = checkIntervalMin / 60
                intervalMins  = checkIntervalMin % 60
                refreshLogFileSize()
                refreshNotificationStatus()
                needsConfigSync = false
            }
            .onChange(of: autoResign) { _ in needsConfigSync = true }
            .onChange(of: checkIntervalMin) { _ in needsConfigSync = true }
            .onChange(of: resignThreshold) { _ in needsConfigSync = true }
            .onDisappear {
                if needsConfigSync {
                    NotificationCenter.default.post(name: NSNotification.Name("com.reprovision.signingd-config-updated"), object: nil)
                }
            }
            .alert("确认重启 SpringBoard", isPresented: $showingRespringAlert) {
                Button("取消", role: .cancel) {}
                Button("重启", role: .destructive) { performRespring() }
            } message: {
                Text("这将关闭所有应用并重新加载 SpringBoard。正在运行的进程将会被终止。")
            }
            .alert("退出登录", isPresented: $showingSignOutAlert) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    account.signOut()
                    loginMessage = nil
                    loginSucceeded = false
                    LogManager.shared.info("已退出 Apple ID", source: "SettingsView")
                }
            } message: {
                Text("退出后需要重新登录才能继续重签名。")
            }
            .alert("清理续签日志", isPresented: $showingClearLogAlert) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) { clearDaemonLog() }
            } message: {
                Text("确定要清空 reprorefresh_at.log 吗？此操作不可撤销。")
            }
            .sheet(isPresented: $showingTeamSheet) { teamSheet }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 账号

    @ViewBuilder
    private var accountSection: some View {
        Section("Apple ID 账户") {
            if account.isSignedIn {
                HStack {
                    Text("账号")
                    Spacer()
                    Text(account.username ?? "-")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Text("Team ID")
                    Spacer()
                    Text(account.teamID ?? "-")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Button("退出登录", role: .destructive) {
                    showingSignOutAlert = true
                }
            } else {
                TextField("Apple ID", text: $appleID)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("密码", text: $password)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                if isLoggingIn {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("正在登录…").foregroundColor(.secondary)
                    }
                }

                if let message = loginMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundColor(loginSucceeded ? .green : .red)
                }

                Button(isLoggingIn ? "登录中…" : "登录") {
                    performLogin()
                }
                .disabled(isLoggingIn || appleID.isEmpty || password.isEmpty)
            }
        }
    }

    // MARK: - 自动重签

    private var autoResignSection: some View {
        Section {
            Toggle("启用自动重签", isOn: $autoResign)
            Stepper("提前 \(resignThreshold) 天重签", value: $resignThreshold, in: 1...7)

            // 展开式间隔选择
            Button {
                withAnimation { showIntervalPicker.toggle() }
            } label: {
                HStack {
                    Text("检查间隔")
                    Spacer()
                    Text(formatInterval(hours: intervalHours, mins: intervalMins))
                        .foregroundColor(.secondary)
                    Image(systemName: showIntervalPicker ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if showIntervalPicker {
                VStack(spacing: 0) {
                    HStack {
                        Picker("小时", selection: $intervalHours) {
                            ForEach(0...23, id: \.self) { h in
                                Text("\(h) 小时").tag(h)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        Picker("分钟", selection: $intervalMins) {
                            ForEach(0...59, id: \.self) { m in
                                Text("\(m) 分钟").tag(m)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                    .frame(height: 160)

                    Button("确定") {
                        let totalMin = max(1, intervalHours * 60 + intervalMins)
                        checkIntervalMin = totalMin
                        intervalHours = totalMin / 60
                        intervalMins  = totalMin % 60
                        withAnimation { showIntervalPicker = false }
                        LogManager.shared.info("检查间隔已更新: \(totalMin) 分钟", source: "SettingsView")
                    }
                    .padding(.vertical, 8)
                }
            }
        } header: {
            Text("自动重签")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("repro-signingd 守护进程以 root 权限定时检查并触发续签。全部日志写入 <jbroot>/var/log/reprorefresh_at.log（daemon + App 共同维护）。")

                HStack {
                    Text("日志大小：")
                    Text(logFileSize)
                        .fontWeight(.medium)
                    Spacer()
                    Button("清理日志") {
                        showingClearLogAlert = true
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 免费账号应用数量限制

    private var freeLimitSection: some View {
        Section {
            Toggle("自动绕过 3 应用限制", isOn: $bypassFreeAppLimit)
                .onChange(of: bypassFreeAppLimit) { newValue in
                    needsConfigSync = true
                    LogManager.shared.info("3 应用限制绕过已\(newValue ? "开启" : "关闭")", source: "SettingsView")
                    if newValue {
                        // 立刻对现有已安装应用执行一次，不必等下次签名
                        RPVSigningdNotify.notifyBypass3AppRequest()
                    }
                }
        } header: {
            Text("免费账号限制")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("⚠️ 这只解除「设备同时 3 个」这一条限制。Apple 服务端的「每 7 天最多注册 10 个 App ID」是另一套机制，无法绕过。")
                    .foregroundColor(.orange)
                Text("sudo /usr/libexec/repro-signingd --bypass-3app")
                    .font(.caption)
            }
        }
    }

    // MARK: - 通知

    private var notificationSection: some View {
        Section {
            Toggle("重签通知", isOn: $notificationsEnabled)
            Toggle("详细通知", isOn: $notificationsDebug)
                .disabled(!notificationsEnabled)

            HStack {
                Text("系统权限")
                Spacer()
                Text(notifyStatusText)
                    .foregroundColor(notifyNeedsSystemSettings ? .red : .secondary)
            }

            if notifyNeedsSystemSettings {
                Button("前往系统设置开启") {
                    openSystemNotificationSettings()
                }
            }
        } header: {
            Text("通知")
        } footer: {
            Text("「重签通知」在每个应用签名完成或失败时推送横幅；「详细通知」会额外播报开始签名、写入签名、重建 IPA、安装等中间步骤，仅排障时建议开启。")
        }
    }

    private func refreshNotificationStatus() {
        RPVNotificationManager.sharedInstance().fetchAuthorizationStatus { status in
            // 取值同 UNAuthorizationStatus
            switch status {
            case 0:
                notifyStatusText = "未申请"
                notifyNeedsSystemSettings = false
            case 1:
                notifyStatusText = "已拒绝"
                notifyNeedsSystemSettings = true
            case 2:
                notifyStatusText = "已授权"
                notifyNeedsSystemSettings = false
            case 3:
                notifyStatusText = "临时授权"
                notifyNeedsSystemSettings = false
            case 4:
                notifyStatusText = "仅定时摘要"
                notifyNeedsSystemSettings = true
            default:
                notifyStatusText = "未知"
                notifyNeedsSystemSettings = false
            }
        }
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func formatInterval(hours: Int, mins: Int) -> String {
        if hours == 0 { return "\(mins) 分钟" }
        if mins == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(mins) 分钟"
    }

    // MARK: - 签名后端

    private var signingBackendSection: some View {
        Section {
            HStack {
                Text("签名工具")
                Spacer()
                Text("zsign")
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .top) {
                Text("可执行文件")
                Spacer()
                Text(zsignPath ?? "未找到")
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(zsignPath == nil ? .red : .secondary)
            }
        } header: {
            Text("签名后端")
        } footer: {
            Text(zsignPath == nil
                 ? "未检测到 zsign，重签会失败。请确认 ReSign 是通过 Sileo/Zebra 安装的（deb 会一并安装 zsign）。"
                 : "zsign 以独立进程运行，签名结果与原版 ReProvision 一致。")
        }
    }

    // MARK: - 系统操作

    private var systemSection: some View {
        Section {
            NavigationLink(destination: AppIDsView()) {
                HStack {
                    Image(systemName: "number")
                    Text("查询已注册 AppID")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(!account.isSignedIn)

            NavigationLink(destination: CertificatesView()) {
                HStack {
                    Image(systemName: "lock.shield")
                    Text("管理证书")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(!account.isSignedIn)

            Button {
                showingRespringAlert = true
            } label: {
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
        } header: {
            Text("系统操作")
        } footer: {
            Text("证书管理可查看和撤销 Apple 开发者账号下的签名证书。免费账号最多 2 个活跃证书，超出后签名会失败。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    .foregroundColor(.secondary)
            }
            if let url = URL(string: "https://www.coolapk.com/u/32152768") {
                Link("作者主页", destination: url)
            }
        }
    }

    // MARK: - Team 选择弹窗

    private var teamSheet: some View {
        NavigationView {
            List(availableTeams) { team in
                Button {
                    selectTeam(team)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(team.name)
                            .foregroundColor(.primary)
                        HStack(spacing: 6) {
                            Text(team.teamID)
                                .font(.system(.caption, design: .monospaced))
                            if let membership = team.membership {
                                Text("·").font(.caption)
                                Text(membership).font(.caption)
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("选择开发者 Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showingTeamSheet = false
                        isLoggingIn = false
                    }
                }
            }
        }
    }

    // MARK: - 动作

    private func performLogin() {
        isLoggingIn = true
        loginMessage = nil
        loginSucceeded = false

        account.login(appleID: appleID, password: password) { step in
            handleLoginStep(step)
        }
    }

    private func handleLoginStep(_ step: BridgeClient.LoginStep) {
        switch step {
        case .chooseTeam(let teams):
            if teams.count == 1, let only = teams.first {
                selectTeam(only)
            } else if teams.isEmpty {
                isLoggingIn = false
                loginMessage = "该 Apple ID 下没有可用的开发者 Team"
                LogManager.shared.error("登录成功但没有可用 Team", source: "SettingsView")
            } else {
                availableTeams = teams
                showingTeamSheet = true
            }

        case .needsTwoFactor:
            loginMessage = "该 Apple ID 开启了两步验证，请在系统弹出的验证界面完成确认…"
            loginSucceeded = false
            LogManager.shared.info("账号需要两步验证，拉起系统验证界面", source: "SettingsView")
            account.continueTwoFactor { next in
                if case .needsTwoFactor = next {
                    isLoggingIn = false
                    loginMessage = "两步验证未完成，请重试"
                    return
                }
                handleLoginStep(next)
            }

        case .failed(let reason):
            isLoggingIn = false
            loginSucceeded = false
            loginMessage = "登录失败: \(reason)"
            LogManager.shared.error("Apple ID 登录失败: \(reason)", source: "SettingsView")
        }
    }

    private func selectTeam(_ team: DeveloperTeam) {
        showingTeamSheet = false
        isLoggingIn = true

        account.selectTeam(team) { result in
            isLoggingIn = false
            switch result {
            case .success:
                loginSucceeded = true
                loginMessage = "登录成功"
                password = ""
                LogManager.shared.info("Apple ID 登录成功，Team = \(team.teamID)", source: "SettingsView")
            case .failure(let error):
                loginSucceeded = false
                loginMessage = "注册设备失败: \(error.localizedDescription)"
                LogManager.shared.error("注册设备失败: \(error.localizedDescription)", source: "SettingsView")
            }
        }
    }

    private func refreshEnvironment() {
        account.refreshAccountState()
        BridgeClient.shared.fetchEnvironment { snapshot in
            zsignPath = snapshot.zsignPath
        }
    }

    private func refreshLogFileSize() {
        logFileSize = DaemonLogSize(DaemonLogDefaultPath())
    }

    private func clearDaemonLog() {
        DaemonLogClear(DaemonLogDefaultPath())
        refreshLogFileSize()
    }

    private func performRespring() {
        let result = BridgeClient.shared.respring()
        if result {
            LogManager.shared.info("已发送 SIGTERM 给 SpringBoard（sysctl 枚举方案）", source: "SettingsView")
            exit(0)
        } else {
            LogManager.shared.error("重启 SpringBoard 失败：未找到 SpringBoard 进程", source: "SettingsView")
        }
    }
}
