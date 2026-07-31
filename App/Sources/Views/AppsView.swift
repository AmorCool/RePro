import SwiftUI
import UniformTypeIdentifiers

// MARK: - UIDocumentPicker 包装器（open 模式，解决 .fileImporter copy 模式下第三方文件被静默忽略的问题）
//
// 原版 RPVInstalledViewController.m:1163-1197 明确指出：
//   "在 copy 模式下，点击会被静默忽略（长按却仍然有效）"
// SwiftUI 的 .fileImporter 无法控制 asCopy 参数，因此必须手写 UIViewControllerRepresentable。

struct IPADocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = []
        if let ipaType = UTType(filenameExtension: "ipa") {
            types.append(ipaType)
        }
        // 原版还声明了自定义 UTI jp.soh.reprovision.ipa，这里用动态类型兜底
        types.append(.archive)
        types.append(.item)

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            LogManager.shared.info("用户取消了文件选择", source: "AppsView")
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
            ZStack {
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
                    }
                    .disabled(viewModel.isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
            .fullScreenCover(isPresented: $showingFileImporter) {
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

            // 已注册 AppIDs 入口（原版在 Installed tab 内的标签）
            if account.isSignedIn {
                Section {
                    NavigationLink(destination: AppIDsView()) {
                        HStack(spacing: 10) {
                            Image(systemName: "number")
                                .foregroundColor(.blue)
                            Text("已注册 App IDs")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("开发者账号")
                } footer: {
                    Text("查看当前 Apple 开发者账号下已注册的应用标识符及其过期时间")
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
