import UIKit

// ===== beary 新手引导 v4（预览简洁精致版，原生实现）=====
// 设计基准：使用指南预览 Space（beary-shi-yong-zhi-nan-zhong-xin-she-ji-yu-lan，
// 2026-11-16 05:44 构建，简洁精致版＋裁切已修；Li 2026-11-18 定按预览做 App 实现）。
// 与 v3 的主要变化：顶栏四段细进度 → 四圆点（当前页 20pt 长胶囊）；底部圆角卡片
// 改为标题区（页码＋衬线标题＋副文案，左对齐）＋底部按钮区（墨色 99px 胶囊主钮
// 52 高＋仅第 4 页的次钮）；演示卡改为预览同款（日期＋可见性胶囊＋占位灰线）；
// 第 2 页可见性列表改为静态三行；第 3 页回应钮 56 圆＋分段切换联动胶囊；第 4 页
// 庆祝熊＋闪烁光标＋点主钮盖橙色印章；「跳过」直达第 4 页（不再直接退出）。
// 公开契约（与 v3 相同，SceneDelegate 不动）：
// - final class BearyOnboardingViewController: UIViewController
// - enum Mode { firstLaunch, replay }，init(mode: Mode)
// - static let seenKey = "beary_onboarding_v3_seen"（key 不变，不重播给已看过的人）
// - 四个可选闭包 onRequestLogin / onRequestGuestBrowse / onRequestCompose / onRequestBrowse：
//   触发时只回调、不自行 dismiss，dismiss 由 SceneDelegate 控制；闭包未设置时才回退为
//   写 seenKey + 自行 dismiss（兜底）。
// - seenKey 归属：闭包已设置时写 key 是容器的责任；本页只在闭包未设置的兜底路径
//   自己写。跳过不再写 key（只翻到第 4 页），退出只走第 4 页主／次钮回调（容器写 key）。
// - 下滑关闭不存在：isModalInPresentation = true 全程禁下滑关闭。
// - 本页不调任何写接口、不改用户默认设置；第 2 页演示为静态，第 3 页只改本地演示态，
//   不产生真实回应、不发布。
// - 演示卡日期为当天动态日期（北京时间，M月d日 · 星期X）；预览写死的 11月16日 只是示例。
// - 图标一律官方资产（icon_lock／icon_globe／icon_clock／icon_check／icon_back），
//   不用 emoji；小熊用 hug／cheer 官方表情资产，不自绘。
// - 衬线只用于页标题（26 bold，规范已定）与第 1 页卡内提示（20 semibold，预览同款）；
//   其余一律系统字体。
// - 动效口径走规范 §6：翻页落点弹簧 0.26s／damping 0.7，拖过页宽 1/3 或速度 ＞600pt/s
//   翻页；标题换页上浮淡入 0.3s；第 3 页回应钮点选 pop 0.5s；第 4 页盖章弹簧 0.35s。
// - 小熊与印章不裁切：演示区容器不设 clipsToBounds，印章允许落在卡片角上。

// MARK: - 动效与布局常量（文件内私有）

private enum OnboardingAnim {
    /// 互动翻页落点弹簧（规范 §6 引导专属档）：0.26s／damping 0.7；快甩把松手速度
    /// 按页宽归一化后传 initialSpringVelocity，慢拖为 0。
    static let pageSpringDuration: TimeInterval = BearyMotion.normal
    static let pageSpringDamping: CGFloat = 0.7
    /// 松手判据：拖过页宽 1/3，或沿翻页方向速度 ＞600pt/s。
    static let pageCommitFraction: CGFloat = 1.0 / 3.0
    static let pageFlingVelocity: CGFloat = 600
    /// 入场错峰间隔；总入场 0.5 秒内（0.09 末位延迟 + 0.26 播长 = 0.35）。
    static let staggerStep: TimeInterval = 0.03
    static let entranceDuration: TimeInterval = BearyMotion.normal
    /// 标题换页上浮淡入（预览口径）：0.3s。
    static let titleChangeDuration: TimeInterval = 0.3
    /// 第 3 页回应钮点选 pop（预览口径）：0.5s。
    static let emotePopDuration: TimeInterval = 0.5
    /// 第 4 页盖章回弹（预览口径）：0.35s。
    static let stampDuration: TimeInterval = 0.35
    /// 第 4 页盖章后停留再跳转：0.4s。
    static let stampSettleDelay: TimeInterval = 0.4
    /// 第 4 页光标闪烁半周期（预览口径周期 1.1s，往返半周期 0.55s）。
    static let cursorBlinkHalfPeriod: TimeInterval = 0.55
}

// MARK: - 圆角 pill 容器（pill 共用：圆角恒为半高，深浅与字号变化时自动跟随）

private final class OnboardingPillView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

// MARK: - 可见范围演示态（第 2 页静态列表与第 3 页分段切换共用）

private enum OnboardingVisibilityDemo: Int, CaseIterable {
    case `private` = 0
    case friendsOnly = 1
    case `public` = 2
    case ephemeral = 3

    /// 官方图标资产名（beary-ui，仓库已核实）。
    var iconName: String {
        switch self {
        case .private: return "icon_lock"
        case .friendsOnly: return "icon_friends_lock"
        case .public: return "icon_globe"
        case .ephemeral: return "icon_limited"
        }
    }

    var title: String {
        switch self {
        case .private: return "私密"
        case .friendsOnly: return "仅好友"
        case .public: return "公开"
        case .ephemeral: return "限时"
        }
    }

    /// 副文案：限时一句以编辑器源码为准（BearyComposerViewController ephemeralSubtitleLabel），不得编造。
    var subtitle: String {
        switch self {
        case .private: return "仅自己可见"
        case .friendsOnly: return "仅互关好友可见"
        case .public: return "所有人可见"
        case .ephemeral: return "公开 24 小时后自动转私密"
        }
    }

    /// 状态标签：私密／限时蓝 pill、公开橙 pill；仅好友墨字灰边 pill（规范：仅好友 pill 墨字灰底）。
    var pillColor: UIColor {
        switch self {
        case .private: return BearyColors.blue
        case .friendsOnly: return BearyColors.gray
        case .public: return BearyColors.orange
        case .ephemeral: return BearyColors.blue
        }
    }

    var explain: String { subtitle }
}

// MARK: - 引导容器

final class BearyOnboardingViewController: UIViewController, UIGestureRecognizerDelegate {
    static let seenKey = "beary_onboarding_v3_seen"

    enum Mode { case firstLaunch, replay }

    let mode: Mode
    var onRequestLogin: (() -> Void)?
    var onRequestGuestBrowse: (() -> Void)?
    var onRequestCompose: (() -> Void)?
    var onRequestBrowse: (() -> Void)?

    // MARK: - 翻页状态机（按钮与互动拖动共用；动画只改 transform 与 opacity）

    private var currentPage = 0
    private var isTransitioning = false
    private var pendingPage: Int?
    // 互动拖动进行态：nil＝未开始／已结束；等于 currentPage＝越界方向
    // （首尾页外拖），其余值＝拖向的目标页。
    private var dragTargetPage: Int?
    private var dragTranslation: CGFloat = 0
    private var finished = false
    private var entrancePlayedPages: Set<Int> = []
    private var lastDotPage: Int?

    // 第 3 页演示态（只记本地选择，不产生真实回应；默认抱抱选中，预览口径）。
    private var selectedEmote: String = "hug"
    // 第 3 页分段切换演示态（默认私密；只改示例，不调写接口、不改用户默认设置）。
    private var selectedVisibility: OnboardingVisibilityDemo = .private

    // 第 4 页盖章态。
    private var stampShown = false
    private var pageFourPrimaryPending = false
    private var cursorBlinking = false

    // MARK: - 骨架视图

    private let topWrap = UIView()
    private let backButton = BearyHit44Button(type: .system)
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private var dotWidthConstraints: [NSLayoutConstraint] = []
    private let skipButton = BearyHit44Button(type: .system)
    private let demoScroll = UIScrollView()
    private let demoContent = UIView()
    private let columnView = UIView()
    /// 演示区引导（demoContent 顶部 → 底部）：短内容时示例区在该区内居中，
    /// 长内容时整页滚动、卡片跟内容走。
    private let demoAreaGuide = UILayoutGuide()
    private let titlePanel = UIView()
    private let titleStack = UIStackView()
    private let pageNumberLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionsView = UIView()
    private let actionsStack = UIStackView()
    private let primaryButton = BearyHit44Button(type: .system)
    private let secondaryButton = BearyHit44Button(type: .system)

    // 600 居中上限（宽 ≥821 才激活，≤820 停用；口径同 BearyDetailViewController）。
    private var topCap: NSLayoutConstraint?
    private var columnCap: NSLayoutConstraint?
    private var titleCap: NSLayoutConstraint?
    private var actionsCap: NSLayoutConstraint?

    // 四页视图及其边缘约束（同一时刻只激活当前页的一组，避免多页高度冲突）。
    private var pageViews: [UIView] = []
    private var pageEdgeConstraints: [[NSLayoutConstraint]] = []

    // 第 1 页元素（入场错峰用）。
    private let pageOneBearWrap = UIView()
    private var pageOneCard: UIView?
    private var pageOneRuleWrap: UIView?

    // 演示卡片（描边为动态色，深浅切换时由 refreshDynamicBorders 重刷）。
    private var demoCards: [UIView] = []

    // 第 3 页元素。
    private var emoteButtons: [String: UIButton] = [:]
    private var emoteViews: [String: BearyEmoteView] = [:]
    private var capsulePill: OnboardingPillView?
    private var capsuleIconView: UIImageView?
    private var capsuleLabel: UILabel?
    private var switchButtons: [OnboardingVisibilityDemo: UIButton] = [:]
    private var switchLabels: [OnboardingVisibilityDemo: UILabel] = [:]
    private var switchUnderlines: [OnboardingVisibilityDemo: UIView] = [:]
    private var switchExplainLabel: UILabel?

    // 第 4 页元素。
    private var cheerBearHeight: NSLayoutConstraint?
    private var cursorView: UIView?
    private var stampView: UIView?
    private var stampImageView: UIImageView?

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        isModalInPresentation = true
        buildChrome()
        buildPages()
        // 首帧即落在第 0 页（无动画）；第 1 页入场错峰在 viewDidAppear 播，避免首帧闪现终态。
        showPageImmediately(0)
        if !UIAccessibility.isReduceMotionEnabled {
            preparePageOneEntrance()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playEntranceIfNeeded(0)
        refreshPageFourCursor()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopAllEmotes()
        stopCursorBlink()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 821 断点：仅 iPad 且宽 ≥821 时 600 上限激活、内容居中；其余停用、可用宽度＋边距撑满。
        let wantCap = BearyDesktop.isWide(view.bounds.width)
        if topCap?.isActive != wantCap { topCap?.isActive = wantCap }
        if columnCap?.isActive != wantCap { columnCap?.isActive = wantCap }
        if titleCap?.isActive != wantCap { titleCap?.isActive = wantCap }
        if actionsCap?.isActive != wantCap { actionsCap?.isActive = wantCap }
        // 矮屏庆祝熊 112pt，其余 148pt（预览口径：≤720pt 矮屏）。
        let shortScreen = view.bounds.height <= 720
        let target: CGFloat = shortScreen ? 112 : 148
        if let height = cheerBearHeight, height.constant != target {
            height.constant = target
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        // 动态色背景自动跟随；CGColor 快照的边框须手动重刷；印章静态图按深浅重取。
        refreshDynamicBorders()
        if let stampImageView = stampImageView {
            stampImageView.image = BearyEmoteImages.image(for: "hug", dark: traitCollection.userInterfaceStyle == .dark)
        }
    }

    // MARK: - 字体口径（仓库既有：BearyDynamicType.scaledFont / cappedFont）

    private func scaledFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        return BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight))
    }

    /// 衬线字体（展示型大标题与卡内提示用，UIFontDescriptor.withDesign(.serif)，不装字体）。
    private func serifFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let serifDescriptor = base.fontDescriptor.withDesign(.serif) {
            return BearyDynamicType.scaledFont(for: UIFont(descriptor: serifDescriptor, size: size))
        }
        return BearyDynamicType.scaledFont(for: base)
    }

    /// 字距＋可选行高的属性文案（页码、副文案、主钮标题用）。
    private func kernedText(_ text: String, font: UIFont, color: UIColor, kern: CGFloat, lineHeightMultiple: CGFloat? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        if let multiple = lineHeightMultiple { paragraph.lineHeightMultiple = multiple }
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
            .paragraphStyle: paragraph,
        ])
    }

    private func makeLabel(size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor, alignment: NSTextAlignment = .left) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = scaledFont(size: size, weight: weight)
        label.textColor = color
        label.textAlignment = alignment
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    // MARK: - 骨架搭建

    private func buildChrome() {
        // 顶栏：返回（第 2 页起才可用，第 1 页占位透明，圆点保持居中）＋ 四圆点 ＋ 跳过。
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 32), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回上一页"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()

        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.axis = .horizontal
        dotsStack.spacing = 7
        dotsStack.alignment = .center
        dotsStack.isAccessibilityElement = true
        dotsStack.accessibilityLabel = "第 1 页，共 4 页"
        for _ in 0..<4 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 3
            dot.backgroundColor = BearyColors.line
            dotsStack.addArrangedSubview(dot)
            dotViews.append(dot)
            let width = dot.widthAnchor.constraint(equalToConstant: 6)
            width.isActive = true
            dotWidthConstraints.append(width)
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }

        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.setTitle("跳过", for: .normal)
        skipButton.setTitleColor(BearyColors.gray, for: .normal)
        skipButton.setTitleColor(BearyColors.gray, for: .highlighted)
        skipButton.contentHorizontalAlignment = .right
        skipButton.titleLabel?.font = scaledFont(size: 13)
        skipButton.titleLabel?.adjustsFontForContentSizeCategory = true
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        skipButton.bearyAddPressFeedback()

        let topStack = UIStackView(arrangedSubviews: [backButton, dotsStack, skipButton])
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 12
        topWrap.translatesAutoresizingMaskIntoConstraints = false
        topWrap.addSubview(topStack)
        view.addSubview(topWrap)

        // 演示区在上（白底＝ BearyColors.bg）；高度不足时中部可滚动。
        demoScroll.translatesAutoresizingMaskIntoConstraints = false
        demoScroll.showsVerticalScrollIndicator = false
        demoScroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(demoScroll)
        demoContent.translatesAutoresizingMaskIntoConstraints = false
        demoScroll.addSubview(demoContent)
        columnView.translatesAutoresizingMaskIntoConstraints = false
        demoContent.addSubview(columnView)

        // 标题区：页码＋衬线标题＋副文案，左对齐（预览口径）。
        titlePanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titlePanel)
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.axis = .vertical
        titleStack.alignment = .fill
        titlePanel.addSubview(titleStack)
        pageNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        pageNumberLabel.textColor = BearyColors.gray
        pageNumberLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = serifFont(size: 26, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .left
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.textAlignment = .left
        subtitleLabel.numberOfLines = 0
        subtitleLabel.adjustsFontForContentSizeCategory = true
        titleStack.addArrangedSubview(pageNumberLabel)
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)
        titleStack.setCustomSpacing(6, after: pageNumberLabel)
        titleStack.setCustomSpacing(9, after: titleLabel)

        // 底部按钮区：墨色胶囊主钮 52 高＋仅第 4 页的次钮（42 高占位，平时透明）。
        actionsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionsView)
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.axis = .vertical
        actionsStack.alignment = .fill
        actionsStack.spacing = 4
        actionsView.addSubview(actionsStack)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.backgroundColor = BearyColors.ink
        primaryButton.setTitleColor(BearyColors.bg, for: .normal)
        primaryButton.setTitleColor(BearyColors.bg, for: .highlighted)
        primaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        primaryButton.layer.cornerRadius = 26
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.bearyAddPressFeedback()
        actionsStack.addArrangedSubview(primaryButton)
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.setTitleColor(BearyColors.gray, for: .normal)
        secondaryButton.setTitleColor(BearyColors.gray, for: .highlighted)
        secondaryButton.titleLabel?.font = scaledFont(size: 13.5)
        secondaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        secondaryButton.bearyAddPressFeedback()
        actionsStack.addArrangedSubview(secondaryButton)

        // 互动翻页与按钮共用翻页状态机（UIPan 手势 1:1 跟手；点按仍走按钮，
        // 横滑接管后按钮触摸自动取消，不会误触）。竖滑留给 demoScroll：
        // 方向仲裁见 gestureRecognizerShouldBegin，demoScroll 的 pan 须等
        // 本手势失败才启动，避免横滑被滚动抢走（同回收站行拖动模式）。
        let pagePan = UIPanGestureRecognizer(target: self, action: #selector(onboardingPanned(_:)))
        pagePan.delegate = self
        view.addGestureRecognizer(pagePan)
        demoScroll.panGestureRecognizer.require(toFail: pagePan)

        demoContent.addLayoutGuide(demoAreaGuide)
        topCap = topWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        columnCap = columnView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        titleCap = titlePanel.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        actionsCap = actionsView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        NSLayoutConstraint.activate([
            topWrap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22).withPriority(.defaultHigh),
            topWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22).withPriority(.defaultHigh),
            topWrap.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -44).withPriority(.defaultHigh),
            topStack.topAnchor.constraint(equalTo: topWrap.topAnchor),
            topStack.leadingAnchor.constraint(equalTo: topWrap.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: topWrap.trailingAnchor),
            topStack.bottomAnchor.constraint(equalTo: topWrap.bottomAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            skipButton.widthAnchor.constraint(equalToConstant: 44),
            skipButton.heightAnchor.constraint(equalToConstant: 44),

            demoScroll.topAnchor.constraint(equalTo: topWrap.bottomAnchor),
            demoScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            demoScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            demoScroll.bottomAnchor.constraint(equalTo: titlePanel.topAnchor, constant: -8),

            demoContent.topAnchor.constraint(equalTo: demoScroll.contentLayoutGuide.topAnchor),
            demoContent.leadingAnchor.constraint(equalTo: demoScroll.contentLayoutGuide.leadingAnchor),
            demoContent.trailingAnchor.constraint(equalTo: demoScroll.contentLayoutGuide.trailingAnchor),
            demoContent.bottomAnchor.constraint(equalTo: demoScroll.contentLayoutGuide.bottomAnchor),
            demoContent.widthAnchor.constraint(equalTo: demoScroll.frameLayoutGuide.widthAnchor),
            demoContent.heightAnchor.constraint(greaterThanOrEqualTo: demoScroll.frameLayoutGuide.heightAnchor),

            columnView.topAnchor.constraint(greaterThanOrEqualTo: demoContent.topAnchor, constant: 8),
            columnView.bottomAnchor.constraint(lessThanOrEqualTo: demoContent.bottomAnchor, constant: -8),
            columnView.centerYAnchor.constraint(equalTo: demoAreaGuide.centerYAnchor).withPriority(.defaultLow),
            columnView.centerXAnchor.constraint(equalTo: demoContent.centerXAnchor),
            columnView.leadingAnchor.constraint(greaterThanOrEqualTo: demoContent.leadingAnchor, constant: 30).withPriority(.defaultHigh),
            columnView.trailingAnchor.constraint(lessThanOrEqualTo: demoContent.trailingAnchor, constant: -30).withPriority(.defaultHigh),
            columnView.widthAnchor.constraint(equalTo: demoContent.widthAnchor, constant: -60).withPriority(.defaultHigh),
            demoAreaGuide.topAnchor.constraint(equalTo: demoContent.topAnchor),
            demoAreaGuide.bottomAnchor.constraint(equalTo: demoContent.bottomAnchor),
            demoAreaGuide.leadingAnchor.constraint(equalTo: demoContent.leadingAnchor),
            demoAreaGuide.trailingAnchor.constraint(equalTo: demoContent.trailingAnchor),

            titlePanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titlePanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 30).withPriority(.defaultHigh),
            titlePanel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -30).withPriority(.defaultHigh),
            titlePanel.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -60).withPriority(.defaultHigh),
            titleStack.topAnchor.constraint(equalTo: titlePanel.topAnchor),
            titleStack.leadingAnchor.constraint(equalTo: titlePanel.leadingAnchor),
            titleStack.trailingAnchor.constraint(equalTo: titlePanel.trailingAnchor),
            titleStack.bottomAnchor.constraint(equalTo: titlePanel.bottomAnchor),

            actionsView.topAnchor.constraint(equalTo: titlePanel.bottomAnchor, constant: 20),
            actionsView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionsView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 30).withPriority(.defaultHigh),
            actionsView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -30).withPriority(.defaultHigh),
            actionsView.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -60).withPriority(.defaultHigh),
            actionsView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            actionsStack.topAnchor.constraint(equalTo: actionsView.topAnchor),
            actionsStack.leadingAnchor.constraint(equalTo: actionsView.leadingAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: actionsView.trailingAnchor),
            actionsStack.bottomAnchor.constraint(equalTo: actionsView.bottomAnchor),
            primaryButton.heightAnchor.constraint(equalToConstant: 52),
            secondaryButton.heightAnchor.constraint(equalToConstant: 42),
        ])
    }

    // MARK: - 四页搭建（预览同款演示，不复制四套布局样式）

    private func buildPages() {
        pageViews = [buildPageOne(), buildPageTwo(), buildPageThree(), buildPageFour()]
        for page in pageViews {
            page.translatesAutoresizingMaskIntoConstraints = false
            page.isHidden = true
            columnView.addSubview(page)
            let edges = [
                page.topAnchor.constraint(equalTo: columnView.topAnchor),
                page.leadingAnchor.constraint(equalTo: columnView.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: columnView.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: columnView.bottomAnchor),
            ]
            pageEdgeConstraints.append(edges)
        }
    }

    // MARK: - 演示卡共用件

    /// 演示日记卡（surface1 底、1px 细线边框、圆角 18、内边距 22／22／24，预览口径）。
    /// 返回卡片与内容栈；各页往内容栈里加演示元素。
    private func makeDemoCard() -> (card: UIView, content: UIStackView) {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.surface1
        card.layer.cornerRadius = 18
        card.layer.borderWidth = 1
        card.layer.bearyDynamicBorderColor = BearyColors.line
        let content = UIStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 10
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
        return (card, content)
    }

    /// 1px 细线分隔（深浅跟随 BearyColors.line）。
    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = BearyColors.line
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return divider
    }

    /// 演示卡顶行：左侧当天日期（12pt 灰）＋右侧可见性胶囊。
    private func makeDateRow(capsule: UIView) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        let dateLabel = makeLabel(size: 12, color: BearyColors.gray)
        dateLabel.text = todayDemoDateText()
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(dateLabel)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(capsule)
        return row
    }

    /// 可见性胶囊（官方图标＋11pt semibold 文字，1px 描边 pill，预览口径）。
    private func makeCapsule(demo: OnboardingVisibilityDemo) -> (pill: OnboardingPillView, iconView: UIImageView, label: UILabel) {
        let pill = OnboardingPillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.borderWidth = 1
        pill.layer.bearyDynamicBorderColor = BearyColors.alpha(demo.pillColor, 0.45)
        let inner = UIStackView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.axis = .horizontal
        inner.spacing = 4
        inner.alignment = .center
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: demo.iconName, pointSize: 12)
        iconView.tintColor = BearyColors.ink
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = scaledFont(size: 11, weight: .semibold)
        label.textColor = demo == .private ? BearyColors.blue : BearyColors.deepOrangeText
        label.text = demo.title
        label.adjustsFontForContentSizeCategory = true
        inner.addArrangedSubview(iconView)
        inner.addArrangedSubview(label)
        pill.addSubview(inner)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            inner.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            inner.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            inner.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            inner.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
        ])
        return (pill, iconView, label)
    }

    /// 占位灰线（高 5pt，宽为内容宽的指定比例，左对齐，surface2）。
    private func makePlaceholderLine(fraction: CGFloat) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = BearyColors.surface2
        line.layer.cornerRadius = 2.5
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 5),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            line.widthAnchor.constraint(equalTo: wrap.widthAnchor, multiplier: fraction),
        ])
        return wrap
    }

    /// 演示卡日期：当天动态日期（北京时间，M月d日 · 星期X）；预览写死的 11月16日 只是示例。
    private func todayDemoDateText() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let weekday = calendar.component(.weekday, from: now)
        let weekdayNames = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let weekdayName = weekdayNames[(weekday - 1 + weekdayNames.count) % weekdayNames.count]
        return "\(month)月\(day)日 · \(weekdayName)"
    }

    // MARK: - 第 1 页

    /// 第 1 页：抱抱熊＋演示日记卡＋居中橙色短线。
    private func buildPageOne() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 24
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        // 官方 hug 表情（静态帧，104×104，预览口径）。
        pageOneBearWrap.translatesAutoresizingMaskIntoConstraints = false
        let bearView = BearyEmoteView(key: "hug", animated: false)
        bearView.translatesAutoresizingMaskIntoConstraints = false
        bearView.isUserInteractionEnabled = false
        pageOneBearWrap.addSubview(bearView)
        NSLayoutConstraint.activate([
            bearView.centerXAnchor.constraint(equalTo: pageOneBearWrap.centerXAnchor),
            bearView.topAnchor.constraint(equalTo: pageOneBearWrap.topAnchor),
            bearView.bottomAnchor.constraint(equalTo: pageOneBearWrap.bottomAnchor),
            bearView.widthAnchor.constraint(equalToConstant: 104),
            bearView.heightAnchor.constraint(equalToConstant: 104),
        ])
        stack.addArrangedSubview(pageOneBearWrap)

        let (card, content) = makeDemoCard()
        pageOneCard = card
        demoCards.append(card)
        let (pill, _, _) = makeCapsule(demo: .private)
        let dateRow = makeDateRow(capsule: pill)
        content.addArrangedSubview(dateRow)
        // 卡内提示（20 semibold 衬线，预览同款；规范衬线 11 处只含页标题，此处跟预览走）。
        let prompt = makeLabel(size: 20, weight: .semibold, color: BearyColors.ink)
        prompt.font = serifFont(size: 20, weight: .semibold)
        prompt.text = "今天，想记住什么？"
        content.addArrangedSubview(prompt)
        let line1 = makePlaceholderLine(fraction: 1.0)
        let line2 = makePlaceholderLine(fraction: 0.75)
        let line3 = makePlaceholderLine(fraction: 0.45)
        content.addArrangedSubview(line1)
        content.addArrangedSubview(line2)
        content.addArrangedSubview(line3)
        content.setCustomSpacing(12, after: dateRow)
        content.setCustomSpacing(14, after: prompt)
        stack.addArrangedSubview(card)

        // 卡片下方居中橙色短线（28×1，预览口径）。
        let ruleWrap = UIView()
        ruleWrap.translatesAutoresizingMaskIntoConstraints = false
        let rule = UIView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.backgroundColor = BearyColors.orange
        ruleWrap.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.widthAnchor.constraint(equalToConstant: 28),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.centerXAnchor.constraint(equalTo: ruleWrap.centerXAnchor),
            rule.topAnchor.constraint(equalTo: ruleWrap.topAnchor),
            rule.bottomAnchor.constraint(equalTo: ruleWrap.bottomAnchor),
        ])
        pageOneRuleWrap = ruleWrap
        stack.addArrangedSubview(ruleWrap)
        stack.setCustomSpacing(26, after: card)
        return page
    }

    // MARK: - 第 2 页

    /// 第 2 页：演示日记卡＋静态可见性三行（私密选中，预览口径：列表为静态演示）。
    private func buildPageTwo() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        let (card, content) = makeDemoCard()
        demoCards.append(card)
        let (pill, _, _) = makeCapsule(demo: .private)
        let dateRow = makeDateRow(capsule: pill)
        content.addArrangedSubview(dateRow)
        let line1 = makePlaceholderLine(fraction: 1.0)
        let line2 = makePlaceholderLine(fraction: 0.6)
        content.addArrangedSubview(line1)
        content.addArrangedSubview(line2)
        // 可见性列表（行高 54：17pt 上下内边距；行间 1px 细线，首行顶边同色）。
        let list = UIStackView()
        list.axis = .vertical
        list.alignment = .fill
        list.spacing = 0
        for (index, demo) in OnboardingVisibilityDemo.allCases.enumerated() {
            if index == 0 {
                list.addArrangedSubview(makeDivider())
            }
            list.addArrangedSubview(makeVisibilityRow(demo: demo, selected: demo == .private))
            list.addArrangedSubview(makeDivider())
        }
        content.addArrangedSubview(list)
        content.setCustomSpacing(12, after: dateRow)
        content.setCustomSpacing(16, after: line2)
        stack.addArrangedSubview(card)
        return page
    }

    /// 可见性静态行：官方图标 20pt＋「标题 — 副文案」同一行；选中行右侧 ✓。
    private func makeVisibilityRow(demo: OnboardingVisibilityDemo, selected: Bool) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: demo.iconName, pointSize: 20)
        iconView.tintColor = selected ? BearyColors.ink : BearyColors.gray
        let textLabel = UILabel()
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.numberOfLines = 0
        let text = NSMutableAttributedString(string: demo.title, attributes: [
            .font: scaledFont(size: 15, weight: .semibold),
            .foregroundColor: selected ? BearyColors.ink : BearyColors.gray,
        ])
        text.append(NSAttributedString(string: " — \(demo.subtitle)", attributes: [
            .font: scaledFont(size: 13),
            .foregroundColor: BearyColors.gray,
        ]))
        textLabel.attributedText = text
        textLabel.adjustsFontForContentSizeCategory = true
        row.addSubview(iconView)
        row.addSubview(textLabel)
        var constraints: [NSLayoutConstraint] = [
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            textLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ]
        if selected {
            let checkView = UIImageView()
            checkView.translatesAutoresizingMaskIntoConstraints = false
            checkView.image = BearyIconImages.image(named: "icon_check", pointSize: 17)
            checkView.tintColor = BearyColors.ink
            row.addSubview(checkView)
            constraints += [
                checkView.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                checkView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                checkView.widthAnchor.constraint(equalToConstant: 17),
                checkView.heightAnchor.constraint(equalToConstant: 17),
            ]
            constraints.append(textLabel.trailingAnchor.constraint(equalTo: checkView.leadingAnchor, constant: -12))
        } else {
            constraints.append(textLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    // MARK: - 第 3 页

    /// 第 3 页：演示日记卡（可变胶囊＋回应钮）＋分段切换＋说明。
    private func buildPageThree() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 30
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        let (card, content) = makeDemoCard()
        demoCards.append(card)
        let (pill, iconView, label) = makeCapsule(demo: selectedVisibility)
        capsulePill = pill
        capsuleIconView = iconView
        capsuleLabel = label
        let dateRow = makeDateRow(capsule: pill)
        content.addArrangedSubview(dateRow)
        let line1 = makePlaceholderLine(fraction: 1.0)
        let line2 = makePlaceholderLine(fraction: 0.6)
        content.addArrangedSubview(line1)
        content.addArrangedSubview(line2)
        // 回应钮行（卡内，上距 22）：3 个 56pt 圆钮，间距 12，居中。
        let emoteRow = UIStackView()
        emoteRow.axis = .horizontal
        emoteRow.spacing = 12
        emoteRow.alignment = .center
        let emoteLabels = ["hug": "抱抱", "love": "喜欢", "cheer": "庆祝"]
        for key in ["hug", "love", "cheer"] {
            let button = BearyHit44Button(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.layer.cornerRadius = 28
            button.layer.borderWidth = 0
            button.accessibilityLabel = emoteLabels[key]
            button.addTarget(self, action: #selector(emoteTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            let emoteView = BearyEmoteView(key: key, animated: false)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            emoteView.isUserInteractionEnabled = false
            button.addSubview(emoteView)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 56),
                button.heightAnchor.constraint(equalToConstant: 56),
                emoteView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                emoteView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                emoteView.widthAnchor.constraint(equalToConstant: 44),
                emoteView.heightAnchor.constraint(equalToConstant: 44),
            ])
            emoteButtons[key] = button
            emoteViews[key] = emoteView
            emoteRow.addArrangedSubview(button)
        }
        let emoteWrap = UIStackView(arrangedSubviews: [emoteRow])
        emoteWrap.axis = .horizontal
        emoteWrap.alignment = .center
        content.addArrangedSubview(emoteWrap)
        content.setCustomSpacing(12, after: dateRow)
        content.setCustomSpacing(22, after: line2)
        stack.addArrangedSubview(card)

        // 分段切换（卡片下方）：等宽四栏、每栏内居中；选中加粗＋底部 2pt 墨色短线。
        let switchContainer = buildVisibilitySwitch()
        stack.addArrangedSubview(switchContainer)
        let explain = makeLabel(size: 12.5, color: BearyColors.gray, alignment: .center)
        explain.text = selectedVisibility.explain
        switchExplainLabel = explain
        stack.addArrangedSubview(explain)
        stack.setCustomSpacing(13, after: switchContainer)
        applyEmoteSelection()
        applyVisibilitySelection()
        return page
    }

    private func buildVisibilitySwitch() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .fill
        container.addSubview(row)
        let bottomBorder = makeDivider()
        container.addSubview(bottomBorder)
        for demo in OnboardingVisibilityDemo.allCases {
            let button = BearyHit44Button(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = demo.rawValue
            button.addTarget(self, action: #selector(visibilitySwitchTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            // 图标＋文字横向居中。
            let inner = UIStackView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            inner.axis = .horizontal
            inner.spacing = 5
            inner.alignment = .center
            let iconView = UIImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = BearyIconImages.image(named: demo.iconName, pointSize: 16)
            iconView.tintColor = BearyColors.ink
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = scaledFont(size: 14)
            label.textColor = BearyColors.ink
            label.text = demo.title
            label.adjustsFontForContentSizeCategory = true
            inner.addArrangedSubview(iconView)
            inner.addArrangedSubview(label)
            button.addSubview(inner)
            // 选中下划线（2pt 墨色，左右各缩进 22%）。
            let underline = UIView()
            underline.translatesAutoresizingMaskIntoConstraints = false
            underline.backgroundColor = BearyColors.ink
            underline.isHidden = true
            button.addSubview(underline)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                inner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                inner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                underline.heightAnchor.constraint(equalToConstant: 2),
                underline.widthAnchor.constraint(equalTo: button.widthAnchor, multiplier: 0.56),
                underline.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                underline.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            switchButtons[demo] = button
            switchLabels[demo] = label
            switchUnderlines[demo] = underline
            row.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 44),
            bottomBorder.topAnchor.constraint(equalTo: row.bottomAnchor),
            bottomBorder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - 第 4 页

    /// 第 4 页：庆祝熊＋带闪烁光标的演示日记卡（点主钮盖橙色印章）。
    private func buildPageFour() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 30
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        // 官方 cheer 表情（静态帧，148×148；矮屏 ≤720pt 时 112×112，预览口径）。
        let cheerWrap = UIView()
        cheerWrap.translatesAutoresizingMaskIntoConstraints = false
        let cheerView = BearyEmoteView(key: "cheer", animated: false)
        cheerView.translatesAutoresizingMaskIntoConstraints = false
        cheerView.isUserInteractionEnabled = false
        cheerWrap.addSubview(cheerView)
        let height = cheerView.heightAnchor.constraint(equalToConstant: 148)
        height.isActive = true
        cheerBearHeight = height
        NSLayoutConstraint.activate([
            cheerView.centerXAnchor.constraint(equalTo: cheerWrap.centerXAnchor),
            cheerView.topAnchor.constraint(equalTo: cheerWrap.topAnchor),
            cheerView.bottomAnchor.constraint(equalTo: cheerWrap.bottomAnchor),
            cheerView.widthAnchor.constraint(equalTo: cheerView.heightAnchor),
        ])
        stack.addArrangedSubview(cheerWrap)

        let (card, content) = makeDemoCard()
        demoCards.append(card)
        let (pill, _, _) = makeCapsule(demo: .private)
        let dateRow = makeDateRow(capsule: pill)
        content.addArrangedSubview(dateRow)
        // 输入态：闪烁光标＋44% 占位线。
        let inputRow = UIView()
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        let cursor = UIView()
        cursor.translatesAutoresizingMaskIntoConstraints = false
        cursor.backgroundColor = BearyColors.orange
        cursor.layer.cornerRadius = 1
        cursorView = cursor
        let inputLine = UIView()
        inputLine.translatesAutoresizingMaskIntoConstraints = false
        inputLine.backgroundColor = BearyColors.surface2
        inputLine.layer.cornerRadius = 2.5
        inputRow.addSubview(cursor)
        inputRow.addSubview(inputLine)
        NSLayoutConstraint.activate([
            inputRow.heightAnchor.constraint(equalToConstant: 18),
            cursor.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor),
            cursor.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            cursor.widthAnchor.constraint(equalToConstant: 2),
            cursor.heightAnchor.constraint(equalToConstant: 18),
            inputLine.leadingAnchor.constraint(equalTo: cursor.trailingAnchor, constant: 8),
            inputLine.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            inputLine.heightAnchor.constraint(equalToConstant: 5),
            inputLine.widthAnchor.constraint(equalTo: inputRow.widthAnchor, multiplier: 0.44),
        ])
        content.addArrangedSubview(inputRow)
        content.setCustomSpacing(12, after: dateRow)
        stack.addArrangedSubview(card)

        // 印章（卡片右下角，46pt 圆、1.5pt 橙边、内含 28pt 抱抱熊；
        // 初始隐藏：透明／放大 1.7／旋转 −20°，点主钮时回弹出现）。
        let stamp = UIView()
        stamp.translatesAutoresizingMaskIntoConstraints = false
        stamp.layer.cornerRadius = 23
        stamp.layer.borderWidth = 1.5
        stamp.layer.borderColor = BearyColors.orange.cgColor
        stamp.backgroundColor = .clear
        let stampImage = UIImageView()
        stampImage.translatesAutoresizingMaskIntoConstraints = false
        stampImage.image = BearyEmoteImages.image(for: "hug", dark: traitCollection.userInterfaceStyle == .dark)
        stampImage.contentMode = .scaleAspectFit
        stamp.addSubview(stampImage)
        NSLayoutConstraint.activate([
            stampImage.centerXAnchor.constraint(equalTo: stamp.centerXAnchor),
            stampImage.centerYAnchor.constraint(equalTo: stamp.centerYAnchor),
            stampImage.widthAnchor.constraint(equalToConstant: 28),
            stampImage.heightAnchor.constraint(equalToConstant: 28),
        ])
        stampView = stamp
        stampImageView = stampImage
        card.addSubview(stamp)
        NSLayoutConstraint.activate([
            stamp.widthAnchor.constraint(equalToConstant: 46),
            stamp.heightAnchor.constraint(equalToConstant: 46),
            stamp.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stamp.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        stamp.alpha = 0
        stamp.transform = CGAffineTransform(scaleX: 1.7, y: 1.7).rotated(by: -20 * CGFloat.pi / 180)
        return page
    }

    // MARK: - 文案（逐字定稿，与 v3 相同：引导标题 26 bold 衬线（规范已定），字号字重不变）

    private func pageNumberText(_ page: Int) -> String {
        return String(format: "%02d — 04", page + 1)
    }

    private func pageTitle(_ page: Int) -> String {
        switch page {
        case 0: return "在这里写日记"
        case 1: return NSLocalizedString("onboarding.title.page1_write_visibility", comment: "")
        case 2: return NSLocalizedString("onboarding.title.page2_bear_reply", comment: "")
        default: return NSLocalizedString("onboarding.title.page3_start_small", comment: "")
        }
    }

    private func pageSubtitle(_ page: Int) -> String {
        switch page {
        case 0: return "写下今天的事和心情。"
        case 1: return "发布前，确认这篇日记的可见范围。"
        case 2: return "" // 第 3 页无副标题：与标题重复（2026-11-14 第 19 轮审计 B5 定版）。
        default: return "想写什么，就写什么。"
        }
    }

    private func pagePrimaryTitle(_ page: Int) -> String {
        switch page {
        case 0: return "下一步"
        case 1, 2: return "继续"
        default: return SessionManager.shared.isLoggedIn ? "写下第一篇" : "开始写日记"
        }
    }

    private func pageSecondaryTitle() -> String {
        return "先逛逛"
    }

    // MARK: - 顶栏与标题区刷新

    private func updateChrome() {
        for (index, dot) in dotViews.enumerated() {
            let isCurrent = index == currentPage
            dot.backgroundColor = isCurrent ? BearyColors.ink : BearyColors.line
            dotWidthConstraints[index].constant = isCurrent ? 20 : 6
        }
        if let last = lastDotPage, last != currentPage, BearyMotion.animated(true) {
            UIView.animate(withDuration: BearyMotion.normal) {
                self.dotsStack.layoutIfNeeded()
            }
        }
        lastDotPage = currentPage
        dotsStack.accessibilityLabel = "第 \(currentPage + 1) 页，共 4 页"
        // 顶栏返回：第 2 页起才可用，第 1 页透明占位（只占位不占事件）。
        let showBack = currentPage >= 1
        backButton.alpha = showBack ? 1 : 0
        backButton.isEnabled = showBack
        backButton.accessibilityElementsHidden = !showBack
        pageNumberLabel.attributedText = kernedText(pageNumberText(currentPage), font: scaledFont(size: 11), color: BearyColors.gray, kern: 2.4)
        titleLabel.text = pageTitle(currentPage)
        subtitleLabel.attributedText = kernedText(pageSubtitle(currentPage), font: scaledFont(size: 14), color: BearyColors.gray, kern: 0, lineHeightMultiple: 1.65)
        subtitleLabel.isHidden = pageSubtitle(currentPage).isEmpty
        setPrimaryTitle(pagePrimaryTitle(currentPage))
        if currentPage == 3 {
            secondaryButton.setTitle(pageSecondaryTitle(), for: .normal)
            secondaryButton.alpha = 1
            secondaryButton.isEnabled = true
            secondaryButton.accessibilityElementsHidden = false
        } else {
            secondaryButton.alpha = 0
            secondaryButton.isEnabled = false
            secondaryButton.accessibilityElementsHidden = true
        }
        refreshPageFourCursor()
    }

    private func setPrimaryTitle(_ text: String) {
        let font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .medium))
        primaryButton.setAttributedTitle(kernedText(text, font: font, color: BearyColors.bg, kern: 2.1), for: .normal)
    }

    /// 标题区换页上浮淡入（预览口径，0.3s）。
    private func animateTitlePanel() {
        guard BearyMotion.animated(true) else { return }
        titlePanel.alpha = 0
        titlePanel.transform = CGAffineTransform(translationX: 0, y: 8)
        UIView.animate(withDuration: OnboardingAnim.titleChangeDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.titlePanel.alpha = 1
            self.titlePanel.transform = .identity
        }, completion: nil)
    }

    // MARK: - 翻页状态机（与 v3 相同：按钮与互动拖动共用）

    private func pageWidth() -> CGFloat {
        return max(columnView.bounds.width, 1)
    }

    private func showPageImmediately(_ page: Int) {
        currentPage = page
        for (index, pageView) in pageViews.enumerated() {
            pageView.isHidden = index != page
            let edges = pageEdgeConstraints[index]
            for constraint in edges {
                constraint.isActive = index == page
            }
        }
        // 换页后所有页复位（不留位移／透明）；动画层面的复位也一样
        // （复位只把视图恢复到静止态，不产出可见画面）。
        for pageView in pageViews {
            pageView.transform = .identity
            pageView.alpha = 1
        }
        updateChrome()
    }

    private func goTo(_ page: Int, animated: Bool) {
        guard page >= 0, page < 4 else { return }
        guard !finished, page != currentPage, !isTransitioning else { return }
        if currentPage == 3 { stopAllEmotes() }
        let target = page
        if !animated {
            showPageImmediately(target)
            playEntranceIfNeeded(target)
            return
        }
        isTransitioning = true
        let fromView = pageViews[currentPage]
        let toView = pageViews[target]
        stageTargetPage(toView, direction: target > currentPage ? 1 : -1)
        let targetTranslation = CGFloat(target > currentPage ? 1 : -1) * pageWidth()
        animateTransition(from: fromView, to: toView, targetTranslation: targetTranslation) {
            self.completeTransition(to: target)
        }
    }

    private func stageTargetPage(_ toView: UIView, direction: Int) {
        toView.isHidden = false
        toView.transform = CGAffineTransform(translationX: CGFloat(direction) * pageWidth(), y: 0)
        toView.alpha = 0.9
    }

    /// 滑出＋滑入＋顶栏标题换页在同一次动画里（顶栏只换圆点／页码／标题，不左右滑）；
    /// 落点用弹簧（0.26s／damping 0.7），动效档三段在 BearyMotion 中。
    /// 动画期间的滑动与翻页互斥（isTransitioning 守门）；若在动画中途收到重复
    /// 翻页请求，goTo 直接丢弃，避免并行变换竞写。
    private func animateTransition(from fromView: UIView, to toView: UIView, targetTranslation: CGFloat, completion: @escaping () -> Void) {
        if !BearyMotion.animated(true) {
            fromView.transform = .identity
            fromView.alpha = 1
            toView.transform = .identity
            toView.alpha = 1
            completion()
            return
        }
        // 滑出＋滑入在同一次动画里，用翻页落点弹簧（0.26s／damping 0.7）。
        UIView.animate(withDuration: OnboardingAnim.pageSpringDuration, delay: 0, usingSpringWithDamping: OnboardingAnim.pageSpringDamping, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            fromView.transform = CGAffineTransform(translationX: -targetTranslation, y: 0)
            fromView.alpha = 0.9
            toView.transform = .identity
            toView.alpha = 1
        }, completion: { _ in
            completion()
        })
    }

    private func completeTransition(to target: Int) {
        let changed = target != currentPage
        if finished {
            isTransitioning = false
            pendingPage = nil
            dragTargetPage = nil
            dragTranslation = 0
            return
        }
        showPageImmediately(target)
        isTransitioning = false
        dragTargetPage = nil
        dragTranslation = 0
        playEntranceIfNeeded(target)
        if changed {
            animateTitlePanel()
        }
        if let pending = pendingPage {
            pendingPage = nil
            goTo(pending, animated: true)
        }
    }

    private func stopAllEmotes() {
        for emoteView in emoteViews.values {
            emoteView.stop()
        }
    }

    // MARK: - 互动翻页（UIPan 1:1 跟手）

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 只有主页面滑动手势参与方向仲裁；demoScroll 的 pan 不归这里管。
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard gestureRecognizer.view == view else { return true }
        let velocity = pan.velocity(in: view)
        // 竖滑留给 demoScroll，横滑才由本手势接管（与回收站行拖动模式相同）。
        if abs(velocity.y) > abs(velocity.x) { return false }
        // 正在拖动滚动内容时不抢横滑，避免从滚动状态横向滑动误翻页。
        if demoScroll.isDragging { return false }
        return true
    }

    @objc private func onboardingPanned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let width = pageWidth()
        switch gesture.state {
        case .began:
            if isTransitioning { return }
            dragTargetPage = nil
            dragTranslation = 0
        case .changed:
            if isTransitioning { return }
            // 1:1 跟手：当前页按手势位移滑动；目标页不参与跟手，只在方向
            // 首次确定时由 stageTargetPage 预摆到对应侧。
            let delta = translation.x - dragTranslation
            dragTranslation = translation.x
            if dragTargetPage == nil, translation.x != 0 {
                let direction = translation.x < 0 ? 1 : -1
                let target = currentPage + direction
                if target < 0 || target >= 4 {
                    // 首尾页外拖：目标不存在，记为原地越界，拖动后回弹。
                    dragTargetPage = currentPage
                    return
                }
                if currentPage == 3 { stopAllEmotes() }
                dragTargetPage = target
                stageTargetPage(pageViews[target], direction: direction)
            }
            if var dragTarget = dragTargetPage {
                if dragTarget == currentPage {
                    // 首尾越界方向锁住后反向越过起点：改向相邻页，继续跟手。
                    if translation.x != 0 {
                        let newTarget = translation.x < 0 ? currentPage + 1 : currentPage - 1
                        if newTarget >= 0, newTarget <= 3 {
                            if currentPage == 3 { stopAllEmotes() }
                            dragTargetPage = newTarget
                            stageTargetPage(pageViews[newTarget], direction: newTarget > currentPage ? 1 : -1)
                            dragTarget = newTarget
                        }
                    }
                } else if (dragTarget > currentPage && translation.x > 0 && currentPage > 0)
                    || (dragTarget < currentPage && translation.x < 0 && currentPage < 3) {
                    // 拖回起点外改向相邻目标页：手指继续移动时页面不停住，1:1 跟手不断。
                    let newTarget = dragTarget > currentPage ? currentPage - 1 : currentPage + 1
                    pageViews[dragTarget].isHidden = true
                    pageViews[dragTarget].transform = .identity
                    dragTargetPage = newTarget
                    stageTargetPage(pageViews[newTarget], direction: newTarget > currentPage ? 1 : -1)
                    dragTarget = newTarget
                }
                if dragTarget == currentPage {
                    // 首尾页外拖：当前页随手势以 0.25 阻尼系数跟手，松手回弹。
                    pageViews[currentPage].transform = CGAffineTransform(translationX: translation.x * 0.25, y: 0)
                } else {
                    // 翻到一半：当前页跟手滑出，目标页在另一侧同步跟手滑入。
                    let direction = dragTarget > currentPage ? 1 : -1
                    let clamped = max(-width, min(width, translation.x))
                    pageViews[currentPage].transform = CGAffineTransform(translationX: clamped, y: 0)
                    pageViews[dragTarget].transform = CGAffineTransform(translationX: CGFloat(direction) * width + clamped, y: 0)
                }
            }
        case .ended, .cancelled:
            guard !isTransitioning, let dragTarget = dragTargetPage else {
                dragTargetPage = nil
                dragTranslation = 0
                return
            }
            let velocity = gesture.velocity(in: view).x
            // 松手判据（与 v3 相同）：拖过页宽 1/3，或沿翻页方向速度 ＞600pt/s。
            if dragTarget == currentPage {
                // 首尾页外拖：松手回弹。
                isTransitioning = true
                UIView.animate(withDuration: OnboardingAnim.pageSpringDuration, delay: 0, usingSpringWithDamping: OnboardingAnim.pageSpringDamping, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                    self.pageViews[self.currentPage].transform = .identity
                }, completion: { _ in
                    self.isTransitioning = false
                })
            } else {
                let direction = dragTarget > currentPage ? 1 : -1
                let shouldCommit = abs(translation.x) >= width * OnboardingAnim.pageCommitFraction
                    || (direction == 1 && velocity <= -OnboardingAnim.pageFlingVelocity)
                    || (direction == -1 && velocity >= OnboardingAnim.pageFlingVelocity)
                settleInteractiveDrag(to: shouldCommit ? dragTarget : currentPage)
            }
            dragTargetPage = nil
            dragTranslation = 0
        default:
            break
        }
    }

    private func settleInteractiveDrag(to finalPage: Int) {
        if finished { return }
        isTransitioning = true
        let fromView = pageViews[currentPage]
        let toView = pageViews[finalPage]
        let targetTranslation = CGFloat(finalPage > currentPage ? 1 : -1) * pageWidth()
        if finalPage == currentPage {
            // 未过阈值：目标页回到原侧隐藏，当前页回到原位（回弹）。
            UIView.animate(withDuration: OnboardingAnim.pageSpringDuration, delay: 0, usingSpringWithDamping: OnboardingAnim.pageSpringDamping, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                fromView.transform = .identity
                fromView.alpha = 1
                toView.transform = CGAffineTransform(translationX: targetTranslation, y: 0)
                toView.alpha = 0.9
            }, completion: { _ in
                self.completeTransition(to: finalPage)
            })
        } else {
            animateTransition(from: fromView, to: toView, targetTranslation: targetTranslation) {
                self.completeTransition(to: finalPage)
            }
        }
    }

    // MARK: - 入场错峰（与 v3 相同：新内容错峰滑入，已有元素不重播）

    private func preparePageOneEntrance() {
        // 首帧前先摆好入场起点：小熊、卡片、短线、标题区、按钮区淡出＋下沉。
        let items: [UIView?] = [pageOneBearWrap, pageOneCard, pageOneRuleWrap, titlePanel, actionsView]
        for view in items {
            view?.alpha = 0
            view?.transform = CGAffineTransform(translationX: 0, y: 6)
        }
    }

    private func playEntranceIfNeeded(_ page: Int) {
        guard !entrancePlayedPages.contains(page) else { return }
        entrancePlayedPages.insert(page)
        if page == 0 {
            var items: [(view: UIView, delay: TimeInterval, finalTransform: CGAffineTransform)] = []
            let views: [UIView?] = [pageOneBearWrap, pageOneCard, pageOneRuleWrap, titlePanel, actionsView]
            for (offset, view) in views.enumerated() {
                guard let view = view else { continue }
                items.append((view, Double(offset) * OnboardingAnim.staggerStep, .identity))
            }
            playStaggeredEntrance(items: items)
            return
        }
        guard pageViews.indices.contains(page),
              let stack = pageViews[page].subviews.first(where: { $0 is UIStackView }) as? UIStackView else { return }
        let items: [(view: UIView, delay: TimeInterval, finalTransform: CGAffineTransform)] = stack.arrangedSubviews.enumerated().map {
            ($0.element, Double($0.offset) * OnboardingAnim.staggerStep, .identity)
        }
        for item in items {
            item.view.alpha = 0
            item.view.transform = CGAffineTransform(translationX: 0, y: 6)
        }
        playStaggeredEntrance(items: items)
    }

    private func playStaggeredEntrance(items: [(view: UIView, delay: TimeInterval, finalTransform: CGAffineTransform)]) {
        // 减弱动效时不播入场，直接落终态。
        guard BearyMotion.animated(true) else {
            for item in items {
                item.view.alpha = 1
                item.view.transform = item.finalTransform
            }
            return
        }
        for item in items {
            UIView.animate(withDuration: OnboardingAnim.entranceDuration, delay: item.delay, options: [.curveEaseOut], animations: {
                item.view.alpha = 1
                item.view.transform = item.finalTransform
            }, completion: nil)
        }
    }

    // MARK: - 第 3 页演示交互（只改本地演示态，不产生真实回应、不发布）

    @objc private func emoteTapped(_ sender: UIButton) {
        for (key, button) in emoteButtons where button == sender {
            selectEmote(key)
            return
        }
    }

    private func selectEmote(_ key: String) {
        for (otherKey, otherView) in emoteViews {
            if otherKey != key { otherView.showStaticFrame() }
        }
        if let current = emoteViews[key] {
            current.replayFromStart()
            playEmotePop(current)
        }
        selectedEmote = key
        applyEmoteSelection()
    }

    private func applyEmoteSelection() {
        for (key, button) in emoteButtons {
            let selected = key == selectedEmote
            button.layer.borderWidth = selected ? 2 : 0
            button.layer.bearyDynamicBorderColor = BearyColors.ink
            button.backgroundColor = selected ? BearyColors.surface2 : .clear
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    /// 点选 pop（预览口径）：0.5s，先缩 0.55 再 1.18／1.04／1.09 回 1，带摆动。
    private func playEmotePop(_ view: UIView) {
        guard BearyMotion.animated(true) else { return }
        view.transform = .identity
        UIView.animateKeyframes(withDuration: OnboardingAnim.emotePopDuration, delay: 0, options: [.beginFromCurrentState], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.15) {
                view.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.15, relativeDuration: 0.25) {
                view.transform = CGAffineTransform(scaleX: 1.18, y: 1.18).rotated(by: -7 * CGFloat.pi / 180)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.4, relativeDuration: 0.2) {
                view.transform = CGAffineTransform(scaleX: 1.04, y: 1.04).rotated(by: 6 * CGFloat.pi / 180)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.2) {
                view.transform = CGAffineTransform(scaleX: 1.09, y: 1.09).rotated(by: -3 * CGFloat.pi / 180)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                view.transform = .identity
            }
        }, completion: nil)
    }

    @objc private func visibilitySwitchTapped(_ sender: UIButton) {
        guard let demo = OnboardingVisibilityDemo(rawValue: sender.tag) else { return }
        selectedVisibility = demo
        applyVisibilitySelection()
    }

    /// 分段切换联动：切换按钮加粗＋下划线，卡片胶囊（图标／文字／描边色）与下方说明同步改。
    private func applyVisibilitySelection() {
        for (demo, button) in switchButtons {
            let selected = demo == selectedVisibility
            switchLabels[demo]?.font = scaledFont(size: 14, weight: selected ? .bold : .regular)
            switchUnderlines[demo]?.isHidden = !selected
            _ = button
        }
        if let pill = capsulePill, let iconView = capsuleIconView, let label = capsuleLabel {
            iconView.image = BearyIconImages.image(named: selectedVisibility.iconName, pointSize: 12)
            label.text = selectedVisibility.title
            label.textColor = selectedVisibility == .private ? BearyColors.blue : BearyColors.deepOrangeText
            pill.layer.bearyDynamicBorderColor = BearyColors.alpha(selectedVisibility.pillColor, 0.45)
        }
        switchExplainLabel?.text = selectedVisibility.explain
    }

    // MARK: - 第 4 页光标与印章

    private func refreshPageFourCursor() {
        guard currentPage == 3, view.window != nil, !UIAccessibility.isReduceMotionEnabled else {
            stopCursorBlink()
            return
        }
        startCursorBlink()
    }

    private func startCursorBlink() {
        guard let cursor = cursorView, !cursorBlinking else { return }
        cursorBlinking = true
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = OnboardingAnim.cursorBlinkHalfPeriod
        blink.autoreverses = true
        blink.repeatCount = .infinity
        cursor.layer.add(blink, forKey: "bearyCursorBlink")
    }

    private func stopCursorBlink() {
        guard cursorBlinking else { return }
        cursorBlinking = false
        cursorView?.layer.removeAnimation(forKey: "bearyCursorBlink")
        cursorView?.layer.opacity = 1
    }

    /// 盖章回弹（预览口径）：0.35s 弹簧到 1 倍／−10°，停留 0.4s 后走回调。
    private func showStamp(completion: @escaping () -> Void) {
        guard let stamp = stampView else { completion(); return }
        stampShown = true
        if !BearyMotion.animated(true) {
            stamp.alpha = 1
            stamp.transform = CGAffineTransform(scaleX: 1, y: 1).rotated(by: -10 * CGFloat.pi / 180)
            completion()
            return
        }
        UIView.animate(withDuration: OnboardingAnim.stampDuration, delay: 0, usingSpringWithDamping: OnboardingAnim.pageSpringDamping, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: {
            stamp.alpha = 1
            stamp.transform = CGAffineTransform(scaleX: 1, y: 1).rotated(by: -10 * CGFloat.pi / 180)
        }, completion: { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + OnboardingAnim.stampSettleDelay) {
                completion()
            }
        })
    }

    // MARK: - 顶栏与底部按钮动作

    @objc private func backTapped() {
        goTo(currentPage - 1, animated: true)
    }

    /// 「跳过」直达第 4 页（预览口径），不写 seenKey、不退出。
    @objc private func skipTapped() {
        goTo(3, animated: true)
    }

    @objc private func primaryTapped() {
        if currentPage < 3 {
            goTo(currentPage + 1, animated: true)
            return
        }
        // 第 4 页：先盖章（预览口径），再走原有回调；已盖过章直接走回调。
        guard !pageFourPrimaryPending else { return }
        if !stampShown {
            pageFourPrimaryPending = true
            showStamp { [weak self] in
                guard let self = self else { return }
                self.pageFourPrimaryPending = false
                guard self.currentPage == 3, !self.finished else { return }
                self.firePageFourPrimary()
            }
        } else {
            firePageFourPrimary()
        }
    }

    private func firePageFourPrimary() {
        if SessionManager.shared.isLoggedIn {
            if let action = onRequestCompose { action() } else { finish() }
        } else {
            if let action = onRequestLogin { action() } else { finish() }
        }
    }

    @objc private func secondaryTapped() {
        if currentPage == 3 {
            if let action = onRequestBrowse { action() } else { finish() }
        }
    }

    // MARK: - 退出

    private func finish() {
        guard !finished else { return }
        finished = true
        // seenKey 只在兜底路径由本页写：闭包已设置时，写 key 是容器的责任。
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        stopAllEmotes()
        stopCursorBlink()
        dismiss(animated: true)
    }

    // MARK: - 动态描边刷新（CGColor 快照须在深浅切换时手动重刷）

    private func refreshDynamicBorders() {
        for card in demoCards {
            card.layer.bearyDynamicBorderColor = BearyColors.line
        }
        for (_, button) in emoteButtons {
            button.layer.bearyDynamicBorderColor = BearyColors.ink
        }
        if let pill = capsulePill {
            pill.layer.bearyDynamicBorderColor = BearyColors.alpha(selectedVisibility.pillColor, 0.45)
        }
        // 印章描边为固定橙，不随深浅变，无需重刷。
    }
}

// MARK: - 约束优先级工具

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
