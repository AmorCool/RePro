import SwiftUI
import UIKit

// MARK: - 系统分享面板封装（UIViewControllerRepresentable）
//
// 注意：UIActivityViewController 设计为「被直接 present」的视图控制器，不能直接当成
// SwiftUI .sheet 的内容 VC（否则首次弹出时其 view 尚未挂载到 window，会在 iPhone 上
// 出现白屏；返回再进因状态就绪才正常）。
// 这里用一个透明容器 VC 承载，待其 view 已挂到 window 后（updateUIViewController 中
// 以 view.window != nil 为守卫）再 present 分享面板，规避首次白屏。

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // 防止重复 present；且必须等 view 已挂载到 window 之后再 present，
        // 否则 UIActivityViewController 在首次弹出时会白屏。
        guard uiViewController.presentedViewController == nil,
              uiViewController.view.window != nil else { return }

        let activityController = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        activityController.excludedActivityTypes = excludedActivityTypes
        // iPhone 上 UIActivityViewController 必须以 pageSheet/fullScreen 呈现，避免尺寸异常白屏
        activityController.modalPresentationStyle = .pageSheet
        uiViewController.present(activityController, animated: true)
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        if uiViewController.presentedViewController != nil {
            uiViewController.dismiss(animated: false)
        }
    }
}
