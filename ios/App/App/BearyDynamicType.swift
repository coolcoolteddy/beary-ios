import UIKit

// Dynamic Type 缩放入口（只依赖 UIKit，不引用任何 App 内类型）。
// 原在 BearyNativeCommon.swift 内；#579 后 PastSelf 改走本入口，测试 target
// 单独编译 BearyPastSelf.swift 时找不到它（同 #555 修红 BearyColors 的原因），
// 故抽成独立文件、双 target 注册。

// MARK: - C8/C9：Dynamic Type 与骨架屏（C 批视觉线）

/// C8 审计口径（只此两处，不扩大）：
/// - 日记正文 16pt、卡片标题 16.5pt 粗体：走 UIFontMetrics scaledFont，label 侧须配
///   adjustsFontForContentSizeCategory = true；富文本 attributed 内的字号不随
///   adjustsFont 自动重解——日记卡片（BearyDiaryCardCell）在内容字号档变化时
///   经 traitCollectionDidChange 立即重建正文/标题富文本并通知行高重算
///   （审计第 27 项修复；此前“下次 configure/reload 才重解”的已知局限在卡片
///   一支已消除，其余富文本仍走下次 configure 口径）。
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

// MARK: - C2：语义字体入口（只立入口，不改数值、不迁调用点）
//
// 只新增转发入口，旧入口（diaryBodyFont / cardTitleFont / scaledFont /
// cappedFont）全部保留不动，全仓调用点一处不改，故任何实际显示字号不变。
// 每条新入口的底值均取自现行调用点已在用的内联写法，不是新定字号：
// - pageTitleFont：顶栏标题 17 bold scaled（规范第 11 节子页标题；Composer / DMChat /
//   DMConversations / Login 顶栏标题现行写法；固定高度容器内的 17 标题
//   仍走原 cappedFont 调用点，本入口不覆盖那种情形）。
// - secondaryFont：次要文本 13 regular scaled（DM snippet、AppLock 状态、
//   Detail/卡片辅助行现行写法）。
// - captionFont：辅助/时间/提示 12 regular scaled（BlindBox 副标题、DM 时间、
//   Composer results、Detail 辅助行现行写法）。
// - buttonFont / buttonCompactFont：与 BearyButton.titleFont 现行值逐字一致
//   （常规 16 semibold scaled 不封顶、紧凑 14 semibold scaled 不封顶）。
// 小号与展示字已于 2026-11-04 定版（见 smallActionFont / smallBodyFont /
//   buttonRegularFont / buttonSmallFont / heroNameFont / avatarInitialFont /
//   smallSemiboldFont），
//   均为 scaled；设置页 12 处迁入。
// 数值角色已于 2026-11-04 定版（12 semibold scaled，见 numberFont），
// 此前混用的 11 regular / 12 bold / 13 semibold 按页分批迁入本入口。
// diaryBodyFont（正文）与 cardTitleFont（卡片标题）本身已是按角色命名，
// 直接列入语义清单，不重复造入口。
extension BearyDynamicType {
    /// 语义：页面/顶栏标题。定版值：17 bold，scaled（规范第 11 节子页标题）。
    static func pageTitleFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
    }

    /// 语义：次要文本。沿用值：13 regular，scaled。
    static func secondaryFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 13))
    }

    /// 语义：辅助/时间/提示。沿用值：12 regular，scaled。
    static func captionFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 12))
    }

    /// 语义：按钮（常规款）。沿用值：16 semibold，scaled 不封顶（与 BearyButton.titleFont 一致）。
    static func buttonFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
    }

    /// 语义：按钮（紧凑款）。沿用值：14 semibold，scaled 不封顶（与 BearyButton.titleFont 一致）。
    static func buttonCompactFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
    }

    /// 等宽数字（tabular figures）：倒计时、剩余分钟、点赞数等会变的数字走本入口，
    /// 数字进位宽度一致，跳字时不抖；字号字重与 Dynamic Type 缩放与原入口一致。
    static func tabularDigitsFont(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        scaledFont(for: UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight))
    }

    /// 语义：数值（行内计数）。定版值：12 semibold，scaled（规范第 11 节）。
    static func numberFont() -> UIFont {
        tabularDigitsFont(ofSize: 12, weight: .semibold)
    }

    /// 语义：小号粗体操作（登录钮、复制钮、账号行头像字）。定版值：15 bold，scaled（规范第 11 节，2026-11-04 Li 定）。
    static func smallActionFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .bold))
    }

    /// 语义：小号常规（分段器、清除钮、按钮）。定版值：15 regular，scaled（规范第 11 节，2026-11-04 Li 定）。
    static func smallBodyFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 15))
    }

    /// 语义：常规字重按钮（编辑资料钮，与紧凑款半粗区分）。定版值：14 regular，scaled（规范第 11 节，2026-11-04 Li 定）。
    static func buttonRegularFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 14))
    }

    /// 语义：小号半粗按钮（退出其他设备钮）。定版值：13 semibold，scaled（规范第 11 节，2026-11-04 Li 定）。
    static func buttonSmallFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
    }

    /// 语义：个人页姓名展示字。定版值：24 heavy，scaled（规范第 11 节，2026-11-04 Li 定）。
    static func heroNameFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 24, weight: .heavy))
    }

    /// 语义：头像首字展示字。定版值：28 bold，scaled（规范第 11 节，2026-11-04 Li 定）。
    static func avatarInitialFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 28, weight: .bold))
    }

    /// 语义：分段器选中态。定版值：15 semibold，scaled（规范第 11 节，2026-11-04 Li 补定）。
    static func smallSemiboldFont() -> UIFont {
        scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
    }
}
