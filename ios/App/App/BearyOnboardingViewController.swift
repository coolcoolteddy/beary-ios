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
// - seenKey 归属（审计登录杂项复核结论，2026-11-02）：闭包已设置时写 key 是容器
//   的责任，SceneDelegate.presentOnboarding 的四个回调与 presentLoginOverOnboarding
//   均已逐项核实写 seenKey（本页不重复写，避免时序竞态）；本页只在闭包未设置
//   的兜底路径与“跳过”时自己写。断言说明：写 key 的语句就写在容器回调本体里，
//   无需另补运行时断言——回调执行即写 key，不存在“回调只跳转不写 key”的分支。
// - 下滑关闭不存在：isModalInPresentation = true 全程禁下滑关闭，故无“下滑关闭
//   时写 seenKey”的路径；退出只走跳过（写 key）与第 4 页主 / 次钮回调（容器写 key）。
// - 跳过：写 seenKey = true 后自行 dismiss（modal 下方就是主页或设置页，直接露出即可）。
// 旧 VC 的预加载步骤 API 已随整文件替换而消失，SceneDelegate 的 presentOnboarding 会暂时
// 无法编译——这是预期的，第 2 棒会重写它，本文件不碰 SceneDelegate。
// 注意：本页不调任何写接口、不改用户默认设置；第 2 页演示只改示例态，第 3 页不产生真实回应。
// 星环装饰：仓库内没有主站 hero 星环同款资产（仅有单颗 icon_star，非星环），按任务要求去掉，
// 不自绘、不拿 SF Symbol 做主图标。

// MARK: - 动效与布局常量（文件内私有）

private enum OnboardingAnim {
    /// 互动翻页落点弹簧（规范 §6 引导专属档，取代旧 0.14＋0.14 两段切）：
    /// 0.30s／damping 0.7；快甩把松手速度按页宽归一化后传 initialSpringVelocity，慢拖为 0。
    static let pageSpringDuration: TimeInterval = 0.30
    static let pageSpringDamping: CGFloat = 0.7
    /// 松手判据：拖过页宽 1/3，或沿翻页方向速度 ＞600pt/s。
    static let pageCommitFraction: CGFloat = 1.0 / 3.0
    static let pageFlingVelocity: CGFloat = 600
    /// 入场错峰间隔；总入场 0.5 秒内（0.09 末位延迟 + 0.25 播长 = 0.34）。
    static let staggerStep: TimeInterval = 0.03
    static let entranceDuration: TimeInterval = 0.25
    /// 第 1 页两张卡片的错位：后卡左右各缩 10，前卡下压 80、微转 0.5°，后卡微转 -3.5°。
    static let cardBackInset: CGFloat = 10
    static let cardFrontOffset: CGFloat = 80
    static let cardBackRotation: CGFloat = -3.5 * CGFloat.pi / 180
    static let cardFrontRotation: CGFloat = 0.5 * CGFloat.pi / 180
}

// MARK: - 圆角 pill 容器（pill / 回应 chip 共用：圆角恒为半高，深浅与字号变化时自动跟随）

private final class OnboardingPillView: UIView {
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
    /// 引导页主视觉区引导（heroContent 顶部 → 底部卡片顶部）：短内容时示例区
    /// 在该区内居中（与旧布局一致），长内容时整页滚动、卡片跟内容走。
    private let heroAreaGuide = UILayoutGuide()
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
    private let demoPill = OnboardingPillView()
    private let demoPillLabel = UILabel()
    private let demoBodyLabel = UILabel()
    private let demoExplainLabel = UILabel()

    // 第 3 页元素。
    private let responseChip = OnboardingPillView()
    private let responseChipIcon = UIImageView()
    private let responseChipCount = UILabel()
    private var emoteButtons: [String: UIButton] = [:]
    private var emoteViews: [String: BearyEmoteView] = [:]
    /// 天气示例图标覆盖层（第 0 页两张示例卡＋第 2 页演示卡各一，均为太阳）：
    /// 播／停由页面切换统一管（refreshWeatherEmotes），只播当前可见页的。
    private var weatherEmoteViews: [BearyEmoteView] = []

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
        refreshWeatherEmotes()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopAllEmotes()
        for weatherEmoteView in weatherEmoteViews {
            weatherEmoteView.stop()
        }
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
        skipButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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

        // 底部圆角卡片：BearyColors surface2 底、顶部圆角 28、通栏。
        bottomCard.translatesAutoresizingMaskIntoConstraints = false
        bottomCard.backgroundColor = BearyColors.surface2
        bottomCard.layer.cornerRadius = BearyCorners.single
        bottomCard.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        heroContent.addSubview(bottomCard)

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
        primaryButton.layer.cornerRadius = BearyCorners.single
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

        // 互动翻页与按钮共用翻页状态机（UIPan 手势 1:1 跟手；点按仍走按钮，
        // 横滑接管后按钮触摸自动取消，不会误触）。竖滑留给 heroScroll：
        // 方向仲裁见 gestureRecognizerShouldBegin，heroScroll 的 pan 须等
        // 本手势失败才启动，避免横滑被滚动抢走（同回收站行拖动模式）。
        let pagePan = UIPanGestureRecognizer(target: self, action: #selector(onboardingPanned(_:)))
        pagePan.delegate = self
        view.addGestureRecognizer(pagePan)
        heroScroll.panGestureRecognizer.require(toFail: pagePan)

        heroContent.addLayoutGuide(heroAreaGuide)
        topCap = topWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        columnCap = columnView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        bottomCap = bottomStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        NSLayoutConstraint.activate([
            topWrap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16).withPriority(.defaultHigh),
            topWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16).withPriority(.defaultHigh),
            topWrap.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32).withPriority(.defaultHigh),
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
            heroScroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            heroContent.topAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.topAnchor),
            heroContent.leadingAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.leadingAnchor),
            heroContent.trailingAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.trailingAnchor),
            heroContent.bottomAnchor.constraint(equalTo: heroScroll.contentLayoutGuide.bottomAnchor),
            heroContent.widthAnchor.constraint(equalTo: heroScroll.frameLayoutGuide.widthAnchor),
            heroContent.heightAnchor.constraint(greaterThanOrEqualTo: heroScroll.frameLayoutGuide.heightAnchor),

            columnView.topAnchor.constraint(greaterThanOrEqualTo: heroContent.topAnchor, constant: 8),
            columnView.bottomAnchor.constraint(lessThanOrEqualTo: bottomCard.topAnchor, constant: -16),
            columnView.centerYAnchor.constraint(equalTo: heroAreaGuide.centerYAnchor).withPriority(.defaultLow),
            columnView.centerXAnchor.constraint(equalTo: heroContent.centerXAnchor),
            columnView.leadingAnchor.constraint(greaterThanOrEqualTo: heroContent.leadingAnchor, constant: 16).withPriority(.defaultHigh),
            columnView.trailingAnchor.constraint(lessThanOrEqualTo: heroContent.trailingAnchor, constant: -16).withPriority(.defaultHigh),
            columnView.widthAnchor.constraint(equalTo: heroContent.widthAnchor, constant: -32).withPriority(.defaultHigh),

            bottomCard.leadingAnchor.constraint(equalTo: heroContent.leadingAnchor),
            bottomCard.trailingAnchor.constraint(equalTo: heroContent.trailingAnchor),
            bottomCard.bottomAnchor.constraint(equalTo: heroContent.bottomAnchor),
            bottomStack.topAnchor.constraint(equalTo: bottomCard.topAnchor, constant: 24),
            bottomStack.centerXAnchor.constraint(equalTo: bottomCard.centerXAnchor),
            bottomStack.leadingAnchor.constraint(greaterThanOrEqualTo: bottomCard.safeAreaLayoutGuide.leadingAnchor, constant: 24).withPriority(.defaultHigh),
            bottomStack.trailingAnchor.constraint(lessThanOrEqualTo: bottomCard.safeAreaLayoutGuide.trailingAnchor, constant: -24).withPriority(.defaultHigh),
            heroAreaGuide.topAnchor.constraint(equalTo: heroContent.topAnchor),
            heroAreaGuide.bottomAnchor.constraint(equalTo: bottomCard.topAnchor),
            heroAreaGuide.leadingAnchor.constraint(equalTo: heroContent.leadingAnchor),
            heroAreaGuide.trailingAnchor.constraint(equalTo: heroContent.trailingAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: bottomCard.bottomAnchor, constant: -16),
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

    /// 示例日记卡片（surface2 底、圆角 16）：日期行＋官方天气图标＋正文。
    private func makeDiaryCard(dateText: String, bodyText: String) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.surface2
        card.layer.cornerRadius = BearyCorners.single
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
        // 示例卡太阳贴动态 Lottie（底层静态图作 fallback；播／停由页面切换统一管）。
        if let sunImage = weatherView.image {
            let sunEmote = BearyEmoteView(key: "sun", animated: true, fallbackImage: sunImage)
            sunEmote.translatesAutoresizingMaskIntoConstraints = false
            weatherView.addSubview(sunEmote)
            NSLayoutConstraint.activate([
                sunEmote.topAnchor.constraint(equalTo: weatherView.topAnchor),
                sunEmote.leadingAnchor.constraint(equalTo: weatherView.leadingAnchor),
                sunEmote.trailingAnchor.constraint(equalTo: weatherView.trailingAnchor),
                sunEmote.bottomAnchor.constraint(equalTo: weatherView.bottomAnchor),
            ])
            weatherEmoteViews.append(sunEmote)
        }
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
        demoCard.backgroundColor = BearyColors.surface2
        demoCard.layer.cornerRadius = BearyCorners.single
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
        demoCard.backgroundColor = BearyColors.surface2
        demoCard.layer.cornerRadius = BearyCorners.single
        let demoStack = UIStackView()
        demoStack.translatesAutoresizingMaskIntoConstraints = false
        demoStack.axis = .vertical
        demoStack.spacing = 10
        let pillWrap = UIStackView()
        pillWrap.translatesAutoresizingMaskIntoConstraints = false
        pillWrap.axis = .horizontal
        pillWrap.alignment = .center
        let pill = OnboardingPillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.borderWidth = 1
        pill.layer.bearyDynamicBorderColor = BearyColors.alpha(BearyColors.orange, 0.45)
        let pillLabel = UILabel()
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = scaledFont(size: 13, weight: .semibold)
        pillLabel.textColor = BearyColors.deepOrangeText
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
        // 演示卡太阳贴动态 Lottie（底层静态图作 fallback；播／停由页面切换统一管）。
        if let sunImage = weatherView.image {
            let sunEmote = BearyEmoteView(key: "sun", animated: true, fallbackImage: sunImage)
            sunEmote.translatesAutoresizingMaskIntoConstraints = false
            weatherView.addSubview(sunEmote)
            NSLayoutConstraint.activate([
                sunEmote.topAnchor.constraint(equalTo: weatherView.topAnchor),
                sunEmote.leadingAnchor.constraint(equalTo: weatherView.leadingAnchor),
                sunEmote.trailingAnchor.constraint(equalTo: weatherView.trailingAnchor),
                sunEmote.bottomAnchor.constraint(equalTo: weatherView.bottomAnchor),
            ])
            weatherEmoteViews.append(sunEmote)
        }
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
        responseChip.backgroundColor = BearyColors.surface2
        responseChip.isHidden = true
        responseChipIcon.translatesAutoresizingMaskIntoConstraints = false
        responseChipCount.translatesAutoresizingMaskIntoConstraints = false
        responseChipCount.font = BearyDynamicType.numberFont()
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
            button.backgroundColor = BearyColors.surface2
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
        promptCard.backgroundColor = BearyColors.surface2
        promptCard.layer.cornerRadius = BearyCorners.single
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
        case 0: return "在这里写日记"
        case 1: return "写下来，也选好谁能看。"
        case 2: return "用小熊回应日记。"
        default: return "从今天的一小件事开始。"
        }
    }

    private func pageSubtitle(_ page: Int) -> String {
        switch page {
        case 0: return "写下今天的事和心情。"
        case 1: return "发布前，确认这篇日记的可见范围。"
        case 2: return "用小熊回应这篇日记。"
        default: return "想写什么，就写什么。"
        }
    }

    private func pagePrimaryTitle(_ page: Int) -> String {
        switch page {
        case 0: return "下一步"
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
        backButton.isHidden = !showBack
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
        refreshWeatherEmotes()
        updateChrome()
        view.layoutIfNeeded()
    }

    /// 当前页宽（互动跟手与按钮滑切共用；columnView 即页宽）。
    private func pageWidth() -> CGFloat {
        let width = columnView.bounds.width
        return width > 0 ? width : view.bounds.width
    }

    /// 把目标页摆到屏外待命：与当前页同框（边缘约束与当前页相同，可
    /// 同时激活），transform 偏一页宽；先布局一次再设位移，避免布局
    /// 后 transform 被冲掉。入场错峰随摆位即播（已播过即空操作），
    /// 拖动中目标页内容随页滑入，不留空白页。
    private func stageTargetPage(_ target: Int, forward: Bool) {
        let width = pageWidth()
        for constraint in pageEdgeConstraints[target] { constraint.isActive = true }
        pageViews[target].isHidden = false
        pageViews[target].alpha = 1
        view.layoutIfNeeded()
        pageViews[target].transform = CGAffineTransform(translationX: forward ? width : -width, y: 0)
        refreshWeatherEmotes()
        playEntranceIfNeeded(target)
    }

    /// 转场收尾（按钮滑切与互动松手共用）：落到终页、清转场与拖动旗标、
    /// 播目标页入场（已播过即空操作），再处理转场中挂起的页码。
    /// 转场中已跳过／已走完：直接收尾，不落终页、不处理挂起页码。
    private func completeTransition(to target: Int) {
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
        if let pending = pendingPage {
            pendingPage = nil
            if pending != currentPage && !finished {
                goTo(pending, animated: true)
            }
        }
    }

    /// 按钮翻页：整页宽滑切＋落点弹簧（与互动松手同档），不再走旧
    /// 0.14＋0.14 两段淡入淡出；减动效时直切终态。
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
        if currentPage == 3 { stopAllEmotes() }
        isTransitioning = true
        let width = pageWidth()
        stageTargetPage(target, forward: forward)
        let toView = pageViews[target]
        UIView.animate(withDuration: OnboardingAnim.pageSpringDuration, delay: 0, usingSpringWithDamping: OnboardingAnim.pageSpringDamping, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            fromView.transform = CGAffineTransform(translationX: forward ? -width : width, y: 0)
            toView.transform = .identity
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            self.completeTransition(to: target)
        })
    }

    // MARK: - 互动翻页（1:1 跟手拖动＋松手弹簧落点，规范 §6 引导专属档）

    /// 手势仲裁：只接横向主导的拖动；竖滑、竖滚进行中、转场中、
    /// 已走完时一律不接管（竖滑留给 heroScroll）。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        guard !finished, !isTransitioning else { return false }
        if heroScroll.isDragging || heroScroll.isDecelerating { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        if velocity == .zero {
            let translation = pan.translation(in: view)
            return abs(translation.x) > abs(translation.y)
        }
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func onboardingPanned(_ sender: UIPanGestureRecognizer) {
        switch sender.state {
        case .began:
            // 方向待首个 .changed 判定；转场中或已走完不接管。
            guard !finished, !isTransitioning else { return }
            dragTargetPage = nil
            dragTranslation = 0
        case .changed:
            guard !finished else { return }
            // 按钮转场在途且本次未建拖动：不接管，防两路转场叠加。
            guard dragTargetPage != nil || !isTransitioning else { return }
            let width = pageWidth()
            guard width > 0 else { return }
            let translation = sender.translation(in: view).x
            if dragTargetPage == nil {
                guard translation != 0 else { return }
                let target = translation < 0 ? currentPage + 1 : currentPage - 1
                if target < 0 || target > 3 {
                    // 首尾越界方向：第 0 页右拖、第 3 页左拖不摆目标页、
                    // 不移动，松手即弹回原页。
                    dragTargetPage = currentPage
                    dragTranslation = 0
                    isTransitioning = true
                    return
                }
                if currentPage == 3 { stopAllEmotes() }
                dragTargetPage = target
                isTransitioning = true
                stageTargetPage(target, forward: target > currentPage)
            }
            guard let target = dragTargetPage else { return }
            guard target != currentPage else { return }
            // 1:1 跟手，夹在起止之间：拖回起点外不反向翻目标，避免中途换向。
            let clamped: CGFloat
            if target > currentPage {
                clamped = min(0, max(-width, translation))
            } else {
                clamped = max(0, min(width, translation))
            }
            dragTranslation = clamped
            pageViews[currentPage].transform = CGAffineTransform(translationX: clamped, y: 0)
            pageViews[target].transform = CGAffineTransform(translationX: clamped + (target > currentPage ? width : -width), y: 0)
        case .ended:
            guard let target = dragTargetPage else { return }
            let width = pageWidth()
            let velocity = sender.velocity(in: view).x
            let commit: Bool
            if target == currentPage {
                commit = false
            } else if target > currentPage {
                commit = -dragTranslation > width * OnboardingAnim.pageCommitFraction
                    || velocity < -OnboardingAnim.pageFlingVelocity
            } else {
                commit = dragTranslation > width * OnboardingAnim.pageCommitFraction
                    || velocity > OnboardingAnim.pageFlingVelocity
            }
            settleInteractiveDrag(to: target, commit: commit, velocity: velocity)
        case .cancelled, .failed:
            guard let target = dragTargetPage else { return }
            settleInteractiveDrag(to: target, commit: false, velocity: 0)
        default:
            break
        }
    }

    /// 互动松手落点：提交则目标页弹簧滑入、当前页滑出；否则弹回原页。
    /// 快甩把松手速度按页宽归一化后传 initialSpringVelocity，慢拖为 0；
    /// 减动效开时直切终态，不播弹簧（拖动跟手本身是手指直驱，不属播放动效）。
    private func settleInteractiveDrag(to target: Int, commit: Bool, velocity: CGFloat) {
        let width = pageWidth()
        let finalPage = commit ? target : currentPage
        guard BearyMotion.animated(true) else {
            completeTransition(to: finalPage)
            return
        }
        let flung = abs(velocity) > OnboardingAnim.pageFlingVelocity
        let springVelocity: CGFloat = flung ? abs(velocity) / max(width, 1) : 0
        let fromPage = currentPage
        let fromView = pageViews[fromPage]
        let toView = pageViews[target]
        let forward = target > fromPage
        UIView.animate(withDuration: OnboardingAnim.pageSpringDuration, delay: 0, usingSpringWithDamping: OnboardingAnim.pageSpringDamping, initialSpringVelocity: springVelocity, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            if commit {
                fromView.transform = CGAffineTransform(translationX: forward ? -width : width, y: 0)
                toView.transform = .identity
            } else {
                fromView.transform = .identity
                if target != fromPage {
                    toView.transform = CGAffineTransform(translationX: forward ? width : -width, y: 0)
                }
            }
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            self.completeTransition(to: finalPage)
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

    /// 审计登录杂项：入场错峰抽为按页通用方法——第 0 页沿用原四件套
    /// （小熊 → 卡片 → 标题）；第 1–3 页错峰其页内栈的各段（此前只有
    /// 0.14＋0.14 整页横移淡入）。每页只播一次；减动效时直出终值。
    private func playEntranceIfNeeded(_ page: Int) {
        guard !entrancePlayedPages.contains(page) else { return }
        entrancePlayedPages.insert(page)
        if page == 0 {
            // Logo（小熊）→ 卡片 → 标题（底部卡片）依次自然出现；小熊轻动一次后安静停留，不循环。
            playStaggeredEntrance(items: [
                (bearWrap, 0, .identity),
                (cardBack, OnboardingAnim.staggerStep, cardBackFinalTransform),
                (cardFront, OnboardingAnim.staggerStep * 2, cardFrontFinalTransform),
                (bottomCard, OnboardingAnim.staggerStep * 3, .identity),
            ])
            return
        }
        guard pageViews.indices.contains(page),
              let stack = pageViews[page].subviews.first(where: { $0 is UIStackView }) as? UIStackView else { return }
        let items: [(view: UIView, delay: TimeInterval, finalTransform: CGAffineTransform)] = stack.arrangedSubviews.enumerated().map {
            ($0.element, Double($0.offset) * OnboardingAnim.staggerStep, .identity)
        }
        // 入场起点先摆好（淡出＋下沉 6pt），再走通用错峰；减动效时
        // playStaggeredEntrance 直出终值，不留半透明起点。
        for item in items {
            item.view.alpha = 0
            item.view.transform = CGAffineTransform(translationX: 0, y: 6)
        }
        playStaggeredEntrance(items: items)
    }

    /// 通用错峰播放：只改 transform 与 opacity；减动效时直出终值。
    /// （第 0 页的起点由 viewDidLoad 的 preparePageOneEntrance 预摆，
    /// 第 1–3 页的起点由 playEntranceIfNeeded 现摆，本方法只负责播出。）
    private func playStaggeredEntrance(items: [(view: UIView, delay: TimeInterval, finalTransform: CGAffineTransform)]) {
        if UIAccessibility.isReduceMotionEnabled {
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

    // MARK: - 第 2 页演示

    private func applyVisibilitySelection() {
        for button in optionButtons {
            button.setSelected(button.demo == selectedVisibility)
        }
        demoIconView.image = BearyIconImages.image(named: selectedVisibility.iconName, pointSize: 20)
        demoPillLabel.text = selectedVisibility.pillText
        demoPillLabel.textColor = selectedVisibility == .private ? BearyColors.blue : BearyColors.deepOrangeText
        demoExplainLabel.text = selectedVisibility.explain
        refreshDynamicBorders()
    }

    private func refreshDynamicBorders() {
        for button in optionButtons {
            button.refreshBorder()
        }
        demoPill.layer.borderWidth = 1
        demoPill.layer.bearyDynamicBorderColor = BearyColors.alpha(selectedVisibility.pillColor, 0.45)
    }

    // MARK: - 第 3 页演示（离屏立即停播）

    private func stopAllEmotes() {
        for emoteView in emoteViews.values {
            emoteView.stop()
        }
    }

    /// 天气示例图标只播当前可见页的：页切（直切／滑切／拖动摆位）与首现时按
    /// 实际显隐播／停；隐藏页的播放器不空转（isHidden 不离窗，播放器自身不停）。
    private func refreshWeatherEmotes() {
        for weatherEmoteView in weatherEmoteViews {
            if isEffectivelyVisible(weatherEmoteView) {
                weatherEmoteView.play()
            } else {
                weatherEmoteView.stop()
            }
        }
    }

    /// 自身及全部祖先均未隐藏且已进窗口，才算真正可见。
    private func isEffectivelyVisible(_ view: UIView) -> Bool {
        guard view.window != nil else { return false }
        var current: UIView? = view
        while let node = current {
            if node.isHidden { return false }
            current = node.superview
        }
        return true
    }

    private func selectEmote(_ key: String) {
        // 其余先冻结为静态帧，再把点中的一只从头播一次；不自动轮播、不加满屏粒子。
        for (otherKey, otherView) in emoteViews {
            if otherKey != key { otherView.showStaticFrame() }
        }
        if let current = emoteViews[key] {
            // 点中即主动重播：走显式 replayFromStart()，不要 stop() + play()——
            // play() 现在是恢复语义，已播过开场的只会从暂停帧续播，不会从头播。
            current.replayFromStart()
        }
        for (buttonKey, button) in emoteButtons {
            let selected = buttonKey == key
            button.layer.borderWidth = selected ? 2 : 0
            button.layer.bearyDynamicBorderColor = BearyColors.ink
            button.backgroundColor = selected ? BearyColors.alpha(BearyColors.ink, 0.07) : BearyColors.surface2
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
            responseChip.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            responseChipIcon.transform = .identity
            if BearyMotion.animated(true) {
                // chip-in 0.45s＋图标 wiggle 0.5s（规范 §6；与卡片／详情页 playChipIn 同款口径）。
                UIView.animateKeyframes(withDuration: 0.45, delay: 0, options: [], animations: {
                    UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.6) {
                        self.responseChip.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                        self.responseChip.alpha = 1
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                        self.responseChip.transform = .identity
                        self.responseChip.alpha = 1
                    }
                }, completion: nil)
                UIView.animateKeyframes(withDuration: 0.5, delay: 0, options: [], animations: {
                    UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                        self.responseChipIcon.transform = CGAffineTransform(rotationAngle: -0.1745).scaledBy(x: 1.3, y: 1.3)
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.3) {
                        self.responseChipIcon.transform = CGAffineTransform(rotationAngle: 0.1396).scaledBy(x: 1.15, y: 1.15)
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                        self.responseChipIcon.transform = .identity
                    }
                }, completion: nil)
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

    @objc private func primaryTapped() {
        if currentPage < 3 {
            goTo(currentPage + 1, animated: true)
            return
        }
        // 第 4 页：只回调、不自行 dismiss；闭包未设置时回退为走完（写 seenKey＋dismiss）。
        // seenKey 归属见文件头契约：闭包已设置时容器回调内写 key，本页不重复写。
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
    private let optionTitleLabel = UILabel()
    private let optionSubtitleLabel = UILabel()
    private let checkView = UIView()
    private let checkImageView = UIImageView()
    private var isOptionSelected = false

    init(demo: OnboardingVisibilityDemo) {
        self.demo = demo
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = BearyColors.surface1
        layer.cornerRadius = BearyCorners.single
        layer.borderWidth = 1.5
        layer.bearyDynamicBorderColor = BearyColors.line

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BearyIconImages.image(named: demo.iconName, pointSize: 28)
        iconView.tintColor = BearyColors.ink
        addSubview(iconView)

        let textStack = UIStackView()
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        optionTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        optionTitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        optionTitleLabel.textColor = BearyColors.ink
        optionTitleLabel.adjustsFontForContentSizeCategory = true
        optionTitleLabel.text = demo.title
        optionSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        optionSubtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        optionSubtitleLabel.textColor = BearyColors.gray
        optionSubtitleLabel.numberOfLines = 0
        optionSubtitleLabel.adjustsFontForContentSizeCategory = true
        optionSubtitleLabel.text = demo.subtitle
        textStack.addArrangedSubview(optionTitleLabel)
        textStack.addArrangedSubview(optionSubtitleLabel)
        addSubview(textStack)

        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.layer.cornerRadius = 12
        checkView.layer.borderWidth = 2
        checkView.layer.bearyDynamicBorderColor = BearyColors.line
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
        backgroundColor = selected ? BearyColors.alpha(BearyColors.ink, 0.07) : BearyColors.surface1
        checkView.backgroundColor = selected ? BearyColors.ink : .clear
        checkImageView.isHidden = !selected
        refreshBorder()
    }

    func refreshBorder() {
        layer.borderWidth = isOptionSelected ? 2 : 1.5
        layer.bearyDynamicBorderColor = isOptionSelected ? BearyColors.ink : BearyColors.line
        checkView.layer.bearyDynamicBorderColor = isOptionSelected ? BearyColors.ink : BearyColors.line
    }
}

// MARK: - 约束优先级小助手（文件内私有）

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
