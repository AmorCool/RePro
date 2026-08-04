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

    // v1.1.128：低电量强制续签。键名必须与 repro-signingd.m 的 s_parseCfg() 读取的键一致。
    @AppStorage("forceResignLowPower") private var forceResignLowPower: Bool = false
    /// 下次自动续签时间（signingd 持久化在 signingd-state.plist 的 nextFireDate）。
    /// v1.1.129：详细 24 小时制 yyyy-MM-dd HH:mm:ss + 副行剩余倒计时，每 30 秒自动刷新
    @State private var nextResignTimeText: String = "—"
    @State private var nextResignCountdownText: String = "等待 daemon 调度…"

    /// 越狱联网修复（国行蜂窝/WiFi 权限重置）：执行中标记 + 结果弹窗
    @State private var isFixingCellular: Bool = false
    @State private var showFixCellularAlert: Bool = false
    @State private var fixCellularMessage: String = ""

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

    /// 小黑屋存储（只读用于显示数量，清空按钮直接操作它）
    @ObservedObject private var blacklist = BlacklistStore.shared

    @State private var appleID: String = BridgeClient.shared.username ?? ""
    @State private var password: String = BridgeClient.shared.savedPassword ?? ""
    @State private var isLoggingIn = false
    /// 登录后：账户 / TeamID 是否明文显示（默认隐藏，点眼睛切换）
    @State private var showAccount = false
    @State private var showTeamID = false
    /// 登录前：密码框是否明文显示
    @State private var showPwdBefore = false
    /// 登录前：Apple ID 框是否明文显示（默认显示，点眼睛可掩码）
    @State private var showAppleIDBefore = true
    @State private var loginMessage: String?
    @State private var loginSucceeded = false
    /// 登录超时看门狗：网络卡住时自动解除“登录中”状态，避免界面永久“卡住”（不自动重试，仅恢复可点击）。
    @State private var loginAttempt: Int = 0
    @State private var loginTimeoutWorkItem: DispatchWorkItem?
    private let loginTimeout: TimeInterval = 30

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
                networkFixSection
                freeLimitSection
                blacklistSection
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
            .onChange(of: forceResignLowPower) { _ in needsConfigSync = true }
            .onChange(of: account.isSignedIn) { signedIn in
                // 退出登录后，重置登录前输入框（带已保存凭据预填）与显示开关
                if !signedIn {
                    appleID = account.username ?? ""
                    password = account.savedPassword ?? ""
                    showAccount = false
                    showTeamID = false
                    showPwdBefore = false
                    showAppleIDBefore = true
                }
            }
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
            .alert("修复越狱联网问题", isPresented: $showFixCellularAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(fixCellularMessage)
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
                // 账号：默认掩码，点眼睛明文
                HStack {
                    Text("账号")
                    Spacer()
                    Text(showAccount ? (account.username ?? "-") : Self.masked(account.username))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button {
                        showAccount.toggle()
                    } label: {
                        Image(systemName: showAccount ? "eye.slash.fill" : "eye.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                // Team ID：默认掩码，点眼睛明文
                HStack {
                    Text("Team ID")
                    Spacer()
                    Text(showTeamID ? (account.teamID ?? "-") : Self.masked(account.teamID))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button {
                        showTeamID.toggle()
                    } label: {
                        Image(systemName: showTeamID ? "eye.slash.fill" : "eye.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                Button("退出登录", role: .destructive) {
                    showingSignOutAlert = true
                }
            } else {
                // 登录前：Apple ID + 密码信息栏（预填已保存凭据，密码默认掩码可点眼睛查看）
                HStack {
                    if showAppleIDBefore {
                        TextField("Apple ID", text: $appleID)
                    } else {
                        SecureField("Apple ID", text: $appleID)
                    }
                    Button {
                        showAppleIDBefore.toggle()
                    } label: {
                        // v1.1.101: 「当前状态语义」——睁眼=明文（能看见）、闭眼=掩码（被遮住），
                        // 与用户直觉一致。密码框与登录后账号行保持 iOS 系统标准（点击后状态语义）不动。
                        Image(systemName: showAppleIDBefore ? "eye.fill" : "eye.slash.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                HStack {
                    if showPwdBefore {
                        TextField("密码", text: $password)
                    } else {
                        SecureField("密码", text: $password)
                    }
                    Button {
                        showPwdBefore.toggle()
                    } label: {
                        // v1.1.102: 与 Apple ID 框统一为「当前状态语义」——
                        // 睁眼=明文（能看见）、闭眼=掩码（被遮住），与用户直觉一致。
                        Image(systemName: showPwdBefore ? "eye.fill" : "eye.slash.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
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

    /// 把敏感字符串掩码：保留首尾、中间用圆点替代，空值返回 "-"
    private static func masked(_ value: String?) -> String {
        guard let s = value, !s.isEmpty else { return "-" }
        if s.count <= 3 { return String(repeating: "•", count: s.count) }
        let head = String(s.prefix(2))
        let tail = String(s.suffix(1))
        return head + String(repeating: "•", count: max(4, s.count - 3)) + tail
    }

    // MARK: - 自动重签

    private var autoResignSection: some View {
        Section {
            Toggle("启用自动重签", isOn: $autoResign)
            Stepper("提前 \(resignThreshold) 天重签", value: $resignThreshold, in: 1...7)

            // v1.1.128：低电量强制续签（原版 ReProvision 默认低电量跳过；开启后不跳过）
            Toggle("低电量强制续签", isOn: $forceResignLowPower)

            // v1.1.128：展示 daemon 持久化的下一次自动续签时间（signingd-state.plist）
            // v1.1.129：详细 24 小时制 + 副行倒计时，.task 每 30 秒自动刷新
            HStack(alignment: .firstTextBaseline) {
                Text("下次自动续签")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(nextResignTimeText)
                        .foregroundColor(.secondary)
                        .onAppear { refreshNextResignTime() }
                    Text(nextResignCountdownText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .task {
                    while !Task.isCancelled {
                        refreshNextResignTime()
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                    }
                }
            }

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
        }
    }

    // MARK: - 越狱联网修复（国行蜂窝/WiFi 权限重置）

    private var networkFixSection: some View {
        Section {
            Button {
                fixCellularTapped()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundColor(.blue)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("修复越狱联网问题")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("越狱后部分插件及应用无法联网（国行「允许使用数据」授权丢失）时，重置所有应用的蜂窝/WiFi 数据策略为「始终允许」，并重启 SpringBoard 生效。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isFixingCellular {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(isFixingCellular)
        } header: {
            Text("联网修复")
        }
    }

    private func fixCellularTapped() {
        guard !isFixingCellular else { return }
        isFixingCellular = true
        RPVBridge.sharedInstance().fixCellularData { success, message in
            isFixingCellular = false
            fixCellularMessage = message ?? (success ? "修复完成" : "修复失败")
            showFixCellularAlert = true
        }
    }

    // MARK: - 小黑屋

    private var blacklistSection: some View {
        Section {
            HStack {
                Text("已拉黑应用")
                Spacer()
                Text("\(blacklist.entries.count) 个")
                    .foregroundColor(.secondary)
            }

            if !blacklist.entries.isEmpty {
                Button("清空小黑屋", role: .destructive) {
                    BlacklistStore.shared.clear()
                    LogManager.shared.info("设置页清空小黑屋", source: "SettingsView")
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("被拉黑的应用会被自动续签 / 批量签名跳过，但手动点击「重签」仍可为其签名。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("小黑屋")
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

    /// 读取 repro-signingd 持久化的下次续签时间（signingd-state.plist 的 nextFireDate）。
    /// v1.1.129：像原版 ReProvision（NSDateFormatter MediumStyle）一样显示完整日期时间，
    /// 但强制 24 小时制（en_US_POSIX locale + 自定义格式，不受系统 12/24 小时设置影响），
    /// 副行显示剩余倒计时；页面可见时每 30 秒自动刷新。
    private func refreshNextResignTime() {
        let statePath = "/var/mobile/Library/RePro/signingd-state.plist"
        guard let d = NSDictionary(contentsOfFile: statePath),
              let next = d["nextFireDate"] as? Date else {
            nextResignTimeText = "—"
            nextResignCountdownText = "等待 daemon 调度…"
            return
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let remain = next.timeIntervalSinceNow
        if remain > 0 {
            nextResignTimeText = fmt.string(from: next)
            let totalSec = Int(remain)
            let mins = totalSec / 60
            let secs = totalSec % 60
            nextResignCountdownText = mins > 0 ? "约 \(mins) 分 \(secs) 秒后触发" : "\(secs) 秒后触发"
        } else {
            // v1.1.130：过期/已触发后不再显示过去的完整时间（易误读），
            // 显示「等待 daemon 调度…」——daemon 启动时会按过期处理并立即续签
            nextResignTimeText = "等待 daemon 调度…"
            nextResignCountdownText = "即将触发…"
        }
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
        attemptLogin()
    }

    /// 一次登录尝试：带超时看门狗。登录失败后解除“登录中”状态、允许手动再次点击登录（按钮不再置灰）。
    /// 每次尝试用 loginAttempt 作为 epoch，旧的迟到回调会被忽略，避免重复处理。
    private func attemptLogin() {
        loginTimeoutWorkItem?.cancel()

        let attempt = loginAttempt + 1
        loginAttempt = attempt

        isLoggingIn = true
        loginSucceeded = false
        loginMessage = nil

        let workItem = DispatchWorkItem { [self] in
            guard self.loginAttempt == attempt else { return }
            self.isLoggingIn = false
            self.loginSucceeded = false
            self.loginMessage = "登录超时（网络可能不稳定），请重试"
            LogManager.shared.error("Apple ID 登录超时（\(Int(self.loginTimeout))s 无响应）", source: "SettingsView")
            self.handleLoginFailure(reason: "timeout")
        }
        loginTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + loginTimeout, execute: workItem)

        account.login(appleID: appleID, password: password) { [self] step in
            guard self.loginAttempt == attempt else { return }
            workItem.cancel()
            self.handleLoginStep(step)
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
            account.continueTwoFactor { [self] next in
                if case .needsTwoFactor = next {
                    self.isLoggingIn = false
                    self.loginMessage = "两步验证未完成，请重试"
                    return
                }
                self.handleLoginStep(next)
            }

        case .failed(let reason):
            handleLoginFailure(reason: reason)
        }
    }

    /// 登录失败统一处理：解除“登录中”状态、展示失败原因，并恢复“登录”按钮可点击
    /// （isLoggingIn=false 使被禁用的按钮恢复，用户可自行再次点击），不自动重试、不弹窗。
    private func handleLoginFailure(reason: String) {
        isLoggingIn = false
        loginSucceeded = false
        loginMessage = "登录失败: \(reason)"
        LogManager.shared.error("Apple ID 登录失败: \(reason)", source: "SettingsView")
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
