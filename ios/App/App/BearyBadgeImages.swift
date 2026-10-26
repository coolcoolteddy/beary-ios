import UIKit

/// 网页版作者行徽章的原生图片入口。
///
/// 图片来源：网页版 `badgeUrl`（`img.teddyhn.com/badges/v5/<key>-static.svg`，
/// 作者行只用静态版；个人主页佩戴态用的 `-animated.svg` 是 CSS 动画版，
/// 静态 PNG 无法承载动画，故作者行不打包动画版）。
/// 编译期经 cairosvg 渲染为 PNG，打包进 Assets.xcassets：`badge_<key>`，
/// 每套含 @1x 17px / @2x 34px / @3x 51px 三档（与卡片 `.card-bdg` 17×17、
/// 皇冠 `crown.imageset` 19/38/57 同款管线）。
/// 徽章是多彩图（BETA 为 19 色像素立体字），走全彩 PNG：调用方直接用图，
/// 不加 template 意图、不 tint（与 `BearyIconImages` 的 alwaysTemplate 路线相反）。
/// 注意：pbxproj 注册由总协调统一做，本文件只提供图片解析。
enum BearyBadgeImages {
    /// 按服务端 `authorBadge` 的 key 取图；无对应资产时返回 nil，
    /// 调用方须隐藏徽章位、绝不留空位。
    static func image(for key: String) -> UIImage? {
        guard !key.isEmpty else { return nil }
        return UIImage(named: "badge_" + key)
    }

    /// I8：取不到图时不静默消失——返回中性占位图并打一条日志。
    /// 占位图是代码现绘的 17×17 问号（非官方资产，仅作“图缺失”的可见标记，
    /// 与卡片徽章位 17×17 同口径）；底色/问号色走 BearyColors 动态色，
    /// 随深浅自适应，不再是固定浅灰块；
    /// 新徽章资产与 key 同步上架仍是上架流程项，代码侧只保证不留空白。
    static func imageOrPlaceholder(for key: String) -> UIImage? {
        if let found = image(for: key) {
            return found
        }
        guard !key.isEmpty else { return nil }
        NSLog("[BearyBadgeImages] missing badge asset for key: %@", key)
        let size = CGSize(width: 17, height: 17)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
            BearyColors.faint.setFill()
            path.fill()
            let question = "?"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 10),
                .foregroundColor: BearyColors.gray,
            ]
            let textSize = question.size(withAttributes: attributes)
            let origin = CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2)
            question.draw(at: origin, withAttributes: attributes)
            _ = context
        }
    }

    /// I9：key→展示名映射；未知 key 一律显示通用文案，不直接露原始 key。
    static func displayName(for key: String) -> String {
        let known: [String: String] = [
            "beta": "内测者",
        ]
        return known[key] ?? "新徽章"
    }
}
