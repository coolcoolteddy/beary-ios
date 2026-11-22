import UIKit

/// 设置页共享 UI 工厂（可复用资源第十六批第 4 项）。
///
/// 主设置页 `BearySettingsViewController` 与设置子页基类
/// `BearySettingsSubpageViewController` 各写一套的
/// `makeGroupCard`／`makeLabel`／`makeSectionTitle` 在此合一；
/// 两处内联同形的开关行也由此出（`makeSwitchRow`）。
/// 卡片体形以主设置页为准（surface1 底、cornerRadius single、
/// 标题 16／-8、行间 1pt line 分隔、行 wrap 内边距 14／16）；
/// 子页版与之一致，只是不做覆盖按钮重钉（见 `repinCoverButtons`）。
enum BearySettingsUI {

    // MARK: - 标签

    static func makeLabel(font: UIFont, color: UIColor, lines: Int = 1, alignment: NSTextAlignment = .left) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        // P1-7：设置页正文 / 辅助 / 分组标题一律走动态字体入口（默认字号下
        // 与原值一致，大字号档跟随系统缩放）；本工厂只产出上述三类文字，
        // 故集中在此接 scaledFont + adjusts，不逐处重复。
        label.font = BearyDynamicType.scaledFont(for: font)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = lines
        label.textAlignment = alignment
        label.lineBreakMode = .byCharWrapping
        return label
    }

    /// F4：组标题改走网页 group-title 口径——12px 灰、放卡内（不再是卡外 14 粗体）。
    /// 字距 1px（网页 letter-spacing:1px）用 kern 复现。
    /// - Parameters:
    ///   - font: 未缩放的基准字（默认 12pt 系统字；经 makeLabel 一次 scaled，
    ///     与各页现行 scaled 字体等值）。反馈页传 13pt 系统字，即其现行
    ///     `BearyDynamicType.secondaryFont()`。
    ///   - kern: 字距（默认 1；传 nil 时用纯文本，不设 attributedText）。
    ///   - lines: 行数（默认 0，多行自适应；反馈页传 1，保持其现行单行）。
    static func makeSectionTitle(_ text: String, font: UIFont? = nil, kern: CGFloat? = 1, lines: Int = 0) -> UILabel {
        let label = makeLabel(font: font ?? UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: lines)
        // P1-7：分组标题多行自适应——大字号下可换行，卡内标题包容器
        // 上下约束已定，行高随文字自动撑开，不钉固定高度。
        if let kernValue = kern {
            label.attributedText = NSAttributedString(string: text, attributes: [.kern: kernValue, .font: label.font])
        } else {
            label.text = text
        }
        return label
    }

    // MARK: - 分组卡

    static func makeCardView(cornerRadius: CGFloat = BearyCorners.single) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        // 卡片底色走 surface1（页上卡片层；2026-11-07 微明度定版：1px 外框已去掉）。
        card.backgroundColor = BearyColors.surface1
        card.layer.borderWidth = 0
        card.layer.cornerRadius = cornerRadius
        card.clipsToBounds = true
        return card
    }

    /// F4：分组卡（网页 .group 口径）：标题在卡内、卡为 card 底 + 1px 边框 +
    /// 圆角 20、行间 1px 分隔线（分隔线通宽，行内容左右 16、上下 14）。
    /// 返回卡片与每行的包容器（包容器用于显隐整行：隐藏行本身仍会留 28pt 内边距，
    /// 故 Plus「内测限免」行须改藏包容器，见 fillPlusDetail）。
    /// 一并返回行间分隔线：separators[i] 位于 wrappers[i] 与 wrappers[i + 1] 之间；
    /// 隐藏第 i（i > 0）行时须连同其前分隔线 separators[i - 1] 一并藏，否则留 stray 线
    /// （第十一轮审计 1：通知提示行与开发者模式行只藏 row，残留 wrap 内边距与分隔线）。
    /// - Parameter repinCoverButtons: 主设置页行为（默认 true）：可点行的覆盖按钮改钉
    ///   外层 wrap 四边；设置子页此前无此逻辑，传 false 保持原样。
    static func makeGroupCard(title: String?, rows: [UIView], repinCoverButtons: Bool = true) -> (card: UIView, wrappers: [UIView], separators: [UIView]) {
        let card = makeCardView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .fill
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        if let titleText = title {
            let titleLabelValue = makeSectionTitle(titleText)
            titleLabelValue.translatesAutoresizingMaskIntoConstraints = false
            let titleWrap = UIView()
            titleWrap.translatesAutoresizingMaskIntoConstraints = false
            titleWrap.addSubview(titleLabelValue)
            NSLayoutConstraint.activate([
                titleLabelValue.topAnchor.constraint(equalTo: titleWrap.topAnchor, constant: 16),
                titleLabelValue.leadingAnchor.constraint(equalTo: titleWrap.leadingAnchor, constant: 16),
                titleLabelValue.trailingAnchor.constraint(equalTo: titleWrap.trailingAnchor, constant: -16),
                titleLabelValue.bottomAnchor.constraint(equalTo: titleWrap.bottomAnchor, constant: -8),
            ])
            stack.addArrangedSubview(titleWrap)
        }
        var wrappers: [UIView] = []
        var separators: [UIView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                NSLayoutConstraint.activate([
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
                stack.addArrangedSubview(separator)
                separators.append(separator)
            }
            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 14),
                row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
                row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -14),
            ])
            if repinCoverButtons {
                // 审计三轮第 4 项：可点行的覆盖按钮改钉外层 wrap 四边（含 14pt 留白），
                // 视觉内边距仍由内容容器控制。判定标准：按钮已零边距钉满内层四边
                // （即整行覆盖钮）；居中独立钮（退出/注销）、带 -52 避让的切号钮、
                // 开关行（无 UIButton）一律不动——开关行仍只响应控件本身。
                // 外层 wrap 每行只包一行，按钮原已盖满整行，扩到外框只多出留白区，
                // 不会盖住任何同行控件；按钮目标与按压反馈跟随按钮本身。
                let coverButtons = row.subviews.compactMap { $0 as? UIButton }.filter { button in
                    let edgeAttrs: [NSLayoutConstraint.Attribute] = [.top, .leading, .trailing, .bottom]
                    return edgeAttrs.allSatisfy { attr in
                        row.constraints.contains { c in
                            (c.firstItem as? UIButton) === button && c.firstAttribute == attr
                                && (c.secondItem as? UIView) === row && c.constant == 0
                        }
                    }
                }
                if coverButtons.count == 1, let button = coverButtons.first {
                    NSLayoutConstraint.deactivate(row.constraints.filter { ($0.firstItem as? UIButton) === button || ($0.secondItem as? UIButton) === button })
                    wrap.addSubview(button)
                    NSLayoutConstraint.activate([
                        button.topAnchor.constraint(equalTo: wrap.topAnchor),
                        button.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                        button.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                        button.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                    ])
                }
            }
            stack.addArrangedSubview(wrap)
            wrappers.append(wrap)
        }
        return (card, wrappers, separators)
    }

    // MARK: - 开关行

    /// 开关行（标题 15 + 说明 12 灰 + UISwitch；纵向栈 spacing 2、
    /// 横向栈 spacing 12、居中对齐）。音效行与诊断日志行同形共用。
    /// 返回行与开关：开关只在需要后续读写时取 `.toggle`，两处现行调用只取 `.row`。
    static func makeSwitchRow(title: String, detail: String, isOn: Bool, target: Any?, action: Selector) -> (row: UIStackView, toggle: UISwitch) {
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（15 regular scaled；入口本身已
        // scaled，覆写而非经工厂再缩放，避免二次缩放）。
        titleLabel.font = BearyDynamicType.smallBodyFont()
        titleLabel.text = title
        titleLabel.numberOfLines = 0 // P1-7：开关行正文标题多行
        let detailLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        detailLabel.text = detail
        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let target = target {
            toggle.addTarget(target, action: action, for: .valueChanged)
        }
        let row = UIStackView(arrangedSubviews: [textStack, toggle])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return (row, toggle)
    }
}
