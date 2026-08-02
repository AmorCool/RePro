import SwiftUI

// MARK: - iOS 26 风格液态玻璃浮动底栏
//
// 视觉参考用户给的图二：浮动圆角胶囊 + 毛玻璃模糊 + 选中项蓝色高亮 + 微光边框。
// 不依赖任何私有 API，纯 SwiftUI 实现。点击由外层系统 TabView 原生接管，
// 本组件只负责外观与写入 selectedTab 绑定。

struct LiquidGlassTabBar: View {
    @Binding var selectedTab: Int

    private let tabs: [(icon: String, label: String)] = [
        ("square.stack.3d.up", "应用"),
        ("gearshape",        "设置"),
        ("doc.text",         "日志"),
        ("heart.text.square","状态"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { index in
                let tab = tabs[index]
                let isSelected = selectedTab == index
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
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
                    .padding(.vertical, 6)
                    .foregroundColor(isSelected ? .white : .secondary)
                    // 选中项蓝色高亮胶囊（图二风格）
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.blue : Color.clear)
                            .animation(.easeInOut(duration: 0.2), value: isSelected)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle()) // 保证整块点击热区
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
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
                            Color.white.opacity(0.5),
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.3),
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
                            Color.white.opacity(0.18),
                            Color.white.opacity(0),
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        )
        // 柔和阴影（浮动感）
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }
}
