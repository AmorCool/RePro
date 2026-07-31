import SwiftUI

// MARK: - 系统健康状态检查页面

struct HealthView: View {
    @ObservedObject private var daemonClient = DaemonClient.shared
    @State private var healthStatus: DaemonHealthStatus?
    @State private var isLoading = false
    @State private var connectionError: String?  // 连接错误信息

    var body: some View {
        NavigationView {
            List {
                // MARK: 守护进程状态
                Section("守护进程") {
                    HealthRow(label: "运行状态",
                             value: {
                                 if let status = healthStatus {
                                     return status.daemonRunning ? "运行中" : "已停止"
                                 } else if connectionError != nil {
                                     return "连接失败"
                                 }
                                 return isLoading ? "检测中..." : "未知"
                             }(),
                             status: {
                                 if healthStatus?.daemonRunning == true { return .good }
                                 if healthStatus?.daemonRunning == false { return .bad }
                                 if connectionError != nil { return .bad }
                                 return .unknown
                             }())

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
                                 } else if connectionError != nil {
                                     return "连接失败"
                                 }
                                 return "未知"
                             }(),
                             status: {
                                 if healthStatus != nil { return (healthStatus?.uid ?? -1) == 0 ? .good : .bad }
                                 if connectionError != nil { return .bad }
                                 return .unknown
                             }())

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
                                 } else if connectionError != nil {
                                     return "连接失败"
                                 }
                                 return "检测中..."
                             }(),
                             status: {
                                 if healthStatus?.zsignPath != nil { return .good }
                                 if healthStatus != nil { return .bad }
                                 if connectionError != nil { return .bad }
                                 return .unknown
                             }())
                }

                // MARK: Token 与 Anisette
                Section("缓存状态") {
                    HealthRow(label: "有效 Token",
                             value: healthStatus != nil ? "\(healthStatus?.validTokenCount ?? 0) 个" : (connectionError != nil ? "连接失败" : "未知"),
                             status: (healthStatus?.validTokenCount ?? 0) > 0 ? .good : (connectionError != nil ? .bad : .unknown))

                    HealthRow(label: "Anisette",
                             value: healthStatus?.anisetteReady == true ? "就绪" : (healthStatus != nil ? "未初始化" : (connectionError != nil ? "连接失败" : "未知")),
                             status: healthStatus?.anisetteReady == true ? .good : (connectionError != nil ? .bad : .unknown))
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
        connectionError = nil
        daemonClient.getHealth { result in
            DispatchQueue.main.async(execute: {
                self.isLoading = false
                switch result {
                case .success(let status):
                    self.healthStatus = status
                    self.connectionError = nil
                case .failure(let error):
                    let errMsg = error.localizedDescription
                    LogManager.shared.error("获取健康状态失败: \(errMsg)", source: "HealthView")
                    self.healthStatus = nil
                    self.connectionError = errMsg
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
