import UIKit

// ===== beary 原生时间线页（含写作日历卡）=====
// 对照源（以 worker.js 为准，网页版 beary.html 与设计稿 layout_rest.html 为形态对照）：
// - 列表：GET /beary/api/entries?scope=timeline&limit=50，游标 before=created_at（毫秒）
//   + before_id=entry.id；服务端排序 created_at DESC, id DESC；响应含 entries、
//   trash_count、tl_counts{total, priv, pub, next_pub}；单条 is_public = now >= publish_at。
// - 日历：GET /beary/api/calendar?month=YYYY-MM（仅本人、需登录），按 created_at 北京日界
//   聚合 days{日: {pub, priv}} + month_total + streak（今天没写则从昨天往前连续计数）。
// - 当日：GET /beary/api/entries?scope=timeline&date=YYYY-MM-DD（同为北京日界过滤），
//   请求 limit=200（网页 loadCalDay 口径）；服务端 worker.js 实测 clamp 到 50，
//   日限 10 篇/天，故 50 已兜底，传 200 只是与网页请求口径对齐。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写；
// BearyAPI.swift 一律不动：日历与当日两个方法以 extension 形式放在本文件内，走既有的
// BearyAPI.request 通用请求（URLSession.shared 共享 cookie，401 走 onUnauthorized 通知，
// 回调不在主线程，碰 UI 一律 DispatchQueue.main.async）；颜色只用 BearyColors，
// 不新增玻璃效果，不用 SF Symbol（图标一律 BearyIconImages + 既有 icon_* 资产），
// 无 force unwrap、无裸 id 变量名。本文件不接线：容器（SceneDelegate 侧）负责实例化、
// 设三个回调、做 600 居中列（宽 >=821 时）与底栏胶囊/FAB 的避让（表底 inset 已留 90）。

// MARK: - 日历接口模型（BearyAPI.request + convertFromSnakeCase 解码）

struct BearyCalendarDayCount: Decodable {
    var pub: Int?
    var priv: Int?
}

struct BearyCalendarMonthResponse: Decodable {
    var month: String?
    var days: [String: BearyCalendarDayCount]?
    var monthTotal: Int?
    var streak: Int?
}

extension BearyAPI {
    /// GET /beary/api/calendar?month=YYYY-MM。month 传空即服务端默认当月（北京月）。
    func fetchCalendar(month: String, completion: @escaping (Result<BearyCalendarMonthResponse, APIError>) -> Void) {
        var query: [String: String] = [:]
        if !month.isEmpty { query["month"] = month }
        request("/beary/api/calendar", query: query, completion: completion)
    }

    /// 当日列表：scope=timeline + date=YYYY-MM-DD（北京日）。复用 EntryList 解码
    /// （entries / trash_count / tl_counts 同列表口径；当日模式下调用方只用 entries）。
    func fetchTimelineDay(date: String, completion: @escaping (Result<EntryList, APIError>) -> Void) {
        request("/beary/api/entries", query: ["scope": "timeline", "date": date, "limit": "200"], completion: completion)
    }
}

// MARK: - 北京日界（与服务端 (created_at + 8h) 日界同一口径）

enum BearyBeijingDay {
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? TimeZone.current
        cal.firstWeekday = 2
        return cal
    }

    static func pad2(_ value: Int) -> String {
        return value < 10 ? "0\(value)" : "\(value)"
    }

    static func monthKey(year: Int, month: Int) -> String {
        return "\(year)-\(pad2(month))"
    }

    static func dayKey(year: Int, month: Int, day: Int) -> String {
        return "\(year)-\(pad2(month))-\(pad2(day))"
    }

    /// 毫秒时间戳 → 北京年月日。
    static func components(ofMs ms: Int) -> (year: Int, month: Int, day: Int)? {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        return (year, month, day)
    }

    static func dayKey(ofMs ms: Int) -> String? {
        guard let c = components(ofMs: ms) else { return nil }
        return dayKey(year: c.year, month: c.month, day: c.day)
    }

    static func date(year: Int, month: Int, day: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps)
    }

    static func todayComponents() -> (year: Int, month: Int, day: Int)? {
        return components(ofMs: Int(Date().timeIntervalSince1970 * 1000.0))
    }

    /// 北京日序号（自 epoch 起的天数），用于“未来日”比较与周一计算。
    static func dayNumber(year: Int, month: Int, day: Int) -> Int? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        return Int(floor((date.timeIntervalSince1970 + 8 * 3600) / 86400))
    }

    static func todayNumber() -> Int? {
        guard let c = todayComponents() else { return nil }
        return dayNumber(year: c.year, month: c.month, day: c.day)
    }

    static func mondayOf(year: Int, month: Int, day: Int) -> (year: Int, month: Int, day: Int)? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: monday)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return (y, m, d)
    }

    static func shifted(year: Int, month: Int, day: Int, byDays delta: Int) -> (year: Int, month: Int, day: Int)? {
        guard let date = date(year: year, month: month, day: day) else { return nil }
        guard let moved = calendar.date(byAdding: .day, value: delta, to: date) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day], from: moved)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return (y, m, d)
    }

    static func shiftedMonth(year: Int, month: Int, byMonths delta: Int) -> (year: Int, month: Int)? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let date = calendar.date(from: comps) else { return nil }
        guard let moved = calendar.date(byAdding: .month, value: delta, to: date) else { return nil }
        let out = calendar.dateComponents([.year, .month], from: moved)
        guard let y = out.year, let m = out.month else { return nil }
        return (y, m)
    }

    static func daysInMonth(year: Int, month: Int) -> Int? {
        guard let date = date(year: year, month: month, day: 1) else { return nil }
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return nil }
        return range.count
    }
}

// MARK: - 日历几何标记（网页 calMarksHtml 口径，原样移植）

enum BearyCalendarMarkColor {
    case published
    case unpublished

    var uiColor: UIColor {
        switch self {
        case .published: return BearyColors.orange
        case .unpublished: return BearyColors.blue
        }
    }
}

enum BearyCalendarMarkKind {
    case dot
    case triangle
    case square
    case pentagon
}

struct BearyCalendarMark {
    var kind: BearyCalendarMarkKind
    var color: BearyCalendarMarkColor
    var size: CGFloat
}

enum BearyCalendarMarks {
    /// 网页口径：1 篇 1 个 6pt 圆点；2 篇 2 点（混合时橙蓝各一）；3 三角、4 方、5 五边、
    /// 6 五边+1 点、7 五边+2 点、8+ 按 7 封顶；主形状取篇数多一方（一样多取橙=公开优先），
    /// 混合时末尾再加 1 个 5pt 异色小点（“形状旁的异色小点 = 两种状态都有”）。
    static func marks(published: Int, unpublished: Int) -> [BearyCalendarMark] {
        let total = published + unpublished
        if total <= 0 { return [] }
        let mixed = published > 0 && unpublished > 0
        let main: BearyCalendarMarkColor
        if unpublished == 0 {
            main = .published
        } else if published == 0 {
            main = .unpublished
        } else if published >= unpublished {
            main = .published
        } else {
            main = .unpublished
        }
        let other: BearyCalendarMarkColor = (main == .published) ? .unpublished : .published
        if total == 1 { return [BearyCalendarMark(kind: .dot, color: main, size: 6)] }
        if total == 2 {
            if mixed {
                return [
                    BearyCalendarMark(kind: .dot, color: .published, size: 6),
                    BearyCalendarMark(kind: .dot, color: .unpublished, size: 6),
                ]
            }
            return [
                BearyCalendarMark(kind: .dot, color: main, size: 6),
                BearyCalendarMark(kind: .dot, color: main, size: 6),
            ]
        }
        let capped = min(total, 7)
        var out: [BearyCalendarMark] = []
        if capped == 3 {
            out.append(BearyCalendarMark(kind: .triangle, color: main, size: 12))
        } else if capped == 4 {
            out.append(BearyCalendarMark(kind: .square, color: main, size: 11))
        } else {
            out.append(BearyCalendarMark(kind: .pentagon, color: main, size: 12))
            if capped >= 6 { out.append(BearyCalendarMark(kind: .dot, color: main, size: 6)) }
            if capped >= 7 { out.append(BearyCalendarMark(kind: .dot, color: main, size: 6)) }
        }
        if mixed { out.append(BearyCalendarMark(kind: .dot, color: other, size: 5)) }
        return out
    }
}

/// 一行几何标记：横向 gap 2、高 13（网页 .cal-dots 口径），用 UIBezierPath 实心绘制。
final class BearyCalendarMarkView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // 黑圈根因之一：本视图从未设过背景。UIView 默认不透明，nil 背景
        // 在不透明图层上会画成黑块（沙漏 BearyHourglassView 同款教训，已在
        // 其 init 里用 .clear + isOpaque=false 修过）；此处照抄该 fix：
        // 显式透明底 + 非不透明，标记行只剩几何图形本身。
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    var marks: [BearyCalendarMark] = [] {
        didSet { invalidateIntrinsicContentSize(); setNeedsDisplay() }
    }

    override var intrinsicContentSize: CGSize {
        var width: CGFloat = 0
        for (index, mark) in marks.enumerated() {
            if index > 0 { width += 2 }
            width += mark.size
        }
        return CGSize(width: width, height: 13)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        var cursor: CGFloat = 0
        for mark in marks {
            let top = (13 - mark.size) / 2
            let box = CGRect(x: cursor, y: top, width: mark.size, height: mark.size)
            let path: UIBezierPath
            switch mark.kind {
            case .dot:
                path = UIBezierPath(ovalIn: box)
            case .triangle:
                let size = mark.size
                path = UIBezierPath()
                path.move(to: CGPoint(x: box.minX + size / 2, y: box.minY + 0.8))
                path.addLine(to: CGPoint(x: box.minX + size - 0.7, y: box.minY + size - 0.8))
                path.addLine(to: CGPoint(x: box.minX + 0.7, y: box.minY + size - 0.8))
                path.close()
            case .square:
                path = UIBezierPath(rect: CGRect(x: box.minX + 0.5, y: box.minY + 0.5, width: mark.size - 1, height: mark.size - 1))
            case .pentagon:
                let center = CGPoint(x: box.midX, y: box.midY)
                let radius = mark.size / 2 - 0.4
                path = UIBezierPath()
                for index in 0..<5 {
                    let angle = -Double.pi / 2 + Double(index) * (2 * Double.pi / 5)
                    let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                path.close()
            }
            mark.color.uiColor.resolvedColor(with: traitCollection).setFill()
            path.fill()
            cursor += mark.size + 2
        }
    }
}

// MARK: - 日历格子模型

struct BearyCalendarDay {
    var year: Int
    var month: Int
    var day: Int
    var isOffMonth: Bool
    var isFuture: Bool
    var isToday: Bool
    var isSelected: Bool
    var published: Int
    var unpublished: Int
    var dataLoaded: Bool

    var key: String {
        return BearyBeijingDay.dayKey(year: year, month: month, day: day)
    }

    /// 网页口径（calCellBtn）：缓存缺省即 {pub:0,priv:0}，空日禁用；未来日禁用；
    /// 跨月占位格禁用。未加载月份的格子因此也是禁用态，待月份补拉到达、
    /// renderCalendar 重渲后才启用（与网页 calPatchDots 到达后启用一致）。
    var isEnabled: Bool {
        if isOffMonth || isFuture { return false }
        return published + unpublished > 0
    }
}

// MARK: - 日历格子按钮（数字圆 30 + 标记行 13，格高 50，网页 .cal-d 口径）

final class BearyCalendarDayButton: UIButton {
    private let numberLabel = UILabel()
    private let markView = BearyCalendarMarkView()
    private(set) var dayValue: BearyCalendarDay?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 黑圈根因之二：见 configure 注释。数字 label 同样显式非不透明，
        // 避免 nil/.clear 背景在不透明图层上被画成黑底。
        numberLabel.isOpaque = false
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.textAlignment = .center
        numberLabel.font = UIFont.systemFont(ofSize: 15)
        markView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)
        addSubview(markView)
        NSLayoutConstraint.activate([
            numberLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 30),
            numberLabel.heightAnchor.constraint(equalToConstant: 30),
            markView.topAnchor.constraint(equalTo: numberLabel.bottomAnchor, constant: 1),
            markView.centerXAnchor.constraint(equalTo: centerXAnchor),
            markView.heightAnchor.constraint(equalToConstant: 13),
            heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 网页 .cal-d.dis .n 口径：color-mix(in srgb, var(--gray) 55%, transparent)，
    /// 即 gray 降到 55% 透明度，不是满值 gray。必须用 trait 闭包从 BearyColors.gray
    /// 现取再降透明度：浅色取 #737373、深色取 #a8a8a8，各自再取 55%，深色下也不错。
    private static var disabledTextColor: UIColor {
        return UIColor { trait in
            BearyColors.gray.resolvedColor(with: trait).withAlphaComponent(0.55)
        }
    }

    func configure(day: BearyCalendarDay) {
        dayValue = day
        numberLabel.text = "\(day.day)"
        // F3：格子补网页 aria 口径无障碍文案（空日“无日记”）。
        let dayTotal = day.published + day.unpublished
        if dayTotal > 0 {
            accessibilityLabel = "\(day.month)月\(day.day)日，共 \(dayTotal) 篇，其中 \(day.unpublished) 篇未公开"
        } else {
            accessibilityLabel = "\(day.month)月\(day.day)日，无日记"
        }
        markView.marks = day.isOffMonth ? [] : BearyCalendarMarks.marks(published: day.published, unpublished: day.unpublished)
        // 标记行背景每格都显式清透明（init 已设，此处防复用残留）。
        markView.backgroundColor = .clear
        isEnabled = day.isEnabled
        numberLabel.layer.cornerRadius = 15
        numberLabel.layer.masksToBounds = true
        numberLabel.layer.borderWidth = 0
        // 黑圈根因（截图 19-24 日全黑、25 日正常已证实）：选中判定本身是对的
        // （只有 25 日是白字，即只有它走了 isSelected 分支；24 日灰字、19-23 日
        // 墨字也都符合各自文字分支）——错在背景侧：选中分支是全函数唯一设实色
        // 的地方，其余分支全写 nil 背景；nil 不是透明，在不透明图层上会画成
        // 黑底，于是非选中日也顶着墨色圆、文字（墨/灰）糊在上面；
        // 标记行更是从未设过背景，整行宽都黑。上一批只改了禁用文字灰度，没动
        // 背景，所以漏了这一处。修复：非选中分支一律显式 .clear（配合 init 的
        // isOpaque=false，才是真透明），选中分支保持墨底白字不变；几何标记不动。
        if day.isOffMonth {
            numberLabel.textColor = BearyColors.line
            numberLabel.font = UIFont.systemFont(ofSize: 15)
            numberLabel.backgroundColor = .clear
        } else if day.isSelected {
            // 网页 .sel 后于 .today：选中态盖过今天态（墨底白字）。
            numberLabel.textColor = BearyColors.bg
            numberLabel.font = UIFont.boldSystemFont(ofSize: 15)
            numberLabel.backgroundColor = BearyColors.ink
        } else if day.isToday {
            numberLabel.textColor = BearyColors.orange
            numberLabel.font = UIFont.boldSystemFont(ofSize: 15)
            numberLabel.backgroundColor = .clear
            numberLabel.layer.borderWidth = 1.5
            numberLabel.layer.borderColor = BearyColors.orange.cgColor
        } else if !day.isEnabled {
            numberLabel.textColor = BearyCalendarDayButton.disabledTextColor
            numberLabel.font = UIFont.systemFont(ofSize: 15)
            numberLabel.backgroundColor = .clear
        } else {
            numberLabel.textColor = BearyColors.ink
            numberLabel.font = UIFont.systemFont(ofSize: 15)
            numberLabel.backgroundColor = .clear
        }
    }
}

// MARK: - 日历卡（网页 .cal-card：边框 1 line、圆角 14、padding 14/14/10、底色 surface）

final class BearyCalendarCardView: UIView {
    enum ViewMode {
        case week
        case month
    }

    var onSelectDay: ((BearyCalendarDay) -> Void)?
    var onToggleView: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onJumpToToday: (() -> Void)?

    private let titleLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private let prevButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let todayButton = UIButton(type: .system)
    private let gridStack = UIStackView()
    private let weekNoteLabel = UILabel()
    private let monthLegendStack = UIStackView()
    private var dayButtons: [BearyCalendarDayButton] = []
    /// 按日期 key 复用的日期按钮（网页 calReuseGrid 口径）：切换视图/数据刷新时
    /// 只移动/新建格子，不整表重建；复用节点不重播月格入场错峰。
    private var buttonByKey: [String: BearyCalendarDayButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.surface
        layer.borderWidth = 1
        layer.borderColor = BearyColors.line.cgColor
        layer.cornerRadius = 14
        layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = BearyColors.ink

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.backgroundColor = BearyColors.faint
        toggleButton.layer.cornerRadius = 16
        toggleButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 12.5)
        toggleButton.setTitleColor(BearyColors.ink, for: .normal)
        toggleButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        toggleButton.addTarget(self, action: #selector(didTapToggle), for: .touchUpInside)

        prevButton.translatesAutoresizingMaskIntoConstraints = false
        prevButton.backgroundColor = BearyColors.faint
        prevButton.layer.cornerRadius = 16
        prevButton.tintColor = BearyColors.gray
        if let chevron = BearyIconImages.image(named: "icon_chevron_right", pointSize: 15) {
            prevButton.setImage(chevron, for: .normal)
            prevButton.imageView?.transform = CGAffineTransform(rotationAngle: CGFloat(Double.pi))
        } else {
            // I14：资产缺失时补文字回退，翻页路径不断。
            prevButton.setTitle("‹", for: .normal)
            prevButton.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        }
        prevButton.addTarget(self, action: #selector(didTapPrevious), for: .touchUpInside)

        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.backgroundColor = BearyColors.faint
        nextButton.layer.cornerRadius = 16
        nextButton.tintColor = BearyColors.gray
        if let chevron = BearyIconImages.image(named: "icon_chevron_right", pointSize: 15) {
            nextButton.setImage(chevron, for: .normal)
        } else {
            // I14：资产缺失时补文字回退，翻页路径不断。
            nextButton.setTitle("›", for: .normal)
            nextButton.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        }
        nextButton.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)

        // 清单 6 回到今天：卡内独立一行、右对齐的常驻 pill（不塞进顶栏，
        // 避免 320pt 窄屏下标题/周月切换/翻页钮挤压截断；常驻则周月步进时
        // 卡高不跳变，performCalendarTransition 的高度动画不受影响）。
        todayButton.translatesAutoresizingMaskIntoConstraints = false
        todayButton.backgroundColor = BearyColors.faint
        todayButton.layer.cornerRadius = 14
        todayButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 12.5)
        todayButton.setTitleColor(BearyColors.ink, for: .normal)
        todayButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        todayButton.setTitle("回到今天", for: .normal)
        todayButton.accessibilityLabel = "回到今天"
        todayButton.addTarget(self, action: #selector(didTapToday), for: .touchUpInside)
        let todaySpacer = UIView()
        let todayRow = UIStackView(arrangedSubviews: [todaySpacer, todayButton])
        todayRow.translatesAutoresizingMaskIntoConstraints = false
        todayRow.axis = .horizontal
        todayRow.alignment = .center

        let topRow = UIStackView(arrangedSubviews: [titleLabel, toggleButton, prevButton, nextButton])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6
        topRow.setCustomSpacing(0, after: titleLabel)

        let weekdayRow = UIStackView()
        weekdayRow.translatesAutoresizingMaskIntoConstraints = false
        weekdayRow.axis = .horizontal
        weekdayRow.distribution = .fillEqually
        for weekdayName in ["一", "二", "三", "四", "五", "六", "日"] {
            let label = UILabel()
            label.text = weekdayName
            label.font = UIFont.systemFont(ofSize: 12)
            label.textColor = BearyColors.gray
            label.textAlignment = .center
            weekdayRow.addArrangedSubview(label)
        }

        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridStack.axis = .vertical

        weekNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        weekNoteLabel.text = "橙 = 已公开 · 蓝 = 未公开"
        weekNoteLabel.font = UIFont.systemFont(ofSize: 12)
        weekNoteLabel.textColor = BearyColors.gray
        weekNoteLabel.textAlignment = .center

        monthLegendStack.translatesAutoresizingMaskIntoConstraints = false
        monthLegendStack.axis = .vertical
        monthLegendStack.alignment = .center
        monthLegendStack.spacing = 2
        monthLegendStack.addArrangedSubview(legendRow(items: [
            (BearyCalendarMarks.marks(published: 1, unpublished: 0), "1 篇"),
            (BearyCalendarMarks.marks(published: 2, unpublished: 0), "2 篇"),
            (BearyCalendarMarks.marks(published: 3, unpublished: 0), "3 篇"),
            (BearyCalendarMarks.marks(published: 4, unpublished: 0), "4 篇"),
        ]))
        monthLegendStack.addArrangedSubview(legendRow(items: [
            (BearyCalendarMarks.marks(published: 5, unpublished: 0), "5 篇"),
            (BearyCalendarMarks.marks(published: 6, unpublished: 0), "6 篇"),
            (BearyCalendarMarks.marks(published: 7, unpublished: 0), "7 篇起"),
        ]))
        let legendNote = UILabel()
        legendNote.text = "橙 = 已公开 · 蓝 = 未公开 · 形状旁的异色小点 = 两种状态都有"
        legendNote.font = UIFont.systemFont(ofSize: 12)
        legendNote.textColor = BearyColors.gray
        legendNote.textAlignment = .center
        legendNote.numberOfLines = 0
        monthLegendStack.addArrangedSubview(legendNote)

        let outer = UIStackView(arrangedSubviews: [topRow, todayRow, weekdayRow, gridStack, weekNoteLabel, monthLegendStack])
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.axis = .vertical
        outer.spacing = 0
        outer.setCustomSpacing(8, after: topRow)
        outer.setCustomSpacing(8, after: todayRow)
        outer.setCustomSpacing(6, after: weekdayRow)
        outer.setCustomSpacing(10, after: gridStack)
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            toggleButton.heightAnchor.constraint(equalToConstant: 32),
            prevButton.widthAnchor.constraint(equalToConstant: 32),
            prevButton.heightAnchor.constraint(equalToConstant: 32),
            nextButton.widthAnchor.constraint(equalToConstant: 32),
            nextButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = BearyColors.line.cgColor
    }

    private func legendRow(items: [(marks: [BearyCalendarMark], text: String)]) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        for item in items {
            let markView = BearyCalendarMarkView()
            markView.marks = item.marks
            let label = UILabel()
            label.text = item.text
            label.font = UIFont.systemFont(ofSize: 12)
            label.textColor = BearyColors.gray
            let pair = UIStackView(arrangedSubviews: [markView, label])
            pair.axis = .horizontal
            pair.spacing = 5
            pair.alignment = .center
            row.addArrangedSubview(pair)
        }
        return row
    }

    func setTitle(_ text: String) {
        titleLabel.text = text
    }

    /// 周视图下按钮文案为“月视图”，月视图下为“周视图”（网页 calViewBtn 口径）。
    func setToggleTitle(_ text: String) {
        toggleButton.setTitle(text, for: .normal)
    }

    func setNavigation(prevEnabled: Bool, nextEnabled: Bool) {
        prevButton.isEnabled = prevEnabled
        nextButton.isEnabled = nextEnabled
        prevButton.alpha = prevEnabled ? 1 : 0.35
        nextButton.alpha = nextEnabled ? 1 : 0.35
    }

    /// weekKeys：月视图入场错峰时要跳过的本周日期 key（网页 calStaggerMonthCells
    /// 口径：本周格子不加 .cal-in）。周视图下本参数无用。
    func render(days: [BearyCalendarDay], mode: ViewMode, weekKeys: Set<String> = []) {
        // F3：翻页钮按周/月模式补无障碍文案。
        prevButton.accessibilityLabel = (mode == .week) ? "上一周" : "上个月"
        nextButton.accessibilityLabel = (mode == .week) ? "下一周" : "下个月"
        let wantedKeys = Set(days.map { $0.key })
        for key in Array(buttonByKey.keys) {
            if !wantedKeys.contains(key) {
                if let stale = buttonByKey[key] {
                    stale.removeFromSuperview()
                }
                buttonByKey[key] = nil
            }
        }
        for row in gridStack.arrangedSubviews {
            gridStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        dayButtons = []
        let staggerEnabled = (mode == .month) && !UIAccessibility.isReduceMotionEnabled
        var staggerIndex = 0
        var index = 0
        while index < days.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            for _ in 0..<7 {
                if index < days.count {
                    let day = days[index]
                    let isNewButton = buttonByKey[day.key] == nil
                    let button: BearyCalendarDayButton
                    if let reused = buttonByKey[day.key] {
                        button = reused
                        button.alpha = 1
                        button.transform = .identity
                    } else {
                        // 注意：不用 (type: .system)——UIButton 的 type 初始化会绕过子类的
                        // init(frame:) 自定义搭建（已知坑），frame 初始化才是 custom 型且必走搭建。
                        button = BearyCalendarDayButton(frame: .zero)
                        button.addTarget(self, action: #selector(didTapDay(_:)), for: .touchUpInside)
                        buttonByKey[day.key] = button
                    }
                    button.configure(day: day)
                    button.removeFromSuperview()
                    row.addArrangedSubview(button)
                    dayButtons.append(button)
                    if staggerEnabled && isNewButton && !weekKeys.contains(day.key) {
                        let delay = min(Double(staggerIndex) * 0.018, 0.24)
                        staggerIndex += 1
                        button.alpha = 0
                        button.transform = CGAffineTransform(translationX: 0, y: 6)
                        UIView.animate(withDuration: 0.32, delay: delay, options: .curveEaseOut, animations: {
                            button.alpha = 1
                            button.transform = .identity
                        }, completion: nil)
                    }
                    index += 1
                } else {
                    let spacer = UIView()
                    row.addArrangedSubview(spacer)
                }
            }
            gridStack.addArrangedSubview(row)
        }
        weekNoteLabel.isHidden = (mode != .week)
        monthLegendStack.isHidden = (mode != .month)
    }

    @objc private func didTapToggle() {
        onToggleView?()
    }

    @objc private func didTapPrevious() {
        onPrevious?()
    }

    @objc private func didTapNext() {
        onNext?()
    }

    @objc private func didTapToday() {
        onJumpToToday?()
    }

    @objc private func didTapDay(_ sender: BearyCalendarDayButton) {
        guard let day = sender.dayValue else { return }
        onSelectDay?(day)
    }
}

// MARK: - 时间线行（网页 .tl-card：边框 1 line、圆角 14、padding 12/14；正文 16.5/1.75）

final class BearyTimelineCell: UITableViewCell {
    static let reuseIdentifier = "BearyTimelineCell"

    private let cardView = UIView()
    private let metaStack = UIStackView()
    private let timeLabel = UILabel()
    private let pillBackground = UIView()
    private let pillLabel = UILabel()
    private let weatherLabel = UILabel()
    private let moodLabel = UILabel()
    private let recipientLabel = UILabel()
    private let contentLabel = UILabel()
    private let thumbsScrollView = UIScrollView()
    private let thumbsStack = UIStackView()
    private let footStack = UIStackView()
    private var thumbsHeightConstraint: NSLayoutConstraint?
    private weak var cardStackReference: UIStackView?
    private var thumbImageViews: [UIImageView] = []

    // TL-1 竖线 + 圆点：线 x=11 宽 2（与 .tl:before 一致）；圆点中心 x=12 与线对齐，
    // 公开 14px 墨圆点（2.5 bg 边 + 1.5 line 外环），私密 9px 蓝空心圆（无外环）。
    private let timelineLineView = UIView()
    private let dotRingView = UIView()
    private let dotView = UIView()
    private var dotSizeConstraint: NSLayoutConstraint?
    private var dotRingSizeConstraint: NSLayoutConstraint?
    private var dotTopConstraint: NSLayoutConstraint?
    // TL-2 沙漏：无 hourglass 资产（资产清单里只有 icon_*，无沙漏/时钟），故按
    // beary.html #beary-hourglass sprite 路径程序化描边绘制，不新增资产、不写 emoji。
    private let hourglassView = BearyHourglassView()
    private var pillLabelLeadingWithIcon: NSLayoutConstraint?
    private var pillLabelLeadingWithoutIcon: NSLayoutConstraint?
    // TL-3 引用卡与私密操作行。
    private let quoteButton = UIButton(type: .custom)
    private let quoteIconView = UIImageView()
    private let quoteTitleLabel = UILabel()
    private let quoteBodyLabel = UILabel()
    private let quoteThumbsStack = UIStackView()
    private var quoteThumbImageViews: [UIImageView] = []
    private var currentEntry: Entry?
    var onEditEntry: ((Entry) -> Void)?
    var onDeleteEntry: ((Entry) -> Void)?
    var onQuoteEntry: ((String) -> Void)?
    /// N7 时间线图片灯箱：主图条点按回调（keys=本条过滤后图 key，index=点按位置），
    /// VC 侧复用详情文件内的 BearyEntryImageViewerViewController 全屏弹出；
    /// 引用卡小图不走此路（点按引用卡仍走 onQuoteEntry 打开被引用日记）。
    var onTapImages: (([String], Int) -> Void)?
    private let actsStack = UIStackView()
    private let statusIconView = UIImageView()
    private let editStatusLabel = UILabel()
    private let editButton = UIButton(type: .custom)
    private let deleteButton = UIButton(type: .custom)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = BearyColors.bg
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = BearyColors.line.cgColor
        cardView.layer.cornerRadius = 14
        cardView.layer.masksToBounds = true

        timeLabel.font = UIFont.systemFont(ofSize: 12.5)
        timeLabel.textColor = BearyColors.gray
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        pillBackground.translatesAutoresizingMaskIntoConstraints = false
        pillBackground.layer.cornerRadius = 10
        pillBackground.layer.masksToBounds = true
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = UIFont.boldSystemFont(ofSize: 11.5)
        hourglassView.translatesAutoresizingMaskIntoConstraints = false
        pillBackground.addSubview(hourglassView)
        pillBackground.addSubview(pillLabel)
        pillLabelLeadingWithIcon = pillLabel.leadingAnchor.constraint(equalTo: hourglassView.trailingAnchor, constant: 4)
        pillLabelLeadingWithoutIcon = pillLabel.leadingAnchor.constraint(equalTo: pillBackground.leadingAnchor, constant: 9)
        NSLayoutConstraint.activate([
            hourglassView.leadingAnchor.constraint(equalTo: pillBackground.leadingAnchor, constant: 9),
            hourglassView.centerYAnchor.constraint(equalTo: pillBackground.centerYAnchor),
            hourglassView.widthAnchor.constraint(equalToConstant: 12),
            hourglassView.heightAnchor.constraint(equalToConstant: 12),
            pillLabel.topAnchor.constraint(equalTo: pillBackground.topAnchor, constant: 2.5),
            pillLabel.trailingAnchor.constraint(equalTo: pillBackground.trailingAnchor, constant: -9),
            pillLabel.bottomAnchor.constraint(equalTo: pillBackground.bottomAnchor, constant: -2.5),
        ])
        pillLabelLeadingWithoutIcon?.isActive = true

        weatherLabel.font = UIFont.systemFont(ofSize: 12.5)
        weatherLabel.textColor = BearyColors.gray
        // L12（“或”分支）：天气/心情单行截断 + 横向低压缩，空间不足时先缩它们，
        // 时间（required）与 pill 绝不被挤到重叠。
        weatherLabel.numberOfLines = 1
        weatherLabel.lineBreakMode = .byTruncatingTail
        weatherLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        moodLabel.font = UIFont.systemFont(ofSize: 12.5)
        moodLabel.textColor = BearyColors.gray
        moodLabel.numberOfLines = 1
        moodLabel.lineBreakMode = .byTruncatingTail
        moodLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recipientLabel.font = UIFont.boldSystemFont(ofSize: 12.5)
        recipientLabel.textColor = BearyColors.orange
        // 网页 .tl-to 口径：单行 + max-width 170 + ellipsis，超出截断不撑开 meta 行。
        // meta 是单行横向 stack、不会像网页 .tl-meta 那样 flex-wrap 换行，故长名字必须
        // 在此先让位：横向抗压缩调到最低，空间不足时先缩它（带省略号），时间（required）
        // 与 pill 绝不被它挤到重叠；纵向抱紧 + 宽 ≤170，上限内按本长显示、不拉伸。
        recipientLabel.numberOfLines = 1
        recipientLabel.lineBreakMode = .byTruncatingTail
        recipientLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recipientLabel.setContentHuggingPriority(.required, for: .horizontal)
        recipientLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true

        metaStack.translatesAutoresizingMaskIntoConstraints = false
        metaStack.axis = .horizontal
        metaStack.spacing = 8
        metaStack.alignment = .center

        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.font = UIFont.systemFont(ofSize: 16.5)
        contentLabel.textColor = BearyColors.ink
        contentLabel.numberOfLines = 0
        contentLabel.attributedText = nil

        thumbsScrollView.translatesAutoresizingMaskIntoConstraints = false
        thumbsScrollView.showsHorizontalScrollIndicator = false
        thumbsStack.translatesAutoresizingMaskIntoConstraints = false
        thumbsStack.axis = .horizontal
        thumbsStack.spacing = 6
        thumbsScrollView.addSubview(thumbsStack)
        NSLayoutConstraint.activate([
            thumbsStack.topAnchor.constraint(equalTo: thumbsScrollView.topAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: thumbsScrollView.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: thumbsScrollView.trailingAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: thumbsScrollView.bottomAnchor),
            thumbsStack.heightAnchor.constraint(equalToConstant: 74),
        ])

        footStack.translatesAutoresizingMaskIntoConstraints = false
        footStack.axis = .horizontal
        footStack.spacing = 16
        footStack.alignment = .center

        timelineLineView.translatesAutoresizingMaskIntoConstraints = false
        timelineLineView.backgroundColor = BearyColors.line
        dotRingView.translatesAutoresizingMaskIntoConstraints = false
        dotRingView.backgroundColor = BearyColors.line
        dotRingView.layer.masksToBounds = true
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.layer.masksToBounds = true

        quoteButton.translatesAutoresizingMaskIntoConstraints = false
        quoteButton.backgroundColor = BearyColors.faint
        quoteButton.layer.borderWidth = 1
        quoteButton.layer.borderColor = BearyColors.line.cgColor
        quoteButton.layer.cornerRadius = 12
        quoteButton.layer.masksToBounds = true
        quoteButton.contentHorizontalAlignment = .left
        quoteButton.addTarget(self, action: #selector(quoteTapped), for: .touchUpInside)
        quoteIconView.translatesAutoresizingMaskIntoConstraints = false
        quoteIconView.tintColor = BearyColors.gray
        quoteTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteTitleLabel.font = UIFont.systemFont(ofSize: 12.5)
        quoteTitleLabel.textColor = BearyColors.gray
        quoteBodyLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteBodyLabel.font = UIFont.systemFont(ofSize: 14.5)
        quoteBodyLabel.textColor = BearyColors.ink
        quoteBodyLabel.numberOfLines = 0
        let quoteTitleRow = UIStackView(arrangedSubviews: [quoteIconView, quoteTitleLabel])
        quoteTitleRow.translatesAutoresizingMaskIntoConstraints = false
        quoteTitleRow.axis = .horizontal
        quoteTitleRow.spacing = 4
        quoteTitleRow.alignment = .center
        // F2：引用缩略图行（网页 tl-qcard 内 .quote-thumbs 口径）：无图时隐藏不占位。
        quoteThumbsStack.translatesAutoresizingMaskIntoConstraints = false
        quoteThumbsStack.axis = .horizontal
        quoteThumbsStack.spacing = 6
        quoteThumbsStack.isHidden = true
        let quoteStack = UIStackView(arrangedSubviews: [quoteTitleRow, quoteBodyLabel, quoteThumbsStack])
        quoteStack.translatesAutoresizingMaskIntoConstraints = false
        quoteStack.axis = .vertical
        quoteStack.spacing = 4
        quoteButton.addSubview(quoteStack)
        NSLayoutConstraint.activate([
            quoteIconView.widthAnchor.constraint(equalToConstant: 14),
            quoteIconView.heightAnchor.constraint(equalToConstant: 14),
            quoteStack.topAnchor.constraint(equalTo: quoteButton.topAnchor, constant: 10),
            quoteStack.leadingAnchor.constraint(equalTo: quoteButton.leadingAnchor, constant: 12),
            quoteStack.trailingAnchor.constraint(equalTo: quoteButton.trailingAnchor, constant: -12),
            quoteStack.bottomAnchor.constraint(equalTo: quoteButton.bottomAnchor, constant: -10),
        ])

        editStatusLabel.font = UIFont.systemFont(ofSize: 12.5)
        editStatusLabel.textColor = BearyColors.gray
        // I11：私密操作行文案前加 13px 状态图标（可编辑 icon_edit / 已结束 icon_lock）。
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.tintColor = BearyColors.gray
        statusIconView.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            statusIconView.widthAnchor.constraint(equalToConstant: 13),
            statusIconView.heightAnchor.constraint(equalToConstant: 13),
        ])
        if let editImage = BearyIconImages.image(named: "icon_edit", pointSize: 14) {
            editButton.setImage(editImage, for: .normal)
        }
        editButton.tintColor = BearyColors.gray
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 14) {
            deleteButton.setImage(trashImage, for: .normal)
        }
        deleteButton.tintColor = BearyColors.red
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        actsStack.translatesAutoresizingMaskIntoConstraints = false
        actsStack.axis = .horizontal
        actsStack.spacing = 12
        actsStack.alignment = .center
        let actsSpacer = UIView()
        actsStack.addArrangedSubview(statusIconView)
        actsStack.addArrangedSubview(editStatusLabel)
        actsStack.addArrangedSubview(actsSpacer)
        actsStack.addArrangedSubview(editButton)
        actsStack.addArrangedSubview(deleteButton)
        NSLayoutConstraint.activate([
            editButton.widthAnchor.constraint(equalToConstant: 32),
            editButton.heightAnchor.constraint(equalToConstant: 32),
            deleteButton.widthAnchor.constraint(equalToConstant: 32),
            deleteButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        let cardStack = UIStackView(arrangedSubviews: [metaStack, contentLabel, quoteButton, thumbsScrollView, footStack, actsStack])
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.axis = .vertical
        cardStack.spacing = 0
        cardStack.setCustomSpacing(6, after: metaStack)
        cardStack.setCustomSpacing(9, after: contentLabel)
        cardStack.setCustomSpacing(10, after: quoteButton)
        cardStack.setCustomSpacing(9, after: thumbsScrollView)
        cardStack.setCustomSpacing(9, after: footStack)
        cardStackReference = cardStack
        cardView.addSubview(cardStack)
        contentView.addSubview(cardView)
        contentView.addSubview(timelineLineView)
        contentView.addSubview(dotRingView)
        contentView.addSubview(dotView)
        dotSizeConstraint = dotView.widthAnchor.constraint(equalToConstant: 14)
        dotRingSizeConstraint = dotRingView.widthAnchor.constraint(equalToConstant: 17)
        dotTopConstraint = dotView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        NSLayoutConstraint.activate([
            timelineLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            timelineLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            timelineLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 11),
            timelineLineView.widthAnchor.constraint(equalToConstant: 2),
            dotRingView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            dotRingView.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            dotView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
        ])
        // 可选约束逐条激活（不可直接放进 activate 数组，类型不匹配）。
        dotTopConstraint?.isActive = true
        dotSizeConstraint?.isActive = true
        dotRingSizeConstraint?.isActive = true
        dotView.heightAnchor.constraint(equalTo: dotView.widthAnchor).isActive = true
        dotRingView.heightAnchor.constraint(equalTo: dotRingView.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
        ])
        // 无图时把图片条高度约束压到 0（只靠 hidden 不够：显式高度约束仍会撑开 stack）。
        thumbsHeightConstraint = thumbsScrollView.heightAnchor.constraint(equalToConstant: 74)
        thumbsHeightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        cardView.layer.borderColor = BearyColors.line.cgColor
        timelineLineView.backgroundColor = BearyColors.line
        dotRingView.backgroundColor = BearyColors.line
        // C1：私密圆点边框按当前 isPublic 重设（公开 bg、私密蓝），
        // 不得无条件写 bg（否则主题切换后私密蓝圈变隐形）。
        if let entry = currentEntry {
            let published = entry.isPublic ?? false
            dotView.backgroundColor = published ? BearyColors.ink : BearyColors.bg
            dotView.layer.borderColor = (published ? BearyColors.bg : BearyColors.blue).cgColor
        } else {
            dotView.layer.borderColor = BearyColors.bg.cgColor
        }
        quoteButton.layer.borderColor = BearyColors.line.cgColor
        hourglassView.setNeedsDisplay()
    }

    /// U14：行点按给卡片短暂 faint 底色（selectionStyle 已是 .none，
    /// 但 setHighlighted 仍由 tableView 在点按时调用；按钮上的点按不走此路）。
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        let apply = {
            self.cardView.backgroundColor = highlighted ? BearyColors.faint : BearyColors.bg
        }
        if animated {
            UIView.animate(withDuration: 0.15, animations: apply)
        } else {
            apply()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentEntry = nil
        cardView.backgroundColor = BearyColors.bg
        quoteButton.isHidden = true
        quoteBodyLabel.isHidden = false
        clearQuoteThumbs()
        actsStack.isHidden = true
        for imageView in thumbImageViews {
            imageView.bearySetImage(url: nil)
            imageView.removeFromSuperview()
        }
        thumbImageViews = []
        for arranged in footStack.arrangedSubviews {
            footStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        for arranged in metaStack.arrangedSubviews {
            metaStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
    }

    func configure(entry: Entry) {
        currentEntry = entry
        for arranged in metaStack.arrangedSubviews {
            metaStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        if let createdMs = entry.createdAt {
            let date = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            // G8：行内时间走北京时区，与服务端日界一致。
            formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
            formatter.dateFormat = "HH:mm"
            timeLabel.text = formatter.string(from: date)
        } else {
            timeLabel.text = ""
        }
        metaStack.addArrangedSubview(timeLabel)
        let published = entry.isPublic ?? false
        if published {
            pillBackground.backgroundColor = BearyColors.faint
            pillLabel.textColor = BearyColors.gray
            pillLabel.text = "已公开"
            hourglassView.isHidden = true
            pillLabelLeadingWithIcon?.isActive = false
            pillLabelLeadingWithoutIcon?.isActive = true
            dotSizeConstraint?.constant = 14
            dotRingSizeConstraint?.constant = 17
            dotTopConstraint?.constant = 12
            dotView.backgroundColor = BearyColors.ink
            dotView.layer.borderWidth = 2.5
            dotView.layer.borderColor = BearyColors.bg.cgColor
            dotView.layer.cornerRadius = 7
            dotRingView.isHidden = false
            dotRingView.layer.cornerRadius = 8.5
        } else {
            // C6：动态色上的 0.13 透明度走 BearyColors.alpha（Common lane 提供），
            // 不再对动态色直接 withAlphaComponent（深浅解析会失真）。
            pillBackground.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.13)
            pillLabel.textColor = BearyColors.blue
            pillLabel.text = BearyTimelineCell.privCountdownText(publishAtMs: entry.publishAt)
            hourglassView.isHidden = false
            pillLabelLeadingWithoutIcon?.isActive = false
            pillLabelLeadingWithIcon?.isActive = true
            dotSizeConstraint?.constant = 9
            dotRingSizeConstraint?.constant = 12
            dotTopConstraint?.constant = 14.5
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderWidth = 2.5
            dotView.layer.borderColor = BearyColors.blue.cgColor
            dotView.layer.cornerRadius = 4.5
            dotRingView.isHidden = true
        }
        metaStack.addArrangedSubview(pillBackground)
        // I3：天气用 icon_wx_* 图标、心情用 14px BearyEmoteView（静态首帧，不播动画），
        // 各自与文字拼成小行再进 meta 行；资产缺失时只留文字。
        if let weatherKey = entry.weather, let weatherName = BearyText.weatherNames[weatherKey] {
            weatherLabel.text = weatherName
            var weatherRowItems: [UIView] = []
            if let weatherImage = BearyIconImages.image(named: "icon_wx_\(weatherKey)", pointSize: 14) {
                let weatherIconView = UIImageView(image: weatherImage)
                weatherIconView.translatesAutoresizingMaskIntoConstraints = false
                weatherIconView.tintColor = BearyColors.gray
                weatherIconView.contentMode = .scaleAspectFit
                NSLayoutConstraint.activate([
                    weatherIconView.widthAnchor.constraint(equalToConstant: 14),
                    weatherIconView.heightAnchor.constraint(equalToConstant: 14),
                ])
                weatherRowItems.append(weatherIconView)
            }
            weatherRowItems.append(weatherLabel)
            let weatherRow = UIStackView(arrangedSubviews: weatherRowItems)
            weatherRow.axis = .horizontal
            weatherRow.spacing = 3
            weatherRow.alignment = .center
            weatherRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            metaStack.addArrangedSubview(weatherRow)
        }
        if let moodKey = entry.mood, let moodName = BearyText.moodNames[moodKey] {
            moodLabel.text = moodName
            let emoteView = BearyEmoteView(key: moodKey, animated: false)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                emoteView.widthAnchor.constraint(equalToConstant: 14),
                emoteView.heightAnchor.constraint(equalToConstant: 14),
            ])
            let moodRow = UIStackView(arrangedSubviews: [emoteView, moodLabel])
            moodRow.axis = .horizontal
            moodRow.spacing = 3
            moodRow.alignment = .center
            moodRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            metaStack.addArrangedSubview(moodRow)
        }
        if let recipientName = entry.recipientName, entry.recipientId != nil {
            recipientLabel.text = "写给 \(recipientName)"
            metaStack.addArrangedSubview(recipientLabel)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.75
        let body = entry.content ?? ""
        contentLabel.attributedText = NSAttributedString(string: body, attributes: [
            .font: UIFont.systemFont(ofSize: 16.5),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ])
        // TL-3 引用卡（网页 tlQuoteHtml 口径）：引用日记在时间线里必须有痕迹，
        // 卡内附 74px 引用缩略图行（见下方 F2 分支），无图不占位。
        // 注意：Entry.Quote 模型没有服务端的 gone/locked 字段，以下是推断口径
        // （API 路若给 Quote 补 gone/locked 字段，应改用服务端值，见交回说明）：
        // quoteId 有而 quote 体缺失 → 已删除；quote 体无正文且未公开 → 尚未公开；
        // gone/locked 卡在网页里带 gone class、不可点，故此处禁用按钮。
        // 引用缩略图见下方 F2 分支（仅有正文的公开/自己的引用才配图）。
        quoteButton.isHidden = true
        quoteBodyLabel.isHidden = false
        clearQuoteThumbs()
        quoteButton.isEnabled = true
        if entry.quote == nil, entry.quoteId != nil {
            quoteTitleLabel.text = "引用的日记已删除"
            quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 14)
            quoteBodyLabel.isHidden = true
            quoteButton.isEnabled = false
            quoteButton.isHidden = false
        } else if let quote = entry.quote {
            let quoteBody = (quote.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if quoteBody.isEmpty {
                if quote.isPublic == true {
                    quoteTitleLabel.text = "引用的日记已删除"
                    quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 14)
                } else {
                    quoteTitleLabel.text = "引用了一篇尚未公开的日记"
                    quoteIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 14)
                }
                quoteBodyLabel.isHidden = true
                quoteButton.isEnabled = false
                quoteButton.isHidden = false
            } else {
                if let createdMs = quote.createdAt {
                    let date = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "zh_CN")
                    // G8：引用日期走北京时区。
                    formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
                    formatter.dateFormat = "M 月 d 日"
                    quoteTitleLabel.text = "引用 · " + formatter.string(from: date) + "的日记"
                } else {
                    quoteTitleLabel.text = "引用"
                }
                quoteBodyLabel.text = quoteBody
                quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 14)
                // F2：引用卡内补一行 74px 小缩略图（网页 tl-qcard 内 .quote-thumbs 口径）；
                // 仅公开引用或自己的引用才配图（网页 quoteThumbsHtml 口径），无图不占位。
                if quote.isPublic == true || entry.isMine == true {
                    let quoteKeys = (quote.images ?? []).filter { !$0.isEmpty }
                    for key in quoteKeys {
                        let imageView = UIImageView()
                        imageView.translatesAutoresizingMaskIntoConstraints = false
                        imageView.contentMode = .scaleAspectFill
                        imageView.clipsToBounds = true
                        imageView.layer.cornerRadius = 10
                        imageView.backgroundColor = BearyColors.faint
                        quoteThumbsStack.addArrangedSubview(imageView)
                        NSLayoutConstraint.activate([
                            imageView.widthAnchor.constraint(equalToConstant: 74),
                            imageView.heightAnchor.constraint(equalToConstant: 74),
                        ])
                        quoteThumbImageViews.append(imageView)
                        if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                            imageView.bearySetImage(url: url)
                        }
                    }
                    quoteThumbsStack.isHidden = quoteKeys.isEmpty
                }
                quoteButton.isHidden = false
            }
        }
        let imageKeys = (entry.images ?? []).filter { !$0.isEmpty }
        thumbsScrollView.isHidden = imageKeys.isEmpty
        thumbsHeightConstraint?.constant = imageKeys.isEmpty ? 0 : 74
        cardStackReference?.setCustomSpacing(imageKeys.isEmpty ? 0 : 9, after: thumbsScrollView)
        for (thumbIndex, key) in imageKeys.enumerated() {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            imageView.backgroundColor = BearyColors.faint
            // N7：主图条点按接灯箱（UIImageView 默认不接收触摸，必须显式开启；
            // 手势会截获此次点按，行点按进详情不再触发）。tag 记下标，
            // didTapThumb 再从 currentEntry 重算 keys（与本循环同一过滤口径）。
            imageView.isUserInteractionEnabled = true
            imageView.tag = thumbIndex
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapThumb(_:))))
            thumbsStack.addArrangedSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 74),
                imageView.heightAnchor.constraint(equalToConstant: 74),
            ])
            thumbImageViews.append(imageView)
            if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                imageView.bearySetImage(url: url)
            }
        }
        footStack.isHidden = true
        actsStack.isHidden = true
        // 与 metaStack 在 configure 开头先清后加一致：foot 行只靠
        // prepareForReuse 清理时，configure 重跑会把足行与 spacer 叠加。
        for arranged in footStack.arrangedSubviews {
            footStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        if published {
            var footItems: [UIView] = []
            let likeCount = entry.likeCount ?? 0
            let likeRow = footItem(iconName: "icon_heart", text: likeCount > 0 ? "\(likeCount)" : nil)
            footItems.append(likeRow)
            var emoteTotal = 0
            for emote in entry.emotes ?? [] {
                emoteTotal += emote.count ?? 0
            }
            if emoteTotal > 0 {
                let emoteLabel = UILabel()
                emoteLabel.font = UIFont.systemFont(ofSize: 12.5)
                emoteLabel.textColor = BearyColors.gray
                emoteLabel.text = "小熊回应 \(emoteTotal)"
                emoteLabel.setContentHuggingPriority(.required, for: .horizontal)
                footItems.append(emoteLabel)
            }
            let bookmarkCount = entry.bookmarkCount ?? 0
            if bookmarkCount > 0 {
                footItems.append(footItem(iconName: "icon_bookmark", text: "\(bookmarkCount)"))
            }
            for item in footItems {
                footStack.addArrangedSubview(item)
            }
            // 足行吸宽 spacer（与 actsStack 的 actsSpacer 同款做法）：
            // footStack 全宽 321pt，足项本身抗拉伸 required 后，多余宽度
            // 只能被这个 defaultLow 的空视图吃掉，足项贴左、按本宽显示。
            // spacer 仍在 footStack 内，prepareForReuse 的全清循环会一并移除，
            // 不新增清理机制。
            let footSpacer = UIView()
            footSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            footSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            footStack.addArrangedSubview(footSpacer)
            footStack.isHidden = false
        } else {
            // TL-3 私密行操作行（网页 .tl-acts 口径）：编辑倒计时或“编辑已结束”
            // + 编辑钮（仅未锁定时）+ 删除钮。删除本身不由本页发请求：走容器回调，
            // 容器按网页 confirmDelete 流程弹“确认删除？/ 删除后会移入回收站，
            // 30 天内可以在「时间线」里恢复。”再调删除接口。
            updateEditRow(entry: entry)
            actsStack.isHidden = false
        }
    }

    /// N7 主图条点按：下标取自 imageView.tag，keys 从 currentEntry 按
    /// configure 同一过滤口径（去空）重算；复用后手势随旧 imageView 一并移除，
    /// configure 重建时重新挂接，不留跨条目残留回调。
    @objc private func didTapThumb(_ sender: UITapGestureRecognizer) {
        guard let entry = currentEntry else { return }
        let keys = (entry.images ?? []).filter { !$0.isEmpty }
        let index = sender.view?.tag ?? 0
        guard index >= 0 && index < keys.count else { return }
        onTapImages?(keys, index)
    }

    /// 网页 tlItemHtml 私密操作行口径：edit_deadline 缺失按 0 计，即已锁。
    private func isEditLocked(entry: Entry) -> Bool {
        guard let deadline = entry.editDeadline else { return true }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return nowMs >= deadline
    }

    private func editStatusText(entry: Entry) -> String {
        guard let deadline = entry.editDeadline else { return "编辑已结束" }
        let remainingSeconds = Int(Date(timeIntervalSince1970: TimeInterval(deadline) / 1000.0).timeIntervalSinceNow)
        if remainingSeconds <= 0 { return "编辑已结束" }
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        let secondsText = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        return "可编辑 \(minutes):\(secondsText)"
    }

    private func updateEditRow(entry: Entry) {
        editStatusLabel.text = editStatusText(entry: entry)
        let locked = isEditLocked(entry: entry)
        // I11：文案前 13px 图标与状态同步（已结束锁 / 可编辑笔）。
        statusIconView.image = BearyIconImages.image(named: locked ? "icon_lock" : "icon_edit", pointSize: 13)
        editButton.isHidden = locked
    }

    /// F2 引用缩略图清理（复用与重配时先清，避免旧图残留）。
    private func clearQuoteThumbs() {
        for imageView in quoteThumbImageViews {
            imageView.bearySetImage(url: nil)
            imageView.removeFromSuperview()
        }
        quoteThumbImageViews = []
        quoteThumbsStack.isHidden = true
    }

    /// TL-2/TL-3 的 1 秒 tick 入口：只改本行 pill 与编辑倒计时文案，不重建行。
    func refreshCountdowns() {
        guard let entry = currentEntry else { return }
        if entry.isPublic == true { return }
        pillLabel.text = BearyTimelineCell.privCountdownText(publishAtMs: entry.publishAt)
        updateEditRow(entry: entry)
    }

    @objc private func editTapped() {
        guard let entry = currentEntry else { return }
        onEditEntry?(entry)
    }

    @objc private func deleteTapped() {
        guard let entry = currentEntry else { return }
        onDeleteEntry?(entry)
    }

    @objc private func quoteTapped() {
        guard let entry = currentEntry, let quoteId = entry.quote?.id else { return }
        onQuoteEntry?(quoteId)
    }

    private func footItem(iconName: String, text: String?) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        // 足行拉伸修复（#41 拉宽爱心）：footStack 与 row 都是横向 .fill，
        // 唯一子项会被双层 stack 左右钉住拉满宽；14 宽约束在该冲突里丢了，
        // 默认 .scaleToFill 的心形图就被横向拉成 321×14 的扁轮廓。
        // 行与图标横向抗拉伸都设 required，让多余宽度只能进后面的 spacer，
        // 图标框永远是 14×14；contentMode 改 aspectFit 是兜底，方框下方形图
        // 本就无变化，万一框再被拉大也不会把心压扁。
        row.setContentHuggingPriority(.required, for: .horizontal)
        let iconView = UIImageView(image: BearyIconImages.image(named: iconName, pointSize: 14))
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
        ])
        row.addArrangedSubview(iconView)
        if let text = text {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 12.5)
            label.textColor = BearyColors.gray
            label.text = text
            row.addArrangedSubview(label)
        }
        return row
    }

    /// 私密 pill 倒计时文案（网页 privCdText 口径，一字不差）：
    /// “投递中 · 还剩 X 天/小时/分钟”，天取整、小时取余数、分钟余数向上取整至少 1。
    /// 到点（remaining <= 0）时网页当即触发重拉、不会出现该文案；原生在重拉完成前
    /// 短暂显示“即将公开”，随后 tick 的重拉会把行翻为“已公开”。
    static func privCountdownText(publishAtMs: Int?) -> String {
        guard let publishAtMs = publishAtMs else { return "未公开" }
        let remaining = Double(publishAtMs) / 1000.0 - Date().timeIntervalSince1970
        if remaining <= 0 { return "即将公开" }
        let days = Int(remaining / 86400)
        if days > 0 { return "投递中 · 还剩 \(days) 天" }
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
        if hours > 0 { return "投递中 · 还剩 \(hours) 小时" }
        let minutes = max(1, Int(ceil(remaining.truncatingRemainder(dividingBy: 3600) / 60)))
        return "投递中 · 还剩 \(minutes) 分钟"
    }
}

/// 沙漏小图标：按 beary.html #beary-hourglass sprite 路径描边绘制
/// （24 坐标系、线宽 2、圆头圆角），颜色走 BearyColors.blue。
private final class BearyHourglassView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // 描边绘制只画蓝线、不填底：此前从未设过背景，未绘制区域按不透明位图
        // 留下 12x12 黑块。显式透明底 + 非不透明，pill 的蓝底透出来，只剩沙漏线。
        // .clear 在此只是“无背景”（非调色板颜色，BearyColors 本无透明项），描边色仍走 BearyColors.blue。
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let scale = rect.width / 24.0
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        let path = UIBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: 7, y: 4))
        path.addLine(to: CGPoint(x: 17, y: 4))
        path.move(to: CGPoint(x: 7, y: 20))
        path.addLine(to: CGPoint(x: 17, y: 20))
        path.move(to: CGPoint(x: 8, y: 4))
        path.addLine(to: CGPoint(x: 8, y: 7))
        path.addQuadCurve(to: CGPoint(x: 12, y: 12), controlPoint: CGPoint(x: 8, y: 10.5))
        path.addLine(to: CGPoint(x: 12, y: 12))
        path.move(to: CGPoint(x: 16, y: 4))
        path.addLine(to: CGPoint(x: 16, y: 7))
        path.addQuadCurve(to: CGPoint(x: 12, y: 12), controlPoint: CGPoint(x: 16, y: 10.5))
        path.move(to: CGPoint(x: 8, y: 20))
        path.addLine(to: CGPoint(x: 8, y: 17))
        path.addQuadCurve(to: CGPoint(x: 12, y: 12), controlPoint: CGPoint(x: 8, y: 13.5))
        path.move(to: CGPoint(x: 16, y: 20))
        path.addLine(to: CGPoint(x: 16, y: 17))
        path.addQuadCurve(to: CGPoint(x: 12, y: 12), controlPoint: CGPoint(x: 16, y: 13.5))
        BearyColors.blue.resolvedColor(with: traitCollection).setStroke()
        path.stroke()
        context.restoreGState()
    }
}

// MARK: - 时间线页

class BearyTimelineViewController: UIViewController {

    /// 回收站 pill 点按（容器接线：打开回收站页；本文件只定义回调，不做页面跳转）。
    var onOpenTrash: (() -> Void)?
    /// 当日/全部列表行点按，传整条 Entry（容器接线：打开详情）。
    var onOpenEntry: ((Entry) -> Void)?
    /// 未登录：首拉 401 时调用一次（另附“先登录”空态内的“去登录”按钮可再次触发）。
    var onRequireLogin: (() -> Void)?
    /// TL-3 私密行编辑/删除/引用卡点按（容器接线，未接线时点按无动作）：
    /// 编辑 → 打开编辑器；删除 → 先按网页 confirmDelete 文案弹确认再删；
    /// 引用卡 → 打开被引用的日记（gone/locked 卡不可点，不触发）。
    var onEditEntry: ((Entry) -> Void)?
    var onDeleteEntry: ((Entry) -> Void)?
    var onQuoteEntry: ((String) -> Void)?
    /// TL-9 详情同款口径：时间线行互动字段在刷新后发生变化时通知容器
    /// （签名与详情页 onInteractionChanged 完全一致：id、点赞数、是否已赞、
    /// 是否已收藏、小熊回应列表）。容器接线由总协调收尾。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?, [EmoteCount]?) -> Void)?

    private enum LoadState {
        case idle
        case loading
        case loaded
        case failed
    }

    private struct DaySection {
        var dayKey: String
        var title: String
        var entries: [Entry]
    }

    private let pageLimit = 50

    private var timelineEntries: [Entry] = []
    private var timelineHasMore = false
    private var timelineState = LoadState.idle
    private var timelineUnauthorized = false
    private var timelineLoadingMore = false
    // G15：分页失败标记——脚部保持“加载失败，点击重试”可重试。
    private var timelinePageFailed = false
    // 清单 7 时间线筛选：只影响本页列表展示（currentSections 过滤时间线
    // 分区），不动服务端排序与日历统计；当日面板（日历选区）不过滤，
    // 避免点某天却看不到该天部分日记。默认全部。
    private enum TimelineFilter {
        case all
        case published
        case unpublished
    }
    private var timelineFilter: TimelineFilter = .all
    // 清单 2 滚动隐藏栏：方向 + 阈值判定，FAB 随栏同隐同现由容器 helper 负责。
    private var timelineChromeHidden = false
    private var timelineLastScrollOffsetY: CGFloat = 0
    // 清单 7 筛选条：固定在页顶（不随列表滚走），高 44；列表 contentInset.top
    // 同步抬高，见 viewDidLoad。
    private let timelineFilterBarHeight: CGFloat = 44
    private let timelineFilterBar = UIView()
    private let timelineFilterControl = UISegmentedControl(items: ["全部", "已公开", "未公开"])
    // M2：分页新增行的错峰滑入队列（willDisplay 时按原始序号起播，播过即摘；
    // 用序号字典而非数组，避免摘除后后续序号前移导致错峰失效）。
    private var staggerInsertOrder: [IndexPath: Int] = [:]
    // M16：跳转提示当前 label 弱引用，消失时先做透明度过渡再移除。
    private weak var jumpNoteLabel: UILabel?
    // G15：分页失败 toast（底色 ink，与回收站 toast 同口径）。
    private let timelineToastWrap = UIView()
    private let timelineToastLabel = UILabel()
    private var trashCountValue = 0
    private var countsValue: TlCounts?
    private var loginNotified = false

    private var calendarCache: [String: BearyCalendarMonthResponse] = [:]
    private var calendarFetching: Set<String> = []
    private var calendarFailed: Set<String> = []
    private var calendarMode: BearyCalendarCardView.ViewMode = .week
    private var calendarAnchor: (year: Int, month: Int, day: Int)?
    private var calendarDisplayedMonth: (year: Int, month: Int)?
    private var selectedDayKey: String?

    private var dayEntries: [Entry] = []
    private var dayState = LoadState.idle
    private var dayKeyForLoad: String?
    private var dayEntriesKey: String?
    private var showJumpNote = false
    private var jumpNoteTimer: Timer?
    /// TL-2 1 秒 tick + 到点重拉（网页 startCountdowns 口径：同篇最多 3 次、间隔 ≥3 秒）。
    private var countdownTimer: Timer?
    private var publishFireCounts: [String: Int] = [:]
    private var publishFireLast: [String: Date] = [:]

    // MARK: - 视图

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.backgroundColor = BearyColors.bg
        tv.separatorStyle = .none
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 180
        tv.estimatedSectionHeaderHeight = 40
        tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 90, right: 0)
        tv.scrollIndicatorInsets = tv.contentInset
        tv.register(BearyTimelineCell.self, forCellReuseIdentifier: BearyTimelineCell.reuseIdentifier)
        tv.delegate = self
        tv.dataSource = self
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        tv.refreshControl = rc
        return tv
    }()

    /// 表头容器：标题行 + 统计小字 + 连续写作行 + 日历卡。
    /// 用 tableHeaderView 承载（随列表一起滚走，不常驻占位）；高度每次渲染后重算。
    /// TL-7：当日列表不再是表头里的筛选条、也不替换整个时间线，而是表格的
    /// 第一个分区（当日面板），时间线分区紧随其后（与网页 #calDay + #tlBody 并存一致）。
    private let headerContainer = UIView()
    private let titleLabel = UILabel()
    private let trashButton = UIButton(type: .system)
    private let countsLabel = UILabel()
    private let statsButton = UIButton(type: .system)
    private let calendarCard = BearyCalendarCardView()
    private var headerStack: UIStackView?
    private var lastHeaderWidth: CGFloat = 0

    private let loadMoreButton = UIButton(type: .system)
    private let footerSpinner = UIActivityIndicatorView(style: .medium)

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildHeader()
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 清单 7 筛选条位置取舍：固定页顶而非塞进随列表滚走的表头，
        // 否则长列表下滑后就换不了筛选；代价是列表顶 inset +44（本页
        // 原本就是 tableView 顶贴 view 顶的全幅布局，安全区外无其他顶栏）。
        // 不透明底 + 底 hairline，避免列表文字从条下透出。
        timelineFilterBar.backgroundColor = BearyColors.bg
        timelineFilterBar.translatesAutoresizingMaskIntoConstraints = false
        timelineFilterControl.translatesAutoresizingMaskIntoConstraints = false
        timelineFilterControl.selectedSegmentIndex = 0
        timelineFilterControl.addTarget(self, action: #selector(didChangeTimelineFilter(_:)), for: .valueChanged)
        let filterHairline = UIView()
        filterHairline.backgroundColor = BearyColors.line
        filterHairline.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timelineFilterBar)
        timelineFilterBar.addSubview(timelineFilterControl)
        timelineFilterBar.addSubview(filterHairline)
        NSLayoutConstraint.activate([
            timelineFilterBar.topAnchor.constraint(equalTo: view.topAnchor),
            timelineFilterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            timelineFilterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            timelineFilterBar.heightAnchor.constraint(equalToConstant: timelineFilterBarHeight),
            timelineFilterControl.leadingAnchor.constraint(equalTo: timelineFilterBar.leadingAnchor, constant: 16),
            timelineFilterControl.trailingAnchor.constraint(equalTo: timelineFilterBar.trailingAnchor, constant: -16),
            timelineFilterControl.centerYAnchor.constraint(equalTo: timelineFilterBar.centerYAnchor),
            filterHairline.leadingAnchor.constraint(equalTo: timelineFilterBar.leadingAnchor),
            filterHairline.trailingAnchor.constraint(equalTo: timelineFilterBar.trailingAnchor),
            filterHairline.bottomAnchor.constraint(equalTo: timelineFilterBar.bottomAnchor),
            filterHairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        tableView.contentInset.top = timelineFilterBarHeight
        tableView.scrollIndicatorInsets.top = timelineFilterBarHeight
        loadMoreButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        loadMoreButton.setTitleColor(BearyColors.gray, for: .normal)
        loadMoreButton.addTarget(self, action: #selector(didTapFooter), for: .touchUpInside)
        footerSpinner.color = BearyColors.gray
        // G15 toast 容器：置于表之上、胶囊之上（底边安全区 -100），平时透明。
        timelineToastWrap.backgroundColor = BearyColors.ink
        timelineToastWrap.layer.cornerRadius = 16
        timelineToastWrap.clipsToBounds = true
        timelineToastWrap.alpha = 0
        timelineToastWrap.translatesAutoresizingMaskIntoConstraints = false
        timelineToastLabel.font = UIFont.systemFont(ofSize: 14)
        timelineToastLabel.textColor = BearyColors.bg
        timelineToastLabel.textAlignment = .center
        timelineToastLabel.numberOfLines = 0
        timelineToastLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timelineToastWrap)
        timelineToastWrap.addSubview(timelineToastLabel)
        NSLayoutConstraint.activate([
            timelineToastWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            timelineToastWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            timelineToastWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            timelineToastWrap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -100),
            timelineToastLabel.topAnchor.constraint(equalTo: timelineToastWrap.topAnchor, constant: 10),
            timelineToastLabel.bottomAnchor.constraint(equalTo: timelineToastWrap.bottomAnchor, constant: -10),
            timelineToastLabel.leadingAnchor.constraint(equalTo: timelineToastWrap.leadingAnchor, constant: 14),
            timelineToastLabel.trailingAnchor.constraint(equalTo: timelineToastWrap.trailingAnchor, constant: -14),
        ])
        reloadTimeline()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if abs(tableView.bounds.width - lastHeaderWidth) > 0.5 {
            refreshHeaderHeight()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdownTimer()
        // 清单 2：回到本页时栏恢复可见（不带动画，避免进页先闪一下栏）。
        // setChromeHidden 由容器 lane 在 SceneDelegate.swift 提供，本文件只调用。
        // lastY 取当前真实 offset（不硬置 0），否则返回时列表停在下方、
        // 第一次上滑会被误判为下滑而藏栏。
        timelineChromeHidden = false
        timelineLastScrollOffsetY = tableView.contentOffset.y
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCountdownTimer()
    }

    deinit {
        countdownTimer?.invalidate()
        jumpNoteTimer?.invalidate()
    }

    // MARK: - 对外入口（容器在 tab 切入/重进时调用）

    /// keepSelectedDay=true 时保留当前选中日：跳过“重置为今天 + 拉今天当日”，
    /// 只拉一次最终选中日（G16 下拉刷新口径；默认 false 保持原有进页行为）。
    func reloadTimeline(keepSelectedDay: Bool = false) {
        let keepDay = keepSelectedDay && selectedDayKey != nil
        timelineEntries = []
        timelineHasMore = false
        timelineState = .idle
        timelineUnauthorized = false
        timelinePageFailed = false
        loginNotified = false
        showJumpNote = false
        jumpNoteTimer?.invalidate()
        jumpNoteTimer = nil
        if calendarAnchor == nil {
            calendarAnchor = BearyBeijingDay.todayComponents()
        }
        if calendarDisplayedMonth == nil, let anchor = calendarAnchor {
            calendarDisplayedMonth = (anchor.year, anchor.month)
        }
        // TL-7 默认选中今天：进页即有当日面板（网页 loadCalendar 默认 calSel=今天）。
        // G16：保留选中日时不重置、不清当日面板。
        if keepDay {
            // 选中日与当日面板原样保留，只刷新时间线与日历。
        } else {
            if let today = BearyBeijingDay.todayComponents() {
                selectedDayKey = BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day)
            } else {
                selectedDayKey = nil
            }
            dayEntries = []
            dayEntriesKey = nil
            dayState = .idle
            dayKeyForLoad = nil
        }
        tableView.reloadData()
        updateChrome()
        loadTimelineFirstPage()
        fetchCalendarMonthsForCurrentView()
        if let dayKey = selectedDayKey {
            fetchDayEntries(key: dayKey, clear: !keepDay)
        }
    }

    /// TL-9 供容器调用的刷新入口（详情改动、回收站恢复/删除后由容器调）：
    /// 首屏时间线 + 日历月份（强制重拉，日历圆点/统计重算）+ 当日面板重拉，
    /// 不重置选中日、不清当日面板；互动字段变化时按详情口径发 onInteractionChanged。
    /// 选中日由有篇变空时走 TL-8 的 calFixSel 等价逻辑（见 fetchDayEntries）。
    func refreshAfterDetailChange() {
        let before = interactionSnapshot()
        loadTimelineFirstPage { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.fireInteractionChanges(before: before)
        }
        for key in monthKeysForCurrentView() {
            fetchCalendarMonth(key: key, force: true)
        }
        if let key = selectedDayKey {
            fetchDayEntries(key: key, clear: false)
        }
    }

    private func interactionSnapshot() -> [String: String] {
        var snapshot: [String: String] = [:]
        let allEntries = timelineEntries + dayEntries
        for entry in allEntries {
            guard let entryId = entry.id else { continue }
            var emoteParts: [String] = []
            for emote in entry.emotes ?? [] {
                emoteParts.append("\(emote.emote ?? ""):\(emote.count ?? 0):\(emote.mine ?? false)")
            }
            snapshot[entryId] = "\(entry.likeCount ?? 0)|\(entry.likedByMe ?? false)|\(entry.bookmarkedByMe ?? false)|\(emoteParts.joined(separator: ","))"
        }
        return snapshot
    }

    private func fireInteractionChanges(before: [String: String]) {
        var fired: Set<String> = []
        let allEntries = timelineEntries + dayEntries
        for entry in allEntries {
            guard let entryId = entry.id, !fired.contains(entryId) else { continue }
            var emoteParts: [String] = []
            for emote in entry.emotes ?? [] {
                emoteParts.append("\(emote.emote ?? ""):\(emote.count ?? 0):\(emote.mine ?? false)")
            }
            let signature = "\(entry.likeCount ?? 0)|\(entry.likedByMe ?? false)|\(entry.bookmarkedByMe ?? false)|\(emoteParts.joined(separator: ","))"
            if before[entryId] != signature {
                fired.insert(entryId)
                onInteractionChanged?(entryId, entry.likeCount, entry.likedByMe, entry.bookmarkedByMe, entry.emotes)
            }
        }
    }

    @objc private func pullToRefresh() {
        // G16：刷新时先保存选中日（reloadTimeline keepDay 分支内保留），
        // 跳过当日拉取，只拉一次最终选中日；不再先拉今天再拉回原选中日。
        reloadTimeline(keepSelectedDay: true)
        refreshHeaderHeight()
    }

    // MARK: - TL-2 1 秒倒计时

    private func startCountdownTimer() {
        if countdownTimer != nil { return }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.countdownTick()
        }
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func countdownTick() {
        var needsReload = false
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        for cell in tableView.visibleCells {
            guard let timelineCell = cell as? BearyTimelineCell else { continue }
            timelineCell.refreshCountdowns()
        }
        // 到点判定看已加载的全部条目（网页 tlBody/calDay 均为全量 DOM，
        // 不只可视行）；触发规则与网页 cdFired 一致：同篇最多 3 次、间隔 ≥3 秒。
        var seen: Set<String> = []
        for entry in timelineEntries + dayEntries {
            guard let entryId = entry.id, entry.isPublic != true else { continue }
            guard let publishAt = entry.publishAt, publishAt > 0, publishAt <= nowMs else { continue }
            if seen.contains(entryId) { continue }
            seen.insert(entryId)
            let fireKey = entryId + "@\(publishAt)"
            let count = publishFireCounts[fireKey] ?? 0
            let last = publishFireLast[fireKey]
            if count < 3 && (last == nil || Date().timeIntervalSince(last ?? Date()) >= 3) {
                publishFireCounts[fireKey] = count + 1
                publishFireLast[fireKey] = Date()
                needsReload = true
            }
        }
        if needsReload {
            refreshAfterDetailChange()
        }
    }

    // MARK: - 表头搭建

    private func buildHeader() {
        headerContainer.backgroundColor = BearyColors.bg

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "时间线"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 19)
        titleLabel.textColor = BearyColors.ink

        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.backgroundColor = BearyColors.faint
        trashButton.layer.cornerRadius = 17
        trashButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 13, bottom: 8, right: 13)
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 16) {
            trashButton.setImage(trashImage, for: .normal)
        }
        trashButton.tintColor = BearyColors.ink
        trashButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        trashButton.addTarget(self, action: #selector(didTapTrash), for: .touchUpInside)
        updateTrashTitle()

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, trashButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.distribution = .equalSpacing

        countsLabel.translatesAutoresizingMaskIntoConstraints = false
        countsLabel.font = UIFont.systemFont(ofSize: 12.5)
        countsLabel.textColor = BearyColors.gray

        statsButton.translatesAutoresizingMaskIntoConstraints = false
        statsButton.contentHorizontalAlignment = .left
        statsButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.5)
        statsButton.addTarget(self, action: #selector(didTapStats), for: .touchUpInside)

        calendarCard.translatesAutoresizingMaskIntoConstraints = false
        calendarCard.onSelectDay = { [weak self] day in
            self?.didSelectCalendarDay(day)
        }
        calendarCard.onToggleView = { [weak self] in
            self?.toggleCalendarView()
        }
        calendarCard.onPrevious = { [weak self] in
            self?.stepCalendar(delta: -1)
        }
        calendarCard.onNext = { [weak self] in
            self?.stepCalendar(delta: 1)
        }
        calendarCard.onJumpToToday = { [weak self] in
            self?.jumpToToday()
        }

        let stack = UIStackView(arrangedSubviews: [titleRow, countsLabel, statsButton, calendarCard])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.setCustomSpacing(4, after: titleRow)
        stack.setCustomSpacing(2, after: countsLabel)
        stack.setCustomSpacing(12, after: statsButton)
        headerStack = stack
        headerContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
        ])
        tableView.tableHeaderView = headerContainer
    }

    private func refreshHeaderHeight() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        lastHeaderWidth = width
        headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let size = headerContainer.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if headerContainer.frame.height != size.height {
            headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
            tableView.tableHeaderView = headerContainer
        }
    }

    private func fittingHeaderHeight() -> CGFloat {
        let width = tableView.bounds.width
        guard width > 0 else { return headerContainer.frame.height }
        headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let size = headerContainer.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return size.height
    }

    /// TL-4 翻页/切换动效：先 180ms 淡出 + 横移 8px（网页 .cal-fading 口径），
    /// 再执行变更并以 .24s 高度 FLIP 过渡到新表头高度（网页 calHeightAnim 口径），
    /// 同时淡回。reduced-motion 时直接变更、无动效。
    private func performCalendarTransition(mutate: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            mutate()
            refreshHeaderHeight()
            return
        }
        UIView.animate(withDuration: 0.18, animations: {
            self.calendarCard.alpha = 0
            self.calendarCard.transform = CGAffineTransform(translationX: 8, y: 0)
        }, completion: { [weak self] _ in
            guard let strongSelf = self else { return }
            mutate()
            let oldHeight = strongSelf.headerContainer.frame.height
            let newHeight = strongSelf.fittingHeaderHeight()
            if abs(newHeight - oldHeight) < 1 {
                UIView.animate(withDuration: 0.18, animations: {
                    strongSelf.calendarCard.alpha = 1
                    strongSelf.calendarCard.transform = .identity
                }, completion: { _ in strongSelf.refreshHeaderHeight() })
                return
            }
            UIView.animate(withDuration: 0.24, animations: {
                strongSelf.headerContainer.frame = CGRect(x: 0, y: 0, width: strongSelf.tableView.bounds.width, height: newHeight)
                strongSelf.tableView.tableHeaderView = strongSelf.headerContainer
                strongSelf.calendarCard.alpha = 1
                strongSelf.calendarCard.transform = .identity
                strongSelf.tableView.layoutIfNeeded()
            }, completion: { _ in strongSelf.refreshHeaderHeight() })
        })
    }

    /// 月视图错峰时要跳过的本周日期 key（网页 calStaggerMonthCells 口径）。
    private func currentWeekKeys() -> Set<String> {
        guard let anchor = calendarAnchor else { return [] }
        guard let monday = BearyBeijingDay.mondayOf(year: anchor.year, month: anchor.month, day: anchor.day) else { return [] }
        var keys: Set<String> = []
        for offset in 0..<7 {
            guard let day = BearyBeijingDay.shifted(year: monday.year, month: monday.month, day: monday.day, byDays: offset) else { continue }
            keys.insert(BearyBeijingDay.dayKey(year: day.year, month: day.month, day: day.day))
        }
        return keys
    }

    private func updateTrashTitle() {
        let base = NSMutableAttributedString(string: "回收站", attributes: [
            .font: UIFont.systemFont(ofSize: 13.5),
            .foregroundColor: BearyColors.ink,
        ])
        if trashCountValue > 0 {
            base.append(NSAttributedString(string: " \(trashCountValue)", attributes: [
                .font: UIFont.systemFont(ofSize: 12.5),
                .foregroundColor: BearyColors.gray,
            ]))
        }
        trashButton.setAttributedTitle(base, for: .normal)
    }

    private func updateCountsLabel() {
        if let counts = countsValue {
            let total = counts.total ?? 0
            let priv = counts.priv ?? 0
            let pub = counts.pub ?? 0
            countsLabel.text = "共 \(total) 篇 · 私密 \(priv) · 公开 \(pub)"
        } else {
            countsLabel.text = ""
        }
    }

    /// 连续写作行：网页 .cal-stats（13.5 灰、数字墨色加粗、16pt 橙色火苗图标）。
    /// 火苗图为本批新建的 icon_fire 资产（beary.html #beary-fire sprite 路径渲染）。
    /// 任一可视月份失败时整行变重试入口（G14）；缺失月份在途拉取时出加载态（G9）。
    private func updateStatsLine() {
        let primaryKey = primaryStatsMonthKey()
        let visibleKeys = monthKeysForCurrentView()
        if let primaryKey = primaryKey, calendarCache[primaryKey] == nil, calendarFetching.contains(primaryKey) {
            statsButton.setImage(nil, for: .normal)
            statsButton.setAttributedTitle(nil, for: .normal)
            statsButton.setTitle("日历加载中…", for: .normal)
            statsButton.setTitleColor(BearyColors.gray, for: .normal)
            return
        }
        let anyVisibleFailed = visibleKeys.contains { calendarFailed.contains($0) && calendarCache[$0] == nil }
        if anyVisibleFailed {
            statsButton.setImage(nil, for: .normal)
            statsButton.setAttributedTitle(nil, for: .normal)
            statsButton.setTitle("日历加载失败，点击重试", for: .normal)
            statsButton.setTitleColor(BearyColors.gray, for: .normal)
            return
        }
        guard let primaryKey = primaryKey, let data = calendarCache[primaryKey] else {
            statsButton.setImage(nil, for: .normal)
            statsButton.setAttributedTitle(nil, for: .normal)
            statsButton.setTitle("", for: .normal)
            return
        }
        statsButton.setImage(BearyIconImages.image(named: "icon_fire", pointSize: 16), for: .normal)
        statsButton.tintColor = BearyColors.orange
        statsButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        let streak = data.streak ?? 0
        let monthTotal = data.monthTotal ?? 0
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13.5),
            .foregroundColor: BearyColors.gray,
        ]
        let boldAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 13.5),
            .foregroundColor: BearyColors.ink,
        ]
        let text = NSMutableAttributedString(string: "已连续写 ", attributes: baseAttributes)
        text.append(NSAttributedString(string: "\(streak) 天", attributes: boldAttributes))
        text.append(NSAttributedString(string: " · 本月共 ", attributes: baseAttributes))
        text.append(NSAttributedString(string: "\(monthTotal) 篇", attributes: boldAttributes))
        statsButton.setTitle(nil, for: .normal)
        statsButton.setAttributedTitle(text, for: .normal)
    }

    private func primaryStatsMonthKey() -> String? {
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return nil }
            return BearyBeijingDay.monthKey(year: anchor.year, month: anchor.month)
        case .month:
            guard let displayed = calendarDisplayedMonth else { return nil }
            return BearyBeijingDay.monthKey(year: displayed.year, month: displayed.month)
        }
    }

    // MARK: - 时间线拉取

    private func loadTimelineFirstPage(completion: (() -> Void)? = nil) {
        timelineState = .loading
        updateChrome()
        // M2：已有行只更新变化行——刷新前记下旧分区，成功后若分区结构（日期键序列）
        // 不变则按行 diff 插删改，否则回落整表 reloadData（首屏旧表为空时同样 reloadData）。
        let oldSections = currentSections()
        let hadOldRows = timelineEntries.isEmpty == false
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let list):
                    strongSelf.timelineEntries = list.entries ?? []
                    strongSelf.trashCountValue = list.trashCount ?? 0
                    strongSelf.countsValue = list.tlCounts
                    strongSelf.timelineHasMore = (list.entries ?? []).count >= strongSelf.pageLimit
                    strongSelf.timelineState = .loaded
                    strongSelf.timelinePageFailed = false
                    strongSelf.updateTrashTitle()
                    strongSelf.updateCountsLabel()
                case .failure(let error):
                    strongSelf.timelineState = .failed
                    if case .unauthorized = error {
                        strongSelf.timelineUnauthorized = true
                        strongSelf.notifyLoginOnce()
                    }
                }
                if case .success = result, hadOldRows, strongSelf.tableView.window != nil,
                   strongSelf.applyFirstPageDiff(oldSections: oldSections) {
                    // diff 已插删改，跳过整表重载。
                } else {
                    strongSelf.tableView.reloadData()
                }
                strongSelf.updateChrome()
                strongSelf.tableView.refreshControl?.endRefreshing()
                completion?()
            }
        }
    }

    /// 首屏刷新行 diff：分区键序列必须全等、每行必须有唯一 id，
    /// 任一异常即返回 false 由调用方回落 reloadData，绝不带病插删。
    private func applyFirstPageDiff(oldSections: [DaySection]) -> Bool {
        let newSections = currentSections()
        guard newSections.count == oldSections.count else { return false }
        for index in 0..<oldSections.count {
            guard oldSections[index].dayKey == newSections[index].dayKey else { return false }
        }
        var deletes: [IndexPath] = []
        var inserts: [IndexPath] = []
        var reloads: [IndexPath] = []
        for section in 0..<oldSections.count {
            let oldRows = oldSections[section].entries
            let newRows = newSections[section].entries
            var oldIndexById: [String: Int] = [:]
            var newIndexById: [String: Int] = [:]
            for (row, entry) in oldRows.enumerated() {
                guard let entryId = entry.id, oldIndexById[entryId] == nil else { return false }
                oldIndexById[entryId] = row
            }
            for (row, entry) in newRows.enumerated() {
                guard let entryId = entry.id, newIndexById[entryId] == nil else { return false }
                newIndexById[entryId] = row
            }
            for (entryId, oldRow) in oldIndexById {
                if newIndexById[entryId] == nil {
                    deletes.append(IndexPath(row: oldRow, section: section))
                }
            }
            for (entryId, newRow) in newIndexById {
                if let oldRow = oldIndexById[entryId] {
                    if entrySignature(oldRows[oldRow]) != entrySignature(newRows[newRow]) {
                        reloads.append(IndexPath(row: oldRow, section: section))
                    }
                } else {
                    inserts.append(IndexPath(row: newRow, section: section))
                }
            }
        }
        if deletes.isEmpty && inserts.isEmpty && reloads.isEmpty { return true }
        tableView.performBatchUpdates({
            if !deletes.isEmpty { self.tableView.deleteRows(at: deletes, with: .fade) }
            if !inserts.isEmpty { self.tableView.insertRows(at: inserts, with: .fade) }
            if !reloads.isEmpty { self.tableView.reloadRows(at: reloads, with: .fade) }
        }, completion: nil)
        return true
    }

    /// 行内容签名：正文 + 公开态 + 互动数字，用于 diff 判定“变化行”。
    private func entrySignature(_ entry: Entry) -> String {
        var emoteParts: [String] = []
        for emote in entry.emotes ?? [] {
            emoteParts.append("\(emote.emote ?? ""):\(emote.count ?? 0):\(emote.mine ?? false)")
        }
        return "\(entry.content ?? "")|\(entry.isPublic ?? false)|\(entry.likeCount ?? 0)|\(entry.likedByMe ?? false)|\(entry.bookmarkedByMe ?? false)|\(emoteParts.joined(separator: ","))"
    }

    private func loadTimelineNextPage() {
        if timelineLoadingMore || !timelineHasMore { return }
        guard let last = timelineEntries.last else { return }
        guard let lastEntryIdValue = last.id, let lastCreated = last.createdAt else { return }
        timelineLoadingMore = true
        timelinePageFailed = false
        updateChrome()
        // M2：分页新增行走 insertRows + 错峰滑入（willDisplay 起播），不再整表 reloadData。
        let oldSections = currentSections()
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: pageLimit, before: lastCreated, beforeId: lastEntryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.timelineLoadingMore = false
                switch result {
                case .success(let list):
                    let fresh = list.entries ?? []
                    var known: Set<String> = []
                    for entry in strongSelf.timelineEntries {
                        if let entryIdValue = entry.id { known.insert(entryIdValue) }
                    }
                    for entry in fresh {
                        guard let entryIdValue = entry.id, !known.contains(entryIdValue) else { continue }
                        strongSelf.timelineEntries.append(entry)
                        known.insert(entryIdValue)
                    }
                    strongSelf.timelineHasMore = fresh.count >= strongSelf.pageLimit
                    strongSelf.timelinePageFailed = false
                    if let inserts = strongSelf.appendedRowIndexPaths(oldSections: oldSections),
                       strongSelf.tableView.window != nil {
                        // 减动效时不排错峰队列，直接插行终值。
                        if UIAccessibility.isReduceMotionEnabled == false {
                            strongSelf.staggerInsertOrder = Dictionary(uniqueKeysWithValues: inserts.enumerated().map { ($0.element, $0.offset) })
                        }
                        strongSelf.tableView.performBatchUpdates({
                            strongSelf.tableView.insertRows(at: inserts, with: .none)
                        }, completion: nil)
                    } else {
                        strongSelf.tableView.reloadData()
                    }
                case .failure:
                    // G15：分页失败 toast，并保持脚部可重试（hasMore 不动、
                    // updateFooter 出“加载失败，点击重试”）。
                    strongSelf.timelinePageFailed = true
                    strongSelf.showTimelineToast(message: "加载失败")
                }
                strongSelf.updateChrome()
            }
        }
    }

    /// 分页追加的行 diff：追加页只能出现在尾部分区（旧分区键序列必须是新分区的前缀，
    /// 旧分区内旧行 id 顺序不变且新增行只在分区尾部），否则返回 nil 回落 reloadData。
    private func appendedRowIndexPaths(oldSections: [DaySection]) -> [IndexPath]? {
        let newSections = currentSections()
        guard newSections.count >= oldSections.count else { return nil }
        var inserts: [IndexPath] = []
        for section in 0..<oldSections.count {
            guard oldSections[section].dayKey == newSections[section].dayKey else { return nil }
            let oldRows = oldSections[section].entries
            let newRows = newSections[section].entries
            guard newRows.count >= oldRows.count else { return nil }
            for row in 0..<oldRows.count {
                guard oldRows[row].id != nil, oldRows[row].id == newRows[row].id else { return nil }
            }
            for row in oldRows.count..<newRows.count {
                inserts.append(IndexPath(row: row, section: section))
            }
        }
        for section in oldSections.count..<newSections.count {
            for row in 0..<newSections[section].entries.count {
                inserts.append(IndexPath(row: row, section: section))
            }
        }
        return inserts
    }

    private func notifyLoginOnce() {
        if !loginNotified {
            loginNotified = true
            onRequireLogin?()
        }
    }

    // MARK: - 日历拉取与渲染

    private func fetchCalendarMonthsForCurrentView() {
        let keys = monthKeysForCurrentView()
        for key in keys {
            fetchCalendarMonth(key: key)
        }
        renderCalendar()
    }

    private func monthKeysForCurrentView() -> [String] {
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return [] }
            guard let monday = BearyBeijingDay.mondayOf(year: anchor.year, month: anchor.month, day: anchor.day) else { return [] }
            var keys: [String] = []
            for offset in 0..<7 {
                guard let day = BearyBeijingDay.shifted(year: monday.year, month: monday.month, day: monday.day, byDays: offset) else { continue }
                let key = BearyBeijingDay.monthKey(year: day.year, month: day.month)
                if !keys.contains(key) { keys.append(key) }
            }
            return keys
        case .month:
            guard let displayed = calendarDisplayedMonth else { return [] }
            return [BearyBeijingDay.monthKey(year: displayed.year, month: displayed.month)]
        }
    }

    private func fetchCalendarMonth(key: String, force: Bool = false) {
        if !force && calendarCache[key] != nil { return }
        if calendarFetching.contains(key) { return }
        calendarFetching.insert(key)
        BearyAPI.shared.fetchCalendar(month: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.calendarFetching.remove(key)
                switch result {
                case .success(let data):
                    strongSelf.calendarCache[key] = data
                    strongSelf.calendarFailed.remove(key)
                case .failure(let error):
                    strongSelf.calendarFailed.insert(key)
                    if case .unauthorized = error {
                        strongSelf.notifyLoginOnce()
                    }
                }
                strongSelf.updateStatsLine()
                strongSelf.renderCalendar()
                strongSelf.refreshHeaderHeight()
            }
        }
    }

    private func calendarDayCounts(year: Int, month: Int, day: Int) -> (published: Int, unpublished: Int, loaded: Bool) {
        let key = BearyBeijingDay.monthKey(year: year, month: month)
        guard let data = calendarCache[key] else { return (0, 0, false) }
        let info = data.days?["\(day)"]
        return (info?.pub ?? 0, info?.priv ?? 0, true)
    }

    private func makeCalendarDay(year: Int, month: Int, day: Int, isOffMonth: Bool) -> BearyCalendarDay {
        let counts = calendarDayCounts(year: year, month: month, day: day)
        let todayNumber = BearyBeijingDay.todayNumber()
        let dayNumber = BearyBeijingDay.dayNumber(year: year, month: month, day: day)
        let isFuture: Bool
        if let todayNumber = todayNumber, let dayNumber = dayNumber {
            isFuture = dayNumber > todayNumber
        } else {
            isFuture = false
        }
        var isToday = false
        if let today = BearyBeijingDay.todayComponents() {
            isToday = (today.year == year && today.month == month && today.day == day)
        }
        let key = BearyBeijingDay.dayKey(year: year, month: month, day: day)
        return BearyCalendarDay(
            year: year, month: month, day: day,
            isOffMonth: isOffMonth, isFuture: isFuture, isToday: isToday,
            isSelected: (selectedDayKey == key),
            published: counts.published, unpublished: counts.unpublished,
            dataLoaded: counts.loaded
        )
    }

    private func renderCalendar() {
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return }
            guard let monday = BearyBeijingDay.mondayOf(year: anchor.year, month: anchor.month, day: anchor.day) else { return }
            var days: [BearyCalendarDay] = []
            for offset in 0..<7 {
                guard let day = BearyBeijingDay.shifted(year: monday.year, month: monday.month, day: monday.day, byDays: offset) else { continue }
                days.append(makeCalendarDay(year: day.year, month: day.month, day: day.day, isOffMonth: false))
            }
            guard let first = days.first, let last = days.last else { return }
            // 网页周标题口径：起日“[年]M月d日 – ”+ 尾日（同月只写 d日，同年写 M月d日，跨年写 Y年M月d日）。
            // TL-6：各段之间有空格（网页 us=' '），≤340px 窄屏才去空格紧凑写。
            let isNarrow = tableView.bounds.width <= 340
            let us = isNarrow ? "" : " "
            let todayYear = BearyBeijingDay.todayComponents()?.year
            var title = ""
            if first.year != todayYear { title += "\(first.year)\(us)年\(us)" }
            title += "\(first.month)\(us)月\(us)\(first.day)\(us)日 – "
            if first.year == last.year && first.month == last.month {
                title += "\(last.day)\(us)日"
            } else if first.year == last.year {
                title += "\(last.month)\(us)月\(us)\(last.day)\(us)日"
            } else {
                title += "\(last.year)\(us)年\(us)\(last.month)\(us)月\(us)\(last.day)\(us)日"
            }
            calendarCard.setTitle(title)
            calendarCard.setToggleTitle("月视图")
            calendarCard.setNavigation(prevEnabled: true, nextEnabled: !isCurrentWeek(monday: monday))
            calendarCard.render(days: days, mode: .week)
        case .month:
            guard let displayed = calendarDisplayedMonth else { return }
            guard let dim = BearyBeijingDay.daysInMonth(year: displayed.year, month: displayed.month) else { return }
            guard let firstDate = BearyBeijingDay.date(year: displayed.year, month: displayed.month, day: 1) else { return }
            let firstWeekday = BearyBeijingDay.calendar.component(.weekday, from: firstDate)
            let leading = (firstWeekday + 5) % 7
            var days: [BearyCalendarDay] = []
            if leading > 0 {
                guard let prevMonth = BearyBeijingDay.shiftedMonth(year: displayed.year, month: displayed.month, byMonths: -1) else { return }
                guard let prevDim = BearyBeijingDay.daysInMonth(year: prevMonth.year, month: prevMonth.month) else { return }
                for day in (prevDim - leading + 1)...prevDim {
                    days.append(makeCalendarDay(year: prevMonth.year, month: prevMonth.month, day: day, isOffMonth: true))
                }
            }
            for day in 1...dim {
                days.append(makeCalendarDay(year: displayed.year, month: displayed.month, day: day, isOffMonth: false))
            }
            let trailing = (7 - (days.count % 7)) % 7
            if trailing > 0 {
                guard let nextMonth = BearyBeijingDay.shiftedMonth(year: displayed.year, month: displayed.month, byMonths: 1) else { return }
                for day in 1...trailing {
                    days.append(makeCalendarDay(year: nextMonth.year, month: nextMonth.month, day: day, isOffMonth: true))
                }
            }
            // TL-6 月标题：宽屏“Y 年 M 月”，≤340px 窄屏才为“Y年M月”。
            if tableView.bounds.width <= 340 {
                calendarCard.setTitle("\(displayed.year)年\(displayed.month)月")
            } else {
                calendarCard.setTitle("\(displayed.year) 年 \(displayed.month) 月")
            }
            calendarCard.setToggleTitle("周视图")
            calendarCard.setNavigation(prevEnabled: true, nextEnabled: !isCurrentMonth(displayed: displayed))
            calendarCard.render(days: days, mode: .month, weekKeys: currentWeekKeys())
        }
        updateStatsLine()
    }

    private func isCurrentWeek(monday: (year: Int, month: Int, day: Int)) -> Bool {
        guard let today = BearyBeijingDay.todayComponents() else { return false }
        guard let currentMonday = BearyBeijingDay.mondayOf(year: today.year, month: today.month, day: today.day) else { return false }
        return currentMonday.year == monday.year && currentMonday.month == monday.month && currentMonday.day == monday.day
    }

    private func isCurrentMonth(displayed: (year: Int, month: Int)) -> Bool {
        guard let today = BearyBeijingDay.todayComponents() else { return false }
        return today.year == displayed.year && today.month == displayed.month
    }

    private func toggleCalendarView() {
        // G9：切换视图后对缺失月份补拉一次（fetchCalendarMonthsForCurrentView
        // 只发未缓存/未在途的月份），在途时统计行出“日历加载中…”；
        // 不再长期停留在“全灰假装无日记”。此前严格零请求的注释已作废。
        var targetMode = calendarMode
        var targetDisplayed = calendarDisplayedMonth
        var targetAnchor = calendarAnchor
        switch calendarMode {
        case .week:
            targetMode = .month
            if let selected = selectedDayKey {
                let parts = selected.split(separator: "-")
                if parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]) {
                    targetDisplayed = (year, month)
                }
            } else if let anchor = calendarAnchor {
                targetDisplayed = (anchor.year, anchor.month)
            }
        case .month:
            targetMode = .week
            if let selected = selectedDayKey {
                let parts = selected.split(separator: "-")
                if parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
                    targetAnchor = (year, month, day)
                }
            } else if let displayed = calendarDisplayedMonth, let today = BearyBeijingDay.todayComponents(), today.year == displayed.year && today.month == displayed.month {
                targetAnchor = today
            }
        }
        performCalendarTransition { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.calendarMode = targetMode
            strongSelf.calendarDisplayedMonth = targetDisplayed
            strongSelf.calendarAnchor = targetAnchor
            strongSelf.renderCalendar()
            // G9：目标视图的缺失月份在此补拉（renderCalendar 先出加载态）。
            strongSelf.fetchCalendarMonthsForCurrentView()
        }
    }

    private func stepCalendar(delta: Int) {
        var targetAnchor = calendarAnchor
        var targetDisplayed = calendarDisplayedMonth
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return }
            // 下一周不许翻进未来：已是本周时 next 按钮本身已禁用，此处再拦一道。
            if delta > 0 {
                guard let monday = BearyBeijingDay.mondayOf(year: anchor.year, month: anchor.month, day: anchor.day) else { return }
                if isCurrentWeek(monday: monday) { return }
            }
            guard let moved = BearyBeijingDay.shifted(year: anchor.year, month: anchor.month, day: anchor.day, byDays: delta * 7) else { return }
            targetAnchor = moved
        case .month:
            guard let displayed = calendarDisplayedMonth else { return }
            if delta > 0 && isCurrentMonth(displayed: displayed) { return }
            guard let moved = BearyBeijingDay.shiftedMonth(year: displayed.year, month: displayed.month, byMonths: delta) else { return }
            targetDisplayed = moved
        }
        performCalendarTransition { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.calendarAnchor = targetAnchor
            strongSelf.calendarDisplayedMonth = targetDisplayed
            strongSelf.fetchCalendarMonthsForCurrentView()
        }
    }

    /// 清单 6 回到今天：周/月步进逻辑不动（calendarMode 不变），只把
    /// 锚点/展示月拉回今天所在周/月，再把选区切回今天并重拉当日数据
    /// （selectDay：已是今天则 clear:false 重拉，否则 clear:true 换日重拉）。
    /// 周模式下锚点=今天 → renderCalendar 出本周；月模式下展示月=本月。
    private func jumpToToday() {
        guard let today = BearyBeijingDay.todayComponents() else { return }
        let key = BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day)
        performCalendarTransition { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.calendarAnchor = today
            strongSelf.calendarDisplayedMonth = (today.year, today.month)
            strongSelf.renderCalendar()
            strongSelf.fetchCalendarMonthsForCurrentView()
            strongSelf.selectDay(key: key)
        }
    }

    // MARK: - 当日面板（TL-7/TL-8）

    private func didSelectCalendarDay(_ day: BearyCalendarDay) {
        selectDay(key: day.key)
    }

    /// TL-8：点已选中日不取消筛选，只重渲 + 重拉当日；
    /// E4-5：同日在途拉取未完成时不重复发请求。
    private func selectDay(key: String) {
        if key == selectedDayKey {
            renderCalendar()
            tableView.reloadData()
            fetchDayEntries(key: key, clear: false)
            return
        }
        selectedDayKey = key
        renderCalendar()
        tableView.reloadData()
        updateChrome()
        refreshHeaderHeight()
        fetchDayEntries(key: key, clear: true)
    }

    private func fetchDayEntries(key: String, clear: Bool) {
        // 在途守卫：同一天的拉取还在飞，不再发第二份（只靠回包归属丢弃不够）。
        if dayKeyForLoad == key && dayState == .loading { return }
        // fixSel 判定用：只有“同一天的面板此前有篇、本次重拉变空”才算删空。
        let wasNonEmptyForKey = (dayEntriesKey == key && !dayEntries.isEmpty)
        dayKeyForLoad = key
        dayState = .loading
        if clear {
            dayEntries = []
            dayEntriesKey = nil
            tableView.reloadData()
        }
        BearyAPI.shared.fetchTimelineDay(date: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                if strongSelf.dayKeyForLoad != key { return }
                switch result {
                case .success(let list):
                    strongSelf.dayEntries = list.entries ?? []
                    strongSelf.dayEntriesKey = key
                    strongSelf.dayState = .loaded
                    if wasNonEmptyForKey && strongSelf.dayEntries.isEmpty {
                        strongSelf.applyDayFixSel()
                        return
                    }
                case .failure(let error):
                    strongSelf.dayState = .failed
                    if case .unauthorized = error {
                        strongSelf.notifyLoginOnce()
                    }
                }
                // M2：同日刷新（clear:false）只重载当日面板分区，不整表 reloadData；
                // 换日（clear:true）或表未入窗时仍整表重载。
                if clear == false && strongSelf.tableView.window != nil && strongSelf.selectedDayKey != nil {
                    strongSelf.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
                } else {
                    strongSelf.tableView.reloadData()
                }
                strongSelf.updateChrome()
            }
        }
    }

    private func clearDaySelection() {
        selectedDayKey = nil
        dayKeyForLoad = nil
        dayEntries = []
        dayEntriesKey = nil
        dayState = .idle
        showJumpNote = false
        jumpNoteTimer?.invalidate()
        jumpNoteTimer = nil
        renderCalendar()
        tableView.reloadData()
        updateChrome()
        refreshHeaderHeight()
    }

    /// TL-8 calFixSel 等价逻辑：选中日变空时，同月内先往前、再往后找最近有日记日
    /// 跳转（周视图下锚点同步跟过去）；同月再无有篇日则取消选中并清面板。
    /// 跳转时面板头下出 3 秒提示“这天已没有日记，已跳到最近的一天”。
    /// 注：网页前向搜索上限写死 31 天，本实现按当月实际天数 bound，结果等价。
    private func applyDayFixSel() {
        guard let key = selectedDayKey else { return }
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            clearDaySelection()
            return
        }
        let monthKey = BearyBeijingDay.monthKey(year: year, month: month)
        guard let monthData = calendarCache[monthKey] else {
            clearDaySelection()
            return
        }
        var foundDay: Int?
        var backward = day - 1
        while backward >= 1 && foundDay == nil {
            let info = monthData.days?["\(backward)"]
            if (info?.pub ?? 0) + (info?.priv ?? 0) > 0 { foundDay = backward }
            backward -= 1
        }
        if foundDay == nil {
            guard let dim = BearyBeijingDay.daysInMonth(year: year, month: month) else {
                clearDaySelection()
                return
            }
            var forward = day + 1
            while forward <= dim && foundDay == nil {
                let info = monthData.days?["\(forward)"]
                if (info?.pub ?? 0) + (info?.priv ?? 0) > 0 { foundDay = forward }
                forward += 1
            }
        }
        if let foundDay = foundDay {
            let newKey = BearyBeijingDay.dayKey(year: year, month: month, day: foundDay)
            selectedDayKey = newKey
            if calendarMode == .week {
                calendarAnchor = (year, month, foundDay)
            }
            showJumpNote = true
            jumpNoteTimer?.invalidate()
            jumpNoteTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                guard let strongSelf = self else { return }
                // M16：提示消失先做 0.4s 透明度过渡，再清标记重载（减动效直清）。
                let cleanup = {
                    strongSelf.showJumpNote = false
                    strongSelf.jumpNoteTimer = nil
                    strongSelf.tableView.reloadData()
                }
                if UIAccessibility.isReduceMotionEnabled {
                    cleanup()
                } else if let noteLabel = strongSelf.jumpNoteLabel {
                    UIView.animate(withDuration: 0.4, animations: {
                        noteLabel.alpha = 0
                    }, completion: { _ in cleanup() })
                } else {
                    cleanup()
                }
            }
            renderCalendar()
            tableView.reloadData()
            updateChrome()
            fetchDayEntries(key: newKey, clear: true)
        } else {
            clearDaySelection()
        }
    }

    /// TL-7 当日面板表头（网页 calDayRender 口径）：
    /// “M 月 d 日 周X · N篇”+ 全公开/全未公开注记；加载中补“加载中…”（M15），
    /// 失败时出“加载失败”（重试走面板头旁的“重试”钮，见 U15）。
    /// head/suffix 分段供表头富文本使用（L13：日期加粗 + 计数灰色 12.5）。
    private func dayPanelTitleParts(key: String) -> (head: String, suffix: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return (key, "") }
        var weekdayText = ""
        if let date = BearyBeijingDay.date(year: year, month: month, day: day) {
            let weekday = BearyBeijingDay.calendar.component(.weekday, from: date)
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            if weekday >= 1 && weekday <= names.count {
                weekdayText = " " + names[weekday - 1]
            }
        }
        let head = "\(month) 月 \(day) 日\(weekdayText)"
        if dayState == .failed {
            return (head, " · 加载失败")
        }
        if dayState != .loaded {
            return (head, " · 加载中…")
        }
        var suffix = " · \(dayEntries.count)篇"
        if !dayEntries.isEmpty {
            let allPublic = dayEntries.allSatisfy { $0.isPublic == true }
            let allPrivate = dayEntries.allSatisfy { $0.isPublic != true }
            if allPublic {
                suffix += " · 都已公开"
            } else if allPrivate {
                suffix += " · 都未公开"
            }
        }
        return (head, suffix)
    }

    private func dayPanelTitle(key: String) -> String {
        let parts = dayPanelTitleParts(key: key)
        return parts.head + parts.suffix
    }

    // MARK: - 列表分区与空态/脚部

    private func currentSections() -> [DaySection] {
        var sections: [DaySection] = []
        // TL-7：当日面板是第一个分区，时间线分区紧随其后，不替换时间线。
        if let key = selectedDayKey {
            sections.append(DaySection(dayKey: key, title: dayPanelTitle(key: key), entries: dayEntries))
        }
        var indexByKey: [String: Int] = [:]
        for entry in timelineEntries {
            guard let createdMs = entry.createdAt else { continue }
            guard let key = BearyBeijingDay.dayKey(ofMs: createdMs) else { continue }
            // 清单 7：筛选只过滤时间线分区（当日面板在上面已原样加入）；
            // isPublic 判定与行圆点一致（entry.isPublic ?? false）。
            if timelineFilter == .published && entry.isPublic != true { continue }
            if timelineFilter == .unpublished && entry.isPublic == true { continue }
            if let existing = indexByKey[key] {
                sections[existing].entries.append(entry)
            } else {
                indexByKey[key] = sections.count
                sections.append(DaySection(dayKey: key, title: dayTitleForMs(createdMs), entries: [entry]))
            }
        }
        return sections
    }

    private func dayTitleForMs(_ ms: Int) -> String {
        guard let comps = BearyBeijingDay.components(ofMs: ms) else { return "" }
        let label = "\(comps.month)月\(comps.day)日"
        guard let today = BearyBeijingDay.todayComponents() else { return label }
        if today.year == comps.year && today.month == comps.month && today.day == comps.day {
            return "今天 · \(label)"
        }
        guard let yesterday = BearyBeijingDay.shifted(year: today.year, month: today.month, day: today.day, byDays: -1) else { return label }
        if yesterday.year == comps.year && yesterday.month == comps.month && yesterday.day == comps.day {
            return "昨天 · \(label)"
        }
        return label
    }

    private func emptyView(title: String, subtitle: String, actionTitle: String?, action: (() -> Void)?, iconName: String = "icon_tray") -> UIView {
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        // I13：空态图标按场景区分（登录态 calendar、失败态 wifi-off，默认 tray）；
        // 资产缺失时回落 tray，不留空白。
        iconView.image = BearyIconImages.image(named: iconName, pointSize: 36) ?? BearyIconImages.image(named: "icon_tray", pointSize: 36)
        iconView.tintColor = BearyColors.gray
        iconView.contentMode = .scaleAspectFit
        let titleView = UILabel()
        titleView.translatesAutoresizingMaskIntoConstraints = false
        titleView.text = title
        titleView.font = UIFont.systemFont(ofSize: 15)
        titleView.textColor = BearyColors.ink
        titleView.textAlignment = .center
        let subtitleView = UILabel()
        subtitleView.translatesAutoresizingMaskIntoConstraints = false
        subtitleView.text = subtitle
        subtitleView.font = UIFont.systemFont(ofSize: 13)
        subtitleView.textColor = BearyColors.gray
        subtitleView.textAlignment = .center
        subtitleView.numberOfLines = 0
        var arranged: [UIView] = [iconView, titleView, subtitleView]
        if let actionTitle = actionTitle {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(actionTitle, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
            button.setTitleColor(BearyColors.blue, for: .normal)
            button.addTarget(self, action: #selector(didTapEmptyAction(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "timelineEmptyAction"
            emptyActionHandler = action
            arranged.append(button)
        }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }

    private var emptyActionHandler: (() -> Void)?

    @objc private func didTapEmptyAction(_ sender: UIButton) {
        emptyActionHandler?()
    }

    private func updateChrome() {
        // TL-7：当日面板的加载/失败/空态只反映在面板表头里，不再用整表背景空态
        // 覆盖时间线；背景空态只在时间线与当日面板双双无行时出现。
        let sections = currentSections()
        let hasRows = sections.contains { !$0.entries.isEmpty }
        let isLoginEmpty = (timelineState == .failed && timelineUnauthorized && timelineEntries.isEmpty)
        if timelineState == .loading && timelineEntries.isEmpty && !hasRows {
            // M2：首屏加载态（此前 backgroundView 置 nil，只有下拉才有 spinner）。
            tableView.backgroundView = timelineLoadingView()
        } else if timelineState == .failed && timelineEntries.isEmpty && !hasRows {
            if isLoginEmpty {
                tableView.backgroundView = emptyView(title: "先登录", subtitle: "时间线只放你自己的日记，登录后就能看", actionTitle: "去登录", action: { [weak self] in
                    self?.onRequireLogin?()
                }, iconName: "IconCalendar")
            } else {
                // W10：加载失败空态副标题补网页同款“网络好像不太顺”。
                tableView.backgroundView = emptyView(title: "加载失败", subtitle: "网络好像不太顺", actionTitle: "点击重试", action: { [weak self] in
                    self?.reloadTimeline()
                }, iconName: "icon_wifi_off")
            }
        } else if timelineState == .loaded && !hasRows {
            if timelineFilter != .all {
                // 清单 7：筛选致空时不谎称“还没有日记”（数据其实有，只是被滤掉）。
                tableView.backgroundView = emptyView(title: "没有符合筛选的日记", subtitle: "换个筛选看看", actionTitle: nil, action: nil)
            } else {
                tableView.backgroundView = emptyView(title: "还没有日记", subtitle: "写下第一篇，它会出现在这里", actionTitle: nil, action: nil)
            }
        } else {
            tableView.backgroundView = nil
        }
        updateFooter()
    }

    /// M2 首屏加载视图：居中 spinner + “正在加载…”（仅首屏无行时作 backgroundView）。
    private func timelineLoadingView() -> UIView {
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = BearyColors.gray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        let label = UILabel()
        label.text = "正在加载…"
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        label.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
        ])
        return container
    }

    /// G15 分页失败 toast（与回收站 toast 同口径：ink 底、自动消失）。
    private func showTimelineToast(message: String) {
        timelineToastLabel.text = message
        timelineToastWrap.alpha = 0
        UIView.animate(withDuration: 0.2, animations: {
            self.timelineToastWrap.alpha = 1
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                UIView.animate(withDuration: 0.3, animations: {
                    self.timelineToastWrap.alpha = 0
                }, completion: nil)
            }
        })
    }

    private func updateFooter() {
        // 脚部只属于时间线翻页；当日面板的加载/失败态在面板表头里。
        // M18：脚部 spinner 不再是死代码——加载时进脚部层级与文案并排。
        footerSpinner.stopAnimating()
        footerSpinner.removeFromSuperview()
        if timelineLoadingMore {
            tableView.tableFooterView = footerLoadingHolder()
        } else if timelinePageFailed && timelineHasMore {
            // G15：分页失败后脚部保持可重试。
            loadMoreButton.setTitle("加载失败，点击重试", for: .normal)
            loadMoreButton.isEnabled = true
            tableView.tableFooterView = footerHolder(button: loadMoreButton)
        } else if timelineHasMore {
            loadMoreButton.setTitle("加载更多", for: .normal)
            loadMoreButton.isEnabled = true
            tableView.tableFooterView = footerHolder(button: loadMoreButton)
        } else {
            tableView.tableFooterView = nil
        }
    }

    /// M18 脚部加载态：spinner + “正在加载…”居中行（高 44，与按钮脚部同高）。
    private func footerLoadingHolder() -> UIView {
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
        let label = UILabel()
        label.text = "正在加载…"
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = BearyColors.gray
        footerSpinner.isHidden = false
        footerSpinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [footerSpinner, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    private func footerHolder(button: UIButton) -> UIView {
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
        button.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    @objc private func didTapFooter() {
        loadTimelineNextPage()
    }

    @objc private func didTapTrash() {
        onOpenTrash?()
    }

    /// 清单 7 筛选切换：只改本页过滤档位 + 整表重载，不发任何服务端请求，
    /// 不动日历月份缓存与统计；分页游标与服务端排序原样保留。
    @objc private func didChangeTimelineFilter(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 1:
            timelineFilter = .published
        case 2:
            timelineFilter = .unpublished
        default:
            timelineFilter = .all
        }
        tableView.reloadData()
        updateChrome()
    }

    @objc private func didTapStats() {
        // G14：重试全部可视失败月份（周视图跨月时次要月份也有入口，不只主月份）。
        for key in monthKeysForCurrentView() {
            if calendarFailed.contains(key) && calendarCache[key] == nil {
                fetchCalendarMonth(key: key)
            }
        }
    }

    @objc private func didTapDayRetry() {
        // U15：当日失败面板头旁“重试”钮：同日重拉，不清面板。
        guard let key = selectedDayKey else { return }
        fetchDayEntries(key: key, clear: false)
    }
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearyTimelineViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        return currentSections().count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let sections = currentSections()
        guard section < sections.count else { return 0 }
        return sections[section].entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else {
            return UITableViewCell()
        }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: BearyTimelineCell.reuseIdentifier, for: indexPath) as? BearyTimelineCell else {
            return UITableViewCell()
        }
        cell.configure(entry: sections[indexPath.section].entries[indexPath.row])
        cell.onEditEntry = onEditEntry
        cell.onDeleteEntry = onDeleteEntry
        cell.onQuoteEntry = onQuoteEntry
        // N7：复用详情文件内的查看器（详情 lane 已由 private 改为内部类），
        // 全屏模态弹出，弹出方式与详情页同款（已弹出时不叠加、减动效直显）。
        cell.onTapImages = { [weak self] keys, index in
            guard let self = self, self.presentedViewController == nil else { return }
            let viewer = BearyEntryImageViewerViewController(imageKeys: keys, startIndex: index)
            viewer.modalPresentationStyle = .fullScreen
            self.present(viewer, animated: UIAccessibility.isReduceMotionEnabled == false, completion: nil)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let sections = currentSections()
        guard section < sections.count else { return nil }
        let isDayPanel = (section == 0 && selectedDayKey != nil)
        let label = UILabel()
        // L13：当日面板头拆日期加粗 + 计数灰色 12.5 两段富文本；时间线分区头不变。
        if isDayPanel, let dayKey = selectedDayKey {
            let parts = dayPanelTitleParts(key: dayKey)
            let attributed = NSMutableAttributedString(string: parts.head, attributes: [
                .font: UIFont.boldSystemFont(ofSize: 15),
                .foregroundColor: BearyColors.ink,
            ])
            if parts.suffix.isEmpty == false {
                attributed.append(NSAttributedString(string: parts.suffix, attributes: [
                    .font: UIFont.systemFont(ofSize: 12.5),
                    .foregroundColor: BearyColors.gray,
                ]))
            }
            label.attributedText = attributed
        } else {
            label.text = sections[section].title
        }
        label.font = UIFont.boldSystemFont(ofSize: isDayPanel ? 15 : 13)
        label.textColor = isDayPanel ? BearyColors.ink : BearyColors.gray
        label.numberOfLines = 0
        let holder = UIView()
        holder.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        // TL-1：时间线日期头与行左缩进对齐（网页 .date-h padding-left 36px）；
        // 当日面板头按网页 .cal-day-t 取 16。
        let leading: CGFloat = isDayPanel ? 16 : 36
        var bottomView: UIView = label
        var bottomConstant: CGFloat = -8
        // U15：当日失败时面板头旁加“重试”文字钮（此前只能靠“点一下日期再试”猜）。
        var labelTrailingAnchor: NSLayoutXAxisAnchor = holder.trailingAnchor
        var labelTrailingConstant: CGFloat = -16
        if isDayPanel && dayState == .failed {
            let retryButton = UIButton(type: .system)
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.setTitle("重试", for: .normal)
            retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.5)
            retryButton.setTitleColor(BearyColors.blue, for: .normal)
            retryButton.addTarget(self, action: #selector(didTapDayRetry), for: .touchUpInside)
            holder.addSubview(retryButton)
            NSLayoutConstraint.activate([
                retryButton.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
                retryButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
            labelTrailingAnchor = retryButton.leadingAnchor
            labelTrailingConstant = -8
        }
        if isDayPanel && showJumpNote {
            let jumpLabel = UILabel()
            jumpLabel.text = "这天已没有日记，已跳到最近的一天"
            jumpLabel.font = UIFont.systemFont(ofSize: 12)
            jumpLabel.textColor = BearyColors.gray
            jumpLabel.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(jumpLabel)
            NSLayoutConstraint.activate([
                jumpLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
                jumpLabel.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: leading),
                jumpLabel.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            ])
            bottomView = jumpLabel
            bottomConstant = -8
            // M16：跳转提示出现时 0.3s 透明度淡入（减动效直显）。
            jumpNoteLabel = jumpLabel
            if UIAccessibility.isReduceMotionEnabled == false {
                jumpLabel.alpha = 0
                UIView.animate(withDuration: 0.3, animations: {
                    jumpLabel.alpha = 1
                }, completion: nil)
            }
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 18),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: labelTrailingAnchor, constant: labelTrailingConstant),
            bottomView.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: bottomConstant),
        ])
        // N8：plain 悬浮头原本是透明 UIView，滚动悬浮时下方卡片文字会透出来；
        // 补与背景同色的不透明底。样式仍是 plain（不改 grouped），悬浮行为不变。
        holder.backgroundColor = BearyColors.bg
        // R1 日期头圆点与竖线承接：条目圆点代码不动，真缺口只在 header。
        // 修法选 header 内补段（不做 section 容器级）：plain 表格没有 section
        // 容器视图，容器级画线要靠帧追踪（悬浮头 + 可变行高 + 批量更新下极脆）；
        // 而行线本就占满整个 cell 高、header 紧贴上下行，header 内一段满高线
        // + 日期文字同行高度处的圆点即可拼成连续线，无需追踪。
        // 线与 cell 线同 x（leading 11）同宽（2）、同色（BearyColors.line）；
        // 圆点与条目公开款同款（17px line 色外环 + 14px 墨圆 + 2.5 bg 边）。
        // 日期头用公开款：头代表整组日期（组内公开/私密混写），私密与否是
        // 每行的圆点 + pill 的事，头不替整组表隐私。
        // 当日面板头除外：其文字 leading 16 会撞上圆点横向范围（5…19），且它
        // 是日历选区面板而非时间线日期组；其不透明底（N8）照常补。
        if !isDayPanel {
            let headerLineView = UIView()
            headerLineView.backgroundColor = BearyColors.line
            headerLineView.translatesAutoresizingMaskIntoConstraints = false
            let headerDotRingView = UIView()
            headerDotRingView.backgroundColor = BearyColors.line
            headerDotRingView.layer.cornerRadius = 8.5
            headerDotRingView.translatesAutoresizingMaskIntoConstraints = false
            let headerDotView = UIView()
            headerDotView.backgroundColor = BearyColors.ink
            headerDotView.layer.borderWidth = 2.5
            headerDotView.layer.borderColor = BearyColors.bg.cgColor
            headerDotView.layer.cornerRadius = 7
            headerDotView.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(headerLineView)
            holder.addSubview(headerDotRingView)
            holder.addSubview(headerDotView)
            NSLayoutConstraint.activate([
                headerLineView.topAnchor.constraint(equalTo: holder.topAnchor),
                headerLineView.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                headerLineView.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 11),
                headerLineView.widthAnchor.constraint(equalToConstant: 2),
                headerDotRingView.centerXAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
                headerDotRingView.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                headerDotRingView.widthAnchor.constraint(equalToConstant: 17),
                headerDotRingView.heightAnchor.constraint(equalToConstant: 17),
                headerDotView.centerXAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
                headerDotView.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                headerDotView.widthAnchor.constraint(equalToConstant: 14),
                headerDotView.heightAnchor.constraint(equalToConstant: 14),
            ])
        }
        return holder
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return }
        onOpenEntry?(sections[indexPath.section].entries[indexPath.row])
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // M2：分页新增行错峰滑入——cell 即将上屏时从透明 + 下偏 6 起播，
        // 按原始序号错峰（减动效时队列为空，不播）。
        guard let order = staggerInsertOrder[indexPath] else { return }
        staggerInsertOrder[indexPath] = nil
        cell.alpha = 0
        cell.transform = CGAffineTransform(translationX: 0, y: 6)
        let delay = min(Double(order) * 0.018, 0.24)
        UIView.animate(withDuration: 0.32, delay: delay, options: .curveEaseOut, animations: {
            cell.alpha = 1
            cell.transform = .identity
        }, completion: nil)
    }

    // MARK: - 清单 2 滚动隐藏栏（时间线部分）

    /// 主滚动视图即本表（plain）：向下滚过阈值藏栏、向上滚显栏；
    /// 顶部回弹区（offset ≤ 0，含 44pt 筛选条 inset 的初始 -44）一律显栏。
    /// 阈值 120pt：小幅抖动不触发，只在明确下滑一段后藏栏。
    /// FAB 随栏同隐同现由容器 helper 内部负责，本页不直接碰 FAB。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        let y = scrollView.contentOffset.y
        defer { timelineLastScrollOffsetY = y }
        if y <= 0 {
            if timelineChromeHidden {
                setTimelineChromeHidden(false)
            }
            return
        }
        if y > timelineLastScrollOffsetY && y > 120 && !timelineChromeHidden {
            setTimelineChromeHidden(true)
        } else if y < timelineLastScrollOffsetY && timelineChromeHidden {
            setTimelineChromeHidden(false)
        }
    }

    private func setTimelineChromeHidden(_ hidden: Bool) {
        timelineChromeHidden = hidden
        // setChromeHidden 由容器 lane 在 SceneDelegate.swift 提供，本文件只调用；
        // 容器 lane 落地前本调用编译不过（见汇报 CI 风险点）。
        SceneDelegate.chrome?.setChromeHidden(hidden, animated: true)
    }
}
