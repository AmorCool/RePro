import SwiftUI

// MARK: - 系统健康状态检查页面

struct HealthView: View {
    @ObservedObject private var daemonClient = DaemonClient.shared
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

                    HealthRow(label: "版本号",
                             value: healthStatus?.daemonVersion ?? "未知",
                             status: healthStatus?.daemonVersion != nil ? .neutral : .unknown)

                    HealthRow(label: "二进制权限",
                             value: {
                                 if let status = healthStatus {
                                     let pid = status.pid ?? 0
                                     let uid = status.uid ?? -1
                                     let euid = status.effectiveUid ?? -1
                                     if uid == 0 {
                                         return "PID=\(pid), root (uid=\(uid))"
                                     } else {
                                         return "PID=\(pid), uid=\(uid) (非root)"
                                     }
                                 }
                                 return "未知"
                             }(),
                             status: (healthStatus?.uid ?? -1) == 0 ? .good : .bad)

                    HealthRow(label: "沙盒限制",
                             value: healthStatus?.isSandboxed == true ? "存在" : "不受限制",
                             status: healthStatus?.isSandboxed == true ? .warning : .good)

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
                             value: {
                                 if let path = healthStatus?.zsignPath {
                                     return path
                                 } else if healthStatus != nil {
                                     return "未找到"
                                 }
                                 return "检测中..."
                             }(),
                             status: {
                                 if healthStatus?.zsignPath != nil { return .good }
                                 if healthStatus != nil { return .bad }
                                 return .unknown
                             }())
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
            DispatchQueue.main.async(execute: {
                self.isLoading = false
                switch result {
                case .success(let status):
                    self.healthStatus = status
                case .failure(let error):
                    LogManager.shared.error("获取健康状态失败: \(error)", source: "HealthView")
                    self.healthStatus = nil
                }
            })
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
