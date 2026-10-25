import UIKit

/// 网页版心情 / 回应熊图的原生图片入口。
///
/// 图片来源：网页版 `emoteUrl`（`img.teddyhn.com/emotes/v2/<key>.svg`，
/// 深色为 `<key>-w.svg`）在编译期经 cairosvg 渲染为 PNG，打包进
/// Assets.xcassets：浅色 `emote_<key>`，深色 `emote_<key>_dark`，
/// 每套含 @1x 72px / @2x 144px / @3x 216px 三档。
/// 注意：pbxproj 注册由总协调统一做，本文件只提供图片解析。
enum BearyEmoteImages {
    /// C3：深色缺失上报记录（首次缺失的 key 集合，供容器/诊断面读取上报；
    /// 当前 40 只深浅资产齐全，本集合正常为空）。
    private(set) static var missingDarkKeys: Set<String> = []

    /// C3：深色资产缺失通知（userInfo ["key": String]），容器可订阅后上报；
    /// 与日志、missingDarkKeys 记录三路上报，缺一不可谓“静默”。
    static let darkAssetMissingNotification = Notification.Name("BearyEmoteDarkAssetMissing")

    static func image(for key: String, dark: Bool) -> UIImage? {
        if dark {
            if let darkImage = UIImage(named: "emote_\(key)_dark") {
                return darkImage
            }
            // C3：深色缺失不得静默回退浅色版蒙混（浅色版为深色线条稿，
            // 深色底上对比度骤降）。首次缺失时日志 + 记录 + 通知三路上报，
            // 并返回 nil（调用方显示空白占位），不让浅色版冒充深色版；
            // 同一 key 只上报一次，避免列表滚动时日志刷屏。
            if !missingDarkKeys.contains(key) {
                missingDarkKeys.insert(key)
                NSLog("[BearyEmoteImages] missing dark asset for key=%@", key)
                NotificationCenter.default.post(name: darkAssetMissingNotification, object: nil, userInfo: ["key": key])
            }
            return nil
        }
        return UIImage(named: "emote_\(key)")
    }
}
