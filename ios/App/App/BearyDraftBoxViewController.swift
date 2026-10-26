import UIKit

// ===== 草稿箱弹层（网页草稿箱移植；对应审计 G1）=====
// 网页对照：~/workspace/teddy_site/beary.html 内 #draftModal。
// 形态：overFullScreen 自包含呈现；遮罩为选人 sheet 同款 0.45 scrim、点遮罩关闭
// （backdrop 点击走 closeDraftBox，行为不变）；
// iPhone 为底部 sheet、最大高度 82vh；iPad（宽 ≥821）为居中 440 宽卡片。
// 数据只读草稿 v3（BearyDraftFiles.swift）：v3 存储是多槽数组文件 beary_draft_v3.json，
// 本弹层按 updatedAt 倒序列出全部草稿；旧 v2 单槽由存储层首次读取时迁入 v3，
// 本文件不做迁移、不改存储结构本身。
// 卡片操作：整卡点按打开（onOpen）；卡片顶行另有打开钮与删除钮（网页 .df-open/.df-trash
// 同款）；删除为本地操作：只删该篇（图片文件不动，6 秒撤销期内可原样恢复），
// 删后出 6 秒撤销条，超时丢弃暂存；不碰服务端。
// 调用约定：点“新建日记”只回调 onNew，点卡片/打开钮只回调 onOpen 并传出该篇草稿，
// 弹层本身不 dismiss——由编辑器代理在打开编辑器时负责 dismiss，避免呈现链冲突；
// 只有关闭钮与遮罩点击会直接 dismiss，且不删任何草稿。
// 约束：颜色只用 BearyColors（遮罩透明用 .clear）；不新增液态玻璃效果；
// 动画遵守 reduced-motion；部署目标 iOS 15.0、Swift 5.0——只用闭包回调，
// 不用 async/await，不用 if-let 简写。

final class BearyDraftBoxViewController: UIViewController {

    // MARK: - 对外 API（编辑器代理按此调用，勿改名）

    init(onNew: @escaping () -> Void, onOpen: @escaping (BearyDraft) -> Void) {
        self.onNewHandler = onNew
        self.onOpenHandler = onOpen
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = boxTransitionDelegate
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 状态

    private let onNewHandler: () -> Void
    private let onOpenHandler: (BearyDraft) -> Void
    private let boxTransitionDelegate = BearyDraftBoxTransitionDelegate()
    private var drafts: [BearyDraft] = []
    private var cardEntries: [(button: UIButton, draftValue: BearyDraft)] = []
    /// 新规矩 (b)：草稿列表入场动效只播一次（首渲），后续重渲不重播已有卡片。
    private var draftCardsAnimatedOnce = false
    private var openEntries: [(button: UIButton, draftValue: BearyDraft)] = []
    private var deleteEntries: [(button: UIButton, draftValue: BearyDraft)] = []
    private var lostEntries: [(button: UIButton, draftValue: BearyDraft)] = []
    /// DF-1/DF-2：编辑器当前正在写的那篇 draftId（由容器/编辑器在呈现草稿箱后设置；
    /// 未设置时“正在写”标记不显示、删正在写回调不触发）。容器接线由总协调收尾。
    var currentDraftId: String?
    /// DF-2：箱内删掉正在写的那篇时通知编辑器（编辑器侧清 draftId、换新 req，
    /// 即网页 deleteDraft 里 edDraftId=null 的等价动作）。容器接线由总协调收尾。
    var onDeleteCurrentDraft: ((String) -> Void)?
    private var pendingDeletedDraft: BearyDraft?
    private var pendingDeletedIndex: Int = 0
    private var undoTimer: Timer?
    private var didPlayEntrance = false
    private var isDismissing = false
    private var isPadLayout = false
    private var bottomSpacerHeight: NSLayoutConstraint?
    /// G5：草稿库读取失败标记（loadAllResult 失败时置位，渲染时出失败态，不出空态）。
    private var draftsLoadFailed = false
    /// G7：箱内轻提示的当前 toast 视图（新 toast 先清旧 toast）。
    private var draftToastView: UIView?
    /// U18：把手外包容器（原 buildViews 内局部变量），下滑关闭手势挂在这里。
    private let handleWrapView = UIView()

    // MARK: - 视图

    private let backdropButton = UIButton(type: .custom)
    private let sheetView = UIView()
    /// 玻璃批：sheet 玻璃背板（钉在 sheetView 内部，只裁玻璃自身，不裁 sheetView 阴影）。
    private let sheetGlassView = BearyGlass.effectView(tint: BearyGlass.neutralTint)
    private let sheetScrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let topBorderView = UIView()
    private let handleView = UIView()
    private let headerWrap = UIView()
    private let titleLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .custom)
    private let subWrap = UIView()
    private let subLabel = UILabel()
    private let newButton = BearyDraftBoxDashedButton(type: .custom)
    private let undoWrap = UIView()
    private let undoBar = UIView()
    private let undoLabel = UILabel()
    private let undoButton = UIButton(type: .custom)
    private let listWrap = UIView()
    private let listStack = UIStackView()
    private let hintWrap = UIView()
    private let hintLabel = UILabel()
    private let bottomSpacer = UIView()

    private var sheetHeightConstraint: NSLayoutConstraint?
    private var sheetWidthConstraint: NSLayoutConstraint?
    private var phoneConstraints: [NSLayoutConstraint] = []
    private var padConstraints: [NSLayoutConstraint] = []

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.clear
        buildViews()
        buildConstraints()
        loadDrafts { [weak self] in
            self?.renderDrafts()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !didPlayEntrance && !UIAccessibility.isReduceMotionEnabled {
            applyEntranceStartState()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if didPlayEntrance || UIAccessibility.isReduceMotionEnabled {
            return
        }
        didPlayEntrance = true
        view.layoutIfNeeded()
        applyEntranceStartState()
        // M20：开箱卡片错峰滑入（仅首次开箱；卡片先置初态，sheet 到位后再逐张播）。
        let cardViews = listStack.arrangedSubviews
        for cardView in cardViews {
            cardView.alpha = 0
            cardView.transform = CGAffineTransform(translationX: 0, y: 8)
        }
        let duration = isPadLayout ? 0.25 : 0.32
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
            self.sheetView.transform = .identity
            self.sheetView.alpha = 1
        }, completion: { _ in
            var delay: TimeInterval = 0
            for cardView in cardViews {
                UIView.animate(withDuration: 0.25, delay: delay, options: .curveEaseOut, animations: {
                    cardView.alpha = 1
                    cardView.transform = .identity
                })
                delay += 0.04
            }
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutModeIfNeeded()
        updateSheetHeight()
        updateBottomSpacer()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷 sheet 边框与卡片/打开钮描边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applySheetChrome()
            for entry in cardEntries {
                entry.button.layer.borderColor = BearyColors.line.cgColor
            }
            for entry in openEntries {
                entry.button.layer.borderColor = BearyColors.line.cgColor
            }
        }
    }

    // MARK: - 视图搭建

    private func buildViews() {
        // 草稿箱遮罩与网页端一致：全透明（网页 #draftModal .backdrop 即透明，P2-7 scrim 已按网页对齐回滚）。
        backdropButton.backgroundColor = .clear
        backdropButton.accessibilityLabel = "关闭"
        backdropButton.addTarget(self, action: #selector(closeBox), for: .touchUpInside)
        backdropButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropButton)

        sheetView.backgroundColor = .clear
        sheetView.layer.cornerRadius = 20
        sheetView.layer.shadowColor = UIColor.black.cgColor
        // 玻璃批：玻璃只钉在 sheetView 内部（index 0，在 topBorder/scrollView 之下），
        // 玻璃自身圆角 20 + clipsToBounds；sheetView 本身不裁剪，阴影保留。
        sheetGlassView.layer.cornerRadius = 20
        sheetGlassView.clipsToBounds = true
        sheetGlassView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.insertSubview(sheetGlassView, at: 0)
        NSLayoutConstraint.activate([
            sheetGlassView.topAnchor.constraint(equalTo: sheetView.topAnchor),
            sheetGlassView.bottomAnchor.constraint(equalTo: sheetView.bottomAnchor),
            sheetGlassView.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            sheetGlassView.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
        ])
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)

        topBorderView.backgroundColor = BearyColors.line
        topBorderView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(topBorderView)

        sheetScrollView.showsVerticalScrollIndicator = false
        sheetScrollView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(sheetScrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        sheetScrollView.addSubview(contentStack)

        handleView.backgroundColor = BearyColors.line
        handleView.layer.cornerRadius = 2
        handleView.translatesAutoresizingMaskIntoConstraints = false
        handleWrapView.translatesAutoresizingMaskIntoConstraints = false
        handleWrapView.addSubview(handleView)
        NSLayoutConstraint.activate([
            handleView.widthAnchor.constraint(equalToConstant: 40),
            handleView.heightAnchor.constraint(equalToConstant: 4),
            handleView.centerXAnchor.constraint(equalTo: handleWrapView.centerXAnchor),
            handleView.topAnchor.constraint(equalTo: handleWrapView.topAnchor, constant: 10),
            handleView.bottomAnchor.constraint(equalTo: handleWrapView.bottomAnchor),
        ])
        // U18：把手加下滑关闭手势（与 closeBox 同动画）；遮罩点按关闭保留。
        handleWrapView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:))))
        contentStack.addArrangedSubview(handleWrapView)

        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "草稿箱"
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.addSubview(titleLabel)
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "关闭"
        if let closeImage = BearyIconImages.image(named: "icon_close", pointSize: 15) {
            closeButton.setImage(closeImage, for: .normal)
        } else {
            // I15：icon_close 资产随包发布（Assets.xcassets/icon_close.imageset），
            // 正常路径恒取到图；此文字分支仅作资产缺失时的兜底，保留以保证关闭入口永在。
            closeButton.setTitle("✕", for: .normal)
            closeButton.setTitleColor(BearyColors.ink, for: .normal)
            closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        }
        closeButton.addTarget(self, action: #selector(closeBox), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.addSubview(closeButton)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: headerWrap.centerXAnchor),
            // 头高内容驱动：标题 15/700 + 上 6 + 下 4，约 29（原固定 42）。
            titleLabel.topAnchor.constraint(equalTo: headerWrap.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(equalTo: headerWrap.bottomAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            closeButton.trailingAnchor.constraint(equalTo: headerWrap.trailingAnchor, constant: -14),
            closeButton.topAnchor.constraint(equalTo: headerWrap.topAnchor, constant: 2),
        ])
        contentStack.addArrangedSubview(headerWrap)

        subLabel.font = UIFont.systemFont(ofSize: 12.5)
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
        newButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.5)
        newButton.tintColor = BearyColors.gray
        if let editImage = BearyIconImages.image(named: "icon_edit", pointSize: 15) {
            newButton.setImage(editImage, for: .normal)
        }
        newButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        newButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        newButton.addTarget(self, action: #selector(newDraftTapped), for: .touchUpInside)
        // M19：新建钮加与卡片一致的按压底色反馈。
        newButton.addTarget(self, action: #selector(newButtonTouchDown(_:)), for: .touchDown)
        newButton.addTarget(self, action: #selector(newButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let newWrap = wrapWithBottomPadding(newButton, bottom: 12, horizontal: 16)
        contentStack.addArrangedSubview(newWrap)

        // 删除撤销条：删卡后出现，6 秒内点“撤销”恢复该篇，超时自动消失。
        undoWrap.isHidden = true
        undoWrap.translatesAutoresizingMaskIntoConstraints = false
        undoBar.backgroundColor = BearyColors.faint
        undoBar.layer.cornerRadius = 12
        undoBar.layer.masksToBounds = true
        undoBar.translatesAutoresizingMaskIntoConstraints = false
        undoLabel.text = "草稿已删除"
        undoLabel.font = UIFont.systemFont(ofSize: 13.5)
        undoLabel.textColor = BearyColors.ink
        undoLabel.translatesAutoresizingMaskIntoConstraints = false
        undoButton.setTitle("撤销", for: .normal)
        undoButton.setTitleColor(BearyColors.blue, for: .normal)
        undoButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.addTarget(self, action: #selector(undoDeleteTapped), for: .touchUpInside)
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
            backdropButton.topAnchor.constraint(equalTo: view.topAnchor),
            backdropButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        sheetScrollView.layer.cornerRadius = 20
        sheetScrollView.layer.masksToBounds = true
        NSLayoutConstraint.activate([
            topBorderView.topAnchor.constraint(equalTo: sheetView.topAnchor),
            topBorderView.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            topBorderView.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            topBorderView.heightAnchor.constraint(equalToConstant: 1),
            sheetScrollView.topAnchor.constraint(equalTo: sheetView.topAnchor),
            sheetScrollView.bottomAnchor.constraint(equalTo: sheetView.bottomAnchor),
            sheetScrollView.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            sheetScrollView.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: sheetScrollView.contentLayoutGuide.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: sheetScrollView.frameLayoutGuide.widthAnchor),
        ])

        let heightConstraint = sheetView.heightAnchor.constraint(equalToConstant: 320)
        heightConstraint.isActive = true
        sheetHeightConstraint = heightConstraint

        let widthConstraint = sheetView.widthAnchor.constraint(equalToConstant: 440)
        sheetWidthConstraint = widthConstraint

        phoneConstraints = [
            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        padConstraints = [
            sheetView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sheetView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            widthConstraint,
        ]
        NSLayoutConstraint.activate(phoneConstraints)
        applySheetChrome()
    }

    // MARK: - 布局模式与尺寸

    private func updateLayoutModeIfNeeded() {
        let pad = view.bounds.width >= 821
        if pad == isPadLayout {
            return
        }
        isPadLayout = pad
        if pad {
            NSLayoutConstraint.deactivate(phoneConstraints)
            NSLayoutConstraint.activate(padConstraints)
        } else {
            NSLayoutConstraint.deactivate(padConstraints)
            NSLayoutConstraint.activate(phoneConstraints)
        }
        applySheetChrome()
    }

    private func applySheetChrome() {
        if isPadLayout {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            sheetView.layer.borderWidth = 1
            sheetView.layer.borderColor = BearyColors.line.cgColor
            sheetView.layer.shadowOpacity = 0.30
            // CALayer radius 取 CSS blur 一半（居中卡片与 SceneDelegate 底 sheet 同口径）：
            // 网页 60 → 30、32 → 16，旧值 60/32 直写会把阴影晕得比网页大一倍。
            sheetView.layer.shadowRadius = 30
            sheetView.layer.shadowOffset = CGSize(width: 0, height: 24)
            topBorderView.isHidden = true
            sheetScrollView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheetView.layer.borderWidth = 0
            sheetView.layer.shadowOpacity = 0.22
            sheetView.layer.shadowRadius = 16
            sheetView.layer.shadowOffset = CGSize(width: 0, height: -12)
            topBorderView.isHidden = false
            sheetScrollView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        // 玻璃批：玻璃圆角裁剪跟随 sheet（手机仅顶圆角 / iPad 四圆角），仍只裁玻璃。
        sheetGlassView.layer.maskedCorners = sheetView.layer.maskedCorners
    }

    private func updateSheetHeight() {
        let maxHeight = view.bounds.height * 0.82
        guard maxHeight > 0 else { return }
        let sheetWidth = isPadLayout ? min(440, view.bounds.width - 80) : view.bounds.width
        if let widthConstraint = sheetWidthConstraint, isPadLayout {
            widthConstraint.constant = max(sheetWidth, 0)
        }
        let fittingHeight = contentStack.systemLayoutSizeFitting(
            CGSize(width: sheetWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard fittingHeight > 100 else { return }
        let target = min(fittingHeight, maxHeight)
        if let heightConstraint = sheetHeightConstraint, abs(heightConstraint.constant - target) > 0.5 {
            heightConstraint.constant = target
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
    private func loadDrafts(completion: (() -> Void)? = nil) {
        BearyDraftStore.ioQueue.async { [weak self] in
            let result = BearyDraftStore.loadAllResult()
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                switch result {
                case .success(let loaded):
                    strongSelf.drafts = loaded
                    strongSelf.draftsLoadFailed = false
                case .failure:
                    strongSelf.drafts = []
                    strongSelf.draftsLoadFailed = true
                }
                completion?()
            }
        }
    }

    private func renderDrafts() {
        for arranged in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        cardEntries = []
        openEntries = []
        deleteEntries = []
        lostEntries = []
        if draftsLoadFailed {
            subLabel.text = nil
            subWrap.isHidden = true
            hintWrap.isHidden = true
            let failedLabel = UILabel()
            failedLabel.text = "草稿读取失败\n原文件已保留，请稍后再试"
            failedLabel.font = UIFont.systemFont(ofSize: 13)
            failedLabel.textColor = BearyColors.gray
            failedLabel.textAlignment = .center
            failedLabel.numberOfLines = 0
            if let attributed = attributedText(failedLabel.text, lineHeightMultiple: 1.7, font: failedLabel.font) {
                failedLabel.attributedText = attributed
            }
            let failedWrap = UIView()
            failedWrap.translatesAutoresizingMaskIntoConstraints = false
            failedWrap.addSubview(failedLabel)
            failedLabel.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                failedLabel.topAnchor.constraint(equalTo: failedWrap.topAnchor, constant: 30),
                failedLabel.bottomAnchor.constraint(equalTo: failedWrap.bottomAnchor, constant: -22),
                failedLabel.leadingAnchor.constraint(equalTo: failedWrap.leadingAnchor, constant: 20),
                failedLabel.trailingAnchor.constraint(equalTo: failedWrap.trailingAnchor, constant: -20),
            ])
            listStack.addArrangedSubview(failedWrap)
            return
        }
        if drafts.isEmpty {
            subLabel.text = nil
            subWrap.isHidden = true
            hintWrap.isHidden = true
            let emptyLabel = UILabel()
            emptyLabel.text = "还没有草稿\n写下的内容会自动存在这里"
            emptyLabel.font = UIFont.systemFont(ofSize: 13)
            emptyLabel.textColor = BearyColors.gray
            emptyLabel.textAlignment = .center
            emptyLabel.numberOfLines = 0
            if let attributed = attributedText(emptyLabel.text, lineHeightMultiple: 1.7, font: emptyLabel.font) {
                emptyLabel.attributedText = attributed
            }
            let emptyWrap = UIView()
            emptyWrap.translatesAutoresizingMaskIntoConstraints = false
            emptyWrap.addSubview(emptyLabel)
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                emptyLabel.topAnchor.constraint(equalTo: emptyWrap.topAnchor, constant: 30),
                emptyLabel.bottomAnchor.constraint(equalTo: emptyWrap.bottomAnchor, constant: -22),
                emptyLabel.leadingAnchor.constraint(equalTo: emptyWrap.leadingAnchor, constant: 20),
                emptyLabel.trailingAnchor.constraint(equalTo: emptyWrap.trailingAnchor, constant: -20),
            ])
            listStack.addArrangedSubview(emptyWrap)
        } else {
            subWrap.isHidden = false
            // Q10：App 草稿只存本机，副文案改“仅保存在本设备”
            //（原网页口径“仅保存在当前浏览器”不适用于 App 本机存储）。
            subLabel.text = "共 \(drafts.count) 份 · 写的时候自动保存 · 仅保存在本设备"
            hintWrap.isHidden = false
            for draftValue in drafts {
                let card = makeCard(for: draftValue)
                cardEntries.append((button: card, draftValue: draftValue))
                listStack.addArrangedSubview(card)
            }
            // 新规矩 (b)：草稿列表首次渲染错峰淡入一次（后续删除/回页重渲不重播，
            // 已有卡片不动；减动效直显）。
            if !draftCardsAnimatedOnce && !UIAccessibility.isReduceMotionEnabled {
                draftCardsAnimatedOnce = true
                var delay: TimeInterval = 0
                for entry in cardEntries {
                    let card = entry.button
                    card.alpha = 0
                    card.transform = CGAffineTransform(translationX: 0, y: 8)
                    UIView.animate(withDuration: 0.25, delay: delay, options: .curveEaseOut, animations: {
                        card.alpha = 1
                        card.transform = .identity
                    })
                    delay += 0.03
                }
            }
        }
    }

    private func makeCard(for draftValue: BearyDraft) -> UIButton {
        let card = UIButton(type: .custom)
        card.backgroundColor = UIColor.clear
        card.layer.borderWidth = 1
        card.layer.borderColor = BearyColors.line.cgColor
        card.layer.cornerRadius = 14
        card.accessibilityLabel = "打开这份草稿"
        card.addTarget(self, action: #selector(cardTouchDown(_:)), for: .touchDown)
        card.addTarget(self, action: #selector(cardTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        card.addTarget(self, action: #selector(cardTapped(_:)), for: .touchUpInside)

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
        timeLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = BearyColors.blue
        topRow.addArrangedSubview(timeLabel)
        let spacer = UIView()
        topRow.addArrangedSubview(spacer)
        if !draftValue.images.isEmpty {
            let imageRow = UIStackView()
            imageRow.axis = .horizontal
            imageRow.spacing = 4
            imageRow.alignment = .center
            if let photoImage = BearyIconImages.image(named: "icon_image", pointSize: 15) {
                let photoView = UIImageView(image: photoImage)
                photoView.tintColor = BearyColors.gray
                photoView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    photoView.widthAnchor.constraint(equalToConstant: 15),
                    photoView.heightAnchor.constraint(equalToConstant: 15),
                ])
                imageRow.addArrangedSubview(photoView)
            }
            let countLabel = UILabel()
            countLabel.text = "\(draftValue.images.count)"
            countLabel.font = UIFont.systemFont(ofSize: 12)
            countLabel.textColor = BearyColors.gray
            imageRow.addArrangedSubview(countLabel)
            topRow.addArrangedSubview(imageRow)
        }
        // 卡片操作钮（网页 .df-open/.df-trash 同款）：打开钮整卡点按等价，删除钮本地删卡。
        let openButton = UIButton(type: .custom)
        openButton.setTitle("打开", for: .normal)
        openButton.setTitleColor(BearyColors.ink, for: .normal)
        openButton.titleLabel?.font = UIFont.systemFont(ofSize: 12.5)
        openButton.layer.borderWidth = 1.5
        openButton.layer.borderColor = BearyColors.line.cgColor
        openButton.layer.cornerRadius = 999
        openButton.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        openButton.accessibilityLabel = "打开这份草稿"
        openButton.addTarget(self, action: #selector(openTapped(_:)), for: .touchUpInside)
        topRow.addArrangedSubview(openButton)
        openEntries.append((button: openButton, draftValue: draftValue))
        let deleteButton = UIButton(type: .custom)
        if let trashImage = BearyIconImages.image(named: "icon_trash", pointSize: 17) {
            deleteButton.setImage(trashImage, for: .normal)
        }
        deleteButton.imageView?.contentMode = .scaleAspectFit
        deleteButton.tintColor = BearyColors.red
        deleteButton.accessibilityLabel = "删除草稿"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        // U19：删除钮触摸区域扩到 44×44（图标本身仍是 17pt，视觉不变）。
        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        deleteButton.addTarget(self, action: #selector(deleteTapped(_:)), for: .touchUpInside)
        topRow.addArrangedSubview(deleteButton)
        deleteEntries.append((button: deleteButton, draftValue: draftValue))
        inner.addArrangedSubview(topRow)

        let summaryLabel = UILabel()
        summaryLabel.font = UIFont.systemFont(ofSize: 16)
        summaryLabel.textColor = BearyColors.ink
        summaryLabel.numberOfLines = 2
        summaryLabel.textAlignment = .left
        let summary = summaryText(for: draftValue)
        if let attributed = attributedText(summary, lineHeightMultiple: 1.65, font: summaryLabel.font) {
            summaryLabel.attributedText = attributed
        } else {
            summaryLabel.text = summary
        }
        inner.addArrangedSubview(summaryLabel)

        let metaRow = UIStackView()
        metaRow.axis = .horizontal
        metaRow.spacing = 8
        metaRow.alignment = .center
        let wordLabel = UILabel()
        wordLabel.text = "\(draftValue.content.count) 字"
        wordLabel.font = UIFont.systemFont(ofSize: 12)
        wordLabel.textColor = BearyColors.gray
        wordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metaRow.addArrangedSubview(wordLabel)
        // DF-1 写给 chip（@ 图标 + 名，网页 buildDraftCard 的 d.to chip 口径）。
        if let recipientName = draftValue.recipientName, !recipientName.isEmpty {
            metaRow.addArrangedSubview(recipientChip(name: recipientName))
        }
        // DF-1 心情 chip 带 emote 图（网页 df-chip 内 emote 图 + 心情名）。
        if let moodKey = draftValue.mood, let moodName = BearyText.moodNames[moodKey] {
            metaRow.addArrangedSubview(moodChip(key: moodKey, name: moodName))
        }
        // DF-1 图片未保存可点清除 chip：只针对已无物可续传的失败图
        // （本地文件与服务端 key 皆无，网页 imgs_lost 的等价情形）；点一下清掉
        // 这些图项与提示，可续传的失败图仍走原有“文字已保存，图片未保存”状态行。
        if hasUnrecoverableImage(for: draftValue) {
            let lostButton = UIButton(type: .custom)
            lostButton.setTitle("图片未保存", for: .normal)
            // D-G13：网页 .df-chip.df-lost 为 faint 底 + 灰字 + 500 字重；
            // 原 App 红底红字 semibold 改齐。
            lostButton.setTitleColor(BearyColors.gray, for: .normal)
            lostButton.titleLabel?.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
            lostButton.backgroundColor = BearyColors.faint
            lostButton.layer.cornerRadius = 999
            lostButton.layer.masksToBounds = true
            lostButton.contentEdgeInsets = UIEdgeInsets(top: 2.5, left: 9, bottom: 2.5, right: 9)
            lostButton.accessibilityLabel = "图片未保存，点一下清除这条提示"
            lostButton.addTarget(self, action: #selector(clearLostTapped(_:)), for: .touchUpInside)
            metaRow.addArrangedSubview(lostButton)
            lostEntries.append((button: lostButton, draftValue: draftValue))
        }
        // DF-1 正在写标记：编辑器当前正在写的那篇（currentDraftId 由容器设置）。
        if let current = currentDraftId, current == draftValue.draftId {
            let writingLabel = UILabel()
            writingLabel.text = "正在写"
            writingLabel.font = UIFont.systemFont(ofSize: 12)
            writingLabel.textColor = BearyColors.gray
            metaRow.addArrangedSubview(writingLabel)
        }
        let status = saveStatus(for: draftValue)
        let statusLabel = UILabel()
        // L7：状态文案必保全，不被长 chip 挤走。
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
        switch status {
        case .saved:
            statusLabel.text = "草稿已保存"
            statusLabel.textColor = BearyColors.blue
        case .partial:
            statusLabel.text = "文字已保存，图片未保存"
            statusLabel.textColor = BearyColors.blue
        case .failed:
            statusLabel.text = "草稿保存失败"
            statusLabel.textColor = BearyColors.red
        }
        metaRow.addArrangedSubview(statusLabel)
        let metaSpacer = UIView()
        metaRow.addArrangedSubview(metaSpacer)
        // 状态行与字数/心情行之间留 8pt（与内层 spacing 的 6pt 叠加后接近网页 meta 的 8pt 上边距）。
        let metaWrap = UIView()
        metaWrap.translatesAutoresizingMaskIntoConstraints = false
        metaWrap.addSubview(metaRow)
        metaRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            metaRow.topAnchor.constraint(equalTo: metaWrap.topAnchor, constant: 2),
            metaRow.bottomAnchor.constraint(equalTo: metaWrap.bottomAnchor),
            metaRow.leadingAnchor.constraint(equalTo: metaWrap.leadingAnchor),
            metaRow.trailingAnchor.constraint(equalTo: metaWrap.trailingAnchor),
        ])
        inner.addArrangedSubview(metaWrap)
        return card
    }

    private func chipShell() -> UIView {
        let chip = UIView()
        chip.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.13)
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
        label.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
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
        let label = UILabel()
        label.text = "写给 \(name)"
        label.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = BearyColors.ink
        // L7：与心情 chip 同口径——省略号 + 低压缩 + chip 最大宽。
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

    private func hasUnrecoverableImage(for draftValue: BearyDraft) -> Bool {
        for item in draftValue.images {
            if item.state == .failed && item.localFile == nil && item.serverKey == nil {
                return true
            }
        }
        return false
    }

    /// 图片未保存 chip 点按：清掉已无物可续传的失败图项并后台写盘、重渲卡片
    /// （网页点 imgs_lost chip 清标记 + 重渲的等价动作；可续传图项不受影响）。
    @objc private func clearLostTapped(_ sender: UIButton) {
        var targetDraft: BearyDraft?
        for entry in lostEntries {
            if entry.button === sender {
                targetDraft = entry.draftValue
            }
        }
        guard var draftValue = targetDraft else { return }
        draftValue.images = draftValue.images.filter { item in
            return !(item.state == .failed && item.localFile == nil && item.serverKey == nil)
        }
        for offset in 0..<drafts.count {
            if drafts[offset].draftId == draftValue.draftId {
                drafts[offset] = draftValue
            }
        }
        // G5：改用带 Bool 回调的写盘；失败时从磁盘重读恢复内存态并 toast，
        // 不让“已清除”的 UI 盖住实际仍在的磁盘内容。
        BearyDraftStore.saveAsyncReporting(draftValue) { [weak self] ok in
            guard let strongSelf = self else { return }
            if ok {
                strongSelf.renderDrafts()
            } else {
                strongSelf.loadDrafts {
                    strongSelf.renderDrafts()
                    strongSelf.showDraftToast(message: "保存失败，图片提示还在")
                }
            }
        }
    }

    // MARK: - 文案推导（网页口径移植）

    /// DF-1 摘要兜底顺序改网页口径（buildDraftCard）：
    /// 正文 > 只有图片 > 只有引用 > 只有心情 > 有天气/写给则“（还没写字）” > “（空白草稿）”。
    private func summaryText(for draftValue: BearyDraft) -> String {
        let trimmed = draftValue.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if !draftValue.images.isEmpty {
            return "（只有图片）"
        }
        if draftValue.quoteId != nil {
            return "（只有引用）"
        }
        if let moodKey = draftValue.mood, BearyText.moodNames[moodKey] != nil {
            return "（只有心情）"
        }
        // G19：recipientName 口径收紧为非空（空字符串不再触发“还没写字”兜底，
        // 与存储层 hasContent 的 recipientName 非空判定一致）。
        if draftValue.weather != nil || draftValue.recipientId != nil || !(draftValue.recipientName ?? "").isEmpty {
            return "（还没写字）"
        }
        return "（空白草稿）"
    }

    private enum DraftSaveStatus {
        case saved
        case partial
        case failed
    }

    /// v3 没有显式的保存失败标记，状态由图片项推导：
    /// 失败且本地文件与服务端 key 皆无（无物可续传）→ 失败红字；
    /// 其余失败项（本地文件尚在、可续传）→ 文字已保存、图片未保存；
    /// 无失败项 → 草稿已保存。
    private func saveStatus(for draftValue: BearyDraft) -> DraftSaveStatus {
        var hasFailedImage = false
        var hasUnrecoverableImage = false
        for item in draftValue.images {
            if item.state == .failed {
                hasFailedImage = true
                if item.localFile == nil && item.serverKey == nil {
                    hasUnrecoverableImage = true
                }
            }
        }
        if hasUnrecoverableImage {
            return .failed
        }
        if hasFailedImage {
            return .partial
        }
        return .saved
    }

    /// 网页 dfTimeStr 移植：v3 updatedAt 为秒，网页 updated_at 为毫秒，此处按秒换算。
    private func draftTimeText(updatedAtSeconds: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: updatedAtSeconds)
        let now = Date()
        let diff = now.timeIntervalSince(date)
        if diff < 3600 {
            let minutes = max(1, Int(floor(diff / 60)))
            return "\(minutes) 分钟前"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let hours = Int(floor(diff / 3600))
            return "\(hours) 小时前"
        }
        let beijingZone = TimeZone(secondsFromGMT: 8 * 3600)
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        // G8（草稿箱部分）：时间显示 formatter 统一设北京时区，与服务端日界一致。
        timeFormatter.timeZone = beijingZone
        // W9：原生定版统一补零（HH:mm），不再以网页昨天 H:mm 口径为准。
        timeFormatter.dateFormat = "HH:mm"
        if calendar.isDateInYesterday(date) {
            return "昨天 " + timeFormatter.string(from: date)
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "zh_CN")
        dayFormatter.timeZone = beijingZone
        dayFormatter.dateFormat = "M月d日"
        return dayFormatter.string(from: date)
    }

    private func attributedText(_ text: String?, lineHeightMultiple: CGFloat, font: UIFont?) -> NSAttributedString? {
        guard let text = text, let font = font else { return nil }
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: style,
        ])
    }

    // MARK: - 入场/退场动效

    private func applyEntranceStartState() {
        if isPadLayout {
            sheetView.alpha = 0
            sheetView.transform = CGAffineTransform(translationX: 0, y: sheetView.bounds.height * 0.04)
        } else {
            sheetView.alpha = 1
            sheetView.transform = CGAffineTransform(translationX: 0, y: sheetView.bounds.height)
        }
    }

    @objc private func closeBox() {
        guard !isDismissing else { return }
        isDismissing = true
        if UIAccessibility.isReduceMotionEnabled {
            dismiss(animated: false, completion: nil)
            return
        }
        let duration = isPadLayout ? 0.25 : 0.32
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn, animations: {
            if self.isPadLayout {
                self.sheetView.alpha = 0
                self.sheetView.transform = CGAffineTransform(translationX: 0, y: self.sheetView.bounds.height * 0.04)
            } else {
                self.sheetView.transform = CGAffineTransform(translationX: 0, y: self.sheetView.bounds.height)
            }
        }, completion: { _ in
            self.dismiss(animated: false, completion: nil)
        })
    }

    @objc private func newDraftTapped() {
        onNewHandler()
    }

    // M19：新建钮按压底色（与卡片 cardTouchDown/cardTouchUp 同口径）。
    @objc private func newButtonTouchDown(_ sender: UIButton) {
        sender.backgroundColor = BearyColors.faint
    }

    @objc private func newButtonTouchUp(_ sender: UIButton) {
        sender.backgroundColor = UIColor.clear
    }

    /// U18：把手下滑关闭——下滑跟手，超过 80pt 或快速下滑时走 closeBox 同动画；
    /// 否则弹回原位。遮罩点按关闭不受影响。
    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard !isDismissing else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            let offset = max(0, translation.y)
            // 把手在内容顶端：下滑时把滚动锁回顶部，避免与滚动回弹打架。
            if translation.y > 0 {
                sheetScrollView.contentOffset = .zero
            }
            sheetView.transform = CGAffineTransform(translationX: 0, y: offset)
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 80 || velocity > 600 {
                closeBox()
            } else {
                UIView.animate(withDuration: 0.25, animations: {
                    self.sheetView.transform = .identity
                })
            }
        case .cancelled, .failed:
            UIView.animate(withDuration: 0.25, animations: {
                self.sheetView.transform = .identity
            })
        default:
            break
        }
    }

    /// G7：箱内轻提示（墨底白字 toast，2 秒后淡出；减动效直接显隐）。
    private func showDraftToast(message: String) {
        draftToastView?.removeFromSuperview()
        draftToastView = nil
        let toastView = UIView()
        toastView.backgroundColor = BearyColors.ink
        toastView.layer.cornerRadius = 12
        toastView.clipsToBounds = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = BearyColors.bg
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -16),
        ])
        view.addSubview(toastView)
        NSLayoutConstraint.activate([
            toastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            toastView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -158),
        ])
        draftToastView = toastView
        if UIAccessibility.isReduceMotionEnabled {
            toastView.alpha = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.draftToastView === toastView {
                    toastView.removeFromSuperview()
                    self?.draftToastView = nil
                }
            }
        } else {
            toastView.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                toastView.alpha = 1
            }, completion: { _ in
                UIView.animate(withDuration: 0.25, delay: 2, options: [], animations: {
                    toastView.alpha = 0
                }, completion: { _ in
                    if self.draftToastView === toastView {
                        toastView.removeFromSuperview()
                        self.draftToastView = nil
                    }
                })
            })
        }
    }

    /// M20：撤销条淡入/滑入（减动效直接显示）。
    private func showUndoAnimated() {
        undoWrap.alpha = 1
        undoWrap.transform = .identity
        undoWrap.isHidden = false
        if UIAccessibility.isReduceMotionEnabled {
            return
        }
        undoWrap.alpha = 0
        undoWrap.transform = CGAffineTransform(translationX: 0, y: 8)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut, animations: {
            self.undoWrap.alpha = 1
            self.undoWrap.transform = .identity
        })
    }

    @objc private func cardTouchDown(_ sender: UIButton) {
        sender.backgroundColor = BearyColors.faint
    }

    @objc private func cardTouchUp(_ sender: UIButton) {
        sender.backgroundColor = UIColor.clear
    }

    @objc private func cardTapped(_ sender: UIButton) {
        for entry in cardEntries {
            if entry.button === sender {
                onOpenHandler(entry.draftValue)
                return
            }
        }
    }

    @objc private func openTapped(_ sender: UIButton) {
        for entry in openEntries {
            if entry.button === sender {
                onOpenHandler(entry.draftValue)
                return
            }
        }
    }

    /// 本地删卡：从列表移除并只删该篇 v3 草稿；图片文件不动（撤销期内可原样恢复，
    /// 超时后由编辑器侧的孤文件清理承接，不在此处改存储结构）。
    @objc private func deleteTapped(_ sender: UIButton) {
        var targetDraft: BearyDraft?
        for entry in deleteEntries {
            if entry.button === sender {
                targetDraft = entry.draftValue
            }
        }
        guard let draftValue = targetDraft else { return }
        // G17：按 draftId 查找下标，不再依赖删除钮数组与草稿数组的下标对齐。
        guard let draftIndex = drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) else { return }
        // 若上一笔删除仍在撤销期内，先使其过期（不再可恢复），再暂存新的一笔。
        expirePendingUndo()
        pendingDeletedDraft = draftValue
        pendingDeletedIndex = draftIndex
        // M3：删卡先高度收起动画再移除，其余卡在栈内原地补位；减动效直接移除。
        guard !UIAccessibility.isReduceMotionEnabled,
              let cardView = cardEntries.first(where: { $0.draftValue.draftId == draftValue.draftId })?.button,
              cardView.bounds.height > 0 else {
            finishDelete(draftValue: draftValue)
            return
        }
        cardView.isUserInteractionEnabled = false
        let heightConstraint = cardView.heightAnchor.constraint(equalToConstant: cardView.bounds.height)
        heightConstraint.isActive = true
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn, animations: {
            cardView.alpha = 0
            heightConstraint.constant = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.finishDelete(draftValue: draftValue)
        })
    }

    /// 删除收尾：删前再按 draftId 校验一次（动画期内下标可能已变），
    /// 后台删盘；只有删盘成功才从内存列表移除并出撤销条，失败时卡片
    /// 原地恢复（仍在原位置）+ toast，不让它静默消失。
    /// G7：删盘走带 Bool 回传的 deleteAsyncReporting（老 deleteAsync
    /// 保留给编辑器两处调用作兼容）；成功路径的 collapse 退场（deleteTapped）
    /// 与撤销条行为不变，只是移除/出条改到删盘成功回调里（本地写盘，
    /// 延迟毫秒级，视觉上与原来无差）。
    private func finishDelete(draftValue: BearyDraft) {
        // 失败恢复用：记下当前下标；删盘失败且内存里已没它时按此插回原位。
        let restoreIndex = drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) ?? pendingDeletedIndex
        BearyDraftStore.deleteAsyncReporting(draftId: draftValue.draftId) { [weak self] ok in
            guard let strongSelf = self else { return }
            if !ok {
                // 失败：本笔仍是待撤销的那笔时清掉暂存（撤销条尚未出，
                // 此处只清暂存与计时器，不动后一笔的暂存）。
                if strongSelf.pendingDeletedDraft?.draftId == draftValue.draftId {
                    strongSelf.expirePendingUndo()
                }
                if strongSelf.drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) == nil {
                    strongSelf.drafts.insert(draftValue, at: min(restoreIndex, strongSelf.drafts.count))
                }
                strongSelf.renderDrafts()
                strongSelf.showDraftToast(message: "删除失败，请再试一次")
                return
            }
            if let currentIndex = strongSelf.drafts.firstIndex(where: { $0.draftId == draftValue.draftId }) {
                strongSelf.drafts.remove(at: currentIndex)
                // DF-2：删的是编辑器正在写的那篇时通知编辑器（容器接线后编辑器清 draftId）。
                // 注意：6 秒内点撤销会把草稿插回箱里，但编辑器侧已清的槽位不会自动接回，
                // 容器需决定撤销后是否重新打开该篇（见交回说明）。
                if let current = strongSelf.currentDraftId, current == draftValue.draftId {
                    strongSelf.onDeleteCurrentDraft?(draftValue.draftId)
                }
            }
            strongSelf.renderDrafts()
            // 只有本笔仍是待撤销的那笔时才出撤销条 + 计时；已被后一笔删除
            // 顶掉时，后一笔自己的回调会出它的撤销条，这里只静默移除。
            if strongSelf.pendingDeletedDraft?.draftId == draftValue.draftId {
                strongSelf.showUndoAnimated()
                strongSelf.undoTimer?.invalidate()
                strongSelf.undoTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                    self?.expirePendingUndo()
                }
            }
        }
    }

    /// 6 秒撤销：把暂存草稿插回原位并写回 v3 多槽文件（仅恢复该篇，同 draftId 覆盖）。
    @objc private func undoDeleteTapped() {
        guard let draftValue = pendingDeletedDraft else {
            expirePendingUndo()
            return
        }
        undoTimer?.invalidate()
        undoTimer = nil
        pendingDeletedDraft = nil
        let insertIndex = min(pendingDeletedIndex, drafts.count)
        drafts.insert(draftValue, at: insertIndex)
        // E1-4：整库写回走后台队列，主线程只更新 UI。
        undoWrap.isHidden = true
        undoWrap.alpha = 1
        undoWrap.transform = .identity
        // G5：恢复写盘带 Bool 回调；失败时从磁盘重读并 toast，不让内存态冒充已恢复。
        BearyDraftStore.saveAsyncReporting(draftValue) { [weak self] ok in
            guard let strongSelf = self else { return }
            if ok {
                strongSelf.renderDrafts()
            } else {
                strongSelf.loadDrafts {
                    strongSelf.renderDrafts()
                    strongSelf.showDraftToast(message: "恢复失败，请再试一次")
                }
            }
        }
    }

    /// 撤销过期：只丢弃暂存（草稿文件在删除时已清），不重建列表。
    private func expirePendingUndo() {
        undoTimer?.invalidate()
        undoTimer = nil
        pendingDeletedDraft = nil
        undoWrap.isHidden = true
        undoWrap.alpha = 1
        undoWrap.transform = .identity
    }

    deinit {
        undoTimer?.invalidate()
    }
}

// MARK: - 自包含呈现：瞬时转场 + sheet 自身动效

/// 呈现/关闭本身不播系统动画，sheet 的滑入/淡入/滑出由本控制器在
/// viewWillAppear/viewDidAppear/closeBox 里做（与网页 .32s/.25s 同口径），
/// 调用方无论 present(animated:) 传 true 还是 false，效果一致。
private final class BearyDraftBoxTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyDraftBoxInstantAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyDraftBoxInstantAnimator(isPresenting: false)
    }
}

private final class BearyDraftBoxInstantAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        if isPresenting {
            if let toView = transitionContext.view(forKey: .to) {
                container.addSubview(toView)
            }
        } else {
            if let fromView = transitionContext.view(forKey: .from) {
                fromView.removeFromSuperview()
            }
        }
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
}

// MARK: - 虚线边框按钮（网页 .df-new 的 1.5px dashed 边框）

private final class BearyDraftBoxDashedButton: UIButton {

    private let dashedLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 撤回批（2026-10-27）：虚线钮去玻璃留虚线——玻璃 subview 会拦截触摸致死钮，删掉，
        // 只留 dashedLayer 描边（原 75 包形态）。
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.strokeColor = BearyColors.line.cgColor
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
        dashedLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CAShapeLayer 描边色只在赋值时解析一次，深浅切换时重赋（编辑器同款虚线钮已有此处理）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            dashedLayer.strokeColor = BearyColors.line.cgColor
        }
    }
}
