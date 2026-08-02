import SwiftUI

// MARK: - iOS 26 风格液态玻璃浮动底栏

/// 模拟 iOS 26 液态玻璃（Liquid Glass）风格的自定义 TabBar。
/// 不依赖任何私有 API，纯 SwiftUI 实现：毛玻璃模糊 + 浮动圆角胶囊 + 微光边框 + 选中动画。
struct LiquidGlassTabBar: View {
    @Binding var selectedTab: Int

    private let tabs: [(icon: String, label: String)] = [
        ("square.stack.3d.up", "应用"),
        ("gearshape",       "设置"),
        ("doc.text",        "日志"),
        ("heart.text.square","状态"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { index in
                let tab = tabs[index]
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = index
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(tab.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(selectedTab == index ? .blue : .secondary)
                    .opacity(selectedTab == index ? 1 : 0.6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        // 液态玻璃核心：超薄材质 + 模糊
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        // 微光边框（模拟玻璃折射）
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.4),
                            Color.white.opacity(0.1),
                            Color.white.opacity(0.25),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        // 内部高光（顶部反光条）
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0),
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        )
        // 柔和阴影（浮动感）
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .padding(.horizontal, 16)
    }
}
