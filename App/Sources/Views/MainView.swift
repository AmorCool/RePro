import SwiftUI

// MARK: - 主界面：TabView 四个标签页

struct MainView: View {
    @ObservedObject private var resign = ResignProgress.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            if resign.isResigning {
                resignBanner
            }
            TabView(selection: $selectedTab) {
                AppsView()
                    .tabItem {
                        Image(systemName: "square.stack.3d.up")
                        Text("应用")
                    }
                    .tag(0)

                SettingsView()
                    .tabItem {
                        Image(systemName: "gearshape")
                        Text("设置")
                    }
                    .tag(1)

                LogView()
                    .tabItem {
                        Image(systemName: "doc.text")
                        Text("日志")
                    }
                    .tag(2)

                HealthView()
                    .tabItem {
                        Image(systemName: "heart.text.square")
                        Text("状态")
                    }
                    .tag(3)
            }
        }
        .accentColor(.blue)
    }

    /// 续签进行中横幅：明确告知用户这是 daemon 后台自动续签、无需操作，
    /// 避免被误判为 BUG / 卡死 / 白屏。
    private var resignBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(resign.title)
                    .font(.subheadline.weight(.semibold))
                Text(resign.message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemOrange).opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
