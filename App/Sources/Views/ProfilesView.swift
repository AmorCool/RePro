import SwiftUI

// MARK: - 系统描述文件管理（v1.1.171）
//
// 数据来自真实的 /var/Managed Preferences/mobile。App 是 uid 501 且受沙盒约束，
// 不能直接列举该目录，所以由 root 侧导出清单快照
// （/var/mobile/Library/Resign/profiles-inventory.plist），本界面只读这份快照；
// 删除与清理同样交给 root 侧执行。
//
// root 侧是谁取决于越狱形态（RPVBridge 自动选择，界面无感）：
//  - rootless / rootful：没有 namespace 隔离，直接同步拉起 setuid root 的 repro-helper 即可
//    （rootless/rootful 下 /var/Managed Preferences/mobile 只是「需 root 才能写」，helper 代劳最快）。
// 实现见 Helper/RPVProfileStore.h。
//
// 为什么需要这个界面：真机实测同一个 App ID 曾堆积 102 份未过期描述文件
// （目录内共 163 份只对应 3 个 App）。profiled 扫描到同一 application-identifier
// 的上百份 profile 时会挑中旧份去校验刚重签的 App → 0xe8008015 → 签名后闪退。

struct ManagedProfile: Identifiable {
    let id: String
    let fileName: String
    let appId: String
    let displayName: String
    let uuid: String
    let sizeBytes: Int
    let isStableName: Bool
    let parsed: Bool
    let creationDate: Date?
    let expirationDate: Date?
    let modifiedDate: Date?

    init?(dict: [String: Any]) {
        guard let fileName = dict["fileName"] as? String, !fileName.isEmpty else { return nil }
        self.id = fileName
        self.fileName = fileName
        self.appId = dict["appId"] as? String ?? ""
        self.displayName = dict["displayName"] as? String ?? ""
        self.uuid = dict["uuid"] as? String ?? ""
        self.sizeBytes = (dict["sizeBytes"] as? NSNumber)?.intValue ?? 0
        self.isStableName = (dict["isStableName"] as? NSNumber)?.boolValue ?? false
        self.parsed = (dict["parsed"] as? NSNumber)?.boolValue ?? false
        self.creationDate = dict["creationDate"] as? Date
        self.expirationDate = dict["expirationDate"] as? Date
        self.modifiedDate = dict["modifiedDate"] as? Date
    }

    var isExpired: Bool {
        guard let e = expirationDate else { return false }
        return e < Date()
    }

    /// application-identifier 形如 TEAMID.com.x.y.TEAMID，剥掉前后 TeamID 只留 Bundle ID。
    var bundleId: String {
        guard !appId.isEmpty else { return "（无法解析）" }
        let team = String(appId.prefix(while: { $0 != "." }))
        var s = appId
        if !team.isEmpty, s.hasPrefix(team + ".") {
            s = String(s.dropFirst(team.count + 1))
        }
        if !team.isEmpty, s.hasSuffix("." + team) {
            s = String(s.dropLast(team.count + 1))
        }
        return s.isEmpty ? appId : s
    }

    /// 排序用时间：优先创建时间，退回文件修改时间。
    var sortDate: Date {
        creationDate ?? modifiedDate ?? Date.distantPast
    }

    var remainingText: String {
        guard let e = expirationDate else { return "有效期未知" }
        if e < Date() { return "已过期" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 0
        if days >= 1 { return "剩余 \(days) 天" }
        let hours = Calendar.current.dateComponents([.hour], from: Date(), to: e).hour ?? 0
        return "剩余 \(max(hours, 0)) 小时"
    }
}

/// 一个 App ID 对应的一组描述文件（组内按时间倒序，第一个是当前生效的那份）。
private struct ProfileGroup: Identifiable {
    let id: String
    let bundleId: String
    let profiles: [ManagedProfile]

    var duplicateCount: Int { max(profiles.count - 1, 0) }
}

struct ProfilesView: View {
    @State private var profiles: [ManagedProfile] = []
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var isStatusError = false
    // 🔴 v1.1.185：删除/清理功能整体移除（MC 注销在 RootHide 下 SIGSEGV 崩溃，
    // @try 接不住信号 → daemon 崩溃 → App 等 60s「root 侧未响应」）。
    // 本页只保留「查看 + 刷新清单」；swipe 删除、清理按钮、相关 state 已删除。

    private var groups: [ProfileGroup] {
        let grouped = Dictionary(grouping: profiles) { $0.appId }
        return grouped.map { key, value in
            let sorted = value.sorted { $0.sortDate > $1.sortDate }
            return ProfileGroup(id: key.isEmpty ? "unknown" : key,
                                bundleId: sorted.first?.bundleId ?? "（无法解析）",
                                profiles: sorted)
        }
        .sorted { $0.profiles.count > $1.profiles.count }
    }

    private var duplicateTotal: Int { groups.reduce(0) { $0 + $1.duplicateCount } }
    private var expiredTotal: Int { profiles.filter { $0.isExpired }.count }

    var body: some View {
        List {
            summarySection

            if let msg = statusMessage {
                Section {
                    Label(msg, systemImage: isStatusError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.footnote)
                        .foregroundColor(isStatusError ? .orange : .green)
                }
            }

            actionsSection

            if profiles.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(isLoading ? "正在读取清单…" : "暂无描述文件清单")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        if !isLoading {
                            Text("点击上方「刷新清单」导出一次。\n若始终为空，说明 repro-helper 未安装或缺少 setuid 权限：\n请确认 /var/jb/usr/libexec/repro-helper 存在且有 root 属主 + setuid 位。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(Array(group.profiles.enumerated()), id: \.element.id) { index, profile in
                            profileRow(profile, isCurrent: index == 0)
                        }
                    } header: {
                        HStack {
                            Text(group.bundleId)
                                .font(.footnote)
                            Spacer()
                            if group.duplicateCount > 0 {
                                Text("\(group.profiles.count) 份 · 多余 \(group.duplicateCount)")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            } else {
                                Text("1 份")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("描述文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadLocalInventory)
    }

    // MARK: - 子视图

    private var summarySection: some View {
        Section {
            HStack {
                statBox(title: "描述文件", value: "\(profiles.count)", color: .primary)
                Divider()
                statBox(title: "涉及 App", value: "\(groups.count)", color: .primary)
                Divider()
                statBox(title: "多余", value: "\(duplicateTotal)", color: duplicateTotal > 0 ? .orange : .secondary)
                Divider()
                statBox(title: "已过期", value: "\(expiredTotal)", color: expiredTotal > 0 ? .red : .secondary)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("系统目录 /var/Managed Preferences/mobile 的实际内容。每次重签都会生成一份描述文件，同一个 App 堆积多份时，系统可能挑中旧的那份去校验刚签好的应用，导致打开即闪退。")
        }
    }

    private func statBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionsSection: some View {
        Section {
            // 🔴 ProgressView 必须嵌在 Button 的 label 内部，绝不能单独成行：
            // 独立成行会让 List contentSize 突变，触发 iOS 17 底栏抖动（v1.1.161 实锤）。
            Button {
                refreshInventory()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("刷新清单")
                    Spacer()
                    if isLoading {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .disabled(isLoading)
            // 🔴 v1.1.185：「清理重复与过期」按钮已移除（删除/清理功能整体下线，
            // 防堆积靠稳定名覆盖写 + profiled 重扫，无需手动清理）。
        } header: {
            Text("操作")
        }
    }

    private func profileRow(_ profile: ManagedProfile, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(profile.displayName.isEmpty ? profile.bundleId : profile.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                if isCurrent {
                    Text("当前")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundColor(.accentColor)
                }
                if profile.isExpired {
                    Text("已过期")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .foregroundColor(.red)
                }
                if !profile.parsed {
                    Text("损坏")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundColor(.orange)
                }
            }

            HStack(spacing: 8) {
                Text(profile.remainingText)
                if let c = profile.creationDate {
                    Text("· 生成于 \(Self.dateFormatter.string(from: c))")
                }
            }
            .font(.caption2)
            .foregroundColor(profile.isExpired ? .red : .secondary)

            Text(profile.uuid.isEmpty ? profile.fileName : profile.uuid)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    // MARK: - 数据

    /// 只读本地快照，不唤醒 root 侧，用于进入界面时立刻出内容。
    private func loadLocalInventory() {
        profiles = Self.parse(RPVBridge.managedProfilesInventory())
        if profiles.isEmpty { refreshInventory() }
    }

    private static func parse(_ raw: [[String: Any]]) -> [ManagedProfile] {
        raw.compactMap { ManagedProfile(dict: $0) }
    }

    /// 桥接方法内部会阻塞等待 root 侧完成（RootHide 走 daemon 最长 60 秒），必须放后台线程。
    private func refreshInventory() {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = RPVBridge.refreshManagedProfilesInventory()
            let items = Self.parse(RPVBridge.managedProfilesInventory())
            DispatchQueue.main.async {
                isLoading = false
                profiles = items
                if !ok && items.isEmpty {
                    isStatusError = true
                    statusMessage = "root 侧未响应，无法读取描述文件清单"
                }
            }
        }
    }
    // 🔴 v1.1.185：runCleanup / runDelete 已移除（删除/清理功能整体下线）。
}
