import SwiftUI

// MARK: - 主界面：自定义四标签容器 + 液态玻璃浮动底栏
//
// 架构决策（v1.1.80 最终方案）：
// - 彻底不用 TabView、不用 overlay——底栏作为 VStack 的真实子视图放在最底部。
//   这是 iOS SwiftUI 中保证自定义底栏可点击的最可靠方式：
//   TabView 无 tabItem → 空系统 bar 拦截（v1.1.78）；overlay+zIndex → NavigationView 手势穿透拦截（v1.1.79）。
//   只有 VStack 真实子视图能保证触摸事件不被上层视图劫持。

struct MainView: View {
    @ObservedObject private var resign = ResignProgress.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // 续签横幅（顶部固定）
            if resign.isResigning {
                resignBanner
            }

            // 内容区：按 selectedTab 切换，占满剩余空间
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

            // 液态玻璃浮动底栏（VStack 真实子视图，保证可点击）
            LiquidGlassTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .accentColor(.blue)
        .background(Color(.systemGroupedBackground)) // 整体背景与列表一致，避免断层
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
