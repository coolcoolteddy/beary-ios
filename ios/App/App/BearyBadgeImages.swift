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
}
