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

    /// 清单 18 补齐：point(inside:) 透传若无 hitTest 转发，扩区点按只会落到
    /// flow 视图自身（chip 为普通 UIView，扩区点在其 bounds 外，默认 hitTest
    /// 认不到钮），边缘点按仍是死区。此处把命中扩后热区的钮直接返回；
    /// 多钮同时命中（行距 8 时上下行扩区在行间重叠）时按中心最近者胜
    /// （欧氏距离；操作行栈同款意图，流式行排取二维距离）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }
        var claimants: [UIButton] = []
        collectClaimingButtons(in: self, point: point, event: event, into: &claimants)
        if claimants.count >= 2 {
            var best: UIButton?
            var bestDistance: CGFloat = .greatestFiniteMagnitude
            for button in claimants {
                let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
                let dx = center.x - point.x
                let dy = center.y - point.y
                let distance = dx * dx + dy * dy
                if distance < bestDistance {
                    bestDistance = distance
                    best = button
                }
            }
            return best
        }
        if claimants.count == 1 {
            return claimants[0]
        }
        return super.hitTest(point, with: event)
    }

    /// 递归收集扩后热区命中该点的 UIButton 子孙（隐藏／不可交互／透明者不算，
    /// 与 UIKit hitTest 的可达条件一致；isEnabled 不参与判定，禁用钮仍占位吞点，
    /// 与现行行为一致）。操作行栈同款。
    private func collectClaimingButtons(in view: UIView, point: CGPoint, event: UIEvent?, into out: inout [UIButton]) {
        for sub in view.subviews {
            guard sub.isHidden == false, sub.alpha >= 0.01, sub.isUserInteractionEnabled else { continue }
            if let button = sub as? UIButton {
                let local = sub.convert(point, from: self)
                if button.point(inside: local, with: event) {
                    out.append(button)
                }
            }
            collectClaimingButtons(in: sub, point: point, event: event, into: &out)
        }
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

// MARK: - 清单 18：回应行中间容器透传栈

/// cell 与详情共用的 rightStack（内容列与 emoteFlowView 之间的垂直栈）
/// 改用此类：回应行末行 chip 的扩后热区（上下各 6pt）会伸出 flow 视图、
/// 乃至伸出 rightStack 下沿——普通 UIStackView 会在栈 bounds 外直接截掉，
/// 边缘点按到不了 flow。此处 point(inside:)/hitTest 只对 passThroughRoot
/// （即 emoteFlowView）内 UIButton 子孙的扩后热区放行并直返该钮，栈内
/// 其他行（标题／操作行／折叠等）一律走默认路径、行为一字不动。
/// 行距仅 8–10pt 时上下行扩区在行间重叠，误触邻行可能为拍板接受；
/// 多钮同时命中时按中心最近者胜（欧氏距离）。
final class BearyPassThroughStackView: UIStackView {

    /// 透传根：只认该根内 UIButton 子孙的扩后热区，调用方设为 emoteFlowView。
    weak var passThroughRoot: UIView?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) {
            return true
        }
        guard let root = passThroughRoot else { return false }
        return hitExpandedButton(in: root, point: point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }
        guard let root = passThroughRoot else { return super.hitTest(point, with: event) }
        var claimants: [UIButton] = []
        collectClaimingButtons(in: root, point: point, event: event, into: &claimants)
        if claimants.count >= 2 {
            var best: UIButton?
            var bestDistance: CGFloat = .greatestFiniteMagnitude
            for button in claimants {
                let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
                let dx = center.x - point.x
                let dy = center.y - point.y
                let distance = dx * dx + dy * dy
                if distance < bestDistance {
                    bestDistance = distance
                    best = button
                }
            }
            return best
        }
        if claimants.count == 1 {
            return claimants[0]
        }
        return super.hitTest(point, with: event)
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
            if hitExpandedButton(in: sub, point: point) {
                return true
            }
        }
        return false
    }

    /// 递归收集透传根内扩后热区命中该点的 UIButton 子孙（隐藏／不可交互／
    /// 透明者不算，与 UIKit hitTest 的可达条件一致；isEnabled 不参与判定，
    /// 禁用钮仍占位吞点，与现行行为一致）。
    private func collectClaimingButtons(in view: UIView, point: CGPoint, event: UIEvent?, into out: inout [UIButton]) {
        for sub in view.subviews {
            guard sub.isHidden == false, sub.alpha >= 0.01, sub.isUserInteractionEnabled else { continue }
            if let button = sub as? UIButton {
                let local = sub.convert(point, from: self)
                if button.point(inside: local, with: event) {
                    out.append(button)
                }
            }
            collectClaimingButtons(in: sub, point: point, event: event, into: &out)
        }
    }
}
