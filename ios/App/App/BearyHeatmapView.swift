import UIKit

/// 写作热力图模块：GitHub 式 27 周 × 7 天格子（预览 v5 定版）。
///
/// 布局：列 = 周（最左为 26 周前的周一，最右为本周）、行 = 星期一到星期日；
/// 今天在最右列，未来的格子不画、不可点。颜色橙色五档（0 篇为空格，
/// 1 / 2 / 3 / 4+ 篇逐档加深）；右上角月份名、左侧星期名、右下“少 → 多”
/// 图例、底部“点某一天，看那天的日记”提示；模块内不写篇数/天数/连续天。
/// 模块本身 surface1 底、无描边，与同页其他模块（写作统计等）统一。
///
/// HorizonCalendar 核实结论（2026-11-06，见 PR 描述）：该库按月分块布局，
/// 行高 = 列宽 × 纵横比（下限 0.5，见其 FrameProvider.daySize），27 周会排成
/// 约 30 行、700pt+ 高的纵向日历，做不成 GitHub 横向长条，故本格用
/// UIKit 自画，不引入 HorizonCalendar 依赖。
final class BearyHeatmapView: UIView {

    /// 周数（列数）与每周天数（行数），GitHub 同款 27 × 7。
    static let weeks = 27
    static let daysPerWeek = 7
    /// 格间距（横向与纵向同值）。
    private static let gap: CGFloat = 3
    /// 星期名列宽与格区间距。
    private static let weekdayWidth: CGFloat = 28
    private static let gridLeadingGap: CGFloat = 8
    /// 月份名行高与格区间距。
    private static let monthRowHeight: CGFloat = 16
    private static let monthGridGap: CGFloat = 4
    /// 图例方块边长。
    private static let legendSwatch: CGFloat = 10

    /// 点某天：传北京日 key（yyyy-MM-dd），容器接线到时间线该日。
    var onSelectDay: ((String) -> Void)?

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.pageTitleFont()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        label.text = "写日记热力图"
        return label
    }()

    private let gridArea = UIView()
    private var gridAreaHeightConstraint: NSLayoutConstraint?
    private var monthLabels: [UILabel] = []
    private var weekdayLabels: [UILabel] = []
    private var dayButtons: [UIButton] = []
    /// 与 dayButtons 一一对应：该格的北京日 key；未来格为空串（按钮隐藏、不可点）。
    private var buttonDayKeys: [String] = []
    /// layoutSubviews 算出的格边长（点按最近中心命中时算 pitch 用）。
    private var gridCellSize: CGFloat = 0

    private let legendStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 3
        stack.alignment = .center
        return stack
    }()

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.secondaryFont()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.text = "点某一天，看那天的日记"
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { return nil }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = BearyColors.surface1
        layer.cornerRadius = BearyCorners.single
        clipsToBounds = true

        addSubview(titleLabel)
        gridArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gridArea)
        addSubview(legendStack)
        addSubview(hintLabel)

        // 月份名（每列首日换月时一个，最多 7 个，位置在 layoutSubviews 里按列算）。
        for _ in 0..<8 {
            let label = UILabel()
            label.font = BearyDynamicType.captionFont()
            label.adjustsFontForContentSizeCategory = true
            // 大字号下月份名（30pt 宽框）可能溢出：允许缩到 0.8 倍兜底。
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            label.textColor = BearyColors.gray
            label.isHidden = true
            gridArea.addSubview(label)
            monthLabels.append(label)
        }
        // 星期名（周一在首行）：规范 §11 星期名 12 regular scaled（captionFont），
        // 框高取整行 pitch 使文字在行内居中；大字号下星期名（28pt 宽框）可能溢出：
        // 允许缩到 0.8 倍兜底（与月份名同款写法），星期列 28pt 宽不放宽。
        for weekday in ["周一", "周二", "周三", "周四", "周五", "周六", "周日"] {
            let label = UILabel()
            label.font = BearyDynamicType.captionFont()
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            label.textColor = BearyColors.gray
            label.text = weekday
            gridArea.addSubview(label)
            weekdayLabels.append(label)
        }
        // 189 个格按钮一次建好复用（小方块、圆角 2、无文字），逐次 configure 只改
        // 颜色、显隐与无障碍文案，不重建视图。
        for _ in 0..<(Self.weeks * Self.daysPerWeek) {
            let button = UIButton(type: .custom)
            button.layer.cornerRadius = 2
            button.clipsToBounds = true
            button.addTarget(self, action: #selector(dayButtonTapped(_:)), for: .touchUpInside)
            button.isAccessibilityElement = true
            button.accessibilityTraits = .button
            dayButtons.append(button)
            buttonDayKeys.append("")
            gridArea.addSubview(button)
        }
        // 点按按最近格子中心命中：格子只有约 8.6pt，手指点不准，落在格间
        // 缝隙也算最近那格；手势只接网格上的轻点，按钮自身的
        // touchUpInside 留给 VoiceOver 激活（读屏点按不经过手势）。
        let gridTap = UITapGestureRecognizer(target: self, action: #selector(gridTapped(_:)))
        gridArea.addGestureRecognizer(gridTap)
        // VoiceOver 按周浏览：转子“周”逐周跳到每周一，不用逐个滑过 189 个格。
        let weekRotor = makeWeekRotor()
        for button in dayButtons {
            button.accessibilityCustomRotors = [weekRotor]
        }
        // 图例：少 + 五档方块 + 多（右对齐）。
        let lessLabel = UILabel()
        lessLabel.font = BearyDynamicType.captionFont()
        lessLabel.adjustsFontForContentSizeCategory = true
        lessLabel.textColor = BearyColors.gray
        lessLabel.text = "少"
        legendStack.addArrangedSubview(lessLabel)
        for level in 0...4 {
            let swatch = UIView()
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.backgroundColor = Self.color(forLevel: level)
            swatch.layer.cornerRadius = 2
            swatch.clipsToBounds = true
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: Self.legendSwatch),
                swatch.heightAnchor.constraint(equalToConstant: Self.legendSwatch),
            ])
            legendStack.addArrangedSubview(swatch)
        }
        let moreLabel = UILabel()
        moreLabel.font = BearyDynamicType.captionFont()
        moreLabel.adjustsFontForContentSizeCategory = true
        moreLabel.textColor = BearyColors.gray
        moreLabel.text = "多"
        legendStack.addArrangedSubview(moreLabel)

        let gridHeight = gridArea.heightAnchor.constraint(equalToConstant: 0)
        gridAreaHeightConstraint = gridHeight
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            gridArea.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            gridArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            gridArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            gridHeight,
            legendStack.topAnchor.constraint(equalTo: gridArea.bottomAnchor, constant: 8),
            legendStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hintLabel.topAnchor.constraint(equalTo: legendStack.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: - 数据

    /// 可见日记按北京日计数（createdAt 缺失的篇跳过，与 BearyEntrySyncStore.groupByDay 同口径）。
    static func counts(from entries: [Entry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let createdAt = entry.createdAt,
                  let key = BearyBeijingDay.dayKey(ofMs: createdAt) else { continue }
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// 橙色五档：0 篇为空格（line 灰，与 surface1 卡底可区分），1 / 2 / 3 / 4+ 篇逐档加深（品牌橙 #ff9500）。
    static func color(forLevel level: Int) -> UIColor {
        switch level {
        case 0: return BearyColors.line
        case 1: return BearyColors.alpha(BearyColors.orange, 0.3)
        case 2: return BearyColors.alpha(BearyColors.orange, 0.55)
        case 3: return BearyColors.alpha(BearyColors.orange, 0.8)
        default: return BearyColors.orange
        }
    }

    static func level(forCount count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1: return 1
        case 2: return 2
        case 3: return 3
        default: return 4
        }
    }

    /// 按可见日记重算每格颜色与文案；visible 为空时调用方直接藏卡，不调这里。
    /// 窗口：今天所在周的周一往前推 26 周（共 27 列），最早一周不丢——
    /// 首列是完整一周（即使其中几天在账号首篇之前，也画 line 空格，不截掉）。
    func configure(entries: [Entry]) {
        let counts = Self.counts(from: entries)
        guard let today = BearyBeijingDay.todayComponents(),
              let todayNumber = BearyBeijingDay.todayNumber(),
              let monday = BearyBeijingDay.mondayOf(year: today.year, month: today.month, day: today.day),
              let windowStart = BearyBeijingDay.shifted(year: monday.0, month: monday.1, day: monday.2, byDays: -26 * 7) else { return }
        for col in 0..<Self.weeks {
            for row in 0..<Self.daysPerWeek {
                let index = col * Self.daysPerWeek + row
                guard let cell = BearyBeijingDay.shifted(year: windowStart.0, month: windowStart.1, day: windowStart.2, byDays: col * 7 + row),
                      let cellNumber = BearyBeijingDay.dayNumber(year: cell.0, month: cell.1, day: cell.2) else { continue }
                let button = dayButtons[index]
                if cellNumber > todayNumber {
                    // 未来的格子不画、不可点。
                    button.isHidden = true
                    buttonDayKeys[index] = ""
                    continue
                }
                button.isHidden = false
                let key = BearyBeijingDay.dayKey(year: cell.0, month: cell.1, day: cell.2)
                let count = counts[key] ?? 0
                button.backgroundColor = Self.color(forLevel: Self.level(forCount: count))
                button.accessibilityLabel = "\(cell.1)月\(cell.2)日，\(count == 0 ? "无日记" : "\(count)篇日记")"
                buttonDayKeys[index] = key
            }
        }
        setNeedsLayout()
    }

    // MARK: - 布局与点按

    override func layoutSubviews() {
        super.layoutSubviews()
        let areaWidth = bounds.width - 28
        guard areaWidth > 0 else { return }
        let gridWidth = areaWidth - Self.weekdayWidth - Self.gridLeadingGap
        let cell = (gridWidth - CGFloat(Self.weeks - 1) * Self.gap) / CGFloat(Self.weeks)
        guard cell > 0 else { return }
        gridCellSize = cell
        let gridHeight = Self.monthRowHeight + Self.monthGridGap + CGFloat(Self.daysPerWeek) * cell + CGFloat(Self.daysPerWeek - 1) * Self.gap
        if gridAreaHeightConstraint?.constant != gridHeight {
            gridAreaHeightConstraint?.constant = gridHeight
        }
        let gridX = Self.weekdayWidth + Self.gridLeadingGap
        let gridTop = Self.monthRowHeight + Self.monthGridGap
        guard let today = BearyBeijingDay.todayComponents(),
              let monday = BearyBeijingDay.mondayOf(year: today.year, month: today.month, day: today.day),
              let windowStart = BearyBeijingDay.shifted(year: monday.0, month: monday.1, day: monday.2, byDays: -26 * 7) else { return }
        // 月份名：每列首日换月时一个，标在该列 x 上；超出右缘的不标（不裁字）。
        var monthLabelIndex = 0
        var previousMonth: Int?
        for col in 0..<Self.weeks {
            guard let cellDate = BearyBeijingDay.shifted(year: windowStart.0, month: windowStart.1, day: windowStart.2, byDays: col * 7) else { continue }
            if previousMonth == cellDate.1 { continue }
            previousMonth = cellDate.1
            let x = gridX + CGFloat(col) * (cell + Self.gap)
            if x + 30 > areaWidth { continue }
            guard monthLabelIndex < monthLabels.count else { continue }
            let label = monthLabels[monthLabelIndex]
            monthLabelIndex += 1
            label.isHidden = false
            label.text = "\(cellDate.1)月"
            label.frame = CGRect(x: x, y: 0, width: 30, height: Self.monthRowHeight)
        }
        for i in monthLabelIndex..<monthLabels.count {
            monthLabels[i].isHidden = true
        }
        // 星期名与格子：行高 = 格高，逐行对齐；星期名框高取整行 pitch，文字居中。
        for row in 0..<Self.daysPerWeek {
            let y = gridTop + CGFloat(row) * (cell + Self.gap)
            weekdayLabels[row].frame = CGRect(x: 0, y: y, width: Self.weekdayWidth, height: cell + Self.gap)
            for col in 0..<Self.weeks {
                let button = dayButtons[col * Self.daysPerWeek + row]
                button.frame = CGRect(x: gridX + CGFloat(col) * (cell + Self.gap), y: y, width: cell, height: cell)
            }
        }
    }

    @objc private func dayButtonTapped(_ sender: UIButton) {
        guard let index = dayButtons.firstIndex(of: sender) else { return }
        selectDay(at: index)
    }

    /// 网格轻点：取离触点最近的可见格中心。阈值 0.75 个 pitch：网格内任意点
    /// 到最近中心的距离上限是半条对角线（≈0.71 pitch），阈值刚好盖住整个
    /// 网格、再带一点点 fat-finger 余量；点到星期名／月份名区的按压离各格
    /// 中心都超过阈值，不触发。
    @objc private func gridTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: gridArea)
        let pitch = gridCellSize + Self.gap
        guard pitch > 0 else { return }
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, button) in dayButtons.enumerated() {
            guard !button.isHidden, !buttonDayKeys[index].isEmpty else { continue }
            let dx = point.x - button.frame.midX
            let dy = point.y - button.frame.midY
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let index = bestIndex,
              bestDistance <= (0.75 * pitch) * (0.75 * pitch) else { return }
        selectDay(at: index)
    }

    private func selectDay(at index: Int) {
        guard index < buttonDayKeys.count else { return }
        let key = buttonDayKeys[index]
        guard !key.isEmpty else { return }
        onSelectDay?(key)
    }

    /// VoiceOver 转子“周”：双指旋转切到“周”后上下滑，逐周跳到每周一。
    private func makeWeekRotor() -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: "周") { [weak self] predicate in
            guard let self else { return nil }
            // 当前焦点所在周；转子刚打开尚无当前项时，按方向从一端起跳。
            let currentWeek: Int
            if let current = predicate.currentItem.targetElement as? UIButton,
               let index = self.dayButtons.firstIndex(of: current) {
                currentWeek = index / Self.daysPerWeek
            } else {
                currentWeek = predicate.searchDirection == .next ? -1 : Self.weeks
            }
            let targetWeek: Int
            switch predicate.searchDirection {
            case .next: targetWeek = currentWeek + 1
            case .previous: targetWeek = currentWeek - 1
            @unknown default: return nil
            }
            guard (0..<Self.weeks).contains(targetWeek) else { return nil }
            // 每周一恒为过去或今天，一定可见、可达。
            let target = self.dayButtons[targetWeek * Self.daysPerWeek]
            return UIAccessibilityCustomRotorItemResult(targetElement: target, targetRange: nil)
        }
    }
}
