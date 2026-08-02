import SwiftUI
import UniformTypeIdentifiers

// MARK: - 原生文件选择器（无 SwiftUI sheet 中间层）

/// 直接从 root VC present UIDocumentPickerViewController，无需 sheet 包裹
private final class IPAFilePicker: NSObject, UIDocumentPickerDelegate {
    private let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

    func present() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }

        // 用 open 模式 (asCopy: false) 而非 copy/import 模式。
        // iCloud 云盘 / 第三方 File Provider 的文件在 copy 模式下常返回 .icloud 占位符或复制失败，
        // 导致「无法读取这个 .ipa」。open 模式给的是带安全域的真实 URL，下方
        // RPVIpaBundleApplication 的 NSFileCoordinator 协调读取会触发 iCloud 下载，从而正确导入。
        // （test2/reborn 参考实现均使用 asCopy: NO，原因见 RPVInstalledViewController 注释。）
        var types: [UTType] = []
        if let ipa = UTType(filenameExtension: "ipa") { types.append(ipa) }
        types.append(.archive)
        types.append(.data)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        top.present(picker, animated: true)

        // 强引用自己，防止 delegate 回调前被释放
        objc_setAssociatedObject(picker, "keeper", self, .OBJC_ASSOCIATION_RETAIN)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            LogManager.shared.info("用户选择了文件: \(url.lastPathComponent)", source: "AppsView")
            onPick(url)
        }
        controller.dismiss(animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
    }
}

// MARK: - 已安装应用列表

struct AppsView: View {
    @StateObject private var viewModel = SigningViewModel()
    @ObservedObject private var account = BridgeClient.shared
    @State private var pendingUninstall: InstalledApp?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
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
                        viewModel.resignAllApplications()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.isBusy || !account.isSignedIn)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openFilePicker()
                    } label: {
                        Image(systemName: "plus")
                        Text("导入")
                    }
                    .disabled(viewModel.isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
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

    // MARK: 打开文件选择器
    private func openFilePicker() {
        let picker = IPAFilePicker { url in
            viewModel.importIPA(url: url)
        }
        picker.present()
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
                openFilePicker()
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
