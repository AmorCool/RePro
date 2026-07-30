import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 初始化日志系统
        LogManager.shared.initialize()
        LogManager.shared.info("RePro 启动", source: "AppDelegate")

        // 检测越狱环境
        let jbType = JailbreakDetect.current()
        LogManager.shared.info("越狱环境: \(jbType.rawValue)", source: "AppDelegate")

        return true
    }
}
