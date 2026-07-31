import SwiftUI

// MARK: - 证书管理视图
//
// 数据来自 Apple Developer API（certificates 端点），
// 通过 RPVBridge → EEAppleServices 拉取。
// 原版位置：Troubleshooting tab → Manage Certificates。
// 功能：列表显示、撤销单个/全部证书、显示/隐藏无关证书切换。

struct CertificatesView: View {
    @ObservedObject private var account = BridgeClient.shared
    @State private var certificates: [DevCertificate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingRevokeAllAlert = false
    @State private var revokingID: String? = nil
    @State private var revokeError: String?
    /// 单个证书撤销确认弹窗
    @State private var pendingRevokeCert: DevCertificate?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("正在拉取证书列表…")
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
                    Button("重试") { loadCertificates() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else if certificates.isEmpty && !isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "lock.shield")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("暂无开发证书")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    if account.isSignedIn {
                        Text("当前账号下没有活跃的开发证书\n如需签名应用，系统将自动创建新证书")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("登录后可查看和管理 Apple 开发者账号下的签名证书")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Section {
                    ForEach(certificates) { cert in
                        CertificateRowView(
                            cert: cert,
                            isRevoking: revokingID == cert.id,
                            onRevoke: { pendingRevokeCert = cert }
                        )
                    }

                    // 免费账号限制提示（与原版一致）
                    if !certificates.isEmpty {
                        Section(footer: footerText) {}
                    }
                }

                // 操作按钮区
                Section {
                    Button(role: .destructive) {
                        showingRevokeAllAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("撤销所有证书")
                            Spacer()
                        }
                    }
                    .disabled(isLoading || certificates.isEmpty || revokingID != nil)
                    .foregroundColor(.red)
                } header: {
                    Text("证书操作")
                } footer: {
                    Text("撤销后需要重新签名应用才能继续使用。免费账号最多同时拥有 2 个活跃的开发证书。")
                }
            }
        }
        .navigationTitle("证书管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: loadCertificates) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || !account.isSignedIn)
            }
        }
        .onAppear { if certificates.isEmpty { loadCertificates() } }
        .alert("确认撤销所有证书", isPresented: $showingRevokeAllAlert) {
            Button("取消", role: .cancel) {}
            Button("撤销全部", role: .destructive) { revokeAllCertificates() }
        } message: {
            Text("此操作将撤销所有 \(certificates.count) 个开发证书，已签名的应用将无法启动。确定要继续吗？")
        }
        .alert("撤销失败", isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } })) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(revokeError ?? "")
        }
        .confirmationDialog("确认撤销证书", isPresented: Binding(get: { pendingRevokeCert != nil }, set: { if !$0 { pendingRevokeCert = nil } }), titleVisibility: .visible) {
            Button("撤销证书", role: .destructive) {
                if let cert = pendingRevokeCert {
                    revokeCertificate(cert)
                }
                pendingRevokeCert = nil
            }
            Button("取消", role: .cancel) { pendingRevokeCert = nil }
        } message: {
            if let cert = pendingRevokeCert {
                Text("确定要撤销「\(cert.machineName)」的签名证书吗？\n使用该证书签名的应用将无法启动。")
            } else {
                Text("")
            }
        }
    }

    // MARK: - 页脚说明

    private var footerText: some View {
        Text("免费 Apple 账号最多可同时拥有 2 个活跃的开发证书。\n如需安装更多应用，请先撤销不需要的证书或使用付费开发者账号。")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: - 数据加载

    private func loadCertificates() {
        guard account.isSignedIn else {
            errorMessage = "请先登录 Apple ID"
            return
        }
        isLoading = true
        errorMessage = nil
        account.fetchCertificates { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let certs):
                    self.certificates = certs
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 撤销操作

    private func revokeCertificate(_ cert: DevCertificate) {
        revokingID = cert.id
        account.revokeCertificate(id: cert.id) { result in
            DispatchQueue.main.async {
                self.revokingID = nil
                switch result {
                case .success:
                    // 从本地列表移除（乐观更新，避免重新拉取延迟）
                    self.certificates.removeAll { $0.id == cert.id }
                    LogManager.shared.info("已撤销证书: \(cert.machineName)", source: "CertificatesView")
                case .failure(let error):
                    self.revokeError = "撤销失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func revokeAllCertificates() {
        guard !certificates.isEmpty else { return }
        isLoading = true
        account.revokeAllCertificates { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success:
                    self.certificates.removeAll()
                    LogManager.shared.info("已撤销所有证书", source: "CertificatesView")
                case .failure(let error):
                    self.revokeError = "批量撤销失败: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 单行证书

private struct CertificateRowView: View {
    let cert: DevCertificate
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("设备: \(cert.machineName)")
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text("来源: \(cert.applicationName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(cert.serialNumber.prefix(16) + "…")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            if isRevoking {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button(action: onRevoke) {
                    VStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                        Text("撤销")
                            .font(.caption2)
                    }
                    .foregroundColor(.red)
                    .padding(6)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
                }
                .padding(.leading, 8)
            }
        }
        .padding(.vertical, 6)
    }
}
