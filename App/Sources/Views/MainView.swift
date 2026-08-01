import SwiftUI

// MARK: - 主界面：TabView 四个标签页

struct MainView: View {
    @State private var selectedTab = 0

    var body: some View {
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
        .accentColor(.blue)
        .onOpenURL { url in
            if url.scheme == "reprovision", url.host == "refresh" {
                _ = AppDelegate.sharedSilentResign()
            }
        }
    }
}
