import SwiftUI

// MARK: - 主界面：TabView 四个标签页 + 液态玻璃浮动底栏

struct MainView: View {
    @ObservedObject private var resign = ResignProgress.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            if resign.isResigning {
                resignBanner
            }
            ZStack {
                // 隐藏原生 TabBar，用 safeAreaInset 自定义浮动底栏替代
                TabView(selection: $selectedTab) {
                    AppsView()
                        .tag(0)

                    SettingsView()
                        .tag(1)

                    LogView()
                        .tag(2)

                    HealthView()
                        .tag(3)
                }
                .animation(.easeInOut(duration: 0.25), value: selectedTab)
                // 隐藏系统 TabBar（我们用自己的液态玻璃底栏）
                // iOS 16+ API 不可用，改用 onAppear UIKit 方式隐藏
                .onAppear { hideSystemTabBar() }
            }
        }
        .accentColor(.blue)
        // 液态玻璃浮动 TabBar：固定在底部安全区域上方
        .safeAreaInset(edge: .bottom) {
            LiquidGlassTabBar(selectedTab: $selectedTab)
                .padding(.bottom, 6)
        }
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

    // MARK: 隐藏系统 TabBar（iOS 15 兼容）
    private func hideSystemTabBar() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                findAndHideTabBar(in: rootVC)
            }
        }
    }

    private func findAndHideTabBar(in vc: UIViewController) {
        if let tabBarController = vc as? UITabBarController {
            tabBarController.tabBar.isHidden = true
            return
        }
        for child in vc.children {
            findAndHideTabBar(in: child)
        }
    }
}
