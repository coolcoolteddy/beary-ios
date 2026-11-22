import UIKit

/// 日记分享共享入口：有效公开门控 → 拼链 → 正文空白折叠 → 组 items →
/// 有弹窗时复制链接兜底 → 失败时复制链接 → iPad popover 锚点。
/// 详情／广场／个人页三处共用；锚点与占用态 toast 文案作参数。
/// 拼链一律走 BearyRoute.webURL，不再手拼 https://teddyhn.com/beary/d/。
enum BearyDiaryShare {

    /// iPad popover 锚点。permittedArrowDirections 为 nil 时不改系统默认方向。
    struct Anchor {
        let sourceView: UIView
        let sourceRect: CGRect
        let permittedArrowDirections: UIPopoverArrowDirection?

        init(sourceView: UIView, sourceRect: CGRect, permittedArrowDirections: UIPopoverArrowDirection? = nil) {
            self.sourceView = sourceView
            self.sourceRect = sourceRect
            self.permittedArrowDirections = permittedArrowDirections
        }

        /// 锚在 view 中心（详情／个人页同款）。
        static func centered(in view: UIView, permittedArrowDirections: UIPopoverArrowDirection? = nil) -> Anchor {
            Anchor(
                sourceView: view,
                sourceRect: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0),
                permittedArrowDirections: permittedArrowDirections
            )
        }
    }

    /// 分享一篇日记。有效公开门控不过（私密／限时已到期按私密算）直接 return，
    /// 不交出正文与链接。返回 true 表示已弹出分享 sheet 或已走复制兜底。
    @discardableResult
    static func present(entry: Entry, from viewController: UIViewController, anchor: Anchor, occupiedMessage: String) -> Bool {
        guard BearyEphemeral.isEffectivelyPublic(entry) else { return false }
        guard let entryId = entry.id, !entryId.isEmpty,
              let url = BearyRoute.entry(entryId).webURL else { return false }
        let shareText = (entry.content ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var items: [Any] = ["beary 日记"]
        if !shareText.isEmpty {
            items.append(String(shareText.prefix(60)))
        }
        items.append(url)
        if viewController.presentedViewController != nil {
            UIPasteboard.general.string = url.absoluteString
            BearyToast.show(in: viewController.view, message: occupiedMessage)
            return true
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak viewController] _, completed, _, error in
            if completed == false, error != nil {
                UIPasteboard.general.string = url.absoluteString
                if let viewController = viewController {
                    BearyToast.show(in: viewController.view, message: "链接已复制")
                }
            }
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = anchor.sourceView
            popover.sourceRect = anchor.sourceRect
            if let directions = anchor.permittedArrowDirections {
                popover.permittedArrowDirections = directions
            }
        }
        viewController.present(activity, animated: BearyMotion.animated(true), completion: nil)
        return true
    }
}
