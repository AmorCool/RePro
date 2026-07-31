import SwiftUI
import UniformTypeIdentifiers

// MARK: - IPA 文件选择器（UIDocumentPickerViewController 包装）
//
// 使用 UIViewControllerRepresentable 包装系统文档选择器，
// 支持 .ipa 文件的选择（带勾选圈和完成按钮，如图二）。
// 必须用 .sheet 而非 .fullScreenCover，否则在越狱环境下可能无法正常选择文件。

struct IPADocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 显式声明 IPA 的 UTType（iOS 不内置 .ipa 类型，需要动态创建）
        let ipaType = UTType(filenameExtension: "ipa") ?? UTType.data

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [ipaType, .archive, .item], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onDismiss: { presentationMode.dismissed() }) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onDismiss: () -> Void
        init(onPick: @escaping (URL) -> Void, onDismiss: @escaping () -> Void) {
            self.onPick = onPick
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
            onDismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            LogManager.shared.info("用户取消了文件选择", source: "AppsView")
            onDismiss()
        }
    }
}

// MARK: - 已安装应用列表

struct AppsView: View {
    @StateObject private var viewModel = SigningViewModel()
    @ObservedObject private var account = BridgeClient.shared
    @State private var showingFileImporter = false
    @State private var pendingUninstall: InstalledApp?
    @State private var showingAppIDs = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 应用列表（有应用时）或空状态（无应用时）
                if viewModel.installedApps.isEmpty {
                    emptyState
                } else {
                    appList
                }

                // 已注册 AppIDs 入口 —— 始终显示（登录后），不受应用列表是否为空影响
                if account.isSignedIn {
                    appIDsSection
                }
            }
            .navigationTitle("RePro")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        viewModel.resignAllExpiring()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.isBusy || !account.isSignedIn)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                        Text("导入")
                    }
                    .disabled(viewModel.isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
            .sheet(isPresented: $showingFileImporter) {
                IPADocumentPicker { url in
                    viewModel.importIPA(url: url)
                }
            }
            .confirmationDialog("卸载应用",
                                isPresented: Binding(get: { pendingUninstall != nil },
                                                     set: { if !$0 { pendingUninstall = nil } }),
                                titleVisibility: .visible) {
                Button("卸载 \(pendingUninstall?.displayName ?? "")", role: .destructive) {
                    if let app = pendingUninstall { viewModel.uninstall(app: app) }
                    pendingUninstall = nil
                }
                Button("取消", role: .cancel) { pendingUninstall = nil }
            } message: {
                Text("该应用及其数据会从设备上移除。")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 底部状态条
    @ViewBuilder
    private var statusBar: some View {
        if viewModel.isBusy || viewModel.lastError != nil || !account.isSignedIn {
            HStack(spacing: 8) {
                if viewModel.isBusy {
                    ProgressView().scaleEffect(0.7)
                    Text(viewModel.progressMessage)
                        .font(.caption)
                        .lineLimit(1)
                } else if let error = viewModel.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundColor(.orange)
                    Text("未登录 Apple ID，无法重签")
                        .font(.caption)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    // MARK: 空状态
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无旁加载的应用")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("导入一个 .ipa，或下拉刷新重新扫描设备")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("导入 IPA") {
                showingFileImporter = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
            Spacer()
        }
    }

    // MARK: 已注册 AppIDs（精简版 —— 单行入口，无冗余文字）

    private var appIDsSection: some View {
        NavigationLink(destination: AppIDsView()) {
            HStack(spacing: 10) {
                Image(systemName: "number")
                    .foregroundColor(.blue)
                    .frame(width: 24)
                Text("查询已注册 AppID")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 应用列表
    private var appList: some View {
        List {
            ForEach(viewModel.installedApps) { app in
                AppRowView(app: app) {
                    viewModel.resign(app: app)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingUninstall = app
                    } label: {
                        Label("卸载", systemImage: "trash")
                    }
                }
            }

            // （已注册 AppIDs 入口已移至 body 层的 appIDsSection，确保无应用时也可见）
        }
        .refreshable {
            await viewModel.refreshApps()
        }
    }
}

// MARK: - 应用行视图

struct AppRowView: View {
    let app: InstalledApp
    let onResign: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if app.isSigning {
                    ProgressView(value: Double(app.signingProgress), total: 100)
                        .frame(maxWidth: 160)
                } else {
                    expiryBadge
                }
            }

            Spacer()

            if app.isSigning {
                Text("\(app.signingProgress)%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Button("重签", action: onResign)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var icon: some View {
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
    }

    // MARK: 过期状态标签
    @ViewBuilder
    private var expiryBadge: some View {
        if let daysLeft = app.daysUntilExpiry {
            if daysLeft < 0 {
                badge("已过期", color: .red)
            } else if daysLeft <= 3 {
                badge("\(daysLeft) 天后过期", color: .orange)
            } else {
                badge("有效 (\(daysLeft) 天)", color: .green)
            }
        } else if app.hasEmbeddedProvision {
            badge("到期时间未知", color: .secondary)
        } else {
            badge("无描述文件", color: .secondary)
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
