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
    /// 每种状态各自按数量拆现有图形词汇（公开=橙、未公开=蓝），一天内先画公开组、
    /// 再画未公开组拼进同一格：1→1 点、2→2 点、3→三角形、4→正方形、5→五边形、
    /// 6→五边形+1 点、7→五边形+2 点、单状态 8+ 按 7 封顶。
    /// 逐一核对 Li 的例子：2 篇 1 公开 = 1 橙点 + 1 蓝点；3 篇 2 公开 = 2 橙点 + 1 蓝点；
    /// 10 篇 7 公开 3 未公开 = 橙五边形 + 橙 2 点 + 蓝三角形。
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
            // 图例行 markView 不在此约束内（图例走自然换行，不裁剪）。
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
    /// 图例行高落定后透传给 VC（VC 再跑 refreshHeaderHeight）。
    var onLegendHeightSettled: (() -> Void)?
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
        // B-G13: legend no longer forced into 4+3 rows; it wraps naturally
        // (web .cal-legend flex-wrap + justify-content:center), row count decided
        // by width. Stack is .fill so the flow view gets full width.
        monthLegendStack.alignment = .fill
        monthLegendStack.spacing = 2
        let legendFlowView = BearyCalendarLegendFlowView()
        legendFlowView.onHeightSettled = { [weak self] in self?.onLegendHeightSettled?() }
        legendFlowView.setPairs([
            legendPair(marks: BearyCalendarMarks.marks(published: 1, unpublished: 0), text: "1 篇"),
            legendPair(marks: BearyCalendarMarks.marks(published: 2, unpublished: 0), text: "2 篇"),
            legendPair(marks: BearyCalendarMarks.marks(published: 3, unpublished: 0), text: "3 篇"),
            legendPair(marks: BearyCalendarMarks.marks(published: 4, unpublished: 0), text: "4 篇"),
            legendPair(marks: BearyCalendarMarks.marks(published: 5, unpublished: 0), text: "5 篇"),
            legendPair(marks: BearyCalendarMarks.marks(published: 6, unpublished: 0), text: "6 篇"),
            legendPair(marks: BearyCalendarMarks.marks(published: 7, unpublished: 0), text: "7 篇起"),
        ])
        monthLegendStack.addArrangedSubview(legendFlowView)
        let legendNote = UILabel()
        legendNote.text = "橙 = 已公开 · 蓝 = 未公开 · 形状旁的异色小点 = 两种状态都有"
        legendNote.font = UIFont.systemFont(ofSize: 12)
        legendNote.textColor = BearyColors.gray
        legendNote.textAlignment = .center
        legendNote.numberOfLines = 0
        monthLegendStack.addArrangedSubview(legendNote)

        let outer = UIStackView(arrangedSubviews: [topRow, weekdayRow, gridStack, weekNoteLabel, monthLegendStack])
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.axis = .vertical
        outer.spacing = 0
        outer.setCustomSpacing(8, after: topRow)
        outer.setCustomSpacing(6, after: weekdayRow)
        outer.setCustomSpacing(10, after: gridStack)
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

    private func legendPair(marks: [BearyCalendarMark], text: String) -> UIStackView {
        let markView = BearyCalendarMarkView()
        markView.marks = marks
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = BearyColors.gray
        let pair = UIStackView(arrangedSubviews: [markView, label])
        pair.axis = .horizontal
        pair.spacing = 5
        pair.alignment = .center
        return pair
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
        // 现与月视图同口径（0.32s、每格 0.018s 错峰、curveEaseOut；复用格子
        // 仍不重播，见下方 isNewButton 分支）。已有月视图时长曲线不动。
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
        onSelectDay?(day)
    }
}

/// B-G13 legend natural-wrap container (native equivalent of web .cal-legend
/// flex-wrap): column gap 14, row gap 8, each line centered; row count is decided
/// by the actual width, never forced. Height is an explicit constraint updated in
/// layoutSubviews once the width is known (the parent stack is .fill, so width is
/// exact); the view controller re-checks header height after layout (see
/// viewDidLayoutSubviews) so the legend is never clipped on first layout.
private final class BearyCalendarLegendFlowView: UIView {
    private var pairs: [UIView] = []
    private var heightConstraint: NSLayoutConstraint?
    /// 图例行高落定回调：行高随宽度最终落定后（可能晚于 VC 的布局检查），
    /// 通知 VC 再跑一次表头高度，避免统计行被压。回调经主队列合并投递，
    /// 不在布局过程中同步重入表头计算。
    var onHeightSettled: (() -> Void)?
    private var settledCallbackPending = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 15)
        heightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setPairs(_ pairs: [UIView]) {
        for old in self.pairs {
            old.removeFromSuperview()
        }
        self.pairs = pairs
        for pair in pairs {
            addSubview(pair)
        }
        setNeedsLayout()
    }

    private func pairSize(_ pair: UIView) -> CGSize {
        let size = pair.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func lines(forWidth width: CGFloat) -> [[UIView]] {
        var lines: [[UIView]] = [[]]
        var lineWidth: CGFloat = 0
        for pair in pairs {
            let size = pairSize(pair)
            let extra = lines[lines.count - 1].isEmpty ? size.width : 14 + size.width
            if lineWidth + extra > width && !lines[lines.count - 1].isEmpty {
                lines.append([pair])
                lineWidth = size.width
            } else {
                lines[lines.count - 1].append(pair)
                lineWidth += extra
            }
        }
        return lines
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let broken = lines(forWidth: width)
        var y: CGFloat = 0
        for (lineIndex, line) in broken.enumerated() {
            let sizes = line.map { pairSize($0) }
            let totalWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, line.count - 1)) * 14
            let lineHeight = sizes.map { $0.height }.max() ?? 0
            var x = (width - totalWidth) / 2
            if x < 0 { x = 0 }
            for (index, pair) in line.enumerated() {
                let size = sizes[index]
                pair.frame = CGRect(x: x, y: y + (lineHeight - size.height) / 2, width: size.width, height: size.height)
                x += size.width + 14
            }
            y += lineHeight
            if lineIndex < broken.count - 1 { y += 8 }
        }
        if heightConstraint?.constant != y {
            heightConstraint?.constant = y
            if !settledCallbackPending {
                settledCallbackPending = true
                DispatchQueue.main.async { [weak self] in
                    self?.settledCallbackPending = false
                    self?.onHeightSettled?()
                }
            }
        }
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
    /// E3：本行天气图标视图（configure 现建现存；复用/重配即清）与落点
    /// 天气 Lottie 覆盖层（仅 gotoEntry 落点行创建，其他行恒为 nil）。
    private var weatherIconView: UIImageView?
    private var weatherEmoteView: BearyEmoteView?
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
    // 公开 14px 橙圆点（2.5 bg 边 + 1.5 line 外环，N1：与网页 --orange #ff9500 同值，
    // 走 BearyColors.orange），私密 9px 蓝空心圆（无外环）。
    // 第 14 项 B：竖线按日通长连续（网页 .tl:before 口径：每个日期组容器一条线，
    // top 8 / bottom 8，组头 .date-h 在组外、线不穿头）。原生无组容器，改为按行
    // 拼线：组内首行 top 8、末行 bottom -8、中间行 top/bottom 均为 0——相邻行
    // 的线在 cell 交界处恰好相接，组内不断；组与组之间由组头隔开，线自然断开。
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
    // TL-2 沙漏：官方 icon_hourglass 资产（beary-ui-2.zip 内有 hourglass.svg，
    // 按 compass 同款工艺渲染入 catalog；此前查 beary-ui.zip 无沙漏是查错了包）。
    // 12pt 模板图 + 蓝色 tint，与原自绘 BearyHourglassView 同色同形，自绘类已删。
    private let hourglassView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.image = BearyIconImages.image(named: "icon_hourglass", pointSize: 12)
        imageViewValue.tintColor = BearyColors.blue
        imageViewValue.contentMode = .scaleAspectFit
        return imageViewValue
    }()
    private var pillLabelLeadingWithIcon: NSLayoutConstraint?
    private var pillLabelLeadingWithoutIcon: NSLayoutConstraint?
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
    private let statusIconView = UIImageView()
    private let editStatusLabel = UILabel()
    private let editButton = BearyHit44Button(type: .custom)
    private let deleteButton = BearyHit44Button(type: .custom)
    // B 方案公开操作（网页 pubActionInnerHtml 口径）：已送达未公开出“公开”钮，
    // 倒计时中出剩余时间 + “取消”钮；未送达时三者全隐。字段约定见 D 路：
    // Entry.publishPendingUntil（Int? 毫秒时间戳，nil = 不在倒计时中）。
    private let publishButton = UIButton(type: .system)
    private let pendingCountdownLabel = UILabel()
    private let cancelPublishButton = UIButton(type: .system)
    var onPublishEntry: ((Entry) -> Void)?
    var onCancelPublishEntry: ((Entry) -> Void)?

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

        timeLabel.font = UIFont.systemFont(ofSize: 13)
        timeLabel.textColor = BearyColors.gray
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 6A pill 左 packed：时间横向抗拉伸同样提到 required，否则时间会吸 slack。
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        pillBackground.translatesAutoresizingMaskIntoConstraints = false
        // 6A pill 左 packed：pill 背景横向抗拉伸提到 required，否则它（默认 250）
        // 会吸走 meta 行 slack、背景向右伸长，看起来就是 pill 被推到右侧。
        pillBackground.setContentHuggingPriority(.required, for: .horizontal)
        pillBackground.layer.cornerRadius = 10
        pillBackground.layer.masksToBounds = true
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        // 88 包 L18：倒计时每秒改文案，等宽数字防宽度抖动（只影响数字字形）。
        pillLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
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

        weatherLabel.font = UIFont.systemFont(ofSize: 13)
        weatherLabel.textColor = BearyColors.gray
        // 网页 .tl-meta 可 flex-wrap 口径：天气/心情允许多行换行（不截断），
        // 横向低压缩，空间不足时先缩它们，时间（required）与 pill 绝不被挤到重叠。
        weatherLabel.numberOfLines = 0
        weatherLabel.lineBreakMode = .byWordWrapping
        weatherLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        moodLabel.font = UIFont.systemFont(ofSize: 13)
        moodLabel.textColor = BearyColors.gray
        moodLabel.numberOfLines = 0
        moodLabel.lineBreakMode = .byWordWrapping
        moodLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        quoteTitleLabel.font = UIFont.systemFont(ofSize: 11.5)
        quoteTitleLabel.textColor = BearyColors.gray
        quoteBodyLabel.translatesAutoresizingMaskIntoConstraints = false
        // B-G1: web .tl-qt 13.5/1.6, clamped to 2 lines.
        quoteBodyLabel.font = UIFont.systemFont(ofSize: 13.5)
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

        editStatusLabel.font = UIFont.systemFont(ofSize: 12)
        editStatusLabel.textColor = BearyColors.gray
        // I11：私密操作行文案前加 13px 状态图标（可编辑 icon_edit / 已结束 icon_lock）。
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.tintColor = BearyColors.gray
        statusIconView.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            statusIconView.widthAnchor.constraint(equalToConstant: 13),
            statusIconView.heightAnchor.constraint(equalToConstant: 13),
        ])
        if let editImage = BearyIconImages.image(named: "icon_edit", pointSize: 17) {
            editButton.setImage(editImage, for: .normal)
        }
        editButton.tintColor = BearyColors.gray
        editButton.alpha = 1
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        editButton.bearyAddPressFeedback()
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 17) {
            deleteButton.setImage(trashImage, for: .normal)
        }
        deleteButton.imageView?.contentMode = .scaleAspectFit
        deleteButton.tintColor = BearyColors.red
        deleteButton.alpha = 0.85
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.bearyAddPressFeedback()
        publishButton.translatesAutoresizingMaskIntoConstraints = false
        // 公开钮图标化（Li 2026-10-26 定：v3 public globe）：22pt 墨色图标、44×44，与编辑/删除同行齐平；无边框、无文字。
        if let globeImage = BearyIconImages.image(named: "icon_globe", pointSize: 22) {
            publishButton.setImage(globeImage, for: .normal)
        }
        publishButton.tintColor = BearyColors.ink
        publishButton.imageView?.contentMode = .scaleAspectFit
        publishButton.accessibilityLabel = "公开"
        publishButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        publishButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        publishButton.addTarget(self, action: #selector(publishTapped), for: .touchUpInside)
        publishButton.bearyAddPressFeedback()
        pendingCountdownLabel.font = UIFont.systemFont(ofSize: 13)
        pendingCountdownLabel.textColor = BearyColors.gray
        cancelPublishButton.translatesAutoresizingMaskIntoConstraints = false
        cancelPublishButton.setTitle("取消", for: .normal)
        cancelPublishButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        cancelPublishButton.setTitleColor(BearyColors.gray, for: .normal)
        cancelPublishButton.addTarget(self, action: #selector(cancelPublishTapped), for: .touchUpInside)
        cancelPublishButton.bearyAddPressFeedback()
        publishButton.isHidden = true
        pendingCountdownLabel.isHidden = true
        cancelPublishButton.isHidden = true
        actsStack.translatesAutoresizingMaskIntoConstraints = false
        actsStack.axis = .horizontal
        actsStack.spacing = 14
        actsStack.alignment = .center
        let actsSpacer = UIView()
        // B-G6: publish button sits inline right after the edit status (web tl-acts
        // puts pub-acts before the flex spacer); the spacer only pushes edit/delete right.
        actsStack.addArrangedSubview(statusIconView)
        actsStack.addArrangedSubview(editStatusLabel)
        actsStack.addArrangedSubview(publishButton)
        actsStack.addArrangedSubview(pendingCountdownLabel)
        actsStack.addArrangedSubview(cancelPublishButton)
        actsStack.addArrangedSubview(actsSpacer)
        actsStack.addArrangedSubview(editButton)
        actsStack.addArrangedSubview(deleteButton)
        NSLayoutConstraint.activate([
            editButton.widthAnchor.constraint(equalToConstant: 28),
            editButton.heightAnchor.constraint(equalToConstant: 28),
            deleteButton.widthAnchor.constraint(equalToConstant: 28),
            deleteButton.heightAnchor.constraint(equalToConstant: 28),
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
        timelineLineTopConstraint = timelineLineView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
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
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
        ])
        // 无图时把图片条高度约束压到 0（只靠 hidden 不够：显式高度约束仍会撑开 stack）。
        thumbsHeightConstraint = thumbsScrollView.heightAnchor.constraint(equalToConstant: 216)
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
        // N1：已公开圆点填充改橙色（与 configure 同口径），主题切换后仍是橙。
        if let entry = currentEntry {
            let published = entry.isPublic ?? false
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderColor = (published ? BearyColors.orange : BearyColors.blue).cgColor
        } else {
            dotView.layer.borderColor = BearyColors.bg.cgColor
        }
        quoteLeftLineView.backgroundColor = BearyColors.line
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

    /// 6A 定位高亮：卡片 faint 闪一下再回 bg（减动效下只滚动不闪）。
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

    /// 第 14 项 B：按行在日组内的位置定竖线边距。首行 top 8、末行 bottom -8、
    /// 中间行 0/0；单行组同时是首末行，即恢复旧的 8/-8。VC 在 cellForRowAt
    /// 设定，复用前 prepareForReuse 复位为 8/-8，防中间行状态漏到单行组。
    func setTimelineLineEdges(isFirstInDay: Bool, isLastInDay: Bool) {
        timelineLineTopConstraint?.constant = isFirstInDay ? 8 : 0
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
        deleteButton.imageView?.transform = .identity
        editButton.imageView?.transform = .identity
        setTimelineLineEdges(isFirstInDay: true, isLastInDay: true)
        currentEntry = nil
        cardView.backgroundColor = BearyColors.bg
        quoteButton.isHidden = true
        quoteBodyLabel.isHidden = false
        clearQuoteThumbs()
        actsStack.isHidden = true
        publishButton.isHidden = true
        pendingCountdownLabel.isHidden = true
        cancelPublishButton.isHidden = true
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
        let published = entry.isPublic ?? false
        if published {
            // N1：已公开 pill 改橙色——文字走 BearyColors.orange（网页 --orange
            // #ff9500），底色为橙色两态透明底（浅 12% / 深 18%，见
            // publishedPillBackground，动态色、主题切换自动跟随）。
            // 未公开口径不动（蓝 pill / 蓝圆点见 updatePill 与 else 分支）。
            pillBackground.backgroundColor = Self.publishedPillBackground()
            pillLabel.textColor = BearyColors.orange
            pillLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
            pillLabel.text = "已公开"
            hourglassView.isHidden = true
            pillLabelLeadingWithIcon?.isActive = false
            pillLabelLeadingWithoutIcon?.isActive = true
            // 竖线圆点统一用未公开的尺寸和结构（9pt 空心 + 12pt 环），只变颜色：
            // 已公开橙边、未公开蓝边（2026-10-28 Li 定，覆盖 #125 的已公开几何口径）。
            dotSizeConstraint?.constant = 9
            dotRingSizeConstraint?.constant = 12
            dotTopConstraint?.constant = 14.5
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderWidth = 2.5
            dotView.layer.borderColor = BearyColors.orange.cgColor
            dotView.layer.cornerRadius = 4.5
            dotRingView.isHidden = true
        } else {
            updatePill(entry: entry)
            // 未公开圆点即统一口径（9pt 空心 + 12pt 环，蓝边）；已公开只换边色为橙。
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
            weatherRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // 6A pill 左 packed：天气行横向抗拉伸提到 required，不吸 slack。
            weatherRow.setContentHuggingPriority(.required, for: .horizontal)
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
            moodRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // 6A pill 左 packed：心情行横向抗拉伸提到 required，不吸 slack。
            moodRow.setContentHuggingPriority(.required, for: .horizontal)
            metaStack.addArrangedSubview(moodRow)
        }
        if let recipientName = entry.recipientName, entry.recipientId != nil {
            recipientLabel.text = "写给 \(recipientName)"
            metaStack.addArrangedSubview(recipientLabel)
        }
        // 6A pill 左 packed：行末 defaultLow 吸宽 spacer（足行 footSpacer 同款口径），
        // 是 meta 行唯一低抗拉伸项，独吞全部 slack，整行左 packed、pill 永远紧贴时间。
        // configure 开头与 prepareForReuse 的全清循环会一并移除，不叠加。
        let metaSpacer = UIView()
        metaSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaStack.addArrangedSubview(metaSpacer)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.75
        paragraph.lineBreakMode = .byCharWrapping
        let body = entry.content ?? ""
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
        // quoteId 有而 quote 体缺失 → 已删除；quote 体无正文且未公开 → 尚未公开。
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
                quoteTitleLabel.text = "引用了一篇尚未公开的日记"
                quoteIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 12)
                quoteBodyLabel.isHidden = true
                quoteButton.isEnabled = false
                quoteButton.isHidden = false
            } else if quoteBody.isEmpty {
                if quote.isPublic == true {
                    quoteTitleLabel.text = "引用的日记已删除"
                    quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 12)
                } else {
                    quoteTitleLabel.text = "引用了一篇尚未公开的日记"
                    quoteIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 12)
                }
                quoteBodyLabel.isHidden = true
                quoteButton.isEnabled = false
                quoteButton.isHidden = false
            } else if quote.isPublic != true && entry.isMine != true {
                // B-G2 visibility gate (the computable subset of web quoteVisible):
                // a non-public quote is visible only when public or the host entry is
                // mine. From another user's perspective, even server-passed body is
                // replaced by the locked placeholder - never leak body or images.
                // Quote has no author_id field, so the "quoted author is the viewer"
                // branch cannot be evaluated here; fail closed to locked state.
                quoteTitleLabel.text = "引用了一篇尚未公开的日记"
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
                    .font: UIFont.systemFont(ofSize: 13.5),
                    .foregroundColor: BearyColors.ink,
                    .paragraphStyle: quoteParagraph,
                ])
                quoteIconView.image = BearyIconImages.image(named: "icon_quote", pointSize: 12)
                // F2：引用卡内补一行 42px 小缩略图（网页 tl-qcard 内 .quote-thumbs 口径）；
                // 仅公开引用或自己的引用才配图（网页 quoteThumbsHtml 口径），无图不占位。
                if quote.isPublic == true || entry.isMine == true {
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
            if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                imageView.bearySetImage(url: url, downsampleToWidth: strip * UIScreen.main.scale)
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
                emoteLabel.font = UIFont.systemFont(ofSize: 13)
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
        // B 方案公开操作：pending 优先于已送达（字段有值即倒计时态）；
        // 字段为 nil 时看是否已送达（publishAt != nil 且 <= now）才出“公开”钮，
        // 未送达则三者全隐。publishPendingUntil 为可选字段，缺失按 nil 计、不崩。
        // 注意：本引用在 D 路补字段前编译不过，见回执说明。
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // B-G5: an expired countdown (pendingUntil <= now) must NOT stick on
        // "剩不到 1 小时"; it falls through to delivered/undelivered state here,
        // and the 1s tick (refreshCountdowns) flips it without waiting for reload.
        if let pendingUntil = entry.publishPendingUntil, pendingUntil > nowMs {
            publishButton.isHidden = true
            pendingCountdownLabel.isHidden = false
            pendingCountdownLabel.text = BearyTimelineCell.pubCountdownText(pendingMs: pendingUntil)
            cancelPublishButton.isHidden = false
        } else if let publishAt = entry.publishAt, publishAt <= nowMs {
            publishButton.isHidden = false
            pendingCountdownLabel.isHidden = true
            cancelPublishButton.isHidden = true
        } else {
            publishButton.isHidden = true
            pendingCountdownLabel.isHidden = true
            cancelPublishButton.isHidden = true
        }
    }

    /// 网页 pubCountdownText 口径（定死粒度）：>=1 小时显示“剩 X 小时”
    /// （X = 剩余毫秒 / 3600000 向上取整），<1 小时显示“剩不到 1 小时”。
    /// 只在渲染/进入时算一次；每秒 tick 经 refreshCountdowns → updateEditRow 重算。
    static func pubCountdownText(pendingMs: Int) -> String {
        let ms = max(0, pendingMs - Int(Date().timeIntervalSince1970 * 1000))
        if ms >= 3600000 {
            let hours = Int(ceil(Double(ms) / 3600000.0))
            return "剩 \(hours) 小时"
        }
        return "剩不到 1 小时"
    }

    @objc private func publishTapped() {
        guard let entry = currentEntry else { return }
        onPublishEntry?(entry)
    }

    @objc private func cancelPublishTapped() {
        guard let entry = currentEntry else { return }
        onCancelPublishEntry?(entry)
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

    /// TL-2/TL-3 的 1 秒 tick 入口：只改本行 pill 与编辑倒计时文案，不重建行。
    func refreshCountdowns() {
        guard let entry = currentEntry else { return }
        if entry.isPublic == true { return }
        // B-G4/B-G5: 1s tick recomputes pill + action row, so delivery / countdown
        // expiry flips state locally without waiting for a reload.
        updatePill(entry: entry)
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
        // B-G2 second lock: gone/locked/other-user-unpublished never navigates,
        // even if the button was somehow left enabled.
        if entry.quote?.gone == true || entry.quote?.locked == true { return }
        if entry.quote?.isPublic != true && entry.isMine != true { return }
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
    private static let timelineQuoteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.dateFormat = "M 月 d 日"
        return f
    }()

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
            label.font = UIFont.systemFont(ofSize: 13)
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
    /// B-G4: private pill (web tlItemHtml / pubState) - pending (countdown not yet
    /// expired) and delivered-but-unpublished both show blue "未公开" with NO hourglass;
    /// only undelivered shows the hourglass + delivery countdown (the original private
    /// countdown pill, verbatim). publishAt missing falls back to the old "未公开".
    /// NOTE: this pill is NOT the detail countdown pill; each is handled separately,
    /// and this change does not touch the detail file.
    /// N1：已公开 pill 两态透明底——浅色橙 12%、深色橙 18%，动态色解析，
    /// 主题切换自动跟随（不用 BearyColors.alpha 固定透明度，后者两态同值）。
    static func publishedPillBackground() -> UIColor {
        return UIColor { trait in
            BearyColors.orange.resolvedColor(with: trait).withAlphaComponent(
                trait.userInterfaceStyle == .dark ? 0.18 : 0.12)
        }
    }

    private func updatePill(entry: Entry) {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let isPending = (entry.publishPendingUntil ?? 0) > nowMs
        let isDelivered = (entry.publishAt ?? 0) > 0 && (entry.publishAt ?? 0) <= nowMs
        // 94 包：归零转公开时行文案变化加 crossDissolve（首现直接写，
        // 之后文案变了才过渡，每秒 tick 文案不变时不重播）。
        let newText: String
        let hideHourglass: Bool
        if isPending || isDelivered {
            newText = "未公开"
            hideHourglass = true
        } else {
            newText = BearyTimelineCell.privCountdownText(publishAtMs: entry.publishAt)
            hideHourglass = false
        }
        // 追加项（投递中去色）：倒计时态（“投递中 · 还剩 X 天/小时/分钟”与
        // “即将公开”）去掉蓝色填充，改与时间文字同级的灰色次要文字显示，
        // 沙漏图标同样改灰色；文案与倒计时计算一字不动，正文重新成为重点。
        // “未公开”三字（待公开倒计时中、已送达未公开、publishAt 缺失回退）
        // 一律保持原蓝色 pill 不动；已公开橙色（N1，configure 分支）也不动。
        // 字体按态显式复位，防复用把倒计时的 13 系统字带到蓝 pill / 已公开。
        let isCountdown = !(isPending || isDelivered) && newText != "未公开"
        let pillBg: UIColor
        let pillTextColor: UIColor
        let pillFont: UIFont
        let hourglassTint: UIColor
        if isCountdown {
            pillBg = .clear
            pillTextColor = BearyColors.gray
            pillFont = UIFont.systemFont(ofSize: 13)
            hourglassTint = BearyColors.gray
        } else {
            // C6：动态色上的 0.13 透明度走 BearyColors.alpha（Common lane 提供），
            // 不再对动态色直接 withAlphaComponent（深浅解析会失真）。
            pillBg = BearyColors.alpha(BearyColors.blue, 0.13)
            pillTextColor = BearyColors.blue
            pillFont = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
            hourglassTint = BearyColors.blue
        }
        let apply = {
            self.pillBackground.backgroundColor = pillBg
            self.pillLabel.textColor = pillTextColor
            self.pillLabel.font = pillFont
            self.hourglassView.tintColor = hourglassTint
            self.pillLabel.text = newText
            self.hourglassView.isHidden = hideHourglass
            self.pillLabelLeadingWithIcon?.isActive = !hideHourglass
            self.pillLabelLeadingWithoutIcon?.isActive = hideHourglass
        }
        if let old = pillLabel.text, !old.isEmpty, old != newText {
            UIView.transition(with: pillBackground, duration: 0.22, options: .transitionCrossDissolve, animations: apply)
        } else {
            apply()
        }
    }

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
    /// 第 2 项 A 初次进入 / 下拉刷新跳转守卫：只在 viewDidLoad 与 pullToRefresh
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
    /// TL-2 1 秒 tick + 到点重拉（网页 startCountdowns 口径：同篇最多 3 次、间隔 ≥3 秒）。
    private var countdownTimer: Timer?
    private var publishFireCounts: [String: Int] = [:]
    /// 80 包 B6：待公开子集快照（id → publishAt），由 updateChrome 在模型变化时
    /// 重建；仅含快照时刻 publishPendingUntil 仍在未来的未公开条目；tick 只扫它。
    private var pendingPublishDue: [String: Int] = [:]
    private var publishFireLast: [String: Date] = [:]

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
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        tv.refreshControl = rc
        return tv
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
    private let stickyHeaderView = UIView()
    private let stickyHeaderLabel = UILabel()
    // 吸顶头状态栏区底色：只盖 view 顶到安全区顶沿这一段（吸顶头自身已盖安全区下方），
    // 与吸顶头同显同隐，滚动内容不再从状态栏区透出。
    private let statusBarBgView = UIView()
    private var stickyHeaderTopConstraint: NSLayoutConstraint?
    private var stickyHeaderCurrentSection: Int?
    private var stickyHeaderCurrentTitle: String?
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
        setupStickyHeader()
        // R8：控制器自有按钮类走 scaledFont + adjusts（卡片内文字由卡片组负责，不碰）。
        loadMoreButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        loadMoreButton.titleLabel?.adjustsFontForContentSizeCategory = true
        loadMoreButton.setTitleColor(BearyColors.gray, for: .normal)
        loadMoreButton.addTarget(self, action: #selector(didTapFooter), for: .touchUpInside)
        loadMoreButton.bearyAddPressHaptic()
        footerSpinner.color = BearyColors.gray
        // G15 toast 已委托 B 批统一 BearyToast（见 showTimelineToast），
        // 此处不再建常驻 toast 容器。
        // 第 2 项 A 调用点 1/2（初次进入）：置跳转守卫挂起，选中日（今天）
        // 无日记时由当日/月份回包触发跳最近有篇日；标志不放在 reloadTimeline
        // 内，以免空态重试等其他 reloadTimeline 调用点也被接上守卫。
        pendingEntryJumpCheck = true
        initialLoadStarted = true
        reloadTimeline()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 顶栏透度批：安全区变化时按已存栏态重算（容器 viewDidLayoutSubviews 也会重发，双重 no-op）。
        applyHeaderTopInset(visible: headerTopInsetVisible)
        // 宽为 0 时丢弃的表头高度重算在此消费：宽一就绪即重算。
        if headerHeightNeedsRefresh, tableView.bounds.width > 0 {
            refreshHeaderHeight()
        }
        if abs(tableView.bounds.width - lastHeaderWidth) > 0.5 {
            refreshHeaderHeight()
            updateStickyHeader()
            return
        }
        // B-G13: legend flow height is only final after layout (row count depends
        // on width). If the fitting height now differs from the header height,
        // refresh it so the legend is never clipped; if it matches, just restore
        // the height that fittingHeaderHeight temporarily zeroed (no reassign, so
        // this cannot loop: after a refresh the heights already match).
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
    /// 故容器 showPage 在离页/进页时显式调这两个钩子；只覆盖倒计时启停
    ///（栏恢复已有 showPage 的 setBarsVisible/setHeaderVisible 兜底，不重复）。
    func pageDidEnter() {
        startCountdownTimer()
        // 80 包 A5：进页恢复可见行表情播放（与 stopVisibleEmotes 对称）。
        resumeVisibleEmotes()
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
    }

    // MARK: - 对外入口（容器在 tab 切入/重进时调用）

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 tableView，
    /// 表框贴页顶 + .never，故属性内边距即视觉顶距：显示 = 安全区顶 + 60，收起 = 安全区顶
    /// （本页在容器里恒收起，显示值只在首页当前、时间线已建未亮时经容器统一发一次，切页时即改回收起）。
    /// 底内边距同步补安全区底（.never 后旧视觉底 = 90 + 安全区底）。本页无公开回顶方法、
    /// 再点当前 tab 口径（容器重拍分支）：已在顶部才刷新，否则只回顶（见 scrollToTop/isAtTop）。
    func applyHeaderTopInset(visible: Bool) {
        headerTopInsetVisible = visible
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
    /// isPublic/publishAt/publishPendingUntil); body and images still require a
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
            merged.publishPendingUntil = freshEntry.publishPendingUntil
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

    @objc private func pullToRefresh() {
        // M12（91 包）：下拉刷新触发给一次轻触觉。
        BearyHaptics.press()
        // G16：刷新时先保存选中日（reloadTimeline keepDay 分支内保留），
        // 跳过当日拉取，只拉一次最终选中日；不再先拉今天再拉回原选中日。
        // 第 2 项 A 调用点 2/2（下拉刷新）：keepSelectedDay 下守卫接在刷新
        // 完成后——当日/月份回包到达时消费本标志，选中日已空即跳最近有篇日。
        pendingEntryJumpCheck = true
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
        // 80 包 B6：到点判定只扫待公开子集快照（id 唯一，无需再建 Set）；
        // 子集为空时直接跳过扫描；可见行倒计时文案仍由上方 refreshCountdowns
        // 每秒刷新，不受此跳过影响。触发规则与网页 cdFired 一致：同篇最多 3 次、间隔 ≥3 秒。
        if pendingPublishDue.isEmpty { return }
        for (entryId, publishAt) in pendingPublishDue {
            guard publishAt > 0, publishAt <= nowMs else { continue }
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

    /// 追加项二：悬浮日期头搭建。样式与现有时间线组头一致（13 粗体灰、
    /// 左缩进 36、上下边距 18/8）；不透明底（BearyColors.bg 动态色）；
    /// 落在安全区下方（top 锚 safeAreaLayoutGuide）；本身不拦截触摸。
    private func setupStickyHeader() {
        stickyHeaderView.translatesAutoresizingMaskIntoConstraints = false
        stickyHeaderView.backgroundColor = BearyColors.bg
        stickyHeaderView.isUserInteractionEnabled = false
        stickyHeaderView.isHidden = true
        stickyHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        stickyHeaderLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 13))
        stickyHeaderLabel.adjustsFontForContentSizeCategory = true
        stickyHeaderLabel.textColor = BearyColors.gray
        stickyHeaderLabel.numberOfLines = 1
        stickyHeaderLabel.isUserInteractionEnabled = false
        stickyHeaderView.addSubview(stickyHeaderLabel)
        view.addSubview(stickyHeaderView)
        stickyHeaderTopConstraint = stickyHeaderView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            stickyHeaderTopConstraint!,
            stickyHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stickyHeaderLabel.topAnchor.constraint(equalTo: stickyHeaderView.topAnchor, constant: 18),
            stickyHeaderLabel.leadingAnchor.constraint(equalTo: stickyHeaderView.leadingAnchor, constant: 36),
            stickyHeaderLabel.trailingAnchor.constraint(equalTo: stickyHeaderView.trailingAnchor, constant: -16),
            stickyHeaderLabel.bottomAnchor.constraint(equalTo: stickyHeaderView.bottomAnchor, constant: -8),
        ])
        statusBarBgView.translatesAutoresizingMaskIntoConstraints = false
        statusBarBgView.backgroundColor = BearyColors.bg
        statusBarBgView.isUserInteractionEnabled = false
        statusBarBgView.isHidden = true
        view.insertSubview(statusBarBgView, belowSubview: stickyHeaderView)
        NSLayoutConstraint.activate([
            statusBarBgView.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarBgView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarBgView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarBgView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    /// 追加项二：悬浮日期头跟随。只走位置计算、不做 UIView 动画
    /// （减动效下同样是跟随，无需分支；动画只会出现在滚动驱动的位置变化里）。
    /// 当前分区 = 组头已越过悬浮区顶沿、且分区底仍在顶沿下方的最末分区；
    /// 第 0 分区是当日面板时悬浮头全程不出现（面板组头可见时不重复，
    /// 面板行仍占顶时也不抢；面板整体滚出、后续分区接管时才出现）。
    /// 下一分区组头顶进悬浮区时，悬浮头 top 常量随之变负、被顶上去
    /// （标准顶替，位置跟随自然实现，不改高度、不逐帧改 frame 以外的值）。
    private func updateStickyHeader() {
        guard tableView.window != nil else { hideStickyHeader(); return }
        let sections = currentSections()
        let count = min(tableView.numberOfSections, sections.count)
        guard count > 0 else { hideStickyHeader(); return }
        let top = tableView.contentOffset.y + view.safeAreaInsets.top
        let headerHeight = 18 + ceil(stickyHeaderLabel.font.lineHeight) + 8
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
        let title = sections[current].title
        if stickyHeaderCurrentSection != current || stickyHeaderCurrentTitle != title {
            stickyHeaderLabel.text = title
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
        if let topConstraint = stickyHeaderTopConstraint, topConstraint.constant != offset {
            topConstraint.constant = offset
        }
        if stickyHeaderView.isHidden {
            stickyHeaderView.isHidden = false
            statusBarBgView.isHidden = false
        }
    }

    private func hideStickyHeader() {
        if stickyHeaderView.isHidden == false {
            stickyHeaderView.isHidden = true
        }
        statusBarBgView.isHidden = true
        stickyHeaderCurrentSection = nil
        stickyHeaderCurrentTitle = nil
        if let topConstraint = stickyHeaderTopConstraint, topConstraint.constant != 0 {
            topConstraint.constant = 0
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        updateStickyHeader()
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
        calendarCard.onLegendHeightSettled = { [weak self] in
            self?.refreshHeaderHeight()
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
                guard seq == strongSelf.timelineFirstPageSeq else { return }
                switch result {
                case .success(let list):
                    strongSelf.timelineEntries = list.entries ?? []
                    // B-G7: patch the day-panel copy from the fresh timeline copy
                    // before diff/reload, so both copies render the same state.
                    strongSelf.dayEntries = strongSelf.patchedEntries(strongSelf.dayEntries, withFresh: strongSelf.timelineEntries)
                    strongSelf.trashCountValue = list.trashCount ?? 0
                    strongSelf.countsValue = list.tlCounts
                    strongSelf.timelineHasMore = (list.entries ?? []).count >= strongSelf.pageLimit
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
                strongSelf.tableView.refreshControl?.endRefreshing()
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
    /// 钮不重播错峰、新格子走既有 0.32s 错峰，不另加转场动画（翻页
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
            if let cached = self.dayEntriesCache[key] {
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
        BearyAPI.shared.fetchTimelineDay(date: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                if strongSelf.dayKeyForLoad != key { return }
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
                    strongSelf.dayEntriesCache[key] = strongSelf.dayEntries
                    dayUnchanged = (clear == false && oldDaySignatures == strongSelf.dayEntries.map { strongSelf.entrySignature($0) })
                    // B-G7: patch the timeline copy from the fresh day-panel copy
                    // before reload, so both copies render the same state.
                    let timelineBefore = strongSelf.timelineEntries.map { strongSelf.entrySignature($0) }
                    strongSelf.timelineEntries = strongSelf.patchedEntries(strongSelf.timelineEntries, withFresh: strongSelf.dayEntries)
                    timelinePatchChanged = timelineBefore != strongSelf.timelineEntries.map { strongSelf.entrySignature($0) }
                    strongSelf.dayEntriesKey = key
                    strongSelf.dayState = .loaded
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
    /// 星期·篇数·状态一段（12.5pt 灰色，如“周日 · 1 篇 · 都未公开”，篇数带空格）。
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

    private func dayTitleForMs(_ ms: Int) -> String {
        guard let comps = BearyBeijingDay.components(ofMs: ms) else { return "" }
        let label = "\(comps.month) 月 \(comps.day) 日"
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
        // 80 包 B6：模型变化时重建待公开子集（timeline + day 去重，id 唯一）。
        do {
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            var snapshot: [String: Int] = [:]
            for entry in timelineEntries + dayEntries {
                guard let entryId = entry.id, entry.isPublic != true,
                      let pendingUntil = entry.publishPendingUntil, pendingUntil > nowMs else { continue }
                if snapshot[entryId] == nil { snapshot[entryId] = entry.publishAt ?? 0 }
            }
            pendingPublishDue = snapshot
        }
        // TL-7：当日面板的加载/失败/空态只反映在面板表头里，不再用整表背景空态
        // 覆盖时间线；背景空态只在时间线与当日面板双双无行时出现。
        let sections = currentSections()
        let hasRows = sections.contains { !$0.entries.isEmpty }
        let isLoginEmpty = (timelineState == .failed && timelineUnauthorized && timelineEntries.isEmpty)
        var newBackgroundKind = "none"
        if timelineState == .loading && timelineEntries.isEmpty && !hasRows {
            // M2：首屏加载态（此前 backgroundView 置 nil，只有下拉才有 spinner）。
            tableView.backgroundView = timelineLoadingView()
            newBackgroundKind = "loading"
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
            tableView.backgroundView = emptyView(title: "还没有日记", subtitle: "写下第一篇，它会出现在这里", actionTitle: "写一篇", action: { [weak self] in
                self?.onCompose?()
            }, iconName: "icon_diary")
            newBackgroundKind = "empty"
        } else {
            tableView.backgroundView = nil
        }
        // 本批 4b：空态切换补入场动效——种类变化且新背景非空时 0.2s 淡入
        // （站内 toast 同款淡入时长；已有动效的时长曲线一律不动）。
        if let backgroundView = tableView.backgroundView,
           newBackgroundKind != "none",
           newBackgroundKind != lastChromeBackgroundKind,
           UIAccessibility.isReduceMotionEnabled == false {
            backgroundView.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
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
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = BearyColors.gray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
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

    /// G15 分页失败 toast：委托 B 批统一 BearyToast。时间线是 Chrome 主 tab，
    /// FAB 常驻（下滑藏栏已拆除；搜索藏栏只针对搜索页），FAB 可见性在本页
    /// 拿不到 Chrome 的私有 fabContainerView，故调用方明确传 aboveFAB=true；
    /// 展示时长由旧 1.6s 统一为 2.0s，调用签名与文案、触发时机不变。
    private func showTimelineToast(message: String) {
        BearyToast.show(in: view, message: message, aboveFAB: true)
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

    /// 第 5 项公开：网页 doPublish 口径 POST /beary/api/entries/:id/publish，
    /// 先弹网页同款确认框（“确认公开？/ 公开后无法撤回或删除。确认后开始 24 小时倒计时，
    /// 期间可以取消公开。”），成功后整页刷新（倒计时态随新数据回来）；
    /// 失败 toast“公开失败，请重试”。在途去重，同一篇重复点按只发一次。
    private func handlePublishEntry(_ entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if publishBusyIds.contains(entryId) { return }
        let alert = UIAlertController(title: "确认公开？", message: "公开后无法撤回或删除。确认后开始 24 小时倒计时，期间可以取消公开。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "公开", style: .default, handler: { [weak self] _ in
            guard let strongSelf = self else { return }
            if strongSelf.publishBusyIds.contains(entryId) { return }
            strongSelf.publishBusyIds.insert(entryId)
            let safe = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
            BearyAPI.shared.requestVoid("/beary/api/entries/\(safe)/publish", method: "POST") { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    strongSelf.publishBusyIds.remove(entryId)
                    switch result {
                    case .success:
                        strongSelf.refreshAfterDetailChange()
                    case .failure:
                        strongSelf.showTimelineToast(message: "公开失败，请重试")
                    }
                }
            }
        }))
        present(alert, animated: true, completion: nil)
    }

    /// 第 5 项取消公开：网页 doPublishCancel 口径 POST /beary/api/entries/:id/publish/cancel，
    /// 无确认框（网页取消即直接发请求），成功后整页刷新，失败 toast“取消失败，请重试”。
    private func handleCancelPublishEntry(_ entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if publishBusyIds.contains(entryId) { return }
        publishBusyIds.insert(entryId)
        let safe = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
        BearyAPI.shared.requestVoid("/beary/api/entries/\(safe)/publish/cancel", method: "POST") { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.publishBusyIds.remove(entryId)
                switch result {
                case .success:
                    strongSelf.refreshAfterDetailChange()
                case .failure:
                    strongSelf.showTimelineToast(message: "取消失败，请重试")
                }
            }
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
        // 第 14 项 B：竖线按日组拼线——首行 top 8、末行 bottom -8、中间行 0/0。
        cell.setTimelineLineEdges(
            isFirstInDay: indexPath.row == 0,
            isLastInDay: indexPath.row == sections[indexPath.section].entries.count - 1
        )
        cell.onEditEntry = onEditEntry
        cell.onDeleteEntry = onDeleteEntry
        cell.onQuoteEntry = onQuoteEntry
        cell.onPublishEntry = { [weak self] entry in self?.handlePublishEntry(entry) }
        cell.onCancelPublishEntry = { [weak self] entry in self?.handleCancelPublishEntry(entry) }
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

    /// C7 滑动操作资格与私密操作行按钮完全一致：删除仅私密行（公开行无
    /// 删除钮），编辑仅私密且未过编辑期（与编辑钮显隐同口径：editDeadline
    /// 缺失即已锁）。触发后只复用 onDeleteEntry/onEditEntry（容器确认/
    /// 编辑器流程），不另写执行逻辑；不符资格的行返回 nil，即不可滑动。
    private static func isTimelineSwipeEditUnlocked(entry: Entry) -> Bool {
        guard let deadline = entry.editDeadline else { return false }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return nowMs < deadline
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return nil }
        let entry = sections[indexPath.section].entries[indexPath.row]
        guard entry.isPublic != true else { return nil }
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
        guard entry.isPublic != true, Self.isTimelineSwipeEditUnlocked(entry: entry) else { return nil }
        let edit = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.onEditEntry?(entry)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [edit])
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
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
