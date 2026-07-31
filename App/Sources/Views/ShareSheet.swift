import SwiftUI
import UIKit

// MARK: - 系统分享面板（直接 UIKit 呈现，绕开 SwiftUI .sheet 白屏）
//
// UIActivityViewController 不能放在 SwiftUI .sheet 里使用（首次弹出时 view 未挂载
// 到 window → 白屏；返回再进因状态就绪才正常）。
// 本文件仅保留一个便捷静态方法，直接从 keyWindow 的 rootVC 呈现，
// 彻底规避 SwiftUI sheet 时序问题。

enum SharePresenter {

    /// 从当前 keyWindow 的顶层 VC 呈现分享面板。
    /// 这是 iOS 上展示 UIActivityViewController 唯一可靠的方式。
    static func share(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              var topVC = window.rootViewController else {
            return
        }

        // 找到最顶层的 presented VC（避免被已有 modal 遮挡）
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let ac = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        // iPad 必须设置 sourceView，否则 crash
        if let popover = ac.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        topVC.present(ac, animated: true)
    }
}
