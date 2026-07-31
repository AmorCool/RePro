import SwiftUI

// MARK: - 已注册 AppIDs 列表视图
//
// 数据来自 Apple Developer API（listAppIds.action），
// 通过 RPVBridge → EEAppleServices 拉取。
// 原版位置：Installed tab 内的 "N AppIDs found" 标签 → 全屏弹窗。

struct AppIDsView: View {
    @ObservedObject private var account = BridgeClient.shared
    @State private var appIDs: [RegisteredAppID] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            appIDContent
        }
        .navigationTitle("已注册 App IDs (\(appIDs.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: loadAppIDs) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || !account.isSignedIn)
            }
        }
        .onAppear { if appIDs.isEmpty { loadAppIDs() } }
    }

    @ViewBuilder
    private var appIDContent: some View {
        if isLoading {
            HStack {
                ProgressView()
                Text("正在拉取 AppID 列表…")
                    .foregroundColor(.secondary)
            }
        } else if let error = errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(error)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("重试") { loadAppIDs() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else if appIDs.isEmpty && !isLoading {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "number")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("暂无已注册的 AppID")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("登录后在 Apple Developer 注册的应用会显示在这里")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ForEach(appIDs) { appID in
                AppIDRowView(appID: appID)
            }
        }
    }

    // MARK: - 数据加载

    private func loadAppIDs() {
        guard account.isSignedIn else {
            errorMessage = "请先登录 Apple ID"
            return
        }
        isLoading = true
        errorMessage = nil
        account.fetchAppIDs { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let ids):
                    self.appIDs = ids
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 单行 AppID

private struct AppIDRowView: View {
    let appID: RegisteredAppID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appID.applicationName)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(appID.identifier)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                expiryBadge
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var expiryBadge: some View {
        let text = appID.detailedTimeRemaining
        if text.contains("已过期") {
            badge(text, color: .red)
        } else if text.contains("即将过期") || text.contains("分钟后过期") {
            badge(text, color: .red)
        } else if let days = appID.daysRemaining, days <= 7 {
            badge(text, color: .orange)
        } else {
            badge(text, color: .green)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}
