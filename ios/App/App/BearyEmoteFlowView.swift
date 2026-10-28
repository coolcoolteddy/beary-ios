import UIKit

// ===== BearyEmoteFlowView 回应行流式布局（B 批卡片合并）=====
// 来源：首页 BearyFeedCell 内的 BearyFeedEmoteFlowView（网页 .emote-row 口径：
// gap 8、自动换行），个人主页的单行横滑 emoteScrollView 已废弃，两页回应流
// 统一走本视图。合并时新增一点：point(inside:) 透传——回应 chip 的点击层与
// + 钮已升级为 BearyHit44Button（热区扩到 44），而 flow 视图本身只有 32–34 高，
// 若不透传，扩出去的热区会被 flow 视图的 hitTest 截掉；本透传只认 UIButton
// 子孙（chip 内层透明钮、+ 钮），不改变任何视觉尺寸与布局。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

final class BearyEmoteFlowView: UIView {

    var itemSpacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    /// 唯一换行布局算法（5-18）：height(forWidth:) 与 layoutSubviews 同调此处。
    /// gap（itemSpacing / lineSpacing）、最小高 32、换行条件只在此一处定义，
    /// 任一处改口径即两处同步，行高与实测不再错位。applyFrames 为 false 时
    /// 只算总高不写 frame（供 height(forWidth:) 用），为 true 时落位子视图。
    private func layoutItems(forWidth width: CGFloat, applyFrames: Bool) -> CGFloat {
        if width <= 0 {
            return 0
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var firstInRow = true
        for sub in subviews {
            if sub.isHidden { continue }
            let size = sub.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let itemWidth = size.width
            let itemHeight = max(size.height, 32)
            if firstInRow == false && x + itemSpacing + itemWidth > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
                firstInRow = true
            }
            if firstInRow == false {
                x += itemSpacing
            }
            if applyFrames {
                sub.frame = CGRect(x: x, y: y, width: itemWidth, height: itemHeight)
            }
            x += itemWidth
            rowHeight = max(rowHeight, itemHeight)
            firstInRow = false
        }
        return y + rowHeight
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if width <= 0 || subviews.isEmpty {
            return 0
        }
        return self.layoutItems(forWidth: width, applyFrames: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = self.layoutItems(forWidth: bounds.width, applyFrames: true)
    }

    /// 热区透传：点落在自身 bounds 内照常；落在外时只当它命中了某个
    /// UIButton 子孙的扩后热区（BearyHit44Button 的 point(inside:) 已扩到 44）
    /// 才放行，否则仍返回 false，不吞邻行触摸。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) {
            return true
        }
        for sub in subviews {
            if self.hitExpandedButton(in: sub, point: point) {
                return true
            }
        }
        return false
    }

    private func hitExpandedButton(in view: UIView, point: CGPoint) -> Bool {
        if view.isHidden {
            return false
        }
        if let button = view as? UIButton {
            let local = view.convert(point, from: self)
            if button.point(inside: local, with: nil) {
                return true
            }
        }
        for sub in view.subviews {
            if self.hitExpandedButton(in: sub, point: point) {
                return true
            }
        }
        return false
    }
}
