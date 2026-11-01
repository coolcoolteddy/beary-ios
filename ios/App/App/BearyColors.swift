import UIKit

// 动态色 token（与 SceneDelegate 原生栏、网页三色制同值）。
// 本文件刻意只依赖 UIKit、不引用任何 App 内类型，以便同时编进 App target
// 与 BearyCoreTests target（与过去的自己单测共用；见 #555 修红）。
// 原在 BearyNativeCommon.swift 内，#555 后 PastSelf 改走本 token，测试 target
// 单独编译 BearyPastSelf.swift 时找不到它，故抽成独立文件、双 target 注册。

enum BearyColors {
    static var ink: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1) : .black } }
    static var gray: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.66, alpha: 1) : UIColor(white: 0.45, alpha: 1) } }
    static var orange: UIColor { UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1) }
    /// 品牌橙上的固定前景色（深墨色，视觉清单第 5 项）：固定纯黑，不随深浅切换。
    /// 不用 ink——ink 深色下是近白，放在固定橙底上会变白字（白字/橙底对比度
    /// 仅约 2.20:1，见 #508 注释）；onBrand 在深浅两模式下恒为墨色，
    /// 橙底对比度约 9.55:1。只用于橙底前景，不替代通用 ink。
    static var onBrand: UIColor { .black }
    /// 语义红：网页 --red #e5484d，浅深同值（超字数提示等语义红一律走这里，不用 systemRed）。
    static var red: UIColor { UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1) }
    /// 点赞填色：亮红 #ff3b30（2026-10-29 Li 定，明显亮于语义红 #e5484d；仅点赞入口用——
    /// 删除按钮与语义红仍走 red，收藏点亮仍走 orange，不动）。
    static var likeRed: UIColor { UIColor(red: 1.0, green: 59.0/255.0, blue: 48.0/255.0, alpha: 1) }
    /// 图片上的深色衬底：固定黑色半透明（与 ink 不同——深色下 ink 是近白，白字会看不清）。
    static var scrim: UIColor { UIColor(white: 0, alpha: 0.6) }
    /// 网页 --blue：浅 #007aff / 深 #0a84ff（深色 G 通道精确 132/255，勿再写 0.52）。
    static var blue: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 10.0/255.0, green: 132.0/255.0, blue: 1.0, alpha: 1) : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1) } }
    /// 语义绿：网页 --green #2fbf71，深浅同值。
    static var green: UIColor { UIColor(red: 47.0/255.0, green: 191.0/255.0, blue: 113.0/255.0, alpha: 1) }
    /// 网页 --line：浅 #dbdbdb / 深 #3a3a40（深色带蓝偏，单 white 值复现不了）。
    static var line: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 58.0/255.0, green: 58.0/255.0, blue: 64.0/255.0, alpha: 1) : UIColor(white: 0.86, alpha: 1) } }
    /// 网页 --bg：浅 #fff / 深 #000000（Li 2026-10-27 点选纯黑，覆盖 10-26 去纯黑令）。
    /// 全 App 深色面（页面底、窗口底、容器底、玻璃 tint 基色）均走本变量，改一处即全跟走。
    /// 注意：裁剪页/灯箱的纯黑底、遮罩 scrim、阴影色是故意的黑，不走本变量，一律不动。
    static var bg: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? .black : .white } }
    /// 网页 --surface：浅 #fff / 深 #26262c。
    static var surface: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 38.0/255.0, green: 38.0/255.0, blue: 44.0/255.0, alpha: 1) : .white } }
    /// 时间线卡片边线（B 方案，v3 预览值，2026-10-29 用户批 v3）：
    /// 1px，浅 #c7c7cc／深 #48484e；色板既有 token 无贴近值（line 是被换掉的旧值，
    /// gray 深太多），故用 v3 精确值，不凑既有 token。
    static var timelineBorder: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 72.0/255.0, green: 72.0/255.0, blue: 78.0/255.0, alpha: 1) : UIColor(red: 199.0/255.0, green: 199.0/255.0, blue: 204.0/255.0, alpha: 1) } }
    /// 时间线可见性裸图标灰：浅色保持 v3 值 #8e8e93；深色纯黑底上该值
    /// 对比偏弱，改走 BearyColors.gray（深色约 0.66 白）。时间文字仍走
    /// BearyColors.gray，不跟这个值走（此处只是深色与它同值）。
    static var timelineIconGray: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? BearyColors.gray.resolvedColor(with: t) : UIColor(red: 142.0/255.0, green: 142.0/255.0, blue: 147.0/255.0, alpha: 1) } }
    static var faint: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : UIColor(white: 0.96, alpha: 1) } }
    /// 网页 --hov：浅 rgba(17,17,20,.06) / 深 rgba(244,244,248,.08)（悬停/按压底色）。
    static var hov: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 244.0/255.0, green: 244.0/255.0, blue: 248.0/255.0, alpha: 0.08) : UIColor(red: 17.0/255.0, green: 17.0/255.0, blue: 20.0/255.0, alpha: 0.06) } }

    /// C6：按当前 trait 重解 base 色再降透明度的动态色。0.13 透明底
    /// （私密 pill 蓝底、草稿 chip 橙底、图片未保存红底等）一律走这里，
    /// 不得对动态色直接 withAlphaComponent——后者会在生成时固化当前
    /// trait 的解析值，深浅切换后不再跟随。固定色（橙/红/绿）重解后不变，
    /// 同样可走本方法。
    static func alpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
        return UIColor { trait in
            color.resolvedColor(with: trait).withAlphaComponent(alpha)
        }
    }
}
