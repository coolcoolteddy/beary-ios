import UIKit

/// 设置子页布局守卫（116 真机：设置页点进的子页顶栏落到屏中部、正文全空）。
/// 115 设置页本身已有同款守卫（#352，其注释自认根因未证实：呈现时 view 帧／
/// 安全区异常把顶栏顶到屏中部），但子页一律没有——子页与设置页同款
/// fullScreen + fadeRise 呈现，同一呈现异常落到子页身上时无任何复位。
/// 守卫只做三件事（每出现一次、在首次布局时跑一次）：
/// ① view.frame 偏离窗口 bounds >0.5pt → 复位回窗口 bounds；
/// ② view.transform 非单位阵（转场中断残留位移）→ 清掉；
/// ③ 顶栏 minY 偏离 safeAreaInsets.top >20pt → 重布局一次。
/// 不重建节点、不重播动效、不改数据与门控。评估与否、触发与否各记 [Diag]
/// 一行，复现时凭日志一次定位是帧、位移还是约束问题。
/// 117 真机教训：首次布局常落在转场动画中途（此时帧还是对的），一次性评估
/// 随即消费掉；偏移若落在呈现完成、后一次布局解析之后，就再也不会被校正——
/// 截图 5 页（标题落屏中、正文全空）正是终态偏离、守卫已 spent 的样子。
/// 因此呈现完成时（viewDidAppear）必须再跑一次：applyAfterAppearance 不受
/// didEvaluate 限制，复位后才算评估完成；动画已结束，复位无视觉跳变。
final class BearySubpageLayoutGuard {
    private var didEvaluate = false
    func resetForAppearance() { didEvaluate = false }
    /// 呈现完成时的再评估：先复位再跑，与 viewDidLayoutSubviews 的那次无关。
    @discardableResult
    func applyAfterAppearance(page: String, view: UIView, topView: UIView?, contentViews: [UIView] = [], presentation: String? = nil) -> Bool {
        didEvaluate = false
        return applyIfNeeded(page: page, view: view, topView: topView, contentViews: contentViews, presentation: presentation)
    }
    @discardableResult
    func applyIfNeeded(page: String, view: UIView, topView: UIView?, contentViews: [UIView] = [], presentation: String? = nil) -> Bool {
        guard !didEvaluate, let window = view.window else { return false }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0, view.bounds.width > 0 else { return false }
        didEvaluate = true
        let frameOff = abs(view.frame.origin.x) > 0.5 || abs(view.frame.origin.y) > 0.5
            || abs(view.frame.width - bounds.width) > 0.5 || abs(view.frame.height - bounds.height) > 0.5
        let transformOff = !view.transform.isIdentity
        let topOff = topView.map { abs($0.frame.minY - view.safeAreaInsets.top) > 20 } ?? false
        // 118 真机教训：三项全通过仍可能坏——坏的是顶栏高度（顶栏顶正常、
        // 高度吃掉全部可用高度、内容区高度归零），三项里没有一项量高度。
        // 故日志必须记顶栏高度与内容区帧，一次定位到底是帧、位移、顶栏位置
        // 还是顶栏高度/内容区高度问题；高度本身由约束上界治（见
        // BearySubpageTopBarHeight），守卫只记不治，不再加一层通用守卫。
        let topHeightOff = topView.map { $0.frame.height > BearySubpageTopBarHeight.max } ?? false
        let contentFrames = contentViews.map { NSCoder.string(for: $0.frame) }.joined(separator: " | ")
        NSLog("[Diag] subpage-layout page=%@ view=%@ top=%@ topH=%@ safeArea=%@ frameOff=%@ transformOff=%@ topOff=%@ topHeightOff=%@ content=[%@] presentation=%@",
              page, NSCoder.string(for: view.frame),
              topView.map { NSCoder.string(for: $0.frame) } ?? "nil",
              topView.map { String(format: "%.1f", $0.frame.height) } ?? "nil",
              NSCoder.string(for: view.safeAreaInsets),
              frameOff ? "Y" : "N", transformOff ? "Y" : "N", topOff ? "Y" : "N", topHeightOff ? "Y" : "N",
              contentFrames, presentation ?? "nil")
        guard frameOff || transformOff || topOff else { return false }
        if transformOff { view.transform = .identity }
        if frameOff { view.frame = bounds }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        NSLog("[Diag] subpage-layout-reset page=%@", page)
        return true
    }
}

/// 子页顶栏高度上下界（公共路径修法，与设置主页同口径）。
/// 根因（117/118 真机 + 截图像素实测）：子页顶栏此前只钉了高度下界（>= 52），
/// 子视图约束又全是不等式（centerY + 上下 >= 6 / <= -6），高度没有任何上界；
/// 顶栏底边经滚动区/正文区/列表链到页底，内容区（scrollView/textView/tableView）
/// 又都没有固有高度——整条竖向链多出一个自由度。实测解算结果是顶栏吃掉全部
/// 可用高度、内容区高度归零：诊断页顶栏顶 61pt（正常安全区顶）、高约 734pt，
/// 操作行被顶到 817pt、正文区只剩约 1pt；隐私/协议/拉黑三页顶栏高约 780pt、
/// 内容区约 0pt；设备页（滚动区底钉 view.bottom）顶栏高约 814pt、滚动区约 0pt。
/// 此时守卫三项全通过：view.frame == 窗口 bounds、transform 是单位阵、顶栏 minY
/// == 安全区顶——坏的是顶栏高度，三项里没有一项量它；重布局也只会把同一套
/// 约束再解出同一个结果，所以 #535 的呈现完成再校兜不住。
/// 修法：与设置主页（>= 52 且 <= 88）同口径给顶栏加上界；88 内仍有余量，
/// 大字号下顶栏可长到 88，内容区永远有高度，坏状态直接不在可行解里。
/// 全量审计（以 BearySettingsViewController 全部呈现点为准，补查结论）：
/// 本支 5 处改动实际覆盖 8 页——壳子页（会员来源明细、登录设备，子类调
/// super.viewDidLoad 故同走壳顶栏）、法律页（隐私政策、用户协议）、诊断日志、
/// 已拉黑用户、反馈与改进；原先只报“5 处”是代码落点数，不是页数。
/// 刻意排除、经逐页核实不存在无界顶栏、不动的页：功能许愿墙（列表页与发起页
/// 顶栏均钉死 == 52，无拉伸自由度）；编辑资料页（无独立顶栏，关闭/标题/保存
/// 是内容栈内的横排 topRow，高度由 44pt 按钮固有高度决定）；添加账号登录页
/// （栈式布局，关闭行 44、logo 行 28、字段 48、按钮 44 全部钉死高度）；使用指南
/// （容器引导页，无顶栏视图）；系统弹窗与分享单（UIAlertController /
/// UIActivityViewController，无自定义顶栏）。上述排除页若仍见标题落屏中、
/// 正文全空，即非本机制，需凭新截图另查，不要再往本处加界。
enum BearySubpageTopBarHeight {
    static let min: CGFloat = 52
    static let max: CGFloat = 88
    static func constraints(for topBar: UIView) -> [NSLayoutConstraint] {
        [topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: min),
         topBar.heightAnchor.constraint(lessThanOrEqualToConstant: max)]
    }
}

// ===== 设置子页：会员来源明细 / 登录设备（2026-10-29 第 7、11 项）=====
// 两页原先以内联卡/内联展开的形式挤在设置页内（Plus 组的来源明细卡、
// 账号与安全组的设备展开列表），本批各抽成独立页：设置页只留一行
// （行尾官方包右箭头 icon_chevron_right，点击进入），列表内容照原样搬过来
// （行格式、当前设备绿 pill、地区与上次活跃时间、空态与失败重试均不变）。
// 接口现状（2026-10-29 已确认）：GET /api/account/plus-detail 与
// GET /api/account/sessions 均已下发明细，直接接，不用等后端；设置页已拉到
// 的数据经构造器传入，未拉到时子页自己拉一次（失败态行内重试）。
// 子页口径与设置页一致：全屏 modal + fadeRise（容器侧接线）、左上文字
// 「关闭」15pt 墨字、标题 17 bold；动效只走 transform/opacity（本页无进场
// 动效，只有失败重试与行内淡入沿用设置页 fadeInNewStackRows 口径的静态显隐，
// 减动效直显）；图标一律官方包，不自绘。

/// 子页通用壳：顶栏（关闭 + 居中标题）+ 滚动内容列；子类往 contentStack 里填卡片。
class BearySettingsSubpageViewController: UIViewController {
    private let pageTitle: String
    let contentStack = UIStackView()
    /// 116 子页空白守卫：顶栏视图由 viewDidLoad 局部变量改为属性，供守卫读取 minY。
    private let subpageLayoutGuard = BearySubpageLayoutGuard()
    private var topBarView: UIView?
    /// 滚动区同样提为属性，供守卫日志记滚动区帧与内容栈高度。
    private let contentScrollView = UIScrollView()
    /// 审计-个人页设置：子页壳 iPad 列宽——顶栏与内容列的宽度约束，
    /// viewDidLayoutSubviews 按 ≥821 时 600 居中、≤820 全宽减 32 更新常量
    /// （断点条件无法用纯约束表达；只在值变化时赋值，避免布局循环）。
    private var subpageTopBarWidthConstraint: NSLayoutConstraint?
    private var subpageContentWidthConstraint: NSLayoutConstraint?

    init(title: String) {
        self.pageTitle = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        // 109：子页壳关闭钮改 BearyHit44Button——视觉（15pt 墨字、无尺寸约束）
        // 不变，仅 point(inside:) 把热区扩到 44pt；对照组设置主页/法律页/
        // 诊断页/拉黑页关闭钮均为 BearyHit44Button，本壳此前是普通钮（约 30×18pt）。
        // 全屏页左上角统一左箭头：此前是文字“关闭”，现改 icon_back 图标钮
        // （左上角位置与 44pt 热区不动，行为仍是 closeTapped 关页）。
        let closeButton = BearyHit44Button(type: .custom)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = pageTitle
        // 32 清单第 13 项：子页顶栏标题/关闭走 cappedFont（上限 20，许愿墙/反馈顶栏同口径）。
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        view.addSubview(topBar)
        topBarView = topBar
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        contentScrollView.delaysContentTouches = false
        view.addSubview(contentScrollView)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        contentScrollView.addSubview(contentStack)
        // 审计-个人页设置：子页壳 iPad 列宽与设置主页/法律/诊断/拉黑对齐——
        // ≥821 时顶栏与内容列同为 600 居中，≤820 时顶栏全宽、内容列全宽减 32
        // （壳原有 -32 内边距不变，不改主页 -40 口径）；宽度常量由
        // viewDidLayoutSubviews 按当前屏宽更新（见 updateSubpageColumnWidths）。
        subpageTopBarWidthConstraint = topBar.widthAnchor.constraint(equalToConstant: view.bounds.width)
        subpageContentWidthConstraint = contentStack.widthAnchor.constraint(equalToConstant: max(view.bounds.width - 32, 0))
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subpageTopBarWidthConstraint!,
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            contentScrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            contentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 审计-个人页设置：子页壳底部钉安全区（原 view.bottomAnchor，
            // 末行内容会沉到 Home 指示条下；法律/诊断/拉黑页已是安全区口径）。
            contentScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.centerXAnchor.constraint(equalTo: contentScrollView.frameLayoutGuide.centerXAnchor),
            subpageContentWidthConstraint!,
            contentStack.bottomAnchor.constraint(equalTo: contentScrollView.contentLayoutGuide.bottomAnchor, constant: -24),
        ] + BearySubpageTopBarHeight.constraints(for: topBar))
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subpageLayoutGuard.resetForAppearance()
    }

    /// 审计-个人页设置：按当前屏宽更新子页壳列宽（仅 iPad ≥821 锁 600，
    /// 其余全宽 / 内容列全宽减 32）；旋转/分屏时 viewDidLayoutSubviews
    /// 再跑即纠正，不另监听尺寸变化。
    private func updateSubpageColumnWidths() {
        let viewWidth = view.bounds.width
        guard viewWidth > 0 else { return }
        let topBarWidth = BearyDesktop.isWide(viewWidth) ? 600 : viewWidth
        let contentWidth = BearyDesktop.isWide(viewWidth) ? 600 : max(viewWidth - 32, 0)
        if subpageTopBarWidthConstraint?.constant != topBarWidth {
            subpageTopBarWidthConstraint?.constant = topBarWidth
        }
        if subpageContentWidthConstraint?.constant != contentWidth {
            subpageContentWidthConstraint?.constant = contentWidth
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSubpageColumnWidths()
        subpageLayoutGuard.applyIfNeeded(page: pageTitle, view: view, topView: topBarView, contentViews: [contentScrollView, contentStack], presentation: "fullScreen+fadeRise")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 117 终态偏离兜底：动画结束后的最终帧再校一次，不受首次布局那次限制。
        subpageLayoutGuard.applyAfterAppearance(page: pageTitle, view: view, topView: topBarView, contentViews: [contentScrollView, contentStack], presentation: "fullScreen+fadeRise")
    }

    /// 行间分隔线 backgroundColor 走动态 UIColor、自动跟随，不用重刷；
    /// 当前设备 curPill 绿边是固定绿，不动。

    /// 分组卡（设置页 makeGroupCard 同款视觉：卡内标题、圆角 20、
    /// 行间 1px 分隔线、行内容左右 16、上下 14）。
    func makeGroupCard(title: String?, rows: [UIView]) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        // 卡片底色走 surface1（页上卡片层；2026-11-07 微明度定版：1px 外框已去掉）。
        card.backgroundColor = BearyColors.surface1
        card.layer.borderWidth = 0
        card.layer.cornerRadius = BearyCorners.single
        card.clipsToBounds = true
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
            // 审计第二波 4a：卡内标题改走 makeSectionTitle（P1-7 同口径，
            // 见本文件 makeSectionTitle；此前内联 12 号固定字、单行）。
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
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                NSLayoutConstraint.activate([separator.heightAnchor.constraint(equalToConstant: 0.5)])
                stack.addArrangedSubview(separator)
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
            stack.addArrangedSubview(wrap)
        }
        return card
    }

    /// 审计第二波 4a：按第一波 P1-7（设置页 makeLabel）同口径接动态字体——
    /// 默认字号下与原值一致，大字号档跟随系统缩放；行尾按字符换行。
    func makeLabel(font: UIFont, color: UIColor, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: font)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = lines
        label.lineBreakMode = .byCharWrapping
        return label
    }

    /// 审计第二波 4a：卡内分组标题（设置页 makeSectionTitle 同口径）——
    /// 12px 灰、字距 1px、多行自适应（大字号下可换行，标题包容器上下
    /// 约束已定、行高随文字自动撑开，不钉固定高度）。
    func makeSectionTitle(_ text: String) -> UILabel {
        let label = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray)
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(string: text, attributes: [.kern: 1, .font: label.font])
        return label
    }
}

// MARK: - 登录设备页（第 11 项）

final class BearyDevicesViewController: BearySettingsSubpageViewController {
    private var sessions: [BearyAccountSession]?
    private var loadFailed: Bool
    private var countText: String?
    /// A2：设置页的设备共享加载结果（同会话在途结果共用）；为 nil 时
    /// 退回旧口径自拉（防御性兜底，设置页现行必传）。
    private var sharedLoad: BearySharedLoad<BearyAccountSessionsResponse>?
    /// 109：同会员来源明细页——重试在途锁 + 代次，防连点多发与过期回包覆盖。
    private var isRetrying = false
    private var retryGeneration = 0
    /// 116：设备行入场错峰只播一次（首个数据 render 且已进窗口时）；
    /// 传入数据首帧（viewDidLoad 时窗口未进）不播、直接显；失败／
    /// 加载态 render 不置位，重试成功后仍可播一次。
    private var deviceRowsAnimated = false
    /// 2026-11-14：当前会话型号补报只发一次（本页生命周期内）；失败时复位，下次加载可再试。
    private var didReportCurrentDevice = false

    /// 设置页已拉到的 sessions 传入（A2：nil = 还没取到，[] = 确认是空，
    /// 两者不再混同）；为 nil 且未失败时本页接设置页同一份在途结果，不再自己另发请求。
    /// 2026-11-19 七组版：退出其他设备钮已移到本页底部（列表下方）。
    var onSessionsChanged: (() -> Void)?
    /// 退出其他设备请求期的忙碌态（钮禁用 + 半透明 + 既有加载图标旋转）。
    private var isRevokingOthers = false
    private let logoutOthersButton = BearyHit44Button(type: .system)
    private let logoutOthersSpinner: BearyRefreshIconView = {
        let view = BearyRefreshIconView()
        view.tintColor = BearyColors.destructiveText
        return view
    }()
    init(sessions: [BearyAccountSession]?, failed: Bool, countText: String?, sharedLoad: BearySharedLoad<BearyAccountSessionsResponse>? = nil) {
        self.sessions = sessions
        self.loadFailed = failed
        self.countText = countText
        self.sharedLoad = sharedLoad
        super.init(title: "登录设备")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLogoutOthersButton()
        if sessions == nil && !loadFailed {
            if let sharedLoad = sharedLoad {
                // A2：接设置页同会话在途结果——在途则等同一份回包，已取到
                // 则直接用缓存；失败则走失败态。回包已在主线程（见 loader）。
                sharedLoad.load { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success(let resp):
                        self.sessions = resp.sessions ?? []
                        if let active = resp.activeCount {
                            self.countText = "共 \(active) 台设备（活跃）"
                        } else {
                            self.countText = "共 \((resp.sessions ?? []).count) 台设备"
                        }
                        self.loadFailed = false
                    case .failure:
                        self.loadFailed = true
                    }
                    self.render()
                    self.reportCurrentDeviceIfNeeded()
                }
            } else {
                BearyAPI.shared.fetchAccountSessions { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        switch result {
                        case .success(let resp):
                            self.sessions = resp.sessions ?? []
                            if let active = resp.activeCount {
                                self.countText = "共 \(active) 台设备（活跃）"
                            } else {
                                self.countText = "共 \((resp.sessions ?? []).count) 台设备"
                            }
                            self.loadFailed = false
                        case .failure:
                            self.loadFailed = true
                        }
                        self.render()
                        self.reportCurrentDeviceIfNeeded()
                    }
                }
            }
        }
        render()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var countLabelView: UILabel?
        if let count = countText {
            let countLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
            countLabel.text = count
            countLabelView = countLabel
            contentStack.addArrangedSubview(countLabel)
        }
        var rows: [UIView] = []
        if sessions == nil && !loadFailed {
            // 自拉进行中：先显加载行，不闪空态（回包后 render 重绘）。
            let spinner = BearyRefreshIconView()
            // 栈内固有尺寸与旧 medium 圈一致（20pt 图）。
            spinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
            spinner.startSpinning()
            let loadingLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
            loadingLabel.text = "加载中…"
            let loadingRow = UIStackView(arrangedSubviews: [spinner, loadingLabel])
            loadingRow.axis = .horizontal
            loadingRow.spacing = 8
            loadingRow.alignment = .center
            rows.append(loadingRow)
        } else if loadFailed {
            let failedLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            failedLabel.text = "加载失败"
            rows.append(failedLabel)
            // 重试两档·行内档（BearyButton.retryInline）：文案/布局/target 不变，
            // 仅把手写规格收进工厂；109 热区仍由 BearyHit44Button 扩到 44pt。
            let retryButton = BearyButton.retryInline()
            retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            rows.append(retryButton)
        } else if let list = sessions, !list.isEmpty {
            for session in list {
                rows.append(sessionRow(session: session))
            }
        } else {
            let emptyLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            emptyLabel.text = "暂无登录设备"
            rows.append(emptyLabel)
        }
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: rows))
        // 2026-11-19 七组版：退出其他设备钮放列表下方（仅当还有非当前
        // 设备时显示；只剩当前设备时无可退出的设备，不显示）。
        // 样式与旧设置页同款：36 高、13/600、destructiveText 字／边（45%）；
        // 配置只在 viewDidLoad 做一次（见 setupLogoutOthersButton），
        // render 只决定加不加进栈，不重复建约束。
        if let list = sessions, !loadFailed, list.contains(where: { $0.isCurrent != true }) {
            contentStack.addArrangedSubview(logoutOthersButton)
        }
        // 116：设备行数据到达时错峰滑入（alpha＋y+6、0.26s、0.03 步进；
        // 行每次 render 重建，故以首个数据 render＋已进窗口为播一次的
        // 守卫；传入数据首帧因窗口未进不播、直接显；加载／失败态
        // render 不置位，重试成功后仍可播一次；减动效直显；目标
        // alpha 按行原值取（各行均为 1，不再有过期行降透明度）。
        if !deviceRowsAnimated, sessions != nil, !loadFailed,
           view.window != nil, !UIAccessibility.isReduceMotionEnabled {
            deviceRowsAnimated = true
            // 116：计数文案随数据到达只淡入本身（无位移）。
            if let countLabelView = countLabelView {
                countLabelView.alpha = 0
                UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut], animations: {
                    countLabelView.alpha = 1
                })
            }
            var delay: TimeInterval = 0
            for row in rows {
                let targetAlpha = row.alpha
                row.alpha = 0
                row.transform = CGAffineTransform(translationX: 0, y: 6)
                UIView.animate(withDuration: BearyMotion.normal, delay: delay, options: [.curveEaseOut], animations: {
                    row.alpha = targetAlpha
                    row.transform = .identity
                })
                delay = min(delay + 0.03, 0.24)
            }
        }
    }

    /// 设置页 rebuildSessions 同款行格式：设备名 15 墨 + 状态 pill
    /// （「当前」11/700 绿字绿边、「已过期」11/700 灰字灰边，内边距 1/7、
    /// 圆角 8）+ 副文案 13 灰「地区 · 上次活跃 dateTime」；过期行不再
    /// 整行降透明度，设备名／地区／上次活跃时间保持正常对比度。
    private func sessionRow(session: BearyAccountSession) -> UIView {
        let devLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        devLabel.text = BearyAccountText.deviceName(session: session)
        var lineParts: [UIView] = [devLabel]
        // 状态 pill 同款几何（11/700、1pt 边、圆角 8、内边距 1/7），
        // 文字与边框同色走 token：当前深绿（#1320 对比度）、已过期灰。
        let makeStatusPill: (String, UIColor) -> UIView = { text, color in
            let pillLabel = self.makeLabel(font: UIFont.systemFont(ofSize: 11, weight: .bold), color: color)
            pillLabel.text = text
            let pill = UIView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.layer.borderWidth = 1
            pill.layer.bearyDynamicBorderColor = color
            pill.layer.cornerRadius = 8
            pill.clipsToBounds = true
            pill.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            pillLabel.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(pillLabel)
            NSLayoutConstraint.activate([
                pillLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1),
                pillLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
                pillLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
                pillLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1),
            ])
            return pill
        }
        if session.isCurrent == true {
            lineParts.append(makeStatusPill("当前", BearyColors.deepGreenText))
        }
        if session.expired == true {
            lineParts.append(makeStatusPill("已过期", BearyColors.gray))
        }
        if session.isCurrent == true || session.expired == true {
            lineParts.append(UIView())
        }
        let lineRow = UIStackView(arrangedSubviews: lineParts)
        lineRow.axis = .horizontal
        lineRow.spacing = 8
        lineRow.alignment = .center
        let region = (session.region ?? "").isEmpty ? "未知地区" : (session.region ?? "")
        let meta = region + " · 上次活跃 " + BearyAccountText.dateTimeString(ms: session.lastActive)
        let metaLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        metaLabel.text = meta
        let rowStack = UIStackView(arrangedSubviews: [lineRow, metaLabel])
        rowStack.axis = .vertical
        rowStack.spacing = 4
        return rowStack
    }

    /// 当前会话设备型号补报（2026-11-14）：老会话登录时未采集型号、列表显示“浏览器”时，
    /// 用显式型号调一次 session-device 补上，成功后重拉列表刷新显示；已有标签绝不覆盖。
    /// 只在当前会话 device 为空或“浏览器”时触发，本页生命周期内最多一次（失败复位可再试）。
    private func reportCurrentDeviceIfNeeded() {
        guard !didReportCurrentDevice else { return }
        guard let current = sessions?.first(where: { $0.isCurrent == true }) else { return }
        let dev = current.device ?? ""
        guard dev.isEmpty || dev == "浏览器" else { return }
        didReportCurrentDevice = true
        BearyAPI.shared.reportSessionDevice(model: BearyAPI.deviceModelName()) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard case .success = result else {
                    self.didReportCurrentDevice = false
                    return
                }
                // 补报成功：重拉一次列表（不走共享缓存，取最新 device），刷新显示。
                BearyAPI.shared.fetchAccountSessions { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        guard case .success(let resp) = result else { return }
                        self.sessions = resp.sessions ?? []
                        if let active = resp.activeCount {
                            self.countText = "共 \(active) 台设备（活跃）"
                        } else {
                            self.countText = "共 \((resp.sessions ?? []).count) 台设备"
                        }
                        self.loadFailed = false
                        self.render()
                    }
                }
            }
        }
    }

    /// 退出其他设备钮配置（只在 viewDidLoad 做一次：36 高、13/600、
    /// destructiveText 字／边 45%、圆角 12；忙碌图标挂在钮内右侧）。
    /// F10 网页 .btn.danger 口径与旧设置页同款；视觉高仍钉死 36，
    /// 热区由 BearyHit44Button 扩到 44pt。
    private func setupLogoutOthersButton() {
        logoutOthersButton.translatesAutoresizingMaskIntoConstraints = false
        logoutOthersButton.setTitle("退出其他设备", for: .normal)
        logoutOthersButton.setTitleColor(BearyColors.destructiveText, for: .normal)
        logoutOthersButton.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        logoutOthersButton.titleLabel?.adjustsFontForContentSizeCategory = true
        logoutOthersButton.layer.borderWidth = 1
        logoutOthersButton.layer.bearyDynamicBorderColor = BearyColors.alpha(BearyColors.destructiveText, 0.45)
        logoutOthersButton.layer.cornerRadius = 12
        logoutOthersButton.addTarget(self, action: #selector(logoutOthersButtonTapped), for: .touchUpInside)
        logoutOthersButton.bearyAddPressFeedback()
        logoutOthersButton.addSubview(logoutOthersSpinner)
        NSLayoutConstraint.activate([
            logoutOthersButton.heightAnchor.constraint(equalToConstant: 36),
            logoutOthersSpinner.widthAnchor.constraint(equalToConstant: 20),
            logoutOthersSpinner.heightAnchor.constraint(equalToConstant: 20),
            logoutOthersSpinner.trailingAnchor.constraint(equalTo: logoutOthersButton.trailingAnchor, constant: -12),
            logoutOthersSpinner.centerYAnchor.constraint(equalTo: logoutOthersButton.centerYAnchor),
        ])
    }

    @objc private func logoutOthersButtonTapped() {
        guard !isRevokingOthers else { return }
        // 第四轮审计 12：居中 Alert 改底部弹窗（文案与退出流程不变）。
        BearyConfirmSheet.show(from: self, title: "退出其他设备", message: "将退出除当前设备外的所有登录，确定继续？", actions: [
            BearyConfirmSheet.Action(title: "退出", style: .destructive, handler: { [weak self] in
                self?.confirmLogoutOthers()
            }),
        ])
    }

    /// 请求期原入口忙碌外观——钮禁用 + 半透明 + 既有加载图标旋转；终结时恢复。
    private func setLogoutOthersBusy(_ busy: Bool) {
        logoutOthersButton.isEnabled = !busy
        logoutOthersButton.alpha = busy ? 0.6 : 1
        if busy { logoutOthersSpinner.startSpinning() } else { logoutOthersSpinner.stopSpinning() }
    }

    private func confirmLogoutOthers() {
        isRevokingOthers = true
        setLogoutOthersBusy(true)
        BearyAPI.shared.revokeOtherSessions { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRevokingOthers = false
                self.setLogoutOthersBusy(false)
                switch result {
                case .success:
                    // 成功后重拉列表刷新显示（不走共享缓存，取最新），
                    // 再回调设置页刷新它的设备数。
                    self.reloadSessionsAfterRevoke()
                    self.onSessionsChanged?()
                case .failure(let error):
                    if case .cancelled = error { return }
                    BearyToast.show(in: self.view, message: "操作失败，请重试")
                }
            }
        }
    }

    /// 退出其他设备成功后重拉列表：直接调接口（不走共享缓存，取最新），
    /// 回包后更新列表与计数、重绘；失败时只留旧列表，不弹失败态。
    private func reloadSessionsAfterRevoke() {
        BearyAPI.shared.fetchAccountSessions { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard case .success(let resp) = result else { return }
                self.sessions = resp.sessions ?? []
                if let active = resp.activeCount {
                    self.countText = "共 \(active) 台设备（活跃）"
                } else {
                    self.countText = "共 \((resp.sessions ?? []).count) 台设备"
                }
                self.loadFailed = false
                self.render()
            }
        }
    }

    @objc private func retryTapped() {
        // 109：同会员来源明细页——在途重试直接忽略，先 render 加载态
        // （sessions=nil 且 !loadFailed 时 render 出转圈“加载中…”行，
        // 失败态重试钮随之离场，等价于禁用），回包后恢复。
        guard !isRetrying else { return }
        isRetrying = true
        retryGeneration += 1
        let gen = retryGeneration
        sessions = nil
        loadFailed = false
        render()
        BearyAPI.shared.fetchAccountSessions { [weak self] result in
            DispatchQueue.main.async {
                // 先解锁再判代次：成功/失败/过期回包一律解锁，不留死锁。
                self?.isRetrying = false
                guard let self = self, self.retryGeneration == gen else { return }
                switch result {
                case .success(let resp):
                    self.sessions = resp.sessions ?? []
                    if let active = resp.activeCount {
                        self.countText = "共 \(active) 台设备（活跃）"
                    } else {
                        self.countText = "共 \((resp.sessions ?? []).count) 台设备"
                    }
                    self.loadFailed = false
                case .failure:
                    self.loadFailed = true
                }
                self.render()
                self.reportCurrentDeviceIfNeeded()
            }
        }
    }
}

// MARK: - 离线保存页（第二批体验检查第 6 项）
//
// 本账号占用＋逐篇下载状态＋清除：
//   - 占用行：本账号离线副本总字节与篇数（Application Support 持久目录，
//     不走 24h/200MB 的 Caches 缓存、不参与淘汰）；
//   - 逐篇行：标题＋状态（已保存／部分保存／未完成）＋张数＋占用，附“移除”；
//   - 批量：保存全部本人日记（以本地已同步归档为源，只取本人篇、跳过已完成篇）；
//   - 清除：全部清除只删本账号离线副本，已同步的日记与 Caches 缓存不受影响。
// 未登录只显登录提示，不拉数据、不建目录。

final class BearyOfflineSaveViewController: BearySettingsSubpageViewController {
    private var isSaving = false
    private var saveProgressText: String?
    /// 当前屏上逐篇行的记录（与移除钮 tag 下标一一对应；每次 render 重建时同步更新）。
    private var currentRecords: [BearyOfflineSaveRecord] = []

    /// 子页标题收进类里（同 BearyDevicesViewController 各子页自带参数的口径）；
    /// 调用方直接 BearyOfflineSaveViewController()，不用再传标题。
    init() {
        super.init(title: "离线保存")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 子页内改动（批量保存/清除）后返回仍是本页：每次出现都重刷，
        // 行尾占用与逐篇状态不滞后。
        if isViewLoaded { render() }
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard BearyOfflineSaveManager.shared.currentAccountId != nil else {
            let hint = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            hint.text = "登录后可离线保存自己的日记"
            contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: [hint]))
            return
        }
        let usage = BearyOfflineSaveManager.shared.usage()
        let records = BearyOfflineSaveManager.shared.savedRecords()
        currentRecords = records

        let summary = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        if let progress = saveProgressText {
            summary.text = progress
        } else if usage.entryCount > 0 {
            summary.text = "本账号占用 \(BearyOfflineSaveStore.formattedBytes(usage.bytes)) · \(usage.entryCount) 篇"
        } else {
            summary.text = "还没有离线保存的日记"
        }
        contentStack.addArrangedSubview(summary)

        let saveAllButton = BearyButton(style: .secondaryOutline(.regular))
        saveAllButton.setTitle(isSaving ? "正在保存…" : "保存全部本人日记", for: .normal)
        saveAllButton.isEnabled = !isSaving
        saveAllButton.addTarget(self, action: #selector(saveAllTapped), for: .touchUpInside)
        saveAllButton.bearyAddPressFeedback()
        let clearButton = BearyButton(style: .destructiveOutline(.regular))
        clearButton.setTitle("清除全部离线保存", for: .normal)
        clearButton.isEnabled = !isSaving && usage.entryCount > 0
        clearButton.addTarget(self, action: #selector(clearAllTapped), for: .touchUpInside)
        clearButton.bearyAddPressFeedback()
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: [saveAllButton, clearButton]))

        if records.isEmpty {
            let empty = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            empty.text = NSLocalizedString("settings.offline_save.empty_hint", comment: "")
            contentStack.addArrangedSubview(makeGroupCard(title: "已保存的日记", rows: [empty]))
        } else {
            contentStack.addArrangedSubview(makeGroupCard(title: "已保存的日记", rows: records.enumerated().map { recordRow($0.element, index: $0.offset) }))
        }
    }

    private func recordRow(_ record: BearyOfflineSaveRecord, index: Int) -> UIView {
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink, lines: 0)
        // 标题走转换器：记号转回熊脸附件。存量标题在保存时已按原文截 24 字，
        // 尾部半截记号先去掉（否则原文露出）；读屏标签保持纯文本。
        titleLabel.attributedText = BearyText.inlineAttributedText(from: BearyText.stripTrailingPartialInlineToken(record.title), font: titleLabel.font, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark)
        let statusLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        statusLabel.text = Self.statusText(for: record)
        let dateLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray)
        dateLabel.text = BearyAccountText.dateString(ms: Int(record.savedAt * 1000))
        let textStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, dateLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        let removeButton = BearyHit44Button(type: .system)
        removeButton.setTitle("移除", for: .normal)
        removeButton.setTitleColor(BearyColors.destructiveText, for: .normal)
        removeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        removeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        removeButton.accessibilityLabel = "移除\(record.title)的离线保存"
        removeButton.tag = index
        removeButton.addTarget(self, action: #selector(removeTapped(_:)), for: .touchUpInside)
        removeButton.bearyAddPressFeedback()
        let row = UIStackView(arrangedSubviews: [textStack, removeButton])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private static func statusText(for record: BearyOfflineSaveRecord) -> String {
        let size = BearyOfflineSaveStore.formattedBytes(record.totalBytes)
        if record.imageCount == 0 {
            return record.isComplete ? "已保存 · 无图片 · \(size)" : "未完成 · \(size)"
        }
        switch record.status {
        case "complete":
            return "已保存 · \(record.downloadedCount) 张图 · \(size)"
        case "partial":
            return "部分保存 · \(record.downloadedCount)/\(record.imageCount) 张图 · \(record.failedKeys.count) 张失败 · \(size)"
        default:
            return "未完成 · \(record.downloadedCount)/\(record.imageCount) 张图 · \(size)"
        }
    }

    @objc private func removeTapped(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < currentRecords.count else { return }
        let entryId = currentRecords[sender.tag].entryId
        let removed = BearyOfflineSaveManager.shared.remove(entryId: entryId)
        BearyToast.show(in: view, message: removed ? "已移除离线保存" : "移除失败，请重试")
        render()
    }

    @objc private func saveAllTapped() {
        guard !isSaving else { return }
        isSaving = true
        saveProgressText = "正在保存…"
        render()
        BearyOfflineSaveManager.shared.saveAllOwnEntries(progress: { [weak self] done, total in
            guard let self = self else { return }
            self.saveProgressText = "正在保存 \(done)/\(total)…"
            self.render()
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.isSaving = false
            self.saveProgressText = nil
            self.render()
            if result.saved == 0 && result.partial == 0 && result.skipped == 0 && result.failed == 0 {
                BearyToast.show(in: self.view, message: "没有可保存的日记")
            } else if result.failed > 0 {
                BearyToast.show(in: self.view, message: "已保存 \(result.saved) 篇，\(result.failed) 篇失败")
            } else if result.partial > 0 {
                BearyToast.show(in: self.view, message: "已保存 \(result.saved) 篇，\(result.partial) 篇部分保存")
            }
        })
    }

    @objc private func clearAllTapped() {
        guard !isSaving else { return }
        BearyConfirmSheet.show(from: self, title: "清除全部离线保存？", message: "已离线保存的日记文字与图片将从本设备删除，已同步的日记不受影响。", actions: [
            BearyConfirmSheet.Action(title: "清除全部", style: .destructive) { [weak self] in
                guard let self = self else { return }
                let cleared = BearyOfflineSaveManager.shared.removeAll()
                BearyToast.show(in: self.view, message: cleared ? "已清除全部离线保存" : "清除失败，请重试")
                self.render()
            },
        ])
    }
}
