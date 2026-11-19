import UIKit

// ===== 登录底 sheet 弹窗（Li 2026-11-02 批准施工：整页登录改弹窗）=====
// 形态：系统底部 sheet（UISheetPresentationController，见 BearySystemSheet）
// ＋登录页内容（BearyLoginViewController.sheetMode = true）。
// 2026-11-20 移植：旧自研容器与登录专用的玻璃 chrome 条
// （BearyLoginSheetPresentationController，顶栏同款液态玻璃）一并退役——
// 玻璃是 Li 批的唯一例外，随容器退役后改实色 surface3（BearyLoginViewController
// viewDidLoad 里 sheetMode 时取 surface3）；高度跟内容走（登录页
// preferredContentSize）、宽：<821 全宽，≥821 居中 600（与 App 内容列同口径）。
// 关闭语义：登录页在 viewWillAppear（sheetMode 时）把自己挂为
// presentationController.delegate；抓手下滑与点外收起都先问 delegate，
// shouldDismiss 返回 false、didAttemptToDismiss 调 cancelFromSheet（= 关闭钮
// 路径，先停倒计时与在途任务、再交 onCancelled），系统 sheet 不得绕开它直接
// dismiss，否则添加账号会话守卫 stays armed。
// 容器：BearyLoginSheet.make() 只建 sheet 模式登录页、不 present；调用点按原样
// 接回调后再 present（与原整页顺序一致，含 dismiss 调用方与会话守卫）。
// 键盘：登录页自带 inset 处理（keyboardWillShow 垫 scrollView.contentInset.bottom
// ＋把输入框滚到键盘上方），系统 sheet 不跟键盘，页内滚动 inset 已处理遮挡。

enum BearyLoginSheet {
    /// 建一个 sheet 模式登录页（BearyLoginViewController.sheetMode = true），
    /// 不 present；调用点接完回调后自行 present。
    static func make() -> BearyLoginViewController {
        let vc = BearyLoginViewController()
        vc.sheetMode = true
        // 2026-11-04：进场前先算一次内容高，首帧不用 666 回退高、随后不再大跳变；
        // 安全区此时未进窗口为 0，落窗后 viewDidLayoutSubviews 按真实安全区跟帧补齐。
        vc.loadViewIfNeeded()
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        // sheet 宽：屏宽 ≥821 取 min(600, 屏宽-32)，否则全宽；落窗后
        // viewDidLayoutSubviews 按实测 sheet 宽跟帧补齐。
        let screenWidth = UIScreen.main.bounds.width
        let sheetWidth: CGFloat = screenWidth >= 821 ? min(600, screenWidth - 32) : screenWidth
        vc.preferredContentSize.width = sheetWidth
        BearySystemSheet.configure(vc)
        return vc
    }
}
