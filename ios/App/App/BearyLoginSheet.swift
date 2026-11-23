import UIKit

// ===== 登录全页（2026-11-16：底 sheet 弹窗改全页，Li 已点头，按登录页预览做）=====
// 形态：全屏 modal（modalPresentationStyle = .fullScreen），不再是底部弹窗；
// BearyLoginSheetPresentationController（底 sheet 玻璃 chrome＋键盘跟随）已随旧形态删除。
// 容器：BearyLoginSheet.make() 只建全页登录页、不 present；调用点按原样接回调后再 present
//（与旧 sheet 顺序一致，含 dismiss 调用方与会话守卫；关闭只关登录页自身）。
// 名字保留 BearyLoginSheet.make()：全部调用点（设置页、个人页、盲盒、私信、回收站、
// 许愿墙、SceneDelegate、引导页）一字不动即走新全页，不留两套登录入口。

enum BearyLoginSheet {
    /// 建一个全页登录页（BearyLoginViewController，全屏 modal），不 present；
    /// 调用点接完回调后自行 present。
    static func make() -> BearyLoginViewController {
        let vc = BearyLoginViewController()
        vc.modalPresentationStyle = .fullScreen
        // 展示审计 G7-08：补左边缘右滑返回，与 × 关闭走同一退出流程
        //（停倒计时、清任务、调 onCancelled；容器负责 dismiss）。
        // EdgeDismiss 的 transitioningDelegate 是弱引用，控制器须由本页强持有。
        // 设了 delegate 后 present 动画由默认上滑改成自右滑入，与其他全屏页一致。
        let edgeDismiss = BearyEdgeDismissController()
        edgeDismiss.attach(to: vc)
        edgeDismiss.onEdgeSwipeCompleted = { [weak vc] in
            guard let vc = vc else { return false }
            return vc.handleEdgeSwipeClose()
        }
        vc.transitioningDelegate = edgeDismiss
        vc.edgeDismiss = edgeDismiss
        return vc
    }
}
