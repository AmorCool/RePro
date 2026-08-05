import SwiftUI
import UIKit

// MARK: - 系统状态页
//
// 这里展示的全部是 App 进程内可以直接探测到的事实（越狱形态、zsign 位置、
// 证书是否随包、账号状态、旁加载应用概况）。没有守护进程，也就没有
// 「守护进程运行状态 / PID / uid」这类需要跨进程询问的指标。

struct HealthView: View {
    @State private var snapshot: EnvironmentSnapshot?
    @State private var isLoading = false
    /// 跳转文件管理器失败时的提示（同时兼作「路径已复制」的回执）
    @State private var openHint: String?

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
            .alert("打开文件管理器",
                   isPresented: Binding(get: { openHint != nil },
                                        set: { if !$0 { openHint = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(openHint ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 越狱环境

    private var jailbreakSection: some View {
        Section {
            HealthRow(label: "环境类型",
                      value: snapshot?.jailbreak.displayName ?? placeholder,
                      status: statusForJailbreak)

            if let root = snapshot?.jailbreakRoot, !root.isEmpty {
                // RootHide 的 jbroot 是随机路径（/var/containers/Bundle/Application/
                // .jbroot-XXXXXXXXXXXXXXXX），照着屏幕手抄进文件管理器极易出错，
                // 干脆做成可点按，直接把 Filza 拉起来定位到这个目录。
                Button {
                    openInFileManager(root)
                } label: {
                    HStack(alignment: .top) {
                        Text("越狱根目录")
                            .foregroundColor(.primary)
                        Spacer(minLength: 12)
                        Text(root)
                            .foregroundColor(.blue)
                            .multilineTextAlignment(.trailing)
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.footnote)
                            .foregroundColor(.blue)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("越狱根目录：\(root)")
                .accessibilityHint("点按用 Filza 打开该目录")
            } else {
                HealthRow(label: "越狱根目录",
                          value: snapshot?.jailbreakRoot ?? placeholder,
                          status: .neutral)
            }
        } header: {
            Text("越狱环境")
        } footer: {
            if let root = snapshot?.jailbreakRoot, !root.isEmpty {
                Text("点按「越狱根目录」可用 Filza 打开该目录；未安装 Filza 时会把路径复制到剪贴板。")
            }
        }
    }

    /// 用 Filza 打开指定目录。
    /// Filza 注册的 scheme 是 `filza://view/<绝对路径>`。
    /// 这里刻意**不用** `canOpenURL` —— 那要求在 Info.plist 的
    /// LSApplicationQueriesSchemes 里预先登记 scheme，否则一律返回 false；
    /// 直接 open 的 completion 同样能告诉我们有没有 App 接管，且没有登记要求。
    private func openInFileManager(_ root: String) {
        let encoded = root.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? root
        guard let url = URL(string: "filza://view" + encoded) else {
            copyPath(root, reason: "路径无法转换成 URL")
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                copyPath(root, reason: "未检测到 Filza（或它拒绝了跳转）")
            }
        }
    }

    private func copyPath(_ path: String, reason: String) {
        UIPasteboard.general.string = path
        openHint = "\(reason)。\n路径已复制到剪贴板：\n\(path)"
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
    //
    // 关键设计：ProgressView 必须放在 Button label 内部，**不能**作为
    // 独立的 List 行存在。否则 isLoading 切换会让 List 高度突变（多/少
    // 一行 ProgressView），iOS 17 上会触发 _UITabBarVisualProvider 的
    // safeAreaInsets 重算，配合 roothide launchdhook 注入的 UIKit
    // 拦截器，最终表现为「系统 TabBar 在刷新瞬间上下抖动」（用户称「鬼畜」）。
    // 把 spinner 嵌进 button label，List 整列高度恒定，TabBar 不再抖动。

    private var actionsSection: some View {
        Section {
            Button {
                refresh()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .foregroundColor(.blue)
                        .frame(width: 24)

                    Text("刷新状态")
                        .foregroundColor(.primary)

                    Spacer()

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            .disabled(isLoading)
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
        // 旁白默认会把 label/value/icon 拆成三个独立元素念出来，体验割裂。
        // 这里合并成一个「label：value（状态）」完整短语。
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
        .accessibilityValue(accessibilityStatusText)
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

    private var accessibilityStatusText: String {
        switch status {
        case .good: return "正常"
        case .bad: return "异常"
        case .warning: return "需关注"
        case .unknown: return "未知"
        case .neutral: return ""
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
