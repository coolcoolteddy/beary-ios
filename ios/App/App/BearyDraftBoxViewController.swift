import UIKit

// ===== 草稿箱弹层（网页草稿箱移植；对应审计 G1）=====
// 网页对照：~/workspace/teddy_site/beary.html 内 #draftModal。
// 形态：系统底部 sheet（UISheetPresentationController，见 BearySystemSheet；
// 2026-11-25 Li 定：所有弹窗都改系统，自研容器退役）；点遮罩关闭与下滑关闭
// 走系统（outside-tap＋抓手）；iPad 宽屏走系统 sheet 宽（600）；
// 面板高度按内容算、320 封顶（第 13 项），高度变化时 refreshDetentsIfNeeded。
// 数据只读草稿 v3（BearyDraftFiles.swift）：v3 存储是多槽数组文件 beary_draft_v3.json，
// 本弹层按 updatedAt 倒序列出全部草稿；旧 v2 单槽由存储层首次读取时迁入 v3，
// 本文件不做迁移、不改存储结构本身。
// 卡片操作：整卡点按打开（onOpen）；卡片顶行另有删除钮（网页 .df-trash
// 同款）；删除为本地操作：只删该篇（图片文件不动，6 秒撤销期内可原样恢复），
// 删后出 6 秒撤销条，超时丢弃暂存；不碰服务端。
// 调用约定：点“新建日记”只回调 onNew，点卡片只回调 onOpen 并传出该篇草稿；
// 弹窗审计 E1-18 统一退场（第 13 项）：关闭、打开、新建三路共用同一退场
// （dismissWithExitAnimation）——退场走系统 sheet 动画、dismiss 后再调回调，
// 编辑器侧不再另行 dismiss；关闭路回调为空，不重复播动画；关闭与打开/新建均不删任何草稿。
// 约束：颜色只用 BearyColors；面板底色透明、走系统 sheet 自带液态玻璃
// （2026-11-25 Li 定：底部弹窗要不带颜色的液态玻璃效果）；
// 动画遵守 reduced-motion；部署目标 iOS 16.0、Swift 5.0——只用闭包回调，
// 不用 async/await，不用 if-let 简写。

/// 审计第 2 项：草稿卡片 meta 区流式布局视图。
/// 原 metaRow 是单行横排 stack（字数 required + 写给/心情 chip + “忽略丢失图片”钮 +
/// 正在写 + 保存状态 required + 末尾 spacer）：窄屏多标签时横排总宽超卡片宽，
/// 只能靠压 chip 或触发约束冲突。UIStackView 本身不换行，故此处用手动分行：
/// 按现有顺序从左到右排，排不下即另起一行；行高取本行最高项，行距 6。
/// 高度由内部 height 约束驱动（layoutSubviews 按当前宽度重算、变化时才更新，
/// 不循环触发布局）；子项用手动 frame，不参与 Auto Layout 竞争，故不再出现
/// 约束冲突。字号、chip 上限宽、文案、顺序一律不动，不靠缩小字号解决。
final class BearyDraftMetaFlowView: UIView {
    var itemSpacing: CGFloat = 8
    var lineSpacing: CGFloat = 6
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let constraint = heightAnchor.constraint(equalToConstant: 0)
        constraint.isActive = true
        heightConstraint = constraint
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for item in subviews {
            var size = item.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if size.width > width { size.width = width }
            if x > 0 && x + itemSpacing + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            if x > 0 { x += itemSpacing }
            item.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width
            lineHeight = max(lineHeight, size.height)
            totalHeight = y + lineHeight
        }
        if heightConstraint?.constant != totalHeight {
            heightConstraint?.constant = totalHeight
        }
    }
}

final class BearyDraftBoxViewController: UIViewController, BearySystemSheetSizing, UIGestureRecognizerDelegate {

    // MARK: - 对外 API（编辑器代理按此调用，勿改名）

    init(onNew: @escaping () -> Void, onOpen: @escaping (BearyDraft) -> Void) {
        self.onNewHandler = onNew
        self.onOpenHandler = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 状态

    private let onNewHandler: () -> Void
    private let onOpenHandler: (BearyDraft) -> Void
    private var drafts: [BearyDraft] = []
    private var cardEntries: [(button: UIButton, draftValue: BearyDraft)] = []
    /// 草稿卡左滑跟手拖动：当前正在被手指拖动的卡片（同一时刻只可能有一张在拖）；
    /// 新卡开始拖时，上一张若还停在偏移处先瞬间复位，避免两张同偏（复用回收站口径）。
    private var draftDraggingCard: UIButton?
    /// 松手执行删除的左滑距离（回收站 trashDragMenuThreshold 同值：卡片左移满此值才删，不满弹回原位）。
    private let draftDragDeleteThreshold: CGFloat = 60
    /// 手指跟手的最大左移量（回收站 trashDragMaxOffset 同值：再往左拖也不跟，防卡片被拖出屏）。
    private let draftDragMaxOffset: CGFloat = 140
    /// 新规矩 (b)：草稿列表入场动效只播一次（首渲），后续重渲不重播已有卡片。
    /// 审计第 12 项起由 tryPlayEntrance 统一置位（原 renderDrafts 首轮置位已移走）。
    private var draftCardsAnimatedOnce = false
    private var deleteEntries = BearyRowButtonLookup<BearyDraft>(id: \.draftId)
    private var lostEntries = BearyRowButtonLookup<BearyDraft>(id: \.draftId)
    /// 发布失败重试钮（草稿持久标记 lastPublishFailure 非空的卡才有）：
    /// 与 deleteEntries／lostEntries 同款行操作按钮查表。
    private var retryEntries = BearyRowButtonLookup<BearyDraft>(id: \.draftId)
    /// DF-1/DF-2：编辑器当前正在写的那篇 draftId（由容器/编辑器在呈现草稿箱后设置；
    /// 未设置时“正在写”标记不显示、删正在写回调不触发）。容器接线由总协调收尾。
    var currentDraftId: String?
    /// DF-2：箱内删掉正在写的那篇时通知编辑器（编辑器侧清 draftId、换新 req，
    /// 即网页 deleteDraft 里 edDraftId=null 的等价动作）。容器接线由总协调收尾。
    var onDeleteCurrentDraft: ((String) -> Void)?
    /// 审计 P1-9：箱内撤销恢复草稿时通知容器（恢复写盘成功后才发，容器按 clearedCurrentDraftId 过滤绑回）。
    var onUndoCurrentDraft: ((BearyDraft) -> Void)?
    /// 审计 P1-8：撤销槽改多笔队列（LIFO）——连续删多篇时新删不再杀上一笔的撤销；
    /// 每笔自带 6 秒计时器，到期只清本笔；撤销恢复最近一笔，余笔仍在队列里。
    private struct PendingUndo {
        let draft: BearyDraft
        let index: Int
        var timer: Timer?
    }
    private var pendingUndos: [PendingUndo] = []
    private var didPlayEntrance = false
    // 88 包 M8：入场错峰交汇门控——首轮 loadDrafts 回调完成 + 已 Appear 才播，
    // 避免 viewDidAppear 对尚未渲染的空栈空跑、卡片随后硬切出现。
    private var draftBoxAppeared = false
    private var draftsInitialLoaded = false
    private var isDismissing = false
    /// 系统 sheet 下滑／点遮罩关闭经 delegate 守门（撤销确认）：用户在确认框里
    /// 点“仍要关闭”后置位，第二次 shouldDismiss 不再拦截。
    private var undoExitConfirmed = false
    /// 无障碍：关闭后焦点返回的触发入口（编辑器草稿钮，由打开方在 present
    /// 前传入；未传入时不发焦点通知）。新建／打开草稿走回调开新界面时不
    /// 用它（新界面自己接管焦点）。
    var accessibilityFocusReturnElement: UIView?
    /// 无障碍：打开首焦点只发一次（viewDidAppear 会在上层弹框关闭回来时
    /// 再触发，不重复抢焦点）。
    private var didPostDraftBoxOpenFocus = false
    private var bottomSpacerHeight: NSLayoutConstraint?
    /// G5：草稿库读取失败标记（loadAllResult 失败时置位，渲染时出失败态，不出空态）。
    private var draftsLoadFailed = false
    /// 审计四轮 06：草稿箱读取代次——每次 loadDrafts +1；回包时校验代次与账号，
    /// 旧结果直接舍弃，不应用到已切号或已有新一轮读取的界面上。
    private var draftsLoadGeneration = 0
    /// 草稿库损坏态（lastLoadError 为 corruptStore 时）：失败态下出清除按钮；v2/v1 旧源损坏不属此态。
    private var draftsLoadCorrupt = false
    /// 系统抓手占位：14pt（顶距 10 + 抓手 4），与旧把手行同高、标题位置不动；
    /// 抓手本身由系统 sheet 绘制（prefersGrabberVisible），下滑关闭走系统。
    private let handleWrapView = UIView()

    // MARK: - 视图

    // 审计第 9 项：滚动取消走共享类（见 BearyNativeCommon.BearyCancellableScrollView）——
    // 从卡片/删除等按钮上起滑时滚动视图能抢到 pan，点按行为不变。
    private let sheetScrollView = BearyCancellableScrollView()
    private let contentStack = UIStackView()
    private let fixedHeaderView = UIView()
    private let headerWrap = UIView()
    private let titleLabel = UILabel()
    private let subWrap = UIView()
    private let subLabel = UILabel()
    private let newButton = BearyDraftBoxDashedButton(type: .custom)
    private let undoWrap = UIView()
    private let undoBar = UIView()
    private let undoLabel = UILabel()
    private let undoButton = BearyHit44Button(type: .custom)
    private let listWrap = UIView()
    private let listStack = UIStackView()
    /// 弹窗审计 E1-19：数据未到时的加载占位（复用图片加载同款细圆环
    /// BearyWebRingSpinnerView，不新增图标/文案）。renderDrafts 清空
    /// listStack 时随之一并摘掉，数据到达后不残留。
    private let loadingWrap = UIView()
    private let loadingSpinner = BearyWebRingSpinnerView()
    private let hintWrap = UIView()
    private let hintLabel = UILabel()
    private let bottomSpacer = UIView()

    /// 第 13 项：面板高度只按内容算，320 只作封顶（不再写死 320 高）。
    private let draftBoxMaxHeight: CGFloat = 320

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        // 面板透明：系统 sheet 自带液态玻璃底，实色会盖住它（2026-11-25 Li 定）；
        // 顶圆角同其他系统 sheet（公告／确认／输入）做法。
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true
        buildViews()
        buildConstraints()
        // 弹窗审计 E1-19（未覆盖的一半）：数据未到先呈现面板框架 + 加载图标，
        // 不等首轮 loadDrafts。副文案与“点任意一份”提示在数据到达前先藏起
        // （无卡片可点时提示会误导），renderDrafts 按实际态（列表/空态/失败态）
        // 再决定显隐；加载占位由 renderDrafts 清空 listStack 时一并摘掉。
        showLoadingState()
        NotificationCenter.default.addObserver(self, selector: #selector(handleDraftBoxUserChanged), name: .bearyUserDidChange, object: nil)
        loadDrafts { [weak self] in
            self?.hideLoadingState()
            self?.renderDrafts()
            self?.draftsInitialLoaded = true
            self?.updatePreferredContentSize()
            self?.tryPlayEntrance()
        }
    }

    /// E1-19 加载态：列表区只放细圆环（上下各 30pt，与空态文案上边距同口径），
    /// 圆环不拦截点按（BearyWebRingSpinnerView 自带 isUserInteractionEnabled=false）。
    private func showLoadingState() {
        subWrap.isHidden = true
        hintWrap.isHidden = true
        loadingWrap.translatesAutoresizingMaskIntoConstraints = false
        loadingWrap.addSubview(loadingSpinner)
        NSLayoutConstraint.activate([
            loadingSpinner.centerXAnchor.constraint(equalTo: loadingWrap.centerXAnchor),
            loadingSpinner.topAnchor.constraint(equalTo: loadingWrap.topAnchor, constant: 30),
            loadingSpinner.bottomAnchor.constraint(equalTo: loadingWrap.bottomAnchor, constant: -30),
        ])
        listStack.addArrangedSubview(loadingWrap)
        loadingSpinner.startSpinning()
    }

    private func hideLoadingState() {
        loadingSpinner.stopSpinning()
        listStack.removeArrangedSubview(loadingWrap)
        loadingWrap.removeFromSuperview()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        draftBoxAppeared = true
        // 系统 sheet 下滑／点遮罩关闭经 delegate 守门（撤销确认）：
        // presentationController 在呈现后才存在，首次 appear 时挂上
        // （之后重复出现时重复挂也无害）；待撤销笔只在箱内删卡后才产生，
        // 此时 appear 早已跑完，守门不会迟到。
        presentationController?.delegate = self
        // 卡片入场仍由 tryPlayEntrance 的 draftsInitialLoaded 门控。
        tryPlayEntrance()
        // 无障碍：打开首焦点只发一次，落到面板标题“草稿箱”；上层弹框关闭
        // 回来时不再重发抢焦点。未开 VoiceOver 时 post 为空操作。
        if !didPostDraftBoxOpenFocus {
            didPostDraftBoxOpenFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isDismissing else { return }
                UIAccessibility.post(notification: .layoutChanged, argument: self.titleLabel)
            }
        }
    }

    /// 88 包 M8：入场错峰只在“已 Appear 且首轮 loadDrafts 已渲染”时播一次；
    /// 减动效与已播过时与原来一致，直接返回。
    /// 审计第 12 项：本函数是卡片入场唯一入口——“数据就绪（draftsInitialLoaded）+
    /// 面板可见（draftBoxAppeared）+ 首屏卡片入场”在此一处协调，不再由
    /// renderDrafts 自行播卡片。renderDrafts 只建卡片终态，入场初态与动画一律
    /// 由本函数在面板到位时设置。面板框架入场走系统 sheet 动画，不在此播。
    private func tryPlayEntrance() {
        guard !didPlayEntrance, draftBoxAppeared, draftsInitialLoaded,
              !UIAccessibility.isReduceMotionEnabled else { return }
        didPlayEntrance = true
        draftCardsAnimatedOnce = true
        // 只动画当前可见卡片：卡片在滚动区坐标系内与当前可视区域相交才入场；
        // 屏外卡片保持终态（alpha 1、identity），滚到时直接可见，不补播、
        // 不留隐藏态。空态/失败态 wrap 不是卡片，不进此列。
        let visibleRect = CGRect(origin: sheetScrollView.contentOffset, size: sheetScrollView.bounds.size)
        var cardViews: [UIView] = []
        for entry in cardEntries {
            let card = entry.button
            let frameInScroll = card.convert(card.bounds, to: sheetScrollView)
            if frameInScroll.intersects(visibleRect) {
                cardViews.append(card)
            }
        }
        for cardView in cardViews {
            cardView.alpha = 0
            cardView.transform = CGAffineTransform(translationX: 0, y: 8)
        }
        // 卡片播放入 playCards：错峰延迟设上限，逐张 +0.03，但累计不超过 0.24——
        // 大量草稿时尾部可见卡片不再拖出超长尾巴；超上限的卡片同批播出。
        let playCards = {
            let maxDelay: TimeInterval = 0.24
            for (index, cardView) in cardViews.enumerated() {
                let delay = min(TimeInterval(index) * 0.03, maxDelay)
                UIView.animate(withDuration: BearyMotion.normal, delay: delay, options: .curveEaseOut, animations: {
                    cardView.alpha = 1
                    cardView.transform = .identity
                })
            }
        }
        playCards()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBottomSpacer()
        updatePreferredContentSize()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷卡片描边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            for entry in cardEntries {
                entry.button.layer.bearyDynamicBorderColor = BearyColors.line
            }
        }
    }

    // MARK: - 视图搭建

    private func buildViews() {
        // 自研容器已退役：遮罩（点按关闭）与面板阴影／圆角走系统 sheet；
        // 内容直接挂在 view 上（view 即 sheet 内容，底色透明、走系统液态玻璃）。
        sheetScrollView.showsVerticalScrollIndicator = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        sheetScrollView.delaysContentTouches = false
        sheetScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetScrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        sheetScrollView.addSubview(contentStack)

        // 系统抓手占位：handleWrapView 只留 14pt 高（顶距 10 + 抓手 4），
        // 与旧把手行同高、标题位置不动；抓手本身由系统 sheet 绘制，
        // 下滑关闭走系统，不再挂自研 pan 手势。
        handleWrapView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            handleWrapView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight),
        ])
        // 审计第 10 项：把手行不进滚动栈，改由下方固定头部容器收纳。

        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "草稿箱"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: headerWrap.centerXAnchor),
            // 第 13 项：删 × 后头高不再由关闭钮链驱动，改钉死 44（原钮 32 + 上 6 + 下 6），
            // 热区不再被约 34 高头截断；标题仍顶锚 6、位置不动，标题底改 ≤。
            headerWrap.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.topAnchor.constraint(equalTo: headerWrap.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerWrap.bottomAnchor, constant: -4),
        ])
        // 审计第 10 项（草稿箱部分）：头部固定在面板顶部——把手行与
        // 标题行移出滚动栈，钉在 view 顶部的固定容器内；
        // 滚动区改为从容器下方起，余下内容（副标题起）按原顺序仍在
        // 滚动栈内。标题文案与头高均不动。
        fixedHeaderView.backgroundColor = .clear
        fixedHeaderView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fixedHeaderView)
        fixedHeaderView.addSubview(handleWrapView)
        fixedHeaderView.addSubview(headerWrap)
        NSLayoutConstraint.activate([
            fixedHeaderView.topAnchor.constraint(equalTo: view.topAnchor),
            fixedHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fixedHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            handleWrapView.topAnchor.constraint(equalTo: fixedHeaderView.topAnchor),
            handleWrapView.leadingAnchor.constraint(equalTo: fixedHeaderView.leadingAnchor),
            handleWrapView.trailingAnchor.constraint(equalTo: fixedHeaderView.trailingAnchor),
            headerWrap.topAnchor.constraint(equalTo: handleWrapView.bottomAnchor),
            headerWrap.leadingAnchor.constraint(equalTo: fixedHeaderView.leadingAnchor),
            headerWrap.trailingAnchor.constraint(equalTo: fixedHeaderView.trailingAnchor),
            headerWrap.bottomAnchor.constraint(equalTo: fixedHeaderView.bottomAnchor),
        ])

        subLabel.font = UIFont.systemFont(ofSize: 12)
        subLabel.textColor = BearyColors.gray
        subLabel.textAlignment = .center
        subLabel.numberOfLines = 0
        subWrap.translatesAutoresizingMaskIntoConstraints = false
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subWrap.addSubview(subLabel)
        NSLayoutConstraint.activate([
            subLabel.topAnchor.constraint(equalTo: subWrap.topAnchor),
            subLabel.bottomAnchor.constraint(equalTo: subWrap.bottomAnchor, constant: -12),
            subLabel.leadingAnchor.constraint(equalTo: subWrap.leadingAnchor),
            subLabel.trailingAnchor.constraint(equalTo: subWrap.trailingAnchor),
        ])
        contentStack.addArrangedSubview(subWrap)

        newButton.setTitle("新建日记", for: .normal)
        newButton.setTitleColor(BearyColors.gray, for: .normal)
        newButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        newButton.tintColor = BearyColors.gray
        if let editImage = BearyIconImages.image(named: "icon_edit", pointSize: 13) {
            newButton.setImage(editImage, for: .normal)
        }
        newButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: BearySpacing.iconTextGap, bottom: 0, right: 0)
        newButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        // 弹窗审计 E1-10：新建钮原视觉高约 37（13pt 字 + 上下各 10 内边距），
        // 未达 44。最小 44 高约束补足热区；
        // 外包 wrap 上缘 = 钮上缘、下缘留 12pt 底边距，44 帧完整落在 wrap 内，
        // 不被父容器截断；文案与位置不变，只虚线框高一档。
        newButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        newButton.addTarget(self, action: #selector(newDraftTapped), for: .touchUpInside)
        let newWrap = wrapWithBottomPadding(newButton, bottom: 12, horizontal: 16)
        contentStack.addArrangedSubview(newWrap)

        // 删除撤销条：删卡后出现，6 秒内点“撤销”恢复该篇，超时自动消失。
        undoWrap.isHidden = true
        undoWrap.translatesAutoresizingMaskIntoConstraints = false
        undoBar.backgroundColor = BearyColors.surface2
        undoBar.layer.cornerRadius = 12
        undoBar.layer.masksToBounds = true
        undoBar.translatesAutoresizingMaskIntoConstraints = false
        undoLabel.text = "草稿已删除"
        undoLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        undoLabel.adjustsFontForContentSizeCategory = true
        undoLabel.textColor = BearyColors.ink
        undoLabel.translatesAutoresizingMaskIntoConstraints = false
        undoButton.setTitle("撤销", for: .normal)
        undoButton.setTitleColor(BearyColors.ink, for: .normal)
        undoButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        undoButton.titleLabel?.adjustsFontForContentSizeCategory = true
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.addTarget(self, action: #selector(undoDeleteTapped), for: .touchUpInside)
        undoButton.bearyAddPressFeedback()
        // 弹窗审计 E1-10：撤销为纯文字约 19 高，未达 44。BearyHit44Button 扩热区
        // + 最小 44 高约束；undoBar 同补最小 44 高——否则 44 帧会超出约 41 高的
        // bar、上缘被 undoWrap 截断（wrap 上缘 = bar 上缘、无上边距）。
        // bar 高 44 时 label 上下 12 约束仍成立，文案居中位置基本不动。
        undoButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        undoBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        undoWrap.addSubview(undoBar)
        undoBar.addSubview(undoLabel)
        undoBar.addSubview(undoButton)
        NSLayoutConstraint.activate([
            undoBar.topAnchor.constraint(equalTo: undoWrap.topAnchor),
            undoBar.bottomAnchor.constraint(equalTo: undoWrap.bottomAnchor, constant: -12),
            undoBar.leadingAnchor.constraint(equalTo: undoWrap.leadingAnchor, constant: 16),
            undoBar.trailingAnchor.constraint(equalTo: undoWrap.trailingAnchor, constant: -16),
            undoLabel.leadingAnchor.constraint(equalTo: undoBar.leadingAnchor, constant: 14),
            undoLabel.topAnchor.constraint(equalTo: undoBar.topAnchor, constant: 12),
            undoLabel.bottomAnchor.constraint(equalTo: undoBar.bottomAnchor, constant: -12),
            undoButton.trailingAnchor.constraint(equalTo: undoBar.trailingAnchor, constant: -14),
            undoButton.centerYAnchor.constraint(equalTo: undoBar.centerYAnchor),
            undoButton.leadingAnchor.constraint(greaterThanOrEqualTo: undoLabel.trailingAnchor, constant: 8),
        ])
        contentStack.addArrangedSubview(undoWrap)

        listStack.axis = .vertical
        listStack.spacing = 10
        listStack.alignment = .fill
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listWrap.translatesAutoresizingMaskIntoConstraints = false
        listWrap.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: listWrap.topAnchor, constant: 2),
            listStack.bottomAnchor.constraint(equalTo: listWrap.bottomAnchor, constant: -4),
            listStack.leadingAnchor.constraint(equalTo: listWrap.leadingAnchor, constant: 16),
            listStack.trailingAnchor.constraint(equalTo: listWrap.trailingAnchor, constant: -16),
        ])
        contentStack.addArrangedSubview(listWrap)

        hintLabel.text = "点任意一份，接着上次的地方继续写"
        hintLabel.font = UIFont.systemFont(ofSize: 12)
        hintLabel.textColor = BearyColors.gray
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintWrap.translatesAutoresizingMaskIntoConstraints = false
        hintWrap.addSubview(hintLabel)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hintLabel.topAnchor.constraint(equalTo: hintWrap.topAnchor, constant: 14),
            hintLabel.bottomAnchor.constraint(equalTo: hintWrap.bottomAnchor, constant: -2),
            hintLabel.leadingAnchor.constraint(equalTo: hintWrap.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: hintWrap.trailingAnchor),
        ])
        contentStack.addArrangedSubview(hintWrap)

        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(bottomSpacer)
    }

    private func wrapWithBottomPadding(_ inner: UIView, bottom: CGFloat, horizontal: CGFloat = 0) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: wrap.topAnchor),
            inner.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -bottom),
            inner.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: horizontal),
            inner.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -horizontal),
        ])
        return wrap
    }

    private func buildConstraints() {
        NSLayoutConstraint.activate([
            // 审计第 10 项：滚动区从固定头部下方起，不再盖住头部。
            sheetScrollView.topAnchor.constraint(equalTo: fixedHeaderView.bottomAnchor),
            sheetScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheetScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: sheetScrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    // MARK: - 尺寸（系统 sheet 定高口径，见 BearySystemSheetSizing）

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    /// 第 13 项：面板高度按内容算，320 只作封顶；量不到（未布局／内容未就绪）
    /// 时保持原高（旧 draftBoxContentHeight 同款守卫）。
    /// 审计第 8 轮第 5 项：首轮数据未到时量的是加载态，面板保持加载态高；
    /// 回包后由 loadDrafts 完成回调再量一次，detent 经 refreshDetentsIfNeeded
    /// 一段动画过渡到内容态，顶边不跳。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        // 审计第 10 项：面板总高 = 固定头部高（把手占位 + 标题行）+ 滚动内容高；
        // 头部已移出滚动栈，故此处须把两部分相加，否则面板会矮一截。
        let headerHeight = fixedHeaderView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let contentHeight = contentStack.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let fittingHeight = headerHeight + contentHeight
        guard fittingHeight > 100 else { return }
        let height = min(fittingHeight, draftBoxMaxHeight) + extraBottomInset
        let preferred = CGSize(width: width, height: ceil(height))
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    private func updateBottomSpacer() {
        // 网页 sheet 底部内边距：14 + safe-area；滚动内容底边留出同样空间。
        let height = 14 + view.safeAreaInsets.bottom
        if let spacerConstraint = bottomSpacerHeight {
            if abs(spacerConstraint.constant - height) > 0.5 {
                spacerConstraint.constant = height
            }
        } else {
            let spacerConstraint = bottomSpacer.heightAnchor.constraint(equalToConstant: height)
            spacerConstraint.isActive = true
            bottomSpacerHeight = spacerConstraint
        }
    }

    // MARK: - 数据与渲染（只读 v3 多槽，存储层已按 updatedAt 倒序）

    /// G5：改用 loadAllResult——读取失败时置失败标记，渲染走失败态，
    /// 绝不以空数组冒充“暂无草稿”。
    /// 旧 23：读盘 + 解码在 BearyDraftStore.ioQueue（串行后台队列，与
    /// save/deleteAsync 同队列，读不到写一半的库）上执行；状态赋值与
    /// completion 一律回主线程，调用方在 completion 里做 UI 渲染。
    /// R23-#1：入队时（主线程）捕获当前账号与代次；ioQueue 内改用捕获
    /// 账号版 loadAllResult(forAccount:)，执行中不再重读 currentAccountId；
    /// 回主线程双核对（代次仍最新 且 会话账号仍为捕获账号），否则丢弃、
    /// 不调 completion——排队后切号读不到 B 的草稿，已读到 A 的结果也
    /// 不会在切号后贴到 B 的箱里。
    private func loadDrafts(completion: (() -> Void)? = nil) {
        // 审计四轮 06：入队时捕获账号与页面代次；后台读库直接用捕获账号，
        // 不再读执行时刻的当前账号。回包时两项都校验，不匹配就舍弃旧结果。
        let requestAccountId = BearyDraftStore.currentAccountId
        draftsLoadGeneration += 1
        let requestGeneration = draftsLoadGeneration
        BearyDraftStore.ioQueue.async { [weak self] in
            let result = BearyDraftStore.loadAllResult(forAccount: requestAccountId)
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                // 账号已切或已有新一轮读取发出时，旧结果直接舍弃、不碰界面、
                // 不调 completion（新一轮读取会自己结算渲染）。
                guard requestAccountId == BearyDraftStore.currentAccountId,
                      requestGeneration == strongSelf.draftsLoadGeneration else { return }
                switch result {
                case .success(let loaded):
                    strongSelf.drafts = loaded
                    strongSelf.draftsLoadFailed = false
                    strongSelf.draftsLoadCorrupt = false
                    // A1：部分恢复写实际结果——好草稿已回写、坏的只留备份时，
                    // 报实际找回数，不报“全部找回”也不报“全部丢失”。
                    if let recovered = BearyDraftStore.lastPartialRecovery, recovered.skipped > 0 {
                        strongSelf.showDraftToast(message: "找回了 \(recovered.kept) 份，还有 \(recovered.skipped) 份没读出来")
                    }
                case .failure(let err):
                    if case .partialSaveFailed(let recovered, let kept, let skipped, _) = err {
                        // A1：回写失败——原文件与备份都在，好草稿先预览，
                        // 不进失败态、不把好草稿藏起来；报实际找回数。
                        strongSelf.drafts = recovered
                        strongSelf.draftsLoadFailed = false
                        strongSelf.draftsLoadCorrupt = false
                        strongSelf.showDraftToast(message: "找回了 \(kept) 份，还有 \(skipped) 份没读出来")
                    } else {
                        strongSelf.drafts = []
                        strongSelf.draftsLoadFailed = true
                        if case .corruptStore(_) = err {
                            strongSelf.draftsLoadCorrupt = true
                        } else {
                            strongSelf.draftsLoadCorrupt = false
                        }
                    }
                }
                completion?()
            }
        }
    }

    /// R23-#1：账号切换——旧号模型立即清掉（在途旧读由 loadDrafts 的
    /// 代次 + 账号双核对丢弃；这里再把代次 +1，使已排队未执行的旧读
    /// 连主线程回包都进不来）。撤销队列一并清掉：旧号草稿不得经撤销
    /// 写盘进新号（saveAsyncReporting 按调用时账号写）。随后下一
    /// runloop 按新会话重读——此时容器 onUserChanged 已跑完 setAccount，
    /// loadDrafts 捕获的即新账号；若箱已在关闭则不重读。
    @objc private func handleDraftBoxUserChanged() {
        guard isViewLoaded else { return }
        draftsLoadGeneration += 1
        drafts = []
        draftsLoadFailed = false
        draftsLoadCorrupt = false
        currentDraftId = nil
        for pending in pendingUndos { pending.timer?.invalidate() }
        pendingUndos = []
        refreshUndoBar()
        renderDrafts()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isDismissing else { return }
            self.loadDrafts { [weak self] in
                self?.hideLoadingState()
                self?.renderDrafts()
                self?.draftsInitialLoaded = true
                self?.updatePreferredContentSize()
                self?.tryPlayEntrance()
            }
        }
    }

    /// 草稿库损坏态清除：先弹确认底 sheet（App 现有确认口径），确认后删当前
    /// 账号的坏 v3 文件（.bak 备份不动），成功后重读 → 空态；失败则留失败态＋toast。
    /// 审计四轮 13：确认框里把不可逆后果讲清——损坏的草稿删掉后在 App 里找不回来。
    @objc private func clearCorruptStoreTapped() {
        // A1：清除前先确认 .bak 真的存在；不存在时不承诺备份、文案如实说。
        // 审计四轮 13：确认框里把不可逆后果讲清——损坏的草稿删掉后在 App 里找不回来。
        // 第十轮审计 dsh II-1：与失败态副文案共用同一句（有／无备份各一句）。
        let backupKept = BearyDraftStore.hasCorruptBackup()
        let message = backupKept
            ? "这些草稿读不出来。清除后 App 内找不回，手机里的备份仍在；新草稿不受影响。"
            : "这些草稿读不出来。清除后无法找回；新草稿不受影响。"
        BearyConfirmSheet.show(from: self, title: "清除无法读取的草稿？", message: message, actions: [
            BearyConfirmSheet.Action(title: "清除", style: .destructive) { [weak self] in
                BearyDraftStore.clearCorruptStoreAsync { [weak self] ok in
                    guard let self = self else { return }
                    if ok {
                        self.loadDrafts { [weak self] in
                            self?.renderDrafts()
                        }
                    } else {
                        self.showDraftToast(message: "清除失败，请重试")
                    }
                }
            },
        ])
    }

    /// 112：非损坏型读取失败的重试：只重读草稿库、不删任何文件；
    /// 成功回列表、仍失败则留失败态（可再次点按重试）。
    @objc private func retryLoadDraftsTapped() {
        loadDrafts { [weak self] in
            self?.renderDrafts()
        }
    }

    /// 第一轮审计 21：草稿份数变化时 0.18s opacity 交叉淡变
    /// （BearyMotion.localStateDuration，许愿墙票数同款 transitionCrossDissolve）；
    /// 数值未变、减动效开、或视图未进窗口时直设终值。
    private func setSubLabelCountText(_ text: String) {
        guard subLabel.text != text, !UIAccessibility.isReduceMotionEnabled, subLabel.window != nil else {
            subLabel.text = text
            return
        }
        UIView.transition(with: subLabel, duration: BearyMotion.localStateDuration, options: .transitionCrossDissolve, animations: { self.subLabel.text = text })
    }

    private func renderDrafts() {
        for arranged in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        cardEntries = []
        deleteEntries.removeAll()
        lostEntries.removeAll()
        retryEntries.removeAll()
        if draftsLoadFailed {
            subLabel.text = nil
            subWrap.isHidden = true
            hintWrap.isHidden = true
            let failedStateView = BearyStateView()
            failedStateView.translatesAutoresizingMaskIntoConstraints = false
            // 两种失败态文案分开：损坏态讲清清除结果（删坏 v3 文件、只留 .bak，
            // 清除后重读回空态）；非损坏态沿用原话 +“重新读取”，确认框口径不动。
            // 审计四轮 13：损坏态不说“无法恢复”——只是本次读不出来，原始数据已保留；
            // 也不提 .bak（用户不认这个词），清除的不可逆后果放在确认框里讲。
            if draftsLoadCorrupt {
                // A1：损坏态副文案同样先确认 .bak 真的存在；没有备份时
                // 不谎称备份保留在手机里，文案如实说。措辞沿审计四轮 13：
                // 不说“无法恢复”，也不提 .bak（用户不认这个词）。
                let corruptSubtitle = BearyDraftStore.hasCorruptBackup()
                    ? "这些草稿读不出来。清除后 App 内找不回，手机里的备份仍在；新草稿不受影响。"
                    : "这些草稿读不出来。清除后无法找回；新草稿不受影响。"
                failedStateView.configure(kind: .error, title: "草稿库已损坏", subtitle: corruptSubtitle, iconName: nil, actionTitle: "清除损坏的草稿数据", actionStyle: .destructiveOutline(.regular), onAction: { [weak self] in self?.clearCorruptStoreTapped() })
            } else {
                failedStateView.configure(kind: .error, title: "草稿读取失败", subtitle: "原文件已保留，请稍后再试", iconName: nil, actionTitle: "重新读取", onAction: { [weak self] in self?.retryLoadDraftsTapped() })
            }
            listStack.addArrangedSubview(failedStateView)
            return
        }
        if drafts.isEmpty {
            subLabel.text = nil
            subWrap.isHidden = true
            hintWrap.isHidden = true
            let emptyStateView = BearyStateView()
            emptyStateView.translatesAutoresizingMaskIntoConstraints = false
            emptyStateView.configure(kind: .empty, title: "还没有草稿", subtitle: "写下的内容会自动存在这里", iconName: nil, actionTitle: nil)
            listStack.addArrangedSubview(emptyStateView)
        } else {
            subWrap.isHidden = false
            // Q10：App 草稿只存本机，副文案改“仅保存在本设备”
            //（原网页口径“仅保存在当前浏览器”不适用于 App 本机存储）。
            setSubLabelCountText("共 \(drafts.count) 份 · 仅保存在本设备")
            hintWrap.isHidden = false
            for draftValue in drafts {
                let card = makeCard(for: draftValue)
                cardEntries.append((button: card, draftValue: draftValue))
                listStack.addArrangedSubview(card)
            }
            // 审计第 12 项：渲染只建卡片终态，不在此播入场动画——入场动画
            // 唯一入口是 tryPlayEntrance（数据就绪 + 面板可见时才播首屏卡片）。
            // 新规矩 (b) 的“后续重渲不重播”由 tryPlayEntrance 的 didPlayEntrance /
            // draftCardsAnimatedOnce 门控承接，减动效下卡片同样直显终态。
        }
    }

    private func makeCard(for draftValue: BearyDraft) -> UIButton {
        let card = UIButton(type: .custom)
        card.backgroundColor = BearyColors.surface1
        card.layer.borderWidth = 0
        card.layer.cornerRadius = BearyCorners.single
        card.addTarget(self, action: #selector(cardTapped(_:)), for: .touchUpInside)
        card.bearyAddRowPressFeedback()

        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 6
        inner.alignment = .fill
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.spacing = 8
        topRow.alignment = .center
        let timeLabel = UILabel()
        timeLabel.text = draftTimeText(updatedAtSeconds: draftValue.updatedAt)
        timeLabel.font = BearyDynamicType.captionFont()
        timeLabel.adjustsFontForContentSizeCategory = true
        // 113：卡片时间改全 App 时间文案同款灰（此前误用蓝）；同卡“草稿已保存”
        // 状态行蓝色不动（见下方 saveStatus 分支）。
        timeLabel.textColor = BearyColors.gray
        topRow.addArrangedSubview(timeLabel)
        let spacer = UIView()
        topRow.addArrangedSubview(spacer)
        if !draftValue.images.isEmpty {
            let imageRow = UIStackView()
            imageRow.axis = .horizontal
            imageRow.spacing = 4
            imageRow.alignment = .center
            if let photoImage = BearyIconImages.image(named: "icon_image", pointSize: 12) {
                let photoView = UIImageView(image: photoImage)
                photoView.tintColor = BearyColors.gray
                photoView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    photoView.widthAnchor.constraint(equalToConstant: 12),
                    photoView.heightAnchor.constraint(equalToConstant: 12),
                ])
                imageRow.addArrangedSubview(photoView)
            }
            let countLabel = UILabel()
            countLabel.text = "\(draftValue.images.count)"
            countLabel.font = BearyDynamicType.numberFont()
            countLabel.adjustsFontForContentSizeCategory = true
            countLabel.textColor = BearyColors.gray
            imageRow.addArrangedSubview(countLabel)
            topRow.addArrangedSubview(imageRow)
        }
        // 卡片操作钮（网页 .df-trash 同款）：删除钮本地删卡；打开只走整卡点按。
        let deleteButton = UIButton(type: .custom)
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 24) {
            deleteButton.setImage(trashImage, for: .normal)
        }
        deleteButton.imageView?.contentMode = .scaleAspectFit
        deleteButton.tintColor = BearyColors.destructiveText
        // 无障碍：照抄回收站口径，把草稿标题拼进按钮名（“删除草稿，标题”）；
        // 无标题草稿用时间文案兜底，不读出空名；删除行为本身不动。
        let draftName = (draftValue.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        deleteButton.accessibilityLabel = draftName.isEmpty
            ? "删除草稿，\(draftTimeText(updatedAtSeconds: draftValue.updatedAt))"
            : "删除草稿，\(draftName)"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        // U19：删除钮触摸区域扩到 44×44（图标 8-12 改为 21pt 档，视觉随档变大）。
        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        deleteButton.addTarget(self, action: #selector(deleteTapped(_:)), for: .touchUpInside)
        deleteButton.bearyAddPressFeedback()
        topRow.addArrangedSubview(deleteButton)
        deleteEntries.append(button: deleteButton, value: draftValue)
        inner.addArrangedSubview(topRow)

        // 2026-11-14（132 真机）：标题独立成行（卡片标题字、粗体），不再挤进
        // 正文摘要槽——此前标题靠 summaryText 兜底进摘要，正文被标题顶掉、
        // 标题也看不出是标题，上方还空出一大段。无标题时整行 isHidden，
        // UIStackView 不留高度（不要只设空文字留着槽位）。
        let titleText = (draftValue.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleLabel = UILabel()
        titleLabel.font = BearyDynamicType.cardTitleFont()
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .left
        titleLabel.isHidden = titleText.isEmpty
        if !titleText.isEmpty {
            // 标题里的记号同样转回熊脸附件（与卡片标题同款）。
            titleLabel.attributedText = BearyText.inlineAttributedText(from: titleText, font: BearyDynamicType.cardTitleFont(), color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: draftValue.images.compactMap { $0.serverKey })
        }
        inner.addArrangedSubview(titleLabel)

        let summaryLabel = UILabel()
        summaryLabel.font = BearyDynamicType.diaryBodyFont()
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = BearyColors.ink
        summaryLabel.numberOfLines = 2
        summaryLabel.textAlignment = .left
        let summary = bodyPreviewText(for: draftValue)
        // 摘要是草稿正文原文，含 [mood:]/[gif:] 记号：走卡片同款渲染，
        // 行高 1.6、尾部截断口径与原来一致。
        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.lineHeightMultiple = 1.6
        summaryStyle.lineBreakMode = .byTruncatingTail
        summaryLabel.attributedText = BearyText.inlineAttributedText(from: summary, font: summaryLabel.font, color: BearyColors.ink, paragraphStyle: summaryStyle, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: draftValue.images.compactMap { $0.serverKey })
        inner.addArrangedSubview(summaryLabel)

        // 审计第 2 项：meta 区改流式布局 + 状态独立成行。顺序与原来一致：
        // 字数 → 写给 chip → 心情 chip → “忽略丢失图片”钮 → 正在写（流式区内自然换行），
        // 保存状态放末尾下一行，不再与 chip 挤同一行；字号与 chip 上限宽均不动。
        let metaFlow = BearyDraftMetaFlowView()
        let wordLabel = UILabel()
        // 草稿卡字数走可见口径：一个心情记号算 1 字（图占 1 格），与编辑器
        // 圆环一致（圆环按 textView.text 计，附件字符本身就是 1 格）。
        // #399 的 editorWordCount 是落盘串原串 count，含记号的草稿会把
        // "[mood:happy]" 这类记号原串全算进去，与圆环对不上，故此处不用它；
        // 去组词串一节已由落盘 committedContent 保证，不在此重复。
        wordLabel.text = "\(BearyText.inlineVisibleCount(of: draftValue.content)) 字"
        wordLabel.font = BearyDynamicType.numberFont()
        wordLabel.textColor = BearyColors.gray
        wordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 流式子项用手动 frame（见 BearyDraftMetaFlowView），不参与 Auto Layout。
        wordLabel.translatesAutoresizingMaskIntoConstraints = false
        metaFlow.addSubview(wordLabel)
        // DF-1 写给 chip（@ 图标 + 名，网页 buildDraftCard 的 d.to chip 口径）。
        if let recipientName = draftValue.recipientName, !recipientName.isEmpty {
            let chip = recipientChip(name: recipientName)
            chip.translatesAutoresizingMaskIntoConstraints = false
            metaFlow.addSubview(chip)
        }
        // DF-1 心情 chip 带 emote 图（网页 df-chip 内 emote 图 + 心情名）。
        if let moodKey = draftValue.mood, let moodName = BearyText.moodNames[moodKey] {
            let chip = moodChip(key: moodKey, name: moodName)
            chip.translatesAutoresizingMaskIntoConstraints = false
            metaFlow.addSubview(chip)
        }
        // DF-1 “忽略丢失图片”可点清除 chip：只针对已无物可续传的失败图
        // （本地文件与服务端 key 皆无，网页 imgs_lost 的等价情形）；点一下清掉
        // 这些图项与提示，可续传的失败图仍走“图片已存本机，待上传”状态行。
        if hasUnrecoverableImage(for: draftValue) {
            // Hit44：视觉约 19 高不动；纵向扩区以流式容器 bounds 为限（独占一行时到不了满 44），
            // 横向已够宽不扩；同行／邻行均为非交互 label／chip，不抢其他按钮热区。
            let lostButton = BearyHit44Button(type: .custom)
            lostButton.setTitle("忽略丢失图片", for: .normal)
            // D-G13：网页 .df-chip.df-lost 为 faint 底 + 灰字 + 500 字重；
            // 原 App 红底红字 semibold 改齐。
            lostButton.setTitleColor(BearyColors.gray, for: .normal)
            lostButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
            lostButton.backgroundColor = BearyColors.surface2
            lostButton.layer.cornerRadius = 999
            lostButton.layer.masksToBounds = true
            lostButton.contentEdgeInsets = UIEdgeInsets(top: 2.5, left: 9, bottom: 2.5, right: 9)
            lostButton.accessibilityLabel = "移除无法恢复的图片记录"
            lostButton.addTarget(self, action: #selector(clearLostTapped(_:)), for: .touchUpInside)
            lostButton.bearyAddPressFeedback()
            lostButton.translatesAutoresizingMaskIntoConstraints = false
            metaFlow.addSubview(lostButton)
            lostEntries.append(button: lostButton, value: draftValue)
        }
        // DF-1 正在写标记：编辑器当前正在写的那篇（currentDraftId 由容器设置）。
        if let current = currentDraftId, current == draftValue.draftId {
            let writingLabel = UILabel()
            writingLabel.text = "正在写"
            writingLabel.font = UIFont.systemFont(ofSize: 12)
            writingLabel.textColor = BearyColors.gray
            writingLabel.translatesAutoresizingMaskIntoConstraints = false
            metaFlow.addSubview(writingLabel)
        }
        let status = saveStatus(for: draftValue)
        let statusLabel = UILabel()
        // L7：状态文案必保全，不被长 chip 挤走。
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        statusLabel.text = saveStatusText(status)
        switch status {
        case .saved, .partial:
            statusLabel.textColor = BearyColors.blue
        case .unreadable, .failed:
            statusLabel.textColor = BearyColors.destructiveText
        }
        // 保存状态独立成行、左对齐（末尾 spacer 撑满行宽，视觉位置与原来行内左置一致）。
        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center
        statusRow.addArrangedSubview(statusLabel)
        let metaSpacer = UIView()
        statusRow.addArrangedSubview(metaSpacer)
        // 发布失败行：草稿箱是失败的持久落点——失败文案红字（单行截断，
        // 全文见 pill 状态表／失败 toast）＋重试钮；原日记已公开时钮文
        // “只重试新篇”，点按走发布中心一键重试，不重开编辑器。
        // 带钮时状态文案须可截断（原 required 抗压会把钮挤出卡外），钮本身不截断。
        if let failureMessage = draftValue.lastPublishFailure {
            statusLabel.text = failureMessage
            statusLabel.textColor = BearyColors.destructiveText
            statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let retryButton = BearyHit44Button(type: .custom)
            retryButton.setTitle(draftValue.sourcePublished ? "只重试新篇" : "重试", for: .normal)
            retryButton.setTitleColor(BearyColors.ink, for: .normal)
            retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            retryButton.backgroundColor = BearyColors.surface2
            retryButton.layer.cornerRadius = 999
            retryButton.layer.masksToBounds = true
            retryButton.contentEdgeInsets = UIEdgeInsets(top: 2.5, left: 9, bottom: 2.5, right: 9)
            retryButton.accessibilityLabel = draftValue.sourcePublished ? "只重试新篇，不再公开原日记" : "重试发布这篇草稿"
            retryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            retryButton.addTarget(self, action: #selector(retryPublishTapped(_:)), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            statusRow.addArrangedSubview(retryButton)
            retryEntries.append(button: retryButton, value: draftValue)
        }
        // 状态行与字数/心情行之间留 8pt（与内层 spacing 的 6pt 叠加后接近网页 meta 的 8pt 上边距）。
        // metaColumn 上边距仍取原 metaRow 的 2pt，行距 6pt 与内层 spacing 一致。
        let metaColumn = UIStackView()
        metaColumn.axis = .vertical
        metaColumn.spacing = 6
        metaColumn.alignment = .fill
        metaColumn.addArrangedSubview(metaFlow)
        metaColumn.addArrangedSubview(statusRow)
        let metaWrap = UIView()
        metaWrap.translatesAutoresizingMaskIntoConstraints = false
        metaWrap.addSubview(metaColumn)
        metaColumn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            metaColumn.topAnchor.constraint(equalTo: metaWrap.topAnchor, constant: 2),
            metaColumn.bottomAnchor.constraint(equalTo: metaWrap.bottomAnchor),
            metaColumn.leadingAnchor.constraint(equalTo: metaWrap.leadingAnchor),
            metaColumn.trailingAnchor.constraint(equalTo: metaWrap.trailingAnchor),
        ])
        inner.addArrangedSubview(metaWrap)
        // C7 改跟手拖动（视觉批 4-4，复用回收站拖拽模式）：草稿箱为 stack
        // 卡片、无 tableView 滑动 API，故左滑删除不用系统侧滑，改用每卡一个
        // UIPanGestureRecognizer 做 1:1 跟手拖动——手指左移卡片即左移，松手
        // 够 60pt 执行删除（复用删除钮路径：直接删卡 + 6 秒撤销条，与按钮
        // 一致，无确认框）、不够弹簧弹回原位。删除钮本身保留；点按打开
        // 不动。与上下滚动抢手势见 gestureRecognizerShouldBegin：横滑才
        // 接管，竖滑与滚动进行中一律放行给滚动视图（另见滚动视图的 pan
        // 须等本手势失败才启动，避免滚动半途被横滑抢走）。
        let drag = UIPanGestureRecognizer(target: self, action: #selector(draftCardDragged(_:)))
        drag.delegate = self
        card.addGestureRecognizer(drag)
        sheetScrollView.panGestureRecognizer.require(toFail: drag)
        // 审计第三轮无障碍：整卡是唯一打开入口，卡名须区分各卡——含标题、
        // 摘要、时间、保存状态；摘要过长时截断，读屏名不念全文。
        var nameParts = ["草稿"]
        let nameTitle = (draftValue.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameTitle.isEmpty { nameParts.append(nameTitle) }
        let nameSummary = summary.count > 80 ? String(summary.prefix(80)) + "…" : summary
        nameParts.append(nameSummary)
        nameParts.append(draftTimeText(updatedAtSeconds: draftValue.updatedAt))
        // 发布失败的卡：读屏名念失败全文，不念通用保存状态。
        if let failureMessage = draftValue.lastPublishFailure {
            nameParts.append(failureMessage)
        } else {
            nameParts.append(saveStatusText(status))
        }
        card.accessibilityLabel = nameParts.joined(separator: "，")
        return card
    }

    /// 手势仲裁（复用回收站口径）：只有左横滑才让卡片拖动手势接管；竖滑
    /// （|vy| ≥ |vx|）与右滑放行给滚动视图；滚动进行中（拖动/减速）不抢，
    /// 避免手指刚松开滚势未消时误触一张卡把它拖偏。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        if sheetScrollView.isDragging || sheetScrollView.isDecelerating { return false }
        let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: view) ?? .zero
        return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
    }

    @objc private func draftCardDragged(_ sender: UIPanGestureRecognizer) {
        guard let card = sender.view as? UIButton,
              let draftValue = cardEntries.first(where: { $0.button === card })?.draftValue else { return }
        switch sender.state {
        case .began:
            if let previous = draftDraggingCard, previous !== card {
                previous.transform = .identity
            }
            draftDraggingCard = card
            // 入场错峰动画若还在跑（transform/alpha 在途），先停掉它：
            // 动画模型值本就是终值（alpha 1、transform identity），停动画
            // 不会闪回，手指接管后 transform 只由拖动写（回收站同款处理）。
            card.layer.removeAllAnimations()
        case .changed:
            let translation = sender.translation(in: view).x
            let offset = max(-draftDragMaxOffset, min(0, translation))
            card.transform = CGAffineTransform(translationX: offset, y: 0)
        case .ended:
            draftDraggingCard = nil
            let offset = card.transform.tx
            if offset <= -draftDragDeleteThreshold {
                // 拖过阈值执行删除：复用删除钮路径（删盘成功后删卡 + 6 秒撤销条），
                // 拖动 transform 不先复位——复位会让卡片先跳回原位再收起，
                // 直接交接给 deleteTapped，删盘成功后的收起动画里一并滑回原位，视觉上连续。
                guard let button = deleteEntries.button(forID: draftValue.draftId) else {
                    resetDraftDragCard(card)
                    return
                }
                deleteTapped(button)
            } else {
                // 未过阈值弹簧复位：松手速度归一化后传弹簧（松手速度 ÷ 回程
                // 距离），慢拖速度近 0 即约等于 0，快甩则带上真实松手速度。
                let distance = abs(offset)
                let springVelocity = distance > 0 ? sender.velocity(in: view).x / distance : 0
                resetDraftDragCard(card, initialSpringVelocity: springVelocity)
            }
        case .cancelled, .failed:
            draftDraggingCard = nil
            resetDraftDragCard(card)
        default:
            break
        }
    }

    /// 拖动结束/取消后卡片归位：减动效直设（回收站 resetTrashDragRow 同款
    /// 门控），其余以统一弹簧弹回（0.26s／damping 0.7，只走 transform）。
    /// completion 在归位动画完成后调（减动效直接调），供拒删摇头接在归位后。
    private func resetDraftDragCard(_ card: UIButton, initialSpringVelocity: CGFloat = 0, completion: (() -> Void)? = nil) {
        if UIAccessibility.isReduceMotionEnabled {
            card.transform = .identity
            completion?()
            return
        }
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: initialSpringVelocity, options: .curveEaseOut, animations: {
            card.transform = .identity
        }, completion: { _ in completion?() })
    }

    private func chipShell() -> UIView {
        let chip = UIView()
        chip.backgroundColor = BearyColors.surface2
        chip.layer.cornerRadius = 999
        chip.layer.masksToBounds = true
        return chip
    }

    /// I16：emote 可用性与播放器回退链同口径——Lottie JSON（当前深浅）或 PNG
    /// 任一存在即有图；两者皆无时播放器只会留 14px 空白，故不放 emote 视图。
    /// （JSON 存在但解析失败的极端情形不在此判定内，属资产损坏而非缺失。）
    private func isEmoteAssetAvailable(key: String) -> Bool {
        let dark = traitCollection.userInterfaceStyle == .dark
        let jsonName = dark ? key + "_dark" : key
        if Bundle.main.url(forResource: jsonName, withExtension: "json") != nil {
            return true
        }
        return BearyEmoteImages.image(for: key, dark: dark) != nil
    }

    private func moodChip(key: String, name: String) -> UIView {
        let chip = chipShell()
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        // I16：emote 加载失败时隐藏 14px 视图，只留心情名。
        // D-G12：网页 .df-chip img 为 14px，原 16 改 14。
        if isEmoteAssetAvailable(key: key) {
            let emoteView = BearyEmoteView(key: key, animated: false)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                emoteView.widthAnchor.constraint(equalToConstant: 14),
                emoteView.heightAnchor.constraint(equalToConstant: 14),
            ])
            row.addArrangedSubview(emoteView)
        }
        let label = UILabel()
        label.text = name
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = BearyColors.ink
        // L7：chip label 省略号 + 低压缩，chip 本身设最大宽，不挤走状态文案。
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        chip.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2.5),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2.5),
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
        return chip
    }

    private func recipientChip(name: String) -> UIView {
        let chip = chipShell()
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        // D-G12：网页 .df-chip .icon 为 12px，原 14 改 12。
        if let atImage = BearyIconImages.image(named: "icon_at", pointSize: 12) {
            let imageView = UIImageView(image: atImage)
            imageView.tintColor = BearyColors.ink
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 12),
                imageView.heightAnchor.constraint(equalToConstant: 12),
            ])
            row.addArrangedSubview(imageView)
        }
        // 2-5：@ 名拆成独立 label 单行截断、最大宽 80pt（“@”前缀
        // 另起一 label 保全不截断）；长名不再把 meta 行状态文案顶到换行边缘，
        // 状态文案的 required 抗压缩不动。chip 整体 180 上限保留作兜底。
        let prefixLabel = UILabel()
        prefixLabel.text = "@"
        prefixLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        prefixLabel.textColor = BearyColors.ink
        prefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(prefixLabel)
        let label = UILabel()
        label.text = name
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = BearyColors.ink
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 80).isActive = true
        row.addArrangedSubview(label)
        chip.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2.5),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2.5),
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
        return chip
    }

    /// 5-19：无物可续传的唯一判定（失败且本地文件与服务端 key 皆无）——
    /// chip 显隐（hasUnrecoverableImage）与清除过滤共用同一判定，口径差一位
    /// 就可能清掉可续传图或漏清，本处收敛为一处。
    private func isUnrecoverableImage(_ item: BearyDraftImageItem) -> Bool {
        return item.state == .failed && item.localFile == nil && item.serverKey == nil
    }

    private func hasUnrecoverableImage(for draftValue: BearyDraft) -> Bool {
        for item in draftValue.images {
            if isUnrecoverableImage(item) {
                return true
            }
        }
        return false
    }

    /// “忽略丢失图片”chip 点按：清掉已无物可续传的失败图项并后台写盘、只刷新这一张卡
    /// （网页点 imgs_lost chip 清标记 + 重渲的等价动作；可续传图项不受影响）。
    /// 审计第 8 轮第 9 项：旧流程先 renderDrafts() 又在写盘成功回调里再
    /// renderDrafts()，整列卡片重建两次、可见位置也无保留；现只原位替换
    /// 这一张卡，写盘成功直接结束，失败才按磁盘重读恢复该卡并 toast。
    @objc private func clearLostTapped(_ sender: UIButton) {
        guard var draftValue = lostEntries.value(for: sender) else { return }
        draftValue.images = draftValue.images.filter { [weak self] item in
            guard let strongSelf = self else { return true }
            return strongSelf.isUnrecoverableImage(item) == false
        }
        for offset in 0..<drafts.count {
            if drafts[offset].draftId == draftValue.draftId {
                drafts[offset] = draftValue
            }
        }
        // 清除后立即只刷新这一张卡（图片计数、状态行、“忽略丢失图片” chip
        // 都随新卡重算），不等磁盘写盘回包；其余卡片不动、滚动位置由锚点保留。
        replaceCard(for: draftValue)
        // G5：改用带 Bool 回调的写盘；写盘成功直接结束，不再重渲；
        // 失败时从磁盘重读恢复该卡并 toast，不让“已清除”的 UI 盖住实际仍在的内容。
        BearyDraftStore.saveAsyncReporting(draftValue) { [weak self] ok in
            guard let strongSelf = self else { return }
            if ok {
                return
            }
            strongSelf.loadDrafts {
                if let restored = strongSelf.drafts.first(where: { $0.draftId == draftValue.draftId }) {
                    strongSelf.replaceCard(for: restored)
                } else {
                    strongSelf.renderDrafts()
                }
                strongSelf.showDraftToast(message: "保存失败，图片提示还在")
            }
        }
    }

    /// 审计第 8 轮第 9 项：只原位替换 draftId 对应的那一张卡，不重建整列。
    /// 旧卡摘掉、新卡按 drafts 里的排位插回同一位置（复用 insertRestoredCard
    /// 的可见锚点口径，卡片变矮不再把正在看的内容推走）；其余卡片、滚动
    /// 位置都不动。失败态／找不到旧卡时退回全量渲染。
    private func replaceCard(for draftValue: BearyDraft) {
        guard !draftsLoadFailed else {
            renderDrafts()
            return
        }
        guard let oldEntryIndex = cardEntries.firstIndex(where: { $0.draftValue.draftId == draftValue.draftId }),
              let stackIndex = listStack.arrangedSubviews.firstIndex(where: { $0 === cardEntries[oldEntryIndex].button }) else {
            renderDrafts()
            return
        }
        let oldCard = cardEntries[oldEntryIndex].button
        // 插卡前采样当前可见卡片锚点（见 insertRestoredCard）：替换布局后
        // 按锚点恢复偏移，卡片变矮不推走正在看的内容。
        let anchor = firstVisibleCardAnchor()
        listStack.removeArrangedSubview(oldCard)
        oldCard.removeFromSuperview()
        cardEntries.removeAll { $0.draftValue.draftId == draftValue.draftId }
        deleteEntries.removeAll(id: draftValue.draftId)
        lostEntries.removeAll(id: draftValue.draftId)
        // makeCard 会把删除钮／丢失图钮登记进 deleteEntries／lostEntries（与 renderDrafts 同路），
        // 卡片登记追加在末尾，再挪回旧卡的位置，保持卡片数组与栈内顺序一致。
        let card = makeCard(for: draftValue)
        if let appendedIndex = cardEntries.firstIndex(where: { $0.draftValue.draftId == draftValue.draftId }),
           appendedIndex != oldEntryIndex {
            let entry = cardEntries.remove(at: appendedIndex)
            cardEntries.insert(entry, at: min(oldEntryIndex, cardEntries.count))
        }
        listStack.insertArrangedSubview(card, at: min(stackIndex, listStack.arrangedSubviews.count))
        restoreVisibleCardAnchor(anchor, restoredCard: card)
    }

    // MARK: - 文案推导（网页口径移植）

    /// 撤销条用摘要：标题优先（标题最能认出是哪篇），无标题走正文预览。
    private func summaryText(for draftValue: BearyDraft) -> String {
        let title = (draftValue.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return bodyPreviewText(for: draftValue)
    }

    /// 卡片正文预览（DF-1 兜底顺序改网页口径 buildDraftCard）：
    /// 正文 > 只有图片 > 只有引用 > 只有心情 > 有天气/写给则“（还没写字）” > “（空白草稿）”。
    /// 标题不在这里——标题另有独立标题行（见 makeCard）。只有标题、无正文时
    /// 给“（还没写字）”，不谎称“（空白草稿）”。
    private func bodyPreviewText(for draftValue: BearyDraft) -> String {
        let trimmed = draftValue.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if !draftValue.images.isEmpty {
            let district = (draftValue.locationDistrict ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let place = district.isEmpty ? (draftValue.locationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : district
            if place.isEmpty {
                return "（\(draftValue.images.count) 张图片）"
            }
            return "（\(draftValue.images.count) 张图片 · \(place)）"
        }
        if draftValue.quoteId != nil {
            return "（只有引用）"
        }
        if let moodKey = draftValue.mood, BearyText.moodNames[moodKey] != nil {
            return "（只有心情）"
        }
        // G19：recipientName 口径收紧为非空（空字符串不再触发“还没写字”兜底，
        // 与存储层 hasContent 的 recipientName 非空判定一致）。
        // 只有标题、无正文时同样给“（还没写字）”——标题行已显示标题，
        // 摘要不谎称“（空白草稿）”。
        if draftValue.weather != nil || draftValue.recipientId != nil || !(draftValue.recipientName ?? "").isEmpty
            || !(draftValue.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "（还没写字）"
        }
        return "（空白草稿）"
    }

    private enum DraftSaveStatus {
        case saved
        case partial
        case unreadable
        case failed
    }

    /// v3 没有显式的保存失败标记，状态由图片项推导：
    /// 失败且本地文件与服务端 key 皆无（无物可续传）→ 失败红字“草稿保存失败，请重试”；
    /// 本地文件在但读不出（归一化派生的 .unreadable）→ 红字“有图片无法恢复，请重新选择”；
    /// 其余失败项（本地文件尚在、可续传）与 pending 项（已落盘引用、尚未上传）
    /// → 蓝字“图片已存本机，待上传”——文件已存本机，只是还没上传，不说“未保存”；
    /// 无失败/待传/损坏项 → 草稿已保存。
    /// 优先级：无物可续传 > 读不出 > 待上传；与编辑器口径一致（本地文件完整的图
    /// 是正常态，不算未保存）。
    private func saveStatus(for draftValue: BearyDraft) -> DraftSaveStatus {
        var hasFailedImage = false
        var hasUnrecoverableImage = false
        var hasPendingImage = false
        var hasUnreadableImage = false
        for item in draftValue.images {
            if item.state == .unreadable {
                hasUnreadableImage = true
            }
            if item.state == .failed {
                hasFailedImage = true
                if item.localFile == nil && item.serverKey == nil {
                    hasUnrecoverableImage = true
                }
            }
            if item.state == .pending {
                hasPendingImage = true
            }
        }
        if hasUnrecoverableImage {
            return .failed
        }
        if hasUnreadableImage {
            return .unreadable
        }
        if hasFailedImage || hasPendingImage {
            return .partial
        }
        return .saved
    }

    /// 保存状态文案（状态行与卡片读屏名同款，不另起第二套说法）。
    private func saveStatusText(_ status: DraftSaveStatus) -> String {
        switch status {
        case .saved: return "草稿已保存"
        case .partial: return "图片已存本机，待上传"
        case .unreadable: return "有图片无法恢复，请重新选择"
        case .failed: return "草稿保存失败，请重试"
        }
    }

    /// 网页 dfTimeStr 移植：v3 updatedAt 为秒，网页 updated_at 为毫秒，此处按秒换算。
    /// 2026-11-21 日期完全本地化：相对时间与绝对日期跟 App 语言（见 BearyLocalizedDate），
    /// 中文输出与改前一致（昨天仍补零 HH:mm，W9 定版口径不变）；今天／昨天判定与
    /// 显示沿用既有北京日历／GMT+8 口径（扫荡 B 定版），本支只改语言、不动时区。
    /// 2026-11-25 Li 定去“前”：分钟／小时走日记版 helper（X 分钟／X 小时）。
    private func draftTimeText(updatedAtSeconds: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: updatedAtSeconds)
        let now = Date()
        let diff = now.timeIntervalSince(date)
        if diff < 3600 {
            let minutes = max(1, Int(floor(diff / 60)))
            return BearyLocalizedDate.diaryMinutesString(minutes)
        }
        // 扫荡 B：今天/昨天判定走北京日历，与显示的北京时区一致。
        // 旧口径用 Calendar.current（设备时区）：设备时区非北京时，跨北京午夜
        // 前后会把“昨天”误判成“今天”（或反之），而显示的 HH:mm/M月d日又是
        // 北京时间，两处口径打架；本处与回收站 TrashText.deletedLabel 对齐。
        let calendar = BearyBeijingDay.calendar
        if calendar.isDateInToday(date) {
            let hours = Int(floor(diff / 3600))
            return BearyLocalizedDate.diaryHoursString(hours)
        }
        if calendar.isDateInYesterday(date) {
            // W9：原生定版统一补零（HH:mm），不再以网页昨天 H:mm 口径为准。
            return BearyLocalizedDate.yesterdayWord(timeZone: BearyLocalizedDate.gmt8) + " " + BearyLocalizedDate.timeStringPadded(from: date, timeZone: BearyLocalizedDate.gmt8)
        }
        return BearyLocalizedDate.monthDayString(from: date, timeZone: BearyLocalizedDate.gmt8)
    }

    // MARK: - 退场守卫与退场（入场面板动画走系统 sheet，卡片入场见 tryPlayEntrance）

    /// 三路统一离场守卫：新建、点开、重试共用（系统 sheet 的下滑／点遮罩
    /// 关闭另走 UIAdaptivePresentationControllerDelegate，见文件末尾）。
    /// 撤销只活在箱内 pendingUndos 内存（deinit 即清计时器与队列），故 6 秒窗内
    /// 任一路离箱都会丢撤销：有可撤销笔时一律先弹确认，确认才执行该路的离场
    /// 动作，取消则保留箱内状态与撤销队列；无待撤销笔时各路关闭路径一字不动。
    /// 关闭路的提示文案与确认钮文案保持原样，新建／点开路复用同一条提示文案，
    /// 确认钮为“仍要继续”。
    private func exitWithUndoGuard(confirmTitle: String, confirmedExit: @escaping () -> Void) {
        // 守卫原先只认 UIAlertController；确认改走底 sheet 后，有在途弹窗
        // 即 presentedViewController 非 nil，一律不再叠弹（原意不变）。
        if presentedViewController != nil { return }
        if !pendingUndos.isEmpty {
            // 原 alert 无标题，底 sheet 标题传空（只显说明＋按钮，不另起文案）。
            // 说明走 catalog（draftbox.undo_exit_message），与系统关闭守卫共用同一 key。
            BearyConfirmSheet.show(from: self, title: "", message: NSLocalizedString("draftbox.undo_exit_message", comment: ""), actions: [
                BearyConfirmSheet.Action(title: confirmTitle, style: .destructive) {
                    confirmedExit()
                },
            ], onDismissWithoutAction: { [weak self] in
                // 取消关闭时焦点回面板标题（面板本就在原位，系统 sheet 无拖动态可复位）。
                guard let strongSelf = self else { return }
                UIAccessibility.post(notification: .layoutChanged, argument: strongSelf.titleLabel)
            })
            return
        }
        confirmedExit()
    }

    /// 弹窗审计 E1-18 统一退场完成回调：关闭、打开、新建三路共用同一
    /// 退场（退场动画走系统 sheet，减动效直 dismiss；本函数只调 dismiss，
    /// 不再手动播——同一关闭只播一次退场动画），dismiss 完成后
    /// 才调 completion（即原 onNew/onOpen 回调）。
    /// 退场在途时再点按一律忽略：不重复播动画，也不让“关闭后又打开”
    /// 的回调在关闭完成后再执行；先到的一路为准。
    private func dismissWithExitAnimation(completion: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        // 无障碍：纯关闭（completion 为 nil）时，dismiss 完成后把焦点还给
        // 打开方传入的触发入口；新建／打开草稿带回调时新界面接管焦点，
        // 这里不发。触发入口已隐藏或离线时不发。
        let focusReturnElement = accessibilityFocusReturnElement
        // 包裹闭包只活到 dismiss 完成，强持有触发入口一小段无害，不用 weak
        //（weak 捕获可选值会在闭包内变成双层可选，反而容易写错）。
        let wrappedCompletion: (() -> Void)? = {
            completion?()
            if completion == nil, let element = focusReturnElement,
               !element.isHidden, element.window != nil {
                UIAccessibility.post(notification: .layoutChanged, argument: element)
            }
        }
        if UIAccessibility.isReduceMotionEnabled {
            dismiss(animated: false, completion: wrappedCompletion)
            return
        }
        dismiss(animated: true, completion: wrappedCompletion)
    }

    @objc private func newDraftTapped() {
        // 与点开路共用 exitWithUndoGuard：6 秒窗内有可撤销笔时先弹确认，
        // 取消保留箱内撤销，确认才退场并调原 onNew 回调。
        exitWithUndoGuard(confirmTitle: "仍要继续") { [weak self] in
            self?.dismissWithExitAnimation { [weak self] in
                self?.onNewHandler()
            }
        }
    }

    /// G7：箱内轻提示：委托统一 BearyToast。“新 toast 先清旧 toast”
    /// 由统一组件内部承接（同容器旧 toast 先移除）。草稿箱是系统 sheet
    /// 模态，盖住 Chrome，落点由组件回落安全区 -32。
    /// 调用签名与文案、触发时机不变。
    private func showDraftToast(message: String) {
        BearyToast.show(in: view, message: message)
    }

    /// M20：撤销条淡入/滑入（减动效直接显示）。
    /// 审计第 8 轮第 6 项：条在滚动栈内占位，显隐只动画条本身会让列表
    /// 瞬间错位——显隐与布局（layoutIfNeeded）走同一段动画，并按首个
    /// 可见卡片锚点恢复偏移，正在看的卡片不动。
    private func showUndoAnimated() {
        undoWrap.isHidden = false
        undoWrap.alpha = 1
        undoWrap.transform = .identity
        if UIAccessibility.isReduceMotionEnabled {
            return
        }
        let anchor = firstVisibleCardAnchor()
        undoWrap.alpha = 0
        undoWrap.transform = CGAffineTransform(translationX: 0, y: 8)
        if BearyMotion.animated(true) && !sheetScrollView.isDragging && !sheetScrollView.isDecelerating {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: .curveEaseOut, animations: {
                self.undoWrap.alpha = 1
                self.undoWrap.transform = .identity
                self.view.layoutIfNeeded()
                if let targetY = self.anchorContentOffsetY(for: anchor) {
                    self.sheetScrollView.contentOffset.y = targetY
                }
            })
        } else {
            undoWrap.alpha = 1
            undoWrap.transform = .identity
            view.layoutIfNeeded()
            if let targetY = anchorContentOffsetY(for: anchor) {
                sheetScrollView.contentOffset.y = targetY
            }
        }
    }

    /// 审计第 8 轮第 6 项：撤销条到期隐藏与显示同口径——淡出＋布局收起
    /// 走同一段动画，并按首个可见卡片锚点恢复偏移；最后一条过期时眼前
    /// 的卡片不再往上跳。减动效／拖动中直接落定（拖动时只直设偏移，
    /// 不与手势抢动画）。
    private func hideUndoAnimated() {
        guard !undoWrap.isHidden else { return }
        if UIAccessibility.isReduceMotionEnabled {
            undoWrap.isHidden = true
            undoWrap.alpha = 1
            undoWrap.transform = .identity
            return
        }
        let anchor = firstVisibleCardAnchor()
        if BearyMotion.animated(true) && !sheetScrollView.isDragging && !sheetScrollView.isDecelerating {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: .curveEaseOut, animations: {
                self.undoWrap.alpha = 0
                self.undoWrap.isHidden = true
                self.view.layoutIfNeeded()
                if let targetY = self.anchorContentOffsetY(for: anchor) {
                    self.sheetScrollView.contentOffset.y = targetY
                }
            }, completion: { [weak self] _ in
                guard let self else { return }
                // 隐藏动画期内又有新删笔时条已重新出现，不复位它的初态。
                if self.pendingUndos.isEmpty {
                    self.undoWrap.alpha = 1
                    self.undoWrap.transform = .identity
                }
            })
        } else {
            undoWrap.isHidden = true
            undoWrap.alpha = 1
            undoWrap.transform = .identity
            view.layoutIfNeeded()
            if let targetY = anchorContentOffsetY(for: anchor) {
                sheetScrollView.contentOffset.y = targetY
            }
        }
    }

    @objc private func cardTapped(_ sender: UIButton) {
        for entry in cardEntries {
            if entry.button === sender {
                // E1-18：整卡打开先走统一退场，dismiss 后再调原 onOpen 回调；
                // 与关闭／新建路共用 exitWithUndoGuard：6 秒窗内有可撤销笔时
                // 先弹确认，取消保留箱内撤销，确认才退场。
                exitWithUndoGuard(confirmTitle: "仍要继续") { [weak self] in
                    self?.dismissWithExitAnimation { [weak self] in
                        self?.onOpenHandler(entry.draftValue)
                    }
                }
                return
            }
        }
    }

    /// 发布失败重试（草稿箱入口）：中心有失败原任务且草稿未被改过时一键
    /// 重跑（原日记已公开即只重试新篇），随后退箱、进度看 Chrome 上的胶囊；
    /// 中心无原任务（如重启后）或草稿已改过时改走正常打开编辑器再点发布——
    /// 编辑器读草稿持久标记后仍跳过门禁与 setVisibility，只发新篇。
    @objc private func retryPublishTapped(_ sender: UIButton) {
        guard let draftValue = retryEntries.value(for: sender) else { return }
        if BearyPublishCenter.shared.isPublishing(draftId: draftValue.draftId) {
            showDraftToast(message: "发布中…")
            return
        }
        switch BearyPublishCenter.shared.retryPublish(draftId: draftValue.draftId) {
        case .started:
            // 重试已接管，退箱看胶囊（toast 会随箱一起退场，不另弹）。
            exitWithUndoGuard(confirmTitle: "仍要继续") { [weak self] in
                self?.dismissWithExitAnimation { }
            }
        case .alreadyRunning:
            showDraftToast(message: "发布中…")
        case .needsEditor:
            exitWithUndoGuard(confirmTitle: "仍要继续") { [weak self] in
                self?.dismissWithExitAnimation { [weak self] in
                    self?.onOpenHandler(draftValue)
                }
            }
        }
    }

    /// 本地删卡：从列表移除并只删该篇 v3 草稿；图片文件不动（撤销期内可原样恢复，
    /// 超时后由编辑器侧的孤文件清理承接，不在此处改存储结构）。
    @objc private func deleteTapped(_ sender: UIButton) {
        guard let draftValue = deleteEntries.value(for: sender) else { return }
        // 发布后台化：发布中的草稿不许从草稿箱删——只删记录不删文件，
        // 失败后重发即丢正文。拦在动画与 pendingUndos 之前，卡片不动。
        if BearyPublishCenter.shared.isPublishing(draftId: draftValue.draftId) {
            // A2：左滑拒删也要回原位——拖动 transform 若不复位，卡片就停
            // 在半路（按钮路径卡片本就在原位，复位是无视觉变化的空操作）。
            // 拒绝反馈（震动＋音效＋toast），摇头等弹簧归位完成后再抖，
            // 免得与归位动画抢 transform。
            if let cardView = cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId })?.button {
                BearyIconMotion.playDenyFeedback()
                resetDraftDragCard(cardView) { [weak self] in
                    guard let strongSelf = self else { return }
                    BearyIconMotion.denyShake(on: cardView, key: "bearyDenyShake")
                }
            }
            showDraftToast(message: "发布中…")
            return
        }
        // G17：按 draftId 查找下标，不再依赖删除钮数组与草稿数组的下标对齐。
        guard let draftIndex = drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) else { return }
        // 连点／拖动＋按钮重复进删只算一笔：在途笔未清前不再追加。
        guard !pendingUndos.contains(where: { $0.draft.draftId == draftValue.draftId }) else { return }
        // 审计 P1-8：多笔队列——新删只追加本笔，不再使上一笔过期。
        pendingUndos.append(PendingUndo(draft: draftValue, index: draftIndex, timer: nil))
        // R21-A1：入队即刷新撤销条——条上显示的永远是队列最后一笔，
        // 不再等删盘回调才刷新，否则 B 的退场／删盘未完成时条仍显示 A，
        // 点撤销却取到 B，与显示不一致。
        refreshUndoBar()
        // A3：删盘先行——卡片只给按压反馈（删除钮自带 bearyAddPressFeedback），
        // 删盘成功后才收起移除；失败卡片原地不动（见 finishDelete）。
        // 先禁用删钮与卡片，免得删盘在途时重复进删或点开该卡。
        sender.isEnabled = false
        cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId })?.button.isUserInteractionEnabled = false
        finishDelete(draftValue: draftValue)
    }

    /// 删除收尾：先后台删盘，成功后才收起卡片、从内存列表移除并出撤销条；
    /// 失败时卡片原地不动（只摇头＋toast），不让它先消失再回来。
    /// G7：删盘走带 Bool 回传的 deleteAsyncReporting（老 deleteAsync
    /// 保留给编辑器两处调用作兼容）。
    private func finishDelete(draftValue: BearyDraft) {
        BearyDraftStore.deleteAsyncReporting(draftId: draftValue.draftId) { [weak self] ok in
            guard let strongSelf = self else { return }
            // r28-3：删盘在途时点了撤销 → 恢复写盘已排在删盘之后入队，串行
            // ioQueue 下先删后存确定发生，磁盘上的草稿仍在，故回调里直接
            // 跳过（不移除、不出条、不计时）；恢复成败由撤销自己的 save 回调汇报。
            // （旧流程删盘排在收起动画之后，撤销的存先于删入队，会把刚恢复的
            // 草稿静默删掉，才须在入队前拦下；删盘先行后该窗口已不存在。）
            guard strongSelf.pendingUndos.contains(where: { $0.draft.draftId == draftValue.draftId }) else { return }
            if !ok {
                // 失败：只清本笔的暂存与计时器（撤销条尚未出），不动队列里其余笔；
                // 内存与卡片都没动过，只需解禁删钮与卡片、摇头＋toast。
                if let idx = strongSelf.pendingUndos.firstIndex(where: { $0.draft.draftId == draftValue.draftId }) {
                    strongSelf.pendingUndos[idx].timer?.invalidate()
                    strongSelf.pendingUndos.remove(at: idx)
                    strongSelf.refreshUndoBar()
                }
                if let cardView = strongSelf.cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId })?.button {
                    cardView.isUserInteractionEnabled = true
                    BearyIconMotion.playDenyFeedback()
                    // 删盘失败：卡片可能带着左滑位移进来（拖动进删不先复位），
                    // 不复位就停在半偏移位；先弹簧归位、摇头等归位完成后再抖
                    //（与发布中拒删分支同口径，免得摇头与归位抢 transform）。
                    strongSelf.resetDraftDragCard(cardView) { [weak self] in
                        guard let strongSelf = self else { return }
                        BearyIconMotion.denyShake(on: cardView, key: "bearyDenyShake")
                    }
                }
                if let deleteButton = strongSelf.deleteEntries.button(forID: draftValue.draftId) {
                    deleteButton.isEnabled = true
                }
                strongSelf.showDraftToast(message: "删除失败，请重试")
                return
            }
            // 2026-11-14 点仍要关闭后已删草稿复活修：删盘成功即通知编辑器，
            // 不再只认开箱时拍的 currentDraftId 快照——恢复可能还没落地，
            // 盒子那时根本不知道这篇就是正在写的那篇；编辑器收到后自行
            // 判断（只认当前握着的那篇），并把该 id 记进已删集合，拦住
            // 随后落地的恢复。6 秒内点撤销会把草稿插回箱里，编辑器侧
            // 已清的槽位由 onUndoCurrentDraft 接回。
            // 注意：通知放这里（删盘成功回调）而不是收起完成处——收起
            // 动画 0.26s 内盒子若被关掉，收起完成回调拿不到 self，通知
            // 就永远发不出去，编辑器侧的恢复仍会把已删草稿填回来。
            strongSelf.onDeleteCurrentDraft?(draftValue.draftId)
            strongSelf.collapseDeletedCardAndRemove(draftValue: draftValue)
        }
    }

    /// 删盘成功后的收起与移除：卡片先淡出、收至 0 高，再从内存列表移除
    /// 并出撤销条、起 6 秒计时。收起动画期内点了撤销（撤销条来自队列
    /// 里其余笔）→ 该笔已不在 pendingUndos，收起完成也不再移除，
    /// 撤销重建的卡片不受影响。
    private func collapseDeletedCardAndRemove(draftValue: BearyDraft) {
        // M3：删卡先高度收起动画再移除，其余卡在栈内原地补位；减动效直接移除。
        // 2026-10-28 Li 定：高度收到 0 允许改约束，算例外——能走 transform 的走 transform，高度必须收到 0 的例外。
        guard !UIAccessibility.isReduceMotionEnabled,
              let cardView = cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId })?.button,
              cardView.bounds.height > 0 else {
            removeDeletedDraftFromList(draftValue: draftValue)
            return
        }
        let heightConstraint = cardView.heightAnchor.constraint(equalToConstant: cardView.bounds.height)
        heightConstraint.isActive = true
        view.layoutIfNeeded()
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: .curveEaseIn, animations: {
            cardView.alpha = 0
            // 拖动进删的卡片带着左移 transform 进来，收起时一并滑回原位，
            // 免得它偏着收起。
            cardView.transform = .identity
            heightConstraint.constant = 0
            self.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let strongSelf = self else { return }
            // 收起期内已点撤销 → 该笔已恢复，不再移除。
            guard strongSelf.pendingUndos.contains(where: { $0.draft.draftId == draftValue.draftId }) else { return }
            strongSelf.removeDeletedDraftFromList(draftValue: draftValue)
        })
    }

    /// 删盘成功且收起完成（减动效直接）后的内存移除与撤销条：
    /// 从内存列表移除，空箱走全量渲染出空态，否则只摘被删卡片；
    /// 本笔计时未起时出条并起 6 秒计时。编辑器通知在 finishDelete
    /// 的删盘成功回调里发，不在这里（见该处注释）。
    private func removeDeletedDraftFromList(draftValue: BearyDraft) {
        guard pendingUndos.contains(where: { $0.draft.draftId == draftValue.draftId }) else { return }
        if let currentIndex = drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) {
            drafts.remove(at: currentIndex)
        }
        if drafts.isEmpty {
            // 删到空时无剩余卡片可保留，走原有全量渲染出空态。
            renderDrafts()
        } else {
            // 88 包 M16：只摘被删卡片与各处按钮登记，不重建剩余卡片。
            // （删卡自身已在 collapseDeletedCardAndRemove 里收起为 0 高，摘除无视觉跳变。）
            if let cardEntry = cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId }) {
                listStack.removeArrangedSubview(cardEntry.button)
                cardEntry.button.removeFromSuperview()
            }
            cardEntries.removeAll { $0.draftValue.draftId == draftValue.draftId }
            deleteEntries.removeAll(id: draftValue.draftId)
            lostEntries.removeAll(id: draftValue.draftId)
            setSubLabelCountText("共 \(drafts.count) 份 · 仅保存在本设备")
        }
        // 本笔在队列里且计时未起时出条并起 6 秒计时；其余笔的计时互不干扰。
        if let idx = pendingUndos.firstIndex(where: { $0.draft.draftId == draftValue.draftId }),
           pendingUndos[idx].timer == nil {
            refreshUndoBar()
            pendingUndos[idx].timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                self?.expireUndo(draftId: draftValue.draftId)
            }
        }
    }

    /// 6 秒撤销：把暂存草稿插回原位并写回 v3 多槽文件（仅恢复该篇，同 draftId 覆盖）。
    /// 审计 P1-8：撤销恢复最近一笔（LIFO）；余笔仍在队列里时条不消失，只改份数。
    @objc private func undoDeleteTapped() {
        guard let last = pendingUndos.last else {
            refreshUndoBar()
            return
        }
        last.timer?.invalidate()
        let queueIndex = pendingUndos.count - 1
        pendingUndos.removeLast()
        let draftValue = last.draft
        let insertIndex = min(last.index, drafts.count)
        // R21-A1：按草稿 ID 去重——B 的删盘未完成时它仍在列表里，
        // 此时点撤销不再把它插第二次（否则出现两张 B 卡片）。
        let alreadyInList = drafts.contains(where: { $0.draftId == draftValue.draftId })
        if !alreadyInList {
            drafts.insert(draftValue, at: insertIndex)
        }
        // E1-4：整库写回走后台队列，主线程只更新 UI。
        refreshUndoBar()
        // G5：恢复写盘带 Bool 回调；失败时从磁盘重读并 toast，不让内存态冒充已恢复。
        BearyDraftStore.saveAsyncReporting(draftValue) { [weak self] ok in
            guard let strongSelf = self else { return }
            if ok {
                strongSelf.insertRestoredCard(draftValue: draftValue)
                // 审计 P1-9：撤销写盘成功后才通知容器绑回（容器按 clearedCurrentDraftId 过滤）。
                strongSelf.onUndoCurrentDraft?(draftValue)
            } else {
                // R21-B1：写盘失败不再只 toast——先把未落盘的草稿从内存与
                // 列表里摘掉（不让内存态冒充已恢复），再把该笔恢复数据插回
                // 队列原位、重起 6 秒计时：撤销条本身就是重试入口，再点
                // “撤销”即重存；过期才真正丢弃（与正常撤销过期同口径）。
                strongSelf.removeUnpersistedRestoredCard(draftValue: draftValue)
                strongSelf.pendingUndos.insert(PendingUndo(draft: draftValue, index: insertIndex, timer: nil), at: min(queueIndex, strongSelf.pendingUndos.count))
                if let idx = strongSelf.pendingUndos.firstIndex(where: { $0.draft.draftId == draftValue.draftId }) {
                    strongSelf.refreshUndoBar()
                    strongSelf.pendingUndos[idx].timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                        self?.expireUndo(draftId: draftValue.draftId)
                    }
                }
                strongSelf.showDraftToast(message: "恢复失败，请重试")
            }
        }
    }

    /// R21-A10：撤销成功只插回被撤销的那一张，不重建全部卡片。
    /// 该卡已在列表里（删盘未完成时撤销又插回）只刷新计数，不重复建卡；
    /// 箱内无卡（空态／失败态）时走原有全量渲染（本来也只有这一张）。
    private func insertRestoredCard(draftValue: BearyDraft) {
        guard !draftsLoadFailed else {
            renderDrafts()
            return
        }
        if let existing = cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId }) {
            // 退场动画进行中点的撤销：卡片已收透明／收到 0 高，单插修不回来，
            // 走全量重建（仅此竞态分支）；其余情况只刷新计数，不重复建卡。
            if existing.button.alpha < 1 || existing.button.bounds.height == 0 {
                renderDrafts()
                return
            }
            subLabel.text = "共 \(drafts.count) 份 · 仅保存在本设备"
            return
        }
        guard !cardEntries.isEmpty else {
            renderDrafts()
            return
        }
        // makeCard 会把删除钮／丢失图钮登记进 deleteEntries／lostEntries（与 renderDrafts 同路）。
        let card = makeCard(for: draftValue)
        let restoredIndex = drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) ?? drafts.count
        // 按草稿在 drafts 里的先后排位，不依赖卡片数组与草稿数组下标对齐。
        let position = cardEntries.filter { entry in
            (drafts.firstIndex(where: { $0.draftId == entry.draftValue.draftId }) ?? Int.max) < restoredIndex
        }.count
        let clamped = min(position, cardEntries.count)
        // 审计第 7 轮第 3 项：插卡前采样当前可见卡片锚点——写盘是异步的，
        // 点撤销后、回调到达前用户可能已滚动；插入布局后按锚点恢复偏移，
        // 插在视口上方的卡片不再把正在看的内容推走。
        let anchor = firstVisibleCardAnchor()
        cardEntries.insert((button: card, draftValue: draftValue), at: clamped)
        listStack.insertArrangedSubview(card, at: min(clamped, listStack.arrangedSubviews.count))
        subWrap.isHidden = false
        hintWrap.isHidden = false
        subLabel.text = "共 \(drafts.count) 份 · 仅保存在本设备"
        restoreVisibleCardAnchor(anchor, restoredCard: card)
    }

    /// 插卡前采样首个可见卡片：draftId＋它相对可视区域顶部的距离。
    private func firstVisibleCardAnchor() -> (draftId: String, viewportOffset: CGFloat)? {
        let visibleRect = CGRect(origin: sheetScrollView.contentOffset, size: sheetScrollView.bounds.size)
        for entry in cardEntries {
            let frameInScroll = entry.button.convert(entry.button.bounds, to: sheetScrollView)
            if frameInScroll.intersects(visibleRect) {
                return (entry.draftValue.draftId, frameInScroll.minY - sheetScrollView.contentOffset.y)
            }
        }
        return nil
    }

    /// 按锚点卡片算布局落定后的滚动偏移（锚点卡片相对视口的位置不变）；
    /// 锚点卡片已不在列表时返回 nil。调用方须先让布局落定再调（动画块内
    /// 先 layoutIfNeeded 再读帧，或布局已完成后直接调）。
    private func anchorContentOffsetY(for anchor: (draftId: String, viewportOffset: CGFloat)?) -> CGFloat? {
        guard let anchor,
              let anchorEntry = cardEntries.first(where: { $0.draftValue.draftId == anchor.draftId }) else {
            return nil
        }
        let anchorFrame = anchorEntry.button.convert(anchorEntry.button.bounds, to: sheetScrollView)
        let targetY = anchorFrame.minY - anchor.viewportOffset
        let maxY = max(sheetScrollView.contentSize.height - sheetScrollView.bounds.height, 0)
        return min(max(targetY, 0), maxY)
    }

    /// 插入并布局后按锚点恢复偏移；恢复的卡片在视口内时，卡片淡入与列表
    /// 重排走同一 0.26s 过渡。用户正在拖动／减速时只直设偏移，不与手势抢动画。
    private func restoreVisibleCardAnchor(_ anchor: (draftId: String, viewportOffset: CGFloat)?, restoredCard: UIButton) {
        let animated = BearyMotion.animated(true) && !sheetScrollView.isDragging && !sheetScrollView.isDecelerating
        view.layoutIfNeeded()
        guard let clampedY = anchorContentOffsetY(for: anchor) else {
            return
        }
        // 布局已落定后再判恢复卡片是否在视口内（插卡前的帧还是 0，不可信）；
        // 在视口内时先置淡入初态，再与偏移恢复走同一动画。减动效时不碰 alpha。
        let restoredFrame = restoredCard.convert(restoredCard.bounds, to: sheetScrollView)
        let visibleRect = CGRect(origin: sheetScrollView.contentOffset, size: sheetScrollView.bounds.size)
        let restoredVisible = restoredFrame.intersects(visibleRect)
        if animated && restoredVisible {
            restoredCard.alpha = 0
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: .curveEaseOut, animations: {
                self.sheetScrollView.contentOffset = CGPoint(x: 0, y: clampedY)
                restoredCard.alpha = 1
            })
        } else {
            sheetScrollView.contentOffset = CGPoint(x: 0, y: clampedY)
        }
    }

    /// R21-B1：撤销写盘失败时把未落盘的草稿从内存与列表里摘掉（不让内存态冒充已恢复）；
    /// 删到空时走原有全量渲染出空态。其余卡片不动。
    private func removeUnpersistedRestoredCard(draftValue: BearyDraft) {
        if let idx = drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) {
            drafts.remove(at: idx)
        }
        if drafts.isEmpty || cardEntries.isEmpty {
            renderDrafts()
            return
        }
        if let cardEntry = cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId }) {
            listStack.removeArrangedSubview(cardEntry.button)
            cardEntry.button.removeFromSuperview()
        }
        cardEntries.removeAll { $0.draftValue.draftId == draftValue.draftId }
        deleteEntries.removeAll(id: draftValue.draftId)
        lostEntries.removeAll(id: draftValue.draftId)
        subLabel.text = "共 \(drafts.count) 份 · 仅保存在本设备"
    }

    /// 撤销条刷新：队列空→藏条；非空→显条并写份数（多笔时“N 份草稿已删除”），
    /// 条已在屏时只改文案不重播入场动效（已有元素不重播）。
    private func refreshUndoBar() {
        guard !pendingUndos.isEmpty else {
            hideUndoAnimated()
            return
        }
        if pendingUndos.count == 1, let only = pendingUndos.first {
            let short = summaryText(for: only.draft)
            // 撤销条文案走转换器：先全文渲染再取前 20 字，记号变单个附件格。
            let rendered = BearyText.inlineAttributedText(from: short, font: undoLabel.font, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: only.draft.images.compactMap { $0.serverKey })
            let result = NSMutableAttributedString(string: "已删除草稿“", attributes: [.font: undoLabel.font, .foregroundColor: BearyColors.ink])
            if rendered.string.count > 20 {
                let prefixLength = rendered.string.prefix(20).utf16.count
                result.append(rendered.attributedSubstring(from: NSRange(location: 0, length: prefixLength)))
                result.append(NSAttributedString(string: "…”", attributes: [.font: undoLabel.font, .foregroundColor: BearyColors.ink]))
            } else {
                result.append(rendered)
                result.append(NSAttributedString(string: "”", attributes: [.font: undoLabel.font, .foregroundColor: BearyColors.ink]))
            }
            undoLabel.attributedText = result
        } else {
            undoLabel.text = "\(pendingUndos.count) 份草稿已删除"
        }
        if undoWrap.isHidden {
            showUndoAnimated()
        }
    }

    /// 单笔撤销过期：只丢弃本笔（草稿文件在删除时已清），不重建列表、不动其余笔。
    private func expireUndo(draftId: String?) {
        guard let draftId = draftId,
              let idx = pendingUndos.firstIndex(where: { $0.draft.draftId == draftId }) else { return }
        pendingUndos[idx].timer?.invalidate()
        pendingUndos.remove(at: idx)
        refreshUndoBar()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .bearyUserDidChange, object: nil)
        for pending in pendingUndos { pending.timer?.invalidate() }
    }
}

// MARK: - 系统 sheet 关闭守卫（下滑／点遮罩）

/// 旧容器下把手下滑与遮罩点按走 closeBox → exitWithUndoGuard；系统 sheet 的
/// 下滑／点遮罩改由 presentationController delegate 守门（delegate 在
/// viewDidAppear 里挂上，见上）。有待撤销笔时先弹确认并拦下（return false），
/// 确认才放行（undoExitConfirmed 置位后第二次 shouldDismiss 不再拦截）；
/// 取消则箱子原样留着，撤销队列不动。确认框已在 shouldDismiss 里弹出，
/// didAttemptToDismiss 不再重复弹。文案与新建／点开路的确认框共用同一组 catalog key。
extension BearyDraftBoxViewController: UIAdaptivePresentationControllerDelegate {

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        if !pendingUndos.isEmpty && !undoExitConfirmed {
            presentUndoExitConfirm()
            return false
        }
        return true
    }

    private func presentUndoExitConfirm() {
        // 确认框已在途时不再叠弹（用户连点遮罩／重复下滑时，第二次
        // shouldDismiss 仍回 false，箱子不动，等用户在确认框里决定）。
        if presentedViewController != nil { return }
        // 确认钮与说明走 catalog（与 exitWithUndoGuard 共用同一组 key，
        // 中文原文即旧硬编码文案原样，英文为本批草稿译法、非 Li 定版）。
        BearyConfirmSheet.show(from: self, title: "", message: NSLocalizedString("draftbox.undo_exit_message", comment: ""), actions: [
            BearyConfirmSheet.Action(title: NSLocalizedString("draftbox.undo_exit_confirm", comment: ""), style: .destructive) { [weak self] in
                self?.undoExitConfirmed = true
                self?.dismissWithExitAnimation(completion: nil)
            },
        ])
    }
}

// MARK: - 虚线边框按钮（网页 .df-new 的 1.5px dashed 边框）

// 弹窗审计 E1-10：虚线钮走 BearyHit44Button（只扩触摸帧，视觉帧不动；
// 本钮另有最小 44 高约束，帧本身已达 44，扩热区为兜底）。
private final class BearyDraftBoxDashedButton: BearyHit44Button {

    private let dashedLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 撤回批（2026-10-27）：虚线钮去玻璃留虚线——玻璃 subview 会拦截触摸致死钮，删掉，
        // 只留 dashedLayer 描边（原 75 包形态）。
        // 描边走 gray：钮底是 surface3，line（浅 #DBDBDB）与 surface3（浅 #F5F5F5）
        // 对比约 1.27:1、浅色下几不可见（#1286 档距拉大后；深色差约 34 阶）。
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.strokeColor = BearyColors.gray.cgColor
        dashedLayer.lineWidth = 1.5
        dashedLayer.lineDashPattern = [6, 4]
        layer.addSublayer(dashedLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedLayer.frame = bounds
        // 描边以 path 为中心：path 贴 bounds 边时，外侧一半落在 layer 背板外被裁掉，
        // 顶边只剩一半粗（像素实测约 0.75pt）、底边却近全粗（约 1.5pt），上下不一。
        // path 内缩半个线宽，整条描边落进 layer 内，四边同粗；外沿仍贴 bounds、
        // 圆角同步减半个线宽（12 - 0.75 = 11.25），外形不动。
        // 线宽 1.5、pattern [6, 4]、颜色、圆角外形均不动。
        let halfLine = dashedLayer.lineWidth / 2
        dashedLayer.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: halfLine, dy: halfLine),
            cornerRadius: BearyCorners.single - halfLine
        ).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CAShapeLayer 描边色只在赋值时解析一次，深浅切换时重赋（编辑器同款虚线钮已有此处理）。
        // 与初建同口径：钮底 surface3 上 line 几不可见，描边走 gray（见上）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            dashedLayer.strokeColor = BearyColors.gray.cgColor
        }
    }
}
