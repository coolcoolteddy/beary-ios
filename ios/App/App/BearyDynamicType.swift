import UIKit

// Dynamic Type 缩放入口（只依赖 UIKit，不引用任何 App 内类型）。
// 原在 BearyNativeCommon.swift 内；#579 后 PastSelf 改走本入口，测试 target
// 单独编译 BearyPastSelf.swift 时找不到它（同 #555 修红 BearyColors 的原因），
// 故抽成独立文件、双 target 注册。

// MARK: - C8/C9：Dynamic Type 与骨架屏（C 批视觉线）

/// C8 审计口径（只此两处，不扩大）：
/// - 日记正文 16pt、卡片标题 16.5pt 粗体：走 UIFontMetrics scaledFont，label 侧须配
///   adjustsFontForContentSizeCategory = true；富文本 attributed 内的字号在下次
///   configure/reload 时重解（系统字号切换当下不自动重绘富文本，属已知局限）。
/// - 固定高度容器（Profile modal 顶栏 44pt，顶栏名 17pt）：cappedFont 上限 20pt 防撑破；
///   默认字号下与原字号完全一致（17 -> 17），只在超大字号档截断。
/// 全工程其余硬编码 systemFont 本批不动，见 PR 描述后续清单。
enum BearyDynamicType {
    /// 固定高度容器字号上限（C8 口径示例值 20pt）。
    static let fixedContainerMaxPointSize: CGFloat = 20

    static func scaledFont(for base: UIFont) -> UIFont {
        UIFontMetrics.default.scaledFont(for: base)
    }

    /// 日记正文 16pt（Feed/Timeline/Search 渲染态卡片正文）。
    static func diaryBodyFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 16))
    }

    /// 卡片标题 16.5pt 粗体（Feed/Profile 卡片作者名行）。
    static func cardTitleFont() -> UIFont {
        scaledFont(for: UIFont.boldSystemFont(ofSize: 16.5))
    }

    /// 固定高度容器用：先缩放、超上限则截断到上限（withSize 保留原字重）。
    static func cappedFont(for base: UIFont, maximumPointSize: CGFloat = fixedContainerMaxPointSize) -> UIFont {
        let scaled = UIFontMetrics.default.scaledFont(for: base)
        guard scaled.pointSize > maximumPointSize else { return scaled }
        return base.withSize(maximumPointSize)
    }
}
