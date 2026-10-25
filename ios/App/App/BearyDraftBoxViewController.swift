import UIKit

// ===== 草稿箱弹层（网页草稿箱移植；对应审计 G1）=====
// 网页对照：~/workspace/teddy_site/beary.html 内 #draftModal。
// 形态：overFullScreen 自包含呈现；遮罩透明且点遮罩关闭（网页 #draftModal .backdrop
// 为 transparent、backdrop 点击走 closeDraftBox，与通用 0.45 黑遮罩不同，审计 S3）；
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

    // MARK: - 视图

    private let backdropButton = UIButton(type: .custom)
    private let sheetView = UIView()
    private let sheetScrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let topBorderView = UIView()
    private let handleView = UIView()
    private let headerWrap = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .custom)
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
        loadDrafts()
        renderDrafts()
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
        let duration = isPadLayout ? 0.25 : 0.32
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
            self.sheetView.transform = .identity
            self.sheetView.alpha = 1
        }, completion: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutModeIfNeeded()
        updateSheetHeight()
        updateBottomSpacer()
    }

    // MARK: - 视图搭建

    private func buildViews() {
        backdropButton.backgroundColor = UIColor.clear
        backdropButton.accessibilityLabel = "关闭"
        backdropButton.addTarget(self, action: #selector(closeBox), for: .touchUpInside)
        backdropButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropButton)

        sheetView.backgroundColor = BearyColors.bg
        sheetView.layer.cornerRadius = 20
        sheetView.layer.shadowColor = UIColor.black.cgColor
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
        let handleWrap = UIView()
        handleWrap.translatesAutoresizingMaskIntoConstraints = false
        handleWrap.addSubview(handleView)
        NSLayoutConstraint.activate([
            handleView.widthAnchor.constraint(equalToConstant: 40),
            handleView.heightAnchor.constraint(equalToConstant: 4),
            handleView.centerXAnchor.constraint(equalTo: handleWrap.centerXAnchor),
            handleView.topAnchor.constraint(equalTo: handleWrap.topAnchor, constant: 10),
            handleView.bottomAnchor.constraint(equalTo: handleWrap.bottomAnchor),
        ])
        contentStack.addArrangedSubview(handleWrap)

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
            sheetView.layer.shadowRadius = 60
            sheetView.layer.shadowOffset = CGSize(width: 0, height: 24)
            topBorderView.isHidden = true
            sheetScrollView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheetView.layer.borderWidth = 0
            sheetView.layer.shadowOpacity = 0.22
            sheetView.layer.shadowRadius = 32
            sheetView.layer.shadowOffset = CGSize(width: 0, height: -12)
            topBorderView.isHidden = false
            sheetScrollView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
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

    private func loadDrafts() {
        drafts = BearyDraftStore.loadAll()
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
            subLabel.text = "共 \(drafts.count) 份 · 写的时候自动保存 · 仅保存在本机"
            hintWrap.isHidden = false
            for draftValue in drafts {
                let card = makeCard(for: draftValue)
                cardEntries.append((button: card, draftValue: draftValue))
                listStack.addArrangedSubview(card)
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
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.spacing = 8
        topRow.alignment = .center
        let timeLabel = UILabel()
        timeLabel.text = draftTimeText(updatedAtSeconds: draftValue.updatedAt)
        timeLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
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
        deleteButton.tintColor = BearyColors.red
        deleteButton.accessibilityLabel = "删除草稿"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 28),
            deleteButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        deleteButton.addTarget(self, action: #selector(deleteTapped(_:)), for: .touchUpInside)
        topRow.addArrangedSubview(deleteButton)
        deleteEntries.append((button: deleteButton, draftValue: draftValue))
        inner.addArrangedSubview(topRow)

        let summaryLabel = UILabel()
        summaryLabel.font = UIFont.systemFont(ofSize: 15.5)
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
            lostButton.setTitleColor(BearyColors.red, for: .normal)
            lostButton.titleLabel?.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
            lostButton.backgroundColor = BearyColors.red.withAlphaComponent(0.13)
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
        chip.backgroundColor = BearyColors.orange.withAlphaComponent(0.13)
        chip.layer.cornerRadius = 999
        chip.layer.masksToBounds = true
        return chip
    }

    private func moodChip(key: String, name: String) -> UIView {
        let chip = chipShell()
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        let isDark = traitCollection.userInterfaceStyle == .dark
        if let emoteImage = BearyEmoteImages.image(for: key, dark: isDark) {
            let imageView = UIImageView(image: emoteImage)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFit
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
            ])
            row.addArrangedSubview(imageView)
        }
        let label = UILabel()
        label.text = name
        label.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = BearyColors.ink
        row.addArrangedSubview(label)
        chip.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2.5),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2.5),
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
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
        if let atImage = BearyIconImages.image(named: "icon_at", pointSize: 14) {
            let imageView = UIImageView(image: atImage)
            imageView.tintColor = BearyColors.ink
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 14),
                imageView.heightAnchor.constraint(equalToConstant: 14),
            ])
            row.addArrangedSubview(imageView)
        }
        let label = UILabel()
        label.text = "写给 \(name)"
        label.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = BearyColors.ink
        row.addArrangedSubview(label)
        chip.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: chip.topAnchor, constant: 2.5),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -2.5),
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
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
        BearyDraftStore.saveAsync(draftValue)
        renderDrafts()
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
        if draftValue.weather != nil || draftValue.recipientId != nil || draftValue.recipientName != nil {
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
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"
        if calendar.isDateInYesterday(date) {
            return "昨天 " + timeFormatter.string(from: date)
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "zh_CN")
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
        var targetIndex: Int?
        var targetDraft: BearyDraft?
        for offset in 0..<deleteEntries.count {
            if deleteEntries[offset].button === sender {
                targetIndex = offset
                targetDraft = deleteEntries[offset].draftValue
            }
        }
        guard let foundIndex = targetIndex, let draftValue = targetDraft, foundIndex < drafts.count else { return }
        // 若上一笔删除仍在撤销期内，先使其过期（不再可恢复），再暂存新的一笔。
        expirePendingUndo()
        pendingDeletedDraft = draftValue
        pendingDeletedIndex = foundIndex
        drafts.remove(at: foundIndex)
        // E1-4：整库删写走后台队列，主线程只更新 UI。
        BearyDraftStore.deleteAsync(draftId: draftValue.draftId)
        // DF-2：删的是编辑器正在写的那篇时通知编辑器（容器接线后编辑器清 draftId）。
        // 注意：6 秒内点撤销会把草稿插回箱里，但编辑器侧已清的槽位不会自动接回，
        // 容器需决定撤销后是否重新打开该篇（见交回说明）。
        if let current = currentDraftId, current == draftValue.draftId {
            onDeleteCurrentDraft?(draftValue.draftId)
        }
        renderDrafts()
        undoWrap.isHidden = false
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.expirePendingUndo()
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
        BearyDraftStore.saveAsync(draftValue)
        undoWrap.isHidden = true
        renderDrafts()
    }

    /// 撤销过期：只丢弃暂存（草稿文件在删除时已清），不重建列表。
    private func expirePendingUndo() {
        undoTimer?.invalidate()
        undoTimer = nil
        pendingDeletedDraft = nil
        undoWrap.isHidden = true
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
}
