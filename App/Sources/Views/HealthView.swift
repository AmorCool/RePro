import SwiftUI

// MARK: - 系统健康状态检查页面

struct HealthView: View {
    @StateObject private var daemonClient = DaemonClient.shared
    @State private var healthStatus: DaemonHealthStatus?
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            List {
                // MARK: 守护进程状态
                Section("守护进程") {
                    HealthRow(label: "运行状态",
                             value: healthStatus?.daemonRunning == true ? "运行中" : "未运行",
                             status: healthStatus?.daemonRunning == true ? .good : .bad)

                    HealthRow(label: "二进制权限",
                             value: healthStatus?.hasRootPrivileges == true ? "Root 正常" : "权限异常",
                             status: healthStatus?.hasRootPrivileges == true ? .good : .bad)

                    HealthRow(label: "沙盒限制",
                             value: healthStatus?.isSandboxed == false ? "无沙盒" : "存在沙盒",
                             status: healthStatus?.isSandboxed == false ? .good : .warning)

                    HealthRow(label: "上次重签",
                             value: healthStatus?.lastResignTime.map(formatTime) ?? "从未",
                             status: .neutral)
                }

                // MARK: 越狱环境
                Section("越狱环境") {
                    let jbType = JailbreakDetect.current()
                    HealthRow(label: "环境类型",
                             value: jbType.displayName,
                             status: .good)

                    HealthRow(label: "zsign 路径",
                             value: healthStatus?.zsignPath ?? "检测中...",
                             status: healthStatus?.zsignPath != nil ? .good : .unknown)
                }

                // MARK: Token 与 Anisette
                Section("缓存状态") {
                    HealthRow(label: "有效 Token",
                             value: "\(healthStatus?.validTokenCount ?? 0) 个",
                             status: (healthStatus?.validTokenCount ?? 0) > 0 ? .good : .bad)

                    HealthRow(label: "Anisette",
                             value: healthStatus?.anisetteReady == true ? "就绪" : "未初始化",
                             status: healthStatus?.anisetteReady == true ? .good : .unknown)
                }

                // MARK: 操作按钮
                Section {
                    Button("刷新状态") {
                        refreshHealth()
                    }
                    .disabled(isLoading)

                    Button("重启守护进程") {
                        restartDaemon()
                    }
                    .disabled(isLoading)

                    if isLoading {
                        ProgressView("正在检测...")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("系统状态")
            .onAppear {
                refreshHealth()
            }
        }
    }

    private func refreshHealth() {
        isLoading = true
        daemonClient.getHealth { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let status):
                    self.healthStatus = status
                case .failure(let error):
                    LogManager.shared.error("获取健康状态失败: \(error)", source: "HealthView")
                    self.healthStatus = nil
                }
            }
        }
    }

    private func restartDaemon() {
        daemonClient.restartDaemon { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                refreshHealth()
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 健康状态行

struct HealthRow: View {
    let label: String
    let value: String
    let status: HealthStatus

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(statusColor)
                .multilineTextAlignment(.trailing)
            statusIcon
        }
    }

    private var statusColor: Color {
        switch status {
        case .good: return .green
        case .bad: return .red
        case .warning: return .orange
        case .unknown: return .secondary
        case .neutral: return .primary
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
