import UIKit

// ===== 景深背景选择页（全屏滑动选择器，2026-11-23，Li 定）=====
// 入口：本人页点封面带 → 选择框「图库／景深背景」→ 本页；他人页不进。
// 全屏滑动：16 张全在里面（默认＋六地封面＋九个节日款），左右滑 1:1 跟手
// 切换；圆点＋缩略图行辅助；每张用真的视图做实时预览，动画只在当前页开、
// 滑走关（与个人页 header 同款省电口径）；页只留当前±1 在内存里，其余拆掉。
// 拥有口径：Plus 拥有全部非默认款（含六张封面）；非 Plus 款显「Plus 专属」
// 锁定态、预览照常看，点应用进 Plus 页（入口③）、不应用；默认档人人可回；
// 当前档点应用直接关闭。节日款带「节日限定」标记。
// 深色压暗与 header 同值（黑遮罩 0.35，封面行不压）；减动效沿用包内 freeze。

final class BearyDepthBackgroundViewController: UIViewController {

    typealias Theme = BearyProfileViewController.FestivalTheme

    private let currentThemeValue: Theme
    /// 第十一轮 04：会员资格是可变快照，不再是 init 定值——Plus 可能在外层
    /// Plus 页→邀请页拿到，init 时的值会过期；回前台时重读（见 refreshPlusStatus）。
    private var isPlusValue: Bool
    /// 点按回调带上选择页最新已知 Plus 态，供个人页应用时再次验证权限
    ///（第十一轮 04：只认个人页 profile.plus 会把刚到账的 Plus 挡在门外）。
    private let onPickValue: (Theme, Bool) -> Bool
    /// 预览顶部的头像与名字（编辑资料页传来，画出来像个人页封面的样子）；
    /// 没传就不叠这一层。
    private let avatarImageValue: UIImage?
    private let displayNameValue: String?
    /// 首次出现不拉 /me：值刚从个人页 profile.plus 传来；之后每次回前台再重读。
    private var hasAppearedOnce = false
    /// 审计四轮第 6 项：会员状态请求的代次——viewWillAppear 每次回前台都发
    /// 一次 /me，旧回包乱序到达会覆盖新状态；只认最新一次请求的回包。
    private var plusStatusRequestSequence = 0
    /// 滑动中：拖动开始先关全部动效，停稳后才给当前页开（与旧列表页同款口径）。
    private var isScrollingPreviews = false
    /// Plus 页的 EdgeDismiss 强持有（仅窄屏全屏路用，见 presentPlusPage）。
    private var plusPageEdgeDismiss: BearyEdgeDismissController?

    private let themesValue: [Theme] = [.none, .halloween, .spring, .china, .usa, .japan, .germany, .canada, .korea, .qixi, .christmas, .newyear, .easter, .lantern, .midautumn, .muertos]

    /// 当前页下标（init 时按当前主题定位）。
    private var currentIndex = 0
    /// 已建好的预览页（只留当前±1）。
    private var pages: [Int: BearyDepthBackgroundPage] = [:]
    /// 上一次布局的页宽；变了才重算页帧与偏移（转屏／分屏时用）。
    private var lastPageWidth: CGFloat = 0
    private var thumbButtons: [UIButton] = []
    private var thumbPosterCache: [ProfileCoverTheme: UIImage] = [:]

    init(currentTheme: Theme, isPlus: Bool, avatarImage: UIImage? = nil, displayName: String? = nil, onPick: @escaping (Theme, Bool) -> Bool) {
        self.currentThemeValue = currentTheme
        self.isPlusValue = isPlus
        self.avatarImageValue = avatarImage
        self.displayNameValue = displayName
        self.onPickValue = onPick
        super.init(nibName: nil, bundle: nil)
        self.currentIndex = themesValue.firstIndex(of: currentTheme) ?? 0
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private let topBarView = UIView()

    private lazy var backButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let titleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "景深背景"
        return labelValue
    }()

    /// 内容列：仅 iPad 且宽 ≥821 时 600 居中，其余屏宽全宽（旧列表页同款口径）；
    /// cap 只在宽屏激活，窄屏不收窄到 600。
    private let columnView = UIView()
    private var columnCapConstraint: NSLayoutConstraint?

    private lazy var pagingScrollView: UIScrollView = {
        let scrollValue = UIScrollView()
        scrollValue.translatesAutoresizingMaskIntoConstraints = false
        scrollValue.isPagingEnabled = true
        scrollValue.showsHorizontalScrollIndicator = false
        scrollValue.showsVerticalScrollIndicator = false
        scrollValue.contentInsetAdjustmentBehavior = .never
        scrollValue.backgroundColor = BearyColors.bg
        scrollValue.delegate = self
        scrollValue.clipsToBounds = true
        return scrollValue
    }()

    /// 预览顶部的头像＋名字（不跟页走，固定叠在预览区左上角；不挡手势）。
    private let headerOverlayView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.isUserInteractionEnabled = false
        return viewValue
    }()

    private let overlayAvatarImageView: UIImageView = {
        let imageValue = UIImageView()
        imageValue.translatesAutoresizingMaskIntoConstraints = false
        imageValue.contentMode = .scaleAspectFill
        imageValue.clipsToBounds = true
        imageValue.layer.cornerRadius = 20
        imageValue.layer.borderWidth = 2
        imageValue.layer.borderColor = UIColor.white.cgColor
        return imageValue
    }()

    private let overlayNameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.pageTitleFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = .white
        labelValue.shadowColor = UIColor.black.withAlphaComponent(0.5)
        labelValue.shadowOffset = CGSize(width: 0, height: 1)
        return labelValue
    }()

    private let bottomStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = BearySpace.md
        return stackValue
    }()

    private let nameRow: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = BearySpace.sm
        stackValue.alignment = .center
        return stackValue
    }()

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cardTitleFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        return labelValue
    }()

    private let stateLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.buttonRegularFont()
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private let pageControl: UIPageControl = {
        let controlValue = UIPageControl()
        controlValue.translatesAutoresizingMaskIntoConstraints = false
        controlValue.isUserInteractionEnabled = false
        controlValue.currentPageIndicatorTintColor = BearyColors.orange
        controlValue.pageIndicatorTintColor = BearyColors.gray
        return controlValue
    }()

    private lazy var thumbnailScrollView: UIScrollView = {
        let scrollValue = UIScrollView()
        scrollValue.translatesAutoresizingMaskIntoConstraints = false
        scrollValue.showsHorizontalScrollIndicator = false
        scrollValue.showsVerticalScrollIndicator = false
        scrollValue.contentInsetAdjustmentBehavior = .never
        return scrollValue
    }()

    private let thumbnailStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .horizontal
        stackValue.spacing = BearySpace.sm
        stackValue.alignment = .center
        return stackValue
    }()

    private lazy var applyButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.backgroundColor = BearyColors.orange
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.titleLabel?.font = BearyDynamicType.buttonFont()
        buttonValue.setTitleColor(.white, for: .normal)
        buttonValue.addTarget(self, action: #selector(applyButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private lazy var plusFooterLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.numberOfLines = 0
        labelValue.text = "仅 Plus 会员可使用景深背景"
        return labelValue
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = BearyColors.bg
        view.addSubview(topBarView)
        topBarView.addSubview(backButton)
        topBarView.addSubview(titleLabel)
        columnView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columnView)
        columnView.addSubview(pagingScrollView)
        columnView.addSubview(headerOverlayView)
        headerOverlayView.addSubview(overlayAvatarImageView)
        headerOverlayView.addSubview(overlayNameLabel)
        if let image = avatarImageValue {
            overlayAvatarImageView.image = image
        }
        overlayNameLabel.text = displayNameValue
        headerOverlayView.isHidden = avatarImageValue == nil && (displayNameValue ?? "").isEmpty
        columnView.addSubview(bottomStack)
        nameRow.addArrangedSubview(nameLabel)
        nameRow.addArrangedSubview(stateLabel)
        bottomStack.addArrangedSubview(nameRow)
        bottomStack.addArrangedSubview(pageControl)
        bottomStack.addArrangedSubview(thumbnailScrollView)
        thumbnailScrollView.addSubview(thumbnailStack)
        bottomStack.addArrangedSubview(applyButton)
        bottomStack.addArrangedSubview(plusFooterLabel)
        pageControl.numberOfPages = themesValue.count
        for (index, theme) in themesValue.enumerated() {
            let thumb = makeThumbnail(for: theme, index: index)
            thumbnailStack.addArrangedSubview(thumb)
            thumbButtons.append(thumb)
        }
        // 内容列：centerX ＋ defaultHigh 的全宽撑满（只靠 centerX＋两侧
        // 不等式列宽会跟着内容走，见 2026-11-02 居中列布局陷阱）；仅 iPad 且宽 ≥821 时
        // cap 600 生效居中，其余 cap 关掉、不收窄。
        let columnWidth = columnView.widthAnchor.constraint(equalTo: view.widthAnchor)
        columnWidth.priority = .defaultHigh
        let columnCap = columnView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        columnCapConstraint = columnCap
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -52),
            columnView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            columnView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            columnWidth,
            columnCap,
            columnView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            columnView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            columnView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            pagingScrollView.topAnchor.constraint(equalTo: columnView.topAnchor),
            pagingScrollView.leadingAnchor.constraint(equalTo: columnView.leadingAnchor),
            pagingScrollView.trailingAnchor.constraint(equalTo: columnView.trailingAnchor),
            pagingScrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -12),
            headerOverlayView.topAnchor.constraint(equalTo: pagingScrollView.topAnchor, constant: 16),
            headerOverlayView.leadingAnchor.constraint(equalTo: pagingScrollView.leadingAnchor, constant: 16),
            headerOverlayView.trailingAnchor.constraint(lessThanOrEqualTo: pagingScrollView.trailingAnchor, constant: -16),
            overlayAvatarImageView.topAnchor.constraint(equalTo: headerOverlayView.topAnchor),
            overlayAvatarImageView.leadingAnchor.constraint(equalTo: headerOverlayView.leadingAnchor),
            overlayAvatarImageView.widthAnchor.constraint(equalToConstant: 40),
            overlayAvatarImageView.heightAnchor.constraint(equalToConstant: 40),
            overlayAvatarImageView.bottomAnchor.constraint(equalTo: headerOverlayView.bottomAnchor),
            overlayNameLabel.leadingAnchor.constraint(equalTo: overlayAvatarImageView.trailingAnchor, constant: 10),
            overlayNameLabel.centerYAnchor.constraint(equalTo: overlayAvatarImageView.centerYAnchor),
            overlayNameLabel.trailingAnchor.constraint(equalTo: headerOverlayView.trailingAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: columnView.leadingAnchor, constant: 16),
            bottomStack.trailingAnchor.constraint(equalTo: columnView.trailingAnchor, constant: -16),
            bottomStack.bottomAnchor.constraint(equalTo: columnView.bottomAnchor, constant: -8),
            thumbnailStack.topAnchor.constraint(equalTo: thumbnailScrollView.contentLayoutGuide.topAnchor),
            thumbnailStack.leadingAnchor.constraint(equalTo: thumbnailScrollView.contentLayoutGuide.leadingAnchor),
            thumbnailStack.trailingAnchor.constraint(equalTo: thumbnailScrollView.contentLayoutGuide.trailingAnchor),
            thumbnailStack.bottomAnchor.constraint(equalTo: thumbnailScrollView.contentLayoutGuide.bottomAnchor),
            thumbnailStack.heightAnchor.constraint(equalTo: thumbnailScrollView.frameLayoutGuide.heightAnchor),
            thumbnailScrollView.heightAnchor.constraint(equalToConstant: 44),
            applyButton.heightAnchor.constraint(equalToConstant: 50),
        ])
        // 进页预热：只解当前已应用主题（个人页封面已在用，多半已缓存）；
        // 其余页由滑动按需建页，不再十六张一次全幅解码
        //（第十轮 01：六张约 113 MiB，画质不降、只改加载时机＋内存预算）。
        if let currentCoverTheme = currentThemeValue.coverTheme {
            ProfileCoverView.prewarmBackdrops(for: [currentCoverTheme])
        }
        updateChrome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 仅 iPad 且宽 ≥821 才激活 600 上限（iPhone 横屏走全宽）。
        let wantCap = BearyDesktop.isWide(view.bounds.width)
        if let cap = columnCapConstraint, cap.isActive != wantCap {
            cap.isActive = wantCap
        }
        layoutPages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshPlusStatus()
        ensurePagesAroundCurrent()
        updatePageAnimations()
    }

    /// 第十一轮 04：回前台重读会员资格——Plus 可能在外层 Plus 页→邀请页
    /// 拿到（邀请绑定成功即发 Plus），init 时的快照会过期。首次出现不拉
    ///（值刚从个人页 profile.plus 传来）；之后每次回前台拉一次 /me。
    /// 失败静默保留旧值，不弹 toast、不把人判成非 Plus；/me 未下发 plus
    ///（nil）时同样保留旧值。只在值真的变了时才刷新状态与底栏。
    /// 审计四轮第 6 项：发起时记下账号与请求序号，回调先校验——已有更新的
    /// 请求发出、或发起后已切号、或 /me 回包的账号与发起账号不符时，过期
    /// 回包直接丢弃，不写 isPlusValue。
    private func refreshPlusStatus() {
        guard hasAppearedOnce else { hasAppearedOnce = true; return }
        plusStatusRequestSequence += 1
        let sequence = plusStatusRequestSequence
        let accountId = BearyDraftStore.currentAccountId
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard sequence == self.plusStatusRequestSequence else { return }
                guard BearyDraftStore.currentAccountId == accountId else { return }
                guard case .success(let user) = result, let rawPlus = user?.plus else { return }
                let plus = BearyDeveloperMode.effectivePlus(rawPlus)
                if let userId = user?.id, let accountId, userId != accountId { return }
                guard plus != self.isPlusValue else { return }
                self.isPlusValue = plus
                self.updatePlusFooter()
                self.refreshVisibleLockStates()
            }
        }
    }

    /// Plus 态变化时同步底栏提示：非 Plus 显示“仅 Plus 会员可使用景深背景”，
    /// 已开通则去掉；与 viewDidLoad 初始态同口径。
    private func updatePlusFooter() {
        plusFooterLabel.isHidden = isPlusValue
    }

    /// 资格变化时只刷新当前页的状态文字与按钮：不重建预览视图、不重读图；
    /// 滑动位置不动。
    private func refreshVisibleLockStates() {
        updateChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for page in pages.values {
            page.setAnimationEnabled(false)
        }
    }

    @objc private func backButtonTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 分页

    /// 页宽变了才重算页帧与偏移（转屏／分屏时用）；平时布局不碰偏移，免得
    /// 打断正在跑的滑动动画。
    private func layoutPages() {
        let pageWidth = pagingScrollView.bounds.width
        let pageHeight = pagingScrollView.bounds.height
        guard pageWidth > 0, pageHeight > 0 else { return }
        let widthChanged = abs(pageWidth - lastPageWidth) > 0.5
        pagingScrollView.contentSize = CGSize(width: pageWidth * CGFloat(themesValue.count), height: pageHeight)
        for (index, page) in pages {
            page.frame = CGRect(x: CGFloat(index) * pageWidth, y: 0, width: pageWidth, height: pageHeight)
        }
        if widthChanged {
            lastPageWidth = pageWidth
            pagingScrollView.contentOffset = CGPoint(x: CGFloat(currentIndex) * pageWidth, y: 0)
        }
        ensurePagesAroundCurrent()
    }

    /// 只留当前±1 页在内存里：建缺的、拆远的；动效只给当前页（滑动中全关）。
    private func ensurePagesAroundCurrent() {
        let pageWidth = pagingScrollView.bounds.width
        let pageHeight = pagingScrollView.bounds.height
        guard pageWidth > 0, pageHeight > 0 else { return }
        let wanted = Set([currentIndex - 1, currentIndex, currentIndex + 1].filter { $0 >= 0 && $0 < themesValue.count })
        for index in wanted where pages[index] == nil {
            let page = BearyDepthBackgroundPage(theme: themesValue[index])
            page.frame = CGRect(x: CGFloat(index) * pageWidth, y: 0, width: pageWidth, height: pageHeight)
            pagingScrollView.addSubview(page)
            pages[index] = page
        }
        for (index, page) in pages where !wanted.contains(index) {
            page.setAnimationEnabled(false)
            page.removeFromSuperview()
            pages.removeValue(forKey: index)
        }
        updatePageAnimations()
    }

    private func updatePageAnimations() {
        for (index, page) in pages {
            page.setAnimationEnabled(!isScrollingPreviews && index == currentIndex)
        }
    }

    /// 停稳后落到最近的页：换页则建新邻页、暖邻页底图、刷新底部状态。
    private func settleToNearestPage() {
        let pageWidth = pagingScrollView.bounds.width
        guard pageWidth > 0 else { return }
        let raw = pagingScrollView.contentOffset.x / pageWidth
        let index = max(0, min(themesValue.count - 1, Int(raw.rounded())))
        isScrollingPreviews = false
        if index != currentIndex {
            currentIndex = index
            ensurePagesAroundCurrent()
            prewarmNeighbors()
        }
        updatePageAnimations()
        updateChrome()
    }

    /// 邻页底图先在后台解码（只暖封面款；节日款／默认档不走此缓存）。
    private func prewarmNeighbors() {
        let coverThemes = [currentIndex - 1, currentIndex, currentIndex + 1]
            .filter { $0 >= 0 && $0 < themesValue.count }
            .compactMap { themesValue[$0].coverTheme }
        if !coverThemes.isEmpty { ProfileCoverView.prewarmBackdrops(for: coverThemes) }
    }

    private func goToPage(_ index: Int, animated: Bool) {
        let clamped = max(0, min(themesValue.count - 1, index))
        let pageWidth = pagingScrollView.bounds.width
        guard pageWidth > 0 else { return }
        guard clamped != currentIndex else {
            updateChrome()
            return
        }
        isScrollingPreviews = true
        updatePageAnimations()
        let shouldAnimate = animated && BearyMotion.animated(true)
        pagingScrollView.setContentOffset(CGPoint(x: CGFloat(clamped) * pageWidth, y: 0), animated: shouldAnimate)
        if !shouldAnimate {
            settleToNearestPage()
        }
    }

    // MARK: - 底部状态

    /// 底部一行状态：当前档“已应用”、锁定档“Plus 专属”、节日款“节日限定”。
    private func stateForTheme(_ theme: Theme) -> (text: String?, color: UIColor) {
        if theme == currentThemeValue {
            return (NSLocalizedString("depth_picker.applied", comment: ""), BearyColors.gray)
        }
        if theme != .none && !isPlusValue {
            return (NSLocalizedString("depth_picker.plus_only", comment: ""), BearyColors.ink)
        }
        if theme.isFestivalTheme {
            return (NSLocalizedString("depth_picker.festival_limited", comment: ""), BearyColors.orange)
        }
        return (nil, BearyColors.gray)
    }

    /// 名字／圆点／缩略图选中态／应用按钮／底栏提示，一处刷新。
    private func updateChrome() {
        let theme = themesValue[currentIndex]
        nameLabel.text = theme.title
        let state = stateForTheme(theme)
        stateLabel.text = state.text
        stateLabel.textColor = state.color
        pageControl.currentPage = currentIndex
        if theme == currentThemeValue {
            applyButton.setTitle(NSLocalizedString("depth_picker.applied", comment: ""), for: .normal)
        } else if theme != .none && !isPlusValue {
            applyButton.setTitle(NSLocalizedString("depth_picker.plus_only", comment: ""), for: .normal)
        } else {
            applyButton.setTitle(NSLocalizedString("depth_picker.apply_cover", comment: ""), for: .normal)
        }
        updatePlusFooter()
        for (index, button) in thumbButtons.enumerated() {
            let selected = index == currentIndex
            button.layer.borderWidth = selected ? 2 : 0
            button.layer.borderColor = BearyColors.orange.cgColor
            button.alpha = selected ? 1 : 0.6
        }
        if currentIndex < thumbButtons.count {
            let thumb = thumbButtons[currentIndex]
            thumbnailScrollView.scrollRectToVisible(thumb.frame.insetBy(dx: -12, dy: 0), animated: BearyMotion.animated(true))
        }
        for (index, page) in pages {
            let pageTheme = themesValue[index]
            let pageState = stateForTheme(pageTheme)
            page.accessibilityLabel = pageState.text.map { "\(pageTheme.title)，\($0)" } ?? pageTheme.title
        }
    }

    @objc private func applyButtonTapped() {
        let theme = themesValue[currentIndex]
        // 当前档点按即关闭（已应用，不重走门控；Plus 过期后仍贴着旧主题时也不弹提示）。
        if theme == currentThemeValue {
            dismiss(animated: BearyMotion.animated(true), completion: nil)
            return
        }
        // 锁定档点按进 Plus 页（入口③），本页停留；门控 toast 仍留编辑资料页
        // 的 handleDepthThemePicked 作兜底。
        if theme != .none && !isPlusValue {
            presentPlusPage()
            return
        }
        // 门控／加载失败时个人页已弹 toast，本页停留；应用成功才关闭回个人页看效果。
        // 应用时带上本页最新已知 Plus 态再验一次权限（第十一轮 04）。
        if onPickValue(theme, isPlusValue) {
            dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
    }

    @objc private func thumbnailTapped(_ sender: UIButton) {
        goToPage(sender.tag, animated: true)
    }

    /// Plus 页入口③：锁定款点按进 Plus 页。呈现口径与本页同款（窄屏全屏＋左边缘
    /// 右滑，宽屏默认呈现）；锁定款只在非 Plus 时出现，故此处恒为未开通态。
    private func presentPlusPage() {
        guard presentedViewController == nil else { return }
        let page = BearyPlusPageViewController(isPlus: isPlusValue)
        if traitCollection.horizontalSizeClass == .compact {
            page.modalPresentationStyle = .fullScreen
            let edgeDismiss = BearyEdgeDismissController()
            edgeDismiss.attach(to: page)
            page.transitioningDelegate = edgeDismiss
            plusPageEdgeDismiss = edgeDismiss
        }
        present(page, animated: BearyMotion.animated(true))
    }

    // MARK: - 缩略图

    private func makeThumbnail(for theme: Theme, index: Int) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = BearyColors.surface2
        button.layer.cornerRadius = 8
        button.clipsToBounds = true
        button.tag = index
        button.accessibilityLabel = theme.title
        button.addTarget(self, action: #selector(thumbnailTapped(_:)), for: .touchUpInside)
        button.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 52),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
        if let coverTheme = theme.coverTheme, let image = posterImage(for: coverTheme) {
            let imageView = UIImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            button.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: button.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        } else if let wallpaperTheme = theme.wallpaperTheme {
            do {
                let preview = try BearyFestivalWallpaperView(theme: wallpaperTheme)
                preview.translatesAutoresizingMaskIntoConstraints = false
                preview.isUserInteractionEnabled = false
                preview.isAnimationEnabled = false
                button.addSubview(preview)
                NSLayoutConstraint.activate([
                    preview.topAnchor.constraint(equalTo: button.topAnchor),
                    preview.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    preview.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    preview.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                ])
            } catch {
                // 预览起不来不拦点按：缩略图只留底色，点按仍走应用流程。
            }
        }
        return button
    }

    /// 缩略图用海报原图（只建对象不解码；52×40 小图，解码量可忽略）。
    private func posterImage(for coverTheme: ProfileCoverTheme) -> UIImage? {
        if let cached = thumbPosterCache[coverTheme] {
            return cached
        }
        guard let url = Bundle.main.url(forResource: coverTheme.rawValue + "-poster", withExtension: "png") else { return nil }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbPosterCache[coverTheme] = image
        return image
    }
}

extension BearyDepthBackgroundViewController: UIScrollViewDelegate {

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        isScrollingPreviews = true
        updatePageAnimations()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView == pagingScrollView else { return }
        if !decelerate { settleToNearestPage() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        settleToNearestPage()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        settleToNearestPage()
    }
}

/// 节日款：除默认与六地封面之外的九个主题（万圣节／春节／七夕／圣诞／元旦／
/// 复活节／元宵／中秋／亡灵节），在选择页里带「节日限定」标记。
private extension BearyDepthBackgroundViewController.Theme {
    var isFestivalTheme: Bool {
        switch self {
        case .none, .china, .usa, .japan, .germany, .canada, .korea:
            return false
        case .halloween, .spring, .qixi, .christmas, .newyear, .easter, .lantern, .midautumn, .muertos:
            return true
        }
    }
}

/// 全屏预览页：真视图实时预览（封面款走真的 ProfileCoverView，节日款走真的
/// BearyFestivalWallpaperView，默认档为纯底色占位）。预览创建失败时（缺资源）
/// 退回纯底色占位，点按仍走个人页应用流程、失败由个人页 toast。
private final class BearyDepthBackgroundPage: UIView {

    private let theme: BearyDepthBackgroundViewController.Theme

    private let dimView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = .black
        viewValue.alpha = 0
        viewValue.isUserInteractionEnabled = false
        viewValue.accessibilityElementsHidden = true
        return viewValue
    }()

    private var coverView: ProfileCoverView?
    private var wallpaperView: BearyFestivalWallpaperView?

    init(theme: BearyDepthBackgroundViewController.Theme) {
        self.theme = theme
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = BearyColors.surface2
        addSubview(dimView)
        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: topAnchor),
            dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let coverTheme = theme.coverTheme {
            let preview = ProfileCoverView(theme: coverTheme)
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.accessibilityElementsHidden = true
            preview.isPlaying = false
            insertSubview(preview, belowSubview: dimView)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: topAnchor),
                preview.leadingAnchor.constraint(equalTo: leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: trailingAnchor),
                preview.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            coverView = preview
        } else if let wallpaperTheme = theme.wallpaperTheme {
            do {
                let preview = try BearyFestivalWallpaperView(theme: wallpaperTheme)
                preview.translatesAutoresizingMaskIntoConstraints = false
                preview.accessibilityElementsHidden = true
                preview.isUserInteractionEnabled = false
                preview.isAnimationEnabled = false
                insertSubview(preview, belowSubview: dimView)
                NSLayoutConstraint.activate([
                    preview.topAnchor.constraint(equalTo: topAnchor),
                    preview.leadingAnchor.constraint(equalTo: leadingAnchor),
                    preview.trailingAnchor.constraint(equalTo: trailingAnchor),
                    preview.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                wallpaperView = preview
            } catch {
                // 预览起不来不拦点按：应用时个人页会再试一次、失败弹 toast。
                wallpaperView = nil
            }
        }
        updateDim()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setAnimationEnabled(_ enabled: Bool) {
        coverView?.isPlaying = enabled
        wallpaperView?.isAnimationEnabled = enabled
    }

    /// 深色压暗与 header 同值（黑遮罩 0.35，浅色 0）；封面行不压（插画本身
    /// 已铺满，压暗会闷住夜班车那张的灯光）。
    func updateDim() {
        if theme.wallpaperTheme != nil {
            dimView.alpha = traitCollection.userInterfaceStyle == .dark ? 0.35 : 0
        } else {
            dimView.alpha = 0
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDim()
    }
}
