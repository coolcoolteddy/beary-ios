import UIKit

// ===== beary 新手引导 v3（原生版，4 页）=====
// 骨架＋四页本体（第 1 棒）。预览基准：~/workspace/onboarding-preview/preview-v3.html，
// v1/v2 与旧 10 屏版一律作废；旧文件只作资产名与 API 名的参考，旧规则一律不用。
// 公开契约（第 2 棒按此接线，改名即断链）：
// - final class BearyOnboardingViewController: UIViewController
// - enum Mode { firstLaunch, replay }，init(mode: Mode)
// - static let seenKey = "beary_onboarding_v3_seen"（新 key，绝不复用旧教程的 seen key）
// - 四个可选闭包 onRequestLogin / onRequestGuestBrowse / onRequestCompose / onRequestBrowse：
//   触发时只回调、不自行 dismiss，dismiss 由 SceneDelegate 控制；闭包未设置时才回退为
//   写 seenKey + 自行 dismiss（兜底，避免按钮无反应）。
// - 跳过：写 seenKey = true 后自行 dismiss（modal 下方就是主页或设置页，直接露出即可）。
// 旧 VC 的预加载步骤 API 已随整文件替换而消失，SceneDelegate 的 presentOnboarding 会暂时
// 无法编译——这是预期的，第 2 棒会重写它，本文件不碰 SceneDelegate。
// 注意：本页不调任何写接口、不改用户默认设置；第 2 页演示只改示例态，第 3 页不产生真实回应。
// 星环装饰：仓库内没有主站 hero 星环同款资产（仅有单颗 icon_star，非星环），按任务要求去掉，
// 不自绘、不拿 SF Symbol 做主图标。

// MARK: - 动效与布局常量（文件内私有）

private enum OnboardingAnim {
    /// 切页总时长（出 0.14 + 入 0.14，落在 0.25–0.32 秒口径内）。
    static let pageHalfDuration: TimeInterval = 0.14
    /// 切页横移幅度（轻微横移＋淡入淡出）。
    static let pageSlide: CGFloat = 20
    /// 入场错峰间隔；总入场 0.5 秒内（0.15 末位延迟 + 0.25 播长 = 0.40）。
    static let staggerStep: TimeInterval = 0.05
    static let entranceDuration: TimeInterval = 0.25
    /// 第 1 页两张卡片的错位：后卡左右各缩 10，前卡下压 80、微转 0.5°，后卡微转 -3.5°。
    static let cardBackInset: CGFloat = 10
    static let cardFrontOffset: CGFloat = 80
    static let cardBackRotation: CGFloat = -3.5 * CGFloat.pi / 180
    static let cardFrontRotation: CGFloat = 0.5 * CGFloat.pi / 180
}

// MARK: - 圆角胶囊容器（pill / 回应 chip 共用：圆角恒为半高，深浅与字号变化时自动跟随）

private final class OnboardingCapsuleView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

// MARK: - 可见范围演示态（第 2 页）

private enum OnboardingVisibilityDemo: Int, CaseIterable {
    case `private` = 0
    case `public` = 1
    case ephemeral = 2

    /// 官方图标资产名（beary-ui，仓库已核实）。
    var iconName: String {
        switch self {
        case .private: return "icon_lock"
        case .public: return "icon_globe"
        case .ephemeral: return "icon_clock"
        }
    }

    var title: String {
        switch self {
        case .private: return "私密"
        case .public: return "公开"
        case .ephemeral: return "限时日记"
        }
    }

    /// 副文案：限时一句以编辑器源码为准（BearyComposerViewController ephemeralSubtitleLabel），不得编造。
    var subtitle: String {
        switch self {
        case .private: return "仅自己可见"
        case .public: return "所有人可见"
        case .ephemeral: return "公开 24 小时后自动转私密"
        }
    }

    /// 状态标签：只用私密蓝 / 公开橙两种 pill；限时存活期即公开态，故用公开橙 pill。
    var pillText: String {
        switch self {
        case .private: return "私密"
        case .public: return "公开"
        case .ephemeral: return "公开"
        }
    }

    var pillColor: UIColor {
        switch self {
        case .private: return BearyColors.blue
        case .public: return BearyColors.orange
        case .ephemeral: return BearyColors.orange
        }
    }

    var explain: String { subtitle }
}

// MARK: - 引导容器

final class BearyOnboardingViewController: UIViewController {
    static let seenKey = "beary_onboarding_v3_seen"

    enum Mode { case firstLaunch, replay }

    let mode: Mode
    var onRequestLogin: (() -> Void)?
    var onRequestGuestBrowse: (() -> Void)?
    var onRequestCompose: (() -> Void)?
    var onRequestBrowse: (() -> Void)?

    // MARK: - 翻页状态机（按钮与左右滑动共用；动画只改 transform 与 opacity）

    private var currentPage = 0
    private var isTransitioning = false
    private var pendingPage: Int?
    private var finished = false
    private var entrancePlayedPages: Set<Int> = []
    private var chipAppeared = false

    // 第 2 页演示态（默认私密；只改示例，不调写接口、不改用户默认设置）。
    private var selectedVisibility: OnboardingVisibilityDemo = .private
    // 第 3 页演示态（只记本地选择，不产生真实回应）。
    private var selectedEmote: String?

    // MARK: - 骨架视图

    private let topWrap = UIView()
    private let backButton = BearyHit44Button(type: .system)
    private let segmentStack = UIStackView()
    private var segmentViews: [UIView] = []
    private let skipButton = BearyHit44Button(type: .system)
    private let heroScroll = UIScrollView()
    private let heroContent = UIView()
    private let columnView = UIView()
    private let bottomCard = UIView()
    private let bottomStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let primaryButton = BearyHit44Button(type: .system)
    private let secondaryButton = BearyHit44Button(type: .system)

    // 600 居中上限（宽 ≥821 才激活，≤820 停用；口径同 BearyDetailViewController）。
    private var topCap: NSLayoutConstraint?
    private var columnCap: NSLayoutConstraint?
    private var bottomCap: NSLayoutConstraint?

    // 四页视图及其边缘约束（同一时刻只激活当前页的一组，避免多页高度冲突）。
    private var pageViews: [UIView] = []
    private var pageEdgeConstraints: [[NSLayoutConstraint]] = []

    // 第 1 页元素（入场错峰用；卡片最终 transform 含旋转，入场只叠加位移）。
    private let bearWrap = UIView()
    private let bearImageView = UIImageView()
    private let cardBack = UIView()
    private let cardFront = UIView()
    private let cardBackFinalTransform = CGAffineTransform(rotationAngle: OnboardingAnim.cardBackRotation)
    private let cardFrontFinalTransform = CGAffineTransform(rotationAngle: OnboardingAnim.cardFrontRotation)

    // 第 2 页元素。
    private var optionButtons: [OnboardingOptionButton] = []
    private let demoIconView = UIImageView()
    private let demoPill = OnboardingCapsuleView()
    private let demoPillLabel = UILabel()
    private let demoBodyLabel = UILabel()
    private let demoExplainLabel = UILabel()

    // 第 3 页元素。
    private let responseChip = OnboardingCapsuleView()
    private let responseChipIcon = UIImageView()
    private let responseChipCount = UILabel()
    private var emoteButtons: [String: UIButton] = [:]
    private var emoteViews: [String: BearyEmoteView] = [:]

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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopAllEmotes()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 821 断点：宽 ≥821 时 600 上限激活、内容居中；≤820 时停用、可用宽度＋边距撑满。
        let wantCap = view.bounds.width >= 821
        if topCap?.isActive != wantCap { topCap?.isActive = wantCap }
        if columnCap?.isActive != wantCap { columnCap?.isActive = wantCap }
        if bottomCap?.isActive != wantCap { bottomCap?.isActive = wantCap }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        // 动态色背景自动跟随；CGColor 快照的边框须手动重刷。
        refreshDynamicBorders()
    }

    // MARK: - 字体口径（仓库既有：BearyDynamicType.scaledFont / cappedFont）

    private func scaledFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        return BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight))
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
        // 顶栏：返回（第 2 页起才可用）＋ 四段细进度 ＋ 跳过。
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()

        segmentStack.translatesAutoresizingMaskIntoConstraints = false
        segmentStack.axis = .horizontal
        segmentStack.spacing = 6
        segmentStack.distribution = .fillEqually
        for _ in 0..<4 {
            let seg = UIView()
            seg.translatesAutoresizingMaskIntoConstraints = false
            seg.layer.cornerRadius = 1.5
            seg.backgroundColor = BearyColors.line
            segmentStack.addArrangedSubview(seg)
            segmentViews.append(seg)
        }

        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.setTitle("跳过", for: .normal)
        skipButton.setTitleColor(BearyColors.gray, for: .normal)
        skipButton.setTitleColor(BearyColors.gray, for: .highlighted)
        skipButton.titleLabel?.font = scaledFont(size: 15)
        skipButton.titleLabel?.adjustsFontForContentSizeCategory = true
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        skipButton.bearyAddPressFeedback()

        let topStack = UIStackView(arrangedSubviews: [backButton, segmentStack, skipButton])
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 12
        topWrap.translatesAutoresizingMaskIntoConstraints = false
        topWrap.addSubview(topStack)
        view.addSubview(topWrap)

        // 主视觉区在上（白底＝ BearyColors.bg）；高度不足时中部可滚动。
        heroScroll.translatesAutoresizingMaskIntoConstraints = false
        heroScroll.showsVerticalScrollIndicator = false
        heroScroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(heroScroll)
        heroContent.translatesAutoresizingMaskIntoConstraints = false
        heroScroll.addSubview(heroContent)
        columnView.translatesAutoresizingMaskIntoConstraints = false
        heroContent.addSubview(columnView)

        // 底部圆角卡片：BearyColors faint 底、顶部圆角 28、通栏。
        bottomCard.translatesAutoresizingMaskIntoConstraints = false
        bottomCard.backgroundColor = BearyColors.faint
        bottomCard.layer.cornerRadius = 28
        bottomCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addSubview(bottomCard)

        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.axis = .vertical
        bottomStack.alignment = .fill
        bottomCard.addSubview(bottomStack)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = scaledFont(size: 26, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = scaledFont(size: 16)
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.adjustsFontForContentSizeCategory = true
        bottomStack.addArrangedSubview(titleLabel)
        bottomStack.addArrangedSubview(subtitleLabel)
        bottomStack.setCustomSpacing(12, after: titleLabel)

        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.backgroundColor = BearyColors.ink
        primaryButton.setTitleColor(BearyColors.bg, for: .normal)
        primaryButton.setTitleColor(BearyColors.bg, for: .highlighted)
        // 固定高度容器：字号上限 20 防撑破（BearyDynamicType.cappedFont 口径）。
        primaryButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        primaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        primaryButton.layer.cornerRadius = 28
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.bearyAddPressFeedback()
        bottomStack.addArrangedSubview(primaryButton)
        bottomStack.setCustomSpacing(20, after: subtitleLabel)

        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.setTitleColor(BearyColors.ink, for: .normal)
        secondaryButton.setTitleColor(BearyColors.ink, for: .highlighted)
        secondaryButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .regular))
        secondaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        secondaryButton.bearyAddPressFeedback()
        bottomStack.addArrangedSubview(secondaryButton)
        bottomStack.setCustomSpacing(4, after: primaryButton)
        secondaryButton.isHidden = true

        // 左右滑动与按钮共用翻页状态机（UISwipe 手势，不拦截点按）。
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(swipedLeft))
        swipeLeft.direction = .left
        swipeLeft.cancelsTouchesInView = false
        view.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(swipedRight))
        swipeRight.direction = .right
        swipeRight.cancelsTouchesInView = false
        view.addGestureRecognizer(swipeRight)

        topCap = topWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        columnCap = columnView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        bottomCap = bottomStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        NSLayoutConstraint.activate([
            topWrap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16).withPriority(750),
            topWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16).withPriority(750),
            topStack.topAnchor.constraint(equalTo: topWrap.topAnchor),
            topStack.leadingAnchor.constraint(equalTo: topWrap.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: topWrap.trailingAnchor),
            topStack.bottomAnchor.constraint(equalTo: topWrap.bottomAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            skipButton.heightAnchor.constraint(equalToConstant: 44),
            segmentStack.heightAnchor.constraint(equalToConstant: 3),

            heroScroll.topAnchor.constraint(equalTo: topWrap.bottomAnchor),
            heroScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            heroScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            heroScroll.bottomAnchor.constraint(equalTo: bottomCard.topAnchor),

            heroContent.topAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.topAnchor),
            heroContent.leadingAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.leadingAnchor),
            heroContent.trailingAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.trailingAnchor),
            heroContent.bottomAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.bottomAnchor),
            heroContent.widthAnchor.constraint(equalTo: heroScroll.frameLayoutGuide.widthAnchor),
            heroContent.heightAnchor.constraint(greaterThanOrEqualTo: heroScroll.frameLayoutGuide.heightAnchor),

            columnView.topAnchor.constraint(greaterThanOrEqualTo: heroContent.topAnchor, constant: 8),
            columnView.bottomAnchor.constraint(lessThanOrEqualTo: heroContent.bottomAnchor, constant: -8),
            columnView.centerYAnchor.constraint(equalTo: heroContent.centerYAnchor).withPriority(250),
            columnView.centerXAnchor.constraint(equalTo: heroContent.centerXAnchor),
            columnView.leadingAnchor.constraint(greaterThanOrEqualTo: heroContent.leadingAnchor, constant: 16).withPriority(750),
            columnView.trailingAnchor.constraint(lessThanOrEqualTo: heroContent.trailingAnchor, constant: -16).withPriority(750),

            bottomCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomCard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomCard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomStack.topAnchor.constraint(equalTo: bottomCard.topAnchor, constant: 24),
            bottomStack.centerXAnchor.constraint(equalTo: bottomCard.centerXAnchor),
            bottomStack.leadingAnchor.constraint(greaterThanOrEqualTo: bottomCard.safeAreaLayoutGuide.leadingAnchor, constant: 24).withPriority(750),
            bottomStack.trailingAnchor.constraint(lessThanOrEqualTo: bottomCard.safeAreaLayoutGuide.trailingAnchor, constant: -24).withPriority(750),
            bottomStack.bottomAnchor.constraint(equalTo: bottomCard.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            primaryButton.heightAnchor.constraint(equalToConstant: 56),
            secondaryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - 四页搭建（公共骨架＋示例卡片，不复制四套布局样式）

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

    /// 示例日记卡片（faint 底、圆角 16）：日期行＋官方天气图标＋正文。
    private func makeDiaryCard(dateText: String, bodyText: String) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.faint
        card.layer.cornerRadius = 16
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        let dateRow = UIStackView()
        dateRow.translatesAutoresizingMaskIntoConstraints = false
        dateRow.axis = .horizontal
        dateRow.spacing = 6
        dateRow.alignment = .center
        let dateLabel = makeLabel(size: 13, color: BearyColors.gray)
        dateLabel.text = dateText
        let weatherView = UIImageView()
        weatherView.translatesAutoresizingMaskIntoConstraints = false
        weatherView.image = BearyIconImages.image(named: "icon_wx_sun", pointSize: 18)
        weatherView.tintColor = BearyColors.ink
        dateRow.addArrangedSubview(dateLabel)
        dateRow.addArrangedSubview(weatherView)
        stack.addArrangedSubview(dateRow)
        let body = makeLabel(size: 16, color: BearyColors.ink)
        body.text = bodyText
        stack.addArrangedSubview(body)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            weatherView.widthAnchor.constraint(equalToConstant: 18),
            weatherView.heightAnchor.constraint(equalToConstant: 18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeDateRowCard(bodyText: String) -> UIView {
        return makeDiaryCard(dateText: "今天", bodyText: bodyText)
    }

    // 第 1 页：认识 beary。
    private func buildPageOne() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 24
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        // 官方抱信封小熊：side_beary_icon（预览 bear.png 与该资产字节一致），放大至约 212pt 高。
        // 星环装饰：仓库无同款资产，已去掉（见文件头注释）。
        bearWrap.translatesAutoresizingMaskIntoConstraints = false
        bearImageView.translatesAutoresizingMaskIntoConstraints = false
        bearImageView.image = UIImage(named: "side_beary_icon")
        bearImageView.contentMode = .scaleAspectFit
        bearWrap.addSubview(bearImageView)
        NSLayoutConstraint.activate([
            bearImageView.centerXAnchor.constraint(equalTo: bearWrap.centerXAnchor),
            bearImageView.topAnchor.constraint(equalTo: bearWrap.topAnchor),
            bearImageView.bottomAnchor.constraint(equalTo: bearWrap.bottomAnchor),
            bearImageView.heightAnchor.constraint(equalToConstant: 212),
            bearImageView.widthAnchor.constraint(equalTo: bearImageView.heightAnchor, multiplier: 235.0 / 247.0),
        ])
        stack.addArrangedSubview(bearWrap)

        // 两张轻微错位叠放的日记卡片（真实产品组件构成主视觉，不做成一张图片）。
        let cardsHost = UIView()
        cardsHost.translatesAutoresizingMaskIntoConstraints = false
        cardBack.translatesAutoresizingMaskIntoConstraints = false
        cardFront.translatesAutoresizingMaskIntoConstraints = false
        let backCard = makeDateRowCard(bodyText: "今天绕了一点远路。")
        backCard.translatesAutoresizingMaskIntoConstraints = false
        let frontCard = makeDateRowCard(bodyText: "刚好看见了很好看的晚霞。")
        frontCard.translatesAutoresizingMaskIntoConstraints = false
        cardBack.addSubview(backCard)
        cardFront.addSubview(frontCard)
        cardsHost.addSubview(cardBack)
        cardsHost.addSubview(cardFront)
        NSLayoutConstraint.activate([
            backCard.topAnchor.constraint(equalTo: cardBack.topAnchor),
            backCard.leadingAnchor.constraint(equalTo: cardBack.leadingAnchor),
            backCard.trailingAnchor.constraint(equalTo: cardBack.trailingAnchor),
            backCard.bottomAnchor.constraint(equalTo: cardBack.bottomAnchor),
            frontCard.topAnchor.constraint(equalTo: cardFront.topAnchor),
            frontCard.leadingAnchor.constraint(equalTo: cardFront.leadingAnchor),
            frontCard.trailingAnchor.constraint(equalTo: cardFront.trailingAnchor),
            frontCard.bottomAnchor.constraint(equalTo: cardFront.bottomAnchor),
            cardBack.topAnchor.constraint(equalTo: cardsHost.topAnchor),
            cardBack.leadingAnchor.constraint(equalTo: cardsHost.leadingAnchor, constant: OnboardingAnim.cardBackInset),
            cardBack.trailingAnchor.constraint(equalTo: cardsHost.trailingAnchor, constant: -OnboardingAnim.cardBackInset),
            cardFront.topAnchor.constraint(equalTo: cardsHost.topAnchor, constant: OnboardingAnim.cardFrontOffset),
            cardFront.leadingAnchor.constraint(equalTo: cardsHost.leadingAnchor),
            cardFront.trailingAnchor.constraint(equalTo: cardsHost.trailingAnchor),
            cardFront.bottomAnchor.constraint(equalTo: cardsHost.bottomAnchor),
        ])
        cardBack.transform = cardBackFinalTransform
        cardFront.transform = cardFrontFinalTransform
        stack.addArrangedSubview(cardsHost)
        return page
    }

    // 第 2 页：理解可见范围（演示用卡片列表，不是真实编辑器的分段控件样子）。
    private func buildPageTwo() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        optionButtons = []
        for demo in OnboardingVisibilityDemo.allCases {
            let button = OnboardingOptionButton(demo: demo)
            button.addTarget(self, action: #selector(optionTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            optionButtons.append(button)
            stack.addArrangedSubview(button)
        }

        // 下方示例日记：随点选同步变官方图标、状态标签、解释文字。
        let demoCard = UIView()
        demoCard.translatesAutoresizingMaskIntoConstraints = false
        demoCard.backgroundColor = BearyColors.faint
        demoCard.layer.cornerRadius = 16
        let demoStack = UIStackView()
        demoStack.translatesAutoresizingMaskIntoConstraints = false
        demoStack.axis = .vertical
        demoStack.spacing = 10
        let pillRow = UIStackView()
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        pillRow.axis = .horizontal
        pillRow.spacing = 8
        pillRow.alignment = .center
        demoIconView.translatesAutoresizingMaskIntoConstraints = false
        demoIconView.tintColor = BearyColors.ink
        demoPill.translatesAutoresizingMaskIntoConstraints = false
        demoPillLabel.translatesAutoresizingMaskIntoConstraints = false
        demoPillLabel.font = scaledFont(size: 13, weight: .semibold)
        demoPillLabel.textAlignment = .center
        demoPillLabel.adjustsFontForContentSizeCategory = true
        demoPill.addSubview(demoPillLabel)
        pillRow.addArrangedSubview(demoIconView)
        pillRow.addArrangedSubview(demoPill)
        demoBodyLabel.translatesAutoresizingMaskIntoConstraints = false
        demoBodyLabel.font = BearyDynamicType.diaryBodyFont()
        demoBodyLabel.textColor = BearyColors.ink
        demoBodyLabel.numberOfLines = 0
        demoBodyLabel.adjustsFontForContentSizeCategory = true
        demoBodyLabel.text = "今天绕了一点远路。"
        demoExplainLabel.translatesAutoresizingMaskIntoConstraints = false
        demoExplainLabel.font = scaledFont(size: 13)
        demoExplainLabel.textColor = BearyColors.gray
        demoExplainLabel.numberOfLines = 0
        demoExplainLabel.adjustsFontForContentSizeCategory = true
        demoStack.addArrangedSubview(pillRow)
        demoStack.addArrangedSubview(demoBodyLabel)
        demoStack.addArrangedSubview(demoExplainLabel)
        demoCard.addSubview(demoStack)
        NSLayoutConstraint.activate([
            demoIconView.widthAnchor.constraint(equalToConstant: 20),
            demoIconView.heightAnchor.constraint(equalToConstant: 20),
            demoPillLabel.topAnchor.constraint(equalTo: demoPill.topAnchor, constant: 3),
            demoPillLabel.leadingAnchor.constraint(equalTo: demoPill.leadingAnchor, constant: 11),
            demoPillLabel.trailingAnchor.constraint(equalTo: demoPill.trailingAnchor, constant: -11),
            demoPillLabel.bottomAnchor.constraint(equalTo: demoPill.bottomAnchor, constant: -3),
            demoStack.topAnchor.constraint(equalTo: demoCard.topAnchor, constant: 16),
            demoStack.leadingAnchor.constraint(equalTo: demoCard.leadingAnchor, constant: 16),
            demoStack.trailingAnchor.constraint(equalTo: demoCard.trailingAnchor, constant: -16),
            demoStack.bottomAnchor.constraint(equalTo: demoCard.bottomAnchor, constant: -16),
        ])
        stack.addArrangedSubview(demoCard)
        stack.setCustomSpacing(18, after: optionButtons.last!)
        let note = makeLabel(size: 12, color: BearyColors.gray, alignment: .center)
        note.text = "示例，不会发布"
        stack.addArrangedSubview(note)
        stack.setCustomSpacing(14, after: demoCard)
        applyVisibilitySelection()
        return page
    }

    // 第 3 页：体验小熊回应。
    private func buildPageThree() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        // 中央示例公开日记（公开橙 pill＋日期＋官方天气图标）。
        let demoCard = UIView()
        demoCard.translatesAutoresizingMaskIntoConstraints = false
        demoCard.backgroundColor = BearyColors.faint
        demoCard.layer.cornerRadius = 16
        let demoStack = UIStackView()
        demoStack.translatesAutoresizingMaskIntoConstraints = false
        demoStack.axis = .vertical
        demoStack.spacing = 10
        let pillWrap = UIStackView()
        pillWrap.translatesAutoresizingMaskIntoConstraints = false
        pillWrap.axis = .horizontal
        pillWrap.alignment = .center
        let pill = OnboardingCapsuleView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.borderWidth = 1
        pill.layer.borderColor = BearyColors.alpha(BearyColors.orange, 0.45).cgColor
        let pillLabel = UILabel()
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = scaledFont(size: 13, weight: .semibold)
        pillLabel.textColor = BearyColors.orange
        pillLabel.textAlignment = .center
        pillLabel.adjustsFontForContentSizeCategory = true
        pillLabel.text = "公开"
        pill.addSubview(pillLabel)
        pillWrap.addArrangedSubview(pill)
        let demoBody = makeLabel(size: 16, color: BearyColors.ink)
        demoBody.text = "今天绕了一点远路。"
        let dateRow = UIStackView()
        dateRow.translatesAutoresizingMaskIntoConstraints = false
        dateRow.axis = .horizontal
        dateRow.spacing = 6
        dateRow.alignment = .center
        let dateLabel = makeLabel(size: 13, color: BearyColors.gray)
        dateLabel.text = "今天"
        let weatherView = UIImageView()
        weatherView.translatesAutoresizingMaskIntoConstraints = false
        weatherView.image = BearyIconImages.image(named: "icon_wx_sun", pointSize: 18)
        weatherView.tintColor = BearyColors.ink
        dateRow.addArrangedSubview(dateLabel)
        dateRow.addArrangedSubview(weatherView)
        demoStack.addArrangedSubview(pillWrap)
        demoStack.addArrangedSubview(demoBody)
        demoStack.addArrangedSubview(dateRow)
        demoCard.addSubview(demoStack)
        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            pillLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 11),
            pillLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -11),
            pillLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            weatherView.widthAnchor.constraint(equalToConstant: 18),
            weatherView.heightAnchor.constraint(equalToConstant: 18),
            demoStack.topAnchor.constraint(equalTo: demoCard.topAnchor, constant: 16),
            demoStack.leadingAnchor.constraint(equalTo: demoCard.leadingAnchor, constant: 16),
            demoStack.trailingAnchor.constraint(equalTo: demoCard.trailingAnchor, constant: -16),
            demoStack.bottomAnchor.constraint(equalTo: demoCard.bottomAnchor, constant: -16),
        ])
        stack.addArrangedSubview(demoCard)

        // 回应标签：点选后才出现；只让新增元素入场一次，后续改选只换内容、不重播。
        responseChip.translatesAutoresizingMaskIntoConstraints = false
        responseChip.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.07)
        responseChip.isHidden = true
        responseChipIcon.translatesAutoresizingMaskIntoConstraints = false
        responseChipCount.translatesAutoresizingMaskIntoConstraints = false
        responseChipCount.font = scaledFont(size: 14, weight: .semibold)
        responseChipCount.textColor = BearyColors.ink
        responseChipCount.adjustsFontForContentSizeCategory = true
        responseChip.addSubview(responseChipIcon)
        responseChip.addSubview(responseChipCount)
        NSLayoutConstraint.activate([
            responseChipIcon.leadingAnchor.constraint(equalTo: responseChip.leadingAnchor, constant: 8),
            responseChipIcon.centerYAnchor.constraint(equalTo: responseChip.centerYAnchor),
            responseChipIcon.widthAnchor.constraint(equalToConstant: 24),
            responseChipIcon.heightAnchor.constraint(equalToConstant: 24),
            responseChipCount.leadingAnchor.constraint(equalTo: responseChipIcon.trailingAnchor, constant: 6),
            responseChipCount.trailingAnchor.constraint(equalTo: responseChip.trailingAnchor, constant: -14),
            responseChipCount.centerYAnchor.constraint(equalTo: responseChip.centerYAnchor),
            responseChip.heightAnchor.constraint(equalToConstant: 36),
        ])
        let chipWrap = UIStackView(arrangedSubviews: [responseChip])
        chipWrap.translatesAutoresizingMaskIntoConstraints = false
        chipWrap.axis = .horizontal
        chipWrap.alignment = .center
        stack.addArrangedSubview(chipWrap)
        stack.setCustomSpacing(20, after: demoCard)

        // 官方 hug、love、cheer 表情：复杂表情复用现有 Lottie，点一只播一次，不自动轮播。
        let emoteRow = UIStackView()
        emoteRow.translatesAutoresizingMaskIntoConstraints = false
        emoteRow.axis = .horizontal
        emoteRow.spacing = 24
        emoteRow.alignment = .center
        for key in ["hug", "love", "cheer"] {
            let button = BearyHit44Button(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.backgroundColor = BearyColors.faint
            button.layer.cornerRadius = 42
            button.layer.borderWidth = 0
            button.accessibilityLabel = BearyText.moodNames[key] ?? key
            button.addTarget(self, action: #selector(emoteTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            let emoteView = BearyEmoteView(key: key, animated: false)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            emoteView.isUserInteractionEnabled = false
            button.addSubview(emoteView)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 84),
                button.heightAnchor.constraint(equalToConstant: 84),
                emoteView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                emoteView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                emoteView.widthAnchor.constraint(equalToConstant: 56),
                emoteView.heightAnchor.constraint(equalToConstant: 56),
            ])
            emoteButtons[key] = button
            emoteViews[key] = emoteView
            emoteRow.addArrangedSubview(button)
        }
        let emoteWrap = UIStackView(arrangedSubviews: [emoteRow])
        emoteWrap.translatesAutoresizingMaskIntoConstraints = false
        emoteWrap.axis = .horizontal
        emoteWrap.alignment = .center
        stack.addArrangedSubview(emoteWrap)
        stack.setCustomSpacing(28, after: chipWrap)

        let note = makeLabel(size: 12, color: BearyColors.gray, alignment: .center)
        note.text = "示例，不会产生真实回应"
        stack.addArrangedSubview(note)
        stack.setCustomSpacing(14, after: emoteWrap)
        return page
    }

    // 第 4 页：开始使用（中央一张收拢的日记卡片＋示例提示）。
    private func buildPageFour() -> UIView {
        let page = UIView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        let promptCard = UIView()
        promptCard.translatesAutoresizingMaskIntoConstraints = false
        promptCard.backgroundColor = BearyColors.faint
        promptCard.layer.cornerRadius = 16
        let prompt = makeLabel(size: 17, color: BearyColors.gray, alignment: .center)
        prompt.text = "今天，想记住什么？"
        promptCard.addSubview(prompt)
        NSLayoutConstraint.activate([
            prompt.topAnchor.constraint(equalTo: promptCard.topAnchor, constant: 48),
            prompt.leadingAnchor.constraint(equalTo: promptCard.leadingAnchor, constant: 20),
            prompt.trailingAnchor.constraint(equalTo: promptCard.trailingAnchor, constant: -20),
            prompt.bottomAnchor.constraint(equalTo: promptCard.bottomAnchor, constant: -48),
        ])
        stack.addArrangedSubview(promptCard)
        return page
    }

    // MARK: - 顶栏与底部文案（随页切换；已有元素不重播入场动效，只换文案）

    private func pageTitle(_ page: Int) -> String {
        switch page {
        case 0: return "把今天，交给小熊。"
        case 1: return "写下来，也选好谁能看。"
        case 2: return "有些心情，一只小熊就懂。"
        default: return "从今天的一小件事开始。"
        }
    }

    private func pageSubtitle(_ page: Int) -> String {
        switch page {
        case 0: return "记下一点生活，也留住当时的心情。"
        case 1: return "发布前，确认这篇日记的可见范围。"
        case 2: return "用小熊回应，让一句日常被温柔接住。"
        default: return "不必写得完整，想记下的就值得留下。"
        }
    }

    private func pagePrimaryTitle(_ page: Int) -> String {
        switch page {
        case 0: return "认识 beary"
        case 1: return "继续"
        case 2: return "继续"
        default: return SessionManager.shared.isLoggedIn ? "写下第一篇" : "登录，开始记录"
        }
    }

    private func pageSecondaryTitle() -> String {
        return SessionManager.shared.isLoggedIn ? "先逛逛" : "先看看公开日记"
    }

    private func updateChrome() {
        for (index, seg) in segmentViews.enumerated() {
            // 预览口径：只有当前段填充，其余为线色（不做已走过的累计填充）。
            seg.backgroundColor = index == currentPage ? BearyColors.ink : BearyColors.line
        }
        let showBack = currentPage >= 1
        backButton.alpha = showBack ? 1 : 0
        backButton.isEnabled = showBack
        backButton.accessibilityElementsHidden = !showBack
        titleLabel.text = pageTitle(currentPage)
        subtitleLabel.text = pageSubtitle(currentPage)
        primaryButton.setTitle(pagePrimaryTitle(currentPage), for: .normal)
        if currentPage == 3 {
            secondaryButton.setTitle(pageSecondaryTitle(), for: .normal)
            secondaryButton.isHidden = false
        } else {
            secondaryButton.isHidden = true
        }
    }

    // MARK: - 翻页状态机

    private func showPageImmediately(_ page: Int) {
        for (index, edges) in pageEdgeConstraints.enumerated() {
            let active = index == page
            for constraint in edges { constraint.isActive = active }
            pageViews[index].isHidden = !active
            pageViews[index].alpha = active ? 1 : 0
            pageViews[index].transform = .identity
        }
        currentPage = page
        updateChrome()
        view.layoutIfNeeded()
    }

    private func goTo(_ page: Int, animated: Bool) {
        let target = max(0, min(3, page))
        guard !finished else { return }
        if isTransitioning {
            // 转场中再点：只记最后一次目标，当前转场结束后再走，避免动画叠加与页码错乱。
            pendingPage = target
            return
        }
        guard target != currentPage else { return }
        let fromView = pageViews[currentPage]
        let forward = target > currentPage
        guard animated && BearyMotion.animated(true) else {
            showPageImmediately(target)
            playEntranceIfNeeded(target)
            return
        }
        isTransitioning = true
        UIView.animate(withDuration: OnboardingAnim.pageHalfDuration, animations: {
            fromView.transform = CGAffineTransform(translationX: forward ? -OnboardingAnim.pageSlide : OnboardingAnim.pageSlide)
            fromView.alpha = 0
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            // 转场中已跳过／已走完：直接收尾，不再续播、不再处理挂起页码。
            if self.finished {
                self.isTransitioning = false
                self.pendingPage = nil
                return
            }
            if self.currentPage == 3 { self.stopAllEmotes() }
            self.showPageImmediately(target)
            let toView = self.pageViews[target]
            toView.transform = CGAffineTransform(translationX: forward ? OnboardingAnim.pageSlide : -OnboardingAnim.pageSlide)
            toView.alpha = 0
            UIView.animate(withDuration: OnboardingAnim.pageHalfDuration, animations: {
                toView.transform = .identity
                toView.alpha = 1
            }, completion: { [weak self] _ in
                guard let self = self else { return }
                self.isTransitioning = false
                self.playEntranceIfNeeded(target)
                if let pending = self.pendingPage {
                    self.pendingPage = nil
                    if pending != self.currentPage && !self.finished {
                        self.goTo(pending, animated: true)
                    }
                }
            })
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        pendingPage = nil
        stopAllEmotes()
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 入场错峰（只改 transform 与 opacity；每页演示结束后安静）

    private func preparePageOneEntrance() {
        // 首帧前先摆好入场起点：小熊轻微缩小＋下沉、卡片淡出＋下沉、底部卡片淡出＋下沉。
        bearWrap.alpha = 0
        bearWrap.transform = CGAffineTransform(scaleX: 0.96, y: 0.96).translatedBy(x: 0, y: 6)
        cardBack.alpha = 0
        cardBack.transform = cardBackFinalTransform.translatedBy(x: 0, y: 10)
        cardFront.alpha = 0
        cardFront.transform = cardFrontFinalTransform.translatedBy(x: 0, y: 10)
        bottomCard.alpha = 0
        bottomCard.transform = CGAffineTransform(translationX: 0, y: 8)
    }

    private func playEntranceIfNeeded(_ page: Int) {
        guard page == 0, !entrancePlayedPages.contains(0), !UIAccessibility.isReduceMotionEnabled else { return }
        entrancePlayedPages.insert(0)
        // Logo（小熊）→ 卡片 → 标题（底部卡片）依次自然出现；小熊轻动一次后安静停留，不循环。
        let items: [(view: UIView, delay: TimeInterval, finalTransform: CGAffineTransform)] = [
            (bearWrap, 0, .identity),
            (cardBack, OnboardingAnim.staggerStep, cardBackFinalTransform),
            (cardFront, OnboardingAnim.staggerStep * 2, cardFrontFinalTransform),
            (bottomCard, OnboardingAnim.staggerStep * 3, .identity),
        ]
        for item in items {
            UIView.animate(withDuration: OnboardingAnim.entranceDuration, delay: item.delay, options: [.curveEaseOut], animations: {
                item.view.alpha = 1
                item.view.transform = item.finalTransform
            }, completion: nil)
        }
    }

    // MARK: - 第 2 页演示

    private func applyVisibilitySelection() {
        for button in optionButtons {
            button.setSelected(button.demo == selectedVisibility)
        }
        demoIconView.image = BearyIconImages.image(named: selectedVisibility.iconName, pointSize: 20)
        demoPillLabel.text = selectedVisibility.pillText
        demoPillLabel.textColor = selectedVisibility.pillColor
        demoExplainLabel.text = selectedVisibility.explain
        refreshDynamicBorders()
    }

    private func refreshDynamicBorders() {
        for button in optionButtons {
            button.refreshBorder()
        }
        demoPill.layer.borderWidth = 1
        demoPill.layer.borderColor = BearyColors.alpha(selectedVisibility.pillColor, 0.45).cgColor
    }

    // MARK: - 第 3 页演示（离屏立即停播）

    private func stopAllEmotes() {
        for emoteView in emoteViews.values {
            emoteView.stop()
        }
    }

    private func selectEmote(_ key: String) {
        // 其余先冻结为静态帧，再把点中的一只从头播一次；不自动轮播、不加满屏粒子。
        for (otherKey, otherView) in emoteViews {
            if otherKey != key { otherView.showStaticFrame() }
        }
        if let current = emoteViews[key] {
            current.stop()
            current.play()
        }
        for (buttonKey, button) in emoteButtons {
            let selected = buttonKey == key
            button.layer.borderWidth = selected ? 2 : 0
            button.layer.borderColor = BearyColors.orange.cgColor
            button.backgroundColor = selected ? BearyColors.alpha(BearyColors.orange, 0.07) : BearyColors.faint
        }
        selectedEmote = key
        let isDark = traitCollection.userInterfaceStyle == .dark
        if let icon = BearyEmoteImages.image(for: key, dark: isDark) {
            responseChipIcon.image = icon
        } else {
            responseChipIcon.image = nil
        }
        responseChipCount.text = "1"
        if !chipAppeared {
            chipAppeared = true
            responseChip.isHidden = false
            responseChip.alpha = 0
            responseChip.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            if BearyMotion.animated(true) {
                UIView.animate(withDuration: 0.2, animations: {
                    self.responseChip.alpha = 1
                    self.responseChip.transform = .identity
                })
            } else {
                responseChip.alpha = 1
                responseChip.transform = .identity
            }
        }
    }

    // MARK: - 动作

    @objc private func backTapped() {
        goTo(currentPage - 1, animated: true)
    }

    @objc private func skipTapped() {
        finish()
    }

    @objc private func swipedLeft() {
        goTo(currentPage + 1, animated: true)
    }

    @objc private func swipedRight() {
        goTo(currentPage - 1, animated: true)
    }

    @objc private func primaryTapped() {
        if currentPage < 3 {
            goTo(currentPage + 1, animated: true)
            return
        }
        // 第 4 页：只回调、不自行 dismiss；闭包未设置时回退为走完（写 seenKey＋dismiss）。
        if SessionManager.shared.isLoggedIn {
            if let action = onRequestCompose { action() } else { finish() }
        } else {
            if let action = onRequestLogin { action() } else { finish() }
        }
    }

    @objc private func secondaryTapped() {
        guard currentPage == 3 else { return }
        if SessionManager.shared.isLoggedIn {
            if let action = onRequestBrowse { action() } else { finish() }
        } else {
            if let action = onRequestGuestBrowse { action() } else { finish() }
        }
    }

    @objc private func optionTapped(_ sender: OnboardingOptionButton) {
        selectedVisibility = sender.demo
        applyVisibilitySelection()
    }

    @objc private func emoteTapped(_ sender: UIButton) {
        for (key, button) in emoteButtons where button == sender {
            selectEmote(key)
            return
        }
    }
}

// MARK: - 演示用选项卡片（第 2 页；不是真实编辑器的分段控件样子）

private final class OnboardingOptionButton: BearyHit44Button {
    let demo: OnboardingVisibilityDemo
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkView = UIView()
    private let checkImageView = UIImageView()
    private var isOptionSelected = false

    init(demo: OnboardingVisibilityDemo) {
        self.demo = demo
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = BearyColors.surface
        layer.cornerRadius = 16
        layer.borderWidth = 1.5
        layer.borderColor = BearyColors.line.cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: demo.iconName, pointSize: 28)
        iconView.tintColor = BearyColors.ink
        addSubview(iconView)

        let textStack = UIStackView()
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        titleLabel.textColor = BearyColors.ink
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = demo.title
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.numberOfLines = 0
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.text = demo.subtitle
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        addSubview(textStack)

        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.layer.cornerRadius = 12
        checkView.layer.borderWidth = 2
        checkView.layer.borderColor = BearyColors.line.cgColor
        checkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkImageView.image = BearyIconImages.image(named: "icon_check", pointSize: 14)
        checkImageView.tintColor = BearyColors.bg
        checkView.addSubview(checkImageView)
        addSubview(checkView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            checkView.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: 12),
            checkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 24),
            checkView.heightAnchor.constraint(equalToConstant: 24),
            checkImageView.centerXAnchor.constraint(equalTo: checkView.centerXAnchor),
            checkImageView.centerYAnchor.constraint(equalTo: checkView.centerYAnchor),
            checkImageView.widthAnchor.constraint(equalToConstant: 14),
            checkImageView.heightAnchor.constraint(equalToConstant: 14),
        ])
        setSelected(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        isOptionSelected = selected
        backgroundColor = selected ? BearyColors.alpha(BearyColors.orange, 0.07) : BearyColors.surface
        checkView.backgroundColor = selected ? BearyColors.orange : .clear
        checkImageView.isHidden = !selected
        refreshBorder()
    }

    func refreshBorder() {
        layer.borderWidth = isOptionSelected ? 2 : 1.5
        layer.borderColor = isOptionSelected ? BearyColors.orange.cgColor : BearyColors.line.cgColor
        checkView.layer.borderColor = isOptionSelected ? BearyColors.orange.cgColor : BearyColors.line.cgColor
    }
}

// MARK: - 约束优先级小助手（文件内私有）

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
