import SwiftUI

// MARK: - 日志管理页面（参考 SideStore）

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
                // MARK: 工具栏
                searchBar
                filterBar

                // MARK: 日志列表
                if filteredLogs.isEmpty {
                    emptyLogView
                } else {
                    logList
                }
            }
            .navigationTitle("日志")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导出日志") { exportLogs() }
                        Button(role: .destructive) { showingClearAlert = true } label: {
                            Label("清空", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("确认清空", isPresented: $showingClearAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    LogManager.shared.clear()
                }
            } message: {
                Text("确定要清空所有日志吗？此操作不可撤销。")
            }
            .alert("导出失败", isPresented: $showingExportError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
        }
    }

    // MARK: 搜索栏
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索日志...", text: $searchText)
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: 筛选条
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "全部", level: nil)
                filterChip(title: "错误", level: .error)
                filterChip(title: "警告", level: .warning)
                filterChip(title: "信息", level: .info)
                filterChip(title: "调试", level: .debug)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func filterChip(title: String, level: LogLevel?) -> some View {
        let isSelected = selectedFilter == level
        Button(title) {
            selectedFilter = isSelected ? nil : level
        }
        .font(.subheadline.weight(isSelected ? .semibold : .regular))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue : Color(.systemGray6))
        .foregroundColor(isSelected ? .white : .primary)
        .cornerRadius(16)
    }

    // MARK: 日志列表
    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredLogs.indices, id: \.self) { index in
                let entry = filteredLogs[index]
                LogEntryRow(entry: entry)
                    .id(index)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            }
            .onAppear {
                if !filteredLogs.isEmpty {
                    proxy.scrollTo(filteredLogs.count - 1, anchor: .bottom)
                }
            }
        }
    }

    // MARK: 空状态
    private var emptyLogView: some View {
        Group {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("暂无日志")
                    .foregroundColor(.secondary)
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
        // 检查是否有日志可导出
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
            // 直接从 keyWindow rootVC 呈现分享面板（绕开 SwiftUI .sheet + UIActivityViewController 白屏）
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(entry.level.color)
                    .frame(width: 6, height: 6)
                Text(entry.level.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(entry.level.color)
                Text(formatTime(entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(entry.source)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Text(entry.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
