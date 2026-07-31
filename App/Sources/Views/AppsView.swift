import SwiftUI
import UniformTypeIdentifiers

// MARK: - IPA 文件选择器
//
// 用空 UIViewController 作为宿主，在 viewDidAppear 时真正 present
// UIDocumentPickerViewController。这样 picker 在 VC 层级链中位置正确，
// delegate 回调（didPickDocumentsAt / didPickDocumentsAtURLs）才能正常触发。
//
// 关键点：
//  - asCopy: true —— 让系统把选中文件拷贝到沙箱临时目录，避免越狱环境下
//    安全作用域 URL（security-scoped resource）访问失败
//  - 不允许选多个文件（我们只需要一个 .ipa）

struct IPADocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> PickerHostController {
        let host = PickerHostController()
        host.onPick = onPick
        host.onDismiss = { [weak host] in
            host?.dismiss(animated: true) {
                self.presentationMode.wrappedValue.dismiss()
            }
        }
        return host
    }

    func updateUIViewController(_ uiViewController: PickerHostController, context: Context) {}

    /// 空 VC：仅用于承载 UIDocumentPickerViewController 的 present
    class PickerHostController: UIViewController {
        var onPick: ((URL) -> Void)?
        var onDismiss: (() -> Void)?
        var appeared = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !appeared else { return }
            appeared = true
            presentPicker()
        }

        private func presentPicker() {
            let ipaType = UTType(filenameExtension: "ipa") ?? UTType.data
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [ipaType, .archive, .item], asCopy: true)
            picker.delegate = self
            // 允许选择目录（某些 IPA 可能在包内）
            picker.allowsMultipleSelection = false
            self.present(picker, animated: true)
        }
    }
}

// MARK: - UIDocumentPickerDelegate

extension IPADocumentPicker.PickerHostController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            LogManager.shared.info("用户选择了文件: \(url.lastPathComponent)", source: "AppsView")
            onPick?(url)
        }
        onDismiss?()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        LogManager.shared.info("用户取消了文件选择", source: "AppsView")
        onDismiss?()
    }
}

// MARK: - 已安装应用列表

struct AppsView: View {
    @StateObject private var viewModel = SigningViewModel()
    @ObservedObject private var account = BridgeClient.shared
    @State private var showingFileImporter = false
    @State private var pendingUninstall: InstalledApp?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 应用列表（有应用时）或空状态（无应用时）
                if viewModel.installedApps.isEmpty {
                    emptyState
                } else {
                    appList
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
