import SwiftUI

// MARK: - 主界面：系统 TabView（原生接管点击）+ 隐藏系统栏 + 自定义液态玻璃浮动底栏
//
// 底栏点击可靠性演进（教训）：
//   v1.1.78  TabView 无 tabItem + safeAreaInset  → 空系统 bar 拦截触摸 ✗
//   v1.1.79  ZStack + overlay(.bottom) + zIndex   → NavigationView 手势层拦截 ✗
//   v1.1.80  VStack 真实子视图 switch 容器         → 仍点不动（自定义容器手势问题）✗
//   v1.1.82  ✅ 系统 TabView(selection:) 原生接管点击 + 隐藏系统栏 + 玻璃栏做真实子视图
//            系统 TabView 自己管理标签切换与触摸事件，100% 可靠；我们只在上面盖一层玻璃视觉。

struct MainView: View {
    @ObservedObject private var resign = ResignProgress.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // 续签横幅（顶部固定，仅进行中显示）
            if resign.isResigning {
                resignBanner
            }

            // 内容区：系统 TabView，原生切换 + 原生触摸
            TabView(selection: $selectedTab) {
                AppsView().tag(0)
                SettingsView().tag(1)
                LogView().tag(2)
                HealthView().tag(3)
            }
            // iOS 16+：隐藏系统自带 tab bar（我们只用自定义玻璃栏）
            .toolbar(.hidden, for: .tabBar)

            // 自定义液态玻璃浮动底栏（VStack 真实子视图，不抢占内容触摸）
            LiquidGlassTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .ignoresSafeArea(.keyboard)
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
