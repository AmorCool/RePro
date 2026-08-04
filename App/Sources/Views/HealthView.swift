import SwiftUI

// MARK: - 系统状态页
//
// 这里展示的全部是 App 进程内可以直接探测到的事实（越狱形态、zsign 位置、
// 证书是否随包、账号状态、旁加载应用概况）。没有守护进程，也就没有
// 「守护进程运行状态 / PID / uid」这类需要跨进程询问的指标。

struct HealthView: View {
    @State private var snapshot: EnvironmentSnapshot?
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            List {
                jailbreakSection
                signingSection
                accountSection
                applicationsSection
                actionsSection
            }
            .navigationTitle("系统状态")
            .onAppear { refresh() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 越狱环境

    private var jailbreakSection: some View {
        Section("越狱环境") {
            HealthRow(label: "环境类型",
                      value: snapshot?.jailbreak.displayName ?? placeholder,
                      status: statusForJailbreak)

            HealthRow(label: "越狱根目录",
                      value: snapshot?.jailbreakRoot ?? placeholder,
                      status: .neutral)
        }
    }

    private var statusForJailbreak: HealthStatus {
        guard let snapshot = snapshot else { return .unknown }
        return snapshot.jailbreak == .unknown ? .bad : .good
    }

    // MARK: 签名后端

    private var signingSection: some View {
        Section {
            HealthRow(label: "zsign",
                      value: snapshot?.zsignPath ?? (snapshot == nil ? placeholder : "未找到"),
                      status: snapshot == nil ? .unknown : (snapshot?.zsignPath != nil ? .good : .bad))

            HealthRow(label: "Apple 根证书",
                      value: snapshot == nil ? placeholder
                                             : (snapshot!.certificatesBundled ? "已随包" : "缺失"),
                      status: snapshot == nil ? .unknown
                                              : (snapshot!.certificatesBundled ? .good : .bad))

            HealthRow(label: "root helper",
                      value: snapshot == nil ? placeholder
                                             : (snapshot!.rootHelperPath ?? "未安装"),
                      status: snapshot == nil ? .unknown
                                              : (snapshot!.rootHelperAvailable ? .good : .warning))
        } header: {
            Text("签名后端")
        } footer: {
            Text("root helper 只在需要写系统描述文件时按需拉起，用完即退；缺失时会退回直接写文件，部分越狱环境下可能失败。")
        }
    }

    // MARK: 账号

    private var accountSection: some View {
        Section("账号") {
            HealthRow(label: "登录状态",
                      value: snapshot == nil ? placeholder : (snapshot!.signedIn ? "已登录" : "未登录"),
                      status: snapshot == nil ? .unknown : (snapshot!.signedIn ? .good : .warning))

            HealthRow(label: "Apple ID",
                      value: snapshot?.username ?? placeholder,
                      status: .neutral)

            HealthRow(label: "Team ID",
                      value: snapshot?.teamID ?? placeholder,
                      status: .neutral)

            HealthRow(label: "设备 UDID",
                      value: snapshot?.deviceUDID ?? placeholder,
                      status: snapshot == nil ? .unknown : (snapshot?.deviceUDID != nil ? .good : .bad))
        }
    }

    // MARK: 应用概况

    private var applicationsSection: some View {
        Section("旁加载应用") {
            HealthRow(label: "已扫描",
                      value: snapshot == nil ? placeholder : "\(snapshot!.sideloadedAppCount) 个",
                      status: .neutral)

            HealthRow(label: "最近到期",
                      value: snapshot?.nearestExpiryDate.map(formatExpiry) ?? (snapshot == nil ? placeholder : "无"),
                      status: expiryStatus)
        }
    }

    private var expiryStatus: HealthStatus {
        guard let date = snapshot?.nearestExpiryDate else { return .neutral }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 0 { return .bad }
        if days <= 3 { return .warning }
        return .good
    }

    // MARK: 操作

    private var actionsSection: some View {
        Section {
            Button("刷新状态") { refresh() }
                .disabled(isLoading)

            if isLoading {
                ProgressView("正在检测…")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: 辅助

    private var placeholder: String { isLoading ? "检测中…" : "未知" }

    private func refresh() {
        isLoading = true
        BridgeClient.shared.fetchEnvironment { result in
            snapshot = result
            isLoading = false
        }
    }

    // 静态 formatter 复用（refresh 每次调用都创建新 formatter，不必要）
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func formatExpiry(_ date: Date) -> String {
        return HealthView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 健康状态行

struct HealthRow: View {
    let label: String
    let value: String
    let status: HealthStatus

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(statusColor)
                .multilineTextAlignment(.trailing)
                .font(.callout)
            statusIcon
        }
    }

    private var statusColor: Color {
        switch status {
        case .good: return .green
        case .bad: return .red
        case .warning: return .orange
        case .unknown: return .secondary
        case .neutral: return .secondary
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .good:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .bad:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .unknown:
            Image(systemName: "questionmark.circle.fill").foregroundColor(.secondary)
        case .neutral:
            EmptyView()
        }
    }
}

enum HealthStatus {
    case good, bad, warning, unknown, neutral
}
