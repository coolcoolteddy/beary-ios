import UIKit

/// 网页版心情 / 回应熊图的原生图片入口。
///
/// 图片来源：网页版 `emoteUrl`（`img.teddyhn.com/emotes/v2/<key>.svg`，
/// 深色为 `<key>-w.svg`）在编译期经 cairosvg 渲染为 PNG，打包进
/// Assets.xcassets：浅色 `emote_<key>`，深色 `emote_<key>_dark`，
/// 每套含 @1x 72px / @2x 144px / @3x 216px 三档。
/// 注意：pbxproj 注册由总协调统一做，本文件只提供图片解析。
enum BearyEmoteImages {
    static func image(for key: String, dark: Bool) -> UIImage? {
        if dark {
            if let darkImage = UIImage(named: "emote_\(key)_dark") {
                return darkImage
            }
        }
        return UIImage(named: "emote_\(key)")
    }
}
