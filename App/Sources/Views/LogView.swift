import SwiftUI

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
                    .font(.system(size: 24)) // 大图标，易点击
                    .foregroundColor(.blue)
                    .frame(width: 36, height: 36) // 扩大热区
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }

    // MARK: 筛选标签组（横向排列，在固定 VStack 中不受 List 影响）
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                filterChip(title: "全部", icon: nil, level: nil)
                filterChip(title: "错误", icon: "xmark.circle.fill", level: .error)
                filterChip(title: "警告", icon: "exclamationmark.triangle.fill", level: .warning)
                filterChip(title: "信息", icon: "info.circle.fill", level: .info)
                filterChip(title: "调试", icon: "bug.fill", level: .debug)
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func filterChip(title: String, icon: String?, level: LogLevel?) -> some View {
        let isSelected = selectedFilter == level
        Button {
            selectedFilter = isSelected ? nil : level
        } label: {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? Color.blue : Color(.systemFill).opacity(0.6))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : Color(.separator).opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 日志列表（纯列表，不含搜索/筛选）
    private var logList: some View {
        List(filteredLogs.indices, id: \.self) { index in
            let entry = filteredLogs[index]
            LogEntryRow(entry: entry)
                .id(index)
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

        let text = filteredLogs.map { "\($0.timestamp) [\($0.level.rawValue)] [\($0.source)] \($0.message)" }.joined(separator: "\n")

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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
