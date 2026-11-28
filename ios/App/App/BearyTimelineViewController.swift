import UIKit
import PhotosUI

// ===== beary 原生时间线页（含写作日历卡）=====
// 对照源（以 worker.js 为准，网页版 beary.html 与设计稿 layout_rest.html 为形态对照）：
// - 列表：GET /beary/api/entries?scope=timeline&limit=12（首屏；秒开批：
//   首拉改为 12 条，对齐广场 firstPageLimit=12；后续分页仍 limit=20），
//   游标 before=created_at（毫秒）+ before_id=entry.id；服务端排序 created_at DESC, id DESC；
//   响应含 entries、trash_count、tl_counts{total, priv, pub, next_pub}；单条 is_public = now >= publish_at。
//   首屏另带 slim=1（后端 patch 未上线前服务端忽略该参数、回包不变；上线后仅裁
//   卡片不渲染的死字段 author_cover/recipient_*/publish_pending_until，计数 likeCount、
//   回应 emotes、引用 quote、图片 images+imgDims 等卡片渲染字段一律保留，首帧不缺块、不补布局）。
// - 日历：GET /beary/api/calendar?month=YYYY-MM（仅本人、需登录），按 created_at 北京日界
//   聚合 days{日: {pub, priv}} + month_total + streak（今天没写则从昨天往前连续计数）。
// - 当日：GET /beary/api/entries?scope=timeline&date=YYYY-MM-DD（同为北京日界过滤），
//   请求 limit=200（网页 loadCalDay 口径）；服务端 worker.js 实测 clamp 到 50，
//   日限 10 篇/天，故 50 已兜底，传 200 只是与网页请求口径对齐。
// 约束：部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写；
// BearyAPI.swift 一律不动：日历与当日两个方法以 extension 形式放在本文件内，走既有的
// BearyAPI.request 通用请求（URLSession.shared 共享 cookie，401 走 onUnauthorized 通知，
// 回调不在主线程，碰 UI 一律 DispatchQueue.main.async）；颜色只用 BearyColors，
// 不新增玻璃效果，不用 SF Symbol（图标一律 BearyIconImages + 既有 icon_* 资产），
// 无 force unwrap、无裸 id 变量名。本文件不接线：容器（SceneDelegate 侧）负责实例化、
// 设三个回调、做 600 居中列（宽 >=821 时）与底栏分段器/FAB 的避让（表底 inset 已留 90）。

// MARK: - 日历接口模型（BearyAPI.request + convertFromSnakeCase 解码）

struct BearyCalendarDayCount: Codable {
    var pub: Int?
    var priv: Int?
    /// 四色圆点新增档（服务端新增键，旧快照缺省即 nil→0）：仅好友、限时。
    /// 服务端 pub 仍含限时、priv 仍含仅好友（网页旧口径不动），App 侧
    /// 橙 = pub - limited、蓝 = priv - friends（见 calendarDayCounts）。
    var friends: Int?
    var limited: Int?
}

struct BearyCalendarMonthResponse: Codable {
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
    /// vis 与 date 可叠加（时间线筛子口径）；vis 为 nil 时不发参数（= 缺省全部）。
    func fetchTimelineDay(date: String, vis: String? = nil, completion: @escaping (Result<EntryList, APIError>) -> Void) {
        var query: [String: String] = ["scope": "timeline", "date": date, "limit": "200"]
        if let v = vis, !v.isEmpty { query["vis"] = v }
        request("/beary/api/entries", query: query, completion: completion)
    }

    /// 秒开·首屏再瘦：时间线首屏专用取数（scope=timeline + limit=12 + slim=1）。
    /// 不走 BearyAPI.fetchEntries（其 limit 封顶 50 且无 slim 参数；本文件既有
    /// 日历/当日方法同款 extension 写法，走既有 BearyAPI.request 通用请求）。
    /// slim=1 在后端 patch 上线前被服务端忽略（回包不变，首屏照常 12 条），
    /// 上线后只裁卡片不渲染的字段，卡片渲染字段与计数一律保留（见文件头注释）。
    /// vis 为 nil 时不发参数（= 缺省全部，默认请求与旧请求一字不差）。
    func fetchTimelineFirstPage(vis: String? = nil, completion: @escaping (Result<EntryList, APIError>) -> Void) {
        var query: [String: String] = ["scope": "timeline", "limit": "12", "slim": "1"]
        if let v = vis, !v.isEmpty { query["vis"] = v }
        request("/beary/api/entries", query: query, completion: completion)
    }
}

// MARK: - 日历几何标记（网页 calMarksHtml 口径，原样移植）

enum BearyCalendarMarkColor {
    case published
    case unpublished
    case friends
    case limited

    var uiColor: UIColor {
        switch self {
        case .published: return BearyColors.orange
        case .unpublished: return BearyColors.blue
        case .friends: return BearyColors.ink
        case .limited: return BearyColors.limitedPurple
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
    /// 时间线改版 v14：几何编码整段删除——圆点数与每天篇数一一对应，
    /// 四色：公开橙、私密蓝、仅好友墨、限时紫（规范四档代表色）。
    /// 顺序：公开 → 私密 → 仅好友 → 限时；单日总共最多 5 点
    /// （格宽约 41pt，5 点 × 6pt + 间距刚好放下；超 5 篇的日子只画前 5 点，
    /// 篇数仍以当日面板标题为准）。
    static func marks(published: Int, unpublished: Int, friends: Int = 0, limited: Int = 0) -> [BearyCalendarMark] {
        var out: [BearyCalendarMark] = []
        for _ in 0..<max(published, 0) { out.append(BearyCalendarMark(kind: .dot, color: .published, size: 6)) }
        for _ in 0..<max(unpublished, 0) { out.append(BearyCalendarMark(kind: .dot, color: .unpublished, size: 6)) }
        for _ in 0..<max(friends, 0) { out.append(BearyCalendarMark(kind: .dot, color: .friends, size: 6)) }
        for _ in 0..<max(limited, 0) { out.append(BearyCalendarMark(kind: .dot, color: .limited, size: 6)) }
        return Array(out.prefix(5))
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
    /// 四色圆点新增档（展示口径：橙 = 公开且非限时、蓝 = 私密且非仅好友；
    /// 服务端 pub 含限时、priv 含仅好友，换算在 calendarDayCounts 里做）。
    var friends: Int = 0
    var limited: Int = 0
    var dataLoaded: Bool
    var dataFailed: Bool

    var key: String {
        return BearyBeijingDay.dayKey(year: year, month: month, day: day)
    }

    /// 网页口径（calCellBtn）：缓存缺省即 {pub:0,priv:0}，空日禁用；未来日禁用；
    /// 跨月占位格禁用。未加载月份的格子因此也是禁用态，待月份补拉到达、
    /// renderCalendar 重渲后才启用（与网页 calPatchDots 到达后启用一致）。
    var isEnabled: Bool {
        if isOffMonth || isFuture { return false }
        return published + unpublished + friends + limited > 0
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
            // 审计-时间线：320pt 下格宽约 41.1pt（(320-32)/7），小于 44pt 热区标准，为已知局限；只加注释，不改数值。
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
        // 审计-时间线：三态区分——未加载/失败不再谎报“无日记”（重试入口在失败悬浮条与统计行，不在本格）；
        // 占位格报“非本月”，不报篇数；今天/已选中补 trait 与 label 后缀。
        if day.isOffMonth {
            accessibilityLabel = "\(day.month)月\(day.day)日，非本月"
        } else if !day.dataLoaded {
            accessibilityLabel = day.dataFailed ? "\(day.month)月\(day.day)日，日历加载失败" : "\(day.month)月\(day.day)日，加载中"
        } else if day.published + day.unpublished + day.friends + day.limited > 0 {
            accessibilityLabel = String(format: NSLocalizedString("timeline.day.accessibility", comment: ""), day.month, day.day, day.published + day.unpublished + day.friends + day.limited)
        } else {
            accessibilityLabel = "\(day.month)月\(day.day)日，无日记"
        }
        var dayTraits: UIAccessibilityTraits = [.button]
        if day.isSelected { dayTraits.insert(.selected) }
        accessibilityTraits = dayTraits
        if day.isToday { accessibilityLabel = (accessibilityLabel ?? "") + "，今天" }
        if day.isSelected { accessibilityLabel = (accessibilityLabel ?? "") + "，已选中" }
        markView.marks = day.isOffMonth ? [] : BearyCalendarMarks.marks(published: day.published, unpublished: day.unpublished, friends: day.friends, limited: day.limited)
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
            // 时间线改版 v14：选中日改橙色描边圆圈（墨底白字废止）。
            numberLabel.textColor = BearyColors.deepOrangeText
            numberLabel.font = UIFont.boldSystemFont(ofSize: 15)
            numberLabel.backgroundColor = .clear
            numberLabel.layer.borderWidth = 1.5
            numberLabel.layer.bearyDynamicBorderColor = BearyColors.orange
        } else if day.isToday {
            // 今天（未选中）只橙字、不描边，与选中日的橙圈区分。
            numberLabel.textColor = BearyColors.deepOrangeText
            numberLabel.font = BearyDynamicType.smallActionFont()
            numberLabel.backgroundColor = .clear
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

/// 年月标题里的数字把手（时间线改版 v14）：年份数字与月份数字各一个，
/// 点按聚焦（橙字）后按上下方向键调整（上 +1、下 -1）。长按拖动的
/// 手势由卡片挂在 label 上，不在本类里。
final class BearyCalendarTitleNumberLabel: UILabel {
    var onStep: ((Int) -> Void)?
    /// 聚焦/亮起态：橙字；平时墨字。长按 0.4 秒亮起与点按聚焦共用本态。
    var isTitleFocused: Bool = false {
        didSet {
            textColor = isTitleFocused ? BearyColors.deepOrangeText : BearyColors.ink
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(stepUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(stepDown)),
        ]
    }

    @objc private func stepUp() { onStep?(1) }
    @objc private func stepDown() { onStep?(-1) }
}

// MARK: - 日历卡（网页 .cal-card：边框 1 line、圆角 14、padding 16、底色 bg（与页面背景同色））

final class BearyCalendarCardView: UIView {
    enum ViewMode {
        case week
        case month
    }

    var onSelectDay: ((BearyCalendarDay) -> Void)?
    var onToggleView: (() -> Void)?
    /// 周/月内前后步进（左滑 +1、右滑 -1；周模式 ±7 天、月模式 ±1 月，VC 内换算）。
    var onStepCalendar: ((Int) -> Void)?
    var onGoToday: (() -> Void)?
    /// 年月数字把手步进（VC 内换算：年 ±1 年、月 ±1 月跨年）。
    var onStepYear: ((Int) -> Void)?
    var onStepMonth: ((Int) -> Void)?
    /// R15-L1：日历失败重试入口（卡内行，见 setLoadFailed）。旧口径在统计行
    /// 与顶部悬浮条各放一处，本支收掉两处、只留卡内一处。
    var onRetry: (() -> Void)?

    private let yearNumberLabel = BearyCalendarTitleNumberLabel()
    private let monthNumberLabel = BearyCalendarTitleNumberLabel()
    private let titleTextStack = UIStackView()
    private let titleRow = UIStackView()
    private let todayButton = BearyHit44Button(type: .system)
    private let gestureHintLabel = UILabel()
    /// 当前视图模式（render 时更新；上下轻扫的展开/收起、提示文案按它分流）。
    private(set) var currentMode: ViewMode = .week
    /// 年月长按拖动的锚点 y（手势起始触点）与已消耗量（30pt 一步，步进后扣掉）。
    private var titleDragAnchorY: CGFloat = 0
    private var titleDragConsumedY: CGFloat = 0
    private let gridStack = UIStackView()
    /// R15-L1：日历失败行（文案 + 文字重试钮），默认隐藏；失败时由 VC 经
    /// setLoadFailed 显隐。行内重试钮是 BearyHit44Button，视觉小、热区 44。
    private let calendarFailedLabel = UILabel()
    private let calendarFailedRetryButton = BearyButton.retryInline()
    private let calendarFailedRow = UIStackView()
    private var dayButtons: [BearyCalendarDayButton] = []
    /// 按日期 key 复用的日期按钮（网页 calReuseGrid 口径）：切换视图/数据刷新时
    /// 只移动/新建格子，不整表重建；复用节点不重播月格入场错峰。
    private var buttonByKey: [String: BearyCalendarDayButton] = [:]
    /// 审计-时间线：上次渲染的格子签名（月份回包增量用；签名不变时 render 直接返回，不重建网格行）。
    private var lastRenderedDaysSignature: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 周/月视图日历卡底色均与页面背景同色（见 render 处注释）。
        backgroundColor = BearyColors.bg
        layer.borderWidth = 1
        layer.bearyDynamicBorderColor = BearyColors.line
        layer.cornerRadius = BearyCorners.single
        layer.masksToBounds = true

        // 年月标题常驻：年份数字与月份数字是两个分开的把手（各管各的），
        // 其间“年”“月”两字是静态文本；标题行右侧是“回到今天”小药丸。
        yearNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        yearNumberLabel.font = BearyDynamicType.cardTitleFont()
        yearNumberLabel.adjustsFontForContentSizeCategory = true
        yearNumberLabel.textColor = BearyColors.ink
        yearNumberLabel.isUserInteractionEnabled = true
        yearNumberLabel.accessibilityHint = NSLocalizedString("timeline.handle.adjust_hint", comment: "")
        monthNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        monthNumberLabel.font = BearyDynamicType.cardTitleFont()
        monthNumberLabel.adjustsFontForContentSizeCategory = true
        monthNumberLabel.textColor = BearyColors.ink
        monthNumberLabel.isUserInteractionEnabled = true
        monthNumberLabel.accessibilityHint = NSLocalizedString("timeline.handle.adjust_hint", comment: "")
        let yearSuffixLabel = UILabel()
        yearSuffixLabel.translatesAutoresizingMaskIntoConstraints = false
        yearSuffixLabel.font = BearyDynamicType.cardTitleFont()
        yearSuffixLabel.adjustsFontForContentSizeCategory = true
        yearSuffixLabel.textColor = BearyColors.ink
        yearSuffixLabel.text = NSLocalizedString("timeline.title.year_suffix", comment: "")
        let monthSuffixLabel = UILabel()
        monthSuffixLabel.translatesAutoresizingMaskIntoConstraints = false
        monthSuffixLabel.font = BearyDynamicType.cardTitleFont()
        monthSuffixLabel.adjustsFontForContentSizeCategory = true
        monthSuffixLabel.textColor = BearyColors.ink
        monthSuffixLabel.text = NSLocalizedString("timeline.title.month_suffix", comment: "")
        titleTextStack.translatesAutoresizingMaskIntoConstraints = false
        titleTextStack.axis = .horizontal
        titleTextStack.alignment = .center
        titleTextStack.spacing = 2 // beary-lint: allow
        titleTextStack.addArrangedSubview(yearNumberLabel)
        titleTextStack.addArrangedSubview(yearSuffixLabel)
        titleTextStack.addArrangedSubview(monthNumberLabel)
        titleTextStack.addArrangedSubview(monthSuffixLabel)
        // 年月把手手势：点按聚焦（方向键调整）、长按 0.4 秒亮起后上下拖动
        // （30pt 一步）；点按须等长按失败，免得一次长按拖动又聚焦。
        let yearTap = UITapGestureRecognizer(target: self, action: #selector(didTapYearNumber))
        let yearLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleYearLongPress(_:)))
        yearLongPress.minimumPressDuration = 0.4
        yearLongPress.allowableMovement = .greatestFiniteMagnitude
        yearTap.require(toFail: yearLongPress)
        yearNumberLabel.addGestureRecognizer(yearTap)
        yearNumberLabel.addGestureRecognizer(yearLongPress)
        yearNumberLabel.onStep = { [weak self] delta in self?.onStepYear?(delta) }
        let monthTap = UITapGestureRecognizer(target: self, action: #selector(didTapMonthNumber))
        let monthLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMonthLongPress(_:)))
        monthLongPress.minimumPressDuration = 0.4
        monthLongPress.allowableMovement = .greatestFiniteMagnitude
        monthTap.require(toFail: monthLongPress)
        monthNumberLabel.addGestureRecognizer(monthTap)
        monthNumberLabel.addGestureRecognizer(monthLongPress)
        monthNumberLabel.onStep = { [weak self] delta in self?.onStepMonth?(delta) }

        // “回到今天”小药丸：surface2 底、圆角 14、高 28，默认隐藏；
        // 显隐只由 VC 的 setTodayButtonVisible 控制（选中日非今天时浮现）。
        let todayButtonHeight: CGFloat = 28
        todayButton.translatesAutoresizingMaskIntoConstraints = false
        todayButton.backgroundColor = BearyColors.surface2
        todayButton.layer.cornerRadius = todayButtonHeight / 2
        todayButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 12))
        todayButton.titleLabel?.adjustsFontForContentSizeCategory = true
        todayButton.setTitleColor(BearyColors.ink, for: .normal)
        todayButton.setTitle(NSLocalizedString("timeline.today_button", comment: ""), for: .normal)
        todayButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: BearySpace.md, bottom: 0, right: BearySpace.md)
        todayButton.accessibilityLabel = NSLocalizedString("timeline.today_button", comment: "")
        todayButton.addTarget(self, action: #selector(didTapToday), for: .touchUpInside)
        todayButton.bearyAddPressFeedback()
        todayButton.isHidden = true
        todayButton.alpha = 0

        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        let titleSpacer = UIView()
        titleSpacer.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addArrangedSubview(titleTextStack)
        titleRow.addArrangedSubview(titleSpacer)
        titleRow.addArrangedSubview(todayButton)

        // 星期头行按 locale 取首日重排（#2092 同口径，不写死周一）：
        // veryShortWeekdaySymbols 本就是周日起排，按 firstWeekday 旋转；
        // 取不到 7 个符号时回落中文周一起始（不裸奔）。
        let weekdayRow = UIStackView()
        weekdayRow.translatesAutoresizingMaskIntoConstraints = false
        weekdayRow.axis = .horizontal
        weekdayRow.distribution = .fillEqually
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let weekdayNames: [String] = symbols.count == 7 ? symbols : [NSLocalizedString("timeline.weekday.sun", comment: ""), NSLocalizedString("timeline.weekday.mon", comment: ""), NSLocalizedString("timeline.weekday.tue", comment: ""), NSLocalizedString("timeline.weekday.wed", comment: ""), NSLocalizedString("timeline.weekday.thu", comment: ""), NSLocalizedString("timeline.weekday.fri", comment: ""), NSLocalizedString("timeline.weekday.sat", comment: "")]
        let firstWeekday = BearyBeijingDay.localeFirstWeekday
        for offset in 0..<7 {
            let label = UILabel()
            label.text = weekdayNames[(firstWeekday - 1 + offset) % 7]
            // 8-3 例外：星期单字属日历格装饰头，不缩放。
            label.font = UIFont.systemFont(ofSize: 12)
            label.textColor = BearyColors.gray
            label.textAlignment = .center
            weekdayRow.addArrangedSubview(label)
        }

        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridStack.axis = .vertical

        // 手势提示（模式相关文案见 render）：周视图下拉展开、左右切周；
        // 月视图上滑收起、左右切月。
        gestureHintLabel.translatesAutoresizingMaskIntoConstraints = false
        gestureHintLabel.font = BearyDynamicType.captionFont()
        gestureHintLabel.adjustsFontForContentSizeCategory = true
        gestureHintLabel.textColor = BearyColors.gray
        gestureHintLabel.textAlignment = .center
        gestureHintLabel.text = NSLocalizedString("timeline.hint.expand_week", comment: "")

        let outer = UIStackView(arrangedSubviews: [titleRow, weekdayRow, gridStack, gestureHintLabel])
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.axis = .vertical
        outer.spacing = 0
        outer.setCustomSpacing(8, after: titleRow)
        outer.setCustomSpacing(BearySpace.sm, after: weekdayRow)
        outer.setCustomSpacing(4, after: gridStack)
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: BearySpace.lg),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BearySpace.lg),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BearySpace.lg),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -BearySpace.lg),
            todayButton.heightAnchor.constraint(equalToConstant: todayButtonHeight),
        ])

        // 轻扫手势（卡片整块）：左/右切周或切月（VC 内按模式换算），
        // 下滑只在周视图展开整月、上滑只在月视图收起回周条；慢速拖动
        // 仍走列表滚动（不抢滚动），轻扫才触发——与预览的下拉/上滑口径
        // 一致，见 PR 说明。
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(didSwipeLeft))
        swipeLeft.direction = .left
        swipeLeft.cancelsTouchesInView = false
        addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(didSwipeRight))
        swipeRight.direction = .right
        swipeRight.cancelsTouchesInView = false
        addGestureRecognizer(swipeRight)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(didSwipeDown))
        swipeDown.direction = .down
        swipeDown.cancelsTouchesInView = false
        addGestureRecognizer(swipeDown)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(didSwipeUp))
        swipeUp.direction = .up
        swipeUp.cancelsTouchesInView = false
        addGestureRecognizer(swipeUp)

        // R15-L1：失败行挂在网格下方（卡内最后一行），默认隐藏、不占位；
        // 显隐只由 setLoadFailed 改，render 的格子签名不管它。
        calendarFailedLabel.translatesAutoresizingMaskIntoConstraints = false
        calendarFailedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        calendarFailedLabel.adjustsFontForContentSizeCategory = true
        calendarFailedLabel.textColor = BearyColors.gray
        calendarFailedLabel.text = "日历加载失败"
        calendarFailedLabel.setContentHuggingPriority(.required, for: .horizontal)
        calendarFailedRetryButton.translatesAutoresizingMaskIntoConstraints = false
        calendarFailedRetryButton.addTarget(self, action: #selector(didTapCalendarRetry), for: .touchUpInside)
        calendarFailedRetryButton.bearyAddPressFeedback()
        calendarFailedRetryButton.accessibilityLabel = "日历加载失败，重试"
        calendarFailedRow.translatesAutoresizingMaskIntoConstraints = false
        calendarFailedRow.axis = .horizontal
        calendarFailedRow.spacing = 8
        calendarFailedRow.alignment = .center
        calendarFailedRow.addArrangedSubview(calendarFailedLabel)
        calendarFailedRow.addArrangedSubview(calendarFailedRetryButton)
        calendarFailedRow.addArrangedSubview(UIView())
        calendarFailedRow.isHidden = true
        outer.addArrangedSubview(calendarFailedRow)
        outer.setCustomSpacing(8, after: gestureHintLabel)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.bearyDynamicBorderColor = BearyColors.line
    }

    /// 年月标题只在值变化时更新：同月内切日期标题值不变时不重复赋值、
    /// 不重排；fadeTitleForDaySwitch 只在标题真变了时才淡入，同值切日期
    /// 不再先置 0 再淡回（即此前“标题闪一下”的来源）。
    private var titleChangedSinceSet = false

    /// 年月标题常驻（周/月视图同一块日历，标题只写年月）：年份与月份
    /// 数字分开设值（各是独立的长按把手），值不变时不重复赋值。
    func setYearMonth(year: Int, month: Int) {
        let yearText = "\(year)"
        let monthText = "\(month)"
        guard yearNumberLabel.text != yearText || monthNumberLabel.text != monthText else {
            titleChangedSinceSet = false
            return
        }
        yearNumberLabel.text = yearText
        monthNumberLabel.text = monthText
        yearNumberLabel.accessibilityLabel = String(format: NSLocalizedString("timeline.handle.year_accessibility", comment: ""), year)
        monthNumberLabel.accessibilityLabel = String(format: NSLocalizedString("timeline.handle.month_accessibility", comment: ""), month)
        titleChangedSinceSet = true
    }

    /// N3：换日时日历标题淡入（0.18s、只动 alpha；减动效时调用方不调本方法）。
    /// 标题是卡内常驻节点，不重建、不重播其他元素；标题值未变时直接
    /// 返回，不播淡入。
    func fadeTitleForDaySwitch() {
        guard titleChangedSinceSet else { return }
        titleChangedSinceSet = false
        titleTextStack.alpha = 0
        UIView.animate(withDuration: BearyMotion.micro, animations: {
            self.titleTextStack.alpha = 1
        })
    }

    /// “回到今天”小药丸显隐（VC 在每次 renderCalendar 末尾重算）：
    /// 浮现淡入＋回弹缩放（0.35s、阻尼 0.7）、隐藏淡出后才 isHidden
    /// （栈内不占位）；减动效直设终值。重复调用同态时直接返回，不重播。
    func setTodayButtonVisible(_ visible: Bool) {
        if visible {
            guard todayButton.isHidden || todayButton.alpha < 1 else { return }
            todayButton.isHidden = false
            if UIAccessibility.isReduceMotionEnabled {
                todayButton.alpha = 1
                todayButton.transform = .identity
            } else {
                todayButton.alpha = 0
                todayButton.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                UIView.animate(withDuration: BearyMotion.screen, delay: 0, usingSpringWithDamping: BearyMotion.springDamping, initialSpringVelocity: 0.5, options: [.beginFromCurrentState], animations: {
                    self.todayButton.alpha = 1
                    self.todayButton.transform = .identity
                }, completion: nil)
            }
        } else {
            guard !todayButton.isHidden else { return }
            if UIAccessibility.isReduceMotionEnabled {
                todayButton.alpha = 0
                todayButton.isHidden = true
            } else {
                UIView.animate(withDuration: BearyMotion.micro, animations: {
                    self.todayButton.alpha = 0
                    self.todayButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
                }, completion: { _ in
                    self.todayButton.isHidden = true
                    self.todayButton.transform = .identity
                })
            }
        }
    }

    /// R15-L1：日历失败行显隐（任一可视月份失败即显，见 VC
    /// updateStatsLine；成功/切走即藏）。返回是否真的改了显隐——VC 据此
    /// 决定要不要重算表头高度（行高约 20pt，显隐即表头高度变化）。
    /// r17-C1：文案三态由调用方按失败/缓存组合传入（无数据「日历加载失败」、
    /// 有旧快照「显示的是上次的数据」、只到一部分「只加载了一部分」）；
    /// 文案只在显行时写，藏行时不动（下次显时再写）。
    @discardableResult
    func setLoadFailed(_ failed: Bool, text: String = "日历加载失败") -> Bool {
        let shouldHide = !failed
        if failed {
            calendarFailedLabel.text = text
            calendarFailedRetryButton.accessibilityLabel = text + "，重试"
        }
        guard calendarFailedRow.isHidden != shouldHide else { return false }
        calendarFailedRow.isHidden = shouldHide
        return true
    }

    @objc private func didTapCalendarRetry() {
        onRetry?()
    }

    /// weekKeys：月视图入场错峰时要跳过的本周日期 key（网页 calStaggerMonthCells
    /// 口径：本周格子不加 .cal-in）。周视图下本参数无用。
    func render(days: [BearyCalendarDay], mode: ViewMode, weekKeys: Set<String> = []) {
        currentMode = mode
        // 手势提示按模式换文案（周视图：下拉展开、左右切周；月视图：上滑收起、左右切月）。
        gestureHintLabel.text = (mode == .week) ? NSLocalizedString("timeline.hint.expand_week", comment: "") : NSLocalizedString("timeline.hint.collapse_month", comment: "")
        // 审计-时间线：月份回包增量——格子签名不变时不重建网格行（复用格子不重播错峰）；
        // 签名含 key/跨月/未来/今天/选中/篇数/加载态/失败态，任一变化即重建。
        let daysSignature = "\(mode)|" + days.map { "\($0.key)|\($0.isOffMonth)|\($0.isFuture)|\($0.isToday)|\($0.isSelected)|\($0.published)|\($0.unpublished)|\($0.friends)|\($0.limited)|\($0.dataLoaded)|\($0.dataFailed)" }.joined(separator: ";")
        if daysSignature == lastRenderedDaysSignature { return }
        lastRenderedDaysSignature = daysSignature
        // 日历卡底色与页面背景同色：周/月视图卡填充均走 BearyColors.bg（动态色，
        // 浅色白、深色纯黑，深浅自动跟随），与页面底无色差；卡片边线与圆角不动，
        // 日记卡等其他卡片一律不动。（#410 只改了月视图，周视图仍走 surface
        // 深灰，本支补齐周视图。）
        backgroundColor = BearyColors.bg
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
        // 现与月视图同口径（0.26s、每格 0.03s 错峰、封顶 0.24s、curveEaseOut；
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
                        UIView.animate(withDuration: BearyMotion.normal, delay: delay, options: .curveEaseOut, animations: {
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

    @objc private func didTapToday() {
        onGoToday?()
    }

    /// 轻扫：左滑去下一周/月、右滑回上一周/月（VC 内按模式换算步长）；
    /// 下滑只在周视图展开整月、上滑只在月视图收起回周条。
    @objc private func didSwipeLeft() {
        resignYearMonthFocus()
        onStepCalendar?(1)
    }

    @objc private func didSwipeRight() {
        resignYearMonthFocus()
        onStepCalendar?(-1)
    }

    @objc private func didSwipeDown() {
        guard currentMode == .week else { return }
        resignYearMonthFocus()
        onToggleView?()
    }

    @objc private func didSwipeUp() {
        guard currentMode == .month else { return }
        resignYearMonthFocus()
        onToggleView?()
    }

    /// 年月数字点按聚焦：成为第一响应者（方向键可用）并亮起；
    /// 另一数字聚焦时先收回。切日/切视图/轻扫时收回（见 didTapDay 与各轻扫）。
    @objc private func didTapYearNumber() {
        focusYearMonthLabel(yearNumberLabel)
    }

    @objc private func didTapMonthNumber() {
        focusYearMonthLabel(monthNumberLabel)
    }

    private func focusYearMonthLabel(_ label: BearyCalendarTitleNumberLabel) {
        for other in [yearNumberLabel, monthNumberLabel] where other !== label {
            other.isTitleFocused = false
            other.resignFirstResponder()
        }
        label.isTitleFocused = true
        _ = label.becomeFirstResponder()
    }

    /// 收回年月聚焦（切日/切视图/轻扫时调，不改标题值）。
    func resignYearMonthFocus() {
        for label in [yearNumberLabel, monthNumberLabel] {
            label.isTitleFocused = false
            label.resignFirstResponder()
        }
    }

    /// 年月长按拖动（0.4 秒亮起后上下拖，30pt 一步）：下拖 +1、上拖 -1；
    /// 年只换年、月只换月（拖过 12 月自动跨年由 VC 的 shiftedMonth 处理）。
    @objc private func handleYearLongPress(_ gesture: UILongPressGestureRecognizer) {
        handleTitleLongPress(gesture, isYear: true)
    }

    @objc private func handleMonthLongPress(_ gesture: UILongPressGestureRecognizer) {
        handleTitleLongPress(gesture, isYear: false)
    }

    private func handleTitleLongPress(_ gesture: UILongPressGestureRecognizer, isYear: Bool) {
        let label = isYear ? yearNumberLabel : monthNumberLabel
        switch gesture.state {
        case .began:
            label.isTitleFocused = true
            titleDragAnchorY = gesture.location(in: label).y
            titleDragConsumedY = 0
        case .changed:
            let deltaY = gesture.location(in: label).y - titleDragAnchorY - titleDragConsumedY
            let steps = Int(deltaY / 30)
            guard steps != 0 else { return }
            titleDragConsumedY += CGFloat(steps) * 30
            if isYear {
                onStepYear?(steps)
            } else {
                onStepMonth?(steps)
            }
        case .ended, .cancelled, .failed:
            label.isTitleFocused = false
            titleDragAnchorY = 0
            titleDragConsumedY = 0
        default:
            break
        }
    }

    @objc private func didTapDay(_ sender: BearyCalendarDayButton) {
        guard let day = sender.dayValue else { return }
        // 5-22 第二道守卫：跨月占位格即使上层 isEnabled 漏算仍不可点，
        // 此处直接返回，不进 selectDay。
        guard !day.isOffMonth else { return }
        resignYearMonthFocus()
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
    /// 限时虚线边框（BearyDashedBorderView：首页同款 1.5pt dashed、line 色、
    /// 圆角 16；由约束钉在 cardView 上内缩 8/6，自身布局时按 bounds 重画，
    /// 引用卡进栈后框高自动跟上，不再停留在不含引用的旧矩形上）。
    private let ephemeralBorderView = BearyDashedBorderView()
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
    /// 本组与卡片同款：官方 icon_location 13 灰 + 13 灰文案；公开篇作者本人
    /// 也只看区级，不再另附提示行；文案与脱敏全走 BearyLocationDisplay。
    private let timelineLocationIconView: UIImageView =
        BearyIconImageView.make(image: BearyLocationIcon.image(pointSize: 13))
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
    private lazy var timelineLocationLineRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [timelineLocationIconView, timelineLocationLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 4
        st.alignment = .center
        return st
    }()
    private lazy var timelineLocationStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [timelineLocationLineRow])
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

    /// 九宫格入口：图片数 > 3 时在图片条下方弹起；纯文字 pill（卡片同款，
    /// surface2 底、墨字、13 semibold、圆角 single 12、高 32）。点按走
    /// onNineGridTapped，Plus 门控在容器侧。
    private lazy var nineGridButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        btn.titleLabel?.adjustsFontForContentSizeCategory = true
        btn.setTitle("九宫格", for: .normal)
        btn.setTitleColor(BearyColors.ink, for: .normal)
        btn.backgroundColor = BearyColors.surface2
        btn.layer.cornerRadius = 12
        btn.clipsToBounds = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        btn.addTarget(self, action: #selector(nineGridButtonTapped), for: .touchUpInside)
        return btn
    }()

    /// 九宫格按钮容器：左贴内容缘，栈内隐藏时自动压零、不留空位。
    private lazy var nineGridWrapView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.alpha = 0
        v.addSubview(nineGridButton)
        NSLayoutConstraint.activate([
            nineGridButton.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            nineGridButton.topAnchor.constraint(equalTo: v.topAnchor),
            nineGridButton.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            nineGridButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        return v
    }()

    /// 九宫格入口隐藏动画代次：收起动画完成时若已有新一轮展开，须以新态为准、不再藏。
    private var nineGridHideToken = 0

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
    // TL-3 引用卡与私密操作行：C4 起复用公共 BearyQuoteCardView，
    // 自绘卡（标题 11.5 不缩放、正文限 2 行、每 configure 新建缩略图视图）已删。
    private let quoteCard = BearyQuoteCardView()
    private var currentEntry: Entry?
    /// 内联 GIF 覆盖层（正文＋标题各一）：按 label 实际排版贴动画 GIF，
    /// 只播可见的；长按 GIF 弹「添加表情」进我的库。
    private let bodyGIFOverlay = BearyInlineGIFOverlay()
    private let titleGIFOverlay = BearyInlineGIFOverlay()
    var onEditEntry: ((Entry) -> Void)?
    var onDeleteEntry: ((Entry) -> Void)?
    var onQuoteEntry: ((String) -> Void)?
    /// N7 时间线图片灯箱：主图条点按回调（keys=本条过滤后图 key，index=点按位置），
    /// VC 侧复用独立文件内的 BearyEntryImageViewerViewController 全屏弹出；
    /// 另传被点缩略图已显示的 UIImage，灯箱打开先显它。
    /// 引用卡小图不走此路（点按引用卡仍走 onQuoteEntry 打开被引用日记）。
    var onTapImages: (([String], Int, CGRect?, UIImage?) -> Void)?
    /// 九宫格入口点按：容器接线（Plus 门控 + 开网格都在容器侧，本处只转发）。
    var onNineGridTapped: ((UIButton) -> Void)?
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
        // （线宽 0.5pt、线色 BearyColors.line 动态色，浅 #dbdbdb／深 #3a3a40，
        // 深浅切换自动跟随，无需手动重刷）。
        // 限时虚线边框视图（ephemeralBorderView）是独立语义指示，不动。
        cardView.backgroundColor = BearyColors.bg
        cardView.layer.borderWidth = 0
        cardView.layer.cornerRadius = 0
        cardView.layer.masksToBounds = true
        // 限时虚线边框视图（插 cardView 最底层、不挡内容；存活期显）。
        ephemeralBorderView.translatesAutoresizingMaskIntoConstraints = false
        ephemeralBorderView.isHidden = true
        cardView.insertSubview(ephemeralBorderView, at: 0)
        NSLayoutConstraint.activate([
            ephemeralBorderView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 6),
            ephemeralBorderView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 8),
            ephemeralBorderView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),
            ephemeralBorderView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -6),
        ])

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
        // 112 视觉扫查：同行时间/天气/心情均已走 scaledFont（见上方 8-3），@ 行此前独漏；
        // 默认档仍为 12 粗体，仅跟随系统字号，170 上限与单行截断口径不动。
        recipientLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 12))
        recipientLabel.adjustsFontForContentSizeCategory = true
        recipientLabel.textColor = BearyColors.ink
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
        thumbsScrollView.delaysContentTouches = false
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
            thumbsStack.heightAnchor.constraint(equalToConstant: BearyImageStrip.height),
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

        quoteCard.translatesAutoresizingMaskIntoConstraints = false
        // 点按走共享卡 onTapped（卡片手势 + 来源行按钮同一路）；gone/locked
        // 不导航的守卫仍在 quoteTapped 内，不凭渲染快照放行。
        quoteCard.onTapped = { [weak self] in self?.quoteTapped() }
        quoteCard.onExpansionChanged = { [weak self] in self?.notifyQuoteExpanded() }
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        // 2026-10-29 改版：⋯ 菜单钮接替原 meta 行末地球钮的位置，
        // 21pt 灰色图标、28×28 帧（BearyHit44Button 扩后热区仍 44）。
        if let moreImage = BearyIconImages.image(named: "icon_more", pointSize: 24) {
            moreButton.setImage(moreImage, for: .normal)
        }
        moreButton.tintColor = BearyColors.gray
        moreButton.imageView?.contentMode = .scaleAspectFit
        moreButton.accessibilityLabel = "更多操作"
        moreButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        moreButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        moreButton.bearyAddPressFeedback()

        // 批 E 补漏：位置行落点 = 图片条 → 引用卡 → 位置行 → 足行（操作行一带），与卡片
        // “图片条之后、操作行之前”同序；图片条后的动态间距（configure 内按有图
        // 9 / 无图 0）现为图片条→引用卡间距，位置行隐藏时栈自动塌掉不留空行。
        let cardStack = UIStackView(arrangedSubviews: [metaStack, titleLabel, contentLabel, thumbsScrollView, nineGridWrapView, quoteCard, timelineLocationStack, footStack])
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.axis = .vertical
        cardStack.spacing = 0
        cardStack.setCustomSpacing(12, after: metaStack)
        // 标题→正文 6（2026-11-05 ChatGPT 间距跟进，与卡片/详情一致，#904 为 4）。
        cardStack.setCustomSpacing(6, after: titleLabel)
        cardStack.setCustomSpacing(14, after: contentLabel)
        cardStack.setCustomSpacing(12, after: thumbsScrollView)
        // 九宫格按钮在图片条与引用卡之间时，图片条→按钮、按钮→引用卡各取 12。
        cardStack.setCustomSpacing(12, after: nineGridWrapView)
        cardStack.setCustomSpacing(12, after: quoteCard)
        cardStack.setCustomSpacing(14, after: timelineLocationStack)
        cardStack.setCustomSpacing(12, after: footStack)
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
            // 115 批：内容到底线顶留白由 20pt 改 12pt（与首页 12pt 对齐），只改栈底
            // 14 → 6：内容到底线顶留白 = 栈底 6 + 列底 8 − 线高 1 = 13pt（线改细后 +1）；
            // 分割线钉 cell 底缘、
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
            dividerView.heightAnchor.constraint(equalToConstant: 0.5),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -6),
        ])
        // 批 E 补漏：位置图标固定 13（详情同款），不靠图片固有尺寸撑行高。
        NSLayoutConstraint.activate([
            timelineLocationIconView.widthAnchor.constraint(equalToConstant: 13),
            timelineLocationIconView.heightAnchor.constraint(equalToConstant: 13),
        ])
        // 无图时把图片条高度约束压到 0（只靠 hidden 不够：显式高度约束仍会撑开 stack）。
        thumbsHeightConstraint = thumbsScrollView.heightAnchor.constraint(equalToConstant: BearyImageStrip.height)
        thumbsHeightConstraint?.isActive = true
        installImageStripPinch()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 审计-时间线：320pt 下天气/心情行隐藏为已知取舍（有意降级，非 bug），不另做双行搬运。
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
        // 内联 GIF 覆盖层：label 宽变或文本重建后跟帧刷新（签名未变时内部短路，不重载）。
        refreshGIFOverlays()
        let metaWidth = metaStack.bounds.width
        guard metaWidth > 0 else { return }
        let narrow = metaWidth < 260
        if let weatherRow = metaWeatherRow, weatherRow.isHidden != narrow {
            weatherRow.isHidden = narrow
        }
        if let moodRow = metaMoodRow, moodRow.isHidden != narrow {
            moodRow.isHidden = narrow
        }
        // 限时虚线边框不再在此手工重画 path：BearyDashedBorderView 自身按
        // 约束后的 cardView bounds 重画，引用卡进栈后框高自动跟上。
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 离屏即停播（cell 复用池离树时动画不空转）；入窗后刷新（可见才播）。
        let visible = window != nil
        bodyGIFOverlay.setVisible(visible)
        titleGIFOverlay.setVisible(visible)
        if visible { refreshGIFOverlays() }
    }

    /// 内联 GIF 覆盖层刷新：正文/标题各配一个，label 宽变或文本重建后
    /// 跟帧刷新；长按回 fullKey（按 rand 在 entry.images 里找回）。
    private func refreshGIFOverlays() {
        let keys = currentEntry?.images ?? []
        bodyGIFOverlay.attach(
            to: contentLabel,
            gifKeys: keys,
            onLongPressGIF: { [weak self] rand in
                guard let self = self,
                      let fullKey = BearyGIF.fullKey(for: rand, in: self.currentEntry?.images ?? []) else { return }
                BearyGIFAddPresenter.presentAddGIF(from: self, fullKey: fullKey)
            }
        )
        titleGIFOverlay.attach(
            to: titleLabel,
            gifKeys: keys,
            onLongPressGIF: { [weak self] rand in
                guard let self = self,
                      let fullKey = BearyGIF.fullKey(for: rand, in: self.currentEntry?.images ?? []) else { return }
                BearyGIFAddPresenter.presentAddGIF(from: self, fullKey: fullKey)
            }
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 对称分割线式：内容列底色与分割线均走动态色（bg / line），
        // 深浅切换自动跟随，无外框 chrome 可刷。
        // 限时虚线描边色由 BearyDashedBorderView 自身在 trait 变化时重刷。
        timelineLineView.backgroundColor = BearyColors.line
        dotRingView.backgroundColor = BearyColors.line
        // C1：圆点边框按当前有效态重设（公开橙、存活限时紫、仅好友墨、私密蓝），
        // 不得无条件写 bg（否则主题切换后私密蓝圈变隐形）。
        // N1：已公开圆点填充改橙色（与 configure 同口径），主题切换后仍是橙。
        if let entry = currentEntry {
            // 限时已到期按私密算（与 configure 同口径）。
            let published = BearyEphemeral.isEffectivelyPublic(entry)
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.bearyDynamicBorderColor = BearyEphemeral.isLive(entry) ? BearyColors.limitedPurple : (published ? BearyColors.orange : (entry.isFriendsOnly ? BearyColors.ink : BearyColors.blue))
        } else {
            dotView.layer.bearyDynamicBorderColor = BearyColors.bg
        }
    }

    /// 2026-11-14 Li 定：点按／长按不再给内容列变色——原 U14 的
    /// setHighlighted（高亮时 cardView 改 surface2）已删；点按仍进详情
    /// （didSelectRowAt 不动），定位落点闪一下走 flashHighlight（不动）。

    /// E3：gotoEntry 落点行天气标播 Lottie（共享 BearyWeatherLottie，
    /// 卡片／详情同款；映射走 BearyText.weatherLottieKey，night→moon）。
    /// 仅落点控制器在定位落定后调用；其他行从不调用，天气标保持静态图。
    /// 覆盖层贴在 14px 天气图标上，停播摘层即回到底层静态图。
    func playWeatherLottie() {
        guard let iconView = weatherIconView else {
            stopWeatherLottie()
            return
        }
        BearyWeatherLottie.play(weatherKey: currentEntry?.weather, iconView: iconView, overlay: &weatherEmoteView)
    }

    /// E3：停播落点天气 Lottie 并摘掉覆盖层。复用、重配、滑出可视区
    /// （播放器离窗自停 + 复用/重配摘层）与新落点盖掉旧落点时均走此路。
    func stopWeatherLottie() {
        BearyWeatherLottie.stop(overlay: &weatherEmoteView)
    }

    /// 6A 定位高亮：内容列 surface2 闪一下再回 bg（减动效下只滚动不闪）。
    /// 复用安全：prepareForReuse 已复位 bg；完成时再核对仍是同一篇才复位。
    func flashHighlight() {
        guard UIAccessibility.isReduceMotionEnabled == false else { return }
        let flashedId = currentEntry?.id
        cardView.backgroundColor = BearyColors.surface2
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
        // 审计-时间线：复用前清全部行回调，防旧回调串到下一行（间接持有链未证实，清回调本身是安全小修）；
        // VC 侧新回调在 cellForRowAt 重设，闭包本身已是 [weak self]（见 cellForRowAt 与日历卡接线）。
        onEditEntry = nil
        onDeleteEntry = nil
        onQuoteEntry = nil
        onMoreEntry = nil
        onTapImages = nil
        onNineGridTapped = nil
        nineGridHideToken += 1
        nineGridWrapView.isHidden = true
        nineGridWrapView.alpha = 0
        resetImageStripPinch()
        // 内联 GIF 覆盖层复用时清理（动画停播、图层摘掉，防串位到下一行）。
        bodyGIFOverlay.clear()
        titleGIFOverlay.clear()
        stopWeatherLottie()
        weatherIconView = nil
        // 80 包 A4/A2-3④：错峰改 cell.alpha/transform，对称复位，防复用残留。
        alpha = 1
        transform = .identity
        setTimelineLineEdges(isFirstInDay: true, isLastInDay: true)
        currentEntry = nil
        titleLabel.text = nil
        titleLabel.isHidden = true
        // 批 E 补漏：位置行复用复位，防上一行位置串到下一行无定位日记（#252 口径保留）。
        timelineLocationStack.isHidden = true
        timelineLocationLabel.text = nil
        // 对称分割线式复位：内容列回页面底 bg、无实线边（限时态只走虚线层）；
        // 分割线是静态约束 + 动态线色，无需复位。
        cardView.backgroundColor = BearyColors.bg
        cardView.layer.borderWidth = 0
        quoteCard.clear()
        quoteCard.isHidden = true
        pillIconView.image = nil
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
        metaWeatherRow = nil
        metaMoodRow = nil
    }

    /// 批 E 补漏：时间线位置行刷新，卡片 refreshLocationRow 同款口径
    /// （display 返回 nil 时整组隐藏，不留空行；公开篇作者本人也只看区级，不再附提示行；
    /// 非公开篇作者本人看精确名；他人只到区级、无区级不显示）。
    private func refreshTimelineLocationRow(entry: Entry) {
        guard let line = BearyLocationDisplay.display(entry: entry) else {
            timelineLocationStack.isHidden = true
            // 位置行隐藏时其后间距置 0（与标题行同款口径；不归零会多 14pt，
            // 与 :1144 注释「栈自动塌掉不留空行」相左，以卡片 126 真机实测为准）。
            cardStackReference?.setCustomSpacing(0, after: timelineLocationStack)
            timelineLocationLabel.text = nil
            return
        }
        timelineLocationStack.isHidden = false
        // sweep131-a：可见时恢复 14（#1250 定版、与卡片/详情对齐；#1268
        // 沿用合入前基线旧值 9，漏跟 #1250 的 9→14）。
        cardStackReference?.setCustomSpacing(14, after: timelineLocationStack)
        timelineLocationLabel.text = line
        // 2026-11-14 存经纬度：有坐标时按当前语言重取地名；失败／无坐标时保留原存文本行。
        // 复用守卫以 currentEntry 为准（configure 已先赋值；复用后旧回调凭 id 不符丢弃）。
        let entryId = entry.id
        BearyLocationDisplayNames.displayLine(for: entry) { [weak self] resolved in
            guard let self = self, let resolved = resolved, self.currentEntry?.id == entryId else { return }
            self.timelineLocationLabel.text = resolved
        }
    }

    /// 图片条捏合拼图（#429 卡片/详情同款口径，时间线 cell 此前根本没有捏合，
    /// 只是点按进灯箱——Li 2026-11-12 报时间线捏不动即因此）：双指捏合把
    /// 间距 8 → 0、圆角 12 → 0（图贴在一起且无圆角），张开恢复 8 / 12。
    /// 只动 thumbsStack.spacing 与缩略图圆角，不动图宽/高，不缩放单张图。
    private var stripPinchStartProgress: CGFloat = 0
    private var stripPinchJoined = false

    private func installImageStripPinch() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(imageStripPinched(_:)))
        pinch.delegate = self
        thumbsScrollView.addGestureRecognizer(pinch)
    }

    /// 捏合跟手圆角：progress 0 → 圆角 12，progress 1（贴合）→ 圆角 0，与间距同一进度走，
    /// 不在松手瞬间跳变；只改缩略图图层圆角，不动其他圆角。
    private func applyImageStripCornerRadius(progress: CGFloat) {
        let radius = 12 * (1 - max(0, min(1, progress)))
        for thumb in thumbImageViews { thumb.layer.cornerRadius = radius }
    }

    @objc private func imageStripPinched(_ gesture: UIPinchGestureRecognizer) {
        // 单图时无间距可收，不接管手势（也不禁滚动）。
        let visibleCount = thumbImageViews.count
        guard visibleCount >= 2 else { return }
        switch gesture.state {
        case .began:
            // 以当前实际间距起算，防上一轮贴合动画中途被新一轮捏合打断时跳变。
            stripPinchStartProgress = max(0, min(1, 1 - thumbsStack.spacing / 8))
            thumbsScrollView.isScrollEnabled = false
        case .changed:
            // scale < 1 为捏合（progress 增大、间距收小），scale > 1 为张开（反向）；
            // 从贴合态起手张开同样走这条式子，不会出现“贴合后张开无效”。
            let progress = max(0, min(1, stripPinchStartProgress + (1 - gesture.scale)))
            thumbsStack.spacing = 8 * (1 - progress)
            applyImageStripCornerRadius(progress: progress)
            thumbsScrollView.setNeedsLayout()
        case .ended, .cancelled, .failed:
            thumbsScrollView.isScrollEnabled = true
            let progress = max(0, min(1, stripPinchStartProgress + (1 - gesture.scale)))
            let wasJoined = stripPinchJoined
            stripPinchJoined = progress >= 0.5
            // 拼合/张开落点到位时各轻震一次：只在 .ended 且落点状态真的变化时震，
            // 跟手过程、取消/失败、原地未变都不震。
            if gesture.state == .ended && wasJoined != stripPinchJoined {
                BearyHaptics.press()
            }
            // 落点走拖拽收尾统一弹簧 0.30s／damping 0.7；减动效直接落终值，不播弹簧。
            if UIAccessibility.isReduceMotionEnabled {
                self.thumbsStack.spacing = self.stripPinchJoined ? 0 : 8
                self.applyImageStripCornerRadius(progress: self.stripPinchJoined ? 1 : 0)
                self.thumbsScrollView.layoutIfNeeded()
            } else {
                UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
                    self.thumbsStack.spacing = self.stripPinchJoined ? 0 : 8
                    self.applyImageStripCornerRadius(progress: self.stripPinchJoined ? 1 : 0)
                    self.thumbsScrollView.layoutIfNeeded()
                })
            }
        default:
            break
        }
    }

    private func resetImageStripPinch() {
        stripPinchJoined = false
        thumbsStack.spacing = 8
        applyImageStripCornerRadius(progress: 0)
        thumbsScrollView.isScrollEnabled = true
    }

    /// 九宫格入口显隐：图片数 > 3 才出现；状态真变时才动（复用滚动不闪）。
    /// 出现走规范 §6 局部状态 0.18s 淡入，减动效直设；收起先淡出、完成再藏。
    private func updateNineGridButton(count: Int) {
        let shouldShow = count > 3
        guard nineGridWrapView.isHidden == shouldShow else { return }
        nineGridHideToken += 1
        let animated = window != nil && !UIAccessibility.isReduceMotionEnabled
        if shouldShow {
            nineGridWrapView.isHidden = false
            nineGridWrapView.alpha = animated ? 0 : 1
            if animated {
                UIView.animate(withDuration: 0.18) {
                    self.nineGridWrapView.alpha = 1
                }
            }
        } else {
            if animated {
                let token = nineGridHideToken
                UIView.animate(withDuration: 0.18, animations: {
                    self.nineGridWrapView.alpha = 0
                }, completion: { _ in
                    guard token == self.nineGridHideToken else { return }
                    self.nineGridWrapView.isHidden = true
                })
            } else {
                nineGridWrapView.isHidden = true
                nineGridWrapView.alpha = 0
            }
        }
    }

    @objc private func nineGridButtonTapped() {
        onNineGridTapped?(nineGridButton)
    }

    /// C4：时间线引用占位/来源行已并入公共 BearyQuoteCardView（showGone /
    /// configure 来源行）；自绘 timelineSourceTitle / applyTimelinePlaceholder
    /// 一并删除，不再另维护一套。

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
            // 日记时间（2026-11-25 Li 定）：7 天内相对、7 天外“/”绝对日期，不带时分
            // （时分只在详情页显示）；见 BearyVisibilityText.diaryTimeString。
            // 时间线按日分组，meta 行以时间开头（13 号灰字）。
            timeLabel.text = BearyVisibilityText.diaryTimeString(publishedAtMs: createdMs, timeZone: entry.diaryTimeZone) ?? BearyDiaryCardCell.feedTimeString(ms: createdMs, timeZone: entry.diaryTimeZone)
        } else {
            timeLabel.text = ""
        }
        metaStack.addArrangedSubview(timeLabel)
        // 限时已到期按私密算（图标/圆点/⋯ 菜单一律走有效态，不只看服务端 isPublic）。
        let published = BearyEphemeral.isEffectivelyPublic(entry)
        if published {
            // 2026-10-29 晚：pill 已整个去掉，只留图标本体——公开＝地球，固定灰 #8e8e93（v3 值）；
            // 圆点口径不动（公开橙边、存活限时紫边见下）。
            // 109：限时存活期只换图标为官方 icon_limited（熊头 + 虚线环，
            // 与顶栏限时态同款，#272 误删后本支从 2bb7df9^ 原样恢复；
            // 纠正：不要 icon_clock；尺寸/灰色与公开/私密同款）；
            // 圆点仍走公开橙边（存活限时走紫边）、虚线框与倒计时行一字不动；到期后 isLive 为假、
            // isEffectivelyPublic 回私密，走下方锁分支，图标自动回锁。
            pillIconView.image = BearyIconImages.image(named: BearyEphemeral.isLive(entry) ? "icon_limited" : "icon_globe", pointSize: 14)
            pillIconView.tintColor = BearyColors.timelineIconGray
            // 竖线圆点统一用私密的尺寸和结构（9pt 空心 + 12pt 环），只变颜色：
            // 已公开橙边、存活限时紫边、私密蓝边（2026-10-28 Li 定，覆盖 #125 的已公开几何口径；限时紫 2026-11-21 Li 定，与日历圆点同口径）。
            dotSizeConstraint?.constant = 9
            dotRingSizeConstraint?.constant = 12
            dotTopConstraint?.constant = 14.5
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderWidth = 2.5
            dotView.layer.bearyDynamicBorderColor = BearyEphemeral.isLive(entry) ? BearyColors.limitedPurple : BearyColors.orange
            dotView.layer.cornerRadius = 4.5
            dotRingView.isHidden = true
        } else if entry.isFriendsOnly {
            // 好友第一期：仅好友态图标＝官方双人锁（icon_friends_lock），圆点边色走墨色
            // （与搜索页／引用面板 pill 的仅好友墨字灰底同口径），与私密蓝边区分；
            // 限时互斥，故仅好友档恒不带倒计时行。
            pillIconView.image = BearyIconImages.image(named: "icon_friends_lock", pointSize: 14)
            pillIconView.tintColor = BearyColors.timelineIconGray
            dotSizeConstraint?.constant = 9
            dotRingSizeConstraint?.constant = 12
            dotTopConstraint?.constant = 14.5
            dotView.backgroundColor = BearyColors.bg
            dotView.layer.borderWidth = 2.5
            dotView.layer.bearyDynamicBorderColor = BearyColors.ink
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
            dotView.layer.bearyDynamicBorderColor = BearyColors.blue
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
        ephemeralBorderView.isHidden = !ephemeralLive
        // I3：天气用 icon_wx_* 图标、心情用 14px BearyEmoteView（播 Lottie 循环，
        // 与 Feed/主页心情位静态首帧不同，时间线卡片心情是动的；减动效下只显完成帧）。
        if let weatherKey = entry.weather, let weatherName = BearyText.weatherNames[weatherKey] {
            weatherLabel.text = weatherName
            var weatherRowItems: [UIView] = []
            if let weatherImage = BearyIconImages.image(named: "icon_wx_\(BearyText.weatherStaticKey(for: weatherKey))", pointSize: 14) {
                let weatherIconView = UIImageView(image: weatherImage)
                weatherIconView.translatesAutoresizingMaskIntoConstraints = false
                weatherIconView.tintColor = BearyColors.gray
                weatherIconView.contentMode = .scaleAspectFit
                NSLayoutConstraint.activate([
                    weatherIconView.widthAnchor.constraint(equalToConstant: 14),
                    weatherIconView.heightAnchor.constraint(equalToConstant: 14),
                ])
                self.weatherIconView = weatherIconView
                // 天气标改动态 Lottie（落点行 playWeatherLottie 同款）。
                playWeatherLottie()
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
            // 32 注销口径：被 @ 者已注销时显“@用户已注销”。
            recipientLabel.text = "@\(bearyDeletedAuthorDisplayName(mentionedName) ?? mentionedName)"
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
        titleLabel.attributedText = trimmedTitle.isEmpty ? nil : BearyText.inlineAttributedText(from: trimmedTitle, font: BearyDynamicType.cardTitleFont(), color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: entry.images)
        titleLabel.isHidden = trimmedTitle.isEmpty
        // 标题隐藏时其后间距置 0，正文直接贴头行间距（卡片／详情同款口径；
        // UIStackView 会把 setCustomSpacing 的值算在隐藏行之后，不归零会多 6pt）。
        cardStackReference?.setCustomSpacing(trimmedTitle.isEmpty ? 0 : 6, after: titleLabel)
        contentLabel.attributedText = BearyText.inlineAttributedText(from: body, font: BearyDynamicType.diaryBodyFont(), color: BearyColors.ink, paragraphStyle: paragraph, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: entry.images)
        // TL-3 引用卡（C4 起复用公共 BearyQuoteCardView，不再自绘）：
        // 引用日记在时间线里必须有痕迹，卡内附 42px 引用缩略图行，无图不占位。
        // B-G2 (privacy, server fields first): Quote.gone/locked ARE decoded
        // (BearyAPI.swift); read them before any heuristic - gone -> deleted state,
        // locked -> locked state, neither leaks body/images, neither is tappable.
        // Missing fields fall back to the old heuristic. A visibility gate also applies:
        // a non-public quote on someone else's entry never shows body, even if the
        // server passed body through (fail-closed, see below).
        // 判定顺序与旧自绘卡一字不动，只把渲染交给公共卡：占位一律 showGone
        // （点按由公共卡 isGoneState 拦住，allowGoneTap 保持 false，与旧禁用按钮
        // 等价）；正常态走 configure（来源行 12、正文 13.5 限 3 行可展开、图标 15、
        // 缩略图池化，均为公共卡口径）。占位文案一字不动。
        quoteCard.clear()
        quoteCard.isHidden = true
        if entry.quote == nil, entry.quoteId != nil {
            quoteCard.showGone(message: "引用的日记已删除", iconName: "icon_quote", sourceDeleted: true)
            quoteCard.isHidden = false
        } else if let quote = entry.quote {
            // B-G2 decision order (web tlQuoteHtml order: gone -> locked -> visibility):
            // non-empty server fields win; missing fields fall back to old heuristic.
            let quoteBody = (quote.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if quote.gone == true {
                quoteCard.showGone(message: "引用的日记已删除", iconName: "icon_quote", sourceDeleted: true)
                quoteCard.isHidden = false
            } else if quote.locked == true {
                let placeholder = BearyQuoteGate.placeholderTextForQuote(publishedAt: quote.publishedAt, locked: true, visibility: quote.visibility)
                quoteCard.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
                quoteCard.isHidden = false
            } else if quoteBody.isEmpty {
                if quote.isPublic == true {
                    quoteCard.showGone(message: "引用的日记已删除", iconName: "icon_quote", sourceDeleted: true)
                } else {
                    let placeholder = BearyQuoteGate.placeholderTextForQuote(publishedAt: quote.publishedAt, locked: false, visibility: quote.visibility)
                    quoteCard.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
                }
                quoteCard.isHidden = false
            } else if quote.isPublic != true && !(quote.isMine == true || (quote.authorId != nil && quote.authorId == SessionManager.shared.currentUser?.id)) {
                // iCity viewer 实时判定：被引篇非公开且 viewer 不是被引作者时，
                // 即使服务端透传了正文也以占位替代，绝不泄漏正文与图片
                //（旧口径以宿主是否本人为代理，已作废；Quote 现有 authorId/isMine 字段）。
                // 10a：仅好友来源走定版句（其余仍回落私密/未公开档，见 placeholderTextForQuote）。
                let placeholder = BearyQuoteGate.placeholderTextForQuote(publishedAt: quote.publishedAt, locked: false, visibility: quote.visibility)
                quoteCard.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
                quoteCard.isHidden = false
            } else {
                // 正常态：缩略图门控与旧自绘卡 F2 一致——仅公开引用或 viewer
                // 是被引作者时出图（allowThumbs），无图不占位；池化由公共卡内做。
                quoteCard.configure(
                    authorName: quote.authorName ?? "",
                    authorAvatar: quote.authorAvatar,
                    content: quoteBody,
                    images: quote.images ?? [],
                    dims: quote.imgDims,
                    createdAt: quote.createdAt,
                    allowThumbs: quote.isPublic == true || quote.isMine == true || (quote.authorId != nil && quote.authorId == SessionManager.shared.currentUser?.id),
                    authorHandle: quote.authorHandle,
                    sourceTappable: true,
                    quoteId: quote.id
                )
                quoteCard.isHidden = false
            }
        }
        // 内联图不进缩略图条（与卡片/详情同款：已插进正文/标题里播，
        // 再进图条会同一张图出现两次）；图条只放照片。
        let imageKeys = (entry.images ?? []).filter { !$0.isEmpty && BearyGIF.isInlineImageKey($0, content: entry.content ?? "", title: entry.title ?? "") == false }
        resetImageStripPinch()
        thumbsScrollView.isHidden = imageKeys.isEmpty
        thumbsHeightConstraint?.constant = imageKeys.isEmpty ? 0 : BearyImageStrip.height
        cardStackReference?.setCustomSpacing(imageKeys.isEmpty ? 0 : 12, after: thumbsScrollView)
        for (thumbIndex, key) in imageKeys.enumerated() {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.backgroundColor = BearyColors.surface2
            // N7：主图条点按接灯箱（UIImageView 默认不接收触摸，必须显式开启；
            // 手势会截获此次点按，行点按进详情不再触发）。tag 记下标，
            // didTapThumb 再从 currentEntry 重算 keys（与本循环同一过滤口径）。
            imageView.isUserInteractionEnabled = true
            imageView.tag = thumbIndex
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapThumb(_:))))
            thumbsStack.addArrangedSubview(imageView)
            // 216 图片条：宽按原图宽高比定（广场 bearyStripWidth 同口径），高固定 216。
            let strip = bearyStripWidth(forKey: key, dims: entry.imgDims, height: BearyImageStrip.height)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: strip),
                imageView.heightAnchor.constraint(equalToConstant: BearyImageStrip.height),
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
            // 卡片糊同款：时间线条也是 216 高，直接走全尺寸图（缩略图 480px 在 3× 机上要拉大到 1438px）。
            if let url = BearyImageURLs.imageURL(key: key, thumb: false) {
                bearyFeedLoadImage(into: imageView, url: url, retryButton: thumbRetry, downsampleToWidth: strip * UIScreen.main.scale, blurUp: true)
            }
        }
        updateNineGridButton(count: imageKeys.count)
        // 批 E 补漏：位置行（图片条 → 引用卡 → 位置行 → 足行）；无位置、或他人视角下
        // 无区级时整组隐藏，不留空行（文案与脱敏走 BearyLocationDisplay，
        // 与首页/个人页卡片、详情同一函数，时间线本只列本人日记，故实效为
        // 私密精确、公开精确 + 橙色提示两态，他人态由 display 兜底）。
        refreshTimelineLocationRow(entry: entry)
        footStack.isHidden = true
        // 与 metaStack 在 configure 开头先清后加一致：foot 行只靠
        // prepareForReuse 清理时，configure 重跑会把足行与 spacer 叠加。
        for arranged in footStack.arrangedSubviews {
            footStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
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
                footItems.append(footItem(iconName: liked ? "icon_heart_fill" : "icon_heart", text: "\(likeCount)", accessibilityName: "点赞", highlighted: liked))
            }
            var emoteTotal = 0
            for emote in entry.emotes ?? [] {
                emoteTotal += emote.count ?? 0
            }
            if emoteTotal > 0 {
                // 回应数图标：单张熊脸 icon_mood（官方资产，放大核对过：只有熊脸，
                // 无手臂、无抱抱动作、无道具），不再用 hug 拥抱表情，避免被误读为
                // “N 个抱抱”。走足项同款 footItem：14pt 图＋13pt 灰字、间距 4，
                // 模板渲染＋灰 tint，深浅模式自动跟走，无需深色变体重刷。
                footItems.append(footItem(iconName: "icon_mood", text: "\(emoteTotal)", accessibilityName: "回应"))
            }
            let bookmarkCount = entry.bookmarkCount ?? 0
            if bookmarkCount > 0 {
                footItems.append(footItem(iconName: "icon_bookmark", text: "\(bookmarkCount)", accessibilityName: "收藏"))
            }
            if !footItems.isEmpty {
                for item in footItems {
                    footStack.addArrangedSubview(item)
                }
                // 足行吸宽 spacer：
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
        // 与缩略图条同口径过滤（内联图不进图条，index 才对得上）。
        let keys = (entry.images ?? []).filter { !$0.isEmpty && BearyGIF.isInlineImageKey($0, content: entry.content ?? "", title: entry.title ?? "") == false }
        let index = sender.view?.tag ?? 0
        guard index >= 0 && index < keys.count else { return }
        onTapImages?(keys, index, sender.view.map { $0.convert($0.bounds, to: nil) }, (sender.view as? UIImageView)?.image)
    }

    @objc private func moreTapped() {
        guard let entry = currentEntry else { return }
        onMoreEntry?(entry, moreButton)
    }

    /// 可见性切换失败的拒绝动效：⋯ 钮摇头 + warning 震动（与卡片
    /// playDenyShake 同口径：减动效只跳视觉抖动，震动照常给；
    /// 原 globe 钮已摘除，摇头目标改为 ⋯ 菜单钮，调用点与音效/震动不变）。
    func playPublishDenyShake() {
        BearyIconMotion.playDenyShake(on: moreButton, key: "bearyDenyShake")
    }

    @objc private func quoteTapped() {
        guard let entry = currentEntry, let quoteId = entry.quote?.id else { return }
        // iCity：gone/locked 卡不导航；其余一律转发 id，容器先 fetchEntry 校验再放行。
        if entry.quote?.gone == true || entry.quote?.locked == true { return }
        onQuoteEntry?(quoteId)
    }

    /// 引用卡展开后通知表格重算行高（审计第十轮第 4 项）：卡片内部只改行数，
    /// 行高归表格所有；begin/end 更新走 motion.normal（0.26s）平滑过渡。
    /// 找不到表（卡未挂表）时不做事。
    private func notifyQuoteExpanded() {
        var tableView: UITableView?
        var view = superview
        while let current = view {
            if let table = current as? UITableView { tableView = table; break }
            view = current.superview
        }
        guard let tableView = tableView else { return }
        UIView.animate(withDuration: BearyMotion.normal) {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    private func footItem(iconName: String, text: String?, accessibilityName: String, highlighted: Bool = false) -> UIView {
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
        // 审计-时间线：足行计数补语义——整行作一个静态文本元素读“点赞/回应/收藏 + 数字”，图标与数字本身不单独出声。
        iconView.isAccessibilityElement = false
        row.isAccessibilityElement = true
        row.accessibilityTraits = .staticText
        row.accessibilityLabel = text.map { "\(accessibilityName) \($0)" } ?? accessibilityName
        row.addArrangedSubview(iconView)
        if let text = text {
            let label = UILabel()
            label.isAccessibilityElement = false
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

// UITableViewCell 在新 SDK 下已自带 UIGestureRecognizerDelegate 遵循，
// 故此处不再重复声明协议、方法改 override；行为与卡片 #429 原意一致。
extension BearyTimelineCell {
    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 只放行本图片条捏合与条自身滚动平移的共存：捏合 began 即禁了条的
        // 滚动，故自家平移本就滑不动；外层列表的竖滑若也放行，两指捏合时
        // 手指稍带竖向漂移就会一边捏合一边滚页。先识别意图者胜。
        return otherGestureRecognizer is UIPanGestureRecognizer
            && otherGestureRecognizer.view === thumbsScrollView
    }

    /// 时间线多图卡片捏合优先于外层列表竖滑：落在图片条上的双指捏合，
    /// 要求外层滚动视图的平移等它先失败——捏合一旦成立，外层平移随之失败；
    /// 单指滑动时捏合无从成立，直接放行，不拖慢列表滚动。只认外层滚动视图
    /// 的平移（UITableView 的竖滑），条自身平移仍走上面的共存口径；详情页
    /// 不走这条，不动。两指同向平移（双指滚页）时捏合始终不成立，外层竖滑
    /// 须等手指抬起、捏合失败后才认，是本修法的已知取舍。
    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === thumbsScrollView,
              otherGestureRecognizer is UIPanGestureRecognizer,
              let otherScrollView = otherGestureRecognizer.view as? UIScrollView,
              otherScrollView !== thumbsScrollView,
              gestureRecognizer.numberOfTouches >= 2,
              thumbImageViews.count >= 2 else { return false }
        return true
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
    /// 未登录：首拉 401 时调用一次（另附“请先登录”空态内的“去登录”按钮可再次触发）。
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

    // 提速：翻页页大小 50 → 20（翻页 hasMore 判定 count >= pageLimit
    // 全走本常量；日历圆点走月份请求、当日面板走
    // fetchDayEntries 或首屏派生回落，均不依赖页大小，见派生注释）。
    private let pageLimit = 20
    /// 秒开·首屏再瘦：首屏只拉 12 条，对齐广场 firstPageLimit=12（屏上只看 5-8 条，
    /// 12 条已覆盖当日 10 篇/天上限 + 翻页余量）；后续分页仍用 pageLimit=20，不多发请求。
    private let firstPageLimit = 12

    /// R15 P2-8：分区快照——currentSections() 的构建结果缓存。
    /// 表格数据源（numberOfSections/rows/cellForRow、组头/高度/滑动操作/
    /// willDisplay 等约 20 处调用点）在一次数据不变的窗口内读同一份快照，
    /// 不再每次全量遍历 timelineEntries 按日分组重建；输入
    /// （dayEntries/timelineEntries/selectedDayKey）任一变化都经 didSet
    /// 同步清掉快照，下一次读取时重建一次——失效与改写同一步完成，
    /// 故任何一次读取都不可能读到过期快照。
    private var cachedSections: [DaySection]?

    /// 审计 r18 第 37 项：dayKey／组标题缓存——dayKey 只由 createdAt 决定
    /// (创建后不变)，按 entry id／dayKey 缓存后 buildSections 重建时
    /// 不再逐条跑 Date＋Calendar 换算；无 id 的条目仍现算。
    private var dayKeyCacheByEntryId: [String: String] = [:]
    private var dayTitleCacheByKey: [String: String] = [:]

    private var timelineEntries: [Entry] = [] { didSet { cachedSections = nil } }
    private var timelineHasMore = false
    private var timelineState = LoadState.idle
    /// 账号隔离：冷启动首帧因身份未确认跳过加载的标记（见 loadTimelineCachedOrRefresh）；
    /// 任何一次真实加载（本函数放行、loadTimelineFirstPage）即清掉；容器凭它在
    /// /me 回包后补调首帧。须为 internal（SceneDelegate 读它）。
    var identityPendingFirstLoad = false
    /// 80 包 B2：viewDidLoad 首拉已发起的标记（引导预加载步骤据此去重，不复发第二拉）。
    var initialLoadStarted = false
    private var timelineUnauthorized = false
    private var timelineLoadingMore = false
    /// 时间线可见性筛子（好友第一期 §八）：五档互斥，默认全部。
    /// 档位名不用 `private` 作 case 名（关键字），另取 privatePosts 等名、
    /// queryValue 映射回后端 vis 取值；全部档 queryValue 为 nil（不发参数）。
    /// 可见性筛选已整支撤掉（时间线改版 v14）：时间线恒出全部档，
    /// 筛子钮、底 sheet 与切档状态机一并删除，不留死状态。
    /// 冷启动框架先行：首个宽就绪布局时先画日历框（当日周/月格＋占位圆点），
    /// 月份圆点由随后回包异步填入；只 prime 一次，后续由月份回包驱动。
    private var calendarFramePrimed = false
    // 崩溃 1（21:33/21:50 两次 Invalid_Batch_Updates）：首屏加载此前无在途守卫，
    // 重拍 tab/下拉/登录翻转/发布都可重入 loadTimelineFirstPage；旧回包按陈旧
    // oldSections diff 时表早已不是旧快照即崩。seq 令牌：每次首屏加载 +1，
    // 回包 seq 不符直接丢弃（不碰模型、不 diff、不 reload、不调 completion，
    // 新加载的回包自会渲染）。当前无调用方传 completion（仅 reloadTimeline
    // 无参调用），故陈旧回包不调 completion 是安全的；日后若有调用方传
    // completion，需自行处理陈旧语义。
    private var timelineFirstPageSeq = 0
    /// 112 分段去重：首屏在途标记（seq 只丢弃旧回包，不阻止重复发请求；
    /// 下拉/重拍/详情回写/静默对齐重叠时曾并发多份同样的 12 条首拉）。
    /// 在途时新调用直接跳过（不 bump seq，否则在途回包会被 seq 守卫丢弃、
    /// 等于白白重拉一次）；在途回包自会结束下拉头并更新模型。
    /// force=true 的硬重载（reloadTimeline 非 keepDay：登录翻转/取消编辑等）
    /// 绕过此标记——旧身份在途请求绝不能吞掉新身份的硬刷新。
    private var timelineFirstPageInFlight = false
    /// 112：在途跳过时暂存的 completion（refreshAfterDetailChange 的互动
    /// 变化回调等），在途回包匹配完成时统一补调；陈旧丢弃分支不补调
    ///（新请求自会完成并补调，避免按过期快照发互动变化）。
    private var timelineFirstPagePendingCompletions: [() -> Void] = []
    /// 112 手势下拉节流时钟：最近一次首屏网络成功的时间。
    private var lastTimelineFirstPageSuccessAt: Date?
    private var lastNavigationAt: Date?
    /// 112 增量当日面板：keepDay 刷新时暂存选中日，不立即另发当日请求；
    /// 首屏回包若已覆盖该日（页内出现更早日的篇），直接从首屏派生面板，
    /// 否则回落正向 fetchDayEntries；首屏失败时同样回落正向拉取。
    private var deferredDayKeyForFirstPage: String?
    /// 秒开-启动瘦身：时间线次级请求（日历月份、当日面板）不再与列表首拉并行，
    /// 改由首拉 completion 触发（见 flushDeferredTimelineSecondary）。与上行
    /// deferredDayKeyForFirstPage 分工不同：那是 keepDay 的“派生或回落”语义，
    /// 这里是“先列表、后次级”的纯时序延后；keepDay 时当日仍走上行机制，
    /// 本组只延后日历。首拉失败时 completion 同样跑（见 finishTimelineFirstPage），
    /// 故次级不会被首拉失败拖死；首拉迟迟不终结时 5 秒兜底同样放行。
    private var deferredCalendarFetch = false
    private var deferredDayKey: String?
    private var deferredDayClear = false
    private var deferredSecondaryFallback: DispatchWorkItem?
    // G15：分页失败标记——脚部保持“加载失败，重试”可重试。
    private var timelinePageFailed = false
    /// 审计 r16 第 17 项：分页失败退避——连续失败次数与下次可重试的最早时刻；
    /// 指数退避 2s 起、翻倍、上限 30s；分页成功或首拉重开即清零。拦在
    /// loadTimelineNextPage 入口，自动触发与手动重试同拦，防低速网络下
    /// 滑动中连续触发分页；手动点按被拦时给 toast 提示，自动触发被拦时静默。
    private var timelinePageFailureCount = 0
    /// 审计 r18 第 36 项：退避窗口锚单调时钟(ProcessInfo.systemUptime 秒数，
    /// 非 Date 墙钟)——改系统时间不再提前或推后窗口。
    private var timelinePageRetryNotBefore: TimeInterval?
    // M2：分页新增行的错峰滑入队列（willDisplay 时按原始序号起播，播过即摘；
    // 用序号字典而非数组，避免摘除后后续序号前移导致错峰失效）。
    private var staggerInsertOrder: [IndexPath: Int] = [:]
    /// 审计 r16 第 10 项：staggerInsertOrder 本次队列是首屏／筛子切换
    ///（60ms 步进、8pt 上移）还是分页追加（50ms 步进、24pt 下滑入），
    ///见 BearyEntranceConfig；减动效时队列为空，不播。
    private var staggerInsertFirstLoad = false
    /// 加载三件套·骨架屏：首屏加载（timelineState == .loading 且无行）时，
    /// 背景视图出 3 张骨架卡（与真实卡片同布局），取代中央转圈；下拉刷新
    /// 进行中（isCustomPullRefreshing）仍按现行口径不挂背景视图。
    private lazy var timelineSkeletonView: UIView = {
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        for _ in 0..<3 {
            stack.addArrangedSubview(BearySkeletonCardView())
        }
        return container
    }()
    /// 骨架是否实际出过屏：首屏回包时内容按 60ms/8px 入场，骨架背景视图
    /// 0.26s 淡出再摘（见 updateChrome）。
    private var didShowTimelineSkeleton = false
    /// 本页是否已展示过日记行：首进冷启动的首屏直接落位，不播 60ms/8px
    /// 入场错峰（行先摆低 8pt 再上移即“往上移动一下”）；之后重载
    /// 仍按旧口径错峰入场。
    private var hasShownTimelineRows = false
    /// 加载三件套·底部脚部（加载中 3 个跳动圆点 / 没有更多了 / 失败重试）。
    private let timelineLoadMoreFooterView = BearyLoadMoreFooterView()
    private var lastTimelineFooterSignature = ""
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
        staggerInsertFirstLoad = false
        // N3：切日错峰队列与组头淡入标志同生命周期，一并清掉，
        // 防旧队列在新数据行上重播（已有元素不重播）。
        daySwitchStagger.removeAll()
        daySwitchTitleFade = false
        daySwitchArrivalKey = nil
        daySwitchSlideDirection = nil
    }
    private var trashCountValue = 0
    /// B5：回收站计数是否已知——首屏/增量刷新取到服务端值或缓存恢复后为真；
    /// 为假时彻底删除不做本地 -1，回落整页重拉校验，不谎报。
    private var trashCountKnown = false
    private var countsValue: TlCounts?
    private var loginNotified = false

    private var calendarCache: [String: BearyCalendarMonthResponse] = [:]
    private var calendarFetching: Set<String> = []
    private var calendarFailed: Set<String> = []
    /// r17-C1：跨日恢复的月份 key——落盘 streak 是服务端按落盘当天算的，
    /// 跨日后未重新确认，统计行不报该 streak（只报本月篇数），直至刷新到达。
    private var calendarStreakUnknownKeys: Set<String> = []
    /// r17-C1：已尝试过落盘恢复的月份 key（无文件时不再重复读盘；
    /// 账号切换清掉；invalidateStatsLine 不清——删缓存后走网络重拉，
    /// 不得用旧落盘把刚失效的缓存顶回去）。
    private var calendarSnapshotRestoreTried: Set<String> = []
    /// 64 包反馈修（第 3 项）+ 本批新规矩：统计行已渲染数值（streak|monthTotal，
    /// 失败/空态另计）。签名故意不含月份 key——切月时数值不变即一字不碰，
    /// 旧签名含月份 key 是闪的根因（数值未变仍整行重建）。
    /// 签名只在写新日记时由 invalidateStatsLine 清掉（删除/回收站恢复走
    /// refreshAfterDetailChange 强制重拉，值变了签名自然不同、无需另清）。
    private var calendarMode: BearyCalendarCardView.ViewMode = .week
    private var calendarAnchor: (year: Int, month: Int, day: Int)?
    private var calendarDisplayedMonth: (year: Int, month: Int)?
    private var selectedDayKey: String? { didSet { cachedSections = nil } }
    /// 第 3 项翻周/翻月选区跟随：新视图月份缓存未到齐时挂起，到达后在
    /// fetchCalendarMonth 回包里重试（tryStepFollowSelection）。
    private var pendingStepFollow = false
    /// 第 4 项 calFixSel 守卫：删除后（refreshAfterDetailChange 置位）或
    /// 月份补拉到达后复核选中日计数；2026-11-04 不跳日口径：计数为 null/0
    /// 也不跳转、不清选区，只清挂起、走正常空态（平时月份到达本就不触发）。
    private var pendingFixSelCheck = false
    /// 第 2 项 A 初次进入 / 下拉刷新守卫：只在 viewDidLoad 与自定义下拉刷新
    /// 两处设置；2026-11-04 不跳日口径：选中日无日记时不再跳最近有篇日，
    /// 只清挂起、走正常空态。故意不用 pendingFixSelCheck 承载，
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

    private var dayEntries: [Entry] = [] { didSet { cachedSections = nil } }
    private var dayState = LoadState.idle
    /// v14 改版：空日占位判定——选中日非空、已加载、该天无条目时，当日面板
    /// 出一枚纯文字占位行「这天没有日记」（不走整表背景空态，时间线其余组不动）。
    private var isDayPanelEmpty: Bool {
        guard let key = selectedDayKey, !key.isEmpty else { return false }
        return dayEntries.isEmpty && dayState == .loaded
    }
    private var dayKeyForLoad: String?
    /// 按日请求递增序号：快速切日 A→B→A 时，切回 A 的新请求会把 dayKeyForLoad
    /// 置回 A，旧 A 回包只验日期反而能通过；序号让旧回包一律作废（账号、
    /// 筛子档、dayKey 校验原样保留）。
    private var dayLoadSeq = 0
    private var dayEntriesKey: String?
    /// N2：已加载过的当日数据缓存（key=北京日，value=该日成功回包的条目）。
    /// 日历缓存（calendarCache）只含计数、不含条目，故切日此前必重拉；
    /// 本缓存只由 fetchDayEntries 成功回包写入，失败不写、不污染。
    /// 缓存是“先显示、后台再对齐”的底子，过期由每次切日的静默刷新纠正，
    /// 不设 TTL（当日数据变化只来自本人的写/删/公开操作，见删除时的清缓存）。
    private var dayEntriesCache: [String: [Entry]] = [:]
    /// 日缓存版本（key=北京日）：每次经 cacheDayEntries 的权威写缓存都 +1；
    /// 相邻日预取发出时捕获当时版本，回调写缓存前比对——期间主动加载已写过
    /// 该日缓存时版本已变，旧预取拒写，不覆盖新数据。预取写缓存本身也推进
    /// 版本，使更早的预取同样被拒；预取从不阻塞主动加载，只丢弃自己的写。
    private var dayCacheVersions: [String: Int] = [:]
    /// 全量同步落盘：落盘是 dayEntriesCache 的持久层，不是第二套真相——
    /// 读顺序永远是内存 → 落盘 → 网络；每次网络日成功都同时写内存与落盘。
    private func cacheDayEntries(key: String, entries: [Entry]) {
        dayCacheVersions[key, default: 0] += 1
        dayEntriesCache[key] = entries
        if let uid = SessionManager.shared.currentUser?.id {
            // 落盘写走同步队列（不卡主线程，同时记写盘代际供全量同步提交守卫判断）；
            // 内存态已同步更新，UI 不等落盘。
            BearyEntrySync.shared.runDiaryDiskWrite(accountId: uid) {
                // r17-C2：落盘写返回结果，失败记日志（内存态已更新，静默刷新会纠正）。
                let ok = BearyEntrySyncStore.saveDay(accountId: uid, dayKey: key, entries: entries)
                if !ok { NSLog("[BearyEntrySync] saveDay failed account=%d day=%@", uid, key) }
            }
        }
    }
    /// 审计四轮增量 06：切日落盘读专用串行队列——单日落盘文件通常不大，
    /// 但 Data(contentsOf:)＋JSON 解码仍在切日首帧上；内存未命中时读盘
    /// 改走这里，回主线程后按代次/选中日/账号复核再更新面板。
    private let dayDiskReadQueue = DispatchQueue(label: "beary.timeline.day-disk-read")
    /// R15 P2-7：切日磁盘预读在途集合（key=北京日；与正向单槽无关，
    /// 同日只读一次，读完即摘，失败不留痕）。
    private var dayDiskLoadInFlight: Set<String> = []
    /// R15 P2-7：点日期即准备数据——内存未命中时把落盘读 + 解码放到后台
    /// （BearyEntrySync.swift:78–81 的 loadDay 是纯同步实现，
    /// Data(contentsOf:) + JSONDecoder.decode，旧路在主线程调它会卡住切日），
    /// 与旧日退场动画并行；读到后回主线程回填内存缓存（与旧同步回填
    /// 同款语义），退场结束的提交只读内存，永不在主线程碰磁盘。
    /// 校验：日缓存是全部档行；回填前比对账号（uid 分桶，中途切号的旧账号
    /// 落盘绝不写进新账号缓存）与日期（按 key 回填），并复用日缓存版本
    /// 检查（与相邻日预取同款）：期间网络已写过该日则版本已变、或槽位
    /// 已被占，迟到的磁盘结果拒写，不覆盖新数据。
    private func prepareDayEntriesInBackground(key: String) {
        guard dayEntriesCache[key] == nil,
              !dayDiskLoadInFlight.contains(key),
              let uid = SessionManager.shared.currentUser?.id else { return }
        dayDiskLoadInFlight.insert(key)
        // 缓存版本快照：发出时记下该日版本，回调写缓存前比对——期间
        // 主动加载已写过该日时版本已变，旧预读直接拒写，不覆盖新缓存。
        let requestCacheVersion = dayCacheVersions[key] ?? 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let disk = BearyEntrySyncStore.loadDay(accountId: uid, dayKey: key)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dayDiskLoadInFlight.remove(key)
                guard SessionManager.shared.currentUser?.id == uid else { return }
                guard (self.dayCacheVersions[key] ?? 0) == requestCacheVersion else { return }
                guard self.dayEntriesCache[key] == nil else { return }
                if let disk = disk {
                    self.dayEntriesCache[key] = disk
                }
            }
        }
    }
    /// 账号切换时清日缓存：内存日缓存与预取在途集合都不跨账号（落盘已按 uid
    /// 分桶，不动）；由 SceneDelegate onUserChanged 的 userChanged 分支在
    /// reloadTimeline 之前调用，登录与退出两个方向都覆盖。时间线 VC 换账号
    /// 不重建，故必须显式清，否则新账号当日面板会先闪出旧账号的日缓存。
    func clearDayCacheForAccountChange() {
        dayEntriesCache.removeAll()
        dayCacheVersions.removeAll()
        dayPrefetchInFlight.removeAll()
        // R15 P2-7：磁盘预读在途集合同样清——旧账号的读在回填前有 uid 校验
        // 不会污染新账号，但不占位，新账号同日可立即重读。
        dayDiskLoadInFlight.removeAll()
        // r17-C1：内存月历缓存同样不跨账号（此前只清日缓存；旧号的圆点/
        // 统计会先闪在新号页上，直至网络回包纠正）。落盘按 uid 分桶不动，
        // 切号后恢复走新号自己的落盘（见 fetchCalendarMonthsForCurrentView）。
        calendarCache.removeAll()
        calendarFailed.removeAll()
        calendarStreakUnknownKeys.removeAll()
        calendarSnapshotRestoreTried.removeAll()
    }
    /// 相邻日预取在途集合（key=北京日）：独立通道专用，与正向单槽
    /// （dayKeyForLoad + dayState）完全分开；同日只发一次，失败不留痕。
    private var dayPrefetchInFlight: Set<String> = []
    /// 换日滑入方向：以新旧选中日（yyyy-MM-dd，可直接按字典序比）比较定——
    /// 新日更早往下翻、更晚往上翻。
    private enum DaySwitchSlideDirection {
        case earlier  // 新日更早：往下翻，新行自下方（+y）滑入
        case later    // 新日更晚：往上翻，新行自上方（−y）滑入
    }
    /// N3：切日入场错峰队列（willDisplay 起播，播过即摘；代际见
    /// daySwitchGeneration，与分页 staggerInsertOrder 同机制不同队列，
    /// 步进 0.03s、封顶 0.24s，下偏 6pt）。selectDay / 清选区 / 整表重载时清掉。
    /// 切日行仍走本口径（与月历一致），不套首屏入场配置。
    private var daySwitchStagger: [IndexPath: Int] = [:]
    private var daySwitchGeneration = 0
    /// 换日定向滑入方向：新日更早往下翻（行自下方滑入）、更晚往上翻（行自上方滑入），
    /// 以新旧选中日比较定（selectDay 里置位，提交与回包到达分支共用）。
    /// 置位时 willDisplay 不走逐行错峰，整版同向齐滑 0.26s；减动效时不置位；
    /// 与 daySwitchStagger 同生命周期（clearStaggerEntries 清掉）。
    private var daySwitchSlideDirection: DaySwitchSlideDirection?
    /// N3：切日组头淡入一次性标志（willDisplayHeaderView 消费一次，不重播）。
    private var daySwitchTitleFade = false
    /// N3：切日回包到达时的入场错峰归属（仅 clear:true 的换日回包设置，
    /// 回包消费后清掉；非换日回包不设，避免旧队列在刷新行上重播）。
    private var daySwitchArrivalKey: String?
    /// TL-2 1 秒 tick（仅限时到期复核；编辑倒计时已随锁取消）。
    private var countdownTimer: Timer?
    /// 审计-时间线：本 tick 内已翻转过的到期 id（防每秒重复重载同行；离表/重变存活即剪枝）。
    private var expiredEphemeralHandledIds: Set<String> = []

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
        tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: BearyChrome.chromeBottomInset(includesFab: true, width: view.bounds.width, safeAreaBottom: view.safeAreaInsets.bottom), right: 0)
        tv.scrollIndicatorInsets = tv.contentInset
        // 顶栏透度批：与 Feed 同理，表框贴页顶（view.top），关自动调整使属性内边距即视觉顶距。
        tv.contentInsetAdjustmentBehavior = .never
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        tv.delaysContentTouches = false
        // 2026-11-14 Li 定：减速不设 .fast，与我的页一致走默认 .normal，
        // 一甩滑得远、手感统一（原跟手批 .fast 让时间线一甩就停）。
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

    /// 已有内容刷新失败条（私信会话列表／广场同款）：已有内容时首拉失败不 toast、
    /// 不清列表，内容顶下方出“未能刷新 · 重试”常驻条；成功或下次刷新时收起。
    /// 显隐只切换表顶约束，不碰 contentOffset、不清列表。
    private let refreshFailedBanner = UIView()
    private let refreshFailedLabel = UILabel()
    private let refreshFailedRetryButton = UIButton(type: .system)
    private var refreshFailedBannerTopConstraint: NSLayoutConstraint?
    private var tableViewTopToViewTopConstraint: NSLayoutConstraint?
    private var tableViewTopToBannerConstraint: NSLayoutConstraint?
    /// 自定义下拉刷新进行中标志（消息页 isCustomPullRefreshing 同款）。
    private var isCustomPullRefreshing = false
    /// 下拉收回动画在途旗：收回动画全程仍持刷新旗，跟随侧不中途重写 pullView.frame。
    private var customPullEndInFlight = false
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

    /// 表头容器：标题行 + 统计小字 + 连续写作行 + 日历卡 + 筛选行。
    /// 用 tableHeaderView 承载（随列表一起滚走，不常驻占位）；高度每次渲染后重算。
    /// 统计小字 + 连续写作行紧贴标题「时间线」下方（2026-11-12 Li 定位置）。
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
    // 吸顶头状态栏区底色：只盖 view 顶到安全区顶沿这一段（吸顶头自身已盖安全区下方）。
    // 常驻不随吸顶头显隐：换日期头那一下吸顶头会先藏后显，若底色同显同隐，
    // 藏的那几帧里正在滑进状态栏区的日记内容就会从状态栏区透出来（本次根因）。
    // 底色与页面底同色，常驻在视觉上无变化，只堵透底。
    private let statusBarBgView = UIView()
    private var stickyHeaderCurrentSection: Int?
    private var stickyHeaderCurrentTitle: String?
    private let headerContainer = UIView()
    private let titleLabel = UILabel()
    // 审计-时间线：表头回收站钮改 BearyHit44Button，视觉帧不动、热区扩至 44×44。
    private let trashButton = BearyHit44Button(type: .system)
    private let countsLabel = UILabel()
    /// 计数行最小高度约束（跳动修）：行高钉死一行，见 buildHeader 内注释；
    /// 字号变化时在 traitCollectionDidChange 里随新字号重算。
    private var countsLabelMinHeightConstraint: NSLayoutConstraint?
    private let calendarCard = BearyCalendarCardView()
    /// 写一笔速写器（v14 改版，表头底部）：写选中那天的日记。
    private let inlineComposer = BearyInlineComposerView()
    /// 写一笔速写器是否聚焦（键盘处理与表头高度重算用）。
    private var inlineComposerFocused = false
    /// 表头筛选行——只放筛子钮（当前可见范围：全部／公开／私密／限时／
    /// 仅好友）；日期只在当日面板组头出现，见 dayPanelTitleParts。
    private var headerStack: UIStackView?
    private var lastHeaderWidth: CGFloat = 0

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildHeader()
        view.addSubview(tableView)
        // 已有内容刷新失败条（私信会话列表／广场同款）：常驻于内容顶下方、列表上方
        //（非弹框、非 toast，失败不消失直至下次成功）；点“重试”走下拉同入口，
        // 只重拉，不改列表与滚动位置。
        refreshFailedBanner.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedBanner.backgroundColor = BearyColors.alpha(BearyColors.red, 0.12)
        refreshFailedBanner.isHidden = true
        view.addSubview(refreshFailedBanner)
        refreshFailedLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        refreshFailedLabel.adjustsFontForContentSizeCategory = true
        refreshFailedLabel.textColor = BearyColors.ink
        refreshFailedLabel.text = "未能刷新"
        refreshFailedBanner.addSubview(refreshFailedLabel)
        refreshFailedRetryButton.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedRetryButton.setTitle("重试", for: .normal)
        refreshFailedRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        refreshFailedRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        refreshFailedRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        refreshFailedRetryButton.accessibilityLabel = "重试"
        refreshFailedRetryButton.accessibilityHint = "重新拉取时间线列表，不改变当前列表位置"
        refreshFailedRetryButton.addTarget(self, action: #selector(refreshFailedRetryTapped), for: .touchUpInside)
        refreshFailedRetryButton.bearyAddPressFeedback()
        refreshFailedBanner.addSubview(refreshFailedRetryButton)
        refreshFailedBannerTopConstraint = refreshFailedBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: (headerTopInsetVisible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset)
        refreshFailedBannerTopConstraint?.isActive = true
        tableViewTopToViewTopConstraint = tableView.topAnchor.constraint(equalTo: view.topAnchor)
        tableViewTopToBannerConstraint = tableView.topAnchor.constraint(equalTo: refreshFailedBanner.bottomAnchor)
        tableViewTopToViewTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            refreshFailedBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            refreshFailedBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            refreshFailedBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            refreshFailedLabel.leadingAnchor.constraint(equalTo: refreshFailedBanner.leadingAnchor, constant: 16),
            refreshFailedLabel.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.trailingAnchor.constraint(equalTo: refreshFailedBanner.trailingAnchor, constant: -16),
            refreshFailedRetryButton.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            refreshFailedRetryButton.leadingAnchor.constraint(greaterThanOrEqualTo: refreshFailedLabel.trailingAnchor, constant: 8),
        ])
        setupStickyHeader()
        // R15-L1：悬浮日历失败横幅已由卡内重试行取代，不再建横幅；
        // 旧 loadMoreButton 已由 BearyLoadMoreFooterView 取代（#924），此处不再配按钮样式。
        // 审计 P2-20：时间线监听拉黑/举报即时清行并清 quoteCache。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        // 开发者模式变化：日期 / 假日记 / 强制态 / 字号（见 handleDevModeChanged）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleDevModeChanged(_:)), name: .bearyDeveloperModeChanged, object: nil)
        // 审计-时间线：前台复核（详情页同口径）——后台期间 1 秒 tick 未跑时，到期在回前台时补位。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundEphemeralCheck(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        // 发布后补拉待办变迁（第三批体验检查第 1 项）：选中日有待办入队/落盘时刷新当日面板（表头“同步中”）。
        NotificationCenter.default.addObserver(self, selector: #selector(handlePendingRefetchChanged(_:)), name: .bearyPendingRefetchDidChange, object: nil)
        // G15 toast 已委托 B 批统一 BearyToast（见 showTimelineToast），
        // 此处不再建常驻 toast 容器。
        // v14 改版：写一笔键盘处理——聚焦时底部内边距顶起键盘高、把速写器
        // 滚入可见区；收起时恢复（时间线此前无任何键盘监听）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        // 第 2 项 A 调用点 1/2（初次进入）：置守卫挂起；2026-11-04 不跳日口径：
        // 选中日（今天）无日记时不再跳最近有篇日，只清挂起、走正常空态；
        // 标志不放在 reloadTimeline 内，以免空态重试等其他 reloadTimeline
        // 调用点也被接上守卫。
        pendingEntryJumpCheck = true
        initialLoadStarted = true
        loadTimelineCachedOrRefresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 冷启动框架先行：宽一就绪即先画日历框、并行拉当月数据，不等时间线
        // 首拉完成（此前日历格要等首拉 completion 才出现、表头随之跳高，整页
        // 被拖后腿）。月份数据无落盘缓存（仅内存），故首屏格子先以加载占位
        // 画出、回包后填圆点；时间线快照的缓存先行已由审计 13 实现，本支不动。
        // 延后逻辑（deferredCalendarFetch）保留：已在途/已缓存时其后补调是
        // no-op，失败时仍由它重试，不改原有重试语义。
        if !calendarFramePrimed, tableView.bounds.width > 0 {
            calendarFramePrimed = true
            if calendarAnchor == nil {
                calendarAnchor = BearyBeijingDay.todayComponents(timeZone: .current)
            }
            if calendarDisplayedMonth == nil, let anchor = calendarAnchor {
                calendarDisplayedMonth = (anchor.year, anchor.month)
            }
            if selectedDayKey == nil, let today = BearyBeijingDay.todayComponents(timeZone: .current) {
                selectedDayKey = BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day)
            }
            renderCalendar()
            updateInlineComposerDay()
            fetchCalendarMonthsForCurrentView()
        }
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
        // 回收站 pill 图标按压缩放残留复位（通用按压反馈 .84 的已知残留类问题，
        // 回页时复位，保证图标回到满尺寸）。
        trashButton.imageView?.transform = .identity
        startCountdownTimer()
        // 回到本页时栏恢复可见（不带动画，避免进页先闪一下栏）。
        // setChromeHidden 由容器 lane 在 SceneDelegate.swift 提供，本文件只调用。
        // 下滑藏栏已拆除（第 11 项）：底栏分段器与 FAB 常驻，不再按滚动方向藏栏。
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCountdownTimer()
    }

    /// 审计-时间线：Timer 自保失效——容器切页走 pageDidLeave、模态离页走 viewWillDisappear，
    /// viewDidDisappear 再停一次，防漏调容器回调时 1 秒 tick 空转。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopCountdownTimer()
    }

    /// 切页生命周期 7 号（最小化）：容器切页只改 isHidden，本回调不触发，
    /// 故容器 showPage 在离页/进页时显式调这两个钩子；只覆盖 tick 启停
    ///（栏恢复已有 showPage 的 setBarsVisible/setHeaderVisible 兜底，不重复）。
    func pageDidEnter() {
        startCountdownTimer()
        // 80 包 A5：进页恢复可见行表情播放（与 stopVisibleEmotes 对称）。
        resumeVisibleEmotes()
        // 底栏复位：时间线页从不藏栏；首页/个人页下滚藏栏后，离场页减速尾巴
        // 的滚动回调可能在切页恢复之后又藏一次，而时间线滚动/筛子/跳转原先
        // 都不碰栏，栏一旦藏住便无恢复路径。进页、切档、跳转、刷新完成四处
        // 均显式亮回（animated:false，不与在途动画打架），不靠“再滚一下”。
        restoreChromeAfterTimelineAction()
    }


    func pageDidLeave() {
        stopCountdownTimer()
    }

    /// 底栏复位（时间线页从不藏栏，故任何时刻亮回都是正确态；animated:false
    /// 直达终值，不与在途 0.26s 栏动画打架）。
    /// 可见性守卫：本页被切走（isHidden）或不在窗内时不碰栏——否则后台
    /// 首拉回包会在首页下滚藏栏后又把栏亮出来，破坏首页滚动藏栏。
    private func restoreChromeAfterTimelineAction() {
        guard view.window != nil, !view.isHidden else { return }
        SceneDelegate.chrome?.setChromeHidden(false, animated: false)
    }

    /// 动画批 11 号：切 tab 离页时停掉本页可见行全部表情（容器只改 isHidden，
    /// 不触发 didEndDisplaying、不离窗，播放器侧无法自停）。
    func stopVisibleEmotes() {
        for cell in tableView.visibleCells {
            cell.stopAllBearyEmotes()
        }
        // 秒开批·图片预热：离页即停，不在后台页继续下缩略图。
        BearyImagePrefetcher.shared.cancel()
    }

    /// 80 包 A5：与 stopVisibleEmotes 对称的恢复入口：
    /// 只恢复可见行内 BearyEmoteView 的播放，不重播整页入场。
    /// 唯一进页入口是 pageDidEnter（其内调本方法）；容器切回时间线只调
    /// pageDidEnter，勿再另调本方法，否则可见行恢复跑两遍。
    func resumeVisibleEmotes() {
        func resume(_ view: UIView) {
            if let emote = view as? BearyEmoteView { emote.play() }
            for sub in view.subviews { resume(sub) }
        }
        for cell in tableView.visibleCells { resume(cell) }
        prefetchNextScreen()
    }

    /// 秒开批·图片预热：分区表先展平成顺序模型，再以最后可见行
    /// 的展平下标为锚点预热下一屏（切回本页时锚点即上次滑到的位置）。
    private func prefetchNextScreen() {
        let sections = currentSections()
        var flat: [Entry] = []
        var flatIndexByPath: [IndexPath: Int] = [:]
        for (section, sec) in sections.enumerated() {
            for (row, entry) in sec.entries.enumerated() {
                flatIndexByPath[IndexPath(row: row, section: section)] = flat.count
                flat.append(entry)
            }
        }
        let last = (tableView.indexPathsForVisibleRows ?? []).compactMap { flatIndexByPath[$0] }.max() ?? -1
        BearyImagePrefetcher.shared.prefetch(entries: flat, lastVisibleIndex: last, viewerId: SessionManager.shared.currentUser?.id)
    }

    /// 动画批 11 号离屏停播：行离屏即停其全部表情（含心情位）。
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.stopAllBearyEmotes()
    }

    deinit {
        countdownTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - 写一笔键盘处理（v14 改版）

    /// 键盘升起：底部内边距顶起键盘高（减安全区底），速写器聚焦时把
    /// 表头滚入可见区（表头在 tableHeaderView 内，scrollRectToVisible
    /// 对表头区域用 contentOffset 直设更稳）；只在速写器聚焦时顶，
    /// 其他输入源（如搜索）不抢。
    @objc private func handleKeyboardWillShow(_ note: Notification) {
        guard inlineComposerFocused,
              let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let keyboardHeight = frameValue.cgRectValue.height
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? BearyMotion.normal
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? Int(UIView.AnimationOptions.curveEaseOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        let bottomInset = max(keyboardHeight - view.safeAreaInsets.bottom, 0)
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.tableView.contentInset.bottom = bottomInset
            self.tableView.scrollIndicatorInsets.bottom = bottomInset
        }, completion: nil)
        // 速写器在表头底部：键盘升起后把它滚到键盘上方可见区。
        let composerFrame = inlineComposer.convert(inlineComposer.bounds, to: tableView)
        let visibleBottom = tableView.bounds.height - bottomInset
        if composerFrame.maxY > visibleBottom {
            var offset = tableView.contentOffset
            offset.y += composerFrame.maxY - visibleBottom + 12
            tableView.setContentOffset(offset, animated: true)
        }
    }

    @objc private func handleKeyboardWillHide(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? BearyMotion.normal
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? Int(UIView.AnimationOptions.curveEaseOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.tableView.contentInset.bottom = 0
            self.tableView.scrollIndicatorInsets.bottom = 0
        }, completion: nil)
    }

    // MARK: - 写一笔发布（v14 改版）

    /// 速写器日期同步：选中日、该天有无日记、是否未来日（锁输入）。
    /// 漏斗：selectDay（两处）＋fetchDayEntries 回包（成功/失败）＋首屏初建。
    private func updateInlineComposerDay() {
        let key = selectedDayKey
        var isFuture = false
        if let key = key {
            let parts = key.split(separator: "-")
            if parts.count == 3,
               let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
               let todayNumber = BearyBeijingDay.todayNumber(),
               let dayNumber = BearyBeijingDay.dayNumber(year: year, month: month, day: day) {
                isFuture = dayNumber > todayNumber
            }
        }
        inlineComposer.updateDay(selectedDayKey: key, hasEntries: !dayEntries.isEmpty, isFuture: isFuture)
    }

    /// 写一笔发布：快照字段顺序照抄编辑器 makePublishSnapshot；date 只在
    /// 选中日非今天时填 YYYY-MM-DD，今天填 nil 走旧口径；visibility 私密；
    /// 标题/心情/天气不填（正文里的 [mood:]/[gif:] 内联记号由服务端渲染口径
    /// 处理）；发布中心 pill 负责失败重试；成功回包清空速写器并刷新当日
    /// 面板、日历圆点与统计行。
    private func publishInlineComposer(_ draft: BearyInlineComposerDraft) {
        let clientReq = BearyDraftStore.newClientReq()
        let accountId = SessionManager.shared.currentUser?.id ?? BearyDraftStore.currentAccountId
        var publishDate: String?
        if let key = selectedDayKey,
           let today = BearyBeijingDay.todayComponents(),
           key != BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day) {
            publishDate = key
        }
        let snapshot = PublishSnapshot(
            content: draft.text,
            mood: nil,
            weather: nil,
            temperature: nil,
            quoteId: draft.quoteId,
            published: 0,
            visibility: "private",
            mentionedUserId: draft.mentionedUserId,
            title: nil,
            tags: draft.tags.isEmpty ? nil : draft.tags,
            ephemeral: nil,
            date: publishDate,
            locationName: draft.location?.name,
            locationDistrict: draft.location?.district,
            locationLatitude: draft.location?.latitude,
            locationLongitude: draft.location?.longitude,
            locationCountry: draft.location?.country,
            locationRegion: draft.location?.region,
            locationCity: draft.location?.city,
            locationStreet: draft.location?.street,
            tzName: TimeZone.current.identifier,
            clientReq: clientReq,
            originAccountId: accountId,
            draftId: nil,
            accountId: accountId,
            imageLocalFiles: draft.imageLocalFiles,
            images: draft.images
        )
        let job = BearyPublishJob(
            snapshot: snapshot,
            images: draft.images,
            publishTogether: false,
            publishToken: UUID(),
            sourceAlreadyPublished: false,
            hostView: view,
            onPublished: { [weak self] _, _ in
                guard let self = self else { return }
                self.inlineComposer.reset()
                self.showTimelineToast(message: NSLocalizedString("timeline.toast.published", comment: ""))
                self.invalidateStatsLine()
                self.fetchCalendarMonthsForCurrentView()
                if let key = self.selectedDayKey {
                    self.fetchDayEntries(key: key, clear: false)
                }
                self.reloadTimeline()
            },
            onRequireLogin: { [weak self] in
                self?.onRequireLogin?()
            },
            onOpenDraft: nil
        )
        BearyPublishCenter.shared.start(job: job)
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
            BearyEntrySync.shared.runDiaryDiskWrite(accountId: uid) {
                // r17-C2：落盘写返回结果，失败记日志（内存态已更新，静默刷新会纠正）。
                let ok = BearyEntrySyncStore.removeEntry(accountId: uid, entryId: entryId)
                if !ok { NSLog("[BearyEntrySync] removeEntry failed account=%d entry=%@", uid, entryId) }
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
        let top = view.safeAreaInsets.top + (visible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset
        refreshFailedBannerTopConstraint?.constant = (visible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset
        let bottom = BearyChrome.chromeBottomInset(includesFab: true, width: view.bounds.width, safeAreaBottom: view.safeAreaInsets.bottom)
        if tableView.contentInset.top != top || tableView.contentInset.bottom != bottom {
            // 冷启动/首进回顶：内边距变大时偏移不动，标题行会顶进状态栏区
            //（首建时 inset 0→安全区顶、偏移仍停 0）；仅当正停在旧顶（容差
            // 1pt，与 isAtTop 同口径）才跟到新顶，深处滚动位置不动。
            let wasAtTop = tableView.contentOffset.y <= -tableView.contentInset.top + 1
            tableView.contentInset.top = top
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.top = top
            tableView.scrollIndicatorInsets.bottom = bottom
            if wasAtTop {
                tableView.contentOffset = CGPoint(x: 0, y: -top)
            }
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

    /// 同 tab 连点刷新在途锁：首屏加载或自定义下拉头在途时，重拍刷新一律不重复触发
    /// （loadTimelineFirstPage 自身的在途跳过守卫是第二道）。
    var isRefreshingForRetap: Bool {
        timelineState == .loading || isCustomPullRefreshing
    }

    /// 账号隔离 9 号：keepDay 时同时保留旧内容——不清时间线模型、不动
    /// timelineState、不清当日面板，首屏回包经行 diff 更新；失败时旧内容
    /// 原样保留（失败/加载态只在空表时渲染特殊态，见 3617 一带，故不闪白）。
    /// 110：冷启动缓存优先（首页 BearyFeedCache SWR 同款口径）。
    /// 时间线此前无首屏磁盘缓存：每次冷启动都清表 + 全量重拉首屏 +
    /// 中央 spinner 等网络，即“冷启动后时间线慢”的主因（首屏 payload
    /// 仅约 60KB、解码可忽略，耗时在 TTFB 与无缓存上，见实测分解）。
    /// 有缓存：即时渲染缓存首屏（不转菊花、不清表），再走既有静默
    /// 路径对齐——首屏 loadTimelineFirstPage（有旧行时走 diff，不重建
    /// 节点；有行时 updateChrome 不挂背景 spinner）；秒开-启动瘦身后，
    /// 日历月份（内存缓存守门）与当日面板（clear:false 静默刷新）不再与
    /// 首拉并行，改由首拉 completion 放行（见 flushDeferredTimelineSecondary），
    /// 到达时仍走各自原有更新路径（日历只画卡片、当日只重载第 0 分区），
    /// 不重建时间线行、不重播已有元素。
    /// 无缓存：走旧 reloadTimeline 全量路径（空框架先立住，数据等网络，
    /// 不加骨架屏），次级同样延后到首拉 completion。
    /// 账号切换同样走本函数（秒开-本地持久化）：桶按切换后的 currentUser
    /// 现算，新号有快照即先画新号自己的快照 + 静默刷新，无快照才走
    /// reloadTimeline；旧号桶绝不被读到。时间线是本人全部日记（含私密），
    /// 缓存不做 Feed 的公开过滤，只按用户桶隔离（与日缓存落盘同款账号桶）。
    /// 注意：切号前容器已清当日内存缓存（clearDayCacheForAccountChange），
    /// 故当日面板的 clear:false 静默刷新仍走网络，不会吃旧号的日缓存。
    /// 秒开-启动瘦身：延后的次级请求放行点（首拉 completion 或 5 秒兜底共用）。
    /// 日历回包只画卡片、当日回包只重载第 0 分区（或数据未变时不动表），
    /// 均复用原有更新路径，不新增整表重建；当日放行时选区已切走即丢弃，
    /// 不把旧日的面板写到新选区上。
    private func flushDeferredTimelineSecondary() {
        deferredSecondaryFallback?.cancel()
        deferredSecondaryFallback = nil
        if deferredCalendarFetch {
            deferredCalendarFetch = false
            fetchCalendarMonthsForCurrentView()
        }
        if let key = deferredDayKey {
            deferredDayKey = nil
            if selectedDayKey == key {
                let clear = deferredDayClear
                deferredDayClear = false
                fetchDayEntries(key: key, clear: clear)
            } else {
                deferredDayClear = false
            }
        }
    }

    /// 秒开-启动瘦身：首拉迟迟不终结（弱网挂起）时次级不被拖死——5 秒后
    /// 直接放行；首拉 completion 先到则取消本兜底。每次设延后标志时重排，
    /// 旧兜底作废，不叠加。
    private func scheduleDeferredSecondaryFallback() {
        deferredSecondaryFallback?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushDeferredTimelineSecondary() }
        deferredSecondaryFallback = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    // 注意：本函数保持 internal（非 private）——SceneDelegate 切号时直接调
    // 用它（秒开-本地持久化），#456 原支的 private 会断该调用，特此保留。
    func loadTimelineCachedOrRefresh() {
        // 账号隔离：身份未确认时绝不渲染 lastKnownUserId 桶（冷启动登 demo 号
        // 却看到自己号数据的根因）；显骨架加载态，等 /me 回包后容器重调。
        guard let bucket = BearyFeedCache.confirmedBucket() else {
            identityPendingFirstLoad = true
            updateChrome()
            return
        }
        identityPendingFirstLoad = false
        // 秒开-启动瘦身：自己的首载若与预取撞车，待发预取取消（自己的首拉
        // 已覆盖，不再重复发一份）；已发出的预取由首拉接手复用（见
        // fetchTimelineFirstPageFull 的 adoptFirstPageIfInFlight）。
        // 账号翻转/冷启动即 fresh entry：不另发请求（本函数随后即重拉）。
        BearyTimelinePrefetch.cancelPendingPrefetch()
        // 审计 13：读盘 + 解码在缓存 IO 队列，界面先不阻塞；回包到主线程
        // 后再应用。桶已换（账号切换）时旧回包直接丢弃，不覆盖新桶内容。
        BearyTimelineCache.load(bucket: bucket) { [weak self] snap in
            guard let self = self else { return }
            self.applyTimelineCacheSnapshot(snap, bucket: bucket)
        }
    }

    /// 审计 13：缓存快照应用体（loadTimelineCachedOrRefresh 的异步回包
    /// 在此落地；抽成方法只为避开逃逸闭包里的隐式 self，语义与原同步
    /// 版一致：桶已换时旧回包丢弃，空快照走 reloadTimeline 全量路径。
    private func applyTimelineCacheSnapshot(_ snap: (entries: [Entry], hasMore: Bool, trashCount: Int, total: Int?, priv: Int?, pub: Int?, savedAt: TimeInterval)?, bucket: String) {
        // 账号隔离：回包时再凭确认后身份算桶——身份未确认时算不出（nil），
        // 旧回包直接丢弃，不覆盖新桶内容。
        let currentBucket = BearyFeedCache.confirmedBucket()
        guard currentBucket == bucket else { return }
        guard let snap = snap, !snap.entries.isEmpty else {
            self.reloadTimeline()
            return
        }
        if calendarAnchor == nil {
            calendarAnchor = BearyBeijingDay.todayComponents(timeZone: .current)
        }
        if calendarDisplayedMonth == nil, let anchor = calendarAnchor {
            calendarDisplayedMonth = (anchor.year, anchor.month)
        }
        if let today = BearyBeijingDay.todayComponents(timeZone: .current) {
            selectedDayKey = BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day)
        } else {
            selectedDayKey = nil
        }
        timelineEntries = snap.entries
        timelineHasMore = snap.hasMore
        trashCountValue = snap.trashCount
        trashCountKnown = true
        if let total = snap.total, let priv = snap.priv, let pub = snap.pub {
            countsValue = TlCounts(total: total, priv: priv, pub: pub, nextPub: nil)
        }
        timelineState = .loaded
        timelinePageFailed = false
        // 审计 r16 第 17 项：缓存快照落表即新一轮列表，清分页退避。
        timelinePageFailureCount = 0
        timelinePageRetryNotBefore = nil
        timelineUnauthorized = false
        loginNotified = false
        // 当日面板先用缓存首屏里今天的篇顶上（静默刷新随后对齐），
        // 避免面板空等网络；缓存里今天无篇时面板空态由静默刷新补，
        // 初次进入守卫挂起（viewDidLoad 已置位）照常消费，不再跳转。
        if let dayKey = selectedDayKey {
            dayEntries = snap.entries.filter { entry in
                guard let created = entry.createdAt, let key = BearyBeijingDay.dayKey(ofMs: created, tzName: entry.tzName) else { return false }
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
        // 缓存快照已落表：本页已有行，之后首屏回包的新行错峰口径不变。
        hasShownTimelineRows = true
        updateTrashTitle()
        updateCountsLabel()
        refreshHeaderHeight()
        updateChrome()
        // 静默对齐（与下拉刷新/首屏 diff 同款，不清表、不转菊花）。
        // 秒开-启动瘦身：日历与当日静默刷新延后到首拉 completion（失败也放行，
        // 见 finishTimelineFirstPage），不再与首拉并行挤首屏窗口。
        deferredCalendarFetch = true
        deferredDayKey = selectedDayKey
        deferredDayClear = false
        scheduleDeferredSecondaryFallback()
        loadTimelineFirstPage(completion: { [weak self] in self?.flushDeferredTimelineSecondary() })
    }

    func reloadTimeline(keepSelectedDay: Bool = false) {
        let keepDay = keepSelectedDay && selectedDayKey != nil
        if keepDay {
            // 只重置瞬时标记，不动模型与状态。
            timelinePageFailed = false
            timelineUnauthorized = false
            loginNotified = false
        } else {
            timelineEntries = []
            timelineHasMore = false
            timelineState = .idle
            timelineUnauthorized = false
            timelinePageFailed = false
            loginNotified = false
            // 清表即无内容：失败条不留（后续首拉结果自会再定）。
            setRefreshFailedBannerVisible(false)
        }
        if calendarAnchor == nil {
            calendarAnchor = BearyBeijingDay.todayComponents(timeZone: .current)
        }
        if calendarDisplayedMonth == nil, let anchor = calendarAnchor {
            calendarDisplayedMonth = (anchor.year, anchor.month)
        }
        // TL-7 默认选中今天：进页即有当日面板（网页 loadCalendar 默认 calSel=今天）。
        // G16：保留选中日时不重置、不清当日面板。
        if keepDay {
            // 选中日与当日面板原样保留，只刷新时间线与日历。
        } else {
            if let today = BearyBeijingDay.todayComponents(timeZone: .current) {
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
        // 112：非 keepDay 硬重载 force=true（登录翻转/取消编辑等绝不能
        // 被旧身份在途首拉吞掉）；keepDay 刷新走在途跳过口径。
        // 秒开-启动瘦身：日历与当日不再与首拉并行，改由首拉 completion 放行
        // （失败也放行，见 finishTimelineFirstPage；5 秒兜底见
        // scheduleDeferredSecondaryFallback）。keepDay 时当日仍走
        // deferredDayKeyForFirstPage 派生/回落机制，本组只延后日历。
        BearyTimelinePrefetch.cancelPendingPrefetch()
        deferredCalendarFetch = true
        scheduleDeferredSecondaryFallback()
        if keepDay {
            // 112：当日面板暂存选中日、不立即另发当日请求——首屏回包
            // 派生或回落（见 deferredDayKeyForFirstPage）；面板与首屏同批
            // 到达，不再比首屏早到（换一次冗余请求为同批更新）。
            deferredDayKeyForFirstPage = selectedDayKey
            loadTimelineFirstPage(completion: { [weak self] in self?.flushDeferredTimelineSecondary() }, force: false)
        } else {
            deferredDayKey = selectedDayKey
            deferredDayClear = true
            loadTimelineFirstPage(completion: { [weak self] in self?.flushDeferredTimelineSecondary() }, force: true)
        }
    }

    /// TL-9 供容器调用的刷新入口（详情改动、回收站恢复/删除后由容器调）：
    /// 首屏时间线 + 日历月份（强制重拉，日历圆点/统计重算）+ 当日面板重拉，
    /// 不重置选中日、不清当日面板；互动字段变化时按详情口径发 onInteractionChanged。
    /// 选中日由有篇变空时不再跳转（2026-11-04 不跳日口径），只显示该天空态。
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
    /// 乐观删除回滚位点（本批 ①）：remove 时记下的原位；失败时
    /// restoreDeletedEntry 按位插回。timelineIndex／dayIndex／日缓存位点
    /// 为 nil 表示当时不在该处；countsDecremented 记总数／公私计数是否
    /// -1 过；removedFromModel 为 false 时模型没动（只加了回收站计数），
    /// 回滚只复位计数与快照。
    struct TimelineDeleteRemoval {
        let timelineIndex: Int?
        let dayIndex: Int?
        let dayCacheKey: String?
        let dayCacheIndex: Int?
        let countsDecremented: Bool
        let removedFromModel: Bool
    }

    /// 乐观删除（本批 ①）：返回摘行前的原位供失败回滚；调用方忽略返回值时行为不变。
    @discardableResult
    func removeDeletedEntry(_ entry: Entry) -> TimelineDeleteRemoval {
        guard let entryId = entry.id else { return TimelineDeleteRemoval(timelineIndex: nil, dayIndex: nil, dayCacheKey: nil, dayCacheIndex: nil, countsDecremented: false, removedFromModel: false) }
        // 乐观回滚位点：摘行前先记原位（行在时间线／当日面板／日缓存各一处）。
        let timelineIndex = timelineEntries.firstIndex(where: { $0.id == entryId })
        let dayIndex = dayEntries.firstIndex(where: { $0.id == entryId })
        var dayCacheKey: String?
        var dayCacheIndex: Int?
        for (key, list) in dayEntriesCache {
            if let idx = list.firstIndex(where: { $0.id == entryId }) {
                dayCacheKey = key
                dayCacheIndex = idx
                break
            }
        }
        let countsDecremented = countsValue != nil
        // 连续删帖防撞：删帖即作废在途首屏回包——在途回包的 oldSections
        // 仍含本篇，其 diff 若在删帖批更新后到达，会对已删行再发
        // deleteRows（Invalid update 闪退）。seq 守卫会把这类旧回包
        // 丢弃（仅停菊花/收刷新头，不动模型与表）。
        timelineFirstPageSeq += 1
        // 删帖同时作废在途当日回包——删除前发出的 fetchDayEntries
        // 旧回包仍含本篇，到达后会整批替换当日面板并写回日缓存；
        // dayLoadSeq 守卫把它丢弃（回落分支的 refreshAfterDetailChange
        // 已间接推进序号，此处只覆盖常规路径）。
        dayLoadSeq += 1
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
            // 模型里没有（已被别处清掉），退回原有整页重拉保底；同时把
            // 快照同步写回（模型里已无本篇），免得重拉失败时快照复活它。
            // 筛子档不写盘：快照只代表全部档，筛后快照会污染下次冷启动。
            if let uid = SessionManager.shared.currentUser?.id {
                BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: timelineEntries, hasMore: timelineHasMore, trashCount: trashCountValue, counts: countsValue)
            }
            refreshAfterDetailChange()
            return TimelineDeleteRemoval(timelineIndex: timelineIndex, dayIndex: dayIndex, dayCacheKey: dayCacheKey, dayCacheIndex: dayCacheIndex, countsDecremented: countsDecremented, removedFromModel: false)
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
            BearyEntrySync.shared.runDiaryDiskWrite(accountId: uid) {
                // r17-C2：落盘写返回结果，失败记日志（内存态已更新，静默刷新会纠正）。
                let ok = BearyEntrySyncStore.removeEntry(accountId: uid, entryId: entryId)
                if !ok { NSLog("[BearyEntrySync] removeEntry failed account=%d entry=%@", uid, entryId) }
            }
            // 回收站桶同增：删帖即进回收站，下次进回收站页先读本地就能看到该条
            //（桶不存在时不建半截桶，进页走网络首拉；下次静默刷新用服务端值纠正残差）。
            // 26-25：进桶写走同步队列（不卡主线程删行）；进页读桶走同一队列
            //（loadFirstPage 经 runDiskWrite），先入队先执行，删完立刻进页仍能看到该条。
            // r17-C2：进桶写返回结果，失败记日志（无桶可写时返回 true，不记日志）。
            BearyEntrySync.shared.runTrashDiskWrite(accountId: uid) {
                if !BearyTrashSyncStore.prependDeleted(accountId: uid, entry: entry) {
                    NSLog("[BearyEntrySync] prependDeleted failed account=%d entry=%@", uid, entry.id ?? "-")
                }
            }
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
        // 删帖复活修：此前删帖只清了日落盘与内存模型，没写时间线首屏
        // 快照——冷启动先渲染快照，已删篇会先回来、要等一次静默刷新成功
        // 才纠掉，弱网/刷新失败时就一直复活。此处删帖即把快照同步写回。
        // 筛子档不写盘：快照只代表全部档，筛后快照会污染下次冷启动。
        if let uid = SessionManager.shared.currentUser?.id {
            BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: timelineEntries, hasMore: timelineHasMore, trashCount: trashCountValue, counts: countsValue)
        }
        // 连续删帖防撞：表当前已渲染行数须与 oldSections 一致才发批更新；
        // 若上一批动画/另一路更新还没落定（行数对不上），批更新必按旧
        // 下标删错行导致 Invalid update 闪退——此时模型已正确，整表重载
        // 即与模型对齐，不带病批更新。
        let renderedMatchesOld: Bool = {
            guard tableView.numberOfSections == oldSections.count else { return false }
            for section in 0..<oldSections.count {
                guard tableView.numberOfRows(inSection: section) == oldSections[section].entries.count else { return false }
            }
            return true
        }()
        if renderedMatchesOld {
            tableView.performBatchUpdates({
                if !rowDeletes.isEmpty { self.tableView.deleteRows(at: rowDeletes, with: .fade) }
                if !sectionDeletes.isEmpty { self.tableView.deleteSections(sectionDeletes, with: .fade) }
            }, completion: { [weak self] _ in
                guard let self = self else { return }
                // 面板头含计数（“N篇”），需重建头视图；日期组头无计数，不用动。
                // 批更新完成前用户若已切日/切页，section 0 未必仍是面板——
                // 越界 reloadSections 同样会闪退，先守卫再重载。
                if panelAffected, self.selectedDayKey != nil, self.tableView.numberOfSections > 0 {
                    self.tableView.reloadSections(IndexSet(integer: 0), with: .none)
                }
            })
        } else {
            tableView.reloadData()
        }
        pendingFixSelCheck = true
        for key in monthKeysForCurrentView() {
            fetchCalendarMonth(key: key, force: true)
        }
        return TimelineDeleteRemoval(timelineIndex: timelineIndex, dayIndex: dayIndex, dayCacheKey: dayCacheKey, dayCacheIndex: dayCacheIndex, countsDecremented: countsDecremented, removedFromModel: true)
    }

    /// 乐观删除失败回滚（本批 ①）：把该篇按原位插回时间线／当日面板／
    /// 日缓存（已在时不动，防重复恢复）；落盘逆操作与 remove 的写走同一
    /// 同步队列，先删后补、顺序有保证；总数／公私计数与回收站计数按
    /// remove 的算术对称复位；快照重写回；表整表重载（失败路径正确性优先）。
    /// 注意：seq 守卫已作废的在途回包不恢复（下次刷新重拉）；月份重拉是
    /// 服务端计数、与回滚后的模型一致，不用撤回。
    func restoreDeletedEntry(_ entry: Entry, removal: TimelineDeleteRemoval) {
        guard let entryId = entry.id else { return }
        if removal.removedFromModel {
            if let idx = removal.timelineIndex, !timelineEntries.contains(where: { $0.id == entryId }) {
                timelineEntries.insert(entry, at: min(idx, timelineEntries.count))
            }
            if let idx = removal.dayIndex, !dayEntries.contains(where: { $0.id == entryId }) {
                dayEntries.insert(entry, at: min(idx, dayEntries.count))
            }
            if let key = removal.dayCacheKey, let idx = removal.dayCacheIndex,
               !(dayEntriesCache[key]?.contains(where: { $0.id == entryId }) ?? false),
               var cachedDay = dayEntriesCache[key] {
                cachedDay.insert(entry, at: min(idx, cachedDay.count))
                dayEntriesCache[key] = cachedDay
            }
            // 落盘逆操作：upsert 补回日文件、removeItem 撤出回收站桶。
            if let uid = SessionManager.shared.currentUser?.id {
                BearyEntrySync.shared.runDiaryDiskWrite(accountId: uid) {
                    _ = BearyEntrySyncStore.upsertEntry(accountId: uid, entry: entry)
                }
                BearyEntrySync.shared.runTrashDiskWrite(accountId: uid) {
                    _ = BearyTrashSyncStore.removeItem(accountId: uid, entryId: entryId)
                }
            }
            if removal.countsDecremented, var counts = countsValue {
                counts.total = (counts.total ?? 0) + 1
                if entry.isPublic == true {
                    counts.pub = (counts.pub ?? 0) + 1
                } else {
                    counts.priv = (counts.priv ?? 0) + 1
                }
                countsValue = counts
                updateCountsLabel()
                refreshHeaderHeight()
            }
        }
        // 回收站计数与 remove 的 +1 对称复位（模型在与不在都 + 过 1）。
        trashCountValue = max(0, trashCountValue - 1)
        updateTrashTitle()
        if let uid = SessionManager.shared.currentUser?.id {
            BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: timelineEntries, hasMore: timelineHasMore, trashCount: trashCountValue, counts: countsValue)
        }
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    /// B5：彻底删除成功后只更新回收站计数（与删帖进回收站的 +1 对称）：
    /// 被删篇早已不在时间线/个人页，彻底删除除计数外不改变任何模型，
    /// 故不再整页重拉时间线与个人页。计数已知时本地 -1、刷新回收站钮、
    /// 同步写回时间线快照（仅全部档写盘，快照只代表全部档）；
    /// 计数未知时返回 false，调用方回落原有整页重拉校验，不谎报。
    /// - Returns: 计数是否已本地更新。
    @discardableResult
    func applyTrashPurged() -> Bool {
        guard trashCountKnown else { return false }
        trashCountValue = max(0, trashCountValue - 1)
        updateTrashTitle()
        if let uid = SessionManager.shared.currentUser?.id {
            BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: timelineEntries, hasMore: timelineHasMore, trashCount: trashCountValue, counts: countsValue)
        }
        return true
    }

    func refreshAfterDetailChange() {
        // 第 4 项删除后守卫：详情/回收站改动后，月份强制重拉到达时
        // 按日历计数复核选中日；2026-11-04 不跳日口径：空也不跳转/取消，
        // 只清挂起、走正常空态，不只靠当日面板变空。
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

    /// C4 详情往返只传变化：编辑/可见性变化按 id 原地更新，不重走首屏 +
    /// 月份 + 当日三路重拉（旧 refreshAfterDetailChange）。timelineEntries /
    /// dayEntries / 日缓存三处模型同改；可见行足数重渲，滚动位置不动。
    /// 可见性翻转不改日归属（createdAt 不动），公私计数按新旧 isPublic 调
    /// 整；日历月计数是月度聚合、篇数未变，不动。落盘由容器统一 upsert，
    /// 本方法另把首屏快照同步写回（与 removeDeletedEntry 同口径），免得
    /// 冷启动快照先复活旧字段。模型里没有本篇时只改命中处（日缓存）、不重拉。
    func applyEditedEntry(_ entry: Entry) {
        guard let entryId = entry.id else { return }
        func patched(_ old: Entry) -> Entry {
            var copy = old
            copy.title = entry.title
            copy.content = entry.content
            copy.images = entry.images
            copy.mood = entry.mood
            copy.weather = entry.weather
            copy.locationName = entry.locationName
            copy.locationDistrict = entry.locationDistrict
            copy.locationLatitude = entry.locationLatitude
            copy.locationLongitude = entry.locationLongitude
            copy.quoteId = entry.quoteId
            copy.quote = entry.quote
            if let v = entry.publishedAt { copy.publishedAt = v }
            if let v = entry.editDeadline { copy.editDeadline = v }
            if let v = entry.isPublic { copy.isPublic = v }
            if let v = entry.visibility { copy.visibility = v }
            copy.ephemeralUntil = entry.ephemeralUntil
            return copy
        }
        // 旧公开态取第一个命中模型的值（首屏 → 当日面板 → 日缓存）；
        // 三处都没有本篇时后面 guard 直接返回，不动计数。
        let oldEntry = timelineEntries.first(where: { $0.id == entryId })
            ?? dayEntries.first(where: { $0.id == entryId })
            ?? dayEntriesCache.values.flatMap({ $0 }).first(where: { $0.id == entryId })
        let oldPublic = oldEntry?.isPublic == true
        var updated = false
        for index in timelineEntries.indices where timelineEntries[index].id == entryId {
            timelineEntries[index] = patched(timelineEntries[index])
            updated = true
        }
        for index in dayEntries.indices where dayEntries[index].id == entryId {
            dayEntries[index] = patched(dayEntries[index])
            updated = true
        }
        for key in dayEntriesCache.keys {
            var list = dayEntriesCache[key] ?? []
            var listUpdated = false
            for index in list.indices where list[index].id == entryId {
                list[index] = patched(list[index])
                listUpdated = true
            }
            if listUpdated {
                dayEntriesCache[key] = list
                updated = true
            }
        }
        guard updated else { return }
        // 公开 ↔ 非公开翻转时公私计数 ±1（与 removeDeletedEntry 同口径，
        // isPublic==true 计公开、其余计私密；总量与月计数不变）。
        let newPublic = entry.isPublic == true
        if oldPublic != newPublic, var counts = countsValue {
            if newPublic {
                counts.pub = (counts.pub ?? 0) + 1
                counts.priv = max(0, (counts.priv ?? 0) - 1)
            } else {
                counts.pub = max(0, (counts.pub ?? 0) - 1)
                counts.priv = (counts.priv ?? 0) + 1
            }
            countsValue = counts
            updateCountsLabel()
            refreshHeaderHeight()
        }
        // 首屏快照同步写回（删帖同款）：冷启动先渲染快照，旧字段不得复活。
        // 筛子档不写盘：快照只代表全部档，筛后快照会污染下次冷启动。
        if let uid = SessionManager.shared.currentUser?.id {
            BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: timelineEntries, hasMore: timelineHasMore, trashCount: trashCountValue, counts: countsValue)
        }
        // 可见行足数重渲（applyInteraction 同款）：模型已改，滑回显示时
        // configure 取新值，不整表重载、不动滚动位置。
        let sections = currentSections()
        for sectionIndex in sections.indices {
            for rowIndex in sections[sectionIndex].entries.indices where sections[sectionIndex].entries[rowIndex].id == entryId {
                if let cell = tableView.cellForRow(at: IndexPath(row: rowIndex, section: sectionIndex)) as? BearyTimelineCell {
                    cell.configure(entry: sections[sectionIndex].entries[rowIndex])
                }
            }
        }
    }

    /// 113 详情互动同步：详情 onInteractionChanged 此前只推 feed，本方法补时间线一路——
    /// timelineEntries / dayEntries / 日缓存三处模型同改，可见行足数重渲；
    /// 详情侧失败回滚口径不动（本方法只写详情传来的确认值，不参与代次/回滚）。
    /// 注意：详情回调不带 bookmarkCount（与 feed 同口径），时间线足行收藏数
    /// 仍靠下次时间线重拉对齐；点赞数/已赞态/回应行可即时同步。
    func applyInteraction(entryId: String, likeCount: Int?, likedByMe: Bool?, bookmarkedByMe: Bool?, emotes: [EmoteCount]?) {
        func patched(_ entry: Entry) -> Entry {
            var copy = entry
            if let value = likeCount { copy.likeCount = value }
            if let value = likedByMe { copy.likedByMe = value }
            if let value = bookmarkedByMe { copy.bookmarkedByMe = value }
            if let value = emotes { copy.emotes = BearyEmoteOrder.merged(previous: copy.emotes, server: value) }
            return copy
        }
        var updated = false
        for index in timelineEntries.indices where timelineEntries[index].id == entryId {
            timelineEntries[index] = patched(timelineEntries[index])
            updated = true
        }
        for index in dayEntries.indices where dayEntries[index].id == entryId {
            dayEntries[index] = patched(dayEntries[index])
            updated = true
        }
        for key in dayEntriesCache.keys {
            var list = dayEntriesCache[key] ?? []
            var listUpdated = false
            for index in list.indices where list[index].id == entryId {
                list[index] = patched(list[index])
                listUpdated = true
            }
            if listUpdated {
                dayEntriesCache[key] = list
                updated = true
            }
        }
        guard updated else { return }
        // 可见行足数重渲（详情模态仍在前台，行不可见时此循环自然为空；
        // 模型已改，滑回/关详情后 configure 取新值，不另整表重载）。
        let sections = currentSections()
        for sectionIndex in sections.indices {
            for rowIndex in sections[sectionIndex].entries.indices where sections[sectionIndex].entries[rowIndex].id == entryId {
                if let cell = tableView.cellForRow(at: IndexPath(row: rowIndex, section: sectionIndex)) as? BearyTimelineCell {
                    cell.configure(entry: sections[sectionIndex].entries[rowIndex])
                }
            }
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
            // 审计-时间线：双副本补丁一并同步 visibility 与 ephemeralUntil（仅好友切私密后图标不再残留仅好友态；限时标记跟随新值，到期翻转由 tick 复核负责）。
            merged.visibility = freshEntry.visibility
            merged.ephemeralUntil = freshEntry.ephemeralUntil
            merged.publishAt = freshEntry.publishAt
            if let publishedAt = freshEntry.publishedAt { merged.publishedAt = publishedAt }
            // 批 E 补漏：双副本补丁此前不合并定位字段——日面板/时间线任一副本
            // 先拿到无定位旧值（落盘缓存、旧回包），另一副本重拉拿到定位后也
            // 同步不过去，位置行恒按旧值渲染。两路回包均来自同一列表接口、
            // 同为服务端权威行，故无条件跟随新值（含清定位时新值为 nil）。
            merged.locationName = freshEntry.locationName
            merged.locationDistrict = freshEntry.locationDistrict
            // 审计第 8 轮补正（时间线同款）：双副本补丁同步标签——日面板回包拿到新标签后时间线副本也要跟上，否则 timelinePatchChanged 判不出变化、时间线行恒显旧标签；回包缺 tags 字段时保留旧值，不清空（与 emotes 同口径；服务端富化恒给字段）。
            if let freshTags = freshEntry.tags { merged.tags = freshTags }
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
    /// 手指行程（pan 手势自顶部锚点起算）× 0.48 阻尼、上限 116；转满一圈在指示高 67.2（= 触发行程 140pt × 0.48），满格点即触发点；图标 alpha 在 30–67.2 间淡入至满。
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
            let progress = min(1, indicatorHeight / 67.2)
            refreshIconView.setPullProgress(progress)
            // 时间线与消息页的关键差别：消息页表框顶 = 安全区顶，表框裁剪会把
            // 指示高 <30 时的图标（中心在安全区顶之上）裁掉；本页表框贴页顶，
            // 表框裁剪裁不掉它，早期图标会 faint 地出现在灵动岛带内。故用 alpha
            // 门模拟同一裁剪：图标中心在指示高 30 时才越过安全区顶，30 以下
            // alpha 强制 0，30–67.2 间按 (指示-30)/37.2 淡入至满 alpha；转满一圈在
            // 指示高 67.2（= 触发行程 140pt × 0.48），满格点即触发点。
            if indicatorHeight <= 30 {
                refreshIconView.alpha = 0
            } else {
                refreshIconView.alpha = min(1, (indicatorHeight - 30) / 37.2)
            }
        }
    }

    /// 自定义下拉刷新进入（消息页 beginCustomPullRefresh 同款，基线适配时间线）：
    /// 指示固定 84 高 + 转圈，回包到即收回（第 2 项后无 0.5 秒最低展示，见 loadTimelineFirstPage 完成分支），
    /// 刷新中内边距 = 基线（安全区顶 + 可见时 60）+ 84，屏内指示底边 = 基线 +84，
    /// 图标中心 = 基线 +54，灵动岛下方；减动效时直接落位，不播 0.38s 动画。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing || timelineState == .loading {
            return
        }
        isCustomPullRefreshing = true
        customPullStartTime = Date()
        refreshIconView.startSpinning()
        // 回程一次到位：先掐断松手后的表减速/回弹（位置不动、仅停掉动量）。
        // 否则表自带物理动画会与下面 easing 动画双路驱动 contentOffset：
        // 先随惯性多下一截、再被拉回 84 位，即“先下降一点再回去”；
        // 旧 0.32s 默认 easeInOut 零初速起手、与手指甩速脱节，手感发轻。
        tableView.setContentOffset(tableView.contentOffset, animated: false)
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
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullIn)
        }
        // 112 刷新节流（仅手势下拉）：上次首屏网络成功 5 秒内且已有行时，
        // 不再发网络请求，指示头随 0.38s 收回动画收回（第 2 项后首屏完成
        // 分支也不再等 500ms）；程序侧刷新（重拍 tab/详情回写/
        // 登录翻转）不受此限。begin 顶部的
        // timelineState == .loading 守卫仍在：静默对齐在途时下拉直接忽略。
        if let last = lastTimelineFirstPageSuccessAt, Date().timeIntervalSince(last) < 5, !timelineEntries.isEmpty {
            endCustomPullRefresh()
            return
        }
        // 原 pullToRefresh 体（触觉改由 scrollViewDidEndDragging 给一次，见下）：
        // G16：刷新时先保存选中日（reloadTimeline keepDay 分支内保留），
        // 跳过当日拉取，只拉一次最终选中日；不再先拉今天再拉回原选中日。
        // 第 2 项 A 调用点 2/2（下拉刷新）：keepSelectedDay 下守卫接在刷新
        // 完成后——当日/月份回包到达时消费本标志；2026-11-04 不跳日口径：
        // 选中日已空也不跳转，只清挂起、走正常空态。
        pendingEntryJumpCheck = true
        reloadTimeline(keepSelectedDay: true)
        // fixall-sync 5-27 集成接线：被守卫挡下的同步在下拉刷新时重跑（内部去重已覆盖已同步/在途）。
        BearyEntrySync.shared.kickForCurrentUser()
        refreshHeaderHeight()
    }

    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing || customPullEndInFlight {
            return
        }
        customPullEndInFlight = true
        // 收回动画全程仍持刷新旗（同广场端）：跟随侧不中途重写 pullView.frame。
        let baseTop = view.safeAreaInsets.top + (headerTopInsetVisible ? 60 : 0)
        let baseBottom = 90 + view.safeAreaInsets.bottom
        // 广场端同款保护：结束时只收指示器——若刷新在途用户已滑到深处（或仍按住拖动），
        // 不再把 contentOffset 拽回 -baseTop 顶部，只复位内边距、藏指示头，留在原位置；
        // 仍停在下拉位的才按旧口径回到 -baseTop（指示区须收掉）。
        // 下拉位 = -(baseTop + 84)（见 beginCustomPullRefresh）；8pt 容差内算仍在下拉位。
        let stillAtPullPosition = !self.tableView.isDragging
            && self.tableView.contentOffset.y <= -(baseTop + 84) + 8
        let pullOut = {
            self.tableView.contentInset.top = baseTop
            self.tableView.contentInset.bottom = baseBottom
            self.tableView.scrollIndicatorInsets.top = baseTop
            self.tableView.scrollIndicatorInsets.bottom = baseBottom
            if stillAtPullPosition {
                self.tableView.contentOffset = CGPoint(x: 0, y: -baseTop)
            }
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.isCustomPullRefreshing = false
            self.customPullEndInFlight = false
            self.refreshIconView.stopSpinning()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullOut, completion: { _ in
                self.isCustomPullRefreshing = false
                self.customPullEndInFlight = false
                self.refreshIconView.stopSpinning()
            })
        }
    }

    // MARK: - TL-2 1 秒 tick（仅限时到期复核；编辑倒计时已随锁取消）

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
        // 审计-时间线：只跑限时到期复核（到期的可见行原地重算有效态）；
        // 编辑倒计时已随 15 分钟锁取消（冲突清单第 4 条），不再每秒刷行。
        sweepEphemeralExpiry()
    }

    /// 审计-时间线：限时到期复核（时间线页内版，详情页 Timer＋前台复核口径）：
    /// tick 到达 ephemeralUntil 时，对可见行重算有效态并原地刷新——pill/虚线框/图标由 cell.configure 按有效态重绘；
    /// 当日面板行走分区重载（面板头后缀同步翻转），时间线行走单行重载；不整表重载、不改存储态 isPublic；
    /// 其他列表页（Feed/搜索/个人页/星图/地图列表）的到期复核由权限组统筹，本支不碰。
    /// F7 夜巡：行翻了、数没翻——表头“公开 X · 私密 Y”与当月圆点仍按过期前算，故 sweep
    /// 命中过期时同步调本地计数（见 applyExpiredEphemeralCounts），只动客户端缓存口径。
    private func sweepEphemeralExpiry() {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var expiredIds: [String] = []
        var expiredEntries: [Entry] = []
        for entry in timelineEntries + dayEntries {
            // 同一篇可能同时在 timelineEntries 与 dayEntries 里：旧代码会把 id 追加两次
            // （当时只多一次行重载、无害）；计数调整按篇扣，去重后才准。
            guard let entryId = entry.id, !expiredEphemeralHandledIds.contains(entryId), !expiredIds.contains(entryId) else { continue }
            if let until = entry.ephemeralUntil, until <= nowMs, entry.isPublic == true {
                expiredIds.append(entryId)
                expiredEntries.append(entry)
            }
        }
        let liveIds = Set((timelineEntries + dayEntries).compactMap { $0.id })
        expiredEphemeralHandledIds = expiredEphemeralHandledIds.intersection(liveIds)
        guard !expiredIds.isEmpty else { return }
        let sections = currentSections()
        var panelExpired = false
        var rowReloads: [IndexPath] = []
        for entryId in expiredIds {
            expiredEphemeralHandledIds.insert(entryId)
            for (sectionIndex, section) in sections.enumerated() {
                guard let row = section.entries.firstIndex(where: { $0.id == entryId }) else { continue }
                if sectionIndex == 0 && selectedDayKey != nil {
                    panelExpired = true
                } else if tableView.indexPathsForVisibleRows?.contains(IndexPath(row: row, section: sectionIndex)) == true {
                    rowReloads.append(IndexPath(row: row, section: sectionIndex))
                }
                break
            }
        }
        if panelExpired && tableView.numberOfSections > 0 {
            tableView.reloadSections(IndexSet(integer: 0), with: .none)
        }
        if !rowReloads.isEmpty {
            tableView.reloadRows(at: rowReloads, with: .none)
        }
        // F7：行已翻、数同步翻（表头计数＋当月圆点），见下。
        applyExpiredEphemeralCounts(expiredEntries)
    }

    /// F7 夜巡：限时篇前台过期后，表头“公开 X · 私密 Y”与当月圆点仍按过期前算——
    /// sweep 只 reload 可见行/面板分区，不动 countsValue 与 calendarCache。
    /// 本方法在 sweep 命中过期时同步调本地计数，口径与改可见性同款（applyEditedEntry :3571）：
    /// 公开 −1／私密 +1，总量不变；只在缓存 pub > 0 时扣（服务端若已按有效态下发，
    /// 回包在过期后，本地不再重复扣）。日历圆点就地改缓存当日的 pub/priv，不删月缓存——
    /// 删缓存会先闪空统计行（updateStatsLine 空态签名）、弱网失败后圆点直接丢；
    /// 就地改无网络依赖，失败也不丢数。月总数与 streak 不受过期影响（总量不变、
    /// streak 只计写作日），不碰。服务端 tl_counts 与日历 pub 均已按有效公开算
    /// （服务端 ephemeral_until > now 条款），下次刷新整体覆盖本地值时与本调整一致，
    /// 不会回弹（核实见本支 NOTES）。
    private func applyExpiredEphemeralCounts(_ expiredEntries: [Entry]) {
        var countsChanged = false
        var touchedViewMonths = Set<String>()
        for entry in expiredEntries {
            // 表头计数：过期篇下发时计公开，本地按有效态公开 −1／私密 +1。
            if var counts = countsValue, (counts.pub ?? 0) > 0 {
                counts.pub = (counts.pub ?? 0) - 1
                counts.priv = (counts.priv ?? 0) + 1
                countsValue = counts
                countsChanged = true
            }
            // 日历圆点：就地改缓存当日的 pub/priv（只改已缓存的月；未缓存的月下次拉取为准，
            // 服务端同口径）。日分桶与服务端一致：北京日界（BearyBeijingDay :3）。
            if let created = entry.createdAt,
               let comp = BearyBeijingDay.components(ofMs: created) {
                let monthKey = BearyBeijingDay.monthKey(year: comp.year, month: comp.month)
                let dayKey = "\(comp.day)"
                if var month = calendarCache[monthKey],
                   var days = month.days,
                   var dayCount = days[dayKey],
                   (dayCount.pub ?? 0) > 0 {
                    dayCount.pub = (dayCount.pub ?? 0) - 1
                    dayCount.priv = (dayCount.priv ?? 0) + 1
                    days[dayKey] = dayCount
                    month.days = days
                    calendarCache[monthKey] = month
                    touchedViewMonths.insert(monthKey)
                }
            }
        }
        if countsChanged {
            updateCountsLabel()
            refreshHeaderHeight()
            // 切档快照同写：否则切档回来 countsValue 被快照里的旧值顶回（applyVisFilter :2899）。
            if let snap = filterSnapshots[.all] {
                filterSnapshots[.all] = FilterSnapshot(entries: snap.entries, hasMore: snap.hasMore, trashCount: snap.trashCount, counts: countsValue)
            }
            // 首屏快照同步写回（删帖/改可见性同款）：冷启动先渲染快照，纠过的计数不得复活。
            if timelineVisFilter == .all, let uid = SessionManager.shared.currentUser?.id {
                BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: timelineEntries, hasMore: timelineHasMore, trashCount: trashCountValue, counts: countsValue)
            }
        }
        // 圆点只在受影响月份处于当前视图时重画（月份回包同款：renderCalendar + 表头高度）。
        if !touchedViewMonths.isEmpty, !Set(monthKeysForCurrentView()).isDisjoint(with: touchedViewMonths) {
            renderCalendar()
            refreshHeaderHeight()
        }
    }

    /// 前台复核：后台期间 tick 未跑时，到期在此补位；未到期则不动（1 秒 tick 接续）。
    @objc private func handleForegroundEphemeralCheck(_ note: Notification) {
        sweepEphemeralExpiry()
    }

    /// 发布后补拉待办变迁（第三批体验检查第 1 项）：只处理选中日——先清
    /// 分区快照再重载面板分区，刷新表头“同步中”后缀；待办已落盘
    /// （resolved）时再静默重拉该日，把新篇接进面板（未变时回包不碰表）。
    @objc private func handlePendingRefetchChanged(_ note: Notification) {
        guard let dayKey = note.userInfo?["dayKey"] as? String, dayKey == selectedDayKey else { return }
        cachedSections = nil
        updateChrome()
        if !reloadDayPanelSectionIfStable() { tableView.reloadData() }
        if note.userInfo?["resolved"] as? Bool == true {
            fetchDayEntries(key: dayKey, clear: false)
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
        statusBarBgView.isHidden = false
        view.insertSubview(statusBarBgView, belowSubview: stickyHeaderContainer)
        // 层级钉死：底色恒在表之上、吸顶容器之下，后续再加覆盖层也不至于把它压到表后。
        view.bringSubviewToFront(statusBarBgView)
        view.bringSubviewToFront(stickyHeaderContainer)
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
        // 刷新失败条在屏时吸顶日期头让位：两者同占内容顶区，叠加会重叠且错位；
        // 条收起后 updateStickyHeader 重入即恢复。
        if !refreshFailedBanner.isHidden { hideStickyHeader(); return }
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
        }
    }

    /// 吸顶日期换日动效：旧日期上滑淡出、新日期从下方滑入淡入，同时走、
    /// 吸顶日期换日动效：同一 label 两段衔接、只动 transform/opacity。
    /// 旧日期上滑淡出（motion.micro 0.18s easeIn）→ 在 alpha=0 时换字 → 新日期从下方
    /// 滑入淡入（motion.micro 0.18s easeOut），总时长 0.36s；任何时刻只显示一个日期，
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
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut]) {
                self.stickyHeaderLabel.transform = .identity
                self.stickyHeaderLabel.alpha = 1
            }
            return
        }
        // 可见态换日：不 removeAllAnimations（那会把呈现态 snap 回模型态），
        // 新退场直接从当前呈现态起手；被取代的旧退场 completion 以
        // finished=false 回调、跳过换字。
        UIView.animate(withDuration: BearyMotion.micro, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.stickyHeaderLabel.transform = CGAffineTransform(translationX: 0, y: -8)
            self.stickyHeaderLabel.alpha = 0
        } completion: { finished in
            guard finished else { return }
            // 此时 alpha=0：换字与 transform 复位（上滑终态 -8 → 下方 +8）
            // 均不可见，入场从 +8 滑回静止态，静止 frame 与基线与换日前一致。
            self.stickyHeaderLabel.text = title
            self.stickyHeaderLabel.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(withDuration: BearyMotion.micro, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.stickyHeaderLabel.transform = .identity
                self.stickyHeaderLabel.alpha = 1
            }
        }
    }

    private func hideStickyHeader() {
        if stickyHeaderContainer.isHidden == false {
            stickyHeaderContainer.isHidden = true
        }
        // 注意：此处不再藏 statusBarBgView——换日交接时吸顶头藏起的那几帧，
        // 正是真实组头滑进状态栏区的时刻，底色必须留着盖住它。
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
        // 加载三件套·加载更多：滑到离底部一屏时预加载下一页（复用现有
        // loadTimelineNextPage；loading/失败/无更多时守卫拦住）。
        if !timelineLoadingMore, timelineHasMore, !timelinePageFailed, !timelineEntries.isEmpty {
            let y = scrollView.contentOffset.y
            let remaining = scrollView.contentSize.height - (y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom)
            if remaining <= scrollView.bounds.height {
                loadTimelineNextPage()
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === tableView else { return }
        // 自定义下拉触发（消息页同款）：手指原始行程满 140pt 松手才刷新。
        // M12（91 包）：触发给一次轻触觉；程序触发的刷新不走这里。
        let panTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 140 && timelineState != .loading && !isCustomPullRefreshing {
            BearyHaptics.press()
            beginCustomPullRefresh()
        }
        // 秒开批·图片预热：不减速即已停稳，直接预热下一屏。
        if !decelerate { prefetchNextScreen() }
    }

    /// 秒开批·图片预热：滚动停稳时预热下一屏；滚动开始时取消在途预热，
    /// 不与当前屏抢连接。
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        prefetchNextScreen()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        BearyImagePrefetcher.shared.cancel()
    }

    private func buildHeader() {
        headerContainer.backgroundColor = BearyColors.bg

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "时间线"
        // R8：控制器自有正文类标签走 scaledFont + adjusts。
        // 2026-11-10 Li 定：时间线头由 tab 头档 19 调大为 21 bold，与消息头同改。
        titleLabel.font = BearyDynamicType.scaledFont(for: BearyDynamicType.serifDesign(for: UIFont.boldSystemFont(ofSize: 21)))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink

        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.backgroundColor = BearyColors.surface2
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
        countsLabel.font = BearyDynamicType.captionFont()
        countsLabel.adjustsFontForContentSizeCategory = true
        countsLabel.textColor = BearyColors.gray
        // 跳动修：计数行恒占一行高。首屏 fitted 时计数为空，空文本 label 在
        // fitting 下高度塌掉，表头算短；计数写入后重算长出一行，整列瞬间下跳。
        // 行高钉死一行（≥ 行高：有文案时内在高度若略大仍以其为准，不裁剪），
        // 首帧即按有计数的高度搭，计数写入不再改表头高。字号变化时约束常量
        // 在 traitCollectionDidChange 里随新字号重算。
        let countsMinHeight = countsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: countsLabel.font.lineHeight)
        countsMinHeight.isActive = true
        countsLabelMinHeightConstraint = countsMinHeight

        calendarCard.translatesAutoresizingMaskIntoConstraints = false
        calendarCard.onSelectDay = { [weak self] day in
            self?.didSelectCalendarDay(day)
        }
        calendarCard.onToggleView = { [weak self] in
            self?.toggleCalendarView()
        }
        // 轻扫切周/切月、年月长按/方向键步进：步长由 VC 按模式换算。
        calendarCard.onStepCalendar = { [weak self] delta in
            self?.stepCalendar(delta: delta)
        }
        calendarCard.onStepYear = { [weak self] delta in
            self?.stepCalendarYear(delta: delta)
        }
        calendarCard.onStepMonth = { [weak self] delta in
            self?.stepCalendarMonth(delta: delta)
        }
        calendarCard.onGoToday = { [weak self] in
            self?.goToToday()
        }
        // R15-L1：日历失败重试只留卡内一处（didTapStats 重拉全部可视失败月份）。
        calendarCard.onRetry = { [weak self] in
            self?.didTapStats()
        }

        // 写一笔速写器（表头底部）：写选中那天的日记，见 BearyInlineComposerView；
        // 发布回调走 publishInlineComposer。
        inlineComposer.translatesAutoresizingMaskIntoConstraints = false
        inlineComposer.presenter = self
        inlineComposer.onToast = { [weak self] message in
            self?.showTimelineToast(message: message)
        }
        inlineComposer.onHeightChanged = { [weak self] in
            self?.refreshHeaderHeight()
        }
        inlineComposer.onPublish = { [weak self] snapshot in
            self?.publishInlineComposer(snapshot)
        }
        inlineComposer.onFocusChanged = { [weak self] focused in
            self?.inlineComposerFocused = focused
            self?.refreshHeaderHeight()
        }
        inlineComposer.onRequireLogin = { [weak self] in
            self?.onRequireLogin?()
        }

        // 表头顺序（v14 改版）：标题与回收站 → 合并统计行（共 X 篇／
        // 私密／公开／连续天数／本月，本月计数只在统计行留）→ 日历
        // → 写一笔速写器 → 日记；≥821pt 居中列 / ≤820pt 全宽列与左右
        // 各 16 边距一律不动（见下方约束与 SceneDelegate 宽度口径）。
        let stack = UIStackView(arrangedSubviews: [titleRow, countsLabel, calendarCard, inlineComposer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.setCustomSpacing(4, after: titleRow)
        stack.setCustomSpacing(2, after: countsLabel)
        stack.setCustomSpacing(12, after: calendarCard)
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

    /// TL-4 翻页/切换动效（审计 14 重构）：目标切换与补拉请求先行——
    /// mutate（含 renderCalendar 与 fetchCalendarMonthsForCurrentView）
    /// 在动画开始前同步执行，请求不再等 0.18s 淡出才发起；视觉只剩
    /// 一次 0.22s 交接（淡入 + 表头高度 FLIP），合计约 0.22s（原 0.18 淡出
    /// + 0.24 淡回 ≈ 0.42s）。同一 runloop 内先 mutate 再把卡片置为淡出初态，
    /// 下一帧才开始呈现，故用户看不到未过动画的新内容闪现；减动效时仍直接
    /// 变更、无动效。
    /// 周/月切换卡片不再横移：旧口径淡入 + 横移 8pt 回位，切换时卡片先偏右
    /// 8pt 再滑回原位，观感即“左右漂移”；现只剩淡入，卡片位置与宽度纹丝
    /// 不动，只有里面的日期内容变。翻页（stepCalendar）早已不走本过渡。
    /// 6-3 例外（日历高度部分，定版不改 transform）：表头高度本身就是
    /// tableHeaderView 的布局高度，表体各行必须随高度差整体平移——只对
    /// calendarCard 做 scaleY 会把格子/日期圆压扁（30pt 圆、50pt 行高失真），
    /// 只做平移 + 裁剪则新月多出的行会被裁掉、或与表体行重叠；高度差只能
    /// 由 frame + layoutIfNeeded 带过去。卡片自身的淡入仍只动 alpha，不在此例外内。删行高度收起不在本文件（回收站
    /// 文件，#5 批已定例外），此处不动。
    private func performCalendarTransition(mutate: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            mutate()
            refreshHeaderHeight()
            return
        }
        let oldHeight = headerContainer.frame.height
        mutate()
        let newHeight = fittingHeaderHeight()
        calendarCard.alpha = 0
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: {
            self.calendarCard.alpha = 1
            if abs(newHeight - oldHeight) >= 1 {
                self.headerContainer.frame = CGRect(x: 0, y: 0, width: self.tableView.bounds.width, height: newHeight)
                self.tableView.tableHeaderView = self.headerContainer
                self.tableView.layoutIfNeeded()
            }
        }, completion: { [weak self] _ in self?.refreshHeaderHeight() })
    }


    /// 月视图错峰时要跳过的本周日期 key（网页 calStaggerMonthCells 口径）。
    private func currentWeekKeys() -> Set<String> {
        guard let anchor = calendarAnchor else { return [] }
        guard let weekStart = BearyBeijingDay.weekStartOf(year: anchor.year, month: anchor.month, day: anchor.day) else { return [] }
        var keys: Set<String> = []
        for offset in 0..<7 {
            guard let day = BearyBeijingDay.shifted(year: weekStart.year, month: weekStart.month, day: weekStart.day, byDays: offset) else { continue }
            keys.insert(BearyBeijingDay.dayKey(year: day.year, month: day.month, day: day.day))
        }
        return keys
    }

    /// 回收站标题上次渲染的计数值（本批新规矩：数值不变不重建标题；
    /// 数值变时只动“ N篇”数字段，静态段“回收站”不动，见 updateTrashSuffixOnly）。
    private var lastTrashCount: Int?
    /// 回收站 pill 宽度下限约束：按钮 intrinsic 会把双段富文本标题算短约 2pt
    /// （13/12 双字号，浮点尾巴），标题在 68pt 标签里差 2pt 即中部截断；
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
            // 116：数字段-only 更新后只淡入标题文案（图标不动）。
            fadeButtonTitle(trashButton)
            return
        }
        let base = NSMutableAttributedString(string: "回收站", attributes: [
            .font: BearyDynamicType.secondaryFont(),
            .foregroundColor: BearyColors.ink,
        ])
        if trashCountValue > 0 {
            base.append(NSAttributedString(string: " \(trashCountValue)篇", attributes: [
                .font: BearyDynamicType.captionFont(),
                .foregroundColor: BearyColors.gray,
            ]))
        }
        trashButton.setAttributedTitle(base, for: .normal)
        lastTrashCount = trashCountValue
        fitTrashButtonWidth()
        // 116：整行重建路径同样只淡入标题文案（图标不动）。
        fadeButtonTitle(trashButton)
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
                .font: BearyDynamicType.captionFont(),
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

    /// 116 数据填入动效：文案／数字变化时只淡入该元素本身（alpha 0→1、
    /// 0.26s，不动 transform／布局、不重建节点、不缩放弹一下）；同值不赋值
    /// 不重播；减动效或未进窗口时直设终值。按钮只淡入 titleLabel，图标
    /// （火苗／回收站图标）不动，符合“数字只动数字本身”。
    private func setLabelTextFaded(_ label: UILabel, _ text: String) {
        BearyLabelFade.setText(text, on: label, duration: BearyMotion.normal)
    }

    private func fadeButtonTitle(_ button: UIButton) {
        guard !UIAccessibility.isReduceMotionEnabled, button.window != nil,
              let titleLabel = button.titleLabel else { return }
        titleLabel.alpha = 0
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            titleLabel.alpha = 1
        })
    }

    /// 计数行入口（v14 改版）：统计已并入标题下方一行小字，统一走
    /// updateMergedStatsLine（116：文案不变时不重写、不重播淡入）。
    private func updateCountsLabel() {
        updateMergedStatsLine()
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
            // r17-C1：落盘恢复的旧数据标记随缓存一起摘（统计不再认旧）；
            // calendarSnapshotRestoreTried 故意不清——删缓存后走网络重拉，
            // 不得用旧落盘把刚失效的缓存顶回去。
            calendarStreakUnknownKeys.remove(key)
        }
    }
    private var lastStatsLineSignature: String?
    /// 统计行上次渲染的数值（与签名分离：数值段替换时也要同步，供下次比对）。
    private var lastStatsStreak: Int?
    private var lastStatsMonthTotal: Int?

    // MARK: - 统计行与日历失败态（R15-L1：悬浮条已收掉，重试只留卡内）
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            // 跳动修：计数行最小高度随新字号重算（否则大字号下行高钉死旧值、文案被裁）。
            countsLabelMinHeightConstraint?.constant = countsLabel.font.lineHeight
        }
    }

    /// 连续写作行：网页 .cal-stats（13.5 灰、数字墨色加粗、16pt 橙色火苗图标）。
    /// 火苗图为本批新建的 icon_fire 资产（beary.html #beary-fire sprite 路径渲染）。
    /// R15-L1：日历失败重试只留卡内一处（BearyCalendarCardView.setLoadFailed，
    /// 重试走 didTapStats）；统计行失败时只留空、不再变重试入口（旧 G14
    /// 统计行重试与 113 顶部悬浮条随本支一并收掉）。在途/缺失月份不出加载态
    ///（无“日历加载中…”）。
    /// 合并统计行（v14 改版：statsButton 已删，统计退到标题下方一行小字）：
    /// “共 X 篇 · 私密 X · 公开 X”＋streak>0 时“ · 已连续写 X 天”＋
    /// “ · 本月共 X 篇”；streak 0 天整项不显示；日历失败/未知态时只出
    /// counts 部分。updateCountsLabel 与 updateStatsLine 都走本函数；
    /// 文案不变时不重写（签名守卫）。
    private func updateMergedStatsLine() {
        // 卡内失败行先于签名守卫更新——切月/重试后失败态可能已变，显隐每次重算
        //（不靠签名守卫）；显隐真变时重算表头高度（失败行约 20pt）。
        let visibleKeys = monthKeysForCurrentView()
        let failedUncached = visibleKeys.filter { calendarFailed.contains($0) && calendarCache[$0] == nil }
        let failedStale = visibleKeys.filter { calendarFailed.contains($0) && calendarCache[$0] != nil }
        let anyVisibleCached = visibleKeys.contains { calendarCache[$0] != nil }
        let failedText: String
        if !failedUncached.isEmpty, anyVisibleCached {
            failedText = "只加载了一部分"
        } else if !failedStale.isEmpty, failedUncached.isEmpty {
            failedText = NSLocalizedString("common.showing_previous_content", comment: "")
        } else {
            failedText = "日历加载失败"
        }
        if calendarCard.setLoadFailed(!failedUncached.isEmpty || !failedStale.isEmpty, text: failedText) {
            refreshHeaderHeight()
        }
        var parts: [String] = []
        if let counts = countsValue {
            let total = counts.total ?? 0
            let priv = counts.priv ?? 0
            let pub = counts.pub ?? 0
            parts.append(String(format: NSLocalizedString("timeline.stats.summary", comment: ""), total, priv, pub))
        }
        let anyVisibleFailed = visibleKeys.contains { calendarFailed.contains($0) && calendarCache[$0] == nil }
        if !anyVisibleFailed, let primaryKey = primaryStatsMonthKey(), let data = calendarCache[primaryKey] {
            let monthTotal = data.monthTotal ?? 0
            if data.streak == nil, calendarStreakUnknownKeys.contains(primaryKey) {
                // r17-C1：跨日恢复的 streak 未重新确认（nil）时不报连续天数，
                // 只报本月篇数；刷新到达后恢复完整行。
                parts.append(String(format: NSLocalizedString("timeline.stats.month_total", comment: ""), monthTotal))
            } else {
                let streak = data.streak ?? 0
                if streak > 0 {
                    parts.append(String(format: NSLocalizedString("timeline.stats.streak", comment: ""), streak))
                }
                parts.append(String(format: NSLocalizedString("timeline.stats.month_total", comment: ""), monthTotal))
            }
        }
        let text = parts.joined(separator: " · ")
        guard text != lastStatsLineSignature else { return }
        lastStatsLineSignature = text
        setLabelTextFaded(countsLabel, text)
    }

    /// 旧统计行入口（statsButton 已删）：统一走合并统计行。
    private func updateStatsLine() {
        updateMergedStatsLine()
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

    /// 开发者模式变化：日期 / 假日记改动走整页重拉（锚点按假日重算）；
    /// 强制态直接置态渲染；字号只重载表（字号在 configure 时重算）。
    @objc private func handleDevModeChanged(_ note: Notification) {
        let kind = (note.userInfo?["kind"] as? String) ?? ""
        switch kind {
        case "date", "fakeEntries":
            reloadTimeline(keepSelectedDay: false)
        case "forcedTimeline":
            applyDevForcedTimeline()
        case "font":
            tableView.reloadData()
        default:
            break
        }
    }

    /// 开发者模式时间线强制态（仅内存）：error / empty / loading 直接置态渲染，不发请求；
    /// 清除后走一次正常重拉。
    private func applyDevForcedTimeline() {
        switch BearyDevPreviewState.forcedTimeline {
        case .none:
            reloadTimeline(keepSelectedDay: false)
        case .error:
            timelineState = .failed
            timelineUnauthorized = false
            timelineEntries = []
            dayEntries = []
            tableView.reloadData()
            updateChrome()
        case .empty:
            timelineState = .loaded
            timelineEntries = []
            dayEntries = []
            tableView.reloadData()
            updateChrome()
        case .loading:
            timelineState = .loading
            timelineEntries = []
            dayEntries = []
            tableView.reloadData()
            updateChrome()
        }
    }

    private func loadTimelineFirstPage(completion: (() -> Void)? = nil, force: Bool = false) {
        // 账号隔离：任何一次真实取数即结束首帧身份待确认态（见 identityPendingFirstLoad）。
        identityPendingFirstLoad = false
        // 112：在途跳过（force 除外）——跳过时不 bump seq、不改状态，
        // 在途回包自会渲染；completion 暂存、在途匹配完成时补调。
        if timelineFirstPageInFlight && force == false {
            if let completion = completion {
                timelineFirstPagePendingCompletions.append(completion)
            }
            return
        }
        // 本次刷新真正启动：旧失败条收起，本次结果自会再定。
        setRefreshFailedBannerVisible(false)
        // 开发者模式强制态（仅内存）：不发请求，按强制态渲染。
        if BearyDevPreviewState.forcedTimeline != .none {
            applyDevForcedTimeline()
            completion?()
            return
        }
        timelineFirstPageSeq += 1
        // 审计 r16 第 17 项：首拉重开即清分页退避（新一轮分页从头计）。
        timelinePageFailureCount = 0
        timelinePageRetryNotBefore = nil
        let seq = timelineFirstPageSeq
        timelineFirstPageInFlight = true
        timelineState = .loading
        updateChrome()
        // M2：已有行只更新变化行——刷新前记下旧分区，成功后若分区结构（日期键序列）
        // 不变则按行 diff 插删改，否则回落整表 reloadData（首屏旧表为空时同样 reloadData）。
        let oldSections = currentSections()
        let hadOldRows = timelineEntries.isEmpty == false
        // 113：常规刷新（force 除外、已有行）先走 since 增量——新篇前插、
        // 旧篇不动、不跳顶；空表、force、游标取不到时走全量。
        if force == false,
           let head = timelineEntries.first,
           let cursor = head.createdAt,
           let headId = head.id, !headId.isEmpty {
            loadTimelineSince(
                seq: seq, oldSections: oldSections, hadOldRows: hadOldRows,
                cursor: cursor, headId: headId, completion: completion
            )
        } else {
            fetchTimelineFirstPageFull(
                seq: seq, oldSections: oldSections, hadOldRows: hadOldRows, completion: completion
            )
        }
    }

    /// 113：首屏全量取数（原 loadTimelineFirstPage 的取数体，不动口径；
    /// since 失败/无新条目时同一 seq/在途标记内续发本函数，不再过在途守卫）。
    private func fetchTimelineFirstPageFull(seq: Int, oldSections: [DaySection], hadOldRows: Bool, completion: (() -> Void)? = nil) {
        // A4：回包处理（自发请求与接手预取共用；BearyAPI 回调不在主线程，
        // 先回主线程；旧回包凭 seq 丢弃，丢弃时仍结束刷新指示）。
        let handleResult: (Result<EntryList, APIError>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 旧回包直接丢弃（见 timelineFirstPageSeq 注释）：表与模型均已由新加载接管。
                // 卡死路径修法：丢弃时仍结束刷新指示（只跳过模型更新），不让
                // “旧请求被取代”等于“刷新头永不结束”；后续新加载的完成分支
                // 因旗标已清而 no-op，不会二次复位。
                // 112：在途标记归新请求所有，丢弃分支不动标记（新请求完成时清）；
                // 暂存的 completion 同样归新请求完成时补调，此处不补调。
                guard seq == strongSelf.timelineFirstPageSeq else {
                    strongSelf.refreshIconView.stopSpinning()
                    strongSelf.endCustomPullRefresh()
                    return
                }
                strongSelf.timelineFirstPageInFlight = false
                // 开发者模式强制态（仅内存）：真实回包（成功或失败）一律不接受，按强制态渲染。
                if BearyDevPreviewState.forcedTimeline != .none {
                    strongSelf.applyDevForcedTimeline()
                    strongSelf.finishTimelineFirstPage(diffEligible: false, oldSections: oldSections, hadOldRows: hadOldRows, completion: completion)
                    return
                }
                switch result {
                case .success(let list):
                    strongSelf.timelineEntries = list.entries ?? []
                    // B-G7: patch the day-panel copy from the fresh timeline copy
                    // before diff/reload, so both copies render the same state.
                    strongSelf.dayEntries = strongSelf.patchedEntries(strongSelf.dayEntries, withFresh: strongSelf.timelineEntries)
                    strongSelf.trashCountValue = list.trashCount ?? 0
                    strongSelf.trashCountKnown = true
                    strongSelf.countsValue = list.tlCounts
                    strongSelf.timelineHasMore = (list.entries ?? []).count >= strongSelf.firstPageLimit
                    // 110：首屏成功即写时间线缓存（下次冷启动缓存优先；
                    // 只在已登录时写，避免游客态写 guest 桶；失败不写）。
                    if let uid = SessionManager.shared.currentUser?.id {
                        BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: strongSelf.timelineEntries, hasMore: strongSelf.timelineHasMore, trashCount: strongSelf.trashCountValue, counts: strongSelf.countsValue)
                    }
                    // 开发者模式 1000 篇假日记（仅内存）：快照已存真实首屏，
                    // 此处再替换内存模型、停分页；当日面板随假模型派生（不写日缓存，见 derive 内守卫）。
                    if BearyDevPreviewState.fakeEntriesEnabled {
                        strongSelf.timelineEntries = BearyDeveloperMode.shared.makeFakeEntries(count: 1000)
                        strongSelf.timelineHasMore = false
                        if let key = strongSelf.selectedDayKey {
                            strongSelf.deriveDayPanelFromFirstPageIfCovered(key: key)
                        }
                    }
                    strongSelf.lastTimelineFirstPageSuccessAt = Date()
                    // 112：keepDay 刷新的增量当日面板——首屏已覆盖选中日时
                    // 直接派生，不再另发当日请求；未覆盖或失败时回落正向拉取。
                    if let deferredKey = strongSelf.deferredDayKeyForFirstPage {
                        strongSelf.deferredDayKeyForFirstPage = nil
                        strongSelf.deriveDayPanelFromFirstPageIfCovered(key: deferredKey)
                    }
                    strongSelf.timelineState = .loaded
                    strongSelf.timelinePageFailed = false
                    strongSelf.updateTrashTitle()
                    strongSelf.updateCountsLabel()
                    // 同上：计数写入后重算表头高度，防统计行被压缩裁剪。
                    strongSelf.refreshHeaderHeight()
                case .failure(let error):
                    strongSelf.timelineState = .failed
                    // 已有内容时首拉失败不 toast、不清列表，改由列表顶的原位失败条提示
                    //（私信会话列表／广场同款）；空表仍走 updateChrome 的居中失败态。
                    if hadOldRows {
                        strongSelf.setRefreshFailedBannerVisible(true)
                    }
                    if case .unauthorized = error {
                        strongSelf.timelineUnauthorized = true
                    }
                    // 112：首屏失败时暂存的当日面板仍需刷新——回落正向拉取，
                    // 面板失败态与旧口径一致（面板不被首屏失败拖空）。
                    // 选区已切走时不回落（新日的正向拉取自有面板归属）。
                    if let deferredKey = strongSelf.deferredDayKeyForFirstPage {
                        strongSelf.deferredDayKeyForFirstPage = nil
                        if strongSelf.selectedDayKey == deferredKey {
                            strongSelf.fetchDayEntries(key: deferredKey, clear: false)
                        }
                    }
                }
                let diffEligible: Bool
                if case .success = result { diffEligible = true } else { diffEligible = false }
                strongSelf.finishTimelineFirstPage(
                    diffEligible: diffEligible, oldSections: oldSections,
                    hadOldRows: hadOldRows, completion: completion
                )
            }
        }
        // A4：接手在途预取——同账号的首屏请求已在途时
        // 不再另发一份，复用同一份回包走同一套首拉渲染；seq 与在途标记
        // 归本函数所有，预取回包到时按首拉口径渲染并清标记。
        if let uid = SessionManager.shared.currentUser?.id,
           BearyTimelinePrefetch.adoptFirstPageIfInFlight(userId: uid, vis: nil, completion: handleResult) {
            return
        }
        BearyAPI.shared.fetchTimelineFirstPage(completion: handleResult)
    }

    /// 113：首屏收尾（原 loadTimelineFirstPage 的尾巴，全量与 since 共用）——
    /// diff 成功即插删改、否则整表重载；结束下拉头/菊花；补调 completion
    /// 与在途暂存的 completion。
    private func finishTimelineFirstPage(diffEligible: Bool, oldSections: [DaySection], hadOldRows: Bool, completion: (() -> Void)?) {
        if diffEligible, hadOldRows, tableView.window != nil,
           applyFirstPageDiff(oldSections: oldSections) {
            // diff 已插删改，跳过整表重载。
        } else {
            tableView.reloadData()
            if didShowTimelineSkeleton && hasShownTimelineRows {
                // 加载三件套·骨架淡出后内容入场：首屏行从上到下每块错开 60ms、
                // 依次淡入并上移 8px（骨架背景视图由 updateChrome 0.26s 淡出）。
                tableView.layoutIfNeeded()
                let cells = (tableView.indexPathsForVisibleRows ?? []).sorted().compactMap { tableView.cellForRow(at: $0) }
                BearyLoadingUX.staggerIn(cells: cells, delayStep: 0.06, yOffset: 8)
            }
        }
        // 首屏已落表：之后重载恢复 60ms/8px 入场错峰；本次是否错峰
        // 由上面分支在置位前判定，故首进直接落位、之后仍错峰。
        if !timelineEntries.isEmpty || !dayEntries.isEmpty {
            hasShownTimelineRows = true
        }
        updateChrome()
        if isCustomPullRefreshing {
            // 自定义下拉回包到即收回（第 2 项后无 0.5 秒最低展示，消息页同款已同步去掉）。
            self.endCustomPullRefresh()
        } else {
            refreshIconView.stopSpinning()
        }
        completion?()
        // 112：在途跳过时暂存的 completion 在此补调（匹配完成才调；
        // 失败同样补调——调用方按失败快照处理，不静默吞掉）。
        let pendingFirstPageCompletions = timelineFirstPagePendingCompletions
        timelineFirstPagePendingCompletions.removeAll()
        for pendingCompletion in pendingFirstPageCompletions {
            pendingCompletion()
        }
        // 刷新跑完后栏回到可见（下拉刷新/首拉均经此收口）。
        restoreChromeAfterTimelineAction()
    }

    /// 113 since 增量刷新：只拉比首条新的时间线条目，前插合并，不动
    /// hasMore、不重置滚动位置（diff 插行在顶部，旧行下推不跳顶）。
    /// 失败或无新条目时同一 seq/在途标记内回落全量；计数只在回包带值时
    /// 更新（since 回包不含 recent_published，计数仍在）。
    private func loadTimelineSince(seq: Int, oldSections: [DaySection], hadOldRows: Bool, cursor: Int, headId: String, completion: (() -> Void)? = nil) {
        let knownIds = Set(timelineEntries.compactMap { $0.id })
        BearyAPI.shared.fetchEntriesSince(
            scope: .timeline, since: cursor, sinceId: headId,
            sortKey: { $0.createdAt }, knownIds: knownIds,
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 旧回包直接丢弃（全量同款）：只结束刷新指示，不动模型。
                guard seq == strongSelf.timelineFirstPageSeq else {
                    strongSelf.refreshIconView.stopSpinning()
                    strongSelf.endCustomPullRefresh()
                    return
                }
                // 开发者模式强制态（仅内存）：在途增量回包不接受，按强制态渲染。
                if BearyDevPreviewState.forcedTimeline != .none {
                    strongSelf.timelineFirstPageInFlight = false
                    strongSelf.applyDevForcedTimeline()
                    strongSelf.finishTimelineFirstPage(diffEligible: false, oldSections: oldSections, hadOldRows: hadOldRows, completion: completion)
                    return
                }
                switch result {
                case .failure:
                    strongSelf.fetchTimelineFirstPageFull(
                        seq: seq, oldSections: oldSections, hadOldRows: hadOldRows, completion: completion
                    )
                case .success(let result):
                    // 补拉带缺口：不谎报成功，走失败同款回落全量首拉。
                    if result.hasGap {
                        strongSelf.fetchTimelineFirstPageFull(
                            seq: seq, oldSections: oldSections, hadOldRows: hadOldRows, completion: completion
                        )
                        return
                    }
                    let fresh = result.entries
                    let firstList = result.firstList
                    // 开发者模式 1000 篇假日记：增量前插不混入假模型，走全量由注入点统一处理。
                    if BearyDevPreviewState.fakeEntriesEnabled {
                        strongSelf.fetchTimelineFirstPageFull(
                            seq: seq, oldSections: oldSections, hadOldRows: hadOldRows, completion: completion
                        )
                        return
                    }
                    let newItems = fresh.filter { entry in
                        guard let entryId = entry.id else { return false }
                        return !knownIds.contains(entryId)
                    }
                    if newItems.isEmpty {
                        // 无新条目：仍走全量 diff 口径对齐一次互动态等字段，
                        // 模型与表结构不变（diff 无变化即不动表），故不闪、不丢。
                        strongSelf.fetchTimelineFirstPageFull(
                            seq: seq, oldSections: oldSections, hadOldRows: hadOldRows, completion: completion
                        )
                        return
                    }
                    strongSelf.timelineFirstPageInFlight = false
                    strongSelf.timelineEntries = newItems + strongSelf.timelineEntries
                    // B-G7 同款：先 patch 当日面板的旧行互动态，再前插选中日新篇。
                    strongSelf.dayEntries = strongSelf.patchedEntries(strongSelf.dayEntries, withFresh: strongSelf.timelineEntries)
                    if let selectedKey = strongSelf.selectedDayKey, strongSelf.dayEntriesKey == selectedKey {
                        let dayNew = newItems.filter { entry in
                            guard let created = entry.createdAt else { return false }
                            return BearyBeijingDay.dayKey(ofMs: created, tzName: entry.tzName) == selectedKey
                        }
                        if !dayNew.isEmpty {
                            let dayKnown = Set(strongSelf.dayEntries.compactMap { $0.id })
                            let dayFresh = dayNew.filter { entry in
                                guard let entryId = entry.id else { return false }
                                return !dayKnown.contains(entryId)
                            }
                            if !dayFresh.isEmpty {
                                strongSelf.dayEntries = dayFresh + strongSelf.dayEntries
                                if let cachedDay = strongSelf.dayEntriesCache[selectedKey] {
                                    strongSelf.cacheDayEntries(key: selectedKey, entries: dayFresh + cachedDay)
                                }
                            }
                        }
                    }
                    if let trashCount = firstList.trashCount {
                        strongSelf.trashCountValue = trashCount
                        strongSelf.trashCountKnown = true
                    }
                    if let counts = firstList.tlCounts { strongSelf.countsValue = counts }
                    // hasMore 不动：since 只补头部，旧页分页游标不受影响。
                    if let uid = SessionManager.shared.currentUser?.id {
                        BearyTimelineCache.save(bucket: BearyFeedCache.bucket(userId: uid), entries: strongSelf.timelineEntries, hasMore: strongSelf.timelineHasMore, trashCount: strongSelf.trashCountValue, counts: strongSelf.countsValue)
                    }
                    strongSelf.lastTimelineFirstPageSuccessAt = Date()
                    // 112 keepDay 同款：首屏已覆盖选中日时直接派生当日面板。
                    if let deferredKey = strongSelf.deferredDayKeyForFirstPage {
                        strongSelf.deferredDayKeyForFirstPage = nil
                        strongSelf.deriveDayPanelFromFirstPageIfCovered(key: deferredKey)
                    }
                    strongSelf.timelineState = .loaded
                    strongSelf.timelinePageFailed = false
                    strongSelf.updateTrashTitle()
                    strongSelf.updateCountsLabel()
                    strongSelf.refreshHeaderHeight()
                    strongSelf.finishTimelineFirstPage(
                        diffEligible: true, oldSections: oldSections,
                        hadOldRows: hadOldRows, completion: completion
                    )
                }
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
            // 审计 r16 第 10 项：首屏 diff 新增行按首屏档入场（60ms／8pt）。
            staggerInsertFirstLoad = true
            staggerQueueGeneration = staggerGeneration
        }
        tableView.performBatchUpdates({
            if !deletes.isEmpty { self.tableView.deleteRows(at: deletes, with: .fade) }
            if !inserts.isEmpty { self.tableView.insertRows(at: inserts, with: staggerFirstPage ? .none : .fade) }
            if !reloads.isEmpty { self.tableView.reloadRows(at: reloads, with: .fade) }
        }, completion: nil)
        return true
    }

    /// 行内容签名：用于 diff 判定“变化行”。须覆盖行实际绘制的全部字段，
    /// 审计 5：此前只含正文/公开态/互动/定位——只改图片/尺寸/天气/气温/
    /// 心情/标题/引用/作者时会被判“无变化”而跳过重载，行恒显旧值。
    /// 变化行的更新仍走既有批更新（delete/insert/reloadRows）：未变化
    /// 的行不动表、不整表 reloadData，滚动位置不受影响；本函数只修
    /// “判不判得出变化”这一环，不另起更新机制。
    // 审计-时间线：签名计入 visibility（仅好友与私密的 isPublic 同为 false，缺它则切换后 diff 判无变化）；ephemeralUntil 本已计入，此处并列确认。
    private func entrySignature(_ entry: Entry) -> String {
        var emoteParts: [String] = []
        for emote in entry.emotes ?? [] {
            emoteParts.append("\(emote.emote ?? ""):\(emote.count ?? 0):\(emote.mine ?? false)")
        }
        let images = (entry.images ?? []).joined(separator: ",")
        // 审计第 8 轮补正（时间线同款）：标签参与卡片绘制（BearyDiaryCardCell 按 entry.tags 出标签行），仅标签变化时签名必须变化，否则 applyFirstPageDiff / dayUnchanged / timelinePatchChanged 均判无变化、卡片恒显旧标签。顺序即服务端顺序，换序亦判为变化（与个人页 #1955 同口径）。
        let tagsPart = (entry.tags ?? []).joined(separator: ",")
        let dims = (entry.imgDims ?? [:]).map { "\($0.key):\($0.value.map(String.init).joined(separator: "x"))" }.sorted().joined(separator: ",")
        let live = (entry.liveVideos ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        let quote = entry.quote
        // 引用签名须覆盖全部参与引用卡绘制的字段：只比 id/正文/删除/锁定/
        // 公开时，引用只换图片、作者信息或可见性会被 dayUnchanged 误判为没变
        // （与详情页、个人页回填的签名覆盖口径一致；imgDims 现阶段服务端
        // 恒为 nil，仍先行纳入，透传后直接生效）。
        let quoteImages = (quote?.images ?? []).joined(separator: ",")
        let quoteDims = (quote?.imgDims ?? [:]).map { "\($0.key):\($0.value.map(String.init).joined(separator: "x"))" }.sorted().joined(separator: ",")
        let quotePart = "\(entry.quoteId ?? "")|\(quote?.id ?? "")|\(quote?.content ?? "")|\(quote?.gone ?? false)|\(quote?.locked ?? false)|\(quote?.isPublic ?? false)|\(quoteImages)|\(quoteDims)|\(quote?.authorName ?? "")|\(quote?.authorAvatar ?? "")|\(quote?.authorHandle ?? "")|\(quote?.visibility ?? "")|\(quote?.publishedAt ?? 0)|\(quote?.ephemeralUntil ?? 0)"
        return "\(entry.content ?? "")|\(entry.isPublic ?? false)|\(entry.visibility ?? "")|\(entry.likeCount ?? 0)|\(entry.likedByMe ?? false)|\(entry.bookmarkedByMe ?? false)|\(entry.bookmarkCount ?? 0)|\(emoteParts.joined(separator: ","))|\(entry.locationName ?? "")|\(entry.locationDistrict ?? "")|\(images)|\(tagsPart)|\(dims)|\(live)|\(entry.weather ?? "")|\(entry.temperatureC.map(String.init) ?? "")|\(entry.mood ?? "")|\(entry.title ?? "")|\(quotePart)|\(entry.authorName ?? "")|\(entry.authorAvatar ?? "")|\(entry.authorPlus ?? 0)|\(entry.mentionedName ?? "")|\(entry.createdAt ?? 0)|\(entry.publishedAt ?? 0)|\(entry.ephemeralUntil ?? 0)"
    }

    private func loadTimelineNextPage(manual: Bool = false) {
        if timelineLoadingMore || !timelineHasMore { return }
        // 审计 r16 第 17 项：失败退避窗口内不发新请求（自动触发与手动重试同拦，
        // 防低速网络下滑动中连续触发分页；窗口到时自动恢复）。
        if let notBefore = timelinePageRetryNotBefore, ProcessInfo.processInfo.systemUptime < notBefore {
            // 手动点按被拦时给一句提示；自动触发被拦时静默，不刷 toast。
            if manual { showTimelineToast(message: NSLocalizedString("common.network_seems_slow", comment: "")) }
            return
        }
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
                    // 审计 r16 第 17 项：分页成功即清退避计数与窗口。
                    strongSelf.timelinePageFailureCount = 0
                    strongSelf.timelinePageRetryNotBefore = nil
                    if let diff = strongSelf.appendedPageDiff(oldSections: oldSections),
                       strongSelf.tableView.window != nil {
                        // 减动效时不排错峰队列，直接插行终值。
                        if UIAccessibility.isReduceMotionEnabled == false {
                            strongSelf.staggerInsertOrder = Dictionary(uniqueKeysWithValues: diff.stagger.enumerated().map { ($0.element, $0.offset) })
                            // 审计 r16 第 10 项：分页追加行按分页档入场（50ms／24pt）。
                            strongSelf.staggerInsertFirstLoad = false
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
                    // 审计 r16 第 17 项：指数退避 2s 起、翻倍、上限 30s。
                    strongSelf.timelinePageFailureCount += 1
                    let backoff = min(2.0 * pow(2.0, Double(strongSelf.timelinePageFailureCount - 1)), 30.0)
                    strongSelf.timelinePageRetryNotBefore = ProcessInfo.processInfo.systemUptime + backoff
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
        // r17-C1：进页先恢复落盘圆点、再刷新当前月——内存未命中且未尝试过
        // 恢复的月份先走落盘（恢复体里按需强制刷新，见 restoreCalendarSnapshots）。
        restoreCalendarSnapshots(keys: keys)
        for key in keys {
            fetchCalendarMonth(key: key)
        }
        renderCalendar()
    }

    private func monthKeysForCurrentView() -> [String] {
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return [] }
            guard let weekStart = BearyBeijingDay.weekStartOf(year: anchor.year, month: anchor.month, day: anchor.day) else { return [] }
            var keys: [String] = []
            for offset in 0..<7 {
                guard let day = BearyBeijingDay.shifted(year: weekStart.year, month: weekStart.month, day: weekStart.day, byDays: offset) else { continue }
                let key = BearyBeijingDay.monthKey(year: day.year, month: day.month)
                if !keys.contains(key) { keys.append(key) }
            }
            return keys
        case .month:
            guard let displayed = calendarDisplayedMonth else { return [] }
            return [BearyBeijingDay.monthKey(year: displayed.year, month: displayed.month)]
        }
    }

    /// r17-C1 月历落盘恢复：对未命中内存且未尝试过的月份读落盘（见
    /// BearyCalendarSnapshotStore）。恢复只填内存空缺——网络已先到时不覆盖；
    /// 恢复当月（savedDayKey == 今天）原样用服务端响应；跨日恢复只用日计数
    /// 与月总数，streak 丢掉待刷新确认（服务端 streak 按当天算，本地不重算）。
    /// 恢复后立即强制刷新该月（SWR：先画上次的圆点，再用网络确认），刷新
    /// 在途时 fetchCalendarMonth 的 calendarFetching 守卫会挡下重复请求。
    /// 账号/会话代次校验在 store 的回包处做（见 load 的 completion 守卫），
    /// 这里再验一次 uid 与代次——恢复期间切号则丢弃，不把旧号圆点画到新号页上。
    private func restoreCalendarSnapshots(keys: [String]) {
        guard let uid = SessionManager.shared.currentUser?.id else { return }
        let generation = SessionManager.shared.currentSessionGeneration
        for key in keys {
            guard calendarCache[key] == nil, !calendarSnapshotRestoreTried.contains(key) else { continue }
            calendarSnapshotRestoreTried.insert(key)
            BearyCalendarSnapshotStore.load(accountId: uid, monthKey: key, sessionGeneration: generation) { [weak self] snapshot in
                guard let self = self else { return }
                guard let snapshot = snapshot else { return }
                guard SessionManager.shared.currentUser?.id == uid,
                      SessionManager.shared.currentSessionGeneration == generation else { return }
                guard self.calendarCache[key] == nil else { return }
                let todayKey = BearyBeijingDay.todayComponents().map { BearyBeijingDay.dayKey(year: $0.year, month: $0.month, day: $0.day) }
                var response = snapshot.response
                if snapshot.savedDayKey != todayKey {
                    // 跨日：streak 未重新确认，丢掉（统计行只报本月篇数）；
                    // 日计数与月总数是历史事实，保留。
                    response.streak = nil
                    self.calendarStreakUnknownKeys.insert(key)
                }
                self.calendarCache[key] = response
                self.renderCalendar()
                self.updateStatsLine()
                // 恢复即强制刷新确认（失败则留旧圆点 + 卡内失败行写上次的数据）。
                self.fetchCalendarMonth(key: key, force: true)
            }
        }
    }

    private func fetchCalendarMonth(key: String, force: Bool = false) {
        if !force && calendarCache[key] != nil { return }
        if calendarFetching.contains(key) { return }
        calendarFetching.insert(key)
        let requestUid = SessionManager.shared.currentUser?.id
        BearyAPI.shared.fetchCalendar(month: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.calendarFetching.remove(key)
                // r17-C1：回包时账号已变（切号/登出）即丢弃——旧号月历不得写进
                // 新号内存缓存，更不得落进新号的盘（落盘按 uid 分桶，见成功分支）。
                guard SessionManager.shared.currentUser?.id == requestUid else { return }
                switch result {
                case .success(let data):
                    strongSelf.calendarCache[key] = data
                    strongSelf.calendarFailed.remove(key)
                    // r17-C1：成功即落盘（原样存服务端响应，streak 不重算）；
                    // 刷新到达后该月不再是「上次的数据」，streak 未知态一并摘掉。
                    strongSelf.calendarStreakUnknownKeys.remove(key)
                    if let uid = requestUid {
                        BearyCalendarSnapshotStore.save(accountId: uid, monthKey: key, response: data)
                    }
                case .failure(let error):
                    strongSelf.calendarFailed.insert(key)
                    // 翻页失败清挂起：残留 pendingStepFollow 不得在之后某次
                    // 月份到达时把用户新点选的日子意外移走（网页失败恢复原选区
                    // 同口径；App 选区在跟随落定前本就未动，故只清挂起、不动选区）。
                    strongSelf.pendingStepFollow = false
                }
                strongSelf.updateStatsLine()
                // 审计-时间线：月份回包只重建该月网格——到达月不在当前视图内时不重渲日历、不重算表头高度（统计行自身有签名守卫，不受影响）。
                if strongSelf.monthKeysForCurrentView().contains(key) {
                    strongSelf.renderCalendar()
                    strongSelf.refreshHeaderHeight()
                }
                // 第 3/4 项：月份到达后先解翻页跟随（若仍挂起则跳过守卫，
                // 避免守卫动选区），跟随落定后再跑 calFixSel 守卫。
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

    private func calendarDayCounts(year: Int, month: Int, day: Int) -> (published: Int, unpublished: Int, friends: Int, limited: Int, loaded: Bool) {
        let key = BearyBeijingDay.monthKey(year: year, month: month)
        guard let data = calendarCache[key] else { return (0, 0, 0, 0, false) }
        let info = data.days?["\(day)"]
        // 服务端 pub 仍含限时、priv 仍含仅好友（网页旧口径不动），App 侧做减法：
        // 橙（公开）= pub - limited、蓝（私密）= priv - friends；墨、紫各取新键；
        // 旧快照缺新键时 nil→0，减法结果钳在 ≥0（防服务端口径漂移出负数）。
        let limited = info?.limited ?? 0
        let friends = info?.friends ?? 0
        let published = max((info?.pub ?? 0) - limited, 0)
        let unpublished = max((info?.priv ?? 0) - friends, 0)
        return (published, unpublished, friends, limited, true)
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
        if let today = BearyBeijingDay.todayComponents(timeZone: .current) {
            isToday = (today.year == year && today.month == month && today.day == day)
        }
        let key = BearyBeijingDay.dayKey(year: year, month: month, day: day)
        let monthKey = BearyBeijingDay.monthKey(year: year, month: month)
        let monthFailed = calendarFailed.contains(monthKey) && calendarCache[monthKey] == nil
        return BearyCalendarDay(
            year: year, month: month, day: day,
            isOffMonth: isOffMonth, isFuture: isFuture, isToday: isToday,
            isSelected: (selectedDayKey == key),
            published: counts.published, unpublished: counts.unpublished,
            friends: counts.friends, limited: counts.limited,
            dataLoaded: counts.loaded, dataFailed: monthFailed
        )
    }

    private func renderCalendar() {
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return }
            guard let weekStart = BearyBeijingDay.weekStartOf(year: anchor.year, month: anchor.month, day: anchor.day) else { return }
            var days: [BearyCalendarDay] = []
            for offset in 0..<7 {
                guard let day = BearyBeijingDay.shifted(year: weekStart.year, month: weekStart.month, day: weekStart.day, byDays: offset) else { continue }
                days.append(makeCalendarDay(year: day.year, month: day.month, day: day.day, isOffMonth: false))
            }
            guard days.first != nil else { return }
            // v14 改版：周/月同一块日历，标题只写年月（周模式用锚点所在年月，
            // 不再写“x月x日 – x月x日”周范围标题）；年月数字是两个分开的把手。
            calendarCard.setYearMonth(year: anchor.year, month: anchor.month)
            calendarCard.render(days: days, mode: .week)
        case .month:
            guard let displayed = calendarDisplayedMonth else { return }
            guard let dim = BearyBeijingDay.daysInMonth(year: displayed.year, month: displayed.month) else { return }
            guard let firstDate = BearyBeijingDay.date(year: displayed.year, month: displayed.month, day: 1) else { return }
            let firstWeekday = BearyBeijingDay.calendar.component(.weekday, from: firstDate)
            // 月视图前导空格按 locale 首日算（周一基 (firstWeekday + 5) % 7 已废）。
            let leading = (firstWeekday - BearyBeijingDay.localeFirstWeekday + 7) % 7
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
            // v14 改版：标题只写年月（周/月同一块日历）。
            calendarCard.setYearMonth(year: displayed.year, month: displayed.month)
            calendarCard.render(days: days, mode: .month, weekKeys: currentWeekKeys())
        }
        updateStatsLine()
        updateCalendarTodayButton()
    }

    private func isCurrentWeek(weekStart: (year: Int, month: Int, day: Int)) -> Bool {
        guard let today = BearyBeijingDay.todayComponents() else { return false }
        guard let currentWeekStart = BearyBeijingDay.weekStartOf(year: today.year, month: today.month, day: today.day) else { return false }
        return currentWeekStart.year == weekStart.year && currentWeekStart.month == weekStart.month && currentWeekStart.day == weekStart.day
    }

    private func isCurrentMonth(displayed: (year: Int, month: Int)) -> Bool {
        guard let today = BearyBeijingDay.todayComponents(timeZone: .current) else { return false }
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
            } else if let displayed = calendarDisplayedMonth, let today = BearyBeijingDay.todayComponents(timeZone: .current), today.year == displayed.year && today.month == displayed.month {
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
            guard let weekStart = BearyBeijingDay.weekStartOf(year: anchor.year, month: anchor.month, day: anchor.day) else { pendingStepFollow = false; return true }
            var weekDays: [(year: Int, month: Int, day: Int)] = []
            for offset in 0..<7 {
                guard let day = BearyBeijingDay.shifted(year: weekStart.year, month: weekStart.month, day: weekStart.day, byDays: offset) else { continue }
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
            if counts.published + counts.unpublished + counts.friends + counts.limited > 0 {
                pendingStepFollow = false
                selectDay(key: BearyBeijingDay.dayKey(year: day.year, month: day.month, day: day.day))
                return true
            }
        }
        pendingStepFollow = false
        return true
    }

    /// 第 4 项 calFixSel 通用守卫：选中日当月计数为 null（days 缺该日）
    /// 或 0 时不再触发跳转/取消（2026-11-04 不跳日口径：只清挂起、返回 false，
    /// 调用方走正常重载，面板显示该天空态）；计数 > 0 时不触发并清挂起。
    /// 月份缓存缺失时挂起并补拉，到达后由 fetchCalendarMonth 回包重试。
    /// 返回值现恒为 false（历史跳转/取消语义已随不跳日口径删除）。
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
        // 2026-11-04 不跳日口径：空日不跳转、不清选区，只清挂起、返回 false。
        pendingFixSelCheck = false
        return false
    }

    /// 第 2 项 A 初次进入 / 下拉刷新守卫（checkFixSel 的同月口径、
    /// 但走独立挂起标志 pendingEntryJumpCheck，不碰 pendingFixSelCheck）：
    /// 2026-11-04 不跳日口径：选中日当月计数 0 时不再跳转/取消，只清挂起、
    /// 返回 false（调用方走正常重载，面板显示该天空态）；计数 > 0 不动。
    /// 缓存缺失时挂起并补拉该月，到达后由 fetchCalendarMonth 回包的本守卫
    /// 分支重试；月份已失败时清挂起、保留选区（与 checkFixSel 同口径，
    /// 防失败回包 → 守卫 → 再补拉死循环）。返回值现恒为 false。
    /// 翻页路径永不调用本函数（翻页全空保留原选区）。
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
        // 2026-11-04 不跳日口径：空日不跳转、不清选区，只清挂起、返回 false。
        pendingEntryJumpCheck = false
        return false
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
                guard let weekStart = BearyBeijingDay.weekStartOf(year: base.year, month: base.month, day: base.day) else { return }
                if isCurrentWeek(weekStart: weekStart) { return }
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

    /// 年月把手步进（v14 改版）：长按年份数字拖动／方向键只换年，
    /// 月份和号数不动（选中日与锚点只改年份）。
    private func stepCalendarYear(delta: Int) {
        guard delta != 0 else { return }
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return }
            let targetYear = anchor.year + delta
            let dim = BearyBeijingDay.daysInMonth(year: targetYear, month: anchor.month) ?? 28
            calendarAnchor = (year: targetYear, month: anchor.month, day: min(anchor.day, dim))
        case .month:
            guard let displayed = calendarDisplayedMonth else { return }
            calendarDisplayedMonth = (year: displayed.year + delta, month: displayed.month)
        }
        fetchCalendarMonthsForCurrentView()
        refreshHeaderHeight()
    }

    /// 年月把手步进（v14 改版）：长按月份数字拖动／方向键只换月，
    /// 拖过 12 月自动跨年（shiftedMonth 处理）；选中日保留号数，
    /// 超月长时截断到月末（同月模式翻页口径）。
    private func stepCalendarMonth(delta: Int) {
        guard delta != 0 else { return }
        switch calendarMode {
        case .week:
            guard let anchor = calendarAnchor else { return }
            guard let moved = BearyBeijingDay.shiftedMonth(year: anchor.year, month: anchor.month, byMonths: delta) else { return }
            let dim = BearyBeijingDay.daysInMonth(year: moved.year, month: moved.month) ?? 28
            calendarAnchor = (year: moved.year, month: moved.month, day: min(anchor.day, dim))
        case .month:
            guard let displayed = calendarDisplayedMonth else { return }
            guard let moved = BearyBeijingDay.shiftedMonth(year: displayed.year, month: displayed.month, byMonths: delta) else { return }
            calendarDisplayedMonth = moved
        }
        fetchCalendarMonthsForCurrentView()
        refreshHeaderHeight()
    }

    /// C10 “今”钮显隐：显示月份/周不含今天，或选中日不是今天时浮现；
    /// 回到今天后 renderCalendar 重算即隐藏。只读 anchor/displayed/
    /// selected，不改任何已有状态；renderCalendar 是唯一漏斗（翻页、
    /// 切换视图、月份回包、点选日全经此），故挂在末尾即全覆盖。
    private func updateCalendarTodayButton() {
        guard let today = BearyBeijingDay.todayComponents(timeZone: .current) else {
            calendarCard.setTodayButtonVisible(false)
            return
        }
        let todayKey = BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day)
        let containsToday: Bool
        switch calendarMode {
        case .week:
            if let anchor = calendarAnchor,
               let weekStart = BearyBeijingDay.weekStartOf(year: anchor.year, month: anchor.month, day: anchor.day) {
                containsToday = isCurrentWeek(weekStart: weekStart)
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
    /// 钮不重播错峰、新格子走既有 0.26s / 0.03 步进错峰，不另加转场动画（翻页
    /// 64 包反馈修已定“只外科更新网格、不整卡转场”）。
    /// 手动点“今”作废翻页跟随挂起（与手动点选日作废定位挂起同口径），
    /// 防在途月份回包把选区跟回旧视图；reload 守卫挂起不动，与点选
    /// 当日格子同语义（见未决风险）。
    private func goToToday() {
        guard let today = BearyBeijingDay.todayComponents(timeZone: .current) else { return }
        pendingStepFollow = false
        calendarAnchor = (year: today.year, month: today.month, day: today.day)
        calendarDisplayedMonth = (year: today.year, month: today.month)
        selectDay(key: BearyBeijingDay.dayKey(year: today.year, month: today.month, day: today.day))
        fetchCalendarMonthsForCurrentView()
        restoreChromeAfterTimelineAction()
    }

    // MARK: - 当日面板（TL-7/TL-8）

    /// 审计四轮增量 06：缓存命中面板（内存命中与落盘回填后共用）——
    /// 整表重载仍保留：换日整表重载是 66 包闪退修法，缓存使重载直接渲染
    /// 出数据，不再有“空面板等网络”的白屏，时间线行因数据未变不闪
    /// （reloadData 本身不播入场动效；新面板行走 N3 错峰）。
    /// 后台静默刷新：不清面板、不闪，数据变了才对齐（见回包分支）。
    private func showCachedDayPanel(entries: [Entry], key: String, reduceMotion: Bool) {
        dayEntries = entries
        dayEntriesKey = key
        dayState = .loaded
        tableView.reloadData()
        updateChrome()
        refreshHeaderHeight()
        if reduceMotion == false {
            daySwitchStagger = Dictionary(uniqueKeysWithValues: entries.indices.map { (IndexPath(row: $0, section: 0), $0) })
            daySwitchGeneration = staggerGeneration
            daySwitchTitleFade = true
        }
        fetchDayEntries(key: key, clear: false)
    }

    /// 审计四轮增量 06：缓存未命中面板（与缓存命中分支对称抽出）——
    /// 切日闪退修：换日分支不再走 reloadSections——点按驱动的更新
    /// 上下文里分段数守卫也挡不住 UIKit Invalid Batch Updates，改整表重载。
    /// N3：换日回包到达时给新行错峰（见 fetchDayEntries 回包分支）。
    private func showNetworkDayPanel(key: String, reduceMotion: Bool) {
        tableView.reloadData()
        updateChrome()
        refreshHeaderHeight()
        if reduceMotion == false {
            daySwitchTitleFade = true
        }
        daySwitchArrivalKey = key
        fetchDayEntries(key: key, clear: true)
    }

    private func didSelectCalendarDay(_ day: BearyCalendarDay) {
        selectDay(key: day.key)
    }

    /// 热力图点某天 → 时间线跳到该日（公开入口，容器在切页之后调；视图已加载）。
    func openDay(key: String) {
        selectDay(key: key)
    }

    /// TL-8：点已选中日不取消筛选，只重渲 + 重拉当日；
    /// E4-5：同日在途拉取未完成时不重复发请求。
    private func selectDay(key: String) {
        // 80 包 A2-3③：切日先清错峰队列并 +1 代际，旧队列条目不得在新日数据行上重播。
        staggerGeneration += 1
        clearStaggerEntries()
        // R15 P2-7：点日期即准备数据——动画开始前同步发起后台磁盘预读
        // （内存命中 / 已在途 / 非全部档时内部直接返回），退场动画与取数
        // 并行，不再等 0.18s 退场完成才在提交里碰磁盘；减动效 / 无可见旧行 /
        // 无旧面板时直接提交的路径同样先预读，无等待。
        prepareDayEntriesInBackground(key: key)
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
            updateInlineComposerDay()
            return
        }
        let hadPanel = selectedDayKey != nil
        // 换日定向滑入：以新旧选中日比较定方向——新日更早往下翻、更晚往上翻；
        // 无旧面板（首次）或减动效时不滑，沿用旧错峰入场。方向存在本轮 selectDay
        // 的状态里，提交（缓存／落盘／网络）与回包到达分支共用；下一轮 selectDay
        // 开头经 clearStaggerEntries 清掉。
        daySwitchSlideDirection = {
            guard UIAccessibility.isReduceMotionEnabled == false,
                  hadPanel, let oldKey = selectedDayKey, key != oldKey else { return nil }
            return key < oldKey ? .earlier : .later
        }()
        selectedDayKey = key
        updateInlineComposerDay()
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
            // 缓存分两层：内存命中即时显示；点按时 prepareDayEntriesInBackground
            //（R15 P2-7）已在后台预读落盘，退场动画期间回填内存，提交时多半
            // 已命中；仍未命中时落盘读改异步（审计四轮增量 06 的 dayDiskReadQueue），
            // 回主线程复核通过才回填内存并按命中同款处理 + 静默刷新。
            // 提交处永不在主线程碰磁盘。
            if let cached = self.dayEntriesCache[key] {
                self.showCachedDayPanel(entries: cached, key: key, reduceMotion: reduceMotion)
            } else {
                // 审计四轮增量 06：内存未命中时落盘读改异步——Data(contentsOf:)
                // ＋JSON 解码不再占切日首帧。面板先不动（旧日行已退场淡出），
                // 读完回主线程复核代次/选中日/账号，通过才回填内存并按命中/
                // 未命中分流；期间用户又切日/清选区/切号（同样 +1 代际），
                // 过期结果直接丢弃，由新的 selectDay 流程接管。
                let requestAccountId = SessionManager.shared.currentUser?.id
                self.dayDiskReadQueue.async { [weak self] in
                    let disk: [Entry]? = {
                        guard let uid = requestAccountId else { return nil }
                        return BearyEntrySyncStore.loadDay(accountId: uid, dayKey: key)
                    }()
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self,
                              self.staggerGeneration == switchGeneration,
                              self.selectedDayKey == key,
                              SessionManager.shared.currentUser?.id == requestAccountId else { return }
                        if let disk = disk {
                            self.dayEntriesCache[key] = disk
                            self.showCachedDayPanel(entries: disk, key: key, reduceMotion: reduceMotion)
                        } else {
                            self.showNetworkDayPanel(key: key, reduceMotion: reduceMotion)
                        }
                    }
                }
            }
        }
        // N3：旧日卡片退场（仅非减动效、表已入窗、旧面板存在且有可见行时）：
        // 只动面板分区可见行（alpha 淡出 + 沿滑入方向滑出，transform/opacity，
        // 严禁逐帧改 height）；退场与滑入同向：更早的日子往下翻，旧行向上滑出；
        // 更晚的日子往上翻，旧行向下滑出。退场完成才提交新日，
        // 减动效 / 无可见旧行时直接提交、无动画。
        if reduceMotion == false, tableView.window != nil, hadPanel {
            let exitingCells = tableView.visibleCells.filter { cell in
                guard let path = tableView.indexPath(for: cell) else { return false }
                return path.section == 0
            }
            if exitingCells.isEmpty == false {
                let exitY: CGFloat = daySwitchSlideDirection == .later ? 8 : -8
                UIView.animate(withDuration: BearyMotion.micro, animations: {
                    for cell in exitingCells {
                        cell.alpha = 0
                        cell.transform = CGAffineTransform(translationX: 0, y: exitY)
                    }
                }, completion: { _ in commitDaySwitch() })
                return
            }
        }
        commitDaySwitch()
    }

    /// 6A gotoEntry 落点（自己篇）：按 createdAt 日切到当日面板并滚动高亮。
    /// 已在当日面板里时直接滚，不重拉；无 createdAt 时只在已加载分区里找。
    /// tzName：有则按篇时区定日（日记时区口径），缺省回落 Asia/Shanghai（旧调用方）。
    func locateEntry(entryId: String, createdAt: Int?, tzName: String? = nil) {
        guard let ms = createdAt, let dayKey = BearyBeijingDay.dayKey(ofMs: ms, tzName: tzName) else {
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

    /// 详情打开时记下该篇相对视口的位置（行顶相对可见区顶）；不在已加载分区里时返回 nil。
    func detailReturnAnchor(for entryId: String) -> CGFloat? {
        let sections = currentSections()
        for (sectionIndex, section) in sections.enumerated() {
            guard let row = section.entries.firstIndex(where: { $0.id == entryId }) else { continue }
            tableView.layoutIfNeeded()
            return tableView.rectForRow(at: IndexPath(row: row, section: sectionIndex)).origin.y - tableView.contentOffset.y
        }
        return nil
    }

    /// 详情展开过渡的源行：行可见时返回 cell（供动画器快照 morph），
    /// 行不在视野内时返回 nil（动画器走兜底，不碰滚动位置）。
    func detailSourceView(for entryId: String) -> UIView? {
        let sections = currentSections()
        for (sectionIndex, section) in sections.enumerated() {
            guard let row = section.entries.firstIndex(where: { $0.id == entryId }) else { continue }
            return tableView.cellForRow(at: IndexPath(row: row, section: sectionIndex))
        }
        return nil
    }

    /// 详情关闭时把该篇放回打开时的视口位置；已在原位（±1pt）或不在已加载分区里时不动。
    func restoreDetailReturnAnchor(entryId: String, viewportOffset: CGFloat) {
        let sections = currentSections()
        for (sectionIndex, section) in sections.enumerated() {
            guard let row = section.entries.firstIndex(where: { $0.id == entryId }) else { continue }
            tableView.layoutIfNeeded()
            BearyScrollAnchor.restoreDetailReturn(in: tableView, rowTop: tableView.rectForRow(at: IndexPath(row: row, section: sectionIndex)).origin.y, viewportOffset: viewportOffset)
            return
        }
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

    /// 112 增量当日面板：首屏已覆盖选中日时直接从首屏派生面板，
    /// 不再另发当日请求；未覆盖时回落正向 fetchDayEntries。
    /// 覆盖判定：首屏是 created DESC 前缀——页内一旦出现早于选中日的篇，
    /// 即证明选中日的全部篇都在页内（当日上限 10 篇/天；判定只看页内
    /// 是否出现早于选中日的篇，与页大小无关，未覆盖时回落正向拉取；
    /// 页空、页尾仍在选中日、或时间戳缺失时一律判未覆盖、走正向拉取）。
    /// 渲染不单独重载：调用点在首屏完成分支内，随后 diff/reloadData
    /// 统一覆盖面板分区（section 0），避免与首屏批更新交错。
    /// 跳转守卫与 fetchDayEntries 回包同口径：非空即清挂起；空且守卫
    /// 接管时不写面板（跳转路径自拉正确日），否则写派生面板。
    private func deriveDayPanelFromFirstPageIfCovered(key: String) {
        // 选区一致守卫：首屏在途期间用户已切到别的日时，旧选中日的
        // 面板绝不能写回（新日的正向拉取自有 dayKeyForLoad 归属守卫；
        // 无此守卫时派生会覆盖新日面板、失败回落还会抢走 dayKeyForLoad
        // 导致新日回包被丢弃）。
        guard selectedDayKey == key else { return }
        let covered = firstPageCoversDay(key: key)
        guard covered else {
            fetchDayEntries(key: key, clear: false)
            return
        }
        let derived = timelineEntries.filter { entry in
            guard let created = entry.createdAt else { return false }
            return BearyBeijingDay.dayKey(ofMs: created, tzName: entry.tzName) == key
        }
        if pendingEntryJumpCheck {
            pendingEntryJumpCheck = false
            if derived.isEmpty, checkEntryJumpForSelectedDay() {
                return
            }
        }
        dayEntries = derived
        dayEntriesKey = key
        dayState = .loaded
        // 筛子档派生不写日缓存：派生行已按 vis 过滤，写盘会污染全部档日缓存。
        // 开发者模式假日记同样不写盘（假数据只放内存）。
        if !BearyDevPreviewState.fakeEntriesEnabled {
            cacheDayEntries(key: key, entries: derived)
        }
        prefetchAdjacentDays(for: key)
    }

    /// 首屏是否已覆盖选中日：页内一旦出现早于选中日的篇，即证明选中日
    /// 的全部篇都在页内（判定口径见 deriveDayPanelFromFirstPageIfCovered
    /// 注释）。审计四轮第 8 项抽出共用：切档命中缓存时先判覆盖，再决定
    /// 立即派生面板还是先清面板等首屏回包。
    private func firstPageCoversDay(key: String) -> Bool {
        timelineEntries.contains { entry in
            guard let created = entry.createdAt, let dayKey = BearyBeijingDay.dayKey(ofMs: created, tzName: entry.tzName) else { return false }
            return dayKey < key
        }
    }

    private func fetchDayEntries(key: String, clear: Bool) {
        // 在途守卫：同一天的拉取还在飞，不再发第二份（只靠回包归属丢弃不够）。
        if dayKeyForLoad == key && dayState == .loading { return }
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
        // 按日请求序号：每次发出即 +1，回调先比序号——切回同日的旧回包
        // 即使日期、账号、筛子档全对上，也因序号过期而丢弃，不动面板与缓存。
        dayLoadSeq += 1
        let requestDaySeq = dayLoadSeq
        BearyAPI.shared.fetchTimelineDay(date: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                guard requestDaySeq == strongSelf.dayLoadSeq else { return }
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
                // R15 P1-2：更新前分区身份快照（dayKey 序列）——当日面板由空变
                // 非空时，普通列表里同日分区消失（currentSections :5770 continue），
                // 分区总数减 1、其后分区序号前移，分区身份与数量同时变化；
                // reloadSections(0) 只在快照一致时安全，否则回落整表重载。
                let sectionsBeforeUpdate = strongSelf.currentSections().map { $0.dayKey }
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
                    strongSelf.updateInlineComposerDay()
                    // 相邻日预取触发点：正向加载成功后才触发（失败不触发）；
                    // 预取只写日缓存，不动面板与时间线行（见 prefetchAdjacentDays）。
                    strongSelf.prefetchAdjacentDays(for: key)
                    // 第 4 项：删除后挂起的守卫在当日面板已空时也跑一次
                    // （以日历计数为准；守卫现不跳转，恒返回 false、走正常重载）。
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
                    strongSelf.updateInlineComposerDay()
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
                            && strongSelf.tableView.numberOfSections == strongSelf.currentSections().count
                            && strongSelf.currentSections().map({ $0.dayKey }) == sectionsBeforeUpdate {
                    // N3：换日回包到达——分区走 .none（不动效），入场错峰
                    // 全权交给 willDisplay（与首屏 insertRows .none 同口径，
                    // 避免 .automatic 淡入与错峰叠播）；分区数守卫仍在，
                    // 守卫失败回落整表重载并清错峰队列（防旧队列日后重播）。
                    strongSelf.daySwitchStagger = Dictionary(uniqueKeysWithValues: strongSelf.dayEntries.indices.map { (IndexPath(row: $0, section: 0), $0) })
                    strongSelf.daySwitchGeneration = strongSelf.staggerGeneration
                    strongSelf.tableView.reloadSections(IndexSet(integer: 0), with: .none)
                } else if clear == false && strongSelf.tableView.window != nil && strongSelf.selectedDayKey != nil
                            && strongSelf.tableView.numberOfSections == strongSelf.currentSections().count
                            && strongSelf.currentSections().map({ $0.dayKey }) == sectionsBeforeUpdate {
                    // R15 P1-2：此前本分支是唯一无守卫的 reloadSections——当日面板
                    // 空变非空时分区总数减 1、序号前移，直接 reloadSections(0) 即
                    // Invalid update。现与相邻分支同口径：分区数与分区身份
                    // （dayKey 序列）双双一致才分区重载，否则回落整表。
                    strongSelf.tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
                } else if strongSelf.tableView.window != nil && strongSelf.selectedDayKey != nil
                            && !timelinePatchChanged
                            && strongSelf.tableView.numberOfSections == strongSelf.currentSections().count
                            && strongSelf.currentSections().map({ $0.dayKey }) == sectionsBeforeUpdate {
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
            // 缓存版本快照：发出时记下该日版本，回调写缓存前比对——期间
            // 主动加载已写过该日时版本已变，旧预取直接拒写，不覆盖新缓存。
            let requestCacheVersion = dayCacheVersions[next] ?? 0
            BearyAPI.shared.fetchTimelineDay(date: next) { [weak self] result in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    strongSelf.dayPrefetchInFlight.remove(next)
                    if SessionManager.shared.currentUser?.id != requestUid { return }
                    switch result {
                    case .success(let list):
                        if strongSelf.dayKeyForLoad == next && strongSelf.dayState == .loading { return }
                        guard (strongSelf.dayCacheVersions[next] ?? 0) == requestCacheVersion else { return }
                        strongSelf.cacheDayEntries(key: next, entries: list.entries ?? [])
                    case .failure:
                        break
                    }
                }
            }
        }
    }

    /// 选中日是否落在日历当前显示的视图之外：月视图比显示月，周视图比
    /// 锚点所在周（首日至末日，首日跟 region 走）。日历状态未就绪时按在视图内算（短式不变）。
    private func isSelectedDayOutsideCalendarView(year: Int, month: Int, day: Int) -> Bool {
        switch calendarMode {
        case .month:
            guard let displayed = calendarDisplayedMonth else { return false }
            return displayed.year != year || displayed.month != month
        case .week:
            guard let anchor = calendarAnchor,
                  let weekStart = BearyBeijingDay.weekStartOf(year: anchor.year, month: anchor.month, day: anchor.day),
                  let weekStartNumber = BearyBeijingDay.dayNumber(year: weekStart.year, month: weekStart.month, day: weekStart.day),
                  let dayNumber = BearyBeijingDay.dayNumber(year: year, month: month, day: day) else { return false }
            return dayNumber < weekStartNumber || dayNumber > weekStartNumber + 6
        }
    }

    /// TL-7 当日面板表头（第 7 项两段式 + 第 15 项网页口径）：
    /// 日期一段（15pt 加粗墨色，如“10 月 25 日”，星期不在此段）；
    /// 星期·篇数·状态一段（12pt 灰色，如“周日 · 1 篇 · 都私密”，篇数带空格）。
    /// R15-L1：失败时日期段保留、后缀只写“ · 加载失败”，重试钮由组头在日期
    /// 旁另出（见 viewForHeaderInSection）；旧口径整段替换日期（B-G8 注释
    /// “日期段不保留”）已废止——失败文案本身不再兼重试入口。
    /// head/suffix 分段供表头富文本使用（日期加粗 15 + 后段灰色 12）；
    /// failed 供组头决定是否出日期旁重试钮。
    /// 日期去重：日期只在此处出现，不在表头重复。日历标题是“日历翻到了哪月／哪周”，此处是“下面正在看
    /// 哪天”——翻到无记录的月／周时选区保留原日（见 tryStepFollowSelection），
    /// 两处所指可能不同月；此时 head 带年份写全（“2026 年 11 月 18 日”），
    /// 让正在看的那天自带年月，与日历标题一眼分清；在当前日历视图内时仍
    /// 写短式（“11 月 18 日”），不加噪音。
    private func dayPanelTitleParts(key: String) -> (head: String, suffix: String, failed: Bool) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return (key, "", false) }
        var weekdayText = ""
        if let date = BearyBeijingDay.date(year: year, month: month, day: day) {
            let weekday = BearyBeijingDay.calendar.component(.weekday, from: date)
            let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            if weekday >= 1 && weekday <= names.count {
                weekdayText = names[weekday - 1]
            }
        }
        let head = isSelectedDayOutsideCalendarView(year: year, month: month, day: day)
            ? "\(year) 年 \(month) 月 \(day) 日"
            : "\(month) 月 \(day) 日"
        if dayState == .failed {
            return (head, " · 加载失败", true)
        }
        if dayState != .loaded {
            return (head, "", false)
        }
        var suffix = ""
        if weekdayText.isEmpty {
            suffix = " · \(dayEntries.count) 篇"
        } else {
            suffix = " · \(weekdayText) · \(dayEntries.count) 篇"
        }
        if !dayEntries.isEmpty {
            // 审计-时间线：后缀改用有效态——已过期限时篇不再算公开（旧口径标“都已公开”），
            // 仅好友篇不再算私密（旧口径标“都私密”）；全仅好友/混合时不贴状态后缀，不新编文案。
            let allPublic = dayEntries.allSatisfy { BearyEphemeral.isEffectivelyPublic($0) }
            let allPrivate = dayEntries.allSatisfy { !BearyEphemeral.isEffectivelyPublic($0) && !$0.isFriendsOnly }
            if allPublic {
                suffix += " · 都已公开"
            } else if allPrivate {
                suffix += " · 都私密"
            }
        }
        // 第三批体验检查第 1 项：该日有已发布但未落盘的待补拉篇——篇数是
        // 落盘前的旧数，不按“空日/已齐”显示，缀“同步中”表明还有篇在路上。
        if BearyEntrySync.shared.hasPendingRefetch(dayKey: key) {
            suffix += " · 同步中"
        }
        return (head, suffix, false)
    }

    private func dayPanelTitle(key: String) -> String {
        let parts = dayPanelTitleParts(key: key)
        return parts.head + parts.suffix
    }

    // MARK: - 列表分区与空态/脚部

    /// R15 P2-8：分区快照读取点——有缓存直接返回同一份 [DaySection]，
    /// 无缓存（输入刚变、快照已被 didSet 清掉）时重建一次并缓存。
    /// 数据、选中日期或当日状态改变时快照即失效，下一次读取即新快照；
    /// 同一窗口内的所有读取点（数据源、组头、高度、滑动操作、willDisplay、
    /// diff 新旧快照等）读的是同一份结果。
    private func currentSections() -> [DaySection] {
        if let cached = cachedSections { return cached }
        let built = buildSections()
        cachedSections = built
        return built
    }

    private func buildSections() -> [DaySection] {
        var sections: [DaySection] = []
        // TL-7：当日面板是第一个分区，时间线分区紧随其后，不替换时间线。
        if let key = selectedDayKey {
            sections.append(DaySection(dayKey: key, title: dayPanelTitle(key: key), entries: dayEntries))
        }
        var indexByKey: [String: Int] = [:]
        for entry in timelineEntries {
            guard let createdMs = entry.createdAt else { continue }
            // 日记时区（2026-11-21 v20 §二）：每篇按其自身时区定日组（cachedDayKey 内按 entry 时区换算）。
            guard let key = cachedDayKey(for: entry, createdMs: createdMs) else { continue }
            // 84 包：当日面板已展示该天条目时，时间线不再重复建组；dayEntries 为空时保留时间线组，避免取数失败藏条目。非今天的选中日同样适用。
            if key == selectedDayKey, !dayEntries.isEmpty { continue }
            if let existing = indexByKey[key] {
                sections[existing].entries.append(entry)
            } else {
                indexByKey[key] = sections.count
                sections.append(DaySection(dayKey: key, title: cachedDayTitle(for: key, ms: createdMs, tzName: entry.tzName), entries: [entry]))
            }
        }
        return sections
    }

    /// 审计 r18 第 37 项：按 entry id 取 dayKey——命中缓存即不跑日历换算；
    /// 未命中时现算并记入缓存；无 id 的条目不缓存、每次现算。
    /// 日记时区：按 entry 自身时区换算（entry 时区固定，按 id 缓存安全）。
    private func cachedDayKey(for entry: Entry, createdMs: Int) -> String? {
        if let entryId = entry.id, let cached = dayKeyCacheByEntryId[entryId] { return cached }
        guard let key = BearyBeijingDay.dayKey(ofMs: createdMs, tzName: entry.tzName) else { return nil }
        if let entryId = entry.id { dayKeyCacheByEntryId[entryId] = key }
        return key
    }

    /// 审计 r18 第 37 项：按 dayKey 取组标题——同 key 的标题只算一次。
    private func cachedDayTitle(for key: String, ms: Int, tzName: String? = nil) -> String {
        if let cached = dayTitleCacheByKey[key] { return cached }
        let title = dayTitleForMs(ms, tzName: tzName)
        dayTitleCacheByKey[key] = title
        return title
    }

    /// 追加 6①：日组标题统一格式——此前今天/昨天带“今天 · / 昨天 · ”前缀、
    /// 更早的日期没有前缀，同页内格式不统一；统一为一律“X月X日”
    /// （当日面板表头是另一组件，口径不动）。
    /// 2026-11-21 日期完全本地化：走共享 helper（中文 M月d日，与卡片同口径）。
    private func dayTitleForMs(_ ms: Int, tzName: String? = nil) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        return BearyLocalizedDate.monthDayString(from: date, timeZone: BearyBeijingDay.timeZone(tzName: tzName))
    }

    private func emptyView(title: String, subtitle: String, actionTitle: String?, action: (() -> Void)?, iconName: String = "icon_tray", kind: BearyStateKind = .empty) -> UIView {
        // 空／失败／登录态统一走 BearyStateView（54 圆图标＋15 粗标题＋12.5 副文案＋常规描边动作钮）；
        // 背景视图居中承载（此前 bespoke 栈顶距 40，统一后居中；动作闭包直通 onAction，不再经 emptyActionHandler 中转）。
        let container = UIView()
        container.backgroundColor = BearyColors.bg
        let stateView = BearyStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.configure(kind: kind, title: title, subtitle: subtitle, iconName: iconName, actionTitle: actionTitle, onAction: action)
        container.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stateView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stateView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            stateView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        return container
    }

    /// 空态/背景视图上次种类（本批 4b：种类切换时新背景视图 0.26s 淡入，
    /// 同种类重复调用不重播；减动效时直显）。
    private var lastChromeBackgroundKind: String?

    private func updateChrome() {
        // TL-7：当日面板的加载/失败/空态只反映在面板表头里，不再用整表背景空态
        // 覆盖时间线；背景空态只在时间线与当日面板双双无行时出现。
        let sections = currentSections()
        let hasRows = sections.contains { !$0.entries.isEmpty }
        let isLoginEmpty = (timelineState == .failed && timelineUnauthorized && timelineEntries.isEmpty)
        var newBackgroundKind = "none"
        if (timelineState == .loading || identityPendingFirstLoad) && timelineEntries.isEmpty && !hasRows {
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
                // 加载三件套·骨架屏：首屏加载出 3 张骨架卡（减动效静态、不扫光）。
                tableView.backgroundView = timelineSkeletonView
                didShowTimelineSkeleton = true
                newBackgroundKind = "loading-skeleton"
            }
        } else if timelineState == .failed && timelineEntries.isEmpty && !hasRows {
            if isLoginEmpty {
                tableView.backgroundView = emptyView(title: "请先登录", subtitle: "时间线只放你自己的日记，登录后就能看", actionTitle: "去登录", action: { [weak self] in
                    self?.onRequireLogin?()
                }, iconName: "icon_calendar", kind: .login)
                newBackgroundKind = "login"
            } else {
                // W10：加载失败空态副标题为中性文案“加载失败，点按重试”。
                tableView.backgroundView = emptyView(title: NSLocalizedString("timeline.load_failed_title", comment: ""), subtitle: NSLocalizedString("timeline.load_failed_retry", comment: ""), actionTitle: NSLocalizedString("common.retry", comment: ""), action: { [weak self] in
                    self?.reloadTimeline()
                }, iconName: "icon_wifi_off", kind: .error)
                newBackgroundKind = "failed"
            }
        } else if timelineState == .loaded && !hasRows {
            // B-G9: web renderTimeline empty state uses beary-diary, not tray.
            // Q5：时间线空态加“写一篇”按钮（走 onCompose 回调，容器接线打开编辑器；
            // 回收站空态不在本文件，不动）。
            tableView.backgroundView = emptyView(title: NSLocalizedString("timeline.empty.title", comment: ""), subtitle: NSLocalizedString("timeline.empty.subtitle", comment: ""), actionTitle: NSLocalizedString("timeline.empty.action", comment: ""), action: { [weak self] in
                self?.onCompose?()
            }, iconName: "icon_diary")
            newBackgroundKind = "empty"
        } else {
            // 加载三件套·骨架淡出：首屏骨架出过屏时，背景视图 0.26s 淡出再摘；
            // 减动效或非骨架背景时直接摘（骨架淡出与内容 60ms/8px 入场同步）。
            if didShowTimelineSkeleton, let oldBackground = tableView.backgroundView, BearyMotion.animated(true) {
                didShowTimelineSkeleton = false
                UIView.animate(withDuration: BearyMotion.normal, animations: {
                    oldBackground.alpha = 0
                }, completion: { [weak self] _ in
                    guard let self = self, self.tableView.backgroundView === oldBackground else { return }
                    self.tableView.backgroundView = nil
                    oldBackground.alpha = 1
                })
            } else if let bg = tableView.backgroundView, bg === timelineSkeletonView, bg.alpha < 1 {
                // 骨架正在淡出中（0.26s 内 updateChrome 重入）：不动，等淡出完成自摘。
            } else {
                didShowTimelineSkeleton = false
                tableView.backgroundView = nil
            }
        }
        // 本批 4b：空态切换补入场动效——种类变化且新背景非空时淡入
        // （6-7 收敛到 0.26s alpha 过渡；只动 backgroundView 的 alpha，
        // 已有表行不重播、不重载）。
        if let backgroundView = tableView.backgroundView,
           newBackgroundKind != "none",
           newBackgroundKind != lastChromeBackgroundKind,
           UIAccessibility.isReduceMotionEnabled == false {
            backgroundView.alpha = 0
            UIView.animate(withDuration: BearyMotion.normal, animations: {
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

    /// G15 分页失败 toast：委托统一 BearyToast。时间线是 Chrome 主 tab，
    /// FAB 常驻（下滑藏栏已拆除；搜索藏栏只针对搜索页），落点由组件按
    /// Chrome 实际 chrome 态算；展示时长由旧 1.6s 统一为 2.0s，
    /// 调用签名与文案、触发时机不变。
    private func showTimelineToast(message: String) {
        BearyToast.show(in: view, message: message)
    }

    /// 已有内容刷新失败条显隐（私信会话列表／广场同款）：只换表顶约束，不碰
    /// contentOffset、不清列表，滚动位置不动；显隐变化后吸顶日期头重算（条在屏时让位）。
    private func setRefreshFailedBannerVisible(_ visible: Bool) {
        refreshFailedBanner.isHidden = !visible
        tableViewTopToViewTopConstraint?.isActive = !visible
        tableViewTopToBannerConstraint?.isActive = visible
        updateStickyHeader()
    }

    @objc private func refreshFailedRetryTapped() {
        reloadTimeline(keepSelectedDay: true)
    }

    private func updateFooter() {
        // 脚部只属于时间线翻页；当日面板的加载/失败态在面板表头里。
        // 加载三件套·底部脚部：加载中 3 个跳动圆点、末页“没有更多了”、
        // 分页失败重试；手动“加载更多”按钮已由离底部一屏自动预加载取代。
        let state: BearyLoadMoreFooterView.State = {
            if timelineLoadingMore { return .loading }
            if timelinePageFailed && timelineHasMore { return .failed }
            if !timelineHasMore && !timelineEntries.isEmpty { return .end }
            return .hidden
        }()
        timelineLoadMoreFooterView.setState(state)
        // 审计 r16 第 17 项：脚部“重试”是手动点按，退避窗口内被拦时给 toast
        // 提示（原 didTapFooter 的 manual: true 口径，主线脚部已改走
        // BearyLoadMoreFooterView 的 onRetry，语义随之搬过来）。
        timelineLoadMoreFooterView.onRetry = { [weak self] in self?.loadTimelineNextPage(manual: true) }
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        let signature = "\(state)-\(Int(width))"
        if signature == lastTimelineFooterSignature, tableView.tableFooterView != nil { return }
        lastTimelineFooterSignature = signature
        guard state != .hidden else {
            tableView.tableFooterView = nil
            return
        }
        timelineLoadMoreFooterView.frame = CGRect(x: 0, y: 0, width: width, height: BearyLoadMoreFooterView.height)
        tableView.tableFooterView = timelineLoadMoreFooterView
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
        // 审计 2026-11-02 第十节：三档选择器（私密/仅好友/公开），选同档即无变化；
        // 引用规则简化（2026-10-31）：切公开先过引用门禁、改私密先查引用数提醒、
        // 改仅好友为收紧方向直接放行；门禁/提醒期间占 busy 位，放弃时清位、
        // 原态未动（乐观落地只在 perform 里做）。
        BearyVisibility.presentPicker(from: self, entry: entry) { [weak self] targetVisibility in
            guard let strongSelf = self else { return }
            if BearyVisibility.isNoChange(target: targetVisibility, for: entry) { return }
            strongSelf.publishBusyIds.insert(entryId)
            if targetVisibility == "public" {
                BearyQuoteGate.gatePublicToggle(from: strongSelf, entry: entry) { [weak self] result in
                    guard let strongSelf = self else { return }
                    switch result {
                    case .proceed:
                        strongSelf.performPublishEntry(entry, targetVisibility: targetVisibility)
                    case .publishTogether(let sourceId):
                        BearyAPI.shared.setVisibility(id: sourceId, visibility: "public") { setResult in
                            DispatchQueue.main.async {
                                switch setResult {
                                case .success:
                                    strongSelf.performPublishEntry(entry, targetVisibility: targetVisibility, publishTogetherSourceId: sourceId)
                                case .failure:
                                    strongSelf.publishBusyIds.remove(entryId)
                                    strongSelf.showTimelineToast(message: "原日记公开失败，请重试")
                                }
                            }
                        }
                    case .aborted:
                        strongSelf.publishBusyIds.remove(entryId)
                    }
                }
            } else if targetVisibility == "private" {
                BearyQuoteGate.confirmPrivateToggleIfQuoted(from: strongSelf, entryId: entryId) { [weak self] confirmed in
                    guard let strongSelf = self else { return }
                    if confirmed {
                        strongSelf.performPublishEntry(entry, targetVisibility: targetVisibility)
                    } else {
                        strongSelf.publishBusyIds.remove(entryId)
                    }
                }
            } else {
                strongSelf.performPublishEntry(entry, targetVisibility: targetVisibility)
            }
        }
    }

    private func performPublishEntry(_ entry: Entry, targetVisibility: String, publishTogetherSourceId: String? = nil) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        let viewerId = SessionManager.shared.currentUser?.id
        guard entry.isMine == true || (entry.authorId != nil && viewerId != nil && entry.authorId == viewerId) else { return }
        let originalPublic = entry.isPublic ?? false
        let originalPublishedAt = entry.publishedAt
        let originalVisibility = entry.visibility
        let originalEphemeralUntil = entry.ephemeralUntil
        // 先行：目标态立即落地（模型 + 可见行，不整页重拉）。
        applyVisibilityLocally(entryId: entryId, isPublic: BearyVisibility.isPublicValue(targetVisibility), publishedAt: nil, visibility: targetVisibility, ephemeralUntil: nil)
        BearySoundPlayer.play(.visibilityClick)
        // 审计动效组：可见性翻转统一为“图标＋pill 文案”。（2026-11-19 震动精简：轻震去掉）
        reloadVisibleTimelineRow(entryId: entryId)
        BearyAPI.shared.setVisibility(id: entryId, visibility: targetVisibility) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.publishBusyIds.remove(entryId)
                switch result {
                case .success(let resp):
                    let isPublic = resp.visibility.map { BearyVisibility.isPublicValue($0) }
                        ?? resp.published.map { $0 == 1 }
                        ?? BearyVisibility.isPublicValue(targetVisibility)
                    // 秒开-网络层：转非公开成功即逐出本篇图片的本机缓存；失败
                    // 回滚分支不逐出（原态未变）。
                    if !isPublic {
                        BearyImageLoader.shared.evictEntryImages(keys: entry.images ?? [])
                    }
                    strongSelf.applyVisibilityLocally(entryId: entryId, isPublic: isPublic, publishedAt: resp.publishedAt, visibility: resp.visibility ?? targetVisibility, ephemeralUntil: resp.ephemeralUntil)
                    strongSelf.refreshAfterDetailChange()
                case .failure(let err):
                    strongSelf.applyVisibilityLocally(entryId: entryId, isPublic: originalPublic, publishedAt: originalPublishedAt, visibility: originalVisibility, ephemeralUntil: originalEphemeralUntil)
                    strongSelf.reloadVisibleTimelineRow(entryId: entryId)
                    // r29-2：一并公开第二步失败时源篇已公开，尝试恢复回私密；
                    // toast 按恢复结果区分，不用泛化“切换失败”。
                    if let sourceId = publishTogetherSourceId {
                        BearyAPI.shared.setVisibility(id: sourceId, visibility: "private") { [weak self] restoreResult in
                            DispatchQueue.main.async {
                                guard let strongSelf = self else { return }
                                switch restoreResult {
                                case .success:
                                    strongSelf.showTimelineToast(message: "公开失败，原日记已恢复私密")
                                case .failure:
                                    strongSelf.showTimelineToast(message: BearyRepeatedCopy.publishFailedRestoreFailed)
                                }
                            }
                        }
                    } else {
                        let message: String
                        if case .server(let code, _) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                        else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                        else { message = "切换失败，请重试" }
                        strongSelf.showTimelineToast(message: message)
                    }
                    strongSelf.shakeVisibleTimelinePublishButton(entryId: entryId)
                }
            }
        }
    }

    /// 2026-11-11 改版：卡片右上角 ⋯ 菜单迁底部弹窗（BearyConfirmSheet；原文案/
    /// 顺序/语义全保留）——编辑内容／修改权限／删除。编辑永久可改，不再按
    /// 15 分钟门控（冲突清单第 4 条）。
    /// 修改权限走原地球钮同一 handlePublishEntry 路径（含乐观落地、失败回滚、拒绝动效）；
    /// 删除走原删除回调同一路（容器确认流程不变）；iPad popover 锚点随迁移删去。
    private func presentTimelineMoreMenu(entry: Entry) {
        var actions: [BearyConfirmSheet.Action] = []
        actions.append(BearyConfirmSheet.Action(title: "编辑内容", style: .default) { [weak self] in
            self?.onEditEntry?(entry)
        })
        actions.append(BearyConfirmSheet.Action(title: "修改权限", style: .default) { [weak self] in
            self?.handlePublishEntry(entry)
        })
        actions.append(BearyConfirmSheet.Action(title: "删除", style: .destructive) { [weak self] in
            self?.onDeleteEntry?(entry)
        })
        // 审计-时间线：present 前统一守卫，已有弹窗时不叠页（筛子呈现留给 11b 气泡，本支不动）。
        guard presentedViewController == nil else { return }
        BearyConfirmSheet.show(from: self, title: "", message: nil, actions: actions)
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
    /// timeline/day 列表与日缓存里的副本就地改 isPublic/visibility/publishedAt；
    /// ephemeralUntil：直接写回传入值；正向翻转传 nil（服务端同口径），失败回滚传原值；
    /// visibility 未传时按 isPublic 派生 public/private。
    /// 改动的日缓存同步写落盘；引用缓存清掉该篇（旧引用卡不按旧可见性渲染）。
    private func applyVisibilityLocally(entryId: String, isPublic: Bool, publishedAt: Int?, visibility: String? = nil, ephemeralUntil: Int? = nil) {
        // 审计 2026-11-02 第十节：成功回写 visibility 与 ephemeralUntil；
        // 手动翻转清限时标记（服务端同口径），否则本地仍画虚线边框——
        // 回包显式带回新的 ephemeralUntil 时以回包为准；回滚路径传回原值。
        // （行签名与 patchedEntries 的 visibility/ephemeralUntil 补齐归时间线组，
        // 本函数只保证三副本的可见性字段同步写回。）
        for index in timelineEntries.indices where timelineEntries[index].id == entryId {
            timelineEntries[index].isPublic = isPublic
            timelineEntries[index].visibility = visibility ?? (isPublic ? "public" : "private")
            timelineEntries[index].ephemeralUntil = ephemeralUntil
            if let publishedAt = publishedAt { timelineEntries[index].publishedAt = publishedAt }
        }
        for index in dayEntries.indices where dayEntries[index].id == entryId {
            dayEntries[index].isPublic = isPublic
            dayEntries[index].visibility = visibility ?? (isPublic ? "public" : "private")
            dayEntries[index].ephemeralUntil = ephemeralUntil
            if let publishedAt = publishedAt { dayEntries[index].publishedAt = publishedAt }
        }
        for key in dayEntriesCache.keys {
            var list = dayEntriesCache[key] ?? []
            var changed = false
            for index in list.indices where list[index].id == entryId {
                list[index].isPublic = isPublic
                list[index].visibility = visibility ?? (isPublic ? "public" : "private")
                list[index].ephemeralUntil = ephemeralUntil
                if let publishedAt = publishedAt { list[index].publishedAt = publishedAt }
                changed = true
            }
            if changed {
                dayEntriesCache[key] = list
                cacheDayEntries(key: key, entries: list)
            }
        }
        if isPublic == false {
            BearyDiaryCardCell.invalidateQuote(id: entryId)
        }
    }

    @objc private func didTapStats() {
        // G14：重试全部可视失败月份（周视图跨月时次要月份也有入口，不只主月份）。
        // r17-C1：失败月即使已有落盘旧数据也要强制重拉——旧圆点只是上次的，
        // 卡内失败行「显示的是上次的数据」的重试必须真发请求，否则点按无反应。
        for key in monthKeysForCurrentView() {
            if calendarFailed.contains(key) {
                fetchCalendarMonth(key: key, force: true)
            }
        }
    }

    /// R15-L1：当日面板组头日期旁重试——重拉选中日（clear:false，不清行；
    /// 在途守卫在 fetchDayEntries 内，重复点按不重复发请求）。
    @objc private func retryDayPanel() {
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
        // v14 改版：空日占位行——当日面板无条目且已加载时出 1 行纯文字占位。
        if section == 0, isDayPanelEmpty { return 1 }
        return sections[section].entries.count
    }

    /// 时间线行高估算（正文行高倍数 1.75、不折叠，与卡片 1.6/6 行封顶不同口径，
    /// 见 configure 内 8-13 注释）。正文列宽按约束取：内容列左 36 + 栈左右各 16，
    /// 右 16，共 84。引用卡/足行等可变行取固定近似值，允许几十 pt 误差。
    private func estimatedTimelineRowHeight(for entry: Entry, tableWidth: CGFloat) -> CGFloat {
        let contentWidth = max(0, tableWidth - 84)
        let text = entry.content ?? ""
        let textHeight = BearyDiaryCardCell.estimatedTextHeight(text, width: contentWidth, lineHeightMultiple: 1.75)
        let imageKeys = (entry.images ?? []).filter { !$0.isEmpty && !BearyGIF.isInlineImageKey($0, content: text, title: entry.title ?? "") }
        let hasImages = !imageKeys.isEmpty
        let hasTitle = !(entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasQuote = entry.quote != nil || entry.quoteId != nil
        let hasLocation = !(entry.locationName ?? "").isEmpty || !(entry.locationDistrict ?? "").isEmpty
        let likeCount = entry.likeCount ?? 0
        let emoteTotal = (entry.emotes ?? []).reduce(0) { $0 + ($1.count ?? 0) }
        let bookmarkCount = entry.bookmarkCount ?? 0
        let hasFootCounts = BearyEphemeral.isEffectivelyPublic(entry) && (likeCount > 0 || emoteTotal > 0 || bookmarkCount > 0)

        var height: CGFloat = 6 + 14  // 列顶 + 栈顶
        height += 28   // meta 行（⋯钮 28）
        height += 12   // meta→正文
        if hasTitle { height += 20 + 6 }                              // 标题行 + 间距
        height += textHeight
        height += 14   // 正文→下行
        if hasImages { height += BearyImageStrip.height + 12 }                           // 图片条 + 间距
        if imageKeys.count > 3 { height += 32 + 12 }                  // 九宫格入口 + 间距
        if hasQuote { height += 72 + 12 }                             // 引用卡（近似）+ 间距
        if hasLocation { height += 18 + 14 }                          // 位置行 + 间距
        if hasFootCounts { height += 17 + 12 }                        // 计数足行 + 间距
        if entry.isMine == true { height += 17 }                      // 编辑行
        height += 6 + 8  // 栈底 + 列底
        return height
    }

    /// 估算用表宽：布局前 bounds 仍为 0 时按 view 宽、再按屏宽回落。
    private func estimationTableWidth(using tableView: UITableView) -> CGFloat {
        if tableView.bounds.width > 0 { return tableView.bounds.width }
        if view.bounds.width > 0 { return view.bounds.width }
        return UIScreen.main.bounds.width
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        // v14 改版：空日占位行固定 44pt。
        if indexPath.section == 0, isDayPanelEmpty { return 44 }
        // 固定 estimatedRowHeight 180 与真实行高（纯文字约 170、有图 400+）差近
        // 200pt，滚动中 contentSize 不断修正会漂移；按模型逐行估算。
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return 180 }
        return estimatedTimelineRowHeight(for: sections[indexPath.section].entries[indexPath.row], tableWidth: estimationTableWidth(using: tableView))
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // v14 改版：空日占位行——纯文字「这天没有日记」，15pt 灰，leading 36
        // 与正文列对齐，上下各 12（行高 44）；不是日记卡，不挂任何操作。
        if indexPath.section == 0, isDayPanelEmpty, indexPath.row == 0 {
            let reuseId = "BearyEmptyDayCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: reuseId) ?? UITableViewCell(style: .default, reuseIdentifier: reuseId)
            cell.selectionStyle = .none
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            // 复用 cell 先清旧文案（同一 identifier 只此一处用，仍防残留）。
            for subview in cell.contentView.subviews {
                subview.removeFromSuperview()
            }
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = NSLocalizedString("timeline.empty_day", comment: "")
            label.font = BearyDynamicType.smallBodyFont()
            label.adjustsFontForContentSizeCategory = true
            label.textColor = BearyColors.gray
            cell.contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 36),
                label.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            ])
            return cell
        }
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
        cell.onMoreEntry = { [weak self] entry, _ in self?.presentTimelineMoreMenu(entry: entry) }
        // N7：复用独立文件内的查看器，全屏模态弹出（已弹出时不叠加、减动效直显）。
        let viewerEntry = sections[indexPath.section].entries[indexPath.row]
        cell.onTapImages = { [weak self] keys, index, originFrame, thumbnail in
            guard let self = self, self.presentedViewController == nil else { return }
            self.presentImageViewer(imageKeys: keys, liveVideos: viewerEntry.liveVideos, startIndex: index, thumbnail: thumbnail, originFrame: originFrame)
        }
        cell.onNineGridTapped = { [weak self] button in
            guard let strongSelf = self else { return }
            BearyNineGridPresenter.present(from: strongSelf, anchorView: button, imageKeys: viewerEntry.images ?? [], liveVideos: viewerEntry.liveVideos)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let sections = currentSections()
        guard section < sections.count else { return nil }
        let isDayPanel = (section == 0 && selectedDayKey != nil)
        let label = UILabel()
        // R15-L1：当日面板失败时组头出日期旁重试钮（见下方约束分支）。
        var dayPanelFailed = false
        // L13：当日面板头拆日期加粗 + 计数灰色 12 两段富文本；时间线分区头不变。
        if isDayPanel, let dayKey = selectedDayKey {
            let parts = dayPanelTitleParts(key: dayKey)
            dayPanelFailed = parts.failed
            // R8：日组标题（正文类）走 scaledFont + adjusts。
            let attributed = NSMutableAttributedString(string: parts.head, attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15)),
                .foregroundColor: BearyColors.ink,
            ])
            if parts.suffix.isEmpty == false {
                attributed.append(NSAttributedString(string: parts.suffix, attributes: [
                    .font: BearyDynamicType.captionFont(),
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
        // R15-L1：当日失败时日期保留、日期旁出文字重试钮（重拉当日，
        // 不清行）；第 15 项“失败文案本身即重试入口（再点日期）”已废止。
        if isDayPanel && dayPanelFailed {
            label.setContentCompressionResistancePriority(.init(749), for: .horizontal)
            let retryButton = BearyButton.retryInline()
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.addTarget(self, action: #selector(retryDayPanel), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            retryButton.accessibilityLabel = "当日列表加载失败，重试"
            holder.addSubview(retryButton)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 16),
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: leading),
                label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -16),
                retryButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
                retryButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                retryButton.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -16),
                bottomView.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: bottomConstant),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: holder.topAnchor, constant: isDayPanel ? 16 : 18),
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: leading),
                label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
                bottomView.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: bottomConstant),
            ])
        }
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

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let sections = currentSections()
        guard indexPath.section < sections.count, indexPath.row < sections[indexPath.section].entries.count else { return }
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        onOpenEntry?(sections[indexPath.section].entries[indexPath.row])
    }

    /// C7 滑动操作资格（iCity）：删除公开/私密均可；冲突清单第 4 条取消
    /// 15 分钟锁后，编辑只看本人（时间线本就只列本人日记），与可见性无关。
    /// 触发后只复用 onDeleteEntry/onEditEntry（容器确认/编辑器流程），
    /// 不另写执行逻辑；不符资格的行返回 nil，即不可滑动。
    private static func isTimelineSwipeEditUnlocked(entry: Entry) -> Bool {
        entry.isMine == true
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
        // P3-30 修正（2026-11-14，132 真机）：编辑钮底色不能直接走 ink——
        // ink 深色下是近白 #F5F5F5，而 UIContextualAction 的标题字固定白色，
        // 深色下白底白字（对比约 1.1:1）完全看不清（截图实测）。按 trait 分流：
        // 浅色仍走 ink 黑底（白字对比约 21:1）；深色走 surface3 #18181C 深灰
        //（白字对比约 17.7:1；与页底 #0B0B0D 只差一档，靠白字认出按钮）。删除钮（destructive
        // 系统红）本身可读，不动。
        edit.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? BearyColors.surface3.resolvedColor(with: trait)
                : BearyColors.ink.resolvedColor(with: trait)
        }
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
                    // 卡片糊同款：首图预热与时间线条同口径的全尺寸图。
                    if let firstKey = entry.images?.first, let imageURL = BearyImageURLs.imageURL(key: firstKey, thumb: false) {
                        // 112：预取与卡片展示同宽下采样（卡片 bearyStripWidth 同公式，
                        // 见 BearyTimelinePrefetchStrip）——旧口径不带宽度时内存键
                        // 与展示键不一致，预取只暖磁盘、展示仍需解码一遍
                        //（灯箱 111 同款问题）。
                        _ = BearyImageLoader.shared.load(url: imageURL, downsampleToWidth: BearyTimelinePrefetchStrip.width(for: entry) * UIScreen.main.scale) { _ in }
                    }
                }
            }
        }
        // N3：切日新行错峰滑入——cell 即将上屏时从透明 + 下偏 6 起播，
        // 按面板行序号错峰（步进 0.03s、封顶 0.24s，下偏 6pt，与月历一致；减动效时队列为空，不播）。
        // 与 M2 同机制：播过即摘、代际不符即弃；仅新日行播，已有行不重播。
        // 只动 transform/opacity，严禁逐帧改 height。
        if let dayOrder = daySwitchStagger[indexPath] {
            daySwitchStagger[indexPath] = nil
            if daySwitchGeneration == staggerGeneration {
                if let slide = daySwitchSlideDirection {
                    // 换日定向滑入：整版同向齐滑 0.26s，不逐行错峰（两种动效不打架）。
                    // 更早的日子往下翻，行自下方滑入；更晚的往上翻，行自上方滑入；
                    // 入场位移 24pt（与分页追加同口径）。队列播完即清方向。
                    let entryY: CGFloat = slide == .earlier ? 24 : -24
                    cell.alpha = 0
                    cell.transform = CGAffineTransform(translationX: 0, y: entryY)
                    UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
                        cell.alpha = 1
                        cell.transform = .identity
                    }, completion: nil)
                    if daySwitchStagger.isEmpty { daySwitchSlideDirection = nil }
                    return
                }
                cell.alpha = 0
                cell.transform = CGAffineTransform(translationX: 0, y: 6)
                let delay = min(Double(dayOrder) * 0.03, 0.24)
                UIView.animate(withDuration: BearyMotion.normal, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
                    cell.alpha = 1
                    cell.transform = .identity
                }, completion: nil)
                return
            }
        }
        // M2：分页新增行错峰滑入——cell 即将上屏时从透明 + 下偏起播，
        // 按原始序号错峰（减动效时队列为空，不播）。
        guard let order = staggerInsertOrder[indexPath] else { return }
        staggerInsertOrder[indexPath] = nil
        // 80 包 A2-3②：队列代际不符时丢弃残留条目，不在新数据行上重播旧错峰。
        guard staggerQueueGeneration == staggerGeneration else { return }
        // 审计 r16 第 10 项：步进／位移走 BearyEntranceConfig（首屏／筛子切换
        // 60ms／8pt、分页追加 30ms／8pt），与广场共用一套配置；0.26s、
        // 封顶 0.24s、可交互。减动效时队列为空，不播。
        let entranceKind: BearyEntranceConfig.Kind = staggerInsertFirstLoad ? .firstLoad : .pagination
        cell.alpha = 0
        cell.transform = CGAffineTransform(translationX: 0, y: BearyEntranceConfig.yOffset(for: entranceKind))
        let delay = BearyEntranceConfig.delay(for: entranceKind, order: order)
        UIView.animate(withDuration: BearyEntranceConfig.duration, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
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
        UIView.animate(withDuration: BearyMotion.micro, animations: {
            view.alpha = 1
        })
    }

    // 下滑藏栏已拆除（第 11 项）：底栏分段器与 FAB 常驻，scrollViewDidScroll
    // 只做追加项二的悬浮日期头跟随，不做藏栏。
}

/// 112：时间线 willDisplay 预取的卡片首图下采样宽度（pt）——与卡片
/// bearyStripWidth(forKey:dims:height:) 同公式：
/// 216 × 宽高比，夹在 216×0.55…216×2.22，无 dims 时 280；调用方再 × scale。
enum BearyTimelinePrefetchStrip {
    static func width(for entry: Entry) -> CGFloat {
        let height: CGFloat = BearyImageStrip.height
        if let dims = entry.imgDims, let firstKey = entry.images?.first,
           let d = dims[firstKey], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = height * CGFloat(d[0]) / CGFloat(d[1])
            return round(max(height * 0.55, min(height * 2.22, raw)))
        }
        return 280
    }
}

/// 110：时间线首屏磁盘缓存（首页 BearyFeedCache 同款结构与桶口径，
/// 见 BearyFeedViewController.swift 末尾）。时间线是本人全部日记，
/// 快照不做公开过滤；桶按用户隔离，游客不写盘（首屏成功写盘处
/// 只在已登录时调用）。快照字段：savedAt、entries、hasMore、
/// trashCount、计数 total/priv/pub（TlCounts 仅 Decodable，故拆存）。
enum BearyTimelineCache {
    /// 审计 13：与 BearyFeedCache 同款——读写与编解码走独立串行队列，
    /// 不占主线程；读写同队列保证同一会话内写后读顺序。快照只存窗口
    /// （snapshotEntryLimit 条，随翻页增长的整表不再落盘）；窗口外还有
    /// 篇时 hasMore 强制为真，截断后的分页游标是窗口末条，before 续拉
    /// 恰好取回被截掉的旧篇，续接不断。
    private static let ioQueue = DispatchQueue(label: "beary.timelineCache.io", qos: .utility)
    static let snapshotEntryLimit = 60

    /// 审计 22 项：按桶的失效代次，与 BearyFeedCache 同口径——purge
    /// 同步推进代次、删除进 ioQueue；save/load 调用时固定代次、队列内
    /// 执行时再次校验。purge 前已排队的写被弃写，purge 前排队的读在
    /// 代次已变时改发 nil，删除后旧任务不能重新落盘、旧快照不能递给
    /// 退出后的界面。代次只由 purge 推进，退出后重登同一桶读写正常。
    private static let generationLock = NSLock()
    private static var generations: [String: UInt64] = [:]

    private static func generation(for bucket: String) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucket] ?? 0
    }

    private static func bumpGeneration(for bucket: String) {
        generationLock.lock()
        generations[bucket, default: 0] += 1
        generationLock.unlock()
    }

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

    static func load(bucket: String, completion: @escaping ((entries: [Entry], hasMore: Bool, trashCount: Int, total: Int?, priv: Int?, pub: Int?, savedAt: TimeInterval)?) -> Void) {
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            var result: (entries: [Entry], hasMore: Bool, trashCount: Int, total: Int?, priv: Int?, pub: Int?, savedAt: TimeInterval)?
            if let url = fileURL(bucket: bucket), let data = try? Data(contentsOf: url),
               let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                result = (snap.entries, snap.hasMore, snap.trashCount, snap.total, snap.priv, snap.pub, snap.savedAt)
            }
            // 代次已变（期间 purge 过）：旧快照不再递出，改发 nil。
            let captured = capturedGeneration == generation(for: bucket) ? result : nil
            DispatchQueue.main.async { completion(captured) }
        }
    }

    static func save(bucket: String, entries: [Entry], hasMore: Bool, trashCount: Int, counts: TlCounts?) {
        let capped = Array(entries.prefix(snapshotEntryLimit))
        let storedHasMore = hasMore || entries.count > snapshotEntryLimit
        let snap = Snapshot(savedAt: Date().timeIntervalSince1970, entries: capped, hasMore: storedHasMore, trashCount: trashCount, total: counts?.total, priv: counts?.priv, pub: counts?.pub)
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 秒开-本地持久化：登出 / 会话失效时清当前账号的时间线快照。
    /// 时间线含私密日记，此前无 purge 入口、登出后文件仍留盘，是本批
    /// 补的缺口（广场 / 图片 / 日落盘此前已有清理，见 SessionManager）。
    /// 只删传入的桶，不碰其他账号的桶；账号切换（不退出）绝不调这里，
    /// 旧号快照保留、切回可复用。
    /// 审计 22 项：删除进入 ioQueue，不再同步删文件（同步删与异步写
    /// 不在同一队列时，删后仍在途的写会重新创建文件）；删除块排在此前
    /// 所有读写块之后，且代次屏障已先弃写 purge 前排队的写。
    static func purge(bucket: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let url = fileURL(bucket: bucket) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// 110：首页加载时的时间线首屏预取（一次/启动，见任务“首页加载时
/// 预取时间线首屏”）。触发点在首页首屏成功回包后（缓存命中走静默
/// 刷新时同样触发）；只在已登录时跑（游客时间线 401，不发无用请求）；
/// 只写时间线缓存，绝不碰时间线 VC 状态（VC 未创建时尤其不能碰）；
/// 预取失败静默丢弃（下次首页首屏成功再试，标志只在成功存盘后置位）；
/// 缓存已有且 10 分钟内新鲜时不重复拉（时间线 VC 每次打开仍静默
/// 刷新对齐，预取只负责冷启动前置，不替代刷新）。
/// 秒开·首屏再瘦：预取与时间线首屏同口径，只拉 12 条（原 50 条），
/// 否则预取本身就是一份 50 条首屏成本，瘦身白做。
enum BearyTimelinePrefetch {
    private static var didPrefetch = false
    /// 秒开-启动瘦身：待发的空闲预取（首屏回包后 2 秒才真正发请求，见 maybePrefetch；
    /// 时间线自己开页时取消——自己的首拉已覆盖，不再重复发一份）。
    private static var pendingWorkItem: DispatchWorkItem?
    /// 审计 13：异步新鲜度检查在途标志 + 代际——检查在途时被取消，
    /// 回包不再排队新任务（见 cancelPendingPrefetch）。
    private static var freshnessCheckInFlight = false
    private static var prefetchGeneration = 0
    /// A4：在途首屏请求（预取发出）：同账号、同筛选的时间线首拉可接手，
    /// 不再另发一份；预取自己的回包处理（写缓存）也挂在这里，与接手方
    /// 共享同一份回包。锁只护注册表读写，回包分发在锁外。
    private final class InFlightFirstPage {
        let userId: Int
        let vis: String?
        var handlers: [(Result<EntryList, APIError>) -> Void] = []
        init(userId: Int, vis: String?) {
            self.userId = userId
            self.vis = vis
        }
    }
    private static var inFlightFirstPage: InFlightFirstPage?
    private static let inFlightLock = NSLock()

    /// C2：didPrefetch 跨线程读写（主线程读、API 回包与缓存 IO 回调写），
    /// 用 inFlightLock 保护每一次读与写，只补同步，不改预热逻辑。
    private static func isPrefetched() -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return didPrefetch
    }
    private static func markPrefetched() {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        didPrefetch = true
    }

    /// A4：预取发首屏请求——与时间线首屏统一走轻量入口
    /// fetchTimelineFirstPage（scope=timeline + limit=12 + slim=1），
    /// 两条路径请求同一份首屏；发出前先登记在途，同账号、同筛选的
    /// 首拉可接手，不再另发。
    private static func fetchFirstPageForPrefetch(userId: Int, bucket: String) {
        let flight = InFlightFirstPage(userId: userId, vis: nil)
        // 预取自己的回包处理：成功写缓存、置 didPrefetch；失败不置位，
        // 下次广场首拉成功时可再排队；接手方各按首拉口径自行处理成败。
        flight.handlers.append { result in
            guard case .success(let list) = result, let entries = list.entries, !entries.isEmpty else { return }
            BearyTimelineCache.save(bucket: bucket, entries: entries, hasMore: entries.count >= 12, trashCount: list.trashCount ?? 0, counts: list.tlCounts)
            markPrefetched()
        }
        inFlightLock.lock()
        inFlightFirstPage = flight
        inFlightLock.unlock()
        BearyAPI.shared.fetchTimelineFirstPage(vis: nil) { result in
            inFlightLock.lock()
            if inFlightFirstPage === flight { inFlightFirstPage = nil }
            let handlers = flight.handlers
            inFlightLock.unlock()
            for handler in handlers { handler(result) }
        }
    }

    /// A4：时间线首拉接手在途预取——同账号、同筛选（vis 相等，全部档为
    /// nil）且预取首屏请求已在途时，把首拉回包处理挂上去，不再另发请
    /// 求；返回 false 时调用方照常自发请求。
    static func adoptFirstPageIfInFlight(userId: Int, vis: String?, completion: @escaping (Result<EntryList, APIError>) -> Void) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        guard let flight = inFlightFirstPage, flight.userId == userId, flight.vis == vis else { return false }
        flight.handlers.append(completion)
        return true
    }

    static func maybePrefetch() {
        guard isPrefetched() == false, pendingWorkItem == nil, freshnessCheckInFlight == false,
              let uid = SessionManager.shared.currentUser?.id else { return }
        let bucket = BearyFeedCache.bucket(userId: uid)
        // 审计 13：新鲜度检查的读盘 + 解码走缓存 IO 队列，不占主线程；
        // 检查在途时被取消（时间线自己开页）须让回包不再排队，用代际守卫。
        let generation = prefetchGeneration
        freshnessCheckInFlight = true
        BearyTimelineCache.load(bucket: bucket) { snap in
            freshnessCheckInFlight = false
            guard generation == prefetchGeneration, isPrefetched() == false, pendingWorkItem == nil else { return }
            if let snap = snap, !snap.entries.isEmpty,
               Date().timeIntervalSince1970 - snap.savedAt < 600 {
                markPrefetched()
                return
            }
            // 秒开-启动瘦身：此前在广场首拉成功当刻立即发时间线首拉，仍挤在
            // 首屏窗口里；现改为空闲 2 秒后再发——首屏图片/动效已让出窗口，且
            // 触发点仍在首屏回包之后。触发时重查登录态与缓存新鲜度：期间用户
            // 已开时间线（取消）或缓存已新（命中）时不再发；失败不置 didPrefetch，
            // 下次广场首拉成功时可再排队。取数口径跟随秒开·首屏再瘦（只拉 12 条，
            // #456 原文 50 已过期，不跟），与时间线首屏同一轻量入口（slim=1），
            // hasMore 阈值同步 12。
            let item = DispatchWorkItem {
                pendingWorkItem = nil
                guard isPrefetched() == false, let uid = SessionManager.shared.currentUser?.id else { return }
                // A4：第二次查缓存后、发请求前也复核代次——查盘期间时间线
                // 自己开页（cancelPendingPrefetch 代次 +1）时不再发请求。
                let generation = prefetchGeneration
                let bucket = BearyFeedCache.bucket(userId: uid)
                BearyTimelineCache.load(bucket: bucket) { snap in
                    guard generation == prefetchGeneration, isPrefetched() == false else { return }
                    if let snap = snap, !snap.entries.isEmpty,
                       Date().timeIntervalSince1970 - snap.savedAt < 600 {
                        markPrefetched()
                        return
                    }
                    fetchFirstPageForPrefetch(userId: uid, bucket: bucket)
                }
            }
            pendingWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
        }
    }

    /// 秒开-启动瘦身：时间线自己的首载接管时取消待发预取（在途请求不取消，
    /// 只写缓存、无界面副作用；时间线首拉会接手在途请求，不再另发一份，
    /// 见 adoptFirstPageIfInFlight）。审计 13：同时代际 +1，
    /// 让在途新鲜度检查的回包不再排队新任务。
    static func cancelPendingPrefetch() {
        prefetchGeneration += 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }
}

/// r17-C1 月历快照落盘：按「账号 + 北京时间年月」存服务端月历响应原样
/// （days 日计数 + monthTotal + streak，streak 是服务端算的、本地不重算）。
/// 目录：Application Support / beary_calendar_snapshot_<uid>/，文件 <YYYY-MM>.json。
/// 存在即「该月已确认」（days 为空/全 0 就是确认当月为空），缺失/损坏才是
/// 「这个月没缓存」——圆点层用 calendarCache 有无区分，落盘层用文件有无区分。
/// 退出/401 清理走 SessionManager.purgeLocalSnapshotsForCurrentAccount。
enum BearyCalendarSnapshotStore {
    static let directoryPrefix = "beary_calendar_snapshot"

    private static let ioQueue = DispatchQueue(label: "beary.calendarSnapshot.io", qos: .utility)
    /// 审计 22 项同款代次（见 BearyTimelineCache）：purge 推进代次、删除进
    /// ioQueue；purge 前排队的写被弃写、读改发 nil。另有 SessionManager 的
    /// 会话代次（load completion 处验），两者各司其职：本地代次拦 purge
    /// 前的旧任务，会话代次拦跨会话（登出/切号/401）的旧回包。
    private static let generationLock = NSLock()
    private static var generations: [String: UInt64] = [:]

    private static func generation(for bucket: String) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucket] ?? 0
    }

    private static func bumpGeneration(for bucket: String) {
        generationLock.lock()
        generations[bucket, default: 0] += 1
        generationLock.unlock()
    }

    /// 快照体：服务端响应原样 + 落盘时的北京日（跨日恢复时 streak 作废的依据）
    /// + 落盘时间戳。
    struct Snapshot: Codable {
        var savedAt: TimeInterval
        var savedDayKey: String
        var response: BearyCalendarMonthResponse
    }

    private static func fileURL(accountId: Int, monthKey: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("\(directoryPrefix)_\(accountId)").appendingPathComponent("\(monthKey).json")
    }

    /// 读盘（异步，ioQueue 上读 + 解码，主线程回包）：文件缺失/损坏发 nil；
    /// 回包前验两道——本地 purge 代次（期间 purge 过即 nil）与调用方传入的
    /// 会话代次（SessionManager.currentSessionGeneration，期间登出/切号/
    /// 401 即 nil）。
    static func load(accountId: Int, monthKey: String, sessionGeneration: Int, completion: @escaping (Snapshot?) -> Void) {
        let bucket = "\(accountId)"
        let capturedLocal = generation(for: bucket)
        ioQueue.async {
            var result: Snapshot?
            if let url = fileURL(accountId: accountId, monthKey: monthKey),
               let data = try? Data(contentsOf: url),
               let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                result = snap
            }
            if capturedLocal != generation(for: bucket) { result = nil }
            let captured = result
            DispatchQueue.main.async {
                // 会话代次是真凭据：读盘期间登出/切号/401 都会 +1，旧回包一律丢弃。
                guard SessionManager.shared.currentUser?.id == accountId,
                      SessionManager.shared.currentSessionGeneration == sessionGeneration else {
                    completion(nil)
                    return
                }
                completion(captured)
            }
        }
    }

    /// 写盘（异步，不卡主线程）：编码/建目录/原子写任一步失败记一条日志
    /// （调用方在 fetch 成功处调，失败不影响内存态，下次成功再写）。
    /// purge 前已排队的写被代次屏障弃写。
    static func save(accountId: Int, monthKey: String, response: BearyCalendarMonthResponse) {
        let bucket = "\(accountId)"
        let capturedLocal = generation(for: bucket)
        let dayKey = BearyBeijingDay.todayComponents().map { BearyBeijingDay.dayKey(year: $0.year, month: $0.month, day: $0.day) } ?? ""
        let snap = Snapshot(savedAt: Date().timeIntervalSince1970, savedDayKey: dayKey, response: response)
        ioQueue.async {
            guard capturedLocal == generation(for: bucket) else { return }
            guard let url = fileURL(accountId: accountId, monthKey: monthKey),
                  let data = try? JSONEncoder().encode(snap) else {
                NSLog("[BearyCalendarSnapshot] encode failed month=%@", monthKey)
                return
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[BearyCalendarSnapshot] write failed month=%@ error=%@", monthKey, error as NSError)
            }
        }
    }

    /// 退出/401 清理：只删传入账号的桶，不碰其他账号；删除进 ioQueue，
    /// 代次屏障先弃写 purge 前排队的读写。
    static func purge(accountId: Int) {
        let bucket = "\(accountId)"
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("\(directoryPrefix)_\(accountId)", isDirectory: true) else { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - 写一笔速写器（v14 改版）

/// 写一笔交 VC 的草稿（点发布瞬间定格）：正文、图片、引用、@、标签、位置。
/// 选中日期由 VC 在 publishInlineComposer 里按 selectedDayKey 填（nil = 今天）。
struct BearyInlineComposerDraft {
    var text: String
    var images: [BearyPublishImage]
    var imageLocalFiles: [String]
    var quoteId: String?
    var mentionedUserId: Int?
    var tags: [String]
    var location: DiaryLocation?
}

/// 写一笔速写器：写选中那天的日记（今天 nil 日期走旧口径，过去某天带 date）。
/// 放在时间线表头底部（日历卡下方）；编辑器页不动。
/// 工具复用编辑器同款签名（图片 PHPicker／定位／表情／标签／@／引用）；
/// 自定义表情上传不做（toast 指去写日记页）；粘贴图片拦截同 #2090 口径。
final class BearyInlineComposerView: UIView, UITextViewDelegate, PHPickerViewControllerDelegate {

    weak var presenter: UIViewController?
    var onPublish: ((BearyInlineComposerDraft) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onHeightChanged: (() -> Void)?
    var onRequireLogin: (() -> Void)?
    var onToast: ((String) -> Void)?

    static let maxImages = 9
    /// 正文长到约 120pt 后内部滚动（与编辑器同口径的上限感）。
    private static let maxTextHeight: CGFloat = 120
    private static let minTextHeight: CGFloat = 48

    private let dateLabel = UILabel()
    private let boxView = UIView()
    private let focusedBackgroundView = UIView()
    private let dashedBorderView = BearyDashedBorderView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let chipsScrollView = UIScrollView()
    private let chipsStack = UIStackView()
    private let toolRow = UIStackView()
    private let publishButton = UIButton(type: .system)
    private var textViewHeightConstraint: NSLayoutConstraint?
    private var lastTextViewWidth: CGFloat = 0

    private var composerFocused = false
    /// 发布在途（发布中心 pill 负责失败重试；成功回包后 VC 调 reset 清掉）。
    var isPublishing = false { didSet { updatePublishButton() } }

    // 选中日状态（VC 每次选日／当日回包后调 updateDay 同步）。
    private(set) var selectedDayKey: String?
    private var dayHasEntries = false
    private var isFutureDay = false

    // 内容
    private var imageItems: [(localFile: String, image: UIImage)] = []
    private var gifKeys: [String] = []
    private var selectedLocation: DiaryLocation?
    private var selectedTags: [String] = []
    private var mentionedUser: SearchUser?
    private var selectedQuote: Entry?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(textView.bounds.width - lastTextViewWidth) > 0.5 {
            lastTextViewWidth = textView.bounds.width
            updateTextViewHeight()
        }
    }

    // MARK: - 搭建

    private func buildUI() {
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = BearyDynamicType.secondaryFont()
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = BearyColors.gray

        // 闲置态虚线框（现成 BearyDashedBorderView：1.5pt、[4,3]、圆角 16、line 色）；
        // 聚焦时切微明度底（surface 系），虚线框不动。
        focusedBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        focusedBackgroundView.backgroundColor = BearyColors.surface1
        focusedBackgroundView.layer.cornerRadius = BearyCorners.single
        focusedBackgroundView.alpha = 0
        dashedBorderView.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.font = BearyDynamicType.smallBodyFont()
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = BearyColors.ink
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: BearySpace.md, left: BearySpace.md, bottom: BearySpace.md, right: BearySpace.md)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.returnKeyType = .default
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = BearyDynamicType.smallBodyFont()
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.isUserInteractionEnabled = false
        boxView.translatesAutoresizingMaskIntoConstraints = false
        boxView.addSubview(focusedBackgroundView)
        boxView.addSubview(dashedBorderView)
        boxView.addSubview(textView)
        boxView.addSubview(placeholderLabel)
        let heightConstraint = textView.heightAnchor.constraint(equalToConstant: Self.minTextHeight)
        heightConstraint.isActive = true
        textViewHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            focusedBackgroundView.topAnchor.constraint(equalTo: boxView.topAnchor),
            focusedBackgroundView.leadingAnchor.constraint(equalTo: boxView.leadingAnchor),
            focusedBackgroundView.trailingAnchor.constraint(equalTo: boxView.trailingAnchor),
            focusedBackgroundView.bottomAnchor.constraint(equalTo: boxView.bottomAnchor),
            dashedBorderView.topAnchor.constraint(equalTo: boxView.topAnchor),
            dashedBorderView.leadingAnchor.constraint(equalTo: boxView.leadingAnchor),
            dashedBorderView.trailingAnchor.constraint(equalTo: boxView.trailingAnchor),
            dashedBorderView.bottomAnchor.constraint(equalTo: boxView.bottomAnchor),
            textView.topAnchor.constraint(equalTo: boxView.topAnchor),
            textView.leadingAnchor.constraint(equalTo: boxView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: boxView.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: boxView.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: boxView.leadingAnchor, constant: 12),
            placeholderLabel.topAnchor.constraint(equalTo: boxView.topAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: boxView.trailingAnchor, constant: -12),
        ])

        chipsScrollView.translatesAutoresizingMaskIntoConstraints = false
        chipsScrollView.showsHorizontalScrollIndicator = false
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsStack.axis = .horizontal
        chipsStack.spacing = BearySpace.sm
        chipsStack.alignment = .center
        chipsScrollView.addSubview(chipsStack)
        NSLayoutConstraint.activate([
            chipsStack.topAnchor.constraint(equalTo: chipsScrollView.topAnchor),
            chipsStack.leadingAnchor.constraint(equalTo: chipsScrollView.leadingAnchor),
            chipsStack.trailingAnchor.constraint(equalTo: chipsScrollView.trailingAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScrollView.bottomAnchor),
            chipsStack.heightAnchor.constraint(equalToConstant: 48),
        ])
        chipsScrollView.isHidden = true

        // 工具行默认收起，聚焦时展开（6 钮：图片、定位、表情、标签、@、引用；
        // 图标复用编辑器同款；发布钮在行末）。
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        toolRow.axis = .horizontal
        toolRow.spacing = BearySpace.xl
        toolRow.alignment = .center
        toolRow.addArrangedSubview(makeToolButton(iconName: "icon_image", label: NSLocalizedString("timeline.composer.add_image", comment: ""), action: #selector(didTapImageTool)))
        toolRow.addArrangedSubview(makeToolButton(locationIcon: true, label: NSLocalizedString("timeline.composer.add_location", comment: ""), action: #selector(didTapLocationTool)))
        toolRow.addArrangedSubview(makeToolButton(iconName: "icon_mood", label: NSLocalizedString("timeline.composer.add_emote", comment: ""), action: #selector(didTapEmoteTool)))
        toolRow.addArrangedSubview(makeTagToolButton())
        toolRow.addArrangedSubview(makeToolButton(iconName: "icon_at", label: NSLocalizedString("timeline.composer.mention", comment: ""), action: #selector(didTapRecipientTool)))
        toolRow.addArrangedSubview(makeToolButton(iconName: "icon_quote", label: NSLocalizedString("timeline.composer.quote", comment: ""), action: #selector(didTapQuoteTool)))
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        toolRow.addArrangedSubview(spacer)
        let publishButtonHeight: CGFloat = 32
        publishButton.translatesAutoresizingMaskIntoConstraints = false
        publishButton.setTitle(NSLocalizedString("timeline.composer.publish", comment: ""), for: .normal)
        publishButton.titleLabel?.font = BearyDynamicType.sectionTitleFont()
        publishButton.titleLabel?.adjustsFontForContentSizeCategory = true
        publishButton.layer.cornerRadius = publishButtonHeight / 2
        publishButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: BearySpace.lg, bottom: 0, right: BearySpace.lg)
        publishButton.addTarget(self, action: #selector(didTapPublish), for: .touchUpInside)
        publishButton.bearyAddPressFeedback()
        toolRow.addArrangedSubview(publishButton)
        NSLayoutConstraint.activate([
            publishButton.heightAnchor.constraint(equalToConstant: publishButtonHeight),
        ])
        toolRow.isHidden = true
        updatePublishButton()

        let stack = UIStackView(arrangedSubviews: [dateLabel, boxView, chipsScrollView, toolRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = BearySpace.sm
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateDateLabel()
        updatePlaceholder()
    }

    private func makeToolButton(iconName: String, label: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: iconName, pointSize: 24), for: .normal)
        button.tintColor = BearyColors.ink
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    private func makeToolButton(locationIcon: Bool, label: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyLocationIcon.image(pointSize: 24), for: .normal)
        button.tintColor = BearyColors.ink
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    private func makeTagToolButton() -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("#", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold) // beary-lint: allow
        button.setTitleColor(BearyColors.ink, for: .normal)
        button.accessibilityLabel = NSLocalizedString("timeline.composer.add_tag", comment: "")
        button.addTarget(self, action: #selector(didTapTagTool), for: .touchUpInside)
        button.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    // MARK: - 选中日同步（VC 调）

    /// 选中日变化时同步日期行、提示语与可写态（未来日锁住写不了）。
    func updateDay(selectedDayKey: String?, hasEntries: Bool, isFuture: Bool) {
        self.selectedDayKey = selectedDayKey
        self.dayHasEntries = hasEntries
        self.isFutureDay = isFuture
        textView.isEditable = !isFuture
        if isFuture {
            textView.resignFirstResponder()
        }
        updateDateLabel()
        updatePlaceholder()
    }

    private func parsedSelectedDay() -> (year: Int, month: Int, day: Int)? {
        guard let key = selectedDayKey else { return nil }
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return (year, month, day)
    }

    private func weekdayName(year: Int, month: Int, day: Int) -> String {
        guard let date = BearyBeijingDay.date(year: year, month: month, day: day) else { return "" }
        let weekday = BearyBeijingDay.calendar.component(.weekday, from: date)
        let names = [NSLocalizedString("timeline.weekday.sun", comment: ""), NSLocalizedString("timeline.weekday.mon", comment: ""), NSLocalizedString("timeline.weekday.tue", comment: ""), NSLocalizedString("timeline.weekday.wed", comment: ""), NSLocalizedString("timeline.weekday.thu", comment: ""), NSLocalizedString("timeline.weekday.fri", comment: ""), NSLocalizedString("timeline.weekday.sat", comment: "")]
        guard weekday >= 1, weekday <= 7 else { return "" }
        return String(format: NSLocalizedString("timeline.date.weekday", comment: ""), names[weekday - 1])
    }

    /// 日期行：今天→“今天 · 11月21日 · 周五”；昨天→“昨天 · 11月20日 · 周四”；
    /// 其他→“11月18日 · 周二”。中文硬编码（与 #2092 本地化支衔接）。
    private func updateDateLabel() {
        guard let day = parsedSelectedDay() else {
            dateLabel.text = ""
            return
        }
        let weekday = weekdayName(year: day.year, month: day.month, day: day.day)
        let monthDay = String(format: NSLocalizedString("timeline.date.month_day", comment: ""), day.month, day.day)
        if let today = BearyBeijingDay.todayComponents(),
           today.year == day.year && today.month == day.month && today.day == day.day {
            dateLabel.text = String(format: NSLocalizedString("timeline.date.today", comment: ""), monthDay, weekday)
            return
        }
        if let today = BearyBeijingDay.todayComponents(),
           let yesterday = BearyBeijingDay.shifted(year: today.year, month: today.month, day: today.day, byDays: -1),
           yesterday.year == day.year && yesterday.month == day.month && yesterday.day == day.day {
            dateLabel.text = String(format: NSLocalizedString("timeline.date.yesterday", comment: ""), monthDay, weekday)
            return
        }
        dateLabel.text = String(format: NSLocalizedString("timeline.date.plain", comment: ""), monthDay, weekday)
    }

    /// 提示语随那天变：未来日锁住；那天已有日记提示再补一笔；今天没写
    /// 「今天还没写日记哦」；过去某天没写「这天还没写，补一篇日记？」。
    private func updatePlaceholder() {
        if isFutureDay {
            placeholderLabel.text = NSLocalizedString("timeline.composer.placeholder_future", comment: "")
        } else if dayHasEntries {
            placeholderLabel.text = NSLocalizedString("timeline.composer.placeholder_add", comment: "")
        } else if let today = BearyBeijingDay.todayComponents(),
                  let day = parsedSelectedDay(),
                  today.year == day.year && today.month == day.month && today.day == day.day {
            placeholderLabel.text = NSLocalizedString("timeline.composer.placeholder_empty_today", comment: "")
        } else {
            placeholderLabel.text = NSLocalizedString("timeline.composer.placeholder_empty_day", comment: "")
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    // MARK: - 发布

    private var canPublish: Bool {
        if isPublishing { return false }
        if !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !imageItems.isEmpty
    }

    private func updatePublishButton() {
        let enabled = canPublish
        publishButton.isEnabled = enabled
        // 写字才亮橙，平时灰（只改底色与字色，不动布局）。
        publishButton.backgroundColor = enabled ? BearyColors.orange : BearyColors.surface2
        publishButton.setTitleColor(enabled ? .white : BearyColors.gray, for: .normal)
    }

    @objc private func didTapPublish() {
        guard canPublish else { return }
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = BearyInlineComposerDraft(
            text: text,
            images: imageItems.map { BearyPublishImage(localFile: $0.localFile, serverKey: nil, liveVideoKey: nil, liveVideoFile: nil, liveVideoData: nil) },
            imageLocalFiles: imageItems.map { $0.localFile },
            quoteId: selectedQuote?.id,
            mentionedUserId: mentionedUser?.id,
            tags: selectedTags,
            location: selectedLocation
        )
        isPublishing = true
        onPublish?(draft)
    }

    /// 发布成功后 VC 调：清空全部内容，恢复闲置态。
    func reset() {
        textView.text = ""
        imageItems = []
        gifKeys = []
        selectedLocation = nil
        selectedTags = []
        mentionedUser = nil
        selectedQuote = nil
        isPublishing = false
        textView.resignFirstResponder()
        toolRow.isHidden = true
        focusedBackgroundView.alpha = 0
        rebuildChips()
        updatePlaceholder()
        updatePublishButton()
        updateTextViewHeight()
        onHeightChanged?()
    }

    // MARK: - UITextViewDelegate

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        // 游客点速写器走登录页（不进输入态）。
        if SessionManager.shared.currentUser == nil {
            onRequireLogin?()
            return false
        }
        return true
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        composerFocused = true
        toolRow.isHidden = false
        UIView.animate(withDuration: BearyMotion.micro, animations: {
            self.focusedBackgroundView.alpha = 1
        })
        onFocusChanged?(true)
        onHeightChanged?()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        composerFocused = false
        // 内容全空时工具行收起；有内容时留着（用户点发布不用再聚焦）。
        if textView.text.isEmpty && imageItems.isEmpty && gifKeys.isEmpty
            && selectedLocation == nil && selectedTags.isEmpty
            && mentionedUser == nil && selectedQuote == nil {
            toolRow.isHidden = true
        }
        UIView.animate(withDuration: BearyMotion.micro, animations: {
            self.focusedBackgroundView.alpha = 0
        })
        onFocusChanged?(false)
        onHeightChanged?()
    }

    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
        updatePublishButton()
        updateTextViewHeight()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // 粘贴图片拦截（同 #2090 口径）："图片请用图片按钮添加"。
        // 图片粘贴以附件字符 U+FFFC 进来；纯文字粘贴不受影响。
        if text.contains("\u{FFFC}") {
            onToast?(NSLocalizedString("composer.paste_image_use_button", comment: ""))
            return false
        }
        return true
    }

    private func updateTextViewHeight() {
        guard textView.bounds.width > 0 else { return }
        textView.isScrollEnabled = false
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        let target = min(max(fitting.height, Self.minTextHeight), Self.maxTextHeight)
        textView.isScrollEnabled = fitting.height > Self.maxTextHeight
        guard let constraint = textViewHeightConstraint, abs(constraint.constant - target) > 0.5 else { return }
        constraint.constant = target
        onHeightChanged?()
    }

    private func insertTextAtCursor(_ text: String) {
        if !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        textView.insertText(text)
    }

    // MARK: - 工具行

    private var remainingImageSlots: Int {
        max(Self.maxImages - imageItems.count - gifKeys.count, 0)
    }

    @objc private func didTapImageTool() {
        // 9 图上限：照片条＋已插 GIF 合计满 9 即拦（编辑器同口径）。
        if remainingImageSlots <= 0 {
            onToast?(NSLocalizedString("timeline.toast.max_images", comment: ""))
            return
        }
        var config = PHPickerConfiguration()
        // 内联版只接静态图（不接实况视频）。
        config.filter = .images
        config.selectionLimit = remainingImageSlots
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: BearyMotion.animated(true))
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: BearyMotion.animated(true))
        for result in results {
            if imageItems.count + gifKeys.count >= Self.maxImages { break }
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let self = self, let image = object as? UIImage else { return }
                DispatchQueue.main.async {
                    self.addPickedImage(image)
                }
            }
        }
    }

    private func addPickedImage(_ image: UIImage) {
        guard imageItems.count + gifKeys.count < Self.maxImages else {
            onToast?(NSLocalizedString("timeline.toast.max_images", comment: ""))
            return
        }
        // 落盘口径同编辑器：长边 1600、q0.92 原图＋480 缩略图，账号版落盘。
        guard let jpeg = BearyImagePrep.jpegData(image),
              let thumb = BearyImagePrep.thumbData(image),
              let localFile = BearyDraftImageStore.save(
                fullData: jpeg.data, thumbData: thumb,
                forAccount: SessionManager.shared.currentUser?.id ?? BearyDraftStore.currentAccountId) else {
            onToast?(NSLocalizedString("timeline.toast.image_save_failed", comment: ""))
            return
        }
        imageItems.append((localFile: localFile, image: image))
        rebuildChips()
        updatePublishButton()
        onHeightChanged?()
    }

    @objc private func didTapLocationTool() {
        guard let presenter = presenter else { return }
        BearyLocationPicker.show(from: presenter, currentLocation: selectedLocation) { [weak self] location in
            self?.selectedLocation = location
            self?.rebuildChips()
            self?.onHeightChanged?()
        } onClear: { [weak self] in
            self?.selectedLocation = nil
            self?.rebuildChips()
            self?.onHeightChanged?()
        }
    }

    @objc private func didTapEmoteTool() {
        guard let presenter = presenter else { return }
        BearyMoodPickerSheet.show(from: presenter, gifKeys: BearyGIFLibrary.cachedKeys()) { [weak self] key in
            guard let self = self else { return }
            // 已插 GIF 也占 1 张（照片条＋已插 GIF 合计满 9 即拦，编辑器同口径）。
            if self.imageItems.count + self.gifKeys.count >= Self.maxImages {
                self.onToast?(NSLocalizedString("timeline.toast.max_images", comment: ""))
                return
            }
            if !self.gifKeys.contains(key) {
                self.gifKeys.append(key)
            }
            self.insertTextAtCursor("[gif:\(key)] ")
            self.updatePublishButton()
        } onUploadGIF: { [weak self] in
            // 自定义表情上传不做：请去写日记页（见 PR 说明）。
            self?.onToast?(NSLocalizedString("timeline.toast.custom_emote_composer_only", comment: ""))
        }
    }

    @objc private func didTapTagTool() {
        guard let presenter = presenter else { return }
        BearyTagPicker.show(from: presenter, selected: selectedTags) { [weak self] tags in
            self?.selectedTags = tags
            self?.rebuildChips()
            self?.onHeightChanged?()
        }
    }

    @objc private func didTapRecipientTool() {
        guard let presenter = presenter else { return }
        let picker = BearyRecipientPickerViewController()
        picker.onPick = { [weak self] user in
            guard let self = self else { return }
            self.mentionedUser = user
            if let handle = user.handle, !handle.isEmpty {
                self.insertTextAtCursor("@\(handle) ")
            }
            self.rebuildChips()
            self.onHeightChanged?()
        }
        presenter.present(picker, animated: BearyMotion.animated(true))
    }

    @objc private func didTapQuoteTool() {
        guard let presenter = presenter else { return }
        let picker = BearyInlineQuotePickerViewController()
        picker.onPick = { [weak self] entry in
            self?.selectedQuote = entry
            self?.rebuildChips()
            self?.onHeightChanged?()
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .pageSheet
        presenter.present(nav, animated: BearyMotion.animated(true))
    }

    // MARK: - chips 行

    private func rebuildChips() {
        for view in chipsStack.arrangedSubviews {
            chipsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, item) in imageItems.enumerated() {
            chipsStack.addArrangedSubview(makeImageChip(item: item, index: index))
        }
        if let location = selectedLocation, !(location.name ?? "").isEmpty {
            chipsStack.addArrangedSubview(makeTextChip(title: location.name ?? "", action: #selector(didTapClearLocationChip)))
        }
        for (index, tag) in selectedTags.enumerated() {
            let chip = makeTextChip(title: "#\(tag)", action: #selector(didTapRemoveTagChip(_:)))
            chip.tag = index
            chipsStack.addArrangedSubview(chip)
        }
        if let user = mentionedUser, let handle = user.handle, !handle.isEmpty {
            chipsStack.addArrangedSubview(makeTextChip(title: "@\(handle)", action: #selector(didTapClearMentionChip)))
        }
        if let quote = selectedQuote {
            let title = (quote.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = title.isEmpty ? NSLocalizedString("timeline.quote.quoted", comment: "") : String(format: NSLocalizedString("timeline.quote.with_title", comment: ""), title)
            chipsStack.addArrangedSubview(makeTextChip(title: label, action: #selector(didTapClearQuoteChip)))
        }
        chipsScrollView.isHidden = chipsStack.arrangedSubviews.isEmpty
    }

    private func makeImageChip(item: (localFile: String, image: UIImage), index: Int) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let imageView = UIImageView(image: item.image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        container.addSubview(imageView)
        let deleteButton = UIButton(type: .system)
        let deleteButtonHeight: CGFloat = 20
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        deleteButton.tintColor = BearyColors.gray
        deleteButton.backgroundColor = BearyColors.surface1
        deleteButton.layer.cornerRadius = deleteButtonHeight / 2
        deleteButton.accessibilityLabel = NSLocalizedString("timeline.image.delete", comment: "")
        deleteButton.tag = index
        deleteButton.addTarget(self, action: #selector(didTapRemoveImageChip(_:)), for: .touchUpInside)
        container.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 48),
            container.heightAnchor.constraint(equalToConstant: 48),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 20),
            deleteButton.heightAnchor.constraint(equalToConstant: deleteButtonHeight),
            deleteButton.topAnchor.constraint(equalTo: container.topAnchor, constant: -4),
            deleteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 4),
        ])
        return container
    }

    private func makeTextChip(title: String, action: Selector) -> UIButton {
        let chip = UIButton(type: .system)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setTitle(String(format: NSLocalizedString("timeline.chip.title_format", comment: ""), title), for: .normal)
        chip.titleLabel?.font = BearyDynamicType.secondaryFont()
        chip.titleLabel?.adjustsFontForContentSizeCategory = true
        chip.setTitleColor(BearyColors.ink, for: .normal)
        chip.backgroundColor = BearyColors.surface2
        chip.layer.cornerRadius = BearyCorners.single
        chip.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10) // beary-lint: allow
        chip.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 24),
        ])
        return chip
    }

    @objc private func didTapRemoveImageChip(_ sender: UIButton) {
        guard sender.tag < imageItems.count else { return }
        imageItems.remove(at: sender.tag)
        rebuildChips()
        updatePublishButton()
        onHeightChanged?()
    }

    @objc private func didTapClearLocationChip() {
        selectedLocation = nil
        rebuildChips()
        onHeightChanged?()
    }

    @objc private func didTapRemoveTagChip(_ sender: UIButton) {
        guard sender.tag < selectedTags.count else { return }
        selectedTags.remove(at: sender.tag)
        rebuildChips()
        onHeightChanged?()
    }

    @objc private func didTapClearMentionChip() {
        mentionedUser = nil
        rebuildChips()
        onHeightChanged?()
    }

    @objc private func didTapClearQuoteChip() {
        selectedQuote = nil
        rebuildChips()
        onHeightChanged?()
    }
}

// MARK: - 写一笔引用选择器（v14 改版轻量版）

/// 最近 50 篇（scope=timeline），行显示标题/正文片段＋日期；pageSheet＋取消钮。
/// 编辑器的 BearyQuoteSheetViewController 深嵌编辑器，不可复用。
final class BearyInlineQuotePickerViewController: UITableViewController {

    var onPick: ((Entry) -> Void)?
    private var entries: [Entry] = []
    private var loadFailed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("timeline.composer.quote", comment: "")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(didTapCancel))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let list):
                    self.entries = list.entries ?? []
                    self.loadFailed = false
                case .failure:
                    self.entries = []
                    self.loadFailed = true
                }
                self.tableView.reloadData()
            }
        }
    }

    @objc private func didTapCancel() {
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        loadFailed ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        if loadFailed {
            config.text = NSLocalizedString("timeline.load_failed_retry", comment: "")
            config.secondaryText = nil
            cell.contentConfiguration = config
            return cell
        }
        let entry = entries[indexPath.row]
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            config.text = title
        } else {
            let snippet = (entry.content ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            config.text = snippet.isEmpty ? NSLocalizedString("timeline.snippet.empty", comment: "") : String(snippet.prefix(40))
        }
        if let createdMs = entry.createdAt,
           let comps = BearyBeijingDay.components(ofMs: createdMs) {
            config.secondaryText = String(format: NSLocalizedString("timeline.date.month_day", comment: ""), comps.month, comps.day)
        } else {
            config.secondaryText = nil
        }
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loadFailed, indexPath.row < entries.count else { return }
        let entry = entries[indexPath.row]
        dismiss(animated: true) { [weak self] in
            self?.onPick?(entry)
        }
    }
}
