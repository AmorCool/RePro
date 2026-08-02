import SwiftUI

// MARK: - 主界面：自定义四标签容器 + 液态玻璃浮动底栏
//
// 架构决策：
// - 不用 TabView（无 tabItem 时系统空 bar 拦截触摸，v1.1.78 已证实）
// - 底栏用 .overlay(alignment:.bottom) + zIndex(100) 挂在最顶层，确保不被内容区遮挡
// - 内容区加 .padding(.bottom, tabBarHeight) 避免列表内容被底栏盖住

struct MainView: View {
    @ObservedObject private var resign = ResignProgress.shared
    @State private var selectedTab = 0

    /// 底栏高度（含 padding）
    private let tabBarHeight: CGFloat = 70

    var body: some View {
        ZStack(alignment: .bottom) {
            // 内容区：按 selectedTab 切换，底部留出底栏空间
            Group {
                switch selectedTab {
                case 0: AppsView()
                case 1: SettingsView()
                case 2: LogView()
                case 3: HealthView()
                default: AppsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 液态玻璃浮动底栏——用 overlay + 高 zIndex 确保始终在最顶层可点击
            LiquidGlassTabBar(selectedTab: $selectedTab)
                .padding(.bottom, 8)
                .zIndex(100)
        }
        .accentColor(.blue)
        .overlay(alignment: .top) {
            if resign.isResigning {
                resignBanner
            }
        }
    }

    /// 续签进行中横幅
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
