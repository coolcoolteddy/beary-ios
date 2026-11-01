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
        // BETA 徽章已下线（2026-10-31）：beta 一律按无徽章处理，调用方隐藏徽章位。
        guard key != "beta", !key.isEmpty else { return nil }
        return UIImage(named: "badge_" + key)
    }

    /// I8：取不到图时不静默消失——返回中性占位图并打一条日志。
    /// 占位图是代码现绘的 17×17 问号（非官方资产，仅作“图缺失”的可见标记，
    /// 与卡片徽章位 17×17 同口径）；底色/问号色走 BearyColors 动态色，
    /// 随深浅自适应，不再是固定浅灰块；
    /// 新徽章资产与 key 同步上架仍是上架流程项，代码侧只保证不留空白。
    static func imageOrPlaceholder(for key: String) -> UIImage? {
        // BETA 已下线：不得 fallback 成占位问号，直接按无徽章处理。
        guard key != "beta" else { return nil }
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

    // displayName 映射已随 BETA 下线删除（455）：无调用方，空映射会使
    // 资产检查误报，见 scripts/check-beary-assets.py 的徽章族退役注释。
}
