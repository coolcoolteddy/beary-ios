import UIKit

// ===== BearyButton 按钮工厂（B 批）=====
// 四类样式（各页实测形态的归纳口径，见下方各 case 注释；数值即原各页数值，
// 工厂只收敛写法，不改任何一处视觉）：
//  .primaryPill：高 44、圆角 22；墨底 + 反色字（bg 色，浅白深黑，与 ink 互为反色），
//    或橙底 + 白字（引导/主操作，Onboarding 主钮同款）。
//  .secondaryOutline：高 44/36、圆角 22/18、1pt line 边框 + surface 底 + ink 字
//    （搜索页“清空搜索”44/22 同款；36/18 为其紧凑版）。
//  .destructiveOutline：高 36/44、圆角 18/22、1pt 45% 红边框 + 红字 + surface 底
//    （回收站“彻底删除”红字口径，边框按任务要求取 45% 红而非 line）。
//  .iconCircleClose：视觉 32×32、圆角 16、faint 底、icon_close 15 + ink tint；
//    热区 44×44 由父类 BearyHit44Button 的 point(inside:) 自动扩（视觉帧不动）。
// 使用范围：只供后续与本批内新写处使用——各页已有按钮一律不动，不为统一而全量重写。
// 约束约定：工厂只定视觉（底色/字色/边框/圆角/默认字号），不替调用方下尺寸约束；
// 调用方按 style.height 下高约束（pill/outline 44 或 36；关闭钮 32×32）。
// 默认字号（调用方可事后改 titleLabel?.font 覆盖）：pill/outline 常规 16 semibold，
// 紧凑 14 semibold（搜索 CTA 同款；P1-4 起紧凑款走 cappedFont 上限 20，见 titleFont）；
// 关闭钮文字兜底 15。
// 边框色是 CGColor、赋值时固化：traitCollectionDidChange 内经 refreshChrome() 重赋，
// 深浅切换后边框不再停留在旧主题色。工厂钮一律 .custom 类型（UIButton(type:) 工厂
// 方法无法走子类初始化链；Pickers 旧关闭钮是 .system，换工厂后按压反馈仍由调用方的
// bearyAddPressFeedback 提供，行为不变）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyButtonTone: Equatable {
    case ink
    case orange
}

enum BearyButtonSize: Equatable {
    case regular
    case compact
}

enum BearyButtonStyle: Equatable {
    case primaryPill(BearyButtonTone)
    case secondaryOutline(BearyButtonSize)
    case destructiveOutline(BearyButtonSize)
    case iconCircleClose

    /// 调用方下高约束时取本值；关闭钮取 32（视觉），热区由父类扩到 44。
    var height: CGFloat {
        switch self {
        case .primaryPill:
            return 44
        case .secondaryOutline(let size):
            return size == .regular ? 44 : 36
        case .destructiveOutline(let size):
            return size == .regular ? 44 : 36
        case .iconCircleClose:
            return 32
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .primaryPill:
            return 22
        case .secondaryOutline(let size):
            return size == .regular ? 22 : 18
        case .destructiveOutline(let size):
            return size == .regular ? 22 : 18
        case .iconCircleClose:
            return 16
        }
    }

    /// 默认标题字号（紧凑 14 / 常规 16，与搜索 CTA / 通知弹窗主副钮同款）。
    /// R8：常规款走 scaledFont，默认字号下与原值一致，大字号档跟随系统缩放。
    /// P1-4：紧凑款（36 高固定容器）走 cappedFont 而非 scaledFont——沿审计 #31
    /// 口径（许愿墙 44 高标题框同款：固定高度容器配 cappedFont，上限 20，
    /// 行高不撑破容器）：默认字号下与原 14 完全一致，超大字号档截断到 20pt，
    /// 36 高内行高约 24pt、上下各余 6pt，按钮文字不再被固定高度纵向截断。
    /// 不走“最小高度随文字增长”：各调用方的高约束是 equalToConstant
    /// （许愿墙/搜索/空态均在各自文件内下死 36），改最小高度须动其他工人
    /// 的文件，文件独占纪律下不动；cappedFont 在本文件内即可闭环。
    var titleFont: UIFont {
        switch self {
        case .primaryPill:
            return BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        case .secondaryOutline(let size):
            if size == .compact {
                // P1-4：紧凑款 36 高固定容器，cappedFont 上限 20（默认上限，见
                // BearyDynamicType.fixedContainerMaxPointSize），默认字号下 = 14 不变。
                return BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
            }
            return BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        case .destructiveOutline(let size):
            if size == .compact {
                // P1-4：同上，紧凑款 cappedFont 上限 20，默认字号下 = 14 不变。
                return BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
            }
            return BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        case .iconCircleClose:
            return BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        }
    }
}

class BearyButton: BearyHit44Button {

    let style: BearyButtonStyle

    /// 投票选中态（仅许愿墙两票钮经 applyVoteSelected 设定后非 nil；其余工厂钮恒 nil，
    /// refreshChrome 仍走原样式边框，不受影响）。
    private var voteSelected: Bool?

    init(style: BearyButtonStyle) {
        self.style = style
        super.init(frame: .zero)
        self.applyStyle()
    }

    required init?(coder: NSCoder) {
        self.style = .secondaryOutline(.regular)
        super.init(coder: coder)
        self.applyStyle()
    }

    /// 快捷构造：带标题的工厂钮（标题仍可事后改 setTitle 覆盖）。
    static func make(style: BearyButtonStyle, title: String) -> BearyButton {
        let button = BearyButton(style: style)
        button.setTitle(title, for: .normal)
        return button
    }

    /// 快捷构造：关闭圆钮（faint 底 32 圆钮 + icon_close 15；资产缺失时“✕”文字兜底）。
    /// 关闭两套定版（2026-10-28 定）：全屏页用文字关闭、弹窗页用本图标圆钮，两套并存，不再强求统一成一种。
    static func closeButton() -> BearyButton {
        return BearyButton(style: .iconCircleClose)
    }

    /// 重试类描边 pill 唯一档：紧凑描边款（36 高 / 圆角 18 / 14 semibold）。
    /// 搜索页两处重试钮共用本工厂，不再各写一套尺寸。
    static func retryPill() -> BearyButton {
        return BearyButton(style: .secondaryOutline(.compact))
    }

    /// 投票选中态公共样式（许愿墙赞成/反对钮共用）：选中 = ink 底 + bg 字——bg 与 ink
    /// 恒成反色（深浅下 bg 自动跟随，不写死 .white）；未选中 = 透明底 + ink 字 + 25% ink 边框。
    /// 只管投票选中文字/底色；公开 pill 橙色、donePill 绿色不在此方法管辖内，一律不动。
    func applyVoteSelected(_ selected: Bool) {
        voteSelected = selected
        if selected {
            backgroundColor = BearyColors.ink
            setTitleColor(BearyColors.bg, for: .normal)
            layer.bearyDynamicBorderColor = BearyColors.ink
        } else {
            backgroundColor = .clear
            setTitleColor(BearyColors.ink, for: .normal)
            layer.bearyDynamicBorderColor = BearyColors.ink.withAlphaComponent(0.25)
        }
    }

    private func applyStyle() {
        layer.cornerRadius = style.cornerRadius
        layer.masksToBounds = true
        titleLabel?.font = style.titleFont
        // R8：工厂钮一律跟随系统字号（紧凑款除外：P1-4 cappedFont 上限 20，见 titleFont）；
        // 调用方事后覆写 titleLabel?.font 时须自行重配 scaledFont/cappedFont + 本开关。
        titleLabel?.adjustsFontForContentSizeCategory = true
        switch style {
        case .primaryPill(let tone):
            layer.borderWidth = 0
            if tone == .ink {
                backgroundColor = BearyColors.ink
                setTitleColor(BearyColors.bg, for: .normal)
                tintColor = BearyColors.bg
            } else {
                backgroundColor = BearyColors.orange
                setTitleColor(.white, for: .normal)
                tintColor = .white
            }
        case .secondaryOutline:
            backgroundColor = BearyColors.surface
            setTitleColor(BearyColors.ink, for: .normal)
            tintColor = BearyColors.ink
            layer.borderWidth = 1
            layer.bearyDynamicBorderColor = BearyColors.line
        case .destructiveOutline:
            backgroundColor = BearyColors.surface
            setTitleColor(BearyColors.red, for: .normal)
            tintColor = BearyColors.red
            layer.borderWidth = 1
            layer.bearyDynamicBorderColor = BearyColors.red.withAlphaComponent(0.45)
        case .iconCircleClose:
            backgroundColor = BearyColors.faint
            tintColor = BearyColors.ink
            accessibilityLabel = "关闭"
            if let closeImage = BearyIconImages.image(named: "icon_close", pointSize: 15) {
                setImage(closeImage, for: .normal)
            } else {
                // I15 同款兜底：icon_close 资产随包发布，正常路径恒取到图；
                // 此文字分支仅作资产缺失时的兜底，保证关闭入口永在。
                setTitle("✕", for: .normal)
                setTitleColor(BearyColors.ink, for: .normal)
            }
        }
    }

    /// 深浅切换重刷：CALayer borderColor 赋值时固化，不重赋即停留在旧主题色。
    /// 背景/字色是 UIColor 动态色，系统自动跟随，无需重赋；红 45% 是固定色，重赋无害。
    /// 投票钮例外：边框须按投票态重赋，否则会被下面 secondaryOutline 分支刷回 line 色。
    func refreshChrome() {
        if let selected = voteSelected {
            applyVoteSelected(selected)
            return
        }
        switch style {
        case .secondaryOutline:
            layer.bearyDynamicBorderColor = BearyColors.line
        case .destructiveOutline:
            layer.bearyDynamicBorderColor = BearyColors.red.withAlphaComponent(0.45)
        case .primaryPill, .iconCircleClose:
            break
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            self.refreshChrome()
        }
    }
}
