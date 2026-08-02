import SwiftUI

// MARK: - 主界面：自定义四标签容器 + 液态玻璃浮动底栏
//
// 注意：之前用 TabView（无 .tabItem）会在底部渲染一个空的系统 tab bar，
// 盖在自定义底栏上方拦截触摸，导致底栏按钮点不动。这里改为自定义容器：
// 用 selectedTab 直接切换内容，液态玻璃栏是普通 VStack 子视图，保证可点击。

struct MainView: View {
    @ObservedObject private var resign = ResignProgress.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            if resign.isResigning {
                resignBanner
            }

            // 内容区：按 selectedTab 切换视图（四个视图互斥挂载，避免隐藏 sheet 问题）
            ZStack {
                switch selectedTab {
                case 0: AppsView()
                case 1: SettingsView()
                case 2: LogView()
                case 3: HealthView()
                default: AppsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: selectedTab)

            // 液态玻璃浮动底栏（普通 VStack 子视图，保证可点击，不依赖系统 TabView）
            LiquidGlassTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
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
