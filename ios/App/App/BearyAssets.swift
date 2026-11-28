// 图片资源名常量入口：资源改名时只改这里，调用点不用逐处改。
// 只收多处共用的名字；一次性名字（"side_beary_word"、"side_beary_icon"）
// 与动态名（"emote_\(key)"）仍就地写，不单列。
// 本文件刻意不依赖 UIKit，只用 String，以便以后进测试 target 也不用改。

enum BearyAssets {
    /// 横版官方 logo（BearyAppLock／Feed／ID 卡／登录／SceneDelegate 共 7 处）。
    static let logoHorizontal = "LogoHorizontal"
    /// 皇冠图（BearyCrownView／原图上传 sheet 共 2 处）。
    static let crown = "crown"
    /// 皇冠深色 Lottie 文件名（BearyCrownView 深色动画；与图片资源同名、
    /// 不同源——只改图片资源名时须同步确认该 Lottie 文件是否同改）。
    static let crownDark = "crown_dark"
}
