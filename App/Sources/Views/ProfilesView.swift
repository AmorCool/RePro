import SwiftUI

// MARK: - 系统描述文件管理（v1.1.171）
//
// 数据来自真实的 /var/Managed Preferences/mobile。App 是 uid 501 且受沙盒约束，
// 不能直接列举该目录，所以由 root 侧导出清单快照
// （/var/mobile/Library/RePro/profiles-inventory.plist），本界面只读这份快照；
// 删除与清理同样交给 root 侧执行。
//
// root 侧是谁取决于越狱形态（RPVBridge 自动选择，界面无感）：
//  - RootHide：走 rootfs LaunchDaemon repro-profiledaemon —— App 在 jbroot namespace 内，
//    自己（乃至 helper）访问该目录会被 overlay 重定向到假目录，必须由它代劳；
//  - rootless / rootful：没有这层隔离，直接同步拉起 setuid root 的 repro-helper 更快。
// 两者调用的是同一份实现（Helper/RPVProfileStore.h），行为完全一致。
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
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var isStatusError = false
    @State private var showingCleanupConfirm = false
    @State private var pendingDelete: ManagedProfile?

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
                            Text("点击上方「刷新清单」导出一次。\n若始终为空，说明 root 助手不可用：\nRootHide 请确认 repro-profiledaemon 已加载，\n其他形态请确认 repro-helper 有 setuid 权限。")
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
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        pendingDelete = profile
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
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
        .alert("清理描述文件", isPresented: $showingCleanupConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { runCleanup() }
        } message: {
            Text("将删除全部已过期/损坏的描述文件，并对每个 App 只保留最新的一份（多余 \(duplicateTotal) 份、过期 \(expiredTotal) 份）。当前生效的描述文件不会被删除。")
        }
        .alert(item: $pendingDelete) { profile in
            // v1.1.184：删除确认文案精简（用户嫌长篇大论烦）——一行问完直接删
            Alert(title: Text("删除描述文件"),
                  message: Text("确定删除这份描述文件吗？"),
                  primaryButton: .destructive(Text("删除")) { runDelete(profile) },
                  secondaryButton: .cancel(Text("取消")))
        }
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
            .disabled(isLoading || isWorking)

            Button {
                showingCleanupConfirm = true
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清理重复与过期")
                        Text("每个 App 只保留最新一份")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isWorking {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .disabled(isLoading || isWorking || (duplicateTotal == 0 && expiredTotal == 0))
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

    private func runCleanup() {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RPVBridge.requestManagedProfileCleanup()
            let items = Self.parse(RPVBridge.managedProfilesInventory())
            DispatchQueue.main.async {
                isWorking = false
                profiles = items
                isStatusError = (result == nil)
                statusMessage = result ?? "清理失败：root 侧未响应"
            }
        }
    }

    private func runDelete(_ profile: ManagedProfile) {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        let name = profile.fileName
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RPVBridge.requestManagedProfileDeletion([name])
            let items = Self.parse(RPVBridge.managedProfilesInventory())
            DispatchQueue.main.async {
                isWorking = false
                profiles = items
                isStatusError = (result == nil)
                statusMessage = result ?? "删除失败：root 侧未响应"
            }
        }
    }
}
