import SwiftUI

// MARK: - 已安装应用列表

struct AppsView: View {
    @StateObject private var viewModel = SigningViewModel()
    @State private var showingFileImporter = false

    var body: some View {
        NavigationView {
            ZStack {
                if viewModel.installedApps.isEmpty {
                    emptyState
                } else {
                    appList
                }
            }
            .navigationTitle("RePro")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingFileImporter = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.archive],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        viewModel.importIPA(url: url)
                    }
                case .failure(let error):
                    LogManager.shared.error("导入 IPA 失败: \(error.localizedDescription)", source: "AppsView")
                }
            }
        }
    }

    // MARK: 空状态
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无已安装的应用")
                .font(.headline)
                .foregroundColor(.secondary)
            Button("导入 IPA") {
                showingFileImporter = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: 应用列表
    private var appList: some View {
        List {
            ForEach(viewModel.installedApps) { app in
                AppRowView(app: app, viewModel: viewModel)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.resign(app: app)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.removeApp(app: app)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .refreshable {
            await viewModel.refreshApps()
        }
    }
}

// MARK: - 应用行视图

struct AppRowView: View {
    let app: InstalledApp
    @ObservedObject var viewModel: SigningViewModel

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            if let icon = app.icon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .cornerRadius(10)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "app").foregroundColor(.secondary))
            }

            // 信息列
            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    expiryBadge
                    signingStatus
                }
            }

            Spacer()

            // 签名按钮
            if app.isSigning {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("重签") {
                    viewModel.resign(app: app)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 过期状态标签
    @ViewBuilder
    private var expiryBadge: some View {
        let daysLeft = app.daysUntilExpiry

        if daysLeft < 0 {
            Text("已过期")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.15))
                .foregroundColor(.red)
                .cornerRadius(4)
        } else if daysLeft <= 3 {
            Text("\(daysLeft) 天后过期")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .cornerRadius(4)
        } else {
            Text("有效 (\(daysLeft) 天)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundColor(.green)
                .cornerRadius(4)
        }
    }

    // MARK: 签名状态
    @ViewBuilder
    private var signingStatus: some View {
        if app.isSigning {
            Text("签名中...")
                .font(.caption2)
                .foregroundColor(.blue)
        }
    }
}
