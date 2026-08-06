import SwiftUI
import Darwin   // v1.1.184：sysctlbyname 取机型 identifier（hw.machine）

// MARK: - 日志管理页面

struct LogView: View {
    @ObservedObject private var logManager = LogManager.shared
    @State private var searchText = ""
    @State private var selectedFilter: LogLevel? = nil
    @State private var showingClearAlert = false
    @State private var showingExportError = false
    @State private var exportErrorMessage = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 固定区域：搜索栏 + 筛选标签（不在 List 内，宽度永远固定）
                searchBar
                    .padding(.top, 8)
                filterChips
                    .padding(.vertical, 8)

                // 日志列表（或空状态）
                if filteredLogs.isEmpty {
                    emptyLogContent
                } else {
                    logList
                }
            }
            .background(Color(.systemGroupedBackground))
            .scrollContentBackground(.hidden)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .top) { statusBarHeader }
            .alert("确认清空", isPresented: $showingClearAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { LogManager.shared.clear() }
            } message: {
                Text("确定要清空所有日志吗？此操作不可撤销。")
            }
            .alert("导出失败", isPresented: $showingExportError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 固定顶部标题栏（替代系统导航栏）
    private var statusBarHeader: some View {
        HStack {
            Text("日志")
                .font(.title2.weight(.bold))
            Spacer()
            Menu {
                Button("导出日志") { exportLogs() }
                Button(role: .destructive) { showingClearAlert = true } label: {
                    Label("清空", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 26))
                    .foregroundColor(.blue)
                    .frame(width: 44, height: 44) // 更大热区
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
                .overlay(alignment: .bottom) { Divider() }
        )
    }

    // MARK: 搜索栏（全宽固定，绝不缩紧）
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.secondary.opacity(0.6))
            TextField("搜索日志...", text: $searchText)
                .font(.subheadline)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10)) // 整个搜索栏都是可点区域
        .padding(.horizontal, 16)
    }

    // MARK: 筛选标签组（纯文字胶囊，无图标）
    private var filterChips: some View {
        HStack(spacing: 7) {
            filterChip(title: "全部", level: nil)
            filterChip(title: "错误", level: .error)
            filterChip(title: "警告", level: .warning)
            filterChip(title: "信息", level: .info)
            filterChip(title: "调试", level: .debug)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func filterChip(title: String, level: LogLevel?) -> some View {
        let isSelected = selectedFilter == level
        Button {
            selectedFilter = isSelected ? nil : level
        } label: {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.blue : Color(.systemFill).opacity(0.6))
                        .overlay(
                            Capsule()
                                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    // MARK: 日志列表（纯列表，不含搜索/筛选）
    // 🔴 v1.1.163：旧版 List(filteredLogs.indices) + filteredLogs[index] —— 日志
    // @Published 更新触发重算时，List 渲染中途 filteredLogs 变化（新日志 append /
    // 切换筛选），下标可能越界 → 「Index out of range」fatalError 崩溃。LogEntry
    // 是 Identifiable，直接数据驱动，杜绝下标访问。
    private var logList: some View {
        List(filteredLogs) { entry in
            LogEntryRow(entry: entry)
                .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: 空状态
    private var emptyLogContent: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary.opacity(0.6))

                Text("暂无日志")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text("应用运行记录将显示在此处")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()
        }
    }

    // MARK: 筛选后的日志
    private var filteredLogs: [LogEntry] {
        var logs = logManager.logs

        if let filter = selectedFilter {
            logs = logs.filter { $0.level == filter }
        }

        if !searchText.isEmpty {
            logs = logs.filter {
                $0.message.localizedCaseInsensitiveContains(searchText) ||
                $0.source.localizedCaseInsensitiveContains(searchText)
            }
        }

        return logs
    }

    // MARK: 导出
    private func exportLogs() {
        guard !filteredLogs.isEmpty else {
            exportErrorMessage = "没有可导出的日志"
            showingExportError = true
            return
        }

        // v1.1.184：导出文件头部预置设备信息（用户要求：日志里要有系统版本 + 手机型号名称）
        let deviceLine = "设备型号: \(LogView.deviceModelName())"
        let systemLine = "系统版本: iOS \(UIDevice.current.systemVersion)"
        let exportTime = LogView.exportDateFormatter.string(from: Date())
        let header = "==== ReSign 日志导出 ====\n\(deviceLine)\n\(systemLine)\n导出时间: \(exportTime)\n========================\n"

        let text = header + filteredLogs.map { "\($0.timestamp) [\($0.level.rawValue)] [\($0.source)] \($0.message)" }.joined(separator: "\n")

        guard let data = text.data(using: .utf8) else {
            exportErrorMessage = "日志数据编码失败"
            showingExportError = true
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("repro_log_\(Int(Date().timeIntervalSince1970)).txt")

        do {
            try data.write(to: tempURL, options: .atomic)
            SharePresenter.share(items: [tempURL])
        } catch {
            exportErrorMessage = "写入文件失败: \(error.localizedDescription)"
            showingExportError = true
        }
    }

    // MARK: 设备信息（v1.1.184）

    /// hw.machine 拿到的 identifier（如 iPhone12,1）→ 用户可读的型号名
    private static func deviceModelName() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "未知设备" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        let identifier = String(cString: buf)

        if let name = Self.modelNames[identifier] {
            return "\(name) (\(identifier))"
        }
        return identifier   // 新机型没收录时至少给出原始 identifier
    }

    private static let modelNames: [String: String] = [
        // 旧款
        "iPhone1,1": "iPhone", "iPhone1,2": "iPhone 3G", "iPhone2,1": "iPhone 3GS",
        "iPhone3,1": "iPhone 4", "iPhone3,3": "iPhone 4 (CDMA)", "iPhone4,1": "iPhone 4s",
        "iPhone5,1": "iPhone 5", "iPhone5,2": "iPhone 5 (CDMA)", "iPhone5,3": "iPhone 5c",
        "iPhone6,1": "iPhone 5s", "iPhone6,2": "iPhone 5s (CDMA)",
        "iPhone7,1": "iPhone 6 Plus", "iPhone7,2": "iPhone 6",
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE (第 1 代)",
        "iPhone9,1": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,3": "iPhone 7", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,3": "iPhone X", "iPhone10,4": "iPhone 8", "iPhone10,5": "iPhone 8 Plus", "iPhone10,6": "iPhone X",
        // XS 系列
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        // 11 系列
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (第 2 代)",
        // 12 系列
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        // 13 系列
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (第 3 代)",
        // 14 系列
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        // 15 系列
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        // 16 系列
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
    ]

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

// MARK: - 单行日志条目

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.level.color)
                        .frame(width: 7, height: 7)
                    Text(entry.level.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(entry.level.color)
                }

                Spacer()

                Text(formatTime(entry.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)

                Text(entry.source)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
            }

            Text(entry.message)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.vertical, 6)
    }

    // 静态 formatter 复用，避免每行日志都 new 一个 DateFormatter（列表 5000 行时开销显著）
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func formatTime(_ date: Date) -> String {
        return LogEntryRow.timeFormatter.string(from: date)
    }
}
