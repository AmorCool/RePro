import SwiftUI

@main
struct ReProApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var isSilentResign = false

    var body: some Scene {
        WindowGroup {
            if isSilentResign {
                Color.clear
                    .onAppear {
                        // UI 不渲染，直接执行静默续签
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            _ = AppDelegate.sharedSilentResign()
                        }
                    }
            } else {
                MainView()
            }
        }
        .onOpenURL { url in
            if url.scheme == "reprovision", url.host == "refresh" {
                isSilentResign = true
            }
        }
    }
}
