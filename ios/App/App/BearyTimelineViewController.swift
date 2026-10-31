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
    /// 64 包反馈修（第 4 项，Li 混色方案）：旧“全天同色多数判定”整段删除——
    /// 每种状态各自按数量拆现有图形词汇（公开=橙、私密=蓝），一天内先画公开组、
    /// 再画私密组拼进同一格：1→1 点、2→2 点、3→三角形、4→正方形、5→五边形、
    /// 6→五边形+1 点、7→五边形+2 点、单状态 8+ 按 7 封顶。
    /// 逐一核对 Li 的例子：2 篇 1 公开 = 1 橙点 + 1 蓝点；3 篇 2 公开 = 2 橙点 + 1 蓝点；
    /// 10 篇 7 公开 3 私密 = 橙五边形 + 橙 2 点 + 蓝三角形。
    static func marks(published: Int, unpublished: Int) -> [BearyCalendarMark] {
        return marksForCount(published, color: .published) + marksForCount(unpublished, color: .unpublished)
    }

    private static func marksForCount(_ count: Int, color: BearyCalendarMarkColor) -> [BearyCalendarMark] {
        let dot = BearyCalendarMark(kind: .dot, color: color, size: 6)
        switch min(max(count, 0), 7) {
        case 0:
            return []
        case 1:
            return [dot]
        case 2:
            return [dot, dot]
        case 3:
            return [BearyCalendarMark(kind: .triangle, color: color, size: 12)]
        case 4:
            return [BearyCalendarMark(kind: .square, color: color, size: 11)]
        case 5:
            return [BearyCalendarMark(kind: .pentagon, color: color, size: 12)]
        case 6:
            return [BearyCalendarMark(kind: .pentagon, color: color, size: 12), dot]
        case 7:
            return [BearyCalendarMark(kind: .pentagon, color: color, size: 12), dot, dot]
        default:
            return []
        }
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
        // P1-9：窄屏双状态高篇数日标记总宽可能超过格宽，超宽部分必须
        // 裁在本格内、不侵入相邻格；居中绘制见 draw（未超宽时与旧左对齐
        // 等价，因格内 markView 本就居中且宽 = 总宽）。
        clipsToBounds = true
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
        // P1-9：居中绘制——总宽 <= 框宽时起点与旧左对齐等价（框宽即总宽
        // 或框居中）；总宽 > 框宽（日历格宽上限裁剪）时左右对称裁剪，
        // 不偏向一侧侵入相邻格。几何/颜色/尺寸/间距口径一律不动。
        var totalWidth: CGFloat = 0
        for (index, mark) in marks.enumerated() {
            if index > 0 { totalWidth += 2 }
            totalWidth += mark.size
        }
        var cursor: CGFloat = (rect.width - totalWidth) / 2
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
        // 8-3 例外：日历格数字钉在 30pt 圆 / 50pt 格里，缩放会撑破格几何，不缩放。
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
            // P1-9：标记行宽上限 = 本格宽（fillEqually 均分后的格宽，随屏宽走，
            // 不写死 pt 值，避免窄屏 320 下 37pt 格被 42pt+ 双状态标记撑出、
            // 宽屏下又无谓裁剪）；超宽部分由 markView 居中裁剪消化。
            markView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
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
        // P2：跨月占位格文案与视觉一致——视觉侧占位格标记被清（marks=[],
        // 见下）、选中态被 isOffMonth 分支压掉、且 isEnabled=false，
        // 故文案不得报篇数（即使该日邻月本身有篇，当前占位格也未呈现）。
        let dayTotal = day.isOffMonth ? 0 : day.published + day.unpublished
        if dayTotal > 0 {
            accessibilityLabel = "\(day.month)月\(day.day)日，共 \(dayTotal) 篇，其中 \(day.unpublished) 篇私密"
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
    var onGoToday: (() -> Void)?

    private let titleLabel = UILabel()
    private let todayButton = BearyHit44Button(type: .system)
    /// “今”钮与标题之间的 8pt 间隔垫片：与钮同显同隐，隐藏时栈内
    /// 不占位，标题 → 切换钮间距与改前（custom 0）完全一致。
    private let todaySpacer = UIView()
    private let toggleButton = BearyHit44Button(type: .system)
    private let prevButton = BearyHit44Button(type: .system)
    private let nextButton = BearyHit44Button(type: .system)
    private let gridStack = UIStackView()
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
        toggleButton.bearyAddPressFeedback()

        // C10 回到今天：轻量胶囊“今”，与翻页钮同款（faint 底、32×32、
        // 圆角 16、12.5 粗体），默认隐藏，只由 VC 的 setTodayButtonVisible
        // 在显示月份/周不含今天或选中日不是今天时浮现；无障碍名“回到今天”。
        todayButton.translatesAutoresizingMaskIntoConstraints = false
        todayButton.backgroundColor = BearyColors.faint
        todayButton.layer.cornerRadius = 16
        todayButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 12.5)
        todayButton.setTitleColor(BearyColors.ink, for: .normal)
        todayButton.setTitle("今", for: .normal)
        todayButton.accessibilityLabel = "回到今天"
        todayButton.addTarget(self, action: #selector(didTapToday), for: .touchUpInside)
        todayButton.bearyAddPressFeedback()
        todayButton.isHidden = true
        todayButton.alpha = 0
        todaySpacer.translatesAutoresizingMaskIntoConstraints = false
        todaySpacer.isHidden = true

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
        prevButton.bearyAddPressHaptic()

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
        nextButton.bearyAddPressFeedback()

        let topRow = UIStackView(arrangedSubviews: [titleLabel, todaySpacer, todayButton, toggleButton, prevButton, nextButton])
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
            // 8-3 例外：星期单字属日历格装饰头，不缩放。
            label.font = UIFont.systemFont(ofSize: 12)
            label.textColor = BearyColors.gray
            label.textAlignment = .center
            weekdayRow.addArrangedSubview(label)
        }

        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridStack.axis = .vertical

        let outer = UIStackView(arrangedSubviews: [topRow, weekdayRow, gridStack])
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.axis = .vertical
        outer.spacing = 0
        outer.setCustomSpacing(8, after: topRow)
        outer.setCustomSpacing(6, after: weekdayRow)
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            todaySpacer.widthAnchor.constraint(equalToConstant: 8),
            todayButton.widthAnchor.constraint(equalToConstant: 32),
            todayButton.heightAnchor.constraint(equalToConstant: 32),
            toggleButton.heightAnchor.constraint(equalToConstant: 32),
            // 64 包反馈修（第 6 项）：周/月切换钮等宽——旧代码宽度随标题内容走，
            // “月视图”/“周视图”两态渲染宽不一致；固定 64（内边距 12+12 + 3 字×12.5 + 余量），
            // 两态同宽，不再随标题伸缩。
            toggleButton.widthAnchor.constraint(equalToConstant: 64),
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

    func setTitle(_ text: String) {
        titleLabel.text = text
    }

    /// N3：换日时日历标题淡入（0.2s、只动 alpha；减动效时调用方不调本方法）。
    /// 标题 label 是卡内常驻节点，不重建、不重播其他元素。
    func fadeTitleForDaySwitch() {
        titleLabel.alpha = 0
        UIView.animate(withDuration: 0.2, animations: {
            self.titleLabel.alpha = 1
        })
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

    /// C10 “今”钮显隐（VC 在每次 renderCalendar 末尾重算）：浮现 0.2s
    /// 淡入、隐藏 0.2s 淡出后才 isHidden（栈内不占位）；减动效直设终值。
    /// 重复调用同态时直接返回，不重播淡入淡出。
    func setTodayButtonVisible(_ visible: Bool) {
        if visible {
            guard todayButton.isHidden || todayButton.alpha < 1 else { return }
            todayButton.isHidden = false
            todaySpacer.isHidden = false
            if UIAccessibility.isReduceMotionEnabled {
                todayButton.alpha = 1
            } else {
                UIView.animate(withDuration: 0.2, animations: {
                    self.todayButton.alpha = 1
                })
            }
        } else {
            guard !todayButton.isHidden else { return }
            if UIAccessibility.isReduceMotionEnabled {
                todayButton.alpha = 0
                todayButton.isHidden = true
                todaySpacer.isHidden = true
            } else {
                UIView.animate(withDuration: 0.2, animations: {
                    self.todayButton.alpha = 0
                }, completion: { _ in
                    self.todayButton.isHidden = true
                    self.todaySpacer.isHidden = true
                })
            }
        }
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
        let staggerEnabled = !UIAccessibility.isReduceMotionEnabled
        // 本批 4b：错峰不再只限月视图——周视图切周时新格子此前静默弹出，
        // 现与月视图同口径（0.25s、每格 0.03s 错峰、封顶 0.24s、curveEaseOut；
        // 复用格子仍不重播，见下方 isNewButton 分支）。
        // 6-5：快速连点翻页时先清掉在途错峰动画，再起新错峰，避免新旧格
        // 动画叠加残影（UIView 动画的模型值已是终值，清动画即落终值，
        // 复用格下方还会显式复位 alpha/transform）。
        for button in buttonByKey.values {
            button.layer.removeAllAnimations()
        }
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
                        button.bearyAddPressFeedback()
                        buttonByKey[day.key] = button
                    }
                    button.configure(day: day)
                    button.removeFromSuperview()
                    row.addArrangedSubview(button)
                    dayButtons.append(button)
                    if staggerEnabled && isNewButton && !weekKeys.contains(day.key) {
                        let delay = min(Double(staggerIndex) * 0.03, 0.24)
                        staggerIndex += 1
                        button.alpha = 0
                        button.transform = CGAffineTransform(translationX: 0, y: 6)
                        UIView.animate(withDuration: 0.25, delay: delay, options: .curveEaseOut, animations: {
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
    }

    @objc private func didTapToggle() {
        onToggleView?()
    }

    @objc private func didTapToday() {
        onGoToday?()
    }

    @objc private func didTapPrevious() {
        onPrevious?()
    }

    @objc private func didTapNext() {
        onNext?()
    }

    @objc private func didTapDay(_ sender: BearyCalendarDayButton) {
        guard let day = sender.dayValue else { return }
        // 5-22 第二道守卫：跨月占位格即使上层 isEnabled 漏算仍不可点，
        // 此处直接返回，不进 selectDay。
        guard !day.isOffMonth else { return }
        onSelectDay?(day)
    }
}

// MARK: - 时间线行（网页 .tl-card：边框 1 line、圆角 14、padding 12/14；正文 16.5/1.75）

final class BearyTimelineCell: UITableViewCell {
    static let reuseIdentifier = "BearyTimelineCell"

    private let cardView = UIView()
    /// 对称分割线式（2026-10-31 Li 点头预览后施工，取代 #254 卡片式与
    /// #251 非对称分割线）：cardView 只作内容列容器，不再有卡片外框
    /// （无边线、无阴影、无圆角、底色即页面底 bg）；行间分隔只靠底缘的
    /// dividerView 横线——左右留白各 36pt 对称：左起内容列左缘 36pt
    /// （竖线轨道留出，绝不碰竖线与圆点）、右沿屏边减 36pt。
    private let dividerView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        v.isUserInteractionEnabled = false
        return v
    }()
    /// 限时倒计时行（meta 行 pill 之后；仅存活期显示，灰字 12pt）。
    private let ephemeralLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = UIFont.systemFont(ofSize: 12)
        l.textColor = BearyColors.gray
        l.isHidden = true
        return l
    }()
    private lazy var ephemeralRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [ephemeralLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 3
        st.alignment = .center
        st.isHidden = true
        return st
    }()
    /// 限时虚线边框（首页同款：1.5pt dashed、line 色、圆角 16、内缩 8/6；
    /// 分割线式下限时篇只留此虚线框，不再有卡片实线边）。
    private let ephemeralBorderLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [4, 3]
        layer.strokeColor = BearyColors.line.cgColor
        layer.isHidden = true
        return layer
    }()
    private let metaStack = UIStackView()
    private let timeLabel = UILabel()
    /// 可见性图标（2026-10-29 改版：公开＝地球、私密＝锁；
    /// 2026-10-29 晚 pill 整个去掉：无背景、无描边、无内边距，只留图标本体，
    /// 固定灰 #8e8e93（v3 值），14pt，直接进 metaStack）。
    private let pillIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        return v
    }()
    private let weatherLabel = UILabel()
    /// E3：本行天气图标视图（configure 现建现存；复用/重配即清）与落点
    /// 天气 Lottie 覆盖层（仅 gotoEntry 落点行创建，其他行恒为 nil）。
    private var weatherIconView: UIImageView?
    private var weatherEmoteView: BearyEmoteView?
    private let moodLabel = UILabel()
    /// 2-1：本行天气/心情行视图（configure 现建现存；复用/重配即清），
    /// 供 layoutSubviews 在窄屏下隐藏天气/心情用（见该函数注释）。
    private var metaWeatherRow: UIView?
    private var metaMoodRow: UIView?
    private let recipientLabel = UILabel()
    private let contentLabel = UILabel()
    /// 审计 P2-12：时间线补标题行（卡片同款 16.5 粗体、单行截断，空标题不占位）。
    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.cardTitleFont()
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        lb.lineBreakMode = .byTruncatingTail
        lb.isHidden = true
        return lb
    }()
    private let thumbsScrollView = UIScrollView()
    private let thumbsStack = UIStackView()
    /// 批 E 补漏（2026-10-30 定位卡片 bug）：时间线卡片此前根本没有位置行，
    /// 批 E 只做了 BearyDiaryCardCell（首页/个人页）与详情，时间线漏网——
    /// 作者在时间线看自己带定位的日记时位置行恒不出现，与字段/脱敏无关。
    /// 本组与卡片同款：官方 icon_location 13 灰 + 13 灰文案，作者本人看自己
    /// 公开篇时下方再挂一行 12 橙色提示；文案与脱敏全走 BearyLocationDisplay。
    private let timelineLocationIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyLocationIcon.image(pointSize: 13)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()
    private let timelineLocationLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        lb.lineBreakMode = .byTruncatingTail
        return lb
    }()
    private let timelineLocationNoteLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.orange
        lb.numberOfLines = 0
        lb.isHidden = true
        return lb
    }()
    private lazy var timelineLocationLineRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [timelineLocationIconView, timelineLocationLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 4
        st.alignment = .center
        return st
    }()
    private lazy var timelineLocationStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [timelineLocationLineRow, timelineLocationNoteLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.spacing = 2
        st.isHidden = true
        return st
    }()
    private let footStack = UIStackView()
    private var thumbsHeightConstraint: NSLayoutConstraint?
    private weak var cardStackReference: UIStackView?
    private var thumbImageViews: [UIImageView] = []

    // TL-1 竖线 + 圆点：线 x=11 宽 2（与 .tl:before 一致）；圆点中心 x=12 与线对齐，
    // 9pt 空心圆（configure 统一口径：公开橙边／私密蓝边，2.5pt 边、bg 填充）。
    // 第 14 项 B + 2026-10-31 Li 定（同日竖线不要断）：竖线按日通长连续
    // （网页 .tl:before 口径：每个日期组容器一条线，组头 .date-h 在组外、线不穿头）。
    // 原生无组容器，改为按行拼线：首行 top 0（线顶抵 cell 顶缘）、末行
    // bottom -8、中间行 top/bottom 均为 0——相邻行的线在 cell 交界处恰好
    // 相接，同日各篇之间连续贯通、不按行分段留缺口；末行 -8 只停在组头之前，
    // 跨日组间断开是分组本身（组头处不穿头），不是同日断线。
    // 边距由 VC 在 cellForRowAt 按行在组内的位置设定（setTimelineLineEdges），
    // 分页向同组追加行时旧末行由 updateChrome 的可见行重刷改回中间行边距。
    private let timelineLineView = UIView()
    private var timelineLineTopConstraint: NSLayoutConstraint?
    private var timelineLineBottomConstraint: NSLayoutConstraint?
    private let dotRingView = UIView()
    private let dotView = UIView()
    private var dotSizeConstraint: NSLayoutConstraint?
    private var dotRingSizeConstraint: NSLayoutConstraint?
    private var dotTopConstraint: NSLayoutConstraint?
    /// 底部足行小熊回应图标视图（configure 现建现存；复用/重配即清），
    /// 供 traitCollectionDidChange 在深浅切换时重刷深浅版 hug 图。
    private var emoteIconView: UIImageView?
    // TL-3 引用卡与私密操作行。
    private let quoteButton = UIButton(type: .custom)
    // B-G1: left 3px line (web .tl-qcard border-left; full border removed).
    private let quoteLeftLineView = UIView()
    private let quoteIconView = UIImageView()
    private let quoteTitleLabel = UILabel()
    private let quoteBodyLabel = UILabel()
    private let quoteThumbsStack = UIStackView()
    // 6A：引用缩略图横向滚动容器（主图条 thumbsScrollView 同款口径）；
    // 原先 stack 直接进 quoteStack、无滚动，多图溢出卡宽后滑不动。
    private let quoteThumbsScrollView = UIScrollView()
    private var quoteThumbImageViews: [UIImageView] = []
    private var currentEntry: Entry?
    var onEditEntry: ((Entry) -> Void)?
    var onDeleteEntry: ((Entry) -> Void)?
    var onQuoteEntry: ((String) -> Void)?
    /// N7 时间线图片灯箱：主图条点按回调（keys=本条过滤后图 key，index=点按位置），
    /// VC 侧复用独立文件内的 BearyEntryImageViewerViewController 全屏弹出；
    /// 引用卡小图不走此路（点按引用卡仍走 onQuoteEntry 打开被引用日记）。
    var onTapImages: (([String], Int) -> Void)?
    private let actsStack = UIStackView()
    private let editStatusLabel = UILabel()
    /// 2026-10-29 Li 定编辑态口径：无图标、只留文字；可编辑期内左侧为倒计时灰字 +
    /// 可点按的“编辑”二字（本行唯一的编辑入口，旧图标编辑钮已摘）；到期 live 翻转时
    /// 同位置变“编辑已结束”，3 秒后淡出消失；首渲染已过期则直接不留。
    private let editStatusGroup = UIStackView()
    private let editTextButton = BearyHit44Button(type: .custom)
    private var editRowSawEditable = false
    private var editRowEndedShown = false
    private var editRowEndTimer: Timer?
    // 时间线卡片 ⋯ 菜单钮（2026-10-29 改版）：卡片顶行右端（meta 行末），
    // 官方 icon_more 横向三点 21pt 灰色，44pt 热区由 BearyHit44Button 的 28 帧扩后保证；
    // 点开菜单：编辑内容／修改权限／删除（原 meta 行末地球切换钮与右下角删除钮均已摘除，
    // 可见性切换走菜单“修改权限”，删除走菜单“删除”，回调与原按钮同一路）。
    private let moreButton = BearyHit44Button(type: .custom)
    var onMoreEntry: ((Entry, UIView) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg

        cardView.translatesAutoresizingMaskIntoConstraints = false
        // 2026-10-31 对称分割线式：#254 卡片外框整组去掉——无边线、无阴影、
        // 无圆角，底色即页面底（bg），行间分隔只靠底缘的 dividerView 横线
        // （线宽 2pt、线色 BearyColors.line 动态色，浅 #dbdbdb／深 #3a3a40，
        // 深浅切换自动跟随，无需手动重刷）。
        // 限时虚线边框层（ephemeralBorderLayer）是独立语义指示，不动。
        cardView.backgroundColor = BearyColors.bg
        cardView.layer.borderWidth = 0
        cardView.layer.cornerRadius = 0
        cardView.layer.masksToBounds = true
        // 限时虚线边框层（存活期显；布局时重画路径，见 layoutSubviews）。
        cardView.layer.addSublayer(ephemeralBorderLayer)

        // 8-3：meta 时间（正文类）走 scaledFont + adjusts。
        timeLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = BearyColors.gray
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 6A pill 左 packed：时间横向抗拉伸同样提到 required，否则时间会吸 slack。
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // 2026-10-29 晚：可见性 pill 整个去掉——无背景、无描边、无内边距，
        // 只留锁／地球图标本体（14pt，固定灰 #8e8e93，configure 按态写图＋灰 tint）；
        // 图标直接进 metaStack（configure 处），不再经包装视图。
        NSLayoutConstraint.activate([
            pillIconView.widthAnchor.constraint(equalToConstant: 14),
            pillIconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        // 8-3：天气/心情（正文类）走 scaledFont + adjusts。
        weatherLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        weatherLabel.adjustsFontForContentSizeCategory = true
        weatherLabel.textColor = BearyColors.gray
        // 2026-10-28 Li 定：天气/心情文字一律单行（多行换行会把两字词挤成竖排，
        // 如“心动”上下排）；空间不足时由写给（单行截断）承接挤压，时间与 pill 不动。
        weatherLabel.numberOfLines = 1
        weatherLabel.lineBreakMode = .byTruncatingTail
        weatherLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        moodLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        moodLabel.adjustsFontForContentSizeCategory = true
        moodLabel.textColor = BearyColors.gray
        moodLabel.numberOfLines = 1
        moodLabel.lineBreakMode = .byTruncatingTail
        moodLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        recipientLabel.font = UIFont.boldSystemFont(ofSize: 12.5)
        recipientLabel.textColor = BearyColors.orange
        // B-G12 (web .tl-to): max-width 170 + single-line ellipsis, never wrap.
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
        contentLabel.font = BearyDynamicType.diaryBodyFont()
        contentLabel.adjustsFontForContentSizeCategory = true
        contentLabel.textColor = BearyColors.ink
        contentLabel.numberOfLines = 0
        contentLabel.lineBreakMode = .byCharWrapping
        contentLabel.attributedText = nil

        thumbsScrollView.translatesAutoresizingMaskIntoConstraints = false
        thumbsScrollView.showsHorizontalScrollIndicator = false
        thumbsStack.translatesAutoresizingMaskIntoConstraints = false
        thumbsStack.axis = .horizontal
        // 主图条：网页 tl-item grabrow / 广场卡口径——216 高、间距 8、圆角 12、
        // 按宽高比定宽（见 configure 内 timelineStripWidth），不再是 74 方块。
        thumbsStack.spacing = 8
        thumbsScrollView.addSubview(thumbsStack)
        NSLayoutConstraint.activate([
            thumbsStack.topAnchor.constraint(equalTo: thumbsScrollView.topAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: thumbsScrollView.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: thumbsScrollView.trailingAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: thumbsScrollView.bottomAnchor),
            thumbsStack.heightAnchor.constraint(equalToConstant: 216),
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
        // 2026-10-29 B 方案：引用卡底色同步回 #183 之前的值（faint）；
        // v3 引用卡值（浅 #f2f2f7／深 #1c1c1e）距 faint（浅 #f5f5f5／深 #141414）仅 Δ≤10，
        // faint 即最接近的既有 token，故沿用，不另起精确值。
        quoteButton.backgroundColor = BearyColors.faint
        // B-G1: web .tl-qcard has no full border, only left 3px line + radius 8.
        quoteButton.layer.borderWidth = 0
        quoteButton.layer.cornerRadius = 8
        quoteButton.layer.masksToBounds = true
        quoteLeftLineView.translatesAutoresizingMaskIntoConstraints = false
        quoteLeftLineView.backgroundColor = BearyColors.line
        quoteButton.contentHorizontalAlignment = .left
        quoteButton.addTarget(self, action: #selector(quoteTapped), for: .touchUpInside)
        quoteButton.bearyAddPressFeedback()
        quoteIconView.translatesAutoresizingMaskIntoConstraints = false
        quoteIconView.tintColor = BearyColors.gray
        quoteTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        // 8-3 例外：引用标题 11.5 属装饰性小字（同 pill 11.5 口径），不缩放。
        quoteTitleLabel.font = UIFont.systemFont(ofSize: 11.5)
        quoteTitleLabel.textColor = BearyColors.gray
        quoteBodyLabel.translatesAutoresizingMaskIntoConstraints = false
        // B-G1: web .tl-qt 13.5/1.6, clamped to 2 lines.
        // 8-3：引用正文（正文类）走 scaledFont（富文本侧见 configure 内同款）。
        quoteBodyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5))
        quoteBodyLabel.adjustsFontForContentSizeCategory = true
        quoteBodyLabel.textColor = BearyColors.ink
        quoteBodyLabel.numberOfLines = 2
        quoteBodyLabel.lineBreakMode = .byTruncatingTail
        let quoteTitleRow = UIStackView(arrangedSubviews: [quoteIconView, quoteTitleLabel])
        quoteTitleRow.translatesAutoresizingMaskIntoConstraints = false
        quoteTitleRow.axis = .horizontal
        quoteTitleRow.spacing = 5
        quoteTitleRow.alignment = .center
        // F2：引用缩略图行（网页 tl-qcard 内 .quote-thumbs 口径）：无图时隐藏不占位。
        // 6A：stack 包进横向滚动条（主图条同款：四边钉 scroll、间距 5、42px 图不变）；
        // 显隐改由 scroll 承担，stack 本身不再藏（藏了 scroll 后 stack 藏不藏都不显示）。
        quoteThumbsStack.translatesAutoresizingMaskIntoConstraints = false
        quoteThumbsStack.axis = .horizontal
        quoteThumbsStack.spacing = 5
        quoteThumbsScrollView.translatesAutoresizingMaskIntoConstraints = false
        quoteThumbsScrollView.showsHorizontalScrollIndicator = false
        quoteThumbsScrollView.isHidden = true
        quoteThumbsScrollView.addSubview(quoteThumbsStack)
        NSLayoutConstraint.activate([
            quoteThumbsStack.topAnchor.constraint(equalTo: quoteThumbsScrollView.topAnchor),
            quoteThumbsStack.leadingAnchor.constraint(equalTo: quoteThumbsScrollView.leadingAnchor),
            quoteThumbsStack.trailingAnchor.constraint(equalTo: quoteThumbsScrollView.trailingAnchor),
            quoteThumbsStack.bottomAnchor.constraint(equalTo: quoteThumbsScrollView.bottomAnchor),
            quoteThumbsScrollView.heightAnchor.constraint(equalToConstant: 42),
        ])
        let quoteStack = UIStackView(arrangedSubviews: [quoteTitleRow, quoteBodyLabel, quoteThumbsScrollView])
        quoteStack.translatesAutoresizingMaskIntoConstraints = false
        quoteStack.axis = .vertical
        quoteStack.spacing = 4
        quoteButton.addSubview(quoteStack)
        NSLayoutConstraint.activate([
            quoteIconView.widthAnchor.constraint(equalToConstant: 12),
            quoteIconView.heightAnchor.constraint(equalToConstant: 12),
            quoteStack.topAnchor.constraint(equalTo: quoteButton.topAnchor, constant: 9),
            quoteStack.leadingAnchor.constraint(equalTo: quoteButton.leadingAnchor, constant: 12),
            quoteStack.trailingAnchor.constraint(equalTo: quoteButton.trailingAnchor, constant: -12),
            quoteStack.bottomAnchor.constraint(equalTo: quoteButton.bottomAnchor, constant: -9),
        ])
        quoteButton.addSubview(quoteLeftLineView)
        NSLayoutConstraint.activate([
            quoteLeftLineView.leadingAnchor.constraint(equalTo: quoteButton.leadingAnchor),
            quoteLeftLineView.topAnchor.constraint(equalTo: quoteButton.topAnchor),
            quoteLeftLineView.bottomAnchor.constraint(equalTo: quoteButton.bottomAnchor),
            quoteLeftLineView.widthAnchor.constraint(equalToConstant: 3),
        ])

        // 8-3：私密操作行状态文案（正文类）走 scaledFont + adjusts。
        editStatusLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        editStatusLabel.adjustsFontForContentSizeCategory = true
        editStatusLabel.textColor = BearyColors.gray
        // 2026-10-29 编辑态口径：倒计时灰字 + 可点按的“编辑”二字（12pt 灰字按钮，
        // BearyHit44Button 扩后热区 44；点按即进编辑器，与旧图标编辑钮同一回调）。
        editTextButton.translatesAutoresizingMaskIntoConstraints = false
        editTextButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        editTextButton.setTitle("编辑", for: .normal)
        editTextButton.setTitleColor(BearyColors.gray, for: .normal)
        editTextButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        editTextButton.bearyAddPressFeedback()
        editTextButton.isHidden = true
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        // 2026-10-29 改版：⋯ 菜单钮接替原 meta 行末地球钮的位置，
        // 21pt 灰色图标、28×28 帧（BearyHit44Button 扩后热区仍 44）。
        if let moreImage = BearyIconImages.image(named: "icon_more", pointSize: 21) {
            moreButton.setImage(moreImage, for: .normal)
        }
        moreButton.tintColor = BearyColors.gray
        moreButton.imageView?.contentMode = .scaleAspectFit
        moreButton.accessibilityLabel = "更多操作"
        moreButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        moreButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        moreButton.bearyAddPressFeedback()
        actsStack.translatesAutoresizingMaskIntoConstraints = false
        actsStack.axis = .horizontal
        actsStack.spacing = 14
        actsStack.alignment = .center
        let actsSpacer = UIView()
        // 2026-10-29 改版：操作行只剩编辑态文字组（旧图标编辑钮已摘，编辑只走
        // 文字“编辑”）；删除钮已摘除，删除收进卡片右上角 ⋯ 菜单。
        editStatusGroup.axis = .horizontal
        editStatusGroup.spacing = 8
        editStatusGroup.alignment = .center
        editStatusGroup.addArrangedSubview(editStatusLabel)
        editStatusGroup.addArrangedSubview(editTextButton)
        actsStack.addArrangedSubview(editStatusGroup)
        actsStack.addArrangedSubview(actsSpacer)

        // 批 E 补漏：位置行落点 = 引用卡 → 位置行 → 足行（操作行一带），与卡片
        // “图片条之后、操作行之前”同序；图片条后的动态间距（configure 内按有图
        // 9 / 无图 0）现为图片条→位置行间距，位置行隐藏时栈自动塌掉不留空行。
        let cardStack = UIStackView(arrangedSubviews: [metaStack, titleLabel, contentLabel, quoteButton, thumbsScrollView, timelineLocationStack, footStack, actsStack])
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.axis = .vertical
        cardStack.spacing = 0
        cardStack.setCustomSpacing(6, after: metaStack)
        cardStack.setCustomSpacing(4, after: titleLabel)
        cardStack.setCustomSpacing(9, after: contentLabel)
        cardStack.setCustomSpacing(10, after: quoteButton)
        cardStack.setCustomSpacing(9, after: thumbsScrollView)
        cardStack.setCustomSpacing(9, after: timelineLocationStack)
        cardStack.setCustomSpacing(9, after: footStack)
        cardStackReference = cardStack
        cardView.addSubview(cardStack)
        contentView.addSubview(cardView)
        contentView.addSubview(dividerView)
        contentView.addSubview(timelineLineView)
        contentView.addSubview(dotRingView)
        contentView.addSubview(dotView)
        dotSizeConstraint = dotView.widthAnchor.constraint(equalToConstant: 14)
        dotRingSizeConstraint = dotRingView.widthAnchor.constraint(equalToConstant: 17)
        dotTopConstraint = dotView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        timelineLineTopConstraint = timelineLineView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 0)
        timelineLineBottomConstraint = timelineLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            timelineLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 11),
            timelineLineView.widthAnchor.constraint(equalToConstant: 2),
            dotRingView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            dotRingView.centerYAnchor.constraint(equalTo: dotView.centerYAnchor),
            dotView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
        ])
        // 可选约束逐条激活（不可直接放进 activate 数组，类型不匹配）。
        dotTopConstraint?.isActive = true
        timelineLineTopConstraint?.isActive = true
        timelineLineBottomConstraint?.isActive = true
        dotSizeConstraint?.isActive = true
        dotRingSizeConstraint?.isActive = true
        dotView.heightAnchor.constraint(equalTo: dotView.widthAnchor).isActive = true
        dotRingView.heightAnchor.constraint(equalTo: dotRingView.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            // 对称分割线式：内容列上下 6 / 8、左右 36 / 16 不动（现行时间线口径，
            // 内容到底线顶留白 = 栈底 14 + 列底 8 − 线高 2 = 20pt）；分割线钉 cell 底缘、
            // 只定左右与高，不参与行高计算（行高仍由内容列底缘 -8 定）。
            // 分割线左右留白各 36pt 对称：左 36 = 内容列左缘（竖线轨道留出，
            // 绝不碰竖线与圆点），右 -36（#251 右到屏边那支不再保留）；
            // 每行底缘都留线（含同日末行——组间分隔同样靠它，见预览 §2）。
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 2),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
        ])
        // 批 E 补漏：位置图标固定 13（详情同款），不靠图片固有尺寸撑行高。
        NSLayoutConstraint.activate([
            timelineLocationIconView.widthAnchor.constraint(equalToConstant: 13),
            timelineLocationIconView.heightAnchor.constraint(equalToConstant: 13),
        ])
        // 无图时把图片条高度约束压到 0（只靠 hidden 不够：显式高度约束仍会撑开 stack）。
        thumbsHeightConstraint = thumbsScrollView.heightAnchor.constraint(equalToConstant: 216)
        thumbsHeightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 2-1 降级（不折行）：metaStack 是单行横向 UIStackView，本身无换行
    /// 能力；改双行需按实测宽在布局时搬运天气/心情行，复用 + 旋转下
    /// 易震荡且本机无法验真机，故按简报降级为窄屏隐藏。窄屏判定用
    /// meta 实测宽 < 260（卡片左右各 16 内边距：320 屏 meta 约 236、
    /// 375 屏约 291，阈值卡在两者之间；iPad 600 居中列远高于阈值，
    /// 永不触发）。窄屏只藏天气/心情行，时间 + pill + 写给全保；
    /// 宽屏/旋转回宽时恢复显示。只改 isHidden（栈自动排除隐藏项），
    /// 不改约束、不碰滚动回调；isHidden 不变时不重复写，避免布局循环。
    override func layoutSubviews() {
        super.layoutSubviews()
        let metaWidth = metaStack.bounds.width
        guard metaWidth > 0 else { return }
        let narrow = metaWidth < 260
        if let weatherRow = metaWeatherRow, weatherRow.isHidden != narrow {
            weatherRow.isHidden = narrow
        }
        if let moodRow = metaMoodRow, moodRow.isHidden != narrow {
            moodRow.isHidden = narrow
        }
        // 限时虚线边框：首页同款（BearyDiaryCardCell 布局口径：宿主矩形内缩
        // dx 8 / dy 6、圆角 16；此处宿主是时间线内容列 cardView，框须裹住
        // 内容列、不得越过左侧时间线竖线/圆点区，故内缩落在 cardView 内，
        // 不改内容列本体布局；分割线式下限时篇只留此虚线框）。
        if !ephemeralBorderLayer.isHidden {
            ephemeralBorderLayer.frame = cardView.bounds
            ephemeralBorderLayer.path = UIBezierPath(roundedRect: cardView.bounds.insetBy(dx: 8, dy: 6), cornerRadius: 16).cgPath
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 对称分割线式：内容列底色与分割线均走动态色（bg / line），
        // 深浅切换自动跟随，无外框 chrome 可刷。
        // 限时虚线描边色是 cgColor 快照，主题切换须重刷。
        ephemeralBorderLayer.strokeColor = BearyColors.line.cgColor
        timelineLineView.backgroundColor = BearyColors.line
        dotRingView.backgroundColor = BearyColors.line
        // C1：私密圆点边框按当前 isPublic 重设（公开 bg、私密蓝），
        // 不得无条件写 bg（否则主题切换后私密蓝圈变隐形）。
        // N1：已公开圆点填充改橙色（与 configure 同口径），主题切换后仍是橙。
        if let entry = currentEntry {
            // 限时已到期按私密算（与 configure 同口径）。
            let published = BearyEphemeral.isEffectivelyPublic(entry)
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderColor = (published ? BearyColors.orange : BearyColors.blue).cgColor
        } else {
            dotView.layer.borderColor = BearyColors.bg.cgColor
        }
        quoteLeftLineView.backgroundColor = BearyColors.line
        // 2026-10-29 改版追加：深浅切换时小熊回应 hug 图重刷为对应深浅版。
        if let emoteView = emoteIconView {
            emoteView.image = BearyEmoteImages.image(for: "hug", dark: traitCollection.userInterfaceStyle == .dark)
        }
    }

    /// U14：行点按给内容列短暂 faint 底色（selectionStyle 已是 .none，
    /// 但 setHighlighted 仍由 tableView 在点按时调用；按钮上的点按不走此路）。
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        let apply = {
            // 分割线式：未高亮回页面底 bg（内容列无卡片底色）。
            self.cardView.backgroundColor = highlighted ? BearyColors.faint : BearyColors.bg
        }
        if animated {
            UIView.animate(withDuration: 0.15, animations: apply)
        } else {
            apply()
        }
    }

    /// E3：gotoEntry 落点行天气标播 Lottie（统一卡片同款口径，见
    /// BearyDiaryCardCell.playWeatherLottie：编辑器选择器同款
    /// BearyEmoteView + LottieWeather 资源，night→moon；深浅切换与减动效
    /// 静态帧由播放器内部处理）。仅落点控制器在定位落定后调用；其他行
    /// 从不调用，天气标保持静态图。覆盖层贴在 14px 天气图标上，停播摘层
    /// 即回到底层静态图。
    func playWeatherLottie() {
        guard let weatherKey = currentEntry?.weather, !weatherKey.isEmpty,
              let iconView = weatherIconView else { return }
        let lottieKey = weatherKey == "night" ? "moon" : weatherKey
        if let current = weatherEmoteView, current.emoteKey == lottieKey {
            current.play()
            return
        }
        stopWeatherLottie()
        let emoteView = BearyEmoteView(key: lottieKey, animated: true, fallbackImage: iconView.image)
        emoteView.isUserInteractionEnabled = false
        emoteView.translatesAutoresizingMaskIntoConstraints = false
        iconView.addSubview(emoteView)
        NSLayoutConstraint.activate([
            emoteView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            emoteView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor),
            emoteView.topAnchor.constraint(equalTo: iconView.topAnchor),
            emoteView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
        ])
        weatherEmoteView = emoteView
    }

    /// E3：停播落点天气 Lottie 并摘掉覆盖层。复用、重配、滑出可视区
    /// （播放器离窗自停 + 复用/重配摘层）与新落点盖掉旧落点时均走此路。
    func stopWeatherLottie() {
        weatherEmoteView?.stop()
        weatherEmoteView?.removeFromSuperview()
        weatherEmoteView = nil
    }

    /// 6A 定位高亮：内容列 faint 闪一下再回 bg（减动效下只滚动不闪）。
    /// 复用安全：prepareForReuse 已复位 bg；完成时再核对仍是同一篇才复位。
    func flashHighlight() {
        guard UIAccessibility.isReduceMotionEnabled == false else { return }
        let flashedId = currentEntry?.id
        cardView.backgroundColor = BearyColors.faint
        UIView.animate(withDuration: 0.6, delay: 0.5, options: [], animations: {
            self.cardView.backgroundColor = BearyColors.bg
        }, completion: { _ in
            if self.currentEntry?.id == flashedId {
                self.cardView.backgroundColor = BearyColors.bg
            }
        })
    }

    /// 第 14 项 B + 2026-10-31 Li 定（同日竖线不要断）：按行在日组内的位置
    /// 定竖线边距，同日各篇之间竖线连续贯通——首行 top 0（线顶抵 cell 顶缘，
    /// 组头与首行之间不留缺口）、中间行 top/bottom 均为 0（相邻行的线在
    /// cell 交界处恰好相接）、末行 bottom -8（线停在组头之前，跨日组间
    /// 断开是分组本身、组头处不穿头，不是同日断线）；单行组 top 0、bottom -8。
    /// VC 在 cellForRowAt 设定，复用前 prepareForReuse 复位为 0/-8，
    /// 防中间行状态漏到单行组；分页追加时 updateChrome 重刷可见行边距，
    /// 旧末行改回中间行 0/0，组内恢复通长。
    /// isFirstInDay 保留供调用方语义（顶边现已恒为 0，不再按首行区分）。
    func setTimelineLineEdges(isFirstInDay: Bool, isLastInDay: Bool) {
        timelineLineTopConstraint?.constant = 0
        timelineLineBottomConstraint?.constant = isLastInDay ? -8 : 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopWeatherLottie()
        weatherIconView = nil
        // 80 包 A4/A2-3④：错峰改 cell.alpha/transform，对称复位，防复用残留。
        alpha = 1
        transform = .identity
        // 按压缩放残留复位：通用按压反馈把按钮 imageView 缩到 .84，
        // 触摸序列异常打断时回弹没跑到，复用会把 .84 带到下一行。
        editTextButton.imageView?.transform = .identity
        // 2026-10-29 编辑态复位：live 翻转计时与“已结束”态不得串位到下一行。
        editRowEndTimer?.invalidate()
        editRowEndTimer = nil
        editRowSawEditable = false
        editRowEndedShown = false
        editStatusGroup.alpha = 1
        editStatusGroup.accessibilityElementsHidden = false
        editTextButton.isHidden = true
        editTextButton.alpha = 1
        editTextButton.isEnabled = true
        setTimelineLineEdges(isFirstInDay: true, isLastInDay: true)
        currentEntry = nil
        titleLabel.text = nil
        titleLabel.isHidden = true
        // 批 E 补漏：位置行复用复位，防上一行位置串到下一行无定位日记（#252 口径保留）。
        timelineLocationStack.isHidden = true
        timelineLocationLabel.text = nil
        timelineLocationNoteLabel.text = nil
        timelineLocationNoteLabel.isHidden = true
        // 对称分割线式复位：内容列回页面底 bg、无实线边（限时态只走虚线层）；
        // 分割线是静态约束 + 动态线色，无需复位。
        cardView.backgroundColor = BearyColors.bg
        cardView.layer.borderWidth = 0
        quoteButton.isHidden = true
        pillIconView.image = nil
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
        emoteIconView = nil
        for arranged in metaStack.arrangedSubviews {
            metaStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        metaWeatherRow = nil
        metaMoodRow = nil
    }

    /// 批 E 补漏：时间线位置行刷新，卡片 refreshLocationRow 同款口径
    /// （display 返回 nil 时整组隐藏，不留空行；note 仅作者本人公开篇）。
    private func refreshTimelineLocationRow(entry: Entry) {
        guard let display = BearyLocationDisplay.display(entry: entry) else {
            timelineLocationStack.isHidden = true
            timelineLocationLabel.text = nil
            timelineLocationNoteLabel.text = nil
            timelineLocationNoteLabel.isHidden = true
            return
        }
        timelineLocationStack.isHidden = false
        timelineLocationLabel.text = display.line
        if let note = display.note {
            timelineLocationNoteLabel.text = note
            timelineLocationNoteLabel.isHidden = false
        } else {
            timelineLocationNoteLabel.text = nil
            timelineLocationNoteLabel.isHidden = true
        }
    }

    /// 主图条定宽：广场卡 stripWidth 同口径（网页 stripW）——0.55–2.22 倍高夹取，
    /// 无尺寸老图默认 280。仅时间线主图条用；引用卡 74 小图不走此路。
    private func timelineStripWidth(forKey key: String, dims: [String: [Int]]?, height: CGFloat) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = height * CGFloat(d[0]) / CGFloat(d[1])
            let low = height * 0.55
            let high = height * 2.22
            return round(max(low, min(high, raw)))
        }
        return 280
    }

    func configure(entry: Entry) {
        stopWeatherLottie()
        weatherIconView = nil
        metaWeatherRow = nil
        metaMoodRow = nil
        currentEntry = entry
        for arranged in metaStack.arrangedSubviews {
            metaStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        if let createdMs = entry.createdAt {
            let date = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
            // G8：行内时间走北京时区，与服务端日界一致（静态 formatter 同口径）。
            timeLabel.text = Self.timelineTimeFormatter.string(from: date)
        } else {
            timeLabel.text = ""
        }
        metaStack.addArrangedSubview(timeLabel)
        // 限时已到期按私密算（图标/圆点/⋯ 菜单一律走有效态，不只看服务端 isPublic）。
        let published = BearyEphemeral.isEffectivelyPublic(entry)
        if published {
            // 2026-10-29 晚：pill 已整个去掉，只留图标本体——公开＝地球，固定灰 #8e8e93（v3 值）；
            // 圆点口径不动（公开橙边见下）。
            // 109：限时存活期只换图标为官方 icon_limited（熊头 + 虚线环，
            // 与顶栏限时态同款，#272 误删后本支从 2bb7df9^ 原样恢复；
            // 纠正：不要 icon_clock；尺寸/灰色与公开/私密同款）；
            // 圆点仍走公开橙边、虚线框与倒计时行一字不动；到期后 isLive 为假、
            // isEffectivelyPublic 回私密，走下方锁分支，图标自动回锁。
            pillIconView.image = BearyIconImages.image(named: BearyEphemeral.isLive(entry) ? "icon_limited" : "icon_globe", pointSize: 14)
            pillIconView.tintColor = BearyColors.timelineIconGray
            // 竖线圆点统一用私密的尺寸和结构（9pt 空心 + 12pt 环），只变颜色：
            // 已公开橙边、私密蓝边（2026-10-28 Li 定，覆盖 #125 的已公开几何口径）。
            dotSizeConstraint?.constant = 9
            dotRingSizeConstraint?.constant = 12
            dotTopConstraint?.constant = 14.5
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderWidth = 2.5
            dotView.layer.borderColor = BearyColors.orange.cgColor
            dotView.layer.cornerRadius = 4.5
            dotRingView.isHidden = true
        } else {
            // 2026-10-29 晚：pill 已整个去掉，只留图标本体——私密＝锁，固定灰 #8e8e93（v3 值）；
            // 圆点口径不动（私密蓝边见下）。
            pillIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 14)
            pillIconView.tintColor = BearyColors.timelineIconGray
            // 私密圆点即统一口径（9pt 空心 + 12pt 环，蓝边）；已公开只换边色为橙。
            dotSizeConstraint?.constant = 9
            dotRingSizeConstraint?.constant = 12
            dotTopConstraint?.constant = 14.5
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderWidth = 2.5
            dotView.layer.borderColor = BearyColors.blue.cgColor
            dotView.layer.cornerRadius = 4.5
            dotRingView.isHidden = true
        }
        metaStack.addArrangedSubview(pillIconView)
        // 限时存活期：meta 行追加灰字倒计时（只留这一行，不另加标签）+ 卡片改虚线边框；
        // 到期或非限时按普通卡（pill/dot 已按有效态走私密分支）。
        if BearyEphemeral.isLive(entry), let until = entry.ephemeralUntil {
            ephemeralLabel.text = BearyEphemeral.remainingText(until: until)
            ephemeralRow.isHidden = false
            metaStack.addArrangedSubview(ephemeralRow)
        } else {
            ephemeralRow.isHidden = true
        }
        let ephemeralLive = BearyEphemeral.isLive(entry)
        // 对称分割线式：内容列无实线边；虚线层仍按存活期显隐（限时篇只留虚线框）。
        cardView.layer.borderWidth = 0
        ephemeralBorderLayer.isHidden = !ephemeralLive
        // I3：天气用 icon_wx_* 图标、心情用 14px BearyEmoteView（播 Lottie 循环，
        // 与 Feed/主页心情位静态首帧不同，时间线卡片心情是动的；减动效下只显完成帧）。
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
                self.weatherIconView = weatherIconView
                weatherRowItems.append(weatherIconView)
            }
            weatherRowItems.append(weatherLabel)
            let weatherRow = UIStackView(arrangedSubviews: weatherRowItems)
            weatherRow.axis = .horizontal
            weatherRow.spacing = 3
            weatherRow.alignment = .center
            weatherRow.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            // 6A pill 左 packed：天气行横向抗拉伸提到 required，不吸 slack。
            weatherRow.setContentHuggingPriority(.required, for: .horizontal)
            metaWeatherRow = weatherRow
            metaStack.addArrangedSubview(weatherRow)
        }
        if let moodKey = entry.mood, let moodName = BearyText.moodNames[moodKey] {
            moodLabel.text = moodName
            let emoteView = BearyEmoteView(key: moodKey, animated: true)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                emoteView.widthAnchor.constraint(equalToConstant: 14),
                emoteView.heightAnchor.constraint(equalToConstant: 14),
            ])
            let moodRow = UIStackView(arrangedSubviews: [emoteView, moodLabel])
            moodRow.axis = .horizontal
            moodRow.spacing = 3
            moodRow.alignment = .center
            moodRow.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            // 6A pill 左 packed：心情行横向抗拉伸提到 required，不吸 slack。
            moodRow.setContentHuggingPriority(.required, for: .horizontal)
            metaMoodRow = moodRow
            metaStack.addArrangedSubview(moodRow)
        }
        if let mentionedName = entry.mentionedName, !mentionedName.isEmpty {
            recipientLabel.text = "@\(mentionedName)"
            metaStack.addArrangedSubview(recipientLabel)
        }
        // 6A pill 左 packed：行末 defaultLow 吸宽 spacer（足行 footSpacer 同款口径），
        // 是 meta 行唯一低抗拉伸项，独吞全部 slack，整行左 packed、pill 永远紧贴时间。
        // configure 开头与 prepareForReuse 的全清循环会一并移除，不叠加。
        let metaSpacer = UIView()
        metaSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaStack.addArrangedSubview(metaSpacer)
        // 2026-10-29 改版：⋯ 菜单钮在卡片顶行右端——meta 行末 spacer 之后追加，
        // 即顶到右端（原地球钮已摘除，位置由 ⋯ 接替；时间线行均为本人行，菜单常驻）。
        metaStack.addArrangedSubview(moreButton)
        // 8-13 保留 1.75（不统一 1.6）：网页版时间线正文 .tl-text 即
        // 16.5px/1.75（worker.js 前端快照 :435，2026-10-27 版，与本行
        // 16.5/1.75 同值；首页卡片 1.6 是另一口径，不混用）。
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.75
        paragraph.lineBreakMode = .byCharWrapping
        let body = entry.content ?? ""
        // 审计 P2-12：标题行（卡片同款，空标题不占位；stack 里隐藏行不占高）。
        let trimmedTitle = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.text = trimmedTitle.isEmpty ? nil : trimmedTitle
        titleLabel.isHidden = trimmedTitle.isEmpty
        contentLabel.attributedText = NSAttributedString(string: body, attributes: [
            .font: BearyDynamicType.diaryBodyFont(),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ])
        // TL-3 引用卡（网页 tlQuoteHtml 口径）：引用日记在时间线里必须有痕迹，
        // 卡内附 42px 引用缩略图行（见下方 F2 分支），无图不占位。
        // B-G2 (privacy, server fields first): Quote.gone/locked ARE decoded
        // (BearyAPI.swift); read them before any heuristic - gone -> deleted state,
        // locked -> locked state, neither leaks body/images, neither is tappable.
        // Missing fields fall back to the old heuristic. A visibility gate also applies:
        // a non-public quote on someone else's entry never shows body, even if the
        // server passed body through (fail-closed, see below).
        // quoteId 有而 quote 体缺失 → 已删除；quote 体无正文且未公开 → 未公开占位。
        // 引用缩略图见下方 F2 分支（仅有正文的公开/自己的引用才配图）。
        quoteButton.isHidden = true
        quoteBodyLabel.isHidden = false
        clearQuoteThumbs()
        quoteButton.isEnabled = true
        if entry.quote == nil, entry.quoteId != nil {
            quoteTitleLabel.text = "引用的日记已删除"
            quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 12)
            quoteBodyLabel.isHidden = true
            quoteButton.isEnabled = false
            quoteButton.isHidden = false
        } else if let quote = entry.quote {
            // B-G2 decision order (web tlQuoteHtml order: gone -> locked -> visibility):
            // non-empty server fields win; missing fields fall back to old heuristic.
            let quoteBody = (quote.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if quote.gone == true {
                quoteTitleLabel.text = "引用的日记已删除"
                quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 12)
                quoteBodyLabel.isHidden = true
                quoteButton.isEnabled = false
                quoteButton.isHidden = false
            } else if quote.locked == true {
                quoteTitleLabel.text = "该日记已设为私密"
                quoteIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 12)
                quoteBodyLabel.isHidden = true
                quoteButton.isEnabled = false
                quoteButton.isHidden = false
            } else if quoteBody.isEmpty {
                if quote.isPublic == true {
                    quoteTitleLabel.text = "引用的日记已删除"
                    quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 12)
                } else {
                    quoteTitleLabel.text = "该日记已设为私密"
                    quoteIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 12)
                }
                quoteBodyLabel.isHidden = true
                quoteButton.isEnabled = false
                quoteButton.isHidden = false
            } else if quote.isPublic != true && !(quote.isMine == true || (quote.authorId != nil && quote.authorId == SessionManager.shared.currentUser?.id)) {
                // iCity viewer 实时判定：被引篇非公开且 viewer 不是被引作者时，
                // 即使服务端透传了正文也以占位替代，绝不泄漏正文与图片
                //（旧口径以宿主是否本人为代理，已作废；Quote 现有 authorId/isMine 字段）。
                quoteTitleLabel.text = "该日记已设为私密"
                quoteIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 12)
                quoteBodyLabel.isHidden = true
                quoteButton.isEnabled = false
                quoteButton.isHidden = false
            } else {
                if let createdMs = quote.createdAt {
                    let date = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)
                    // G8：引用日期走北京时区（静态 formatter 同口径）。
                    quoteTitleLabel.text = "引用 · " + Self.timelineQuoteDateFormatter.string(from: date) + "的日记"
                } else {
                    quoteTitleLabel.text = "引用"
                }
                // B-G1: web .tl-qt 13.5/1.6, clamped to 2 lines (count set in init).
                let quoteParagraph = NSMutableParagraphStyle()
                quoteParagraph.lineHeightMultiple = 1.6
                quoteParagraph.lineBreakMode = .byTruncatingTail
                quoteBodyLabel.attributedText = NSAttributedString(string: quoteBody, attributes: [
                    .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5)),
                    .foregroundColor: BearyColors.ink,
                    .paragraphStyle: quoteParagraph,
                ])
                quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 12)
                // F2：引用卡内补一行 42px 小缩略图（网页 tl-qcard 内 .quote-thumbs 口径）；
                // 仅公开引用或 viewer 是被引作者时才配图，无图不占位。
                if quote.isPublic == true || quote.isMine == true || (quote.authorId != nil && quote.authorId == SessionManager.shared.currentUser?.id) {
                    let quoteKeys = (quote.images ?? []).filter { !$0.isEmpty }
                    for key in quoteKeys {
                        let imageView = UIImageView()
                        imageView.translatesAutoresizingMaskIntoConstraints = false
                        imageView.contentMode = .scaleAspectFill
                        imageView.clipsToBounds = true
                        imageView.layer.cornerRadius = 7
                        imageView.backgroundColor = BearyColors.faint
                        quoteThumbsStack.addArrangedSubview(imageView)
                        NSLayoutConstraint.activate([
                            imageView.widthAnchor.constraint(equalToConstant: 42),
                            imageView.heightAnchor.constraint(equalToConstant: 42),
                        ])
                        quoteThumbImageViews.append(imageView)
                        if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                            imageView.bearySetImage(url: url, downsampleToWidth: 42 * UIScreen.main.scale)
                        }
                    }
                    quoteThumbsScrollView.isHidden = quoteKeys.isEmpty
                }
                quoteButton.isHidden = false
            }
        }
        let imageKeys = (entry.images ?? []).filter { !$0.isEmpty }
        thumbsScrollView.isHidden = imageKeys.isEmpty
        thumbsHeightConstraint?.constant = imageKeys.isEmpty ? 0 : 216
        cardStackReference?.setCustomSpacing(imageKeys.isEmpty ? 0 : 9, after: thumbsScrollView)
        for (thumbIndex, key) in imageKeys.enumerated() {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.backgroundColor = BearyColors.faint
            // N7：主图条点按接灯箱（UIImageView 默认不接收触摸，必须显式开启；
            // 手势会截获此次点按，行点按进详情不再触发）。tag 记下标，
            // didTapThumb 再从 currentEntry 重算 keys（与本循环同一过滤口径）。
            imageView.isUserInteractionEnabled = true
            imageView.tag = thumbIndex
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapThumb(_:))))
            thumbsStack.addArrangedSubview(imageView)
            // 216 图片条：宽按原图宽高比定（广场 stripWidth 同口径），高固定 216。
            let strip = timelineStripWidth(forKey: key, dims: entry.imgDims, height: 216)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: strip),
                imageView.heightAnchor.constraint(equalToConstant: 216),
            ])
            thumbImageViews.append(imageView)
            // 审计 P2-14：主图条补广场同款失败重试钮（居中 28pt 圆盘，失败时亮；
            // 复用时 imageView 连同重试钮一并移除，无残留）。
            let thumbRetry = bearyFeedRetryButton(target: self, action: #selector(timelineThumbRetryTapped(_:)))
            imageView.addSubview(thumbRetry)
            NSLayoutConstraint.activate([
                thumbRetry.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                thumbRetry.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                thumbRetry.widthAnchor.constraint(equalToConstant: 28),
                thumbRetry.heightAnchor.constraint(equalToConstant: 28),
            ])
            if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                bearyFeedLoadImage(into: imageView, url: url, retryButton: thumbRetry, downsampleToWidth: strip * UIScreen.main.scale)
            }
        }
        // 批 E 补漏：位置行（引用卡 → 位置行 → 足行）；无位置、或他人视角下
        // 无区级时整组隐藏，不留空行（文案与脱敏走 BearyLocationDisplay，
        // 与首页/个人页卡片、详情同一函数，时间线本只列本人日记，故实效为
        // 私密精确、公开精确 + 橙色提示两态，他人态由 display 兜底）。
        refreshTimelineLocationRow(entry: entry)
        footStack.isHidden = true
        actsStack.isHidden = true
        // 与 metaStack 在 configure 开头先清后加一致：foot 行只靠
        // prepareForReuse 清理时，configure 重跑会把足行与 spacer 叠加。
        for arranged in footStack.arrangedSubviews {
            footStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        emoteIconView = nil
        if published {
            // 2026-10-29 改版：足行三项按数量显隐——任一项为 0 就不显示该图标与数字，
            // 三项全 0 时整行塌掉（footStack 保持隐藏，cardStack 间距自然承接，不留空行）。
            var footItems: [UIView] = []
            let likeCount = entry.likeCount ?? 0
            if likeCount > 0 {
                // 2026-10-29 Li 定（第 5 项）：自己点过赞的日记，卡片下方爱心
                // 须按已点赞态上色——此前足行只按计数渲染、一律空心灰，
                // likedByMe 被忽略；本人日记自点赞同样计入，不得特殊处理成空心。
                // 纯展示不动：仍无互动入口，只改颜色态。
                let liked = entry.likedByMe ?? false
                footItems.append(footItem(iconName: liked ? "icon_heart_fill" : "icon_heart", text: "\(likeCount)", highlighted: liked))
            }
            var emoteTotal = 0
            for emote in entry.emotes ?? [] {
                emoteTotal += emote.count ?? 0
            }
            if emoteTotal > 0 {
                // 小熊回应由文字改图标：官方 hug 拥抱表情（深色用 _dark 版，不 tint）
                // ＋数字，与足项同款 14pt 图＋13pt 灰字、间距 4。
                let emoteRow = UIStackView()
                emoteRow.axis = .horizontal
                emoteRow.spacing = 4
                emoteRow.alignment = .center
                let emoteIcon = UIImageView(image: BearyEmoteImages.image(for: "hug", dark: traitCollection.userInterfaceStyle == .dark))
                emoteIcon.translatesAutoresizingMaskIntoConstraints = false
                emoteIcon.contentMode = .scaleAspectFit
                let emoteCountLabel = UILabel()
                emoteCountLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
                emoteCountLabel.adjustsFontForContentSizeCategory = true
                emoteCountLabel.textColor = BearyColors.gray
                emoteCountLabel.text = "\(emoteTotal)"
                emoteCountLabel.setContentHuggingPriority(.required, for: .horizontal)
                emoteRow.addArrangedSubview(emoteIcon)
                emoteRow.addArrangedSubview(emoteCountLabel)
                NSLayoutConstraint.activate([
                    emoteIcon.widthAnchor.constraint(equalToConstant: 14),
                    emoteIcon.heightAnchor.constraint(equalToConstant: 14),
                ])
                emoteIconView = emoteIcon
                footItems.append(emoteRow)
            }
            let bookmarkCount = entry.bookmarkCount ?? 0
            if bookmarkCount > 0 {
                footItems.append(footItem(iconName: "icon_bookmark", text: "\(bookmarkCount)"))
            }
            if !footItems.isEmpty {
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
            }
        } else {
            // TL-3 私密行操作行（2026-10-29 口径）：只剩编辑态文字组（倒计时 + “编辑”）；
            // 删除已收进卡片右上角 ⋯ 菜单。删除本身不由本页发请求：
            // 走容器回调，容器按网页 confirmDelete 流程弹“确认删除？/ 删除后会移入回收站，
            // 30 天内可在「回收站」里恢复。”再调删除接口。
            updateEditRow(entry: entry)
            actsStack.isHidden = false
        }
        // iCity：公开行与私密行共用操作行——公开行在计数足行之外同样出操作行
        //（只剩编辑态文字组，编辑仅 15 分钟内；删除走 ⋯ 菜单，公开/私密均可）。
        if published {
            updateEditRow(entry: entry)
            actsStack.isHidden = false
        }
    }

    /// N7 主图条点按：下标取自 imageView.tag，keys 从 currentEntry 按
    /// configure 同一过滤口径（去空）重算；复用后手势随旧 imageView 一并移除，
    /// configure 重建时重新挂接，不留跨条目残留回调。
    /// 审计 P2-14：主图条重试（广场同款 bearyFeedPerformRetry）。
    @objc private func timelineThumbRetryTapped(_ sender: BearyFeedRetryButton) {
        bearyFeedPerformRetry(sender)
    }

    @objc private func didTapThumb(_ sender: UITapGestureRecognizer) {
        guard let entry = currentEntry else { return }
        let keys = (entry.images ?? []).filter { !$0.isEmpty }
        let index = sender.view?.tag ?? 0
        guard index >= 0 && index < keys.count else { return }
        onTapImages?(keys, index)
    }

    /// 2026-10-29 Li 定编辑态口径（无图标、只留文字、状态会变）：
    /// - 可编辑期内：左侧“还剩 N 分钟”灰字（按分钟刷新，向上取整，至少 1 分钟）+
    ///   可点按的“编辑”二字（本行唯一的编辑入口）；数字变化只改 label 文本。
    /// - 到期那一刻（本行此前已渲染过可编辑态，即看着它过期）：同位置变
    ///   “编辑已结束”灰字，约 3 秒后淡出到不可见（减动效下直接不可见）。
    ///   2026-10-30 外框定格：退场只降 alpha，绝不 isHidden——本行在布局里
    ///   始终占位，卡片高度与限时虚线框（cardView.bounds）不因编辑态翻转
    ///   而跳变；“什么都不留”指的是视觉上无文字，不是布局上塌掉本行。
    /// - 首渲染已过期（含 deadline 缺失即已锁）：不闪“编辑已结束”，直接什么都不留。
    /// - 小地球显隐与无障碍文案同在此定（已挪 meta 行末，恒灰色 21pt）。
    private func updateEditRow(entry: Entry) {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if let deadline = entry.editDeadline, nowMs < deadline {
            editRowSawEditable = true
            editRowEndTimer?.invalidate()
            editRowEndTimer = nil
            editStatusGroup.isHidden = false
            editStatusGroup.alpha = 1
            editStatusGroup.accessibilityElementsHidden = false
            editStatusLabel.textColor = BearyColors.gray
            let remainingSeconds = (deadline - nowMs) / 1000
            let minutes = max(1, (remainingSeconds + 59) / 60)
            let text = "还剩 \(minutes) 分钟"
            if editStatusLabel.text != text {
                editStatusLabel.text = text
            }
            editTextButton.isHidden = false
            editTextButton.alpha = 1
            editTextButton.isEnabled = true
        } else if editRowSawEditable && !editRowEndedShown {
            // live 翻转：此前见过可编辑态，才走“编辑已结束 → 3 秒消失”这一段。
            editRowEndedShown = true
            editStatusGroup.isHidden = false
            editStatusGroup.alpha = 1
            editStatusGroup.accessibilityElementsHidden = false
            editStatusLabel.text = "编辑已结束"
            editStatusLabel.textColor = BearyColors.gray
            // 外框定格：只换文字、不增删视图——“编辑”钮只降 alpha 并禁用，
            // 仍留在布局里占位，本行宽高与可编辑期完全一致，卡片不跳变。
            editTextButton.isHidden = false
            editTextButton.alpha = 0
            editTextButton.isEnabled = false
            editRowEndTimer?.invalidate()
            editRowEndTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                self?.hideEditEndedRow()
            }
        } else if !editRowSawEditable && !editRowEndedShown {
            // 首渲染已过期：不闪提示，直接什么都不留。
            editRowEndTimer?.invalidate()
            editRowEndTimer = nil
            editStatusGroup.isHidden = true
        }
        // 已结束且已消失后：后续 tick 不再碰本行（editRowEndedShown 守卫）。
        // 2026-10-29 改版：⋯ 菜单钮常驻 meta 行末，不再按行态显隐或改文案；
        // 可见性切换走菜单“修改权限”，与原地球钮同一 handlePublishEntry 路径。
    }

    /// “编辑已结束”3 秒后的退场：只淡出到不可见，绝不 isHidden。
    /// 旧口径在动画完成时 isHidden=true，UIStackView 会把本行高度塌到 0，
    /// 卡片随之缩短、限时虚线框（cardView.bounds 重画）位置上移，
    /// 就是 Li 报的“编辑已结束文字出现时外框变化”。本行保留“编辑已结束”
    /// 文本与布局占位、仅 alpha=0，卡片高度与外框全程不动。
    private func hideEditEndedRow() {
        editRowEndTimer = nil
        if UIAccessibility.isReduceMotionEnabled {
            editStatusGroup.alpha = 0
            editStatusGroup.accessibilityElementsHidden = true
            return
        }
        UIView.animate(withDuration: 0.25, animations: { [weak self] in
            self?.editStatusGroup.alpha = 0
        }, completion: { [weak self] _ in
            self?.editStatusGroup.alpha = 0
            self?.editStatusGroup.accessibilityElementsHidden = true
        })
    }

    @objc private func moreTapped() {
        guard let entry = currentEntry else { return }
        onMoreEntry?(entry, moreButton)
    }

    /// 可见性切换失败的拒绝动效：⋯ 钮摇头 + warning 震动（与卡片
    /// playDenyShake 同口径：减动效只跳视觉抖动，震动照常给；
    /// 原 globe 钮已摘除，摇头目标改为 ⋯ 菜单钮，调用点与音效/震动不变）。
    func playPublishDenyShake() {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled { return }
        moreButton.layer.removeAnimation(forKey: "bearyDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        moreButton.layer.add(shake, forKey: "bearyDenyShake")
    }

    /// F2 引用缩略图清理（复用与重配时先清，避免旧图残留）。
    private func clearQuoteThumbs() {
        for imageView in quoteThumbImageViews {
            imageView.bearySetImage(url: nil)
            imageView.removeFromSuperview()
        }
        quoteThumbImageViews = []
        quoteThumbsScrollView.isHidden = true
    }

    /// TL-2/TL-3 的 1 秒 tick 入口：只改本行编辑倒计时文案，不重建行
    ///（pill 现为静态两态，公开/私密行都跑编辑倒计时）。
    func refreshCountdowns() {
        guard let entry = currentEntry else { return }
        updateEditRow(entry: entry)
    }

    @objc private func editTapped() {
        guard let entry = currentEntry else { return }
        onEditEntry?(entry)
    }

    @objc private func quoteTapped() {
        guard let entry = currentEntry, let quoteId = entry.quote?.id else { return }
        // iCity：gone/locked 卡不导航；其余一律转发 id，容器先 fetchEntry 校验再放行。
        if entry.quote?.gone == true || entry.quote?.locked == true { return }
        onQuoteEntry?(quoteId)
    }

    /// 80 包 B4-1：行内时间与引用日期 formatter 静态复用（原每次 configure 新建）。
    private static let timelineTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.dateFormat = "HH:mm"
        return f
    }()
    // 补缺 P3-29：引用日期全站统一 F3 口径 M月d日 H:mm（卡片/详情引用卡已用该口径；原 M 月 d 日无时间且带空格）。
    private static let timelineQuoteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.dateFormat = "M月d日 H:mm"
        return f
    }()

    private func footItem(iconName: String, text: String?, highlighted: Bool = false) -> UIView {
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
        // 已点赞态：图标与数字同走点赞亮红（与卡片/详情已点赞态同色）；
        // 未点赞态仍走灰；收藏足项不传 highlighted，恒灰。
        iconView.tintColor = highlighted ? BearyColors.likeRed : BearyColors.gray
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
            label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = highlighted ? BearyColors.likeRed : BearyColors.gray
            label.text = text
            row.addArrangedSubview(label)
        }
        return row
    }

    /// N1：已公开 pill 两态透明底——浅色橙 12%、深色橙 18%，动态色解析，
    /// 主题切换自动跟随（不用 BearyColors.alpha 固定透明度，后者两态同值）。
    static func publishedPillBackground() -> UIColor {
        return UIColor { trait in
            BearyColors.orange.resolvedColor(with: trait).withAlphaComponent(
                trait.userInterfaceStyle == .dark ? 0.18 : 0.12)
        }
    }

}


// MARK: - 时间线页

class BearyTimelineViewController: UIViewController {

    /// 回收站 pill 点按（容器接线：打开回收站页；本文件只定义回调，不做页面跳转）。
    var onOpenTrash: (() -> Void)?
    /// 时间线空态“写一篇”点按（容器接线：打开编辑器；与 onOpenTrash 同口径，
    /// 本文件只定义回调，不直接 present 编辑器——编辑器的 centered/sheet
    /// 呈现逻辑在容器侧，时间线侧直接 present 会走错呈现形态）。
    /// 注意：容器尚未接线本回调前，空态按钮点按无动作（见回执待办）。
    var onCompose: (() -> Void)?
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
    /// 80 包 B2：viewDidLoad 首拉已发起的标记（引导预加载步骤据此去重，不复发第二拉）。
    var initialLoadStarted = false
    private var timelineUnauthorized = false
    private var timelineLoadingMore = false
    // 崩溃 1（21:33/21:50 两次 Invalid_Batch_Updates）：首屏加载此前无在途守卫，
    // 重拍 tab/下拉/登录翻转/发布都可重入 loadTimelineFirstPage；旧回包按陈旧
    // oldSections diff 时表早已不是旧快照即崩。seq 令牌：每次首屏加载 +1，
    // 回包 seq 不符直接丢弃（不碰模型、不 diff、不 reload、不调 completion，
    // 新加载的回包自会渲染）。当前无调用方传 completion（仅 reloadTimeline
    // 无参调用），故陈旧回包不调 completion 是安全的；日后若有调用方传
    // completion，需自行处理陈旧语义。
    private var timelineFirstPageSeq = 0
    // G15：分页失败标记——脚部保持“加载失败，重试”可重试。
    private var timelinePageFailed = false
    // M2：分页新增行的错峰滑入队列（willDisplay 时按原始序号起播，播过即摘；
    // 用序号字典而非数组，避免摘除后后续序号前移导致错峰失效）。
    private var staggerInsertOrder: [IndexPath: Int] = [:]
    /// 80 包 A2-3②：错峰队列代际——切日/清选区时 +1，队列写入时记录当时
    /// 代际；willDisplay 发现代际不符即丢弃残留条目，不在新数据行上重播。
    private var staggerGeneration = 0
    private var staggerQueueGeneration = 0
    /// 切页/整表重载时清掉未播的错峰队列：分页追加后未显示的行若带着 stagger
    /// 条目切走 tab，切回时 willDisplay 会补播滑入——行已是既有内容，不得重播。
    /// 容器切离时间线页与 reloadTimeline 整表重载时调用；分页追加本身不调
    ///（新行首显仍需滑入；willDisplay 播过即摘，不影响正常路径）。
    func clearStaggerEntries() {
        staggerInsertOrder.removeAll()
        // N3：切日错峰队列与组头淡入标志同生命周期，一并清掉，
        // 防旧队列在新数据行上重播（已有元素不重播）。
        daySwitchStagger.removeAll()
        daySwitchTitleFade = false
        daySwitchArrivalKey = nil
    }
    // M16：跳转提示当前 label 弱引用，消失时先做透明度过渡再移除。
    private weak var jumpNoteLabel: UILabel?
    private var trashCountValue = 0
    private var countsValue: TlCounts?
    private var loginNotified = false

    private var calendarCache: [String: BearyCalendarMonthResponse] = [:]
    private var calendarFetching: Set<String> = []
    private var calendarFailed: Set<String> = []
    /// 64 包反馈修（第 3 项）+ 本批新规矩：统计行已渲染数值（streak|monthTotal，
    /// 失败/空态另计）。签名故意不含月份 key——切月时数值不变即一字不碰按钮，
    /// 旧签名含月份 key 是闪的根因（数值未变仍整行 setAttributedTitle 重建）。
    /// 数值真变时只替换数字段（见 updateStatsNumbersOnly），静态段与火苗图标不动。
    /// 签名只在写新日记时由 invalidateStatsLine 清掉（删除/回收站恢复走
    /// refreshAfterDetailChange 强制重拉，值变了签名自然不同、无需另清）。
    private var calendarMode: BearyCalendarCardView.ViewMode = .week
    private var calendarAnchor: (year: Int, month: Int, day: Int)?
    private var calendarDisplayedMonth: (year: Int, month: Int)?
    private var selectedDayKey: String?
    /// 第 3 项翻周/翻月选区跟随：新视图月份缓存未到齐时挂起，到达后在
    /// fetchCalendarMonth 回包里重试（tryStepFollowSelection）。
    private var pendingStepFollow = false
    /// 第 4 项 calFixSel 守卫：删除后（refreshAfterDetailChange 置位）或
    /// 月份补拉到达后，选中日计数为 null/0 时才触发跳转/取消选中；
    /// 平时月份到达不触发，避免空的今天被无故清选区。
    private var pendingFixSelCheck = false
    /// 第 2 项 A 初次进入 / 下拉刷新跳转守卫：只在 viewDidLoad 与自定义下拉刷新
    /// 两处设置；选中日无日记时走 checkEntryJumpForSelectedDay → applyDayFixSel
    /// 跳最近有篇日并出 jumpNote 提示。故意不用 pendingFixSelCheck 承载，
    /// 避免守卫漏到翻页（tryStepFollowSelection）路径：翻页到全无有篇日时
    /// 必须保留原选区，本标志在当日/月份回包到达时即被消费或清掉。
    private var pendingEntryJumpCheck = false
    /// 6A gotoEntry 定位挂起：定位目标 id + 目标北京日；当日回包尾部消费一次。
    /// 用户手动切日（非定位触发的 selectDay）即作废，避免之后无故跳转。
    private var pendingLocateEntryId: String?
    private var pendingLocateDayKey: String?
    /// 6A：本次 selectDay 是否由定位触发（是则保留 pending，否则清掉）。
    private var locateDaySelection = false
    /// 第 5 项公开/取消在途去重（同篇重复点按只发一次请求）。
    private var publishBusyIds: Set<String> = []

    private var dayEntries: [Entry] = []
    private var dayState = LoadState.idle
    private var dayKeyForLoad: String?
    private var dayEntriesKey: String?
    /// N2：已加载过的当日数据缓存（key=北京日，value=该日成功回包的条目）。
    /// 日历缓存（calendarCache）只含计数、不含条目，故切日此前必重拉；
    /// 本缓存只由 fetchDayEntries 成功回包写入，失败不写、不污染。
    /// 缓存是“先显示、后台再对齐”的底子，过期由每次切日的静默刷新纠正，
    /// 不设 TTL（当日数据变化只来自本人的写/删/公开操作，见删除时的清缓存）。
    private var dayEntriesCache: [String: [Entry]] = [:]
    /// 全量同步落盘：落盘是 dayEntriesCache 的持久层，不是第二套真相——
    /// 读顺序永远是内存 → 落盘 → 网络；每次网络日成功都同时写内存与落盘。
    private func cacheDayEntries(key: String, entries: [Entry]) {
        dayEntriesCache[key] = entries
        if let uid = SessionManager.shared.currentUser?.id {
            // 落盘写走同步队列（不卡主线程，同时记写盘代际供全量同步提交守卫判断）；
            // 内存态已同步更新，UI 不等落盘。
            BearyEntrySync.shared.runDiaryDiskWrite {
                BearyEntrySyncStore.saveDay(accountId: uid, dayKey: key, entries: entries)
            }
        }
    }
    /// 落盘读：命中则同步回填内存（调用方按内存命中同款处理 + 静默刷新）。
    private func diskCachedDayEntries(key: String) -> [Entry]? {
        guard let uid = SessionManager.shared.currentUser?.id,
              let disk = BearyEntrySyncStore.loadDay(accountId: uid, dayKey: key) else { return nil }
        dayEntriesCache[key] = disk
        return disk
    }
    /// 账号切换时清日缓存：内存日缓存与预取在途集合都不跨账号（落盘已按 uid
    /// 分桶，不动）；由 SceneDelegate onUserChanged 的 userChanged 分支在
    /// reloadTimeline 之前调用，登录与退出两个方向都覆盖。时间线 VC 换账号
    /// 不重建，故必须显式清，否则新账号当日面板会先闪出旧账号的日缓存。
    func clearDayCacheForAccountChange() {
        dayEntriesCache.removeAll()
        dayPrefetchInFlight.removeAll()
    }
    /// 相邻日预取在途集合（key=北京日）：独立通道专用，与正向单槽
    /// （dayKeyForLoad + dayState）完全分开；同日只发一次，失败不留痕。
    private var dayPrefetchInFlight: Set<String> = []
    /// N3：切日入场错峰队列（willDisplay 起播，播过即摘；代际见
    /// daySwitchGeneration，与分页 staggerInsertOrder 同机制不同队列，
    /// 步进 0.05s、封顶 0.5s）。selectDay / 清选区 / 整表重载时清掉。
    private var daySwitchStagger: [IndexPath: Int] = [:]
    private var daySwitchGeneration = 0
    /// N3：切日组头淡入一次性标志（willDisplayHeaderView 消费一次，不重播）。
    private var daySwitchTitleFade = false
    /// N3：切日回包到达时的入场错峰归属（仅 clear:true 的换日回包设置，
    /// 回包消费后清掉；非换日回包不设，避免旧队列在刷新行上重播）。
    private var daySwitchArrivalKey: String?
    private var showJumpNote = false
    private var jumpNoteTimer: Timer?
    /// TL-2 1 秒 tick（仅刷编辑倒计时文案）。
    private var countdownTimer: Timer?

    // MARK: - 视图

    private lazy var tableView: UITableView = {
        // 不吸顶（第 10 项）：grouped 风格的 section header 随内容滚动、不悬浮；
        // plain 的悬浮吸顶是问题根源。sectionHeaderTopPadding 置 0，避免 grouped
        // 默认的首组顶距改变原有纵向节奏；其余布局（自定义头视图、行高、表头）不变。
        let tv = UITableView(frame: .zero, style: .grouped)
        tv.sectionHeaderTopPadding = 0
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.backgroundColor = BearyColors.bg
        tv.separatorStyle = .none
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 180
        tv.estimatedSectionHeaderHeight = 40
        tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 90, right: 0)
        tv.scrollIndicatorInsets = tv.contentInset
        // 顶栏透度批：与 Feed 同理，表框贴页顶（view.top），关自动调整使属性内边距即视觉顶距。
        tv.contentInsetAdjustmentBehavior = .never
        tv.register(BearyTimelineCell.self, forCellReuseIdentifier: BearyTimelineCell.reuseIdentifier)
        tv.delegate = self
        tv.dataSource = self
        // 自定义下拉头（消息页同款，见 pullView）：表内子视图，平时藏在内容上方，
        // 不再用 UIRefreshControl——标准刷新头会把 32pt 图标钉在刷新头正中心，
        // 时间线表框贴页顶 + 收起顶距只有安全区本身时，小拉动图标中心落在
        // 安全区顶 -30pt 附近，正好被灵动岛遮挡。
        tv.addSubview(pullView)
        return tv
    }()

    /// 下拉刷新指示：官方刷新图标（32pt，全 App 统一 icon_refresh）。
    private let refreshIconView = BearyRefreshIconView()
    /// 自定义下拉刷新进行中标志（消息页 isCustomPullRefreshing 同款）。
    private var isCustomPullRefreshing = false
    private var customPullStartTime: Date?
    private var pullEngageTranslation: CGFloat?

    /// 自定义下拉指示器（消息页 pullView 同款口径）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 图标底边 -14、不拦截触摸；刷新中改固定 84 高。
    /// 时间线与消息页的区别只在基线：本页表框贴页顶、contentInset.top 基线是
    /// 安全区顶（收起态），不是消息页的 0，所以指示器屏内底边 = 安全区顶 + 指示高，
    /// 满指示 80pt 时图标中心落在安全区顶 +50pt 左右，灵动岛下方。
    /// 另一区别在裁剪：消息页表框顶 = 安全区顶，早期图标被表框裁掉；本页
    /// 表框贴页顶裁不掉，故 updateCustomPullIndicator 里用 alpha 门模拟裁剪
    /// （指示高 ≤30 时图标 alpha 强制 0）。
    private lazy var pullView: UIView = {
        let pull = UIView()
        pull.backgroundColor = BearyColors.bg
        pull.isUserInteractionEnabled = false
        pull.frame = CGRect(x: 0, y: -116, width: 0, height: 116)
        pull.addSubview(refreshIconView)
        NSLayoutConstraint.activate([
            refreshIconView.centerXAnchor.constraint(equalTo: pull.centerXAnchor),
            refreshIconView.bottomAnchor.constraint(equalTo: pull.bottomAnchor, constant: -14),
            refreshIconView.widthAnchor.constraint(equalToConstant: 32),
            refreshIconView.heightAnchor.constraint(equalToConstant: 32),
        ])
        return pull
    }()

    /// 表头容器：标题行 + 统计小字 + 连续写作行 + 日历卡。
    /// 用 tableHeaderView 承载（随列表一起滚走，不常驻占位）；高度每次渲染后重算。
    /// TL-7：当日列表不替换整个时间线，而是表格的
    /// 第一个分区（当日面板），时间线分区紧随其后（与网页 #calDay + #tlBody 并存一致）。
    /// 顶栏透度批：容器最后一次发来的栏态（viewDidLayoutSubviews 安全区变化时按此重算）。
    private var headerTopInsetVisible = false
    /// 追加项二：悬浮日期头（标准 sticky section header）。表保持 grouped
    /// 不动（第 10 项红线：不得改回 plain 悬浮吸顶），悬浮视图是 VC view 上
    /// 的独立覆盖层，只跟随滚动偏移显隐与顶替，不参与表布局、不拦截触摸。
    /// 顶替裁剪容器：钉在安全区顶沿、clipsToBounds，吸顶条在容器内用
    /// transform 上移顶替，滑出安全区的部分被容器裁掉——旧日期是渐渐被裁没，
    /// 永不滑进状态栏区；换日时旧条已被全裁，位移归零无可见跳变。
    private let stickyHeaderContainer = UIView()
    private let stickyHeaderView = UIView()
    private let stickyHeaderLabel = UILabel()
    // 吸顶头状态栏区底色：只盖 view 顶到安全区顶沿这一段（吸顶头自身已盖安全区下方），
    // 与吸顶头同显同隐，滚动内容不再从状态栏区透出。
    private let statusBarBgView = UIView()
    private var stickyHeaderCurrentSection: Int?
    private var stickyHeaderCurrentTitle: String?
    private let headerContainer = UIView()
    private let titleLabel = UILabel()
    /// 盲盒入口（时间线顶部）：与广场顶部入口共用 BearyBlindBoxEntryView 与
    /// BlindBoxState，同一当日计数；点按进同一流程页。
    private let blindBoxEntryView = BearyBlindBoxEntryView()
    private let trashButton = UIButton(type: .system)
    private let countsLabel = UILabel()
    private let statsButton = UIButton(type: .system)
    private let calendarCard = BearyCalendarCardView()
    private var headerStack: UIStackView?
    private var lastHeaderWidth: CGFloat = 0

    // 112：脚部“加载更多”改 BearyHit44Button——旧 plain UIButton 无高度约束，
    // 实际可点高度仅标题约 20pt，holder 上下各约 12pt 点按无反应。
    // 视觉字号/文案不动（viewDidLoad 里 14pt 与颜色原样保留）。
    private let loadMoreButton = BearyHit44Button(type: .system)
    private let footerSpinner = BearyRefreshIconView()

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
        setupStickyHeader()
        // R8：控制器自有按钮类走 scaledFont + adjusts（卡片内文字由卡片组负责，不碰）。
        loadMoreButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        loadMoreButton.titleLabel?.adjustsFontForContentSizeCategory = true
        loadMoreButton.setTitleColor(BearyColors.gray, for: .normal)
        loadMoreButton.addTarget(self, action: #selector(didTapFooter), for: .touchUpInside)
        loadMoreButton.bearyAddPressHaptic()
        // 审计 P2-20：时间线监听拉黑/举报即时清行并清 quoteCache。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlindBoxStateChanged), name: .bearyBlindBoxDidChange, object: nil)
        blindBoxEntryView.onTap = { [weak self] in
            self?.presentBlindBoxFlow()
        }
        // 2026-10-30 全 App 统一 icon_refresh：脚部圈取 20pt 图，栈内固有尺寸与旧 medium 圈一致。
        footerSpinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
        // G15 toast 已委托 B 批统一 BearyToast（见 showTimelineToast），
        // 此处不再建常驻 toast 容器。
        // 第 2 项 A 调用点 1/2（初次进入）：置跳转守卫挂起，选中日（今天）
        // 无日记时由当日/月份回包触发跳最近有篇日；标志不放在 reloadTimeline
        // 内，以免空态重试等其他 reloadTimeline 调用点也被接上守卫。
        pendingEntryJumpCheck = true
        initialLoadStarted = true
        loadTimelineCachedOrRefresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 顶栏透度批：安全区变化时按已存栏态重算（容器 viewDidLayoutSubviews 也会重发，双重 no-op）。
        // 自定义下拉刷新进行中 applyHeaderTopInset 有守卫不改写内边距，但 pullView
        // 宽度仍需跟随旋转/分屏宽度（消息页同款宽度同步）。
        applyHeaderTopInset(visible: headerTopInsetVisible)
        if pullView.frame.width != tableView.bounds.width {
            pullView.frame.size.width = tableView.bounds.width
        }
        // 宽为 0 时丢弃的表头高度重算在此消费：宽一就绪即重算。
        if headerHeightNeedsRefresh, tableView.bounds.width > 0 {
            refreshHeaderHeight()
        }
        if abs(tableView.bounds.width - lastHeaderWidth) > 0.5 {
            refreshHeaderHeight()
            updateStickyHeader()
            return
        }
        // 表头拟合高度只在布局后才最终落定（随宽度走）。若拟合高度与当前
        // 表头高度不一致则刷新；若一致，只恢复 fittingHeaderHeight 临时
        // 清零的高度（不重赋值，不会循环：刷新后高度已一致）。
        let oldHeight = headerContainer.frame.height
        let fitting = fittingHeaderHeight()
        if abs(fitting - oldHeight) > 0.5 {
            refreshHeaderHeight()
        } else {
            headerContainer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: oldHeight)
        }
        // 追加项二：布局落定后重算悬浮头（旋转/安全区变化/重载后跟随）。
        updateStickyHeader()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 盲盒计数：进页即按本地镜像刷新（跨日重置 + 流程页回来的已换态）。
        BlindBoxState.shared.resetIfNewDay()
        blindBoxEntryView.refresh()
        // 回收站 pill 图标按压缩放残留复位（通用按压反馈 .84 的已知残留类问题，
        // 回页时复位，保证图标回到满尺寸）。
        trashButton.imageView?.transform = .identity
        startCountdownTimer()
        // 回到本页时栏恢复可见（不带动画，避免进页先闪一下栏）。
        // setChromeHidden 由容器 lane 在 SceneDelegate.swift 提供，本文件只调用。
        // 下滑藏栏已拆除（第 11 项）：底栏胶囊与 FAB 常驻，不再按滚动方向藏栏。
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCountdownTimer()
    }

    /// 切页生命周期 7 号（最小化）：容器切页只改 isHidden，本回调不触发，
    /// 故容器 showPage 在离页/进页时显式调这两个钩子；只覆盖 tick 启停
    ///（栏恢复已有 showPage 的 setBarsVisible/setHeaderVisible 兜底，不重复）。
    func pageDidEnter() {
        startCountdownTimer()
        // 盲盒计数：切 tab 回页时同样按本地镜像刷新（容器只改 isHidden，不触发 viewWillAppear）。
        BlindBoxState.shared.resetIfNewDay()
        blindBoxEntryView.refresh()
        // 80 包 A5：进页恢复可见行表情播放（与 stopVisibleEmotes 对称）。
        resumeVisibleEmotes()
    }

    /// 盲盒流程页（全屏 modal + fadeRise，广场入口同款；游客态由流程页内登录提示承接）。
    private func presentBlindBoxFlow() {
        let vc = BearyBlindBoxFlowViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func handleBlindBoxStateChanged() {
        blindBoxEntryView.refresh()
    }

    func pageDidLeave() {
        stopCountdownTimer()
    }

    /// 动画批 11 号：切 tab 离页时停掉本页可见行全部表情（容器只改 isHidden，
    /// 不触发 didEndDisplaying、不离窗，播放器侧无法自停）。
    func stopVisibleEmotes() {
        for cell in tableView.visibleCells {
            cell.stopAllBearyEmotes()
        }
    }

    /// 80 包 A5：与 stopVisibleEmotes 对称的恢复入口（容器切回时调用）：
    /// 只恢复可见行内 BearyEmoteView 的播放，不重播整页入场。
    func resumeVisibleEmotes() {
        func resume(_ view: UIView) {
            if let emote = view as? BearyEmoteView { emote.play() }
            for sub in view.subviews { resume(sub) }
        }
        for cell in tableView.visibleCells { resume(cell) }
    }

    /// 动画批 11 号离屏停播：行离屏即停其全部表情（含心情位）。
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.stopAllBearyEmotes()
    }

    deinit {
        countdownTimer?.invalidate()
        jumpNoteTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyBlindBoxDidChange, object: nil)
    }

    /// 审计 P2-20：拉黑/举报广播到后即时清行——内存三处（timelineEntries/dayEntries/
    /// dayEntriesCache）与落盘同清（不进回收站：这只是隐藏，不是删除），引用缓存同清。
    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int else { return }
        var removedIds: [String] = []
        for list in dayEntriesCache.values {
            for e in list where e.authorId == userId {
                if let id = e.id { removedIds.append(id) }
            }
        }
        for e in timelineEntries where e.authorId == userId {
            if let id = e.id, !removedIds.contains(id) { removedIds.append(id) }
        }
        guard !removedIds.isEmpty else { return }
        for id in removedIds { purgeTimelineEntry(entryId: id) }
        tableView.reloadData()
    }

    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, !entryId.isEmpty else { return }
        purgeTimelineEntry(entryId: entryId)
        BearyDiaryCardCell.quoteCache.removeValue(forKey: entryId)
        tableView.reloadData()
    }

    private func purgeTimelineEntry(entryId: String) {
        timelineEntries.removeAll { $0.id == entryId }
        dayEntries.removeAll { $0.id == entryId }
        for key in dayEntriesCache.keys {
            dayEntriesCache[key]?.removeAll { $0.id == entryId }
        }
        if let uid = SessionManager.shared.currentUser?.id {
            BearyEntrySync.shared.runDiaryDiskWrite {
                BearyEntrySyncStore.removeEntry(accountId: uid, entryId: entryId)
            }
        }
    }

    // MARK: - 对外入口（容器在 tab 切入/重进时调用）

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 tableView，
    /// 表框贴页顶 + .never，故属性内边距即视觉顶距：显示 = 安全区顶 + 60，收起 = 安全区顶
    /// （本页在容器里恒收起，显示值只在首页当前、时间线已建未亮时经容器统一发一次，切页时即改回收起）。
    /// 底内边距同步补安全区底（.never 后旧视觉底 = 90 + 安全区底）。本页无公开回顶方法、
    /// 再点当前 tab 口径（容器重拍分支）：已在顶部才刷新，否则只回顶（见 scrollToTop/isAtTop）。
    func applyHeaderTopInset(visible: Bool) {
        headerTopInsetVisible = visible
        // 自定义下拉刷新进行中不改写（消息页同款守卫）：刷新中内边距是基线 +84，
        // 容器重发顶距会打断指示器。
        guard !isCustomPullRefreshing else { return }
        let top = view.safeAreaInsets.top + (visible ? 60 : 0)
        let bottom = 90 + view.safeAreaInsets.bottom
        if tableView.contentInset.top != top || tableView.contentInset.bottom != bottom {
            tableView.contentInset.top = top
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.top = top
            tableView.scrollIndicatorInsets.bottom = bottom
        }
    }

    /// keepSelectedDay=true 时保留当前选中日：跳过“重置为今天 + 拉今天当日”，
    /// 只拉一次最终选中日（G16 下拉刷新口径；默认 false 保持原有进页行为）。
    /// 再点当前 tab：回顶（与首页 scrollToTop 同口径，减动效直达）。
    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 再点当前 tab 口径：offset 是否已在顶部容差（1pt）内；在顶部才刷新，否则只回顶。
    var isAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
    }

    /// 账号隔离 9 号：keepDay 时同时保留旧内容——不清时间线模型、不动
    /// timelineState、不清当日面板，首屏回包经行 diff 更新；失败时旧内容
    /// 原样保留（失败/加载态只在空表时渲染特殊态，见 3617 一带，故不闪白）。
    /// 110：冷启动缓存优先（首页 BearyFeedCache SWR 同款口径）。
    /// 时间线此前无首屏磁盘缓存：每次冷启动都清表 + 全量重拉 50 条 +
    /// 中央 spinner 等网络，即“冷启动后时间线慢”的主因（首屏 payload
    /// 仅约 60KB、解码可忽略，耗时在 TTFB 与无缓存上，见实测分解）。
    /// 有缓存：即时渲染缓存首屏（不转菊花、不清表），再走既有静默
    /// 路径对齐——首屏 loadTimelineFirstPage（有旧行时走 diff，不重建
    /// 节点；有行时 updateChrome 不挂背景 spinner）、日历月份（内存
    /// 缓存守门）、当日面板（clear:false 静默刷新）；三路并行，不串行。
    /// 无缓存：走旧 reloadTimeline 全量路径。
    /// 账号切换不走本函数：SceneDelegate 切号时调 reloadTimeline 强制
    /// 重拉，不读旧桶缓存。时间线是本人全部日记（含私密），缓存不做
    /// Feed 的公开过滤，只按用户桶隔离（与日缓存落盘同款账号桶）。
    private func loadTimelineCachedOrRefresh() {
        let bucket = BearyFeedCache.bucket(userId: SessionManager.shared.currentUser?.id ?? BearyFeedCache.lastKnownUserId())
        guard let snap = BearyTimelineCache.load(bucket: bucket), !snap.entries.isEmpty else {
            reloadTimeline()
            return
        }
        if calendarAnchor == nil {
            calendarAnchor = BearyBeijingDay.todayComponents()
        }
        if calendarDisplayedMonth == nil, let anchor = calendarAnchor {
            calendarDisplayedMonth = (anchor.year, anchor.month)
        }
        if let today = BearyBeijingDay.todayComponents() {
            selectedDayKey = BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day)
        } else {
            selectedDayKey = nil
        }
        timelineEntries = snap.entries
        timelineHasMore = snap.hasMore
        trashCountValue = snap.trashCount
        if let total = snap.total, let priv = snap.priv, let pub = snap.pub {
            countsValue = TlCounts(total: total, priv: priv, pub: pub, nextPub: nil)
        }
        timelineState = .loaded
        timelinePageFailed = false
        timelineUnauthorized = false
        loginNotified = false
        showJumpNote = false
        // 当日面板先用缓存首屏里今天的篇顶上（静默刷新随后对齐），
        // 避免面板空等网络；缓存里今天无篇时面板空态由静默刷新补，
        // 初次进入跳最近有篇日的挂起（viewDidLoad 已置位）照常消费。
        if let dayKey = selectedDayKey {
            dayEntries = snap.entries.filter { entry in
                guard let created = entry.createdAt, let key = BearyBeijingDay.dayKey(ofMs: created) else { return false }
                return key == dayKey
            }
            dayEntriesKey = dayKey
            dayState = .loaded
        } else {
            dayEntries = []
            dayEntriesKey = nil
            dayState = .idle
        }
        clearStaggerEntries()
        tableView.reloadData()
        updateTrashTitle()
        updateCountsLabel()
        refreshHeaderHeight()
        updateChrome()
        // 静默对齐（与下拉刷新/首屏 diff 同款，不清表、不转菊花）。
        loadTimelineFirstPage()
        fetchCalendarMonthsForCurrentView()
        if let dayKey = selectedDayKey {
            fetchDayEntries(key: dayKey, clear: false)
        }
    }

    func reloadTimeline(keepSelectedDay: Bool = false) {
        let keepDay = keepSelectedDay && selectedDayKey != nil
        if keepDay {
            // 只重置瞬时标记，不动模型与状态。
            timelinePageFailed = false
            timelineUnauthorized = false
            loginNotified = false
            showJumpNote = false
            jumpNoteTimer?.invalidate()
            jumpNoteTimer = nil
        } else {
            timelineEntries = []
            timelineHasMore = false
            timelineState = .idle
            timelineUnauthorized = false
            timelinePageFailed = false
            loginNotified = false
            showJumpNote = false
            jumpNoteTimer?.invalidate()
            jumpNoteTimer = nil
        }
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
        clearStaggerEntries()
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
    /// 88 包 M14：删帖行级退场——模型里删掉该篇后按旧分区定位做 deleteRows，
    /// 分区空了则 deleteSections，不再整页首拉重载。日历点与统计行仍走强制
    /// 月份重拉刷新（与 refreshAfterDetailChange 同口径），选中日空了由
    /// pendingFixSelCheck 走原有跳转/取消逻辑；总数行本地递减。
    /// P0-1 例外：当日面板分区（section 0 且有选中日）在 currentSections 里
    /// 恒存在（即使 dayEntries 为空也占一个分区），变空时绝不能 deleteSections——
    /// 那会与数据源分区数脱节、且 completion 的 reloadSections(0) 越界崩溃；
    /// 面板变空只 deleteRows，随后 pendingFixSelCheck + 强制月份重拉走既有
    /// 选区跳转/取消逻辑。P1-8：本方法仅由删帖成功分支调用（容器 API 成功后），
    /// 故此处即删帖成功点，回收站计数 +1 并立即刷新 pill。
    func removeDeletedEntry(_ entry: Entry) {
        guard let entryId = entry.id else { return }
        // P1-8：先于模型/分区处理加计数——即使模型里已无该篇而走下方
        // refreshAfterDetailChange 回落，删帖成功进回收站的事实不变；
        // 回落的首拉成功后 trashCountValue 会被服务端值覆盖校准，不会累加。
        trashCountValue += 1
        updateTrashTitle()
        let oldSections = currentSections()
        var occurrences: [(section: Int, row: Int)] = []
        for (section, sec) in oldSections.enumerated() {
            for (row, e) in sec.entries.enumerated() where e.id == entryId {
                occurrences.append((section, row))
            }
        }
        guard !occurrences.isEmpty else {
            // 模型里没有（已被别处清掉），退回原有整页重拉保底。
            refreshAfterDetailChange()
            return
        }
        timelineEntries.removeAll { $0.id == entryId }
        dayEntries.removeAll { $0.id == entryId }
        // N2：删除同步清日缓存，否则切回该日会先闪出已删的旧行
        // （后台刷新虽会纠正，但“先闪后纠”本身就是要修的闪烁）。
        for key in dayEntriesCache.keys {
            dayEntriesCache[key]?.removeAll { $0.id == entryId }
        }
        // 落盘同清：否则切回该日会先闪出已删的旧行（静默刷新虽会纠正，但先闪后纠同样要修）。
        // 删帖落盘写走同步队列（不卡主线程，同时记写盘代际）。
        if let uid = SessionManager.shared.currentUser?.id {
            BearyEntrySync.shared.runDiaryDiskWrite {
                BearyEntrySyncStore.removeEntry(accountId: uid, entryId: entryId)
            }
            // 回收站桶同增：删帖即进回收站，下次进回收站页先读本地就能看到该条
            //（桶不存在时不建半截桶，进页走网络首拉；下次静默刷新用服务端值纠正残差）。
            BearyTrashSyncStore.prependDeleted(accountId: uid, entry: entry)
        }
        let newSections = currentSections()
        var rowDeletes: [IndexPath] = []
        var sectionDeletes = IndexSet()
        var panelAffected = false
        for occ in occurrences {
            let oldKey = oldSections[occ.section].dayKey
            let isDayPanel = occ.section == 0 && selectedDayKey != nil
            if isDayPanel { panelAffected = true }
            if isDayPanel {
                // P0-1：只删行（见方法头注释）——旧 1 行 → 新 0 行，与
                // 数据源的空面板分区一致；completion 的 reloadSections(0)
                // 因此仍在界内，可重建含计数的面板头。
                rowDeletes.append(IndexPath(row: occ.row, section: occ.section))
            } else if occ.section < newSections.count && newSections[occ.section].dayKey == oldKey && !newSections[occ.section].entries.isEmpty {
                rowDeletes.append(IndexPath(row: occ.row, section: occ.section))
            } else {
                sectionDeletes.insert(occ.section)
            }
        }
        if var counts = countsValue {
            counts.total = max(0, (counts.total ?? 0) - 1)
            if entry.isPublic == true {
                counts.pub = max(0, (counts.pub ?? 0) - 1)
            } else {
                counts.priv = max(0, (counts.priv ?? 0) - 1)
            }
            countsValue = counts
            updateCountsLabel()
            // 计数文案写入后表头高度必须重算（首屏 fitted 时计数为空，高度算短了，
            // 统计行会被 stack 压缩、上下裁剪；2423/3112 两路写入后都补）。
            refreshHeaderHeight()
        }
        tableView.performBatchUpdates({
            if !rowDeletes.isEmpty { self.tableView.deleteRows(at: rowDeletes, with: .fade) }
            if !sectionDeletes.isEmpty { self.tableView.deleteSections(sectionDeletes, with: .fade) }
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            // 面板头含计数（“N篇”），需重建头视图；日期组头无计数，不用动。
            if panelAffected {
                self.tableView.reloadSections(IndexSet(integer: 0), with: .none)
            }
        })
        pendingFixSelCheck = true
        for key in monthKeysForCurrentView() {
            fetchCalendarMonth(key: key, force: true)
        }
    }

    func refreshAfterDetailChange() {
        // 第 4 项删除后守卫：详情/回收站改动后，月份强制重拉到达时
        // 按日历计数复核选中日（空则跳转/取消），不只靠当日面板变空。
        pendingFixSelCheck = true
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

    /// B-G7 local sync patch: timeline and day panel are two independent decodes
    /// of the same entry (currentSections can show one id twice). After either
    /// source reloads, copy interaction/publication state into the other source so
    /// a copy whose own reload failed does not stay split from the fresh state.
    /// Only interaction + publication fields are patched (like/bookmark/emotes/
    /// isPublic/publishAt/publishedAt); body and images still require a
    /// full reload. Calendar month counts are monthly aggregates that paginated
    /// lists cannot recompute, so they keep syncing via refreshAfterDetailChange's
    /// forced month refetch; this patch deliberately does not touch calendarCache.
    private func patchedEntries(_ target: [Entry], withFresh fresh: [Entry]) -> [Entry] {
        var freshById: [String: Entry] = [:]
        for entry in fresh {
            if let entryId = entry.id { freshById[entryId] = entry }
        }
        return target.map { old in
            guard let entryId = old.id, let freshEntry = freshById[entryId] else { return old }
            var merged = old
            merged.likeCount = freshEntry.likeCount
            merged.likedByMe = freshEntry.likedByMe
            merged.bookmarkCount = freshEntry.bookmarkCount
            merged.bookmarkedByMe = freshEntry.bookmarkedByMe
            // 表情排序批同款：重拉回包不直接覆盖已显示顺序（新贴追加末尾），
            // 否则顺序敏感的互动签名会误触发跨页同步、把刚贴的顶到前面；
            // 回包缺 emotes 字段时保留旧值，不清空。
            if let freshEmotes = freshEntry.emotes {
                merged.emotes = BearyEmoteOrder.merged(previous: old.emotes, server: freshEmotes)
            }
            merged.isPublic = freshEntry.isPublic
            merged.publishAt = freshEntry.publishAt
            if let publishedAt = freshEntry.publishedAt { merged.publishedAt = publishedAt }
            // 批 E 补漏：双副本补丁此前不合并定位字段——日面板/时间线任一副本
            // 先拿到无定位旧值（落盘缓存、旧回包），另一副本重拉拿到定位后也
            // 同步不过去，位置行恒按旧值渲染。两路回包均来自同一列表接口、
            // 同为服务端权威行，故无条件跟随新值（含清定位时新值为 nil）。
            merged.locationName = freshEntry.locationName
            merged.locationDistrict = freshEntry.locationDistrict
            return merged
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

    /// 自定义下拉指示器跟随（消息页 updateCustomPullIndicator 同款）：
    /// 手指行程（pan 手势自顶部锚点起算）× 0.48 阻尼、上限 116；指示高 ≥80 时转圈淡入放大。
    /// 指示器是表内子视图：屏内底边 = 安全区顶 + 指示高（基线内边距已计入 contentRaw），
    /// 顶边随表回弹裁剪；刷新中不跟随。
    private func updateCustomPullIndicator() {
        if isCustomPullRefreshing {
            return
        }
        // 双图标互斥（一向）：首屏/程序加载态（timelineState == .loading）由
        // 背景加载 spinner 独占指示，下拉跟随在此态一律不画——此前跟随无此
        // 守卫（触发侧 scrollViewDidEndDragging 有 .loading 守卫，跟随侧没有），
        // 空表加载中下拉会同时出现背景 spinner（20pt，顶 +40）与下拉图标
        // （32pt），即“有时候两个刷新图标”。这是状态级禁用（跟随直接返回，
        // 不计算指示高、不画图标），不是把图标移出可视区假装藏掉。
        if timelineState == .loading {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: tableView.bounds.width, height: 116)
            refreshIconView.setPullProgress(0)
            refreshIconView.alpha = 0
            return
        }
        if !tableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: tableView.bounds.width, height: 116)
            refreshIconView.setPullProgress(0)
            return
        }
        let contentRaw = max(0, -(tableView.contentOffset.y + tableView.contentInset.top))
        let panTranslation = tableView.panGestureRecognizer.translation(in: tableView).y
        if tableView.contentOffset.y <= -tableView.contentInset.top && pullEngageTranslation == nil {
            pullEngageTranslation = panTranslation
        } else if tableView.contentOffset.y > -tableView.contentInset.top {
            pullEngageTranslation = nil
        }
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        let indicatorHeight = min(fingerRaw * 0.48, 116)
        pullView.frame = CGRect(x: 0, y: indicatorHeight - 116 - contentRaw, width: tableView.bounds.width, height: 116)
        if indicatorHeight <= 0 {
            refreshIconView.setPullProgress(0)
        } else {
            let progress = min(1, indicatorHeight / 98.4)
            refreshIconView.setPullProgress(progress)
            // 时间线与消息页的关键差别：消息页表框顶 = 安全区顶，表框裁剪会把
            // 指示高 <30 时的图标（中心在安全区顶之上）裁掉；本页表框贴页顶，
            // 表框裁剪裁不掉它，早期图标会 faint 地出现在灵动岛带内。故用 alpha
            // 门模拟同一裁剪：图标中心在指示高 30 时才越过安全区顶，30 以下
            // alpha 强制 0，30–80 间按 (指示-30)/50 淡入至满 alpha；转满一圈在
            // 指示高 98.4（= 触发行程 205pt × 0.48），满格点即触发点（alpha 口径不动）。
            if indicatorHeight <= 30 {
                refreshIconView.alpha = 0
            } else {
                refreshIconView.alpha = min(1, (indicatorHeight - 30) / 50)
            }
        }
    }

    /// 自定义下拉刷新进入（消息页 beginCustomPullRefresh 同款，基线适配时间线）：
    /// 指示固定 84 高 + 转圈，至少展示 500ms（见 loadTimelineFirstPage 完成分支），
    /// 刷新中内边距 = 基线（安全区顶 + 可见时 60）+ 84，屏内指示底边 = 基线 +84，
    /// 图标中心 = 基线 +54，灵动岛下方；减动效时直接落位，不播 0.32s 动画。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing || timelineState == .loading {
            return
        }
        isCustomPullRefreshing = true
        customPullStartTime = Date()
        refreshIconView.startSpinning()
        let baseTop = view.safeAreaInsets.top + (headerTopInsetVisible ? 60 : 0)
        let baseBottom = 90 + view.safeAreaInsets.bottom
        let pullIn = {
            self.tableView.contentInset.top = baseTop + 84
            self.tableView.contentInset.bottom = baseBottom
            self.tableView.scrollIndicatorInsets.top = baseTop + 84
            self.tableView.scrollIndicatorInsets.bottom = baseBottom
            self.tableView.contentOffset = CGPoint(x: 0, y: -(baseTop + 84))
            self.pullView.frame = CGRect(x: 0, y: -84, width: self.tableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: 0.32, animations: pullIn)
        }
        // 原 pullToRefresh 体（触觉改由 scrollViewDidEndDragging 给一次，见下）：
        // G16：刷新时先保存选中日（reloadTimeline keepDay 分支内保留），
        // 跳过当日拉取，只拉一次最终选中日；不再先拉今天再拉回原选中日。
        // 第 2 项 A 调用点 2/2（下拉刷新）：keepSelectedDay 下守卫接在刷新
        // 完成后——当日/月份回包到达时消费本标志，选中日已空即跳最近有篇日。
        pendingEntryJumpCheck = true
        reloadTimeline(keepSelectedDay: true)
        // fixall-sync 5-27 集成接线：被守卫挡下的同步在下拉刷新时重跑（内部去重已覆盖已同步/在途）。
        BearyEntrySync.shared.kickForCurrentUser()
        refreshHeaderHeight()
    }

    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing {
            return
        }
        isCustomPullRefreshing = false
        let baseTop = view.safeAreaInsets.top + (headerTopInsetVisible ? 60 : 0)
        let baseBottom = 90 + view.safeAreaInsets.bottom
        let pullOut = {
            self.tableView.contentInset.top = baseTop
            self.tableView.contentInset.bottom = baseBottom
            self.tableView.scrollIndicatorInsets.top = baseTop
            self.tableView.scrollIndicatorInsets.bottom = baseBottom
            self.tableView.contentOffset = CGPoint(x: 0, y: -baseTop)
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.refreshIconView.stopSpinning()
        } else {
            UIView.animate(withDuration: 0.32, animations: pullOut, completion: { _ in
                self.refreshIconView.stopSpinning()
            })
        }
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
        // iCity：1 秒 tick 只刷编辑倒计时文案（refreshCountdowns）；送达/待公开
        // 到点重拉机制已随送达模型一并删除，不再扫描 pending 子集。
        for cell in tableView.visibleCells {
            guard let timelineCell = cell as? BearyTimelineCell else { continue }
            timelineCell.refreshCountdowns()
        }
    }

    // MARK: - 表头搭建

    /// 追加项二：悬浮日期头搭建。样式与现有时间线组头一致（13 粗体灰、
    /// 左缩进 36、上下边距 18/8）；不透明底（BearyColors.bg 动态色）；
    /// 落在安全区下方（top 锚 safeAreaLayoutGuide）；本身不拦截触摸。
    private func setupStickyHeader() {
        // 容器钉在安全区顶沿、裁掉上滑出界的部分；显隐统一走容器，
        // 吸顶条自身不再单独 isHidden（容器藏即全藏）。
        stickyHeaderContainer.translatesAutoresizingMaskIntoConstraints = false
        stickyHeaderContainer.backgroundColor = .clear
        stickyHeaderContainer.isUserInteractionEnabled = false
        stickyHeaderContainer.clipsToBounds = true
        stickyHeaderContainer.isHidden = true
        view.addSubview(stickyHeaderContainer)
        NSLayoutConstraint.activate([
            stickyHeaderContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stickyHeaderContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyHeaderContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        stickyHeaderView.translatesAutoresizingMaskIntoConstraints = false
        stickyHeaderView.backgroundColor = BearyColors.bg
        stickyHeaderView.isUserInteractionEnabled = false
        stickyHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        stickyHeaderLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 13))
        stickyHeaderLabel.adjustsFontForContentSizeCategory = true
        stickyHeaderLabel.textColor = BearyColors.gray
        stickyHeaderLabel.numberOfLines = 1
        stickyHeaderLabel.isUserInteractionEnabled = false
        stickyHeaderView.addSubview(stickyHeaderLabel)
        stickyHeaderContainer.addSubview(stickyHeaderView)
        NSLayoutConstraint.activate([
            stickyHeaderView.topAnchor.constraint(equalTo: stickyHeaderContainer.topAnchor),
            stickyHeaderView.leadingAnchor.constraint(equalTo: stickyHeaderContainer.leadingAnchor),
            stickyHeaderView.trailingAnchor.constraint(equalTo: stickyHeaderContainer.trailingAnchor),
            stickyHeaderView.bottomAnchor.constraint(equalTo: stickyHeaderContainer.bottomAnchor),
            stickyHeaderLabel.topAnchor.constraint(equalTo: stickyHeaderView.topAnchor, constant: 18),
            stickyHeaderLabel.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor, constant: 36),
            stickyHeaderLabel.trailingAnchor.constraint(equalTo: stickyHeaderView.trailingAnchor, constant: -16),
            stickyHeaderLabel.bottomAnchor.constraint(equalTo: stickyHeaderView.bottomAnchor, constant: -8),
        ])
        statusBarBgView.translatesAutoresizingMaskIntoConstraints = false
        statusBarBgView.backgroundColor = BearyColors.bg
        statusBarBgView.isUserInteractionEnabled = false
        statusBarBgView.isHidden = true
        view.insertSubview(statusBarBgView, belowSubview: stickyHeaderContainer)
        NSLayoutConstraint.activate([
            statusBarBgView.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarBgView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarBgView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarBgView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    /// 追加项二：悬浮日期头跟随。位置跟随只走 transform、不做 UIView 动画
    /// （减动效下同样是跟随，无需分支）；日期变化时的新旧交替走
    /// animateStickyDateChange（同一 label 两段衔接，只动 transform/opacity，
    /// 减动效下直接换字）。顶替位移同样只动 transform，滚动回调不改约束、
    /// 不调 layoutIfNeeded，滑出部分由容器裁掉。
    /// 当前分区 = 组头已越过悬浮区顶沿、且分区底仍在顶沿下方的最末分区；
    /// 第 0 分区是当日面板时悬浮头全程不出现（面板组头可见时不重复，
    /// 面板行仍占顶时也不抢；面板整体滚出、后续分区接管时才出现）。
    /// 112：组头可见时悬浮头不叠加——current 只看组头顶沿是否越过悬浮区
    /// 顶沿，但组头本身仍占悬浮区时（组头正滑出悬浮区，或 rectForHeader
    /// 估算位置与实测位置有差、悬浮头提前亮起），悬浮头与组头会同屏显示
    /// 同一日期（如顶部悬浮“10 月 31 日”下方组头又显一次“10 月 31 日”）。
    /// 故加实测门控：能拿到 headerView 时用其 frame，否则回落
    /// rectForHeader；组头底沿仍在悬浮区顶沿下方（即组头仍与悬浮区重叠）
    /// 时隐藏悬浮头，组头底沿滑出悬浮区顶沿后悬浮头再接替显示（组头残影
    /// 若落在状态栏区，由随悬浮头同显的状态栏底色盖住）。日期文案与
    /// 分组/排序/分页逻辑不动，悬浮头本身不删。
    /// 下一分区组头顶进悬浮区时，吸顶条 transform.ty 随之变负、被顶上去
    /// （标准顶替；滑出容器顶沿的部分被裁掉，不改高度、不改约束）。
    private func updateStickyHeader() {
        guard tableView.window != nil else { hideStickyHeader(); return }
        let sections = currentSections()
        let count = min(tableView.numberOfSections, sections.count)
        guard count > 0 else { hideStickyHeader(); return }
        let top = tableView.contentOffset.y + view.safeAreaInsets.top
        // 顶替贴合点取吸顶条实测高度（布局后即准），未布局时回落字体算式。
        let headerHeight = stickyHeaderView.bounds.height > 0
            ? stickyHeaderView.bounds.height
            : 18 + ceil(stickyHeaderLabel.font.lineHeight) + 8
        let bottom = top + headerHeight
        var current: Int?
        for index in 0..<count {
            let headerTop = tableView.rectForHeader(inSection: index).minY
            let sectionBottom = tableView.rect(forSection: index).maxY
            if headerTop <= top && sectionBottom > top {
                current = index
            }
        }
        guard let current = current, current < sections.count else { hideStickyHeader(); return }
        // 当日面板分区（第 0 分区 + 选中日存在）永不进悬浮头。
        if current == 0 && selectedDayKey != nil { hideStickyHeader(); return }
        // 112 组头可见门控：当前分区自己的组头仍与悬浮区重叠时不亮悬浮头，
        // 组头底沿滑出悬浮区顶沿后才接替。实测 frame 优先（headerView 仅在
        // 组头真实显示时返回，不受估算行高影响）；取不到时回落 rectForHeader。
        // 坐标均为表内容坐标：top 即悬浮区顶沿对应的内容坐标。
        let currentHeaderRect: CGRect
        if let headerView = tableView.headerView(forSection: current) {
            currentHeaderRect = headerView.frame
        } else {
            currentHeaderRect = tableView.rectForHeader(inSection: current)
        }
        if currentHeaderRect.maxY > top {
            hideStickyHeader()
            return
        }
        let title = sections[current].title
        if stickyHeaderCurrentSection != current || stickyHeaderCurrentTitle != title {
            animateStickyDateChange(to: title)
            stickyHeaderCurrentSection = current
            stickyHeaderCurrentTitle = title
        }
        var offset: CGFloat = 0
        let next = current + 1
        if next < count {
            let nextHeaderTop = tableView.rectForHeader(inSection: next).minY
            if nextHeaderTop < bottom {
                offset = nextHeaderTop - bottom
            }
        }
        // 顶替只动 transform：立即生效、不触发布局，滚动回调不改约束；
        // 滑出容器顶沿的部分由容器裁掉，不进状态栏区。换日时旧条已被全裁
        // （不可见），位移归零无可见跳变。
        if stickyHeaderView.transform.ty != offset {
            stickyHeaderView.transform = CGAffineTransform(translationX: 0, y: offset)
        }
        if stickyHeaderContainer.isHidden {
            stickyHeaderContainer.isHidden = false
            statusBarBgView.isHidden = false
        }
    }

    /// 吸顶日期换日动效：旧日期上滑淡出、新日期从下方滑入淡入，同时走、
    /// 吸顶日期换日动效：同一 label 两段衔接、只动 transform/opacity。
    /// 旧日期上滑淡出（0.12s easeIn）→ 在 alpha=0 时换字 → 新日期从下方
    /// 滑入淡入（0.13s easeOut），总时长仍 0.25s；任何时刻只显示一个日期，
    /// 相邻日期文案仅差一字时也不再出现双字重影。快速连续换日时新退场以
    /// beginFromCurrentState 从当前呈现态平滑反向（不 snap）；只有最后一段
    /// 退场完成时才换字，中途被取代的退场 completion 以 finished=false 回调、
    /// 跳过换字，不闪中间日期。减动效下直接换字。
    private func animateStickyDateChange(to title: String) {
        let wasHidden = stickyHeaderContainer.isHidden
        if UIAccessibility.isReduceMotionEnabled {
            stickyHeaderLabel.layer.removeAllAnimations()
            stickyHeaderLabel.transform = .identity
            stickyHeaderLabel.alpha = 1
            stickyHeaderLabel.text = title
            return
        }
        if wasHidden {
            // 首次出现（刚从隐藏恢复）：容器尚不可见，打断复位无可见 snap；
            // 只有出场（从下方滑入淡入），无旧日期可退。
            stickyHeaderLabel.layer.removeAllAnimations()
            stickyHeaderLabel.transform = .identity
            stickyHeaderLabel.alpha = 1
            stickyHeaderLabel.text = title
            stickyHeaderLabel.transform = CGAffineTransform(translationX: 0, y: 8)
            stickyHeaderLabel.alpha = 0
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                self.stickyHeaderLabel.transform = .identity
                self.stickyHeaderLabel.alpha = 1
            }
            return
        }
        // 可见态换日：不 removeAllAnimations（那会把呈现态 snap 回模型态），
        // 新退场直接从当前呈现态起手；被取代的旧退场 completion 以
        // finished=false 回调、跳过换字。
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.stickyHeaderLabel.transform = CGAffineTransform(translationX: 0, y: -8)
            self.stickyHeaderLabel.alpha = 0
        } completion: { finished in
            guard finished else { return }
            // 此时 alpha=0：换字与 transform 复位（上滑终态 -8 → 下方 +8）
            // 均不可见，入场从 +8 滑回静止态，静止 frame 与基线与换日前一致。
            self.stickyHeaderLabel.text = title
            self.stickyHeaderLabel.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(withDuration: 0.13, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.stickyHeaderLabel.transform = .identity
                self.stickyHeaderLabel.alpha = 1
            }
        }
    }

    private func hideStickyHeader() {
        if stickyHeaderContainer.isHidden == false {
            stickyHeaderContainer.isHidden = true
        }
        statusBarBgView.isHidden = true
        stickyHeaderCurrentSection = nil
        stickyHeaderCurrentTitle = nil
        // 隐藏时在途动效一律打断并复位（此时容器不可见，无 snap 可见），
        // 顶替位移同步归零，不留残影与残位移给下次出现。
        stickyHeaderLabel.layer.removeAllAnimations()
        stickyHeaderLabel.transform = .identity
        stickyHeaderLabel.alpha = 1
        stickyHeaderView.transform = .identity
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        updateCustomPullIndicator()
        updateStickyHeader()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === tableView else { return }
        // 自定义下拉触发（消息页同款）：手指原始行程满 205px 松手才刷新。
        // M12（91 包）：触发给一次轻触觉；程序触发的刷新不走这里。
        let panTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 205 && timelineState != .loading && !isCustomPullRefreshing {
            BearyHaptics.press()
            beginCustomPullRefresh()
        }
    }

    private func buildHeader() {
        headerContainer.backgroundColor = BearyColors.bg

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "时间线"
        // R8：控制器自有正文类标签走 scaledFont + adjusts。
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 19))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink

        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.backgroundColor = BearyColors.faint
        trashButton.layer.cornerRadius = 17
        trashButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 16) {
            trashButton.setImage(trashImage, for: .normal)
        }
        // 回收站图标防压扁：按钮 imageView 默认 scaleToFill，受挤压即失真，
        // 显式 aspectFit + 方形图，任何压缩都不改变宽高比。
        trashButton.imageView?.contentMode = .scaleAspectFit
        trashButton.tintColor = BearyColors.ink
        trashButton.imageEdgeInsets = UIEdgeInsets.zero
        trashButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        // pill 宽度不得被 stack 压缩（否则图标被 aspectFit 缩小、标题中部截断）。
        trashButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // R8：回收站按钮标题走 scaledFont（见 updateTrashTitle 各段属性）+ adjusts。
        // 标题万一再溢出也只尾部截断，不中部截断（UIButton 默认中部截断即“回…12篇”的样子）。
        trashButton.titleLabel?.lineBreakMode = .byTruncatingTail
        trashButton.titleLabel?.adjustsFontForContentSizeCategory = true
        trashButton.addTarget(self, action: #selector(didTapTrash), for: .touchUpInside)
        trashButton.bearyAddPressFeedback()
        updateTrashTitle()

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, trashButton])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.distribution = .equalSpacing

        countsLabel.translatesAutoresizingMaskIntoConstraints = false
        // R8：统计行文字（正文类）走 scaledFont + adjusts。
        countsLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        countsLabel.adjustsFontForContentSizeCategory = true
        countsLabel.textColor = BearyColors.gray

        statsButton.translatesAutoresizingMaskIntoConstraints = false
        statsButton.contentHorizontalAlignment = .left
        // R8：统计行按钮走 scaledFont + adjusts（富文本各段见 updateStatsLine）。
        statsButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5))
        statsButton.titleLabel?.adjustsFontForContentSizeCategory = true
        statsButton.addTarget(self, action: #selector(didTapStats), for: .touchUpInside)
        statsButton.bearyAddPressFeedback()
        // P2：统计行初态不可点（无文案、无重试可做）；失败态由
        // updateStatsLine 重新启用，正常态保持禁用。
        statsButton.isEnabled = false

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
        calendarCard.onGoToday = { [weak self] in
            self?.goToToday()
        }

        // 盲盒入口行插在标题行与统计行之间（随表头一起滚走，不常驻占位）。
        let stack = UIStackView(arrangedSubviews: [titleRow, blindBoxEntryView, countsLabel, statsButton, calendarCard])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.setCustomSpacing(4, after: titleRow)
        stack.setCustomSpacing(12, after: blindBoxEntryView)
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

    /// 表头高度待重算：refreshHeaderHeight 在表宽为 0 时置位，
    /// 宽一就绪即由 viewDidLayoutSubviews 消费重算，不静默丢弃。
    private var headerHeightNeedsRefresh = false

    private func refreshHeaderHeight() {
        let width = tableView.bounds.width
        guard width > 0 else {
            headerHeightNeedsRefresh = true
            return
        }
        headerHeightNeedsRefresh = false
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
    /// 6-3 例外（日历高度部分，定版不改 transform）：表头高度本身就是
    /// tableHeaderView 的布局高度，表体各行必须随高度差整体平移——只对
    /// calendarCard 做 scaleY 会把格子/日期圆压扁（30pt 圆、50pt 行高失真），
    /// 只做平移 + 裁剪则新月多出的行会被裁掉、或与表体行重叠；高度差只能
    /// 由 frame + layoutIfNeeded 带过去。卡片自身的淡入/横移仍只动
    /// alpha/transform，不在此例外内。删行高度收起不在本文件（回收站
    /// 文件，#5 批已定例外），此处不动。
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
            UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState], animations: {
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

    /// 回收站标题上次渲染的计数值（本批新规矩：数值不变不重建标题；
    /// 数值变时只动“ N篇”数字段，静态段“回收站”不动，见 updateTrashSuffixOnly）。
    private var lastTrashCount: Int?
    /// 回收站 pill 宽度下限约束：按钮 intrinsic 会把双段富文本标题算短约 2pt
    /// （13.5/12.5 双字号，浮点尾巴），标题在 68pt 标签里差 2pt 即中部截断；
    /// 本约束按标题实测宽重算，保证按钮永远不比内容窄（≥ 约束，只扩不缩）。
    private var trashButtonMinWidthConstraint: NSLayoutConstraint?

    private func fitTrashButtonWidth() {
        guard let title = trashButton.attributedTitle(for: .normal) else { return }
        let titleWidth = title.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        ).width
        // 按钮宽 = 左右内边距 20 + 图标 16 + 图文间距 6 + 标题实宽（向上取整盖住浮点尾巴）。
        let needed = ceil(titleWidth) + 20 + 16 + 6
        if let c = trashButtonMinWidthConstraint {
            c.constant = needed
        } else {
            let c = trashButton.widthAnchor.constraint(greaterThanOrEqualToConstant: needed)
            c.isActive = true
            trashButtonMinWidthConstraint = c
        }
    }

    private func updateTrashTitle() {
        // P1-26：回收站钮按功能命名（计数同步更新，含数字段-only 与
        // 数值不变提前返回两路——标签放在所有返回之前，不会被短路漏掉）。
        trashButton.accessibilityLabel = trashCountValue > 0 ? "回收站，\(trashCountValue)篇" : "回收站"
        if let last = lastTrashCount, last == trashCountValue,
           trashButton.attributedTitle(for: .normal) != nil {
            return
        }
        if let last = lastTrashCount,
           let current = trashButton.attributedTitle(for: .normal),
           updateTrashSuffixOnly(current, oldCount: last, newCount: trashCountValue) {
            lastTrashCount = trashCountValue
            fitTrashButtonWidth()
            return
        }
        let base = NSMutableAttributedString(string: "回收站", attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5)),
            .foregroundColor: BearyColors.ink,
        ])
        if trashCountValue > 0 {
            base.append(NSAttributedString(string: " \(trashCountValue)篇", attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5)),
                .foregroundColor: BearyColors.gray,
            ]))
        }
        trashButton.setAttributedTitle(base, for: .normal)
        lastTrashCount = trashCountValue
        fitTrashButtonWidth()
    }

    /// 回收站标题数字段-only 更新：静态段“回收站”不动，只增/改/删
    /// 尾段“ N篇”。旧标题格式对不上时返回 false，调用方回落整行重建。
    private func updateTrashSuffixOnly(_ current: NSAttributedString, oldCount: Int, newCount: Int) -> Bool {
        let prefix = "回收站"
        let full = current.string
        guard full.hasPrefix(prefix) else { return false }
        let nsFull = full as NSString
        let prefixLength = (prefix as NSString).length
        let expectedOldSuffix = oldCount > 0 ? " \(oldCount)篇" : ""
        guard nsFull.substring(from: prefixLength) == expectedOldSuffix else { return false }
        let mutable = NSMutableAttributedString(attributedString: current)
        if newCount > 0 {
            let suffixAttributes: [NSAttributedString.Key: Any] = [
                .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5)),
                .foregroundColor: BearyColors.gray,
            ]
            if oldCount > 0 {
                let range = NSRange(location: prefixLength, length: nsFull.length - prefixLength)
                mutable.replaceCharacters(in: range, with: " \(newCount)篇")
                mutable.addAttributes(suffixAttributes, range: NSRange(location: prefixLength, length: (" \(newCount)篇" as NSString).length))
            } else {
                mutable.append(NSAttributedString(string: " \(newCount)篇", attributes: suffixAttributes))
            }
        } else if oldCount > 0 {
            let range = NSRange(location: prefixLength, length: nsFull.length - prefixLength)
            mutable.deleteCharacters(in: range)
        } else {
            return true
        }
        trashButton.setAttributedTitle(mutable, for: .normal)
        return true
    }

    private func updateCountsLabel() {
        if let counts = countsValue {
            let total = counts.total ?? 0
            let priv = counts.priv ?? 0
            let pub = counts.pub ?? 0
            // 本批新规矩（跳过未变）：纯文本 label 无容器重建、无入场动效，
            // 文案不变时不重复赋值；数值变时仍整行文本赋值（UILabel 文本
            // 本身不重播动效，拆成多 label 属布局结构改动，不做）。
            let newText = "共 \(total) 篇 · 私密 \(priv) · 公开 \(pub)"
            guard countsLabel.text != newText else { return }
            countsLabel.text = newText
        } else {
            guard countsLabel.text != "" else { return }
            countsLabel.text = ""
        }
    }

    /// 64 包反馈修（第 3 项）：写新日记后统计行失效——清已渲染签名并丢掉当前视图月份缓存，
    /// 使随后 reloadTimeline 的非强制月份拉取真正走网络（否则缓存命中、统计恒旧）。
    /// 切日期、翻页、删除、恢复均不调本方法（删除/恢复走强制重拉 + 签名比对）。
    func invalidateStatsLine() {
        lastStatsLineSignature = nil
        lastStatsStreak = nil
        lastStatsMonthTotal = nil
        for key in monthKeysForCurrentView() {
            calendarCache.removeValue(forKey: key)
        }
    }
    private var lastStatsLineSignature: String?
    /// 统计行上次渲染的数值（与签名分离：数值段替换时也要同步，供下次比对）。
    private var lastStatsStreak: Int?
    private var lastStatsMonthTotal: Int?

    /// 连续写作行：网页 .cal-stats（13.5 灰、数字墨色加粗、16pt 橙色火苗图标）。
    /// 火苗图为本批新建的 icon_fire 资产（beary.html #beary-fire sprite 路径渲染）。
    /// 任一可视月份失败时整行变重试入口（G14）；在途/缺失月份不出加载态（无“日历加载中…”）。
    private func updateStatsLine() {
        let primaryKey = primaryStatsMonthKey()
        let visibleKeys = monthKeysForCurrentView()
        let anyVisibleFailed = visibleKeys.contains { calendarFailed.contains($0) && calendarCache[$0] == nil }
        if anyVisibleFailed {
            // P2：失败态是唯一可点态（重试入口），保持启用 + 按压反馈；
            // P1-26：按功能命名（与可见文案一致）。
            statsButton.isEnabled = true
            statsButton.accessibilityLabel = "日历加载失败，重试"
            // 64 包反馈修（第 3 项）：失败态亦计签名，一致则不重碰按钮。
            let signature = "fail"
            guard signature != lastStatsLineSignature else { return }
            lastStatsLineSignature = signature
            lastStatsStreak = nil
            lastStatsMonthTotal = nil
            statsButton.setImage(nil, for: .normal)
            statsButton.setAttributedTitle(nil, for: .normal)
            statsButton.setTitle("日历加载失败，重试", for: .normal)
            statsButton.setTitleColor(BearyColors.gray, for: .normal)
            return
        }
        guard let primaryKey = primaryKey, let data = calendarCache[primaryKey] else {
            // P2：空态无内容、无重试可做，与正常态同为不可点。
            statsButton.isEnabled = false
            statsButton.accessibilityLabel = nil
            let signature = "empty"
            guard signature != lastStatsLineSignature else { return }
            lastStatsLineSignature = signature
            lastStatsStreak = nil
            lastStatsMonthTotal = nil
            statsButton.setImage(nil, for: .normal)
            statsButton.setAttributedTitle(nil, for: .normal)
            statsButton.setTitle("", for: .normal)
            return
        }
        // 本批新规矩：签名不含月份 key——切月数值不变直接返回，按钮一字不动
        // （确诊：旧签名 "\(primaryKey)|streak|monthTotal"，切月必变签名 →
        // 整行 setAttributedTitle 重建 → 闪；容器/表头在此路径下本就不重建，
        // 闪只来自本行标题重建，不是 stepCalendar/renderCalendar 重建容器）。
        // 数值真变时只换数字段（下分支），静态段与火苗图标一律不动。
        let streak = data.streak ?? 0
        let monthTotal = data.monthTotal ?? 0
        // P2：正常态不可点——禁用即去掉按压反馈（touchDown 缩放/震动
        // 只在启用钮上触发），didTapStats 的重试逻辑只在失败态可达；
        // P1-26：无障碍名与可见统计文案一致。
        statsButton.isEnabled = false
        statsButton.accessibilityLabel = "已连续写 \(streak) 天，本月共 \(monthTotal) 篇"
        if lastStatsLineSignature == "normal", lastStatsStreak == streak, lastStatsMonthTotal == monthTotal {
            return
        }
        if lastStatsLineSignature == "normal",
           let current = statsButton.attributedTitle(for: .normal),
           updateStatsNumbersOnly(current, streak: streak, monthTotal: monthTotal) {
            lastStatsLineSignature = "normal"
            lastStatsStreak = streak
            lastStatsMonthTotal = monthTotal
            return
        }
        // 首建或态切换（失败/空态 → 正常）或数字段解析失败时才整行重建；
        // 数字段解析失败回落整行是防残留旧格式的安全阀，不是常规路径。
        lastStatsLineSignature = "normal"
        lastStatsStreak = streak
        lastStatsMonthTotal = monthTotal
        statsButton.setImage(BearyIconImages.image(named: "icon_fire", pointSize: 16), for: .normal)
        statsButton.tintColor = BearyColors.orange
        statsButton.imageEdgeInsets = UIEdgeInsets.zero
        statsButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        // R8：统计行富文本各段走 scaledFont（按钮 adjusts 开关见 buildHeader）。
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5)),
            .foregroundColor: BearyColors.gray,
        ]
        let boldAttributes: [NSAttributedString.Key: Any] = [
            .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 13.5)),
            .foregroundColor: BearyColors.ink,
        ]
        let text = NSMutableAttributedString(string: "已连续写 ", attributes: baseAttributes)
        text.append(NSAttributedString(string: "\(streak) 天", attributes: boldAttributes))
        text.append(NSAttributedString(string: " · 本月共 ", attributes: baseAttributes))
        text.append(NSAttributedString(string: "\(monthTotal) 篇", attributes: boldAttributes))
        statsButton.setTitle(nil, for: .normal)
        statsButton.setAttributedTitle(text, for: .normal)
    }

    /// 统计行数字段-only 更新：只替换两处纯数字区间（streak、monthTotal），
    /// 静态段“已连续写 ”、“ 天 · 本月共 ”、“ 篇”与火苗图标原样不动（不重建
    /// 整行 attributed 文案、不碰 image/tint）。格式对不上（旧格式残留、
    /// 数字段非纯数字）时返回 false，调用方回落整行重建。
    /// 区间用 NSString（UTF-16）定位：文案固定中文 + 阿拉伯数字，均为 BMP
    /// 字符，NSString 长度与 NSRange 定位一致；先换后段（monthTotal）再换
    /// 前段（streak），使前段位置不受后段长度变化影响。
    private func updateStatsNumbersOnly(_ current: NSAttributedString, streak: Int, monthTotal: Int) -> Bool {
        let prefix = "已连续写 "
        let middle = " 天 · 本月共 "
        let suffix = " 篇"
        let full = current.string
        guard full.hasPrefix(prefix), full.hasSuffix(suffix) else { return false }
        let nsFull = full as NSString
        let prefixLength = (prefix as NSString).length
        let middleLength = (middle as NSString).length
        let suffixLength = (suffix as NSString).length
        let middleRange = nsFull.range(of: middle)
        guard middleRange.location != NSNotFound else { return false }
        let streakRange = NSRange(location: prefixLength, length: middleRange.location - prefixLength)
        let totalRange = NSRange(
            location: middleRange.location + middleRange.length,
            length: nsFull.length - suffixLength - (middleRange.location + middleRange.length)
        )
        guard streakRange.length > 0, totalRange.length > 0 else { return false }
        guard Int(nsFull.substring(with: streakRange)) != nil,
              Int(nsFull.substring(with: totalRange)) != nil else { return false }
        let boldAttributes: [NSAttributedString.Key: Any] = [
            .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 13.5)),
            .foregroundColor: BearyColors.ink,
        ]
        let mutable = NSMutableAttributedString(attributedString: current)
        let newStreakText = "\(streak)"
        let newTotalText = "\(monthTotal)"
        mutable.replaceCharacters(in: totalRange, with: newTotalText)
        mutable.replaceCharacters(in: streakRange, with: newStreakText)
        let newStreakRange = NSRange(location: prefixLength, length: (newStreakText as NSString).length)
        let newTotalRange = NSRange(
            location: prefixLength + (newStreakText as NSString).length + middleLength,
            length: (newTotalText as NSString).length
        )
        mutable.addAttributes(boldAttributes, range: newStreakRange)
        mutable.addAttributes(boldAttributes, range: newTotalRange)
        statsButton.setAttributedTitle(mutable, for: .normal)
        return true
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
        timelineFirstPageSeq += 1
        let seq = timelineFirstPageSeq
        timelineState = .loading
        updateChrome()
        // M2：已有行只更新变化行——刷新前记下旧分区，成功后若分区结构（日期键序列）
        // 不变则按行 diff 插删改，否则回落整表 reloadData（首屏旧表为空时同样 reloadData）。
        let oldSections = currentSections()
        let hadOldRows = timelineEntries.isEmpty == false
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: pageLimit) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 旧回包直接丢弃（见 timelineFirstPageSeq 注释）：表与模型均已由新加载接管。
                // 卡死路径修法：丢弃时仍结束刷新指示（只跳过模型更新），不让
                // “旧请求被取代”等于“刷新头永不结束”；后续新加载的完成分支
                // 因旗标已清而 no-op，不会二次复位。
                guard seq == strongSelf.timelineFirstPageSeq else {
                    strongSelf.refreshIconView.stopSpinning()
                    strongSelf.endCustomPullRefresh()
                    return
                }
                switch result {
                case .success(let list):
                    strongSelf.timelineEntries = list.entries ?? []
                    // B-G7: patch the day-panel copy from the fresh timeline copy
                    // before diff/reload, so both copies render the same state.
                    strongSelf.dayEntries = strongSelf.patchedEntries(strongSelf.dayEntries, withFresh: strongSelf.timelineEntries)
                    strongSelf.trashCountValue = list.trashCount ?? 0
                    strongSelf.countsValue = list.tlCounts
                    strongSelf.timelineHasMore = (list.entries ?? []).count >= strongSelf.pageLimit
                    // 110：首屏成功即写时间线缓存（下次冷启动缓存优先；
                    // 只在已登录时写，避免游客态写 guest 桶；失败不写）。
                    if let uid = SessionManager.shared.currentUser?.id {
                        BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: strongSelf.timelineEntries, hasMore: strongSelf.timelineHasMore, trashCount: strongSelf.trashCountValue, counts: strongSelf.countsValue)
                    }
                    strongSelf.timelineState = .loaded
                    strongSelf.timelinePageFailed = false
                    strongSelf.updateTrashTitle()
                    strongSelf.updateCountsLabel()
                    // 同上：计数写入后重算表头高度，防统计行被压缩裁剪。
                    strongSelf.refreshHeaderHeight()
                case .failure(let error):
                    strongSelf.timelineState = .failed
                    if case .unauthorized = error {
                        strongSelf.timelineUnauthorized = true
                    }
                }
                if case .success = result, hadOldRows, strongSelf.tableView.window != nil,
                   strongSelf.applyFirstPageDiff(oldSections: oldSections) {
                    // diff 已插删改，跳过整表重载。
                } else {
                    strongSelf.tableView.reloadData()
                }
                strongSelf.updateChrome()
                if strongSelf.isCustomPullRefreshing {
                    // 自定义下拉至少展示 500ms（消息页同款），快回包也要等满再收回。
                    let elapsed = strongSelf.customPullStartTime.map({ Date().timeIntervalSince($0) }) ?? 0.5
                    let remaining = max(0, 0.5 - elapsed)
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        strongSelf.endCustomPullRefresh()
                    }
                } else {
                    strongSelf.refreshIconView.stopSpinning()
                }
                completion?()
            }
        }
    }

    /// 首屏刷新行 diff：分区键序列必须全等、每行必须有唯一 id，
    /// 任一异常即返回 false 由调用方回落 reloadData，绝不带病插删。
    private func applyFirstPageDiff(oldSections: [DaySection]) -> Bool {
        // 纵深校验：diff 的前提是表当前仍显示 oldSections。首屏加载与分页追加/
        // 选日重载交错时，模型新旧快照可能一致但表已被改写（计数对不上即
        // Invalid_Batch_Updates）；计数不符一律回落 reloadData，绝不带病批更新。
        // numberOfSections/numberOfRows 取表当前已渲染态（非数据源实时查询），
        // 故能反映 reloadData/批更新后的表状态。
        guard tableView.numberOfSections == oldSections.count else { return false }
        for section in 0..<oldSections.count {
            guard tableView.numberOfRows(inSection: section) == oldSections[section].entries.count else { return false }
        }
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
        // 80 包 A2-3①：首屏 diff 新增行同样走错峰队列（willDisplay 起播），故插行
        // 动画用 .none、由 willDisplay 统一入场；减动效时保持 .fade。
        let staggerFirstPage = UIAccessibility.isReduceMotionEnabled == false && !inserts.isEmpty
        if staggerFirstPage {
            staggerInsertOrder = Dictionary(uniqueKeysWithValues: inserts.enumerated().map { ($0.element, $0.offset) })
            staggerQueueGeneration = staggerGeneration
        }
        tableView.performBatchUpdates({
            if !deletes.isEmpty { self.tableView.deleteRows(at: deletes, with: .fade) }
            if !inserts.isEmpty { self.tableView.insertRows(at: inserts, with: staggerFirstPage ? .none : .fade) }
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
        // 批 E 补漏：签名此前不含定位——只改定位（编辑加定位、清定位、翻
        // 可见性改脱敏）的静默刷新会被判“无变化”而跳过重载，位置行恒旧。
        return "\(entry.content ?? "")|\(entry.isPublic ?? false)|\(entry.likeCount ?? 0)|\(entry.likedByMe ?? false)|\(entry.bookmarkedByMe ?? false)|\(emoteParts.joined(separator: ","))|\(entry.locationName ?? "")|\(entry.locationDistrict ?? "")"
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
        // 80 包 A3：分页代际（首屏 timelineFirstPageSeq 同口径）——首屏重拉即作废在途分页。
        let nextPageSeq = timelineFirstPageSeq
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: pageLimit, before: lastCreated, beforeId: lastEntryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.timelineLoadingMore = false
                // 80 包 A3：离页（容器切页改 isHidden）或首屏已重拉时丢弃分页回包，
                // 只复位 loading 标记，不动模型与表。
                guard strongSelf.view.window != nil, strongSelf.view.isHidden == false,
                      nextPageSeq == strongSelf.timelineFirstPageSeq else { return }
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
                    if let diff = strongSelf.appendedPageDiff(oldSections: oldSections),
                       strongSelf.tableView.window != nil {
                        // 减动效时不排错峰队列，直接插行终值。
                        if UIAccessibility.isReduceMotionEnabled == false {
                            strongSelf.staggerInsertOrder = Dictionary(uniqueKeysWithValues: diff.stagger.enumerated().map { ($0.element, $0.offset) })
                            strongSelf.staggerQueueGeneration = strongSelf.staggerGeneration
                        }
                        strongSelf.tableView.performBatchUpdates({
                            if !diff.sections.isEmpty { strongSelf.tableView.insertSections(diff.sections, with: .none) }
                            if !diff.rows.isEmpty { strongSelf.tableView.insertRows(at: diff.rows, with: .none) }
                        }, completion: nil)
                    } else {
                        strongSelf.tableView.reloadData()
                    }
                case .failure:
                    // G15：分页失败 toast，并保持脚部可重试（hasMore 不动、
                    // updateFooter 出“加载失败，重试”）。
                    strongSelf.timelinePageFailed = true
                    strongSelf.showTimelineToast(message: "加载失败")
                }
                strongSelf.updateChrome()
            }
        }
    }

    /// 分页追加的行 diff：追加页只能出现在尾部分区（旧分区键序列必须是新分区的前缀，
    /// 旧分区内旧行 id 顺序不变且新增行只在分区尾部），否则返回 nil 回落 reloadData。
    /// 分页追加 diff：返回旧分区尾部追加行 + 新增分区 + 全部新增行（供错峰映射）。
    /// 88 包 H3：新分区必须先插区、其行随区而来，不再单独插行——只插行属非法更新。
    private func appendedPageDiff(oldSections: [DaySection]) -> (rows: [IndexPath], sections: IndexSet, stagger: [IndexPath])? {
        let newSections = currentSections()
        guard newSections.count >= oldSections.count else { return nil }
        var rows: [IndexPath] = []
        var stagger: [IndexPath] = []
        for section in 0..<oldSections.count {
            guard oldSections[section].dayKey == newSections[section].dayKey else { return nil }
            let oldRows = oldSections[section].entries
            let newRows = newSections[section].entries
            guard newRows.count >= oldRows.count else { return nil }
            for row in 0..<oldRows.count {
                guard oldRows[row].id != nil, oldRows[row].id == newRows[row].id else { return nil }
            }
            for row in oldRows.count..<newRows.count {
                let ip = IndexPath(row: row, section: section)
                rows.append(ip)
                stagger.append(ip)
            }
        }
        var sections = IndexSet()
        for section in oldSections.count..<newSections.count {
            sections.insert(section)
            for row in 0..<newSections[section].entries.count {
                stagger.append(IndexPath(row: row, section: section))
            }
        }
        return (rows, sections, stagger)
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
                    // 翻页失败清挂起：残留 pendingStepFollow 不得在之后某次
                    // 月份到达时把用户新点选的日子意外移走（网页失败恢复原选区
                    // 同口径；App 选区在跟随落定前本就未动，故只清挂起、不动选区）。
                    strongSelf.pendingStepFollow = false
                }
                strongSelf.updateStatsLine()
                strongSelf.renderCalendar()
                strongSelf.refreshHeaderHeight()
                // 第 3/4 项：月份到达后先解翻页跟随（若仍挂起则跳过守卫，
                // 避免守卫把选区跳回旧月），跟随落定后再跑 calFixSel 守卫。
                if strongSelf.pendingStepFollow {
                    if strongSelf.tryStepFollowSelection() && strongSelf.pendingFixSelCheck {
                        _ = strongSelf.checkFixSelForSelectedDay()
                    }
                } else if strongSelf.pendingFixSelCheck {
                    _ = strongSelf.checkFixSelForSelectedDay()
                } else if strongSelf.pendingEntryJumpCheck {
                    // 第 2 项 A：初次进入 / 下拉刷新守卫在月份回包处消费。
                    // 翻页跟随挂起时走上一分支，本分支不抢翻页选区。
                    _ = strongSelf.checkEntryJumpForSelectedDay()
                }
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
        updateCalendarTodayButton()
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
        // 只发未缓存/未在途的月份）；在途时统计行不出加载态。
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

    /// 第 3 项翻周/翻月选区跟随（网页 calFlipPending 口径）：
    /// 在新周/月内先找锚点日，再全部往前、再全部往后（与 calFixSel 的
    /// 先往前再往后一致，不按距离交替）找最近有篇日，找到即重定选区并
    /// 重拉当日面板；新视图月份缓存未到齐时返回 false、挂起待月份到达后重试；
    /// 新视图内全无有篇日时返回 true（落定、保留原选区，不清选区）。
    /// 锚点：周模式 = 新锚点日；月模式 = 原选中日的“日号”落到新月（超月长则截断）。
    private func tryStepFollowSelection() -> Bool {
        guard selectedDayKey != nil else {
            pendingStepFollow = false
            return true
        }
        var candidateDays: [(year: Int, month: Int, day: Int)] = []
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { pendingStepFollow = false; return true }
            guard let monday = BearyBeijingDay.mondayOf(year: anchor.year, month: anchor.month, day: anchor.day) else { pendingStepFollow = false; return true }
            var weekDays: [(year: Int, month: Int, day: Int)] = []
            for offset in 0..<7 {
                guard let day = BearyBeijingDay.shifted(year: monday.year, month: monday.month, day: monday.day, byDays: offset) else { continue }
                weekDays.append(day)
            }
            // 缓存未到齐（周跨两月时两月都要有）则挂起。
            for day in weekDays {
                if calendarCache[BearyBeijingDay.monthKey(year: day.year, month: day.month)] == nil { return false }
            }
            guard let anchorIndex = weekDays.firstIndex(where: { $0.year == anchor.year && $0.month == anchor.month && $0.day == anchor.day }) else { pendingStepFollow = false; return true }
            candidateDays.append(weekDays[anchorIndex])
            // 网页口径：先全部往前（锚点前一日 → 周首日），再全部往后
            // （锚点后一日 → 周末日），不按距离交替。
            var backwardIndex = anchorIndex - 1
            while backwardIndex >= 0 {
                candidateDays.append(weekDays[backwardIndex])
                backwardIndex -= 1
            }
            var forwardIndex = anchorIndex + 1
            while forwardIndex < weekDays.count {
                candidateDays.append(weekDays[forwardIndex])
                forwardIndex += 1
            }
        case .month:
            guard let displayed = calendarDisplayedMonth else { pendingStepFollow = false; return true }
            guard calendarCache[BearyBeijingDay.monthKey(year: displayed.year, month: displayed.month)] != nil else { return false }
            guard let dim = BearyBeijingDay.daysInMonth(year: displayed.year, month: displayed.month) else { pendingStepFollow = false; return true }
            var anchorDay = calendarAnchor?.day ?? 1
            if let selected = selectedDayKey {
                let parts = selected.split(separator: "-")
                if parts.count == 3, let day = Int(parts[2]) { anchorDay = day }
            }
            anchorDay = min(max(anchorDay, 1), dim)
            candidateDays.append((displayed.year, displayed.month, anchorDay))
            // 网页口径：先全部往前（锚点日前一日 → 1 日），再全部往后
            // （锚点日后一日 → 月末日），不按距离交替。
            var backwardDay = anchorDay - 1
            while backwardDay >= 1 {
                candidateDays.append((displayed.year, displayed.month, backwardDay))
                backwardDay -= 1
            }
            var forwardDay = anchorDay + 1
            while forwardDay <= dim {
                candidateDays.append((displayed.year, displayed.month, forwardDay))
                forwardDay += 1
            }
        }
        for day in candidateDays {
            let counts = calendarDayCounts(year: day.year, month: day.month, day: day.day)
            if counts.published + counts.unpublished > 0 {
                pendingStepFollow = false
                selectDay(key: BearyBeijingDay.dayKey(year: day.year, month: day.month, day: day.day))
                return true
            }
        }
        pendingStepFollow = false
        return true
    }

    /// 第 4 项 calFixSel 通用守卫：选中日当月计数为 null（days 缺该日）
    /// 或 0 时触发；计数 > 0 时不触发并清挂起。月份缓存缺失时挂起并补拉，
    /// 到达后由 fetchCalendarMonth 回包重试，不直接取消选中。
    /// 返回 true 表示已执行跳转/取消（调用方应跳过后续重载），false 表示未触发或仍挂起。
    @discardableResult
    private func checkFixSelForSelectedDay() -> Bool {
        guard let key = selectedDayKey else {
            pendingFixSelCheck = false
            return false
        }
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            pendingFixSelCheck = false
            return false
        }
        let monthKey = BearyBeijingDay.monthKey(year: year, month: month)
        guard calendarCache[monthKey] != nil else {
            // 月份已失败则不再补拉（避免失败回包 → 守卫 → 再补拉的死循环）：
            // 挂起清掉、保留选区，统计行重试入口会重新拉取该月。
            if calendarFailed.contains(monthKey) {
                pendingFixSelCheck = false
                return false
            }
            pendingFixSelCheck = true
            fetchCalendarMonth(key: monthKey)
            return false
        }
        let counts = calendarDayCounts(year: year, month: month, day: day)
        if counts.published + counts.unpublished > 0 {
            pendingFixSelCheck = false
            return false
        }
        pendingFixSelCheck = false
        applyDayFixSel()
        return true
    }

    /// 第 2 项 A 初次进入 / 下拉刷新跳转守卫（checkFixSel 的同月口径、
    /// 但走独立挂起标志 pendingEntryJumpCheck，不碰 pendingFixSelCheck）：
    /// 选中日当月计数 > 0 不动；计数 0 时经 applyDayFixSel 同月先往前、
    /// 再往后找最近有篇日并跳过去，提示复用现成 jumpNote 机制
    /// （showJumpNote + viewForHeader 的“这天已没有日记，已跳到最近的一天”）；
    /// 同月全空时 applyDayFixSel 原有行为是取消选中 + toast“这天已没有日记”
    /// （无可跳之日，故无跳转提示）。缓存缺失时挂起并补拉该月，到达后由
    /// fetchCalendarMonth 回包的本守卫分支重试；月份已失败时清挂起、
    /// 保留选区（与 checkFixSel 同口径，防失败回包 → 守卫 → 再补拉死循环）。
    /// 返回 true 表示已执行跳转/取消（调用方应跳过后续重载），false 表示
    /// 未触发或仍挂起。翻页路径永不调用本函数（翻页全空保留原选区）。
    @discardableResult
    private func checkEntryJumpForSelectedDay() -> Bool {
        guard let key = selectedDayKey else {
            pendingEntryJumpCheck = false
            return false
        }
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            pendingEntryJumpCheck = false
            return false
        }
        let monthKey = BearyBeijingDay.monthKey(year: year, month: month)
        guard calendarCache[monthKey] != nil else {
            if calendarFailed.contains(monthKey) {
                pendingEntryJumpCheck = false
                return false
            }
            pendingEntryJumpCheck = true
            fetchCalendarMonth(key: monthKey)
            return false
        }
        let counts = calendarDayCounts(year: year, month: month, day: day)
        if counts.published + counts.unpublished > 0 {
            pendingEntryJumpCheck = false
            return false
        }
        pendingEntryJumpCheck = false
        applyDayFixSel()
        return true
    }

    private func stepCalendar(delta: Int) {
        var targetAnchor = calendarAnchor
        var targetDisplayed = calendarDisplayedMonth
        switch calendarMode {
        case .week:
            // 翻周锚点 = 点选日 + 7 天（网页 calFlip 以 calAnchor 为基；
            // 点选已同步 calendarAnchor，见 selectDay，但直接赋值选区/
            // 守卫路径可能让两者脱节，故翻周以点选日为准，点选缺失
            // 时才回落 calendarAnchor）。
            var base = calendarAnchor
            if let selected = selectedDayKey {
                let parts = selected.split(separator: "-")
                if parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
                    base = (year, month, day)
                }
            }
            guard let base = base else { return }
            // 下一周不许翻进未来：已是本周时 next 按钮本身已禁用，此处再拦一道。
            if delta > 0 {
                guard let monday = BearyBeijingDay.mondayOf(year: base.year, month: base.month, day: base.day) else { return }
                if isCurrentWeek(monday: monday) { return }
            }
            guard let moved = BearyBeijingDay.shifted(year: base.year, month: base.month, day: base.day, byDays: delta * 7) else { return }
            targetAnchor = moved
        case .month:
            guard let displayed = calendarDisplayedMonth else { return }
            if delta > 0 && isCurrentMonth(displayed: displayed) { return }
            guard let moved = BearyBeijingDay.shiftedMonth(year: displayed.year, month: displayed.month, byMonths: delta) else { return }
            targetDisplayed = moved
        }
        // 64 包反馈修（第 7 项）：翻页不再走 performCalendarTransition——旧路径先整卡
        // 淡出 + 横移、再淡回并重挂 tableHeaderView，表头整块（时间线顶部到日历图底部）
        // 肉眼可见闪一下；翻页只外科更新日历网格内容：锚点/月份直改、网格重渲（复用
        // 的日期钮不重播动效）、表头高度同步直设（refreshHeaderHeight 本就无动画），
        // 头部、统计、日历容器节点不重建、不重播动效。视图切换（周/月）仍走过渡动画。
        calendarAnchor = targetAnchor
        calendarDisplayedMonth = targetDisplayed
        // 第 3 项：锚点改完即挂起跟随；缓存已齐时当场跟随，
        // 未齐时月份到达后在 fetchCalendarMonth 回包里跟随。
        if selectedDayKey != nil {
            pendingStepFollow = true
        }
        fetchCalendarMonthsForCurrentView()
        if pendingStepFollow {
            _ = tryStepFollowSelection()
        }
        refreshHeaderHeight()
    }

    /// C10 “今”钮显隐：显示月份/周不含今天，或选中日不是今天时浮现；
    /// 回到今天后 renderCalendar 重算即隐藏。只读 anchor/displayed/
    /// selected，不改任何已有状态；renderCalendar 是唯一漏斗（翻页、
    /// 切换视图、月份回包、点选日全经此），故挂在末尾即全覆盖。
    private func updateCalendarTodayButton() {
        guard let today = BearyBeijingDay.todayComponents() else {
            calendarCard.setTodayButtonVisible(false)
            return
        }
        let todayKey = BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day)
        let containsToday: Bool
        switch calendarMode {
        case .week:
            if let anchor = calendarAnchor,
               let monday = BearyBeijingDay.mondayOf(year: anchor.year, month: anchor.month, day: anchor.day) {
                containsToday = isCurrentWeek(monday: monday)
            } else {
                containsToday = false
            }
        case .month:
            if let displayed = calendarDisplayedMonth {
                containsToday = isCurrentMonth(displayed: displayed)
            } else {
                containsToday = false
            }
        }
        calendarCard.setTodayButtonVisible(!containsToday || selectedDayKey != todayKey)
    }

    /// C10 回到今天：先把锚点与显示月归到今天（月视图下 selectDay
    /// 的同日分支不碰 displayed 月，光调它回不到当月；周视图下
    /// selectDay 本就同步锚点，此处同值无害），再复用 selectDay 切日
    /// + 补拉当月圆点，不另写切日路径。切日动效即现有口径：网格复用
    /// 钮不重播错峰、新格子走既有 0.25s / 0.03 步进错峰，不另加转场动画（翻页
    /// 64 包反馈修已定“只外科更新网格、不整卡转场”）。
    /// 手动点“今”作废翻页跟随挂起（与手动点选日作废定位挂起同口径），
    /// 防在途月份回包把选区跟回旧视图；reload 守卫挂起不动，与点选
    /// 当日格子同语义（见未决风险）。
    private func goToToday() {
        guard let today = BearyBeijingDay.todayComponents() else { return }
        pendingStepFollow = false
        calendarAnchor = (year: today.year, month: today.month, day: today.day)
        calendarDisplayedMonth = (year: today.year, month: today.month)
        selectDay(key: BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day))
        fetchCalendarMonthsForCurrentView()
    }

    // MARK: - 当日面板（TL-7/TL-8）

    private func didSelectCalendarDay(_ day: BearyCalendarDay) {
        selectDay(key: day.key)
    }

    /// TL-8：点已选中日不取消筛选，只重渲 + 重拉当日；
    /// E4-5：同日在途拉取未完成时不重复发请求。
    private func selectDay(key: String) {
        // 80 包 A2-3③：切日先清错峰队列并 +1 代际，旧队列条目不得在新日数据行上重播。
        staggerGeneration += 1
        clearStaggerEntries()
        // 6A 定位守卫：定位触发的切日保留 pending；用户手动切日即作废 pending。
        if locateDaySelection {
            locateDaySelection = false
        } else {
            pendingLocateEntryId = nil
            pendingLocateDayKey = nil
        }
        // 点选同步 calendarAnchor（网页周视图点选口径；此前点选不更新
        // 锚点是 bug：翻周基点会落在旧锚点而非点选日）。解析失败时不动锚点。
        // 重复点选同日也同步（修锚点漂移后重拍即回正）。
        let keyParts = key.split(separator: "-")
        if keyParts.count == 3, let year = Int(keyParts[0]), let month = Int(keyParts[1]), let day = Int(keyParts[2]) {
            calendarAnchor = (year, month, day)
        }
        if key == selectedDayKey {
            renderCalendar()
            // 本批 4b：打开当天面板不再整表 reloadData（已有时间线行会跟着重播/闪）——
            // 分区结构不变时只以 .fade 重载当日面板分区，守卫失败才回落整表。
            if !reloadDayPanelSectionIfStable() {
                tableView.reloadData()
            }
            fetchDayEntries(key: key, clear: false)
            return
        }
        let hadPanel = selectedDayKey != nil
        selectedDayKey = key
        renderCalendar()
        // N3：换日时日历标题淡入（仅非减动效；只动标题 alpha，不动高度）。
        if UIAccessibility.isReduceMotionEnabled == false && tableView.window != nil {
            calendarCard.fadeTitleForDaySwitch()
        }
        // N2+N3 换日提交：缓存命中即时显示 + 后台静默刷新；未命中走旧路
        // （先整表重载空面板、再等网络回包）。提交只执行一次：退场动画
        // 完成时若代际已变（用户又切了新日 / 清了选区），本次提交作废，
        // 由更新的 selectDay / 清选区流程接管，避免旧日数据盖掉新日。
        let switchGeneration = staggerGeneration
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let commitDaySwitch = { [weak self] in
            guard let self = self, self.staggerGeneration == switchGeneration, self.selectedDayKey == key else { return }
            // 缓存分两层：内存命中，或落盘命中（全量同步/既往日拉取已落盘；
            // 落盘命中时同步回填内存，同款处理 + 静默刷新）。
            if let cached = self.dayEntriesCache[key] ?? self.diskCachedDayEntries(key: key) {
                // N2 缓存命中：整表重载仍保留——换日整表重载是 66 包闪退修法，
                // 本批不动该回归点；缓存使重载直接渲染出数据，不再有
                // “空面板等网络”的白屏，时间线行因数据未变不闪（reloadData
                // 本身不播入场动效；新面板行走下方 N3 错峰）。
                self.dayEntries = cached
                self.dayEntriesKey = key
                self.dayState = .loaded
                self.tableView.reloadData()
                self.updateChrome()
                self.refreshHeaderHeight()
                if reduceMotion == false {
                    self.daySwitchStagger = Dictionary(uniqueKeysWithValues: cached.indices.map { (IndexPath(row: $0, section: 0), $0) })
                    self.daySwitchGeneration = self.staggerGeneration
                    self.daySwitchTitleFade = true
                }
                // 后台静默刷新：不清面板、不闪，数据变了才对齐（见回包分支）。
                self.fetchDayEntries(key: key, clear: false)
            } else {
                // 切日闪退修：换日分支不再走 reloadSections——点按驱动的更新
                // 上下文里分段数守卫也挡不住 UIKit Invalid Batch Updates，改整表重载。
                self.tableView.reloadData()
                self.updateChrome()
                self.refreshHeaderHeight()
                if reduceMotion == false {
                    self.daySwitchTitleFade = true
                }
                // N3：换日回包到达时给新行错峰（见 fetchDayEntries 回包分支）。
                self.daySwitchArrivalKey = key
                self.fetchDayEntries(key: key, clear: true)
            }
        }
        // N3：旧日卡片退场（仅非减动效、表已入窗、旧面板存在且有可见行时）：
        // 只动面板分区可见行（alpha 淡出 + 下移 8，transform/opacity，
        // 严禁逐帧改 height）；时间线行不动、不重播。退场完成才提交新日，
        // 减动效 / 无可见旧行时直接提交、无动画。
        if reduceMotion == false, tableView.window != nil, hadPanel {
            let exitingCells = tableView.visibleCells.filter { cell in
                guard let path = tableView.indexPath(for: cell) else { return false }
                return path.section == 0
            }
            if exitingCells.isEmpty == false {
                UIView.animate(withDuration: 0.18, animations: {
                    for cell in exitingCells {
                        cell.alpha = 0
                        cell.transform = CGAffineTransform(translationX: 0, y: 8)
                    }
                }, completion: { _ in commitDaySwitch() })
                return
            }
        }
        commitDaySwitch()
    }

    /// 6A gotoEntry 落点（自己篇）：按 createdAt 北京日切到当日面板并滚动高亮。
    /// 已在当日面板里时直接滚，不重拉；无 createdAt 时只在已加载分区里找。
    func locateEntry(entryId: String, createdAt: Int?) {
        guard let ms = createdAt, let dayKey = BearyBeijingDay.dayKey(ofMs: ms) else {
            pendingLocateEntryId = nil
            pendingLocateDayKey = nil
            tryLocateInLoadedSections(entryId: entryId)
            return
        }
        if dayEntriesKey == dayKey, dayEntries.contains(where: { $0.id == entryId }) {
            pendingLocateEntryId = nil
            pendingLocateDayKey = nil
            scrollToEntryRow(section: 0, row: dayEntries.firstIndex(where: { $0.id == entryId }) ?? 0, entryId: entryId)
            return
        }
        // 引用点按快路径：已加载时间线分区里已有该篇时直接滚，不再切日重拉；
        // 切日才走 selectDay → fetchDayEntries（1 次往返）。日历选区保持原选区不变，
        // 落点行与高亮与旧路径一致；同时清掉旧定位挂起，避免前一次切日请求的回包
        // 把用户拽回旧目标（快速连点两篇引用时）。
        if tryLocateInLoadedSections(entryId: entryId) {
            pendingLocateEntryId = nil
            pendingLocateDayKey = nil
            return
        }
        pendingLocateEntryId = entryId
        pendingLocateDayKey = dayKey
        locateDaySelection = true
        selectDay(key: dayKey)
    }

    /// 6A：当日回包尾部消费定位挂起（只消费一次；找不到时静默停在当日）。
    private func consumePendingLocate() {
        guard let target = pendingLocateEntryId else { return }
        pendingLocateEntryId = nil
        pendingLocateDayKey = nil
        if let row = dayEntries.firstIndex(where: { $0.id == target }) {
            scrollToEntryRow(section: 0, row: row, entryId: target)
            return
        }
        tryLocateInLoadedSections(entryId: target)
    }

    /// 6A：在已加载全部分区里找目标行（时间线分区兜底），找到即滚动高亮并返回 true。
    private func tryLocateInLoadedSections(entryId: String) -> Bool {
        let sections = currentSections()
        for (sectionIndex, section) in sections.enumerated() {
            if let row = section.entries.firstIndex(where: { $0.id == entryId }) {
                scrollToEntryRow(section: sectionIndex, row: row, entryId: entryId)
                return true
            }
        }
        return false
    }

    /// 详情返回定位（guarded）：只在已加载分区里找，找到即按现行定位体验滚动高亮；
    /// 未加载时什么都不做（不插入、不追拉）。
    func scrollToEntryIdIfPresent(_ entryId: String) {
        _ = tryLocateInLoadedSections(entryId: entryId)
    }

    /// 6A：滚动到指定行并闪一下（两段 async：先等重载落定，再等滚动落定取 cell）。
    private func scrollToEntryRow(section: Int, row: Int, entryId: String) {
        let sections = currentSections()
        guard section < sections.count, row < sections[section].entries.count else { return }
        let path = IndexPath(row: row, section: section)
        let animated = UIAccessibility.isReduceMotionEnabled == false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let fresh = self.currentSections()
            guard section < fresh.count, row < fresh[section].entries.count else { return }
            self.tableView.scrollToRow(at: path, at: .middle, animated: animated)
            DispatchQueue.main.async { [weak self] in
                guard let cell = self?.tableView.cellForRow(at: path) as? BearyTimelineCell else { return }
                cell.flashHighlight()
                // E3：定位落定后，目标行天气标播 Lottie；先停其他可见行，
                // 避免上一次落点仍在视野内时两行同播。
                if let tableView = self?.tableView {
                    for visibleCell in tableView.visibleCells {
                        if let timelineCell = visibleCell as? BearyTimelineCell, timelineCell !== cell {
                            timelineCell.stopWeatherLottie()
                        }
                    }
                }
                cell.playWeatherLottie()
            }
        }
    }

    /// 当日面板分区安全重载：表已入窗、选中日存在、分区数与当前分区数一致
    /// 时才 reloadSections（面板头 + 面板行走 .fade 入场，时间线行不动、
    /// 不重播）；任一条件不满足返回 false，调用方回落 reloadData。
    private func reloadDayPanelSectionIfStable() -> Bool {
        guard tableView.window != nil, selectedDayKey != nil else { return false }
        let sections = currentSections()
        guard !sections.isEmpty, tableView.numberOfSections == sections.count else { return false }
        tableView.reloadSections(IndexSet(integer: 0), with: .fade)
        return true
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
        // 账号代际：请求时捕获 uid，回包写缓存/落盘前比对——中途切号到达的
        // 旧账号回包直接丢弃（新账号的 reloadTimeline 会重拉，不靠旧回包对齐）。
        let requestUid = SessionManager.shared.currentUser?.id
        BearyAPI.shared.fetchTimelineDay(date: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                if strongSelf.dayKeyForLoad != key { return }
                if SessionManager.shared.currentUser?.id != requestUid { return }
                // N2/N3 回包快照：静默刷新比对用旧签名；换日到达标志在此消费
                // （早退分支如 fixSel 跳转也不留残标志，避免后一次回包误错峰）。
                let oldDaySignatures = strongSelf.dayEntries.map { strongSelf.entrySignature($0) }
                let isDaySwitchArrival = clear && strongSelf.daySwitchArrivalKey == key
                if isDaySwitchArrival { strongSelf.daySwitchArrivalKey = nil }
                var dayUnchanged = false
                // 本批 4b 用：B-G7 补丁是否改动了时间线侧行（改动则当日面板
                // 分区重载会丢时间线侧同步，必须回落整表重载；未改动则可分区重载）。
                var timelinePatchChanged = false
                switch result {
                case .success(let list):
                    strongSelf.dayEntries = list.entries ?? []
                    // N2：成功回包写入日缓存（失败不写）；静默刷新比对签名。
                    // 写透：内存与落盘同写（见 cacheDayEntries）。
                    strongSelf.cacheDayEntries(key: key, entries: strongSelf.dayEntries)
                    dayUnchanged = (clear == false && oldDaySignatures == strongSelf.dayEntries.map { strongSelf.entrySignature($0) })
                    // B-G7: patch the timeline copy from the fresh day-panel copy
                    // before reload, so both copies render the same state.
                    let timelineBefore = strongSelf.timelineEntries.map { strongSelf.entrySignature($0) }
                    strongSelf.timelineEntries = strongSelf.patchedEntries(strongSelf.timelineEntries, withFresh: strongSelf.dayEntries)
                    timelinePatchChanged = timelineBefore != strongSelf.timelineEntries.map { strongSelf.entrySignature($0) }
                    strongSelf.dayEntriesKey = key
                    strongSelf.dayState = .loaded
                    // 相邻日预取触发点：正向加载成功后才触发（失败不触发）；
                    // 预取只写日缓存，不动面板与时间线行（见 prefetchAdjacentDays）。
                    strongSelf.prefetchAdjacentDays(for: key)
                    if wasNonEmptyForKey && strongSelf.dayEntries.isEmpty {
                        // 第 2 项 A 的活已由本次跳转完成，挂起标志随之清掉，
                        // 避免之后某次月份到达时对新选区再跑一次初次/刷新守卫。
                        strongSelf.pendingEntryJumpCheck = false
                        strongSelf.applyDayFixSel()
                        return
                    }
                    // 第 4 项：删除后挂起的守卫在当日面板已空时也跑一次
                    // （以日历计数为准；已跳转/取消则跳过后续重载）。
                    if strongSelf.pendingFixSelCheck && strongSelf.dayEntries.isEmpty {
                        if strongSelf.checkFixSelForSelectedDay() {
                            strongSelf.pendingEntryJumpCheck = false
                            return
                        }
                    }
                    // 第 2 项 A：初次进入 / 下拉刷新守卫在当日回包处消费。
                    // 当日已空才跑（非空即清挂起、不跳转）；缓存未到时
                    // checkEntryJumpForSelectedDay 会重新挂起并补拉该月，
                    // 到达后由月份回包分支重试，本处先按空面板正常重载。
                    if strongSelf.pendingEntryJumpCheck {
                        strongSelf.pendingEntryJumpCheck = false
                        if strongSelf.dayEntries.isEmpty {
                            if strongSelf.checkEntryJumpForSelectedDay() {
                                return
                            }
                        }
                    }
                case .failure(let error):
                    strongSelf.dayState = .failed
                }
                // M2：同日刷新（clear:false）只重载当日面板分区，不整表 reloadData。
                // 本批 4b：换日（clear:true）回包也不再一律整表——分区数稳定且
                // B-G7 未改动时间线侧行时，面板分区走 .automatic 入场（与 M2 同口径，
                // 时间线已有行不重播）；任一条件不满足才回落整表重载；表未入窗时仍整表。
                // N2：后台静默刷新数据一字未变且时间线侧未动时，不碰表——
                // 可见行瞬态（展开/高亮/滚动位置）全保留，无闪烁。
                if dayUnchanged && !timelinePatchChanged {
                    // 不重载，只走下方 updateChrome / consumePendingLocate。
                } else if isDaySwitchArrival && UIAccessibility.isReduceMotionEnabled == false
                            && strongSelf.tableView.window != nil && strongSelf.selectedDayKey != nil
                            && !timelinePatchChanged
                            && strongSelf.tableView.numberOfSections == strongSelf.currentSections().count {
                    // N3：换日回包到达——分区走 .none（不动效），入场错峰
                    // 全权交给 willDisplay（与首屏 insertRows .none 同口径，
                    // 避免 .automatic 淡入与错峰叠播）；分区数守卫仍在，
                    // 守卫失败回落整表重载并清错峰队列（防旧队列日后重播）。
                    strongSelf.daySwitchStagger = Dictionary(uniqueKeysWithValues: strongSelf.dayEntries.indices.map { (IndexPath(row: $0, section: 0), $0) })
                    strongSelf.daySwitchGeneration = strongSelf.staggerGeneration
                    strongSelf.tableView.reloadSections(IndexSet(integer: 0), with: .none)
                } else if clear == false && strongSelf.tableView.window != nil && strongSelf.selectedDayKey != nil {
                    strongSelf.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
                } else if strongSelf.tableView.window != nil && strongSelf.selectedDayKey != nil
                            && !timelinePatchChanged
                            && strongSelf.tableView.numberOfSections == strongSelf.currentSections().count {
                    strongSelf.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
                } else {
                    strongSelf.daySwitchStagger.removeAll()
                    strongSelf.tableView.reloadData()
                }
                strongSelf.updateChrome()
                // 6A：当日回包尾部消费定位挂起（成功与失败都走：失败时 dayEntries
                // 不变，若目标仍在已加载行里照常滚到，找不到则静默清掉）。
                strongSelf.consumePendingLocate()
            }
        }
    }

    /// 相邻日预取：选中日 ±1 天（独立通道，不抢正向单槽）。
    /// 隔离方式：不碰 dayKeyForLoad / dayState / dayEntries / dayEntriesKey，
    /// 只读写 dayPrefetchInFlight 与 dayEntriesCache；回包只写缓存，不 reload、
    /// 不 updateChrome、不弹 toast、不影响当前日显示。
    /// 让路规则：触发时正向加载在途（dayState == .loading）则整体跳过，
    /// 等下次正向成功再触发；单日回包时若正向后来居上（同日正向在途），
    /// 本次预取不写缓存，正向成功回包自会写。
    /// 去重规则：已缓存的日、已在途的日一律跳过；失败静默（不记失败态、
    /// 不写缓存），下次切日走正常正向路径。
    /// 缓存语义与 #116 日缓存一致：先显示、切日静默刷新再对齐。
    private func adjacentDayKeys(for key: String) -> [String] {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let base = BearyBeijingDay.date(year: year, month: month, day: day) else { return [] }
        var keys: [String] = []
        for delta in [-1, 1] {
            guard let shifted = BearyBeijingDay.calendar.date(byAdding: .day, value: delta, to: base) else { continue }
            let comps = BearyBeijingDay.calendar.dateComponents([.year, .month, .day], from: shifted)
            guard let yy = comps.year, let mm = comps.month, let dd = comps.day else { continue }
            keys.append(BearyBeijingDay.dayKey(year: yy, month: mm, day: dd))
        }
        return keys
    }

    private func prefetchAdjacentDays(for key: String) {
        guard tableView.window != nil else { return }
        guard dayState != .loading else { return }
        // 账号代际：与正向加载同款，请求时捕获 uid，回包写缓存前比对。
        let requestUid = SessionManager.shared.currentUser?.id
        for next in adjacentDayKeys(for: key) {
            guard dayEntriesCache[next] == nil, !dayPrefetchInFlight.contains(next) else { continue }
            if dayKeyForLoad == next && dayState == .loading { continue }
            dayPrefetchInFlight.insert(next)
            BearyAPI.shared.fetchTimelineDay(date: next) { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    strongSelf.dayPrefetchInFlight.remove(next)
                    if SessionManager.shared.currentUser?.id != requestUid { return }
                    switch result {
                    case .success(let list):
                        if strongSelf.dayKeyForLoad == next && strongSelf.dayState == .loading { return }
                        strongSelf.cacheDayEntries(key: next, entries: list.entries ?? [])
                    case .failure:
                        break
                    }
                }
            }
        }
    }

    private func clearDaySelection() {
        // 80 包 A6-1：清选区不再硬切——复用日历翻页过渡（0.18s 淡出 + 高度过渡淡回），
        // 减动效时 helper 内直换；队列代际同步 +1，0.18s 窗口内若用户已切新日则旧清区作废。
        staggerGeneration += 1
        clearStaggerEntries()
        let clearGeneration = staggerGeneration
        performCalendarTransition { [weak self] in
            guard let strongSelf = self, strongSelf.staggerGeneration == clearGeneration else { return }
            strongSelf.selectedDayKey = nil
            strongSelf.dayKeyForLoad = nil
            strongSelf.dayEntries = []
            strongSelf.dayEntriesKey = nil
            strongSelf.dayState = .idle
            strongSelf.showJumpNote = false
            strongSelf.jumpNoteTimer?.invalidate()
            strongSelf.jumpNoteTimer = nil
            strongSelf.renderCalendar()
            strongSelf.tableView.reloadData()
            strongSelf.updateChrome()
        }
    }

    /// TL-8 calFixSel 等价逻辑：选中日变空时，同月内先往前、再往后找最近有日记日
    /// 跳转（周视图下锚点同步跟过去）；同月再无有篇日则取消选中并清面板，
    /// 并以 toast 提示“这天已没有日记”（第 4 项：找不到也要提示）。
    /// 跳转时面板头下出 3 秒提示“这天已没有日记，已跳到最近的一天”。
    /// 注：网页前向搜索上限写死 31 天，本实现按当月实际天数 bound，结果等价。
    /// 月份缓存缺失时不直接取消选中：挂起并补拉，月份到达后由守卫重试。
    private func applyDayFixSel() {
        guard let key = selectedDayKey else { return }
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            clearDaySelection()
            return
        }
        let monthKey = BearyBeijingDay.monthKey(year: year, month: month)
        guard let monthData = calendarCache[monthKey] else {
            // 月份已失败时不补拉（防死循环）、不取消选中，保留选区待重试。
            if calendarFailed.contains(monthKey) {
                pendingFixSelCheck = false
                return
            }
            pendingFixSelCheck = true
            fetchCalendarMonth(key: monthKey)
            return
        }
        pendingFixSelCheck = false
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
            showTimelineToast(message: "这天已没有日记")
        }
    }

    /// TL-7 当日面板表头（第 7 项两段式 + 第 15 项网页口径）：
    /// 日期一段（15pt 加粗墨色，如“10 月 25 日”，星期不在此段）；
    /// 星期·篇数·状态一段（12.5pt 灰色，如“周日 · 1 篇 · 都私密”，篇数带空格）。
    /// 失败时只写“加载失败，点一下日期再试”，重试靠再点日期（无头旁重试钮）；
    /// 加载中/未加载时不写“加载中…”，只出日期一段。
    /// head/suffix 分段供表头富文本使用（日期加粗 15 + 后段灰色 12.5）。
    private func dayPanelTitleParts(key: String) -> (head: String, suffix: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return (key, "") }
        var weekdayText = ""
        if let date = BearyBeijingDay.date(year: year, month: month, day: day) {
            let weekday = BearyBeijingDay.calendar.component(.weekday, from: date)
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            if weekday >= 1 && weekday <= names.count {
                weekdayText = names[weekday - 1]
            }
        }
        let head = "\(month) 月 \(day) 日"
        if dayState == .failed {
            // B-G8: web replaces the whole day segment with the failure text
            // (beary.html 4216/4223); the date segment is NOT kept. Empty head
            // leaves only the 12.5 gray failure text in viewForHeader.
            return ("", "加载失败，点一下日期再试")
        }
        if dayState != .loaded {
            return (head, "")
        }
        var suffix = ""
        if weekdayText.isEmpty {
            suffix = " · \(dayEntries.count) 篇"
        } else {
            suffix = " · \(weekdayText) · \(dayEntries.count) 篇"
        }
        if !dayEntries.isEmpty {
            let allPublic = dayEntries.allSatisfy { $0.isPublic == true }
            let allPrivate = dayEntries.allSatisfy { $0.isPublic != true }
            if allPublic {
                suffix += " · 都已公开"
            } else if allPrivate {
                suffix += " · 都私密"
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
            // 84 包：当日面板已展示该天条目时，时间线不再重复建组；dayEntries 为空时保留时间线组，避免取数失败藏条目。非今天的选中日同样适用。
            if key == selectedDayKey, !dayEntries.isEmpty { continue }
            if let existing = indexByKey[key] {
                sections[existing].entries.append(entry)
            } else {
                indexByKey[key] = sections.count
                sections.append(DaySection(dayKey: key, title: dayTitleForMs(createdMs), entries: [entry]))
            }
        }
        return sections
    }

    /// 追加 6①：日组标题统一格式——此前今天/昨天带“今天 · / 昨天 · ”前缀、
    /// 更早的日期没有前缀，同页内格式不统一；统一为一律“X 月 X 日”
    /// （当日面板表头是另一组件，口径不动）。
    private func dayTitleForMs(_ ms: Int) -> String {
        guard let comps = BearyBeijingDay.components(ofMs: ms) else { return "" }
        return "\(comps.month) 月 \(comps.day) 日"
    }

    private func emptyView(title: String, subtitle: String, actionTitle: String?, action: (() -> Void)?, iconName: String = "icon_tray", actionOutlined: Bool = false) -> UIView {
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
        // R8：空态标题/副标题（正文类）走 scaledFont + adjusts。
        titleView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        titleView.adjustsFontForContentSizeCategory = true
        titleView.textColor = BearyColors.ink
        titleView.textAlignment = .center
        let subtitleView = UILabel()
        subtitleView.translatesAutoresizingMaskIntoConstraints = false
        subtitleView.text = subtitle
        subtitleView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        subtitleView.adjustsFontForContentSizeCategory = true
        subtitleView.textColor = BearyColors.gray
        subtitleView.textAlignment = .center
        subtitleView.numberOfLines = 0
        var arranged: [UIView] = [iconView, titleView, subtitleView]
        if let actionTitle = actionTitle {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(actionTitle, for: .normal)
            // R8：空态按钮走 scaledFont + adjusts。
            button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            if actionOutlined {
                // 80 包重试统一：与首页失败行/主页失败脚部同款描边 pill 钮。
                button.setTitleColor(BearyColors.ink, for: .normal)
                button.tintColor = BearyColors.ink
                button.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 15), for: .normal)
                button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
                button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
                button.layer.borderWidth = 1
                button.layer.borderColor = BearyColors.line.cgColor
                button.layer.cornerRadius = 20
            } else {
                button.setTitleColor(BearyColors.blue, for: .normal)
            }
            // Q1 按钮高统一 44（空态各按钮同口径；仅数值约束，不改布局结构）。
            button.heightAnchor.constraint(equalToConstant: actionOutlined ? 40 : 44).isActive = true
            button.addTarget(self, action: #selector(didTapEmptyAction(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
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

    /// 空态/背景视图上次种类（本批 4b：种类切换时新背景视图 0.2s 淡入，
    /// 同种类重复调用不重播；减动效时直显）。
    private var lastChromeBackgroundKind: String?

    private func updateChrome() {
        // TL-7：当日面板的加载/失败/空态只反映在面板表头里，不再用整表背景空态
        // 覆盖时间线；背景空态只在时间线与当日面板双双无行时出现。
        let sections = currentSections()
        let hasRows = sections.contains { !$0.entries.isEmpty }
        let isLoginEmpty = (timelineState == .failed && timelineUnauthorized && timelineEntries.isEmpty)
        var newBackgroundKind = "none"
        if timelineState == .loading && timelineEntries.isEmpty && !hasRows {
            // 双图标互斥（另一向）：自定义下拉刷新进行中由 pullView 图标独占
            // 指示，此时即使另有重载把表行清掉、首屏加载分支成立，背景加载
            // spinner 也不得再挂——否则刷新中同时出现下拉图标与背景 spinner
            // （空表下拉刷新必复现：下拉进入后 loadTimelineFirstPage 置
            // .loading 即走本分支）。这是挂载级禁用（backgroundView 置 nil），
            // 不是把背景 spinner 移出可视区。
            if isCustomPullRefreshing {
                tableView.backgroundView = nil
                newBackgroundKind = "none"
            } else {
                // M2：首屏加载态（此前 backgroundView 置 nil，只有下拉才有 spinner）。
                tableView.backgroundView = timelineLoadingView()
                newBackgroundKind = "loading"
            }
        } else if timelineState == .failed && timelineEntries.isEmpty && !hasRows {
            if isLoginEmpty {
                tableView.backgroundView = emptyView(title: "先登录", subtitle: "时间线只放你自己的日记，登录后就能看", actionTitle: "去登录", action: { [weak self] in
                    self?.onRequireLogin?()
                }, iconName: "icon_calendar")
                newBackgroundKind = "login"
            } else {
                // W10：加载失败空态副标题补网页同款“网络好像不太顺”。
                tableView.backgroundView = emptyView(title: "加载失败", subtitle: "网络好像不太顺", actionTitle: "重试", action: { [weak self] in
                    self?.reloadTimeline()
                }, iconName: "icon_wifi_off", actionOutlined: true)
                newBackgroundKind = "failed"
            }
        } else if timelineState == .loaded && !hasRows {
            // B-G9: web renderTimeline empty state uses beary-diary, not tray.
            // Q5：时间线空态加“写一篇”按钮（走 onCompose 回调，容器接线打开编辑器；
            // 回收站空态不在本文件，不动）。
            tableView.backgroundView = emptyView(title: "把日子留在这里", subtitle: "写下第一篇，它会出现在这里", actionTitle: "写一篇", action: { [weak self] in
                self?.onCompose?()
            }, iconName: "icon_diary")
            newBackgroundKind = "empty"
        } else {
            tableView.backgroundView = nil
        }
        // 本批 4b：空态切换补入场动效——种类变化且新背景非空时淡入
        // （6-7 收敛到 0.25s alpha 过渡；只动 backgroundView 的 alpha，
        // 已有表行不重播、不重载）。
        if let backgroundView = tableView.backgroundView,
           newBackgroundKind != "none",
           newBackgroundKind != lastChromeBackgroundKind,
           UIAccessibility.isReduceMotionEnabled == false {
            backgroundView.alpha = 0
            UIView.animate(withDuration: 0.25, animations: {
                backgroundView.alpha = 1
            }, completion: nil)
        }
        lastChromeBackgroundKind = newBackgroundKind
        // 第 14 项 B：分页向同组追加行时，旧末行不会重走 cellForRowAt，
        // 其 bottom -8 会在新行（top 0）上方留 8px 断口；此处按当前分区
        // 重刷可见行的线边距，旧末行改回中间行 0/0，组内恢复通长。
        // updateChrome 在首屏/分页/当日回包后均被调用，且只碰可见行、无重载。
        for visibleCell in tableView.visibleCells {
            guard let timelineCell = visibleCell as? BearyTimelineCell else { continue }
            guard let indexPath = tableView.indexPath(for: timelineCell) else { continue }
            guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { continue }
            timelineCell.setTimelineLineEdges(
                isFirstInDay: indexPath.row == 0,
                isLastInDay: indexPath.row == sections[indexPath.section].entries.count - 1
            )
        }
        // 追加项二：数据重载后重算悬浮头（滚动事件未必触发时仍跟随）。
        updateStickyHeader()
        updateFooter()
    }

    /// M2 首屏加载视图：居中 spinner + “正在加载…”（仅首屏无行时作 backgroundView）。
    private func timelineLoadingView() -> UIView {
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let spinner = BearyRefreshIconView()
        // 栈内固有尺寸须与旧 medium 圈一致（20），故图取 20pt。
        spinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
        spinner.startSpinning()
        let label = UILabel()
        label.text = "正在加载…"
        // R8：首屏加载文字（正文类）走 scaledFont + adjusts。
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.adjustsFontForContentSizeCategory = true
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

    /// G15 分页失败 toast：委托统一 BearyToast。时间线是 Chrome 主 tab，
    /// FAB 常驻（下滑藏栏已拆除；搜索藏栏只针对搜索页），落点由组件按
    /// Chrome 实际 chrome 态算；展示时长由旧 1.6s 统一为 2.0s，
    /// 调用签名与文案、触发时机不变。
    private func showTimelineToast(message: String) {
        BearyToast.show(in: view, message: message)
    }

    private func updateFooter() {
        // 脚部只属于时间线翻页；当日面板的加载/失败态在面板表头里。
        // M18：脚部 spinner 不再是死代码——加载时进脚部层级与文案并排。
        footerSpinner.stopSpinning()
        footerSpinner.removeFromSuperview()
        if timelineLoadingMore {
            tableView.tableFooterView = footerLoadingHolder()
        } else if timelinePageFailed && timelineHasMore {
            // G15：分页失败后脚部保持可重试。
            loadMoreButton.setTitle("加载失败，重试", for: .normal)
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
        // R8：脚部加载文字（正文类）走 scaledFont + adjusts。
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        footerSpinner.isHidden = false
        footerSpinner.startSpinning()
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
        // 112：按钮本身铺满脚部行——高钉死 44、左右贴 holder 边缘，标题仍居中。
        // 只换类不够：BearyHit44Button 只扩 <44 的轴，标题宽已超 44 时横向不扩，
        // 标题外左右区域仍点不到；holder 高度不动（不是只把 holder 加高糊弄）。
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return holder
    }

    @objc private func didTapFooter() {
        loadTimelineNextPage()
    }

    @objc private func didTapTrash() {
        onOpenTrash?()
    }

    /// iCity：操作行双向切换钮——显式目标态，无确认框；
    /// publishBusyIds 复用防重入；成功先就地同步缓存（timeline/day/
    /// 日缓存/落盘 + 引用缓存清理），再整页重拉以服务端为准。
    /// 目标态按有效态算（2026-10-29 第 18 项根因修法，与详情页对齐；过期限时篇
    /// stored 仍公开，旧口径会把“公开”点成“私密”）。
    /// 即时反馈（2026-10-29 定版）：点按瞬间先按目标态就地同步并只刷可见行
    /// （图标立即变，不整页重拉、不重播动效），回包成功再整页对齐；
    /// 失败回滚原态 + 拒绝动效。
    private func handlePublishEntry(_ entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 审计 P2-23：可见性切换是作者动作——非作者不执行（时间线本只列本人日记，此为纵深门控）。
        let viewerId = SessionManager.shared.currentUser?.id
        guard entry.isMine == true || (entry.authorId != nil && viewerId != nil && entry.authorId == viewerId) else { return }
        if publishBusyIds.contains(entryId) { return }
        let target = BearyEphemeral.isEffectivelyPublic(entry) ? 0 : 1
        let originalPublic = entry.isPublic ?? false
        let originalPublishedAt = entry.publishedAt
        publishBusyIds.insert(entryId)
        // 先行：目标态立即落地（模型 + 可见行，不整页重拉）。
        applyVisibilityLocally(entryId: entryId, isPublic: target == 1, publishedAt: nil)
        BearySoundPlayer.play(.visibilityClick)
        reloadVisibleTimelineRow(entryId: entryId)
        BearyAPI.shared.setVisibility(id: entryId, published: target) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.publishBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    let isPublic = resp.published.map { $0 == 1 } ?? (target == 1)
                    strongSelf.applyVisibilityLocally(entryId: entryId, isPublic: isPublic, publishedAt: resp.publishedAt)
                    strongSelf.refreshAfterDetailChange()
                case .failure(let err):
                    strongSelf.applyVisibilityLocally(entryId: entryId, isPublic: originalPublic, publishedAt: originalPublishedAt)
                    strongSelf.reloadVisibleTimelineRow(entryId: entryId)
                    let message: String
                    if case .server(let code) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                    else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                    else { message = "切换失败，请重试" }
                    strongSelf.showTimelineToast(message: message)
                    strongSelf.shakeVisibleTimelinePublishButton(entryId: entryId)
                }
            }
        }
    }

    /// 2026-10-29 改版：卡片右上角 ⋯ 菜单（actionSheet）——编辑内容／修改权限／删除。
    /// 编辑内容仅 15 分钟内出现（与编辑文字钮、左滑编辑同口径：deadline 缺失即已锁）；
    /// 修改权限走原地球钮同一 handlePublishEntry 路径（含乐观落地、失败回滚、拒绝动效）；
    /// 删除走原删除回调同一路（容器确认流程不变）；iPad 须设 popover 锚点，否则崩溃。
    private func presentTimelineMoreMenu(entry: Entry, sourceView: UIView) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if let deadline = entry.editDeadline, nowMs < deadline {
            sheet.addAction(UIAlertAction(title: "编辑内容", style: .default) { [weak self] _ in
                self?.onEditEntry?(entry)
            })
        }
        sheet.addAction(UIAlertAction(title: "修改权限", style: .default) { [weak self] _ in
            self?.handlePublishEntry(entry)
        })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.onDeleteEntry?(entry)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(sheet, animated: true)
    }

    /// 可见行单行重刷（.none，不播行动画、不重播已有元素动效）：按 currentSections
    /// 定位该篇所在组行，仅行在视野内时刷。
    private func reloadVisibleTimelineRow(entryId: String) {
        let sections = currentSections()
        for (sectionIndex, section) in sections.enumerated() {
            guard let row = section.entries.firstIndex(where: { $0.id == entryId }) else { continue }
            let path = IndexPath(row: row, section: sectionIndex)
            if tableView.indexPathsForVisibleRows?.contains(path) == true {
                tableView.reloadRows(at: [path], with: .none)
            }
            return
        }
    }

    /// 可见行 ⋯ 钮拒绝动效：摇头 + warning 震动（与卡片 playDenyShake 同口径）。
    private func shakeVisibleTimelinePublishButton(entryId: String) {
        let sections = currentSections()
        for (sectionIndex, section) in sections.enumerated() {
            guard let row = section.entries.firstIndex(where: { $0.id == entryId }) else { continue }
            let path = IndexPath(row: row, section: sectionIndex)
            guard let cell = tableView.cellForRow(at: path) as? BearyTimelineCell else { return }
            cell.playPublishDenyShake()
            return
        }
    }

    /// 翻转本地同步（removeDeletedEntry 式清理口径，改的是可见性不是删除）：
    /// timeline/day 列表与日缓存里的副本就地改 isPublic/publishedAt，
    /// 改动的日缓存同步写落盘；引用缓存清掉该篇（旧引用卡不按旧可见性渲染）。
    private func applyVisibilityLocally(entryId: String, isPublic: Bool, publishedAt: Int?) {
        for index in timelineEntries.indices where timelineEntries[index].id == entryId {
            timelineEntries[index].isPublic = isPublic
            // 手动翻转清限时标记（服务端同口径），否则本地仍画虚线边框。
            timelineEntries[index].ephemeralUntil = nil
            if let publishedAt = publishedAt { timelineEntries[index].publishedAt = publishedAt }
        }
        for index in dayEntries.indices where dayEntries[index].id == entryId {
            dayEntries[index].isPublic = isPublic
            dayEntries[index].ephemeralUntil = nil
            if let publishedAt = publishedAt { dayEntries[index].publishedAt = publishedAt }
        }
        for key in dayEntriesCache.keys {
            var list = dayEntriesCache[key] ?? []
            var changed = false
            for index in list.indices where list[index].id == entryId {
                list[index].isPublic = isPublic
                list[index].ephemeralUntil = nil
                if let publishedAt = publishedAt { list[index].publishedAt = publishedAt }
                changed = true
            }
            if changed {
                dayEntriesCache[key] = list
                cacheDayEntries(key: key, entries: list)
            }
        }
        if isPublic == false {
            BearyDiaryCardCell.quoteCache.removeValue(forKey: entryId)
        }
    }

    @objc private func didTapStats() {
        // G14：重试全部可视失败月份（周视图跨月时次要月份也有入口，不只主月份）。
        for key in monthKeysForCurrentView() {
            if calendarFailed.contains(key) && calendarCache[key] == nil {
                fetchCalendarMonth(key: key)
            }
        }
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
        // 第 14 项 B + 2026-10-31 同日竖线不断：首行 top 0、末行 bottom -8、
        // 中间行 0/0——同日各篇的线在 cell 交界处相接、连续贯通。
        cell.setTimelineLineEdges(
            isFirstInDay: indexPath.row == 0,
            isLastInDay: indexPath.row == sections[indexPath.section].entries.count - 1
        )
        cell.onEditEntry = onEditEntry
        cell.onDeleteEntry = onDeleteEntry
        cell.onQuoteEntry = onQuoteEntry
        cell.onMoreEntry = { [weak self] entry, sourceView in self?.presentTimelineMoreMenu(entry: entry, sourceView: sourceView) }
        // N7：复用独立文件内的查看器，全屏模态弹出（已弹出时不叠加、减动效直显）。
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
            // R8：日组标题（正文类）走 scaledFont + adjusts。
            let attributed = NSMutableAttributedString(string: parts.head, attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15)),
                .foregroundColor: BearyColors.ink,
            ])
            if parts.suffix.isEmpty == false {
                attributed.append(NSAttributedString(string: parts.suffix, attributes: [
                    .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5)),
                    .foregroundColor: BearyColors.gray,
                ]))
            }
            label.attributedText = attributed
        } else {
            label.text = sections[section].title
        }
        label.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: isDayPanel ? 15 : 13))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = isDayPanel ? BearyColors.ink : BearyColors.gray
        label.numberOfLines = 0
        let holder = UIView()
        holder.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        // TL-1：时间线日期头与行左缩进对齐（网页 .date-h padding-left 36px）；
        // 当日面板头按网页 .cal-day-t 取 16。
        let leading: CGFloat = isDayPanel ? 16 : 36
        var bottomView: UIView = label
        // B-G8: day header uses web .cal-day-t (top 16, bottom 4); timeline section
        // headers keep .date-h (top 18, bottom 8). They previously shared 18/8,
        // so the day header was 2/4pt too tall.
        var bottomConstant: CGFloat = isDayPanel ? -4 : -8
        // 第 15 项：当日失败不再出头旁蓝色“重试”文字钮，重试靠再点日期
        // （失败文案本身即“加载失败，点一下日期再试”）。
        if isDayPanel && showJumpNote {
            let jumpLabel = UILabel()
            jumpLabel.text = "这天已没有日记，已跳到最近的一天"
            // R8：跳转提示（正文类提示文字）走 scaledFont + adjusts。
            jumpLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
            jumpLabel.adjustsFontForContentSizeCategory = true
            jumpLabel.textColor = BearyColors.gray
            jumpLabel.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(jumpLabel)
            NSLayoutConstraint.activate([
                jumpLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
                jumpLabel.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: leading),
                jumpLabel.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            ])
            bottomView = jumpLabel
            bottomConstant = isDayPanel ? -4 : -8
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
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: isDayPanel ? 16 : 18),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            bottomView.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: bottomConstant),
        ])
        // 第 9 项：组头处无圆点、竖线不穿头——R1 补段已拆除，组头不再补
        // 14px 墨圆 + 17px line 色外环与满高竖线（网页 .date-h 在 .tl 组外同口径）。
        // 第 14 项 B：竖线按日通长连续——组内行按首/中/末拼线（见 TL-1 注释），
        // 组与组之间由组头隔开，线自然断开，不再是每行各 inset 8px 的分段。
        // 第 10 项：表已改 grouped，头不吸顶，仍需不透明底防透字。
        holder.backgroundColor = BearyColors.bg
        return holder
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return }
        // W6：行点按补 .light 轻震。
        BearyHaptics.press()
        onOpenEntry?(sections[indexPath.section].entries[indexPath.row])
    }

    /// C7 滑动操作资格（iCity）：删除公开/私密均可，编辑仅看 15 分钟编辑期
    ///（与编辑钮显隐同口径：editDeadline 缺失即已锁），与可见性无关。
    /// 触发后只复用 onDeleteEntry/onEditEntry（容器确认/编辑器流程），
    /// 不另写执行逻辑；不符资格的行返回 nil，即不可滑动。
    private static func isTimelineSwipeEditUnlocked(entry: Entry) -> Bool {
        guard let deadline = entry.editDeadline else { return false }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return nowMs < deadline
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return nil }
        let entry = sections[indexPath.section].entries[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.onDeleteEntry?(entry)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return nil }
        let entry = sections[indexPath.section].entries[indexPath.row]
        guard Self.isTimelineSwipeEditUnlocked(entry: entry) else { return nil }
        let edit = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.onEditEntry?(entry)
            completion(true)
        }
        // 补缺 P3-30：左滑编辑钮底色显式设墨色（原未指定，随系统默认）。
        edit.backgroundColor = BearyColors.ink
        return UISwipeActionsConfiguration(actions: [edit])
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // 110：相邻项图片预取——行将上屏时，把同组下一行与下一组首行
        // 的头像/首张正文图经 BearyImageLoader 预热（内存 + 磁盘命中后
        // 主图秒出；只发加载请求，不改布局、不加骨架、不碰错峰队列，
        // 放在错峰逻辑之前、且不早退，保证每行都触发）。
        do {
            let sections = currentSections()
            if indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count {
                var upcoming: [Entry] = []
                let sectionEntries = sections[indexPath.section].entries
                if indexPath.row + 1 < sectionEntries.count {
                    upcoming.append(sectionEntries[indexPath.row + 1])
                }
                if indexPath.section + 1 < sections.count, let first = sections[indexPath.section + 1].entries.first {
                    upcoming.append(first)
                }
                for entry in upcoming {
                    if let avatarURL = BearyImageURLs.avatarURL(entry.authorAvatar) {
                        _ = BearyImageLoader.shared.load(url: avatarURL, downsampleToWidth: 40 * UIScreen.main.scale) { _ in }
                    }
                    if let firstKey = entry.images?.first, let imageURL = BearyImageURLs.imageURL(key: firstKey, thumb: true) {
                        _ = BearyImageLoader.shared.load(url: imageURL) { _ in }
                    }
                }
            }
        }
        // N3：切日新行错峰滑入——cell 即将上屏时从透明 + 下偏 6 起播，
        // 按面板行序号错峰（步进 0.05s、封顶 0.5s；减动效时队列为空，不播）。
        // 与 M2 同机制：播过即摘、代际不符即弃；仅新日行播，已有行不重播。
        // 只动 transform/opacity，严禁逐帧改 height。
        if let dayOrder = daySwitchStagger[indexPath] {
            daySwitchStagger[indexPath] = nil
            if daySwitchGeneration == staggerGeneration {
                cell.alpha = 0
                cell.transform = CGAffineTransform(translationX: 0, y: 6)
                let delay = min(Double(dayOrder) * 0.05, 0.5)
                UIView.animate(withDuration: 0.25, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
                    cell.alpha = 1
                    cell.transform = .identity
                }, completion: nil)
                return
            }
        }
        // M2：分页新增行错峰滑入——cell 即将上屏时从透明 + 下偏 6 起播，
        // 按原始序号错峰（减动效时队列为空，不播）。
        guard let order = staggerInsertOrder[indexPath] else { return }
        staggerInsertOrder[indexPath] = nil
        // 80 包 A2-3②：队列代际不符时丢弃残留条目，不在新数据行上重播旧错峰。
        guard staggerQueueGeneration == staggerGeneration else { return }
        // 80 包 A2-3④/A3-3：分页/首屏入场统一口径——cell 级 alpha + y+6、
        // 0.25s、0.03 步进封顶 0.24s、可交互（与首页/主页一致）。
        cell.alpha = 0
        cell.transform = CGAffineTransform(translationX: 0, y: 6)
        let delay = min(Double(order) * 0.03, 0.24)
        UIView.animate(withDuration: 0.25, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
            cell.alpha = 1
            cell.transform = .identity
        }, completion: nil)
    }

    // N3：切日组头淡入（一次性：标志消费后不再重播；减动效时标志不置位）。
    // 只动组头 holder 的 alpha，组头节点本身由 viewForHeaderInSection 新建，
    // 不重建已有行、不碰高度。
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard daySwitchTitleFade, section == 0, selectedDayKey != nil else { return }
        daySwitchTitleFade = false
        view.alpha = 0
        UIView.animate(withDuration: 0.2, animations: {
            view.alpha = 1
        })
    }

    // 下滑藏栏已拆除（第 11 项）：底栏胶囊与 FAB 常驻，scrollViewDidScroll
    // 只做追加项二的悬浮日期头跟随，不做藏栏。
}

/// 110：时间线首屏磁盘缓存（首页 BearyFeedCache 同款结构与桶口径，
/// 见 BearyFeedViewController.swift 末尾）。时间线是本人全部日记，
/// 快照不做公开过滤；桶按用户隔离，游客不写盘（首屏成功写盘处
/// 只在已登录时调用）。快照字段：savedAt、entries、hasMore、
/// trashCount、计数 total/priv/pub（TlCounts 仅 Decodable，故拆存）。
enum BearyTimelineCache {
    private struct Snapshot: Codable {
        var savedAt: TimeInterval
        var entries: [Entry]
        var hasMore: Bool
        var trashCount: Int
        var total: Int?
        var priv: Int?
        var pub: Int?
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("beary_timeline_cache_\(bucket).json")
    }

    static func load(bucket: String) -> (entries: [Entry], hasMore: Bool, trashCount: Int, total: Int?, priv: Int?, pub: Int?, savedAt: TimeInterval)? {
        guard let url = fileURL(bucket: bucket), let data = try? Data(contentsOf: url) else { return nil }
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        return (snap.entries, snap.hasMore, snap.trashCount, snap.total, snap.priv, snap.pub, snap.savedAt)
    }

    static func save(bucket: String, entries: [Entry], hasMore: Bool, trashCount: Int, counts: TlCounts?) {
        guard let url = fileURL(bucket: bucket) else { return }
        let snap = Snapshot(savedAt: Date().timeIntervalSince1970, entries: entries, hasMore: hasMore, trashCount: trashCount, total: counts?.total, priv: counts?.priv, pub: counts?.pub)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// 110：首页加载时的时间线首屏预取（一次/启动，见任务“首页加载时
/// 预取时间线首屏”）。触发点在首页首屏成功回包后（缓存命中走静默
/// 刷新时同样触发）；只在已登录时跑（游客时间线 401，不发无用请求）；
/// 只写时间线缓存，绝不碰时间线 VC 状态（VC 未创建时尤其不能碰）；
/// 预取失败静默丢弃（下次首页首屏成功再试，标志只在成功存盘后置位）；
/// 缓存已有且 10 分钟内新鲜时不重复拉（时间线 VC 每次打开仍静默
/// 刷新对齐，预取只负责冷启动前置，不替代刷新）。
enum BearyTimelinePrefetch {
    private static var didPrefetch = false

    static func maybePrefetch() {
        guard didPrefetch == false, let uid = SessionManager.shared.currentUser?.id else { return }
        let bucket = BearyFeedCache.bucket(userId: uid)
        if let snap = BearyTimelineCache.load(bucket: bucket), !snap.entries.isEmpty,
           Date().timeIntervalSince1970 - snap.savedAt < 600 {
            didPrefetch = true
            return
        }
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50) { result in
            guard case .success(let list) = result, let entries = list.entries, !entries.isEmpty else { return }
            BearyTimelineCache.save(bucket: bucket, entries: entries, hasMore: entries.count >= 50, trashCount: list.trashCount ?? 0, counts: list.tlCounts)
            didPrefetch = true
        }
    }
}
