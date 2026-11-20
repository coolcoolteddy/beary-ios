import UIKit

// MARK: - 通知相关 UI 组件（独立通知页已删，数据层见 BearyNotificationsData.swift）
//
// 本文件只剩：信件整页 BearyLetterViewController、头像组 BearyAvatarStackView、
// 通知行 BearyNotificationCell、哨兵行 BearyNotificationTrailingCell、
// 合并详情页 BearyNotificationDetailViewController。
// MARK: - 系统通知／信件整页阅读（2026-11-19 Li 定：居中弹窗改整页读）
//
// 顶栏只有左上角返回（标题在内容区衬线大标题）；正文整页可上下滑到底；
// 无“知道了”按钮。打开走正常推入（SceneDelegate.presentLetterPage：
// 全屏 nav＋EdgeDismiss），不用展开过渡／morph 动画。
// 内容口径与旧 BearyLetterModal 一致：图标（徽章信礼花／信封动画／
// 其余静态图标）＋标题＋来源·时间＋正文（1.9 行高、心情渲染）＋
// 可选引用块（1.75 行高）＋有去向时“查看这篇日记”入口。
final class BearyLetterViewController: UIViewController {

    /// “查看这篇日记”点按：先关本页、再由调用方进日记详情（见 goTapped）。
    var onGoEntry: ((String) -> Void)?

    private let titleText: String
    private let bodyText: String
    private let iconName: String
    private let sourceText: String
    private let timeMs: Int?
    private let goEntryId: String?

    private let isPopper: Bool
    private let isMail: Bool

    private let topBar = UIView()
    private let backButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let popperView = BearyPopperView()
    private let mailView = BearyMailView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let bodyLabel = UILabel()
    private let quoteWrap = UIView()
    private let quoteBar = UIView()
    private let quoteTextLabel = UILabel()
    private let quoteMetaLabel = UILabel()
    private let goButton = UIButton(type: .system)

    /// 宽屏内容列 600 居中（反馈页同款：821 断点，≤820 全宽减 48）。
    private var contentWidthCap: NSLayoutConstraint?
    private var contentIsWide = false

    init(
        title: String,
        body: String,
        iconName: String,
        quoteText: String?,
        quoteMeta: String?,
        goEntryId: String?,
        sourceText: String,
        timeMs: Int?
    ) {
        self.titleText = title
        self.bodyText = body
        self.iconName = iconName
        self.sourceText = sourceText
        self.timeMs = timeMs
        self.goEntryId = goEntryId
        self.isPopper = (iconName == "icon_popper")
        self.isMail = (iconName == "icon_mail")
        super.init(nibName: nil, bundle: nil)
        if let quoteText = quoteText, let quoteMeta = quoteMeta {
            pendingQuote = (quoteText, quoteMeta)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// init 时带的引用（调用方传 nil 时无引用；随后补引用走 fillQuote）。
    private var pendingQuote: (text: String, meta: String)?

    /// 引用原文（深浅切换重建引用富文本用；无引用时 nil）。
    private var quotePlainText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        // 顶栏：详情页同款（44 高、左上角返回 44×44、标题在内容区、不重复）。
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = BearyColors.bg
        // 顶栏已是固定条、底 inset 手动补（viewDidLayoutSubviews），
        // 不自动叠加安全区内边距，免得手动值与系统值叠成双份（详情页同款）。
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 0
        scrollView.addSubview(contentStack)

        // 图标行：徽章信礼花 36、信封动画 54、其余静态图标 36，均居中。
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isHidden = isPopper || isMail
        if !isPopper && !isMail {
            iconView.image = BearyIconImages.image(named: iconName, pointSize: 36)
        }
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        popperView.translatesAutoresizingMaskIntoConstraints = false
        popperView.isHidden = !isPopper
        mailView.translatesAutoresizingMaskIntoConstraints = false
        mailView.envelopeColor = BearyColors.ink
        mailView.isHidden = !isMail
        iconContainer.addSubview(iconView)
        iconContainer.addSubview(popperView)
        iconContainer.addSubview(mailView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: Self.serifTitleFont())
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.text = titleText
        titleLabel.accessibilityTraits = .header

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = BearyColors.gray
        metaLabel.textAlignment = .center
        metaLabel.numberOfLines = 0
        metaLabel.text = metaText()

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = BearyColors.ink
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byCharWrapping

        quoteWrap.translatesAutoresizingMaskIntoConstraints = false
        quoteWrap.backgroundColor = BearyColors.surface2
        quoteWrap.layer.cornerRadius = 12
        quoteWrap.clipsToBounds = true
        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        quoteBar.backgroundColor = BearyColors.gray
        quoteTextLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteTextLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        quoteTextLabel.adjustsFontForContentSizeCategory = true
        quoteTextLabel.textColor = BearyColors.ink
        quoteTextLabel.numberOfLines = 0
        quoteTextLabel.lineBreakMode = .byCharWrapping
        quoteMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        quoteMetaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        quoteMetaLabel.adjustsFontForContentSizeCategory = true
        quoteMetaLabel.textColor = BearyColors.gray
        quoteMetaLabel.numberOfLines = 0
        quoteWrap.addSubview(quoteBar)
        quoteWrap.addSubview(quoteTextLabel)
        quoteWrap.addSubview(quoteMetaLabel)
        if let quote = pendingQuote {
            pendingQuote = nil
            quotePlainText = quote.text
            quoteTextLabel.attributedText = Self.moodLineHeightText(quote.text, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.75, dark: traitCollection.userInterfaceStyle == .dark)
            quoteMetaLabel.text = quote.meta
            quoteWrap.isHidden = false
        } else {
            quoteWrap.isHidden = true
        }

        goButton.translatesAutoresizingMaskIntoConstraints = false
        goButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        goButton.titleLabel?.adjustsFontForContentSizeCategory = true
        goButton.setTitleColor(BearyColors.ink, for: .normal)
        // 2026-11-14 Li 定：纯白／纯黑墨底太突兀，改 surface2 柔和灰底 + ink 字（旧模态“去看看”同款）。
        goButton.backgroundColor = BearyColors.surface2
        goButton.layer.cornerRadius = BearyCorners.single
        goButton.setTitle("查看这篇日记", for: .normal)
        goButton.isHidden = goEntryId == nil
        goButton.addTarget(self, action: #selector(goTapped), for: .touchUpInside)
        goButton.bearyAddPressFeedback()

        contentStack.addArrangedSubview(iconContainer)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(metaLabel)
        contentStack.addArrangedSubview(bodyLabel)
        contentStack.addArrangedSubview(quoteWrap)
        contentStack.addArrangedSubview(goButton)
        applyRowSpacing()
        rebuildAttributedTexts()

        let contentWidthEquality = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48)
        contentWidthEquality.priority = UILayoutPriority(750)
        contentWidthCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentWidthCap?.isActive = false
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -32),
            contentWidthEquality,
            iconContainer.heightAnchor.constraint(equalToConstant: 54),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            popperView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            popperView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            popperView.widthAnchor.constraint(equalToConstant: 36),
            popperView.heightAnchor.constraint(equalToConstant: 36),
            mailView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            mailView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            mailView.widthAnchor.constraint(equalToConstant: 54),
            mailView.heightAnchor.constraint(equalToConstant: 54),
            quoteBar.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: quoteWrap.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: quoteWrap.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),
            quoteTextLabel.topAnchor.constraint(equalTo: quoteWrap.topAnchor, constant: 12),
            quoteTextLabel.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor, constant: 14),
            quoteTextLabel.trailingAnchor.constraint(equalTo: quoteWrap.trailingAnchor, constant: -14),
            quoteMetaLabel.topAnchor.constraint(equalTo: quoteTextLabel.bottomAnchor, constant: 8),
            quoteMetaLabel.leadingAnchor.constraint(equalTo: quoteWrap.leadingAnchor, constant: 14),
            quoteMetaLabel.trailingAnchor.constraint(equalTo: quoteWrap.trailingAnchor, constant: -14),
            quoteMetaLabel.bottomAnchor.constraint(equalTo: quoteWrap.bottomAnchor, constant: -12),
            goButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 模态全屏无底栏：滚动区底只留安全区底＋16（详情页同款）。
        let bottom = 16 + view.safeAreaInsets.bottom
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
            scrollView.scrollIndicatorInsets.bottom = bottom
        }
        // 反馈页同款：821 断点——仅宽屏激活 600 上限；状态不变不开关，避免布局循环。
        let wide = BearyDesktop.isWide(view.bounds.width)
        if wide != contentIsWide {
            contentIsWide = wide
            contentWidthCap?.isActive = wide
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isPopper {
            popperView.start()
        }
        if isMail {
            mailView.start()
        }
        // VoiceOver：进页即聚焦标题（旧模态同款）。
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 富文本字号／颜色在构建时解析一次：深浅切换或字号档变化时重建才跟上。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            rebuildAttributedTexts()
        }
    }

    /// 行间距：隐藏行不占位，间距随引用／去向行的显隐走对应值。
    private func applyRowSpacing() {
        contentStack.setCustomSpacing(16, after: iconContainer)
        contentStack.setCustomSpacing(8, after: titleLabel)
        contentStack.setCustomSpacing(20, after: metaLabel)
        if !quoteWrap.isHidden {
            contentStack.setCustomSpacing(18, after: bodyLabel)
            contentStack.setCustomSpacing(24, after: quoteWrap)
        } else {
            contentStack.setCustomSpacing(24, after: bodyLabel)
        }
    }

    /// 来源 · 时间（与列表行同口径：相对时间；无时间只显来源）。
    private func metaText() -> String {
        let time = BearyVisibilityText.publishedRelativeString(publishedAtMs: timeMs)
            ?? (timeMs.map { BearyText.timeString(ms: $0) } ?? "")
        return time.isEmpty ? sourceText : "\(sourceText) · \(time)"
    }

    /// 衬线大标题（预览定版样式；withDesign(.serif)，中文回退字体待真机验，
    /// 与其余衬线标题同口径，见规范表 §11）。
    private static func serifTitleFont() -> UIFont {
        let base = UIFont.boldSystemFont(ofSize: 22)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: 22)
        }
        return base
    }

    /// 正文／引用富文本重建（深浅切换与字号档变化时调用）。
    private func rebuildAttributedTexts() {
        let dark = traitCollection.userInterfaceStyle == .dark
        bodyLabel.attributedText = Self.moodLineHeightText(bodyText, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.9, dark: dark)
        if let quoteText = quotePlainText, !quoteWrap.isHidden {
            quoteTextLabel.attributedText = Self.moodLineHeightText(quoteText, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.75, dark: dark)
        }
    }

    /// 行高富文本（旧模态同款：正文 1.9、引用 1.75）。
    private static func lineHeightText(_ string: String, font: UIFont, color: UIColor, multiple: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// 信件正文／引用走心情渲染：服务端 body 可能内嵌日记正文切片
    /// （如转回私密通知），含 [mood:] 记号原文；与卡片同款渲染（旧模态同款）。
    private static func moodLineHeightText(_ string: String, font: UIFont, color: UIColor, multiple: CGFloat, dark: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = .byCharWrapping
        return BearyText.inlineAttributedText(from: BearyText.stripTrailingPartialInlineToken(string), font: font, color: color, paragraphStyle: paragraph, dark: dark, gifImageKeys: nil)
    }

    /// 引用预览随后补全（旧模态 fillQuote 同款：引用区随正文一起进滚动区）。
    func fillQuote(text: String, meta: String) {
        let isNewQuote = quoteWrap.isHidden
        quotePlainText = text
        quoteTextLabel.attributedText = Self.moodLineHeightText(text, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)), color: BearyColors.ink, multiple: 1.75, dark: traitCollection.userInterfaceStyle == .dark)
        quoteMetaLabel.text = meta
        quoteWrap.isHidden = false
        applyRowSpacing()
        // 审计 C-20 同款：新增引用区播 0.18s 透明度过渡；已有正文不重播入场动画。
        // 减动效时直接显现，不播过渡。
        guard isNewQuote, !UIAccessibility.isReduceMotionEnabled else {
            quoteWrap.alpha = 1
            return
        }
        quoteWrap.alpha = 0
        view.layoutIfNeeded()
        UIView.animate(withDuration: BearyMotion.micro) {
            self.quoteWrap.alpha = 1
        }
    }

    @objc private func backTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    @objc private func goTapped() {
        // 旧模态“去看看”同款：先关本页、再进日记详情。
        dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            if let entryId = self?.goEntryId {
                self?.onGoEntry?(entryId)
            }
        }
    }
}


// MARK: - 通知行 cell（网页 .nt-item 口径）

/// 聚合行左侧可展开头像组（2026-11-18 Li 定）：圆形头像向右重叠排列，
/// 每个压住前一个的三分之一（42pt 圆、间距 28）；最多 4 个圆，超 4 人时
/// 前 3 个为头像、第 4 个圆显示“+数字”（数字＝剩余人数）；点按后头像
/// 依次向右散开成一排（间距 50，每个间隔 40ms），下方淡入 11pt 灰名字；
/// 再点一次从右往左依次收回。减动效直接落终值。
/// 圆带 2pt 页面底色描边分隔（bearyDynamicBorderColor，深浅切换自动重刷）；
/// 头像加载走 BearyImageLoader（42×scale 下采样），失败留首字母占位、
/// 无重试钮；复用/重配时取消在途加载、复位收起态。点按用透明 UIButton
/// 覆盖栈区（UIControl 点按不触发 didSelectRowAt，回关钮同款原理）。
final class BearyAvatarStackView: UIView {

    static let avatarDiameter: CGFloat = 42
    static let collapsedPitch: CGFloat = 28
    static let expandedPitch: CGFloat = 50
    /// 名字行高：11pt 名字缩放后的实际行高，向上取整防截断；大字号下随字体
    /// 长大，不再固定 14（审计第 10 项：固定 14 在大字号下会纵向截断名字）。
    static var nameHeight: CGFloat {
        ceil(BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11)).lineHeight)
    }
    /// 展开高：头像 42 ＋ 4 间隙 ＋ 名字实际行高。
    static var expandedHeight: CGFloat {
        avatarDiameter + 4 + nameHeight
    }

    static func collapsedWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return avatarDiameter + CGFloat(count - 1) * collapsedPitch
    }

    static func expandedWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return avatarDiameter + CGFloat(count - 1) * expandedPitch
    }

    private struct Circle {
        let container: UIView
        let nameLabel: UILabel
        var task: URLSessionDataTask?
    }

    private var circles: [Circle] = []
    private var onToggle: (() -> Void)?
    private var loadGeneration = 0
    private(set) var isExpanded = false
    private(set) var circleCount = 0

    private lazy var tapButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .clear
        button.isAccessibilityElement = true
        button.addTarget(self, action: #selector(stackTapped), for: .touchUpInside)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(tapButton)
        NSLayoutConstraint.activate([
            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// actors：按时间倒序（最新在前）；overflowCount > 0 时末圆为“+N”不配名字。
    func configure(actors: [(name: String, avatarURL: URL?)], overflowCount: Int, expanded: Bool, onToggle: @escaping () -> Void) {
        reset()
        self.onToggle = onToggle
        self.isExpanded = expanded
        for actor in actors {
            circles.append(makeAvatarCircle(name: actor.name, avatarURL: actor.avatarURL))
        }
        if overflowCount > 0 {
            circles.append(makeOverflowCircle(count: overflowCount))
        }
        circleCount = circles.count
        tapButton.accessibilityLabel = expanded ? "收起头像" : "展开头像"
        bringSubviewToFront(tapButton)
        layoutCircles(animated: false)
    }

    /// 复用/重配：取消在途头像加载（回调凭代次作废）、拆掉旧圆、复位收起态。
    func reset() {
        for circle in circles {
            circle.task?.cancel()
            circle.container.removeFromSuperview()
            circle.nameLabel.removeFromSuperview()
        }
        circles.removeAll()
        loadGeneration += 1
        onToggle = nil
        isExpanded = false
        circleCount = 0
    }

    /// 点按切换：改圆圈位置＋名字淡入淡出；栈宽/高约束由 cell 同步改，
    /// 行高生长由 VC 的 begin/endUpdates 驱动。
    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        tapButton.accessibilityLabel = expanded ? "收起头像" : "展开头像"
        layoutCircles(animated: animated)
    }

    @objc private func stackTapped() {
        onToggle?()
    }

    private func makeCircleContainer() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.line
        container.layer.cornerRadius = Self.avatarDiameter / 2
        container.layer.borderWidth = 2
        container.layer.bearyDynamicBorderColor = BearyColors.bg
        container.clipsToBounds = true
        return container
    }

    private func makeNameLabel(text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.text = text
        label.alpha = 0
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeAvatarCircle(name: String, avatarURL: URL?) -> Circle {
        let container = makeCircleContainer()
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // 首字母占位与单头像同款（15/700 灰）；无图直接露占位，不走加载。
        let displayName = name.isEmpty ? "beary 用户" : name
        let fallbackLabel = UILabel()
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        fallbackLabel.textColor = BearyColors.gray
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackLabel.textAlignment = .center
        fallbackLabel.text = String(displayName.prefix(1)).uppercased()
        container.addSubview(fallbackLabel)
        NSLayoutConstraint.activate([
            fallbackLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            fallbackLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let nameLabel = makeNameLabel(text: displayName)
        addSubview(container)
        addSubview(nameLabel)
        var circle = Circle(container: container, nameLabel: nameLabel, task: nil)
        if let url = avatarURL {
            let generation = loadGeneration
            circle.task = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: Self.avatarDiameter * UIScreen.main.scale) { [weak self, weak imageView, weak fallbackLabel] result in
                guard let strongSelf = self, generation == strongSelf.loadGeneration else { return }
                guard let imageView = imageView, let fallbackLabel = fallbackLabel else { return }
                switch result {
                case .success(let image):
                    imageView.image = image
                    fallbackLabel.isHidden = true
                case .failure:
                    // 失败留首字母占位、无重试钮。
                    imageView.image = nil
                    fallbackLabel.isHidden = false
                }
            }
        }
        return circle
    }

    private func makeOverflowCircle(count: Int) -> Circle {
        let container = makeCircleContainer()
        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        countLabel.textColor = BearyColors.ink
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textAlignment = .center
        countLabel.text = "+\(count)"
        container.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        // +N 圆无名字：名字位留空 label（alpha 恒 0），布局与头像圆一致。
        let nameLabel = makeNameLabel(text: "")
        addSubview(container)
        addSubview(nameLabel)
        return Circle(container: container, nameLabel: nameLabel, task: nil)
    }

    private func circleCenterX(at index: Int, expanded: Bool) -> CGFloat {
        let pitch = expanded ? Self.expandedPitch : Self.collapsedPitch
        return Self.avatarDiameter / 2 + CGFloat(index) * pitch
    }

    private func layoutCircles(animated: Bool) {
        let animate = animated && BearyMotion.animated(true)
        for (index, circle) in circles.enumerated() {
            let centerX = circleCenterX(at: index, expanded: isExpanded)
            let containerFrame = CGRect(x: centerX - Self.avatarDiameter / 2, y: 0, width: Self.avatarDiameter, height: Self.avatarDiameter)
            // 名字宽 50 居中于圆心，超长截断；头像下方 4pt 间隙，高取缩放后实际行高。
            let nameFrame = CGRect(x: centerX - 25, y: Self.avatarDiameter + 4, width: 50, height: Self.nameHeight)
            let apply = {
                circle.container.frame = containerFrame
                circle.nameLabel.frame = nameFrame
                circle.nameLabel.alpha = self.isExpanded ? 1 : 0
            }
            if animate {
                // 散开从左往右、收回从右往左：收回时倒序延时。
                let staggerIndex = isExpanded ? index : (circles.count - 1 - index)
                UIView.animate(withDuration: BearyMotion.normal, delay: TimeInterval(staggerIndex) * 0.04, options: [.curveEaseInOut], animations: apply, completion: nil)
            } else {
                apply()
            }
        }
    }
}

class BearyNotificationCell: UITableViewCell {

    private var avatarTask: URLSessionDataTask?
    private var avatarLoadGeneration = 0
    private var avatarRetryURL: URL?
    private var avatarRetryActorName = ""

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 21
        return imageView
    }()

    private let avatarFallbackLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        return label
    }()

    private let avatarIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    /// 第 17 项 B：行内 popper 动态画（网页 NB.popper 口径，见 BearyPopperView）。
    /// 仅系统行“成就/徽章”标题时用；其余行仍走 avatarIconView 静态资产。
    private let popperView: BearyPopperView = {
        let view = BearyPopperView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    /// 头像加载失败重试：纯图标按钮（非文字按钮），44×44 点击区居中压在头像上；
    /// 仅失败态可见，加载中与成功态一律隐藏（见 loadAvatar）。无描边、无背景色，
    /// 故深浅切换无需重刷；图标本身走 BearyIconImages 本地资产，不会再加载失败。
    private let avatarRetryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 24), for: .normal)
        button.tintColor = BearyColors.ink
        button.isHidden = true
        button.accessibilityLabel = "重试"
        button.accessibilityHint = "重新加载头像"
        button.addTarget(self, action: #selector(avatarRetryTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    /// 好友第一期（关注/回关模型）：关注提醒卡行内动作区（单个墨色主按钮，回关／关注；
    /// 没有同意/拒绝两个按钮）。按钮是 UIControl，点按不触发行的 didSelectRowAt
    ///（默认点按行为是标已读 + 进对方主页，按钮区与之互斥）；已互关时按钮换成
    /// “已互关”灰文案、不可再点。
    private let followActionStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.isHidden = true
        return stack
    }()

    private lazy var followBackButton: UIButton = {
        // 审计：回关钮视觉高约 32 不变，热区用 Hit44 扩到 44。
        // 第十三轮第 7 项：初始不预设标题——关系未查出前不把“回关”摆出来，
        // 标题只由 configureFollowCard 按已确认态写（加载态画中性占位）。
        let button = BearyHit44Button(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setTitleColor(BearyColors.bg, for: .normal)
        button.backgroundColor = BearyColors.ink
        button.layer.cornerRadius = BearyCorners.single
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        button.addTarget(self, action: #selector(followBackTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    private let followProcessedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.isHidden = true
        return label
    }()

    private var followActionsTopConstraint: NSLayoutConstraint?
    private var followActionsHeightConstraint: NSLayoutConstraint?
    private var followBackHandler: (() -> Void)?
    /// 第十三轮第 7 项：回关钮定宽约束——按“回关”量取，加载态无文案占位与有文案态同宽，态变不顶布局。
    private var followBackButtonWidthConstraint: NSLayoutConstraint?

    /// 右下角 19 号类型角标（网页 .nt-kind：圆底 bg、1px line 边、11 号橙图标）。
    private let kindBadgeView: UIView = {
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = BearyColors.bg
        badge.layer.borderWidth = 1
        badge.layer.bearyDynamicBorderColor = BearyColors.line
        badge.layer.cornerRadius = 9.5
        badge.clipsToBounds = true
        return badge
    }()

    private let kindIconView: UIImageView = {
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        return iconView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        label.textColor = BearyColors.ink
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        // 通知标题改完整显示：多行换行不截断；横向低压缩先缩标题，timeLabel 保持 required 不被挤。
        label.lineBreakMode = .byCharWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// 标题行：标题 label + 时间 label（表情改用 NSTextAttachment 内联进标题文本，
    /// 见 configure；标题多行完整显示、时间跟标题首行基线对齐，落在第一排）。
    private let titleRowStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }()


    /// 标题＋摘要竖排栈：标题行（标题＋时间）与摘要行；间距默认 2（独立通知页现行），
    /// 合并消息页改 4，与日记卡片头副标题（12pt、标题行下 4pt）一致。
    private let bodyStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }()

    private let excerptLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.textColor = BearyColors.gray
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    /// 新一轮 01：本行通知的创建时间（毫秒），供页面分钟边界/轮询节拍刷新时重算时间标签。
    private var lastTimeMs: Int?

    /// 新一轮 01：只刷新本行的时间标签（页面分钟边界/轮询节拍调），不触其他内容、不 reloadData。
    func refreshTimeLabel() {
        guard let ms = lastTimeMs else { return }
        timeLabel.text = Self.timeText(ms: ms)
    }

    private let unreadDotView: UIView = {
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = BearyColors.blue
        dot.layer.cornerRadius = 4
        return dot
    }()

    /// 卡面下箭头（网页 .nt-chev 16 灰，展开时旋转 180°）；行内默认隐藏。
    private let chevronView: UIImageView = {
        let chevron = UIImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit
        chevron.isHidden = true
        return chevron
    }()

    private var avatarLeadingConstraint: NSLayoutConstraint?
    private var separatorLeadingConstraint: NSLayoutConstraint?
    private var avatarTopConstraint: NSLayoutConstraint?
    private var avatarCenterYConstraint: NSLayoutConstraint?
    private var avatarBottomGuardConstraint: NSLayoutConstraint?
    /// 标题栈顶锚点：独立页沿用内容顶 +14；合并页改锚头像顶
    ///（见 applyAvatarVerticalStyle），标题字形顶对齐圆圈顶。
    private var bodyStackTopToContentConstraint: NSLayoutConstraint?
    private var bodyStackTopToAvatarConstraint: NSLayoutConstraint?
    private var dotTrailingToContentConstraint: NSLayoutConstraint?
    private var dotTrailingToChevronConstraint: NSLayoutConstraint?

    /// 聚合头像组：单头像位替换为头像栈；bodyStack 左缘在单头像/栈之间切换。
    private let avatarStackView = BearyAvatarStackView()
    private var bodyStackLeadingToAvatarConstraint: NSLayoutConstraint?
    private var bodyStackLeadingToStackConstraint: NSLayoutConstraint?
    private var avatarStackWidthConstraint: NSLayoutConstraint?
    private var avatarStackHeightConstraint: NSLayoutConstraint?
    private var avatarStackBottomGuard: NSLayoutConstraint?

    private let separatorView: UIView = {
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = BearyColors.line
        return separator
    }()

    /// 未读高亮专用底 view（fix 1）：不再用 contentView 全幅底色——
    /// 嵌套行高亮从竖线右侧（x=18）起，竖线左侧 gutter 永远是页面底色；
    /// 顶层行/卡面从行左缘（x=0）起，与旧观感一致。
    private let unreadBgView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }()
    private var unreadBgLeadingConstraint: NSLayoutConstraint?

    /// 嵌套行左侧竖线（网页 .nt-sysin border-left 2px line 色，x=20 起，
    /// 随展开区整列连续；仅嵌套行显示，卡面/顶层行隐藏）。
    private let nestedLineView: UIView = {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = BearyColors.line
        line.isHidden = true
        return line
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = BearyColors.hov
        selectedBackgroundView = selectedBackground
        // 高度生长动画中行高缩到 0 时内容不得溢出到相邻行。
        clipsToBounds = true
        bodyStack.addArrangedSubview(titleRowStack)
        bodyStack.addArrangedSubview(excerptLabel)
        titleRowStack.addArrangedSubview(titleLabel)
        titleRowStack.addArrangedSubview(timeLabel)
        kindBadgeView.addSubview(kindIconView)
        contentView.addSubview(unreadBgView)
        contentView.sendSubviewToBack(unreadBgView)
        contentView.addSubview(avatarImageView)
        contentView.addSubview(avatarFallbackLabel)
        contentView.addSubview(avatarIconView)
        contentView.addSubview(popperView)
        contentView.addSubview(kindBadgeView)
        contentView.addSubview(avatarRetryButton)
        avatarStackView.translatesAutoresizingMaskIntoConstraints = false
        avatarStackView.isHidden = true
        contentView.addSubview(avatarStackView)
        contentView.addSubview(bodyStack)
        contentView.addSubview(unreadDotView)
        contentView.addSubview(chevronView)
        contentView.addSubview(separatorView)
        contentView.addSubview(nestedLineView)
        // 好友申请卡动作区：贴 bodyStack 下方（头像/标题列左缘对齐），平时 0 高不占位。
        followActionStack.addArrangedSubview(followBackButton)
        followActionStack.addArrangedSubview(followProcessedLabel)
        contentView.addSubview(followActionStack)
        followActionsTopConstraint = followActionStack.topAnchor.constraint(equalTo: bodyStack.bottomAnchor, constant: 0)
        followActionsHeightConstraint = followActionStack.heightAnchor.constraint(equalToConstant: 0)
        followActionsTopConstraint?.isActive = true
        followActionsHeightConstraint?.isActive = true
        // 行内边距 16/14 由 cell 自身承担（列宽已是满 600，见 contentView 注释；
        // 32 清单第 5 项：头像 x 与未读点/箭头右距统一 16，与规范 §3 内容列 16 对齐）：
        // 顶层行头像 x=16、未读点右 -16、箭头右 -16；嵌套行在此基础上再缩进（见 configure）。
        avatarLeadingConstraint = avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        separatorLeadingConstraint = separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
        dotTrailingToContentConstraint = unreadDotView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        dotTrailingToChevronConstraint = unreadDotView.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -12)
        avatarLeadingConstraint?.isActive = true
        separatorLeadingConstraint?.isActive = true
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false
        // bodyStack 左缘：单头像行钉头像右缘＋12，聚合行钉头像栈右缘＋12；
        // 栈与单头像同顶（14）、同左缘（跟 avatarLeadingConstraint 走嵌套缩进）。
        bodyStackLeadingToAvatarConstraint = bodyStack.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12)
        bodyStackLeadingToStackConstraint = bodyStack.leadingAnchor.constraint(equalTo: avatarStackView.trailingAnchor, constant: 12)
        avatarStackWidthConstraint = avatarStackView.widthAnchor.constraint(equalToConstant: 42)
        avatarStackHeightConstraint = avatarStackView.heightAnchor.constraint(equalToConstant: 42)
        avatarStackBottomGuard = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarStackView.bottomAnchor, constant: 14)
        avatarStackBottomGuard?.priority = UILayoutPriority(999)
        bodyStackLeadingToAvatarConstraint?.isActive = true
        avatarStackWidthConstraint?.isActive = true
        avatarStackHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            avatarStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarStackView.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
        ])
        unreadBgLeadingConstraint = unreadBgView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
        unreadBgLeadingConstraint?.isActive = true
        // 头像垂直锚点：默认顶锚 14（独立通知页现行）；合并消息页改居中（见 applyAvatarVerticalStyle）。
        avatarTopConstraint = avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)
        avatarCenterYConstraint = avatarImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        avatarTopConstraint?.isActive = true
        // 标题栈顶锚点：默认内容顶 +14（独立通知页现行）；合并页改锚头像顶
        //（见 applyAvatarVerticalStyle），头像锚默认不激活。
        bodyStackTopToContentConstraint = bodyStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)
        bodyStackTopToAvatarConstraint = bodyStack.topAnchor.constraint(equalTo: avatarImageView.topAnchor, constant: 0)
        bodyStackTopToContentConstraint?.isActive = true
        NSLayoutConstraint.activate([
            unreadBgView.topAnchor.constraint(equalTo: contentView.topAnchor),
            unreadBgView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            unreadBgView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 42),
            avatarImageView.heightAnchor.constraint(equalToConstant: 42),
            avatarFallbackLabel.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarFallbackLabel.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarIconView.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarIconView.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarIconView.widthAnchor.constraint(equalToConstant: 19),
            avatarIconView.heightAnchor.constraint(equalToConstant: 19),
            popperView.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            popperView.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            popperView.widthAnchor.constraint(equalToConstant: 19),
            popperView.heightAnchor.constraint(equalToConstant: 19),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
            kindBadgeView.widthAnchor.constraint(equalToConstant: 19),
            kindBadgeView.heightAnchor.constraint(equalToConstant: 19),
            kindBadgeView.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 4),
            kindBadgeView.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 4),
            kindIconView.centerXAnchor.constraint(equalTo: kindBadgeView.centerXAnchor),
            kindIconView.centerYAnchor.constraint(equalTo: kindBadgeView.centerYAnchor),
            kindIconView.widthAnchor.constraint(equalToConstant: 11),
            kindIconView.heightAnchor.constraint(equalToConstant: 11),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            followActionStack.leadingAnchor.constraint(equalTo: bodyStack.leadingAnchor),
            followActionStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            followActionStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            // 标题行右缘钉到未读点左缘 -12：时间在标题行内，标题列撑满整宽，
            // 标题在（整宽 - 时间宽 - 间距）内换行，未读点位置由自身约束定，不依赖此式。
            bodyStack.trailingAnchor.constraint(equalTo: unreadDotView.leadingAnchor, constant: -12),
            unreadDotView.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            unreadDotView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            unreadDotView.widthAnchor.constraint(equalToConstant: 8),
            unreadDotView.heightAnchor.constraint(equalToConstant: 8),
            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevronView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            chevronView.widthAnchor.constraint(equalToConstant: 16),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),
            nestedLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nestedLineView.widthAnchor.constraint(equalToConstant: 2),
            nestedLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            nestedLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        // 底线贴行底时行高由内容撑起：头像 42 + 顶 14 + 底 16 即最小 72。
        avatarBottomGuardConstraint = contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarImageView.bottomAnchor, constant: 16)
        avatarBottomGuardConstraint?.priority = UILayoutPriority(999)
        avatarBottomGuardConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 角标描边是 CGColor，深浅切换时重赋，否则深色下仍留浅色边。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            kindBadgeView.layer.bearyDynamicBorderColor = BearyColors.line
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelAvatarLoad()
        resetAvatarStack()
        avatarRetryURL = nil
        avatarRetryActorName = ""
        avatarRetryButton.isHidden = true
        avatarImageView.image = nil
        avatarFallbackLabel.text = nil
        avatarFallbackLabel.isHidden = true
        avatarIconView.image = nil
        avatarIconView.isHidden = true
        avatarIconView.tintColor = BearyColors.orange
        popperView.stop()
        popperView.isHidden = true
        kindBadgeView.isHidden = true
        kindIconView.image = nil
        titleLabel.attributedText = nil
        titleLabel.text = nil
        excerptLabel.attributedText = nil
        excerptLabel.text = nil
        // 错峰入场动画残留不得带到复用行。
        alpha = 1
        transform = CGAffineTransform.identity
        timeLabel.text = nil
        lastTimeMs = nil
        unreadDotView.isHidden = true
        chevronView.isHidden = true
        chevronView.transform = CGAffineTransform.identity
        chevronView.image = nil
        avatarLeadingConstraint?.constant = 16
        separatorLeadingConstraint?.constant = 0
        // 头像垂直锚点与标题／摘要间距复位到独立页基线（顶锚 14 + 底 guard 16、间距 2）；
        // 合并页 configure 再按 mergedList 改。
        avatarCenterYConstraint?.isActive = false
        avatarTopConstraint?.isActive = true
        avatarBottomGuardConstraint?.constant = 16
        bodyStackTopToAvatarConstraint?.isActive = false
        bodyStackTopToContentConstraint?.isActive = true
        bodyStack.spacing = 2
        nestedLineView.isHidden = true
        unreadBgView.backgroundColor = .clear
        unreadBgLeadingConstraint?.constant = 0
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false
        // 关注提醒卡动作区不得带到复用行。
        hideFollowAction()
    }

    /// 取消在途头像加载并作废其回调：复用/换行时旧失败回调不得亮重试图标。
    private func cancelAvatarLoad() {
        avatarTask?.cancel()
        avatarTask = nil
        avatarLoadGeneration += 1
    }

    /// 互动行头像加载：加载中与成功态沿用现有行为（首字母占位 / 落图）；
    /// 仅失败态新增重试图标：失败时藏首字母占位、亮重试图标，点重试重新走
    /// 本方法（重试中图标先藏、恢复首字母占位），成功后图标消失。
    /// 取消（复用/换图）不算失败，不亮重试图标；无图（avatarURL 为空）不走
    /// 本方法，调用方只露首字母占位、不亮重试图标。
    private func loadAvatar(url: URL, actorName: String) {
        cancelAvatarLoad()
        avatarRetryURL = url
        // 第十三轮第 8 项：缺名（nil 或空串已在调用方回落，此处再兜底一次）不再回退字母 "T"，
        // 与全站缺省名“beary 用户”一致（首字母占位即 "B"）。
        let displayName = actorName.isEmpty ? "beary 用户" : actorName
        avatarRetryActorName = displayName
        avatarImageView.image = nil
        avatarRetryButton.isHidden = true
        avatarFallbackLabel.isHidden = false
        avatarFallbackLabel.text = String(displayName.prefix(1)).uppercased()
        let generation = avatarLoadGeneration
        // 头像框 42pt：下采样到 42×scale 解码，不整图全解码进内存。
        avatarTask = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: 42 * UIScreen.main.scale) { [weak self] result in
            guard let strongSelf = self else { return }
            guard generation == strongSelf.avatarLoadGeneration else { return }
            strongSelf.avatarTask = nil
            switch result {
            case .success(let loadedImage):
                strongSelf.avatarImageView.image = loadedImage
                strongSelf.avatarFallbackLabel.isHidden = true
                strongSelf.avatarRetryButton.isHidden = true
            case .failure(let loadError):
                if case .cancelled = loadError {
                    return
                }
                strongSelf.avatarImageView.image = nil
                strongSelf.avatarFallbackLabel.isHidden = true
                strongSelf.avatarRetryButton.isHidden = false
            }
        }
    }

    @objc private func avatarRetryTapped() {
        guard let retryURL = avatarRetryURL else { return }
        loadAvatar(url: retryURL, actorName: avatarRetryActorName)
    }

    /// 卡面箭头旋转（调用方用 UIView.animate 包裹即得展开/收起动画）。
    func setChevronExpanded(_ expanded: Bool) {
        chevronView.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
    }

    /// 未读高亮与未读点分离：高亮只画在 unreadBgView（嵌套行从竖线右侧
    /// x=18 起，顶层行/卡面从行左缘起），cell 与 contentView 永远是页面底色；
    /// 点仍只看未读（highlight=false 时点照常亮，见 seen 水印规则）。
    private func applyUnreadHighlight(highlight: Bool, blueAlpha: CGFloat, nested: Bool) {
        unreadBgLeadingConstraint?.constant = nested ? 18 : 0
        unreadBgView.backgroundColor = highlight ? BearyColors.alpha(BearyColors.blue, blueAlpha) : .clear
        contentView.backgroundColor = BearyColors.bg
        backgroundColor = BearyColors.bg
    }

    /// C-G10：已读态直接改 class——只动高亮与未读点，不重载行。
    /// 普通行未读底蓝 7%、sys 行蓝 9%（与 configure 同口径）；highlight
    /// 由调用方按 seen 水印算（未读但已 seen 时高亮灭、点仍亮）。
    func setReadAppearance(isUnread: Bool, isSystemStyle: Bool, highlight: Bool) {
        applyUnreadHighlight(highlight: highlight, blueAlpha: isSystemStyle ? 0.09 : 0.07, nested: !nestedLineView.isHidden)
        unreadDotView.isHidden = !isUnread
    }

    /// 卡面类别色（第十轮 #13／#15）：系统卡一律橙底＋深橙图标（已读也不退，
    /// 橙色类别标记不动；浅色图标走 deepOrangeText）；互动卡未读时蓝底＋蓝图标，
    /// 已读退回灰底＋墨图标，蓝色只剩未读点／未读背景承担。
    private func applyCardCategoryColors(isSystem: Bool, anyUnread: Bool) {
        if isSystem {
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.14)
            avatarIconView.tintColor = BearyColors.deepOrangeText
        } else if anyUnread {
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.12)
            avatarIconView.tintColor = BearyColors.blue
        } else {
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.gray, 0.12)
            avatarIconView.tintColor = BearyColors.ink
        }
    }

    /// C-G10：卡面已读态直接改 class——未读底一律蓝 9%；highlight 同上。
    /// 类别色同步重算（就地标已读也要把互动卡蓝图标／蓝底退回墨／灰，见上）。
    func setCardReadAppearance(anyUnread: Bool, highlight: Bool, isSystem: Bool) {
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.09, nested: false)
        unreadDotView.isHidden = !anyUnread
        applyCardCategoryColors(isSystem: isSystem, anyUnread: anyUnread)
    }

    /// 合并消息页口径：头像改垂直居中（与私信行同款；居中 42 圆在 72 高行内
    /// 上下各 15，底 guard 相应改为 15）；独立通知页仍走顶锚 14 + 底 guard 16。
    /// 合并页标题栈顶同时改锚头像顶，标题字形顶对齐圆圈顶。
    /// 只由两 configure 方法的 mergedList 分支调；复用复位见 prepareForReuse。
    private func applyAvatarVerticalStyle(mergedList: Bool) {
        if mergedList {
            avatarTopConstraint?.isActive = false
            avatarCenterYConstraint?.isActive = true
            avatarBottomGuardConstraint?.constant = 15
            // 标题顶对齐圆圈顶：16 粗标题字形顶比 label 框顶低 ascender-capHeight
            //（默认字号约 4pt），标题栈顶改锚头像顶再上移该量，字形顶即落到头像顶；
            // 按当前字号实算，大字号下仍对齐。时间在标题行内跟首行基线，不用另动。
            let titleFont = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16))
            bodyStackTopToAvatarConstraint?.constant = -(titleFont.ascender - titleFont.capHeight)
            bodyStackTopToContentConstraint?.isActive = false
            bodyStackTopToAvatarConstraint?.isActive = true
        } else {
            avatarCenterYConstraint?.isActive = false
            avatarTopConstraint?.isActive = true
            avatarBottomGuardConstraint?.constant = 16
            bodyStackTopToAvatarConstraint?.isActive = false
            bodyStackTopToContentConstraint?.isActive = true
        }
    }

    /// 折叠卡卡面：系统卡橙 14% 底 + mail 图，互动卡未读蓝 12% 底 + heart 图、
    /// 已读灰底＋墨图标（第十轮 #15）；未读底一律蓝 9%（网页 .nt-item.sys.unread，
    /// 互动卡同样带 sys 类）。
    /// - Parameter mergedList: 合并消息页与通知详情页时 true：分隔线缩进 16、
    ///   标题/摘要不用 1.5 倍行高、头像垂直居中、标题／摘要间距 5（与私信行一致），
    ///   且不显示右三角；独立通知页传 false（默认），下箭头展开行为不变。
    func configureAsCard(title: String, excerpt: String, timeMs: Int?, anyUnread: Bool, isSystem: Bool, expanded: Bool, highlight: Bool, mergedList: Bool = false) {
        applyAvatarVerticalStyle(mergedList: mergedList)
        bodyStack.spacing = mergedList ? 4 : 2
        cancelAvatarLoad()
        hideFollowAction()
        avatarRetryURL = nil
        avatarRetryActorName = ""
        avatarRetryButton.isHidden = true
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.09, nested: false)
        unreadDotView.isHidden = !anyUnread
        applyCardCategoryColors(isSystem: isSystem, anyUnread: anyUnread)
        popperView.stop()
        popperView.isHidden = true
        avatarIconView.isHidden = false
        avatarIconView.image = BearyIconImages.image(named: isSystem ? "icon_mail" : "icon_heart", pointSize: 19)
        avatarFallbackLabel.isHidden = true
        kindBadgeView.isHidden = true
        nestedLineView.isHidden = true
        titleLabel.attributedText = BearyNotificationCell.moodLineHeightText(title, font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)), color: BearyColors.ink, lineBreakMode: .byCharWrapping, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        excerptLabel.attributedText = BearyNotificationCell.moodLineHeightText(excerpt, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: mergedList ? 12 : 14)), color: BearyColors.gray, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        lastTimeMs = timeMs
        timeLabel.text = BearyNotificationCell.timeText(ms: timeMs)
        if mergedList {
            // 合并消息页与通知详情页：右三角去掉（点按进详情不变）；未读点贴内容右缘。
            chevronView.isHidden = true
            chevronView.image = nil
            chevronView.transform = .identity
            dotTrailingToContentConstraint?.isActive = true
            dotTrailingToChevronConstraint?.isActive = false
        } else {
            chevronView.isHidden = false
            chevronView.image = BearyIconImages.image(named: "icon_chevron_down", pointSize: 16)
            chevronView.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
            dotTrailingToContentConstraint?.isActive = false
            dotTrailingToChevronConstraint?.isActive = true
        }
        avatarLeadingConstraint?.constant = 16
        separatorLeadingConstraint?.constant = mergedList ? 16 : 0
        nestedLineView.isHidden = true
    }

    /// 网页 .nt-body line-height 1.5：标题 16→24、摘要 14→21，
    /// 与上下 14 padding 合计行高约 77；合并消息页与通知详情页传 multiple 1.0
    ///（与私信行同款无倍数行高），行高由底 guard 72 兜底。
    private static func lineHeightText(_ string: String, font: UIFont, color: UIColor, lineBreakMode: NSLineBreakMode = .byTruncatingTail, multiple: CGFloat = 1.5) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = lineBreakMode
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// 摘要/标题走心情渲染：服务端 excerpt/body 是日记正文切片，
    /// 含 [mood:]/[gif:] 记号原文；与卡片同款 inlineAttributedText，
    /// 行高默认 1.5、断行口径与 lineHeightText 一致；合并列表传
    /// multiple 1.0（与私信行同款无倍数行高）。通知无条目图，
    /// [gif:] 记号按既有兜底留原文。
    private static func moodLineHeightText(_ string: String, font: UIFont, color: UIColor, lineBreakMode: NSLineBreakMode = .byTruncatingTail, multiple: CGFloat = 1.5, dark: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = multiple
        paragraph.lineBreakMode = lineBreakMode
        return BearyText.inlineAttributedText(from: BearyText.stripTrailingPartialInlineToken(string), font: font, color: color, paragraphStyle: paragraph, dark: dark, gifImageKeys: nil)
    }


    /// 通知时间口径（2026-11-11 定版带空格，取代 2026-11-05 口径）：24 小时内相对时间——不到 1 分钟“刚刚”，
    /// 不到 1 小时“X 分钟前”，不到 24 小时“X 小时前”；超过 24 小时写天数“X 天前”。
    /// 新一轮 01：几秒内的时钟偏差仍算“刚刚”；明显未来（> 5 秒）不误报为刚发送，
    /// 改走绝对时间显示。
    private static func timeText(ms: Int?) -> String {
        guard let msValue = ms else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let diff = Date().timeIntervalSince(date)
        if diff < -5 { return BearyText.timeString(ms: msValue) }
        // 相对档位复用带空格共享实现（规范 §12）；共享实现无未来分支，故未来守卫留本地。
        return BearyVisibilityText.publishedRelativeString(publishedAtMs: msValue) ?? ""
    }


    /// 互动动词（卡面最新一条与行标题共用，须对 VC 可见，故不 private）。
    /// 网页 ntVerb 口径：非 like / bookmark / mention 一律回退为“给你的日记贴了小熊回应”
    ///（未知 type 同 emote 文案，不再返回空串）。
    static func verb(for type: String?) -> String {
        if type == "like" {
            return "赞了你的日记"
        }
        if type == "bookmark" {
            return "收藏了你的日记"
        }
        // 补缺 P3-36：@ 通知（服务端 type=mention）不用回应文案，改“@了你”。
        if type == "mention" {
            return "@了你"
        }
        // 好友第一期：关注提醒行文案（卡面标题即“XXX 关注了你”，回关按钮另见
        // configureFollowCard）；私信行文案“发来一条私信”，摘要走 excerpt；
        // 未知 type 仍回退回应文案，不编造新动词。
        if type == "follow" {
            return "关注了你"
        }
        if type == "dm" {
            return "发来一条私信"
        }
        return "给你的日记贴了小熊回应"
    }

    /// - Parameter mergedList: 合并消息页与通知详情页时 true：分隔线缩进 16、
    ///   标题/摘要不用 1.5 倍行高、头像垂直居中、标题／摘要间距 5，与私信行统一；
    ///   独立通知页传 false（默认）。
    func configure(with item: NotificationItem, nested: Bool, highlight: Bool, mergedList: Bool = false) {
        // 复用行先清关注动作区；关注行由 VC 随后调 configureFollowCard 补上。
        hideFollowAction()
        resetAvatarStack()
        applyAvatarVerticalStyle(mergedList: mergedList)
        bodyStack.spacing = mergedList ? 4 : 2
        let itemType = item.type ?? ""
        let isSystemStyle = itemType == "system" || itemType == "letter"
        let isUnread = (item.read ?? true) == false

        // 嵌套行（网页 .nt-sysin 口径）：容器 margin-left 20 + border 2px
        // + padding-left 8，再加行内 padding 20——头像 x=20+2+8+20=50，
        // 分隔线（行底边、起于行左缘）x=20+2+8=30；App 原 48/28 各左偏 2px。
        // 竖线本身 x=20（margin 起点）不变。
        // 补缺 P3-37：嵌套头像 x 按文件头注释口径（网页 .nt-sysin：头像 x=50、分隔线起于 30）统一为 50；
        // 真实像素未经真机截图量取，待 Li 真机核实（不得以本值冒充实测值）。
        avatarLeadingConstraint?.constant = nested ? 50 : 16
        separatorLeadingConstraint?.constant = mergedList ? 16 : (nested ? 30 : 0)
        nestedLineView.isHidden = !nested
        chevronView.isHidden = true
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false

        // 未读底：普通行蓝 7%、sys 行（含信件行）蓝 9%（网页 .nt-item.unread / .sys.unread）。
        // 高亮走 unreadBgView（嵌套行从竖线右侧起），点只看未读。
        applyUnreadHighlight(highlight: highlight, blueAlpha: isSystemStyle ? 0.09 : 0.07, nested: nested)
        unreadDotView.isHidden = !isUnread

        if isSystemStyle {
            // 信件行与系统信行：橙 14% 底头像 + 19 号图（网页 .nt-sysava）。
            // 本地图标无网络加载，故无重试图标；在途互动头像加载一律取消作废。
            cancelAvatarLoad()
            avatarRetryURL = nil
            avatarRetryActorName = ""
            avatarRetryButton.isHidden = true
            // system 行标题含“成就/徽章”时用 popper（礼花）图，否则 mail 图；
            // letter 行恒为 mail 图（网页 ntOne 两分支同口径）。
            // 第十轮 #13：系统图标浅色走 deepOrangeText（#C2410C，淡橙底上约 5.18:1；
            // 原 orange 亮橙仅约 2.20:1），深色与 orange 同值不变；底仍保留淡橙 14%。
            avatarImageView.backgroundColor = BearyColors.alpha(BearyColors.orange, 0.14)
            avatarIconView.tintColor = BearyColors.deepOrangeText
            // C-G2：同上，空串标题回退（网页 || 语义）。
            let rawTitle = item.title ?? ""
            let titleText = rawTitle.isEmpty ? (itemType == "letter" ? "消息" : "通知") : rawTitle
            // 第 17 项 B：system 行标题含“成就/徽章”时不再用静态 icon_popper，
            // 改 BearyPopperView 按网页 NB.popper 动态画；否则仍为 mail 静态图。
            if itemType == "system" && (titleText.contains("成就") || titleText.contains("徽章")) {
                avatarIconView.image = nil
                avatarIconView.isHidden = true
                popperView.isHidden = false
                popperView.start()
            } else {
                popperView.stop()
                popperView.isHidden = true
                avatarIconView.isHidden = false
                avatarIconView.image = BearyIconImages.image(named: "icon_mail", pointSize: 19)
            }
            avatarFallbackLabel.isHidden = true
            kindBadgeView.isHidden = true
            titleLabel.attributedText = BearyNotificationCell.moodLineHeightText(titleText, font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)), color: BearyColors.ink, lineBreakMode: .byCharWrapping, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        } else {
            // 互动行：42 圆头像（无图回退首字母 15/700 灰）+ 右下角 19 号类型角标。
            avatarImageView.backgroundColor = BearyColors.line
            popperView.stop()
            popperView.isHidden = true
            avatarIconView.isHidden = true
            kindBadgeView.isHidden = false
            // 网页 ntOne 口径：非 like / bookmark 的角标一律回退为 mood 图；@ 行补 @ 图标。
            let kindIconName: String
            if itemType == "like" {
                kindIconName = "icon_heart"
            } else if itemType == "bookmark" {
                kindIconName = "icon_bookmark"
            } else if itemType == "mention" {
                kindIconName = "icon_at"
            } else if itemType == "emote" {
                kindIconName = "icon_mood"
            } else if itemType == "follow" {
                kindIconName = "icon_user_plus"
            } else if itemType == "dm" {
                kindIconName = "icon_mail"
            } else {
                kindIconName = "icon_mood"
            }
            kindIconView.image = BearyIconImages.image(named: kindIconName, pointSize: 11)
            // 32 注销口径：通知行对方已注销时，标题与头像首字母显“用户已注销／用”。
            // 第十三轮第 8 项：缺名（nil 或空串）统一回落全站缺省名“beary 用户”，
            // 与已注销（“用户已注销”）是两种状态，不混淆。
            let deletedName = bearyDeletedAuthorDisplayName(item.actorName) ?? ""
            let actorName = deletedName.isEmpty ? "beary 用户" : deletedName
            if let avatarURL = BearyImageURLs.avatarURL(item.actorAvatar) {
                loadAvatar(url: avatarURL, actorName: actorName)
            } else {
                cancelAvatarLoad()
                avatarRetryURL = nil
                avatarRetryActorName = ""
                avatarRetryButton.isHidden = true
                avatarFallbackLabel.isHidden = false
                avatarFallbackLabel.text = String(actorName.prefix(1)).uppercased()
            }
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(
                string: actorName,
                attributes: [
                    .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            let verbText = BearyNotificationCell.verb(for: itemType)
            title.append(NSAttributedString(
                string: " " + verbText,
                attributes: [
                    .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)),
                    .foregroundColor: BearyColors.ink,
                ]
            ))
            // 网页 .nt-act 口径：emote 仅作内联附件贴进标题文本流（20x20、
            // vertical-align -5），标题换行时表情随文本流换行，不再是行末固定视图。
            // 静态 PNG（BearyEmoteImages）与网页 <img> 同为静态图，不走 Lottie 播放器。
            if itemType == "emote", let emoteKey = item.emote, !emoteKey.isEmpty {
                let isDark = traitCollection.userInterfaceStyle == .dark
                if let emoteImage = BearyEmoteImages.image(for: emoteKey, dark: isDark) {
                    let attachment = NSTextAttachment()
                    attachment.image = emoteImage
                    attachment.bounds = CGRect(x: 0, y: -5, width: 20, height: 20)
                    title.append(NSAttributedString(string: " "))
                    title.append(NSAttributedString(attachment: attachment))
                }
            }
            let titleParagraph = NSMutableParagraphStyle()
            titleParagraph.lineHeightMultiple = mergedList ? 1.0 : 1.5
            titleParagraph.lineBreakMode = .byCharWrapping
            title.addAttribute(.paragraphStyle, value: titleParagraph, range: NSRange(location: 0, length: title.length))
            titleLabel.attributedText = title
        }

        excerptLabel.attributedText = BearyNotificationCell.moodLineHeightText(item.excerpt ?? "", font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: mergedList ? 12 : 14)), color: BearyColors.gray, multiple: mergedList ? 1.0 : 1.5, dark: traitCollection.userInterfaceStyle == .dark)
        lastTimeMs = item.createdAt
        timeLabel.text = BearyNotificationCell.timeText(ms: item.createdAt)
    }

    /// 聚合行配置（2026-11-18 Li 定）：单头像换成可展开头像组，标题为
    /// 多人名＋动词（2 人「A 和 B …」，3 人及以上人名以、连接、末两人以和
    /// 连接；名字段整体粗体、动词常规，与单行同口径）；副标题与时间走
    /// 组内最新一条（代表条）；未读点与高亮看组内任一成员。聚合行不画
    /// 类型角标（动作已在动词里）与关注卡（回关归属不明）；emote 组不贴
    /// 表情附件（各成员表情可能不同，动词已说明动作）。
    /// 注：后端已在通知里补 e.title（2026-11-18 Li 定），代表条有标题时动词后加《标题》，
    /// 无标题（null/空/旧缓存）仍用现行动词（「赞了你的日记」）。
    func configureAsGroup(representative: NotificationItem, members: [NotificationItem], nested: Bool, highlight: Bool, expanded: Bool, onToggle: @escaping () -> Void) {
        hideFollowAction()
        resetAvatarStack()
        cancelAvatarLoad()
        avatarRetryURL = nil
        avatarRetryActorName = ""
        avatarRetryButton.isHidden = true
        avatarImageView.isHidden = true
        avatarFallbackLabel.isHidden = true
        avatarIconView.isHidden = true
        popperView.stop()
        popperView.isHidden = true
        kindBadgeView.isHidden = true
        avatarLeadingConstraint?.constant = nested ? 50 : 16
        separatorLeadingConstraint?.constant = nested ? 30 : 0
        nestedLineView.isHidden = !nested
        chevronView.isHidden = true
        dotTrailingToContentConstraint?.isActive = true
        dotTrailingToChevronConstraint?.isActive = false

        let anyUnread = members.contains(where: { ($0.read ?? true) == false })
        applyUnreadHighlight(highlight: highlight, blueAlpha: 0.07, nested: nested)
        unreadDotView.isHidden = !anyUnread

        // 头像组：≤4 人全显示，超 4 人前 3 个头像＋第 4 个圆“+数字”。
        let shownMembers = members.count > 4 ? Array(members.prefix(3)) : members
        let overflowCount = members.count > 4 ? members.count - 3 : 0
        let actors: [(name: String, avatarURL: URL?)] = shownMembers.map { member in
            let deletedName = bearyDeletedAuthorDisplayName(member.actorName) ?? ""
            let displayName = deletedName.isEmpty ? "beary 用户" : deletedName
            return (name: displayName, avatarURL: BearyImageURLs.avatarURL(member.actorAvatar))
        }
        avatarStackView.configure(actors: actors, overflowCount: overflowCount, expanded: expanded, onToggle: onToggle)
        avatarStackView.isHidden = false
        let circleCount = avatarStackView.circleCount
        avatarStackWidthConstraint?.constant = expanded ? BearyAvatarStackView.expandedWidth(count: circleCount) : BearyAvatarStackView.collapsedWidth(count: circleCount)
        avatarStackHeightConstraint?.constant = expanded ? BearyAvatarStackView.expandedHeight : BearyAvatarStackView.avatarDiameter
        avatarStackBottomGuard?.isActive = true
        bodyStackLeadingToAvatarConstraint?.isActive = false
        bodyStackLeadingToStackConstraint?.isActive = true

        let displayNames = members.map { member -> String in
            let deletedName = bearyDeletedAuthorDisplayName(member.actorName) ?? ""
            return deletedName.isEmpty ? "beary 用户" : deletedName
        }
        let namesText: String
        if displayNames.count == 2 {
            namesText = displayNames[0] + " 和 " + displayNames[1]
        } else if displayNames.count > 2 {
            let head = displayNames.dropLast().joined(separator: "、")
            namesText = head + " 和 " + (displayNames.last ?? "")
        } else {
            namesText = displayNames.first ?? "beary 用户"
        }
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: namesText,
            attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 16)),
                .foregroundColor: BearyColors.ink,
            ]
        ))
        let verbText = BearyNotificationCell.verb(for: representative.type)
        title.append(NSAttributedString(
            string: " " + verbText,
            attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)),
                .foregroundColor: BearyColors.ink,
            ]
        ))
        // 聚合行《标题》（2026-11-18 Li 定，后端已补 e.title）：代表条有标题时动词后加《标题》，
        // 无标题（null/空/旧缓存）保持现行动词文案不变。
        if let entryTitle = representative.entryTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !entryTitle.isEmpty {
            let titleFont = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: BearyColors.ink]
            title.append(NSAttributedString(string: "《", attributes: titleAttrs))
            title.append(BearyText.inlineAttributedText(from: BearyText.stripTrailingPartialInlineToken(entryTitle), font: titleFont, color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: nil))
            title.append(NSAttributedString(string: "》", attributes: titleAttrs))
        }
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineHeightMultiple = 1.5
        titleParagraph.lineBreakMode = .byCharWrapping
        title.addAttribute(.paragraphStyle, value: titleParagraph, range: NSRange(location: 0, length: title.length))
        titleLabel.attributedText = title

        excerptLabel.attributedText = BearyNotificationCell.moodLineHeightText(representative.excerpt ?? "", font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14)), color: BearyColors.gray, dark: traitCollection.userInterfaceStyle == .dark)
        lastTimeMs = representative.createdAt
        timeLabel.text = BearyNotificationCell.timeText(ms: representative.createdAt)
    }

    /// 头像组展开/收起（VC 的 toggleGroupExpanded 调）：栈宽/高约束同步改，
    /// 圆圈散开/收回由栈自己播；行高生长由 VC 的 begin/endUpdates 驱动。
    func setGroupExpanded(_ expanded: Bool, animated: Bool) {
        guard !avatarStackView.isHidden else { return }
        let count = avatarStackView.circleCount
        avatarStackWidthConstraint?.constant = expanded ? BearyAvatarStackView.expandedWidth(count: count) : BearyAvatarStackView.collapsedWidth(count: count)
        avatarStackHeightConstraint?.constant = expanded ? BearyAvatarStackView.expandedHeight : BearyAvatarStackView.avatarDiameter
        avatarStackView.setExpanded(expanded, animated: animated)
    }

    /// 聚合态复位：拆头像栈、恢复单头像约束（prepareForReuse 与单条 configure 共用）。
    private func resetAvatarStack() {
        avatarStackView.reset()
        avatarStackView.isHidden = true
        avatarStackBottomGuard?.isActive = false
        bodyStackLeadingToStackConstraint?.isActive = false
        bodyStackLeadingToAvatarConstraint?.isActive = true
        avatarImageView.isHidden = false
        kindBadgeView.isHidden = false
    }

    /// 好友第一期：关注提醒卡动作区状态（VC 按关注方 id 持有，不随 cell 复用丢失）。
    /// 一律按实时关系状态定（state 接口现取现定，不沿用通知创建时的快照）：
    /// 对方仍关注我、我没关注对方 → 回关；对方已取关、我也没关注 → 关注；
    /// 我已关注对方 → 已关注灰文案、不可再点；已互关 → 已互关灰文案、不可再点。
    enum FollowCardState {
        /// state 接口在途：按钮禁用防重复发，画中性占位（无“回关”/“关注”文字，不暗示关系）。
        case loading
        /// 对方仍关注我、我没关注对方：回关钮可点。
        case canFollowBack
        /// 对方已取关、我也没关注对方：关注钮可点（不是回关）。
        case canFollow
        /// 我已关注对方：已关注灰文案、不可再点。
        case following
        /// 已互关：按钮换成“已互关”灰文案、不可再点。
        case mutual
        /// 回关请求在途：按钮禁用防重复发。
        case busy
        /// state 拉取失败：按钮恢复可点（画“重试”，见下），点按重试拉取。
        case loadFailed
    }

    /// 关注提醒卡动作区：base configure(with:) 已画好头像/名字/时间（verb“关注了你”），
    /// 本函数只管动作区。loading/busy 时画与按钮等宽的中性占位（无文案、读屏跳过），
    /// 查询成功后才显准确操作；canFollowBack 时回关钮可点；
    /// canFollow 时关注钮可点；following 时“已关注”灰文案、不可再点；
    /// mutual 时按钮换成“已互关”文案、不可再点；loadFailed 时按钮画“重试”可点
    /// （点按重试拉取，不是直接关注）。非关注行调用 hideFollowAction。
    func configureFollowCard(state: FollowCardState, onFollowBack: @escaping () -> Void) {
        followBackHandler = onFollowBack
        followActionStack.isHidden = false
        followActionsTopConstraint?.constant = 10
        followActionsHeightConstraint?.isActive = false
        // 第十三轮第 7 项：定宽（按“回关”量取，与“关注”同宽），每次重配都按当前字号重算，
        // 加载态无文案占位与有文案态同宽，态变不顶布局、不闪没。
        let titleFont = followBackButton.titleLabel?.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        let placeholderWidth = ceil(("回关" as NSString).size(withAttributes: [.font: titleFont]).width)
            + followBackButton.contentEdgeInsets.left + followBackButton.contentEdgeInsets.right
        if let constraint = followBackButtonWidthConstraint {
            constraint.constant = placeholderWidth
        } else {
            let constraint = followBackButton.widthAnchor.constraint(equalToConstant: placeholderWidth)
            constraint.isActive = true
            followBackButtonWidthConstraint = constraint
        }
        switch state {
        case .loading, .busy:
            // 第十三轮第 7 项：关系未查出前不摆“回关”/“关注”——中性占位（line 底、
            // 无文案、读屏跳过），只禁用防重复发；查询成功后才出现准确操作。
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle(nil, for: .normal)
            followBackButton.accessibilityLabel = nil
            followBackButton.isAccessibilityElement = false
            followBackButton.backgroundColor = BearyColors.line
            followBackButton.isEnabled = false
            followBackButton.alpha = 1
        case .canFollowBack:
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle("回关", for: .normal)
            followBackButton.accessibilityLabel = "回关"
            followBackButton.isAccessibilityElement = true
            followBackButton.backgroundColor = BearyColors.ink
            followBackButton.isEnabled = true
            followBackButton.alpha = 1
        case .canFollow:
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle("关注", for: .normal)
            followBackButton.accessibilityLabel = "关注"
            followBackButton.isAccessibilityElement = true
            followBackButton.backgroundColor = BearyColors.ink
            followBackButton.isEnabled = true
            followBackButton.alpha = 1
        case .loadFailed:
            // 拉取失败画“重试”不画“关注”：关系未知时点按只是重试拉取
            // （见 handleFollowBack），不把重试画成关注，避免用户误以为已关注。
            followBackButton.isHidden = false
            followProcessedLabel.isHidden = true
            followBackButton.setTitle("重试", for: .normal)
            followBackButton.isEnabled = true
            followBackButton.alpha = 1
        case .following:
            followBackButton.isHidden = true
            followProcessedLabel.isHidden = false
            followProcessedLabel.text = "已关注"
        case .mutual:
            followBackButton.isHidden = true
            followProcessedLabel.isHidden = false
            followProcessedLabel.text = "已互关"
        }
    }

    func hideFollowAction() {
        followBackHandler = nil
        followActionStack.isHidden = true
        followActionsTopConstraint?.constant = 0
        followActionsHeightConstraint?.isActive = true
        followProcessedLabel.isHidden = true
        // 第十三轮第 7 项：复用行先清标题与读屏名，加载态不留上一行的“回关”/“关注”。
        followBackButton.setTitle(nil, for: .normal)
        followBackButton.accessibilityLabel = nil
        followBackButton.isAccessibilityElement = false
    }

    @objc private func followBackTapped() {
        followBackHandler?()
    }
}

// MARK: - 行内 popper 动态画（第 17 项 B，网页 NB.popper 口径）

/// 网页定义来源：~/workspace/teddy_site/beary.html:1340（NB.popper）与 :85-86
///（nb-shake / nb-pb 关键帧 + .cn / .pb 规则），行内尺寸见 :96（.nt-sysava svg.nb 19px）。
/// 48 盒描边：stroke-width 2.2、round cap/join、fill none；炮身 .cn 两条路径
/// M7 41l8-24 16 16z 与 M12 29l8 8；彩带 .pb 六条短线，各带 --x/--y/--r。
/// 动画：炮身 nb-shake 2.8s（0/70/100% 转 0，76% -5°，84% 4°，92% -2°，
/// 原点 20% 90%）；彩带 nb-pb 2.8s（0/70% 不可见在原点，76% 现形，100%
/// 按 --x/--y 平移 + --r 旋转后消失），d2 延迟 .8s、d3 延迟 1.6s。
/// 颜色：行内 .nt-sysava 的 color 是橙（beary.html:699），故网页 currentColor
/// 在此上下文即橙；原生全程用 BearyColors.orange（固定色，深浅同值，
/// 不触动现有 tint 写法），不引入 SF 符号、不自创图形。
/// 减动效：与网页 prefers-reduced-motion 一致——炮身静止、彩带隐藏。
/// 自绘模式参照 App 内已有先例 BearyIconMotion（CAShapeLayer + 关键帧动画）。
private final class BearyPopperView: UIView {

    /// 彩带一条：48 盒起止点 + 飞散位移/旋转（网页 --x/--y/--r，单位=48 盒单位）+ 延迟。
    private struct Confetti {
        let from: CGPoint
        let to: CGPoint
        let dx: CGFloat
        let dy: CGFloat
        let rotation: CGFloat
        let delay: TimeInterval
    }

    private let confettiSpecs: [Confetti] = [
        Confetti(from: CGPoint(x: 26, y: 16), to: CGPoint(x: 27.6, y: 14.4), dx: 8, dy: -14, rotation: 80, delay: 0),
        Confetti(from: CGPoint(x: 30, y: 22), to: CGPoint(x: 32, y: 21), dx: 16, dy: -6, rotation: -60, delay: 0.8),
        Confetti(from: CGPoint(x: 22, y: 12), to: CGPoint(x: 22, y: 9.8), dx: -2, dy: -16, rotation: 50, delay: 1.6),
        Confetti(from: CGPoint(x: 29, y: 17), to: CGPoint(x: 30.4, y: 15.2), dx: 14, dy: -14, rotation: 110, delay: 1.6),
        Confetti(from: CGPoint(x: 31, y: 26), to: CGPoint(x: 33.2, y: 26.4), dx: 18, dy: 2, rotation: -90, delay: 0),
        Confetti(from: CGPoint(x: 25, y: 14), to: CGPoint(x: 25.8, y: 12), dx: 4, dy: -17, rotation: -50, delay: 0.8),
    ]

    private let cannonLayer = CALayer()
    private var confettiLayers: [CAShapeLayer] = []
    private var builtSize: CGSize = .zero
    private var animating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.size != builtSize else { return }
        builtSize = bounds.size
        buildLayers()
        if animating {
            start()
        }
    }

    /// 按当前框重建图层：48 盒路径等比缩放到框宽，线宽 2.2 同比缩放。
    private func buildLayers() {
        cannonLayer.removeFromSuperlayer()
        for layer in confettiLayers {
            layer.removeFromSuperlayer()
        }
        confettiLayers = []
        let scale = bounds.width / 48
        let lineWidth = 2.2 * scale
        let stroke = BearyColors.orange.cgColor

        cannonLayer.bounds = bounds
        cannonLayer.anchorPoint = CGPoint(x: 0.2, y: 0.9)
        cannonLayer.position = CGPoint(x: bounds.width * 0.2, y: bounds.height * 0.9)
        layer.addSublayer(cannonLayer)

        let bodyPath = UIBezierPath()
        bodyPath.move(to: CGPoint(x: 7, y: 41))
        bodyPath.addLine(to: CGPoint(x: 15, y: 17))
        bodyPath.addLine(to: CGPoint(x: 31, y: 33))
        bodyPath.close()
        bodyPath.apply(CGAffineTransform(scaleX: scale, y: scale))
        let bodyLayer = CAShapeLayer()
        bodyLayer.frame = bounds
        bodyLayer.path = bodyPath.cgPath
        bodyLayer.fillColor = UIColor.clear.cgColor
        bodyLayer.strokeColor = stroke
        bodyLayer.lineWidth = lineWidth
        bodyLayer.lineCap = .round
        bodyLayer.lineJoin = .round
        cannonLayer.addSublayer(bodyLayer)

        let fusePath = UIBezierPath()
        fusePath.move(to: CGPoint(x: 12, y: 29))
        fusePath.addLine(to: CGPoint(x: 20, y: 37))
        fusePath.apply(CGAffineTransform(scaleX: scale, y: scale))
        let fuseLayer = CAShapeLayer()
        fuseLayer.frame = bounds
        fuseLayer.path = fusePath.cgPath
        fuseLayer.fillColor = UIColor.clear.cgColor
        fuseLayer.strokeColor = stroke
        fuseLayer.lineWidth = lineWidth
        fuseLayer.lineCap = .round
        fuseLayer.lineJoin = .round
        cannonLayer.addSublayer(fuseLayer)

        for spec in confettiSpecs {
            let path = UIBezierPath()
            path.move(to: spec.from)
            path.addLine(to: spec.to)
            path.apply(CGAffineTransform(scaleX: scale, y: scale))
            let confettiLayer = CAShapeLayer()
            confettiLayer.frame = bounds
            confettiLayer.path = path.cgPath
            confettiLayer.fillColor = UIColor.clear.cgColor
            confettiLayer.strokeColor = stroke
            confettiLayer.lineWidth = lineWidth
            confettiLayer.lineCap = .round
            confettiLayer.lineJoin = .round
            confettiLayer.opacity = 0
            layer.addSublayer(confettiLayer)
            confettiLayers.append(confettiLayer)
        }
    }

    /// 开始 2.8s 无限循环动画；减动效时只留静态炮身，彩带保持隐藏。
    func start() {
        animating = true
        guard bounds.width > 0 else { return }
        if builtSize != bounds.size {
            buildLayers()
            builtSize = bounds.size
        }
        if UIAccessibility.isReduceMotionEnabled {
            stopAnimationsOnly()
            for confettiLayer in confettiLayers {
                confettiLayer.opacity = 0
            }
            return
        }
        cannonLayer.removeAnimation(forKey: "bearyPopperShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        shake.values = [0, 0, -5 * CGFloat.pi / 180, 4 * CGFloat.pi / 180, -2 * CGFloat.pi / 180, 0]
        shake.keyTimes = [0, 0.70, 0.76, 0.84, 0.92, 1]
        shake.duration = 2.8
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shake.repeatCount = .infinity
        cannonLayer.add(shake, forKey: "bearyPopperShake")

        let scale = bounds.width / 48
        for (index, confettiLayer) in confettiLayers.enumerated() {
            let spec = confettiSpecs[index]
            confettiLayer.removeAnimation(forKey: "bearyPopperBurst")
            confettiLayer.removeAnimation(forKey: "bearyPopperFade")
            let translation = CATransform3DMakeTranslation(spec.dx * scale, spec.dy * scale, 0)
            let rotation = CATransform3DMakeRotation(spec.rotation * CGFloat.pi / 180, 0, 0, 1)
            let burst = CAKeyframeAnimation(keyPath: "transform")
            burst.values = [
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: CATransform3DConcat(translation, rotation)),
            ]
            burst.keyTimes = [0, 0.70, 0.76, 1]
            burst.duration = 2.8
            burst.beginTime = CACurrentMediaTime() + spec.delay
            burst.repeatCount = .infinity
            confettiLayer.add(burst, forKey: "bearyPopperBurst")
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0, 1, 0]
            fade.keyTimes = [0, 0.70, 0.76, 1]
            fade.duration = 2.8
            fade.beginTime = CACurrentMediaTime() + spec.delay
            fade.repeatCount = .infinity
            confettiLayer.add(fade, forKey: "bearyPopperFade")
        }
    }

    private func stopAnimationsOnly() {
        cannonLayer.removeAnimation(forKey: "bearyPopperShake")
        for confettiLayer in confettiLayers {
            confettiLayer.removeAnimation(forKey: "bearyPopperBurst")
            confettiLayer.removeAnimation(forKey: "bearyPopperFade")
        }
    }

    /// 停动画并复位：炮身回正、彩带隐藏，供复用与切行时调用。
    func stop() {
        animating = false
        stopAnimationsOnly()
        for confettiLayer in confettiLayers {
            confettiLayer.opacity = 0
        }
    }
}

// MARK: - 哨兵 cell（翻页触发占位：忙时 16px 转圈，闲时不可见，失败时显重试文案）

class BearyNotificationTrailingCell: UITableViewCell {

    /// 忙时仅 16pt 官方刷新图标转圈（与网页 .more-sentinel 16px 同口径；2026-10-30
    /// 全 App 统一 icon_refresh，不再用 medium 圈 ×0.8 缩放）。
    private let spinner = BearyRefreshIconView()

    /// 112：失败态重试文案。哨兵闲时不可见，若失败态也全隐形，
    /// 用户无从发现可点按重试；只在失败态显形，闲时/到底了态不动。
    private let retryLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.text = "加载失败，点按重试"
        label.isHidden = true
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        contentView.addSubview(spinner)
        contentView.addSubview(retryLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            retryLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            retryLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            retryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            retryLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 哨兵 cell 已无描边钮，转圈颜色走 UIColor 动态解析，无需重刷。
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopSpinning()
        retryLabel.isHidden = true
    }

    /// 忙时仅 16px 转圈；闲时不可见、无按钮、无点击。
    func configureLoading() {
        retryLabel.isHidden = true
        spinner.isHidden = false
        spinner.startSpinning()
    }

    func configureIdle() {
        spinner.stopSpinning()
        spinner.isHidden = true
        retryLabel.isHidden = true
    }

    /// 112：失败态——藏转圈、显“加载失败，点按重试”，整行点按走
    /// didSelectRowAt 的失败重试分支；无更多页时本行不存在。
    func configureFailed() {
        spinner.stopSpinning()
        spinner.isHidden = true
        retryLabel.isHidden = false
    }
}

// MARK: - 通知详情页（合并列表卡面点按推的新页；独立通知页不用）
//
// 一张卡一页：标题为卡名（系统消息／互动消息），表内是该卡全部条目
// （items 原序倒序），每行与行 cell 同款（头像／名＋动词／摘要／时间），
// 关注行另带回关钮（状态与动作全走子页原有回关逻辑）。
// 行点按走子页 openItemForDetail 全套分流（进日记详情／个人页／会话／
// 信件整页），与合并行点按同口径；人名／头像点按：follow 行进个人页
// （原来整行点按就是进个人页，拆成独立按钮后行为不变；其余行人名不
// 另设按钮，整行点按目的地不变）。
// toast 改挂本页 view（viewWillAppear 改挂、viewWillDisappear 时由容器恢复，
// 见 onDetailWillDisappear）。
// 翻页追加的新条目：本页打开期间不实时追（回列表重进即见最新），
// 但从上层页返回时 viewWillAppear 重读卡快照补齐。

final class BearyNotificationDetailViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    private let card: NotifMergeCardData
    private let notifSource: BearyNotificationsData
    private let onDetailWillDisappear: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var items: [NotificationItem]

    init(
        card: NotifMergeCardData,
        notifSource: BearyNotificationsData,
        onDetailWillDisappear: (() -> Void)?
    ) {
        self.card = card
        self.notifSource = notifSource
        self.items = card.items
        self.onDetailWillDisappear = onDetailWillDisappear
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = card.title
        topBar.addSubview(titleLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        // 顶栏已是固定条、底 inset 手动补（viewDidLayoutSubviews），
        // 不自动叠加安全区内边距，免得手动值与系统值叠成双份。
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyNotificationCell.self, forCellReuseIdentifier: "BearyNotificationCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 模态全屏无底栏：表底只留安全区底＋16，不留 tab 页的 80。
        let bottom = 16 + view.safeAreaInsets.bottom
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.bottom = bottom
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从上层页返回时补齐翻页追加的新条目；toast 改挂本页。
        if let fresh = notifSource.mergeSnapshot.cards.first(where: { $0.kind == card.kind }) {
            items = fresh.items
            tableView.reloadData()
        }
        notifSource.toastOverride = { [weak self] message in
            guard let view = self?.view else { return }
            BearyToast.show(in: view, message: message)
        }
        // 单条标已读失败回滚：源页回滚只刷源表与合并快照，本页本地拷贝
        // 须另行改回未读并重画该行（见 applyLocalReadRollback）。
        notifSource.onSingleReadRollback = { [weak self] notificationId in
            self?.applyLocalReadRollback(notificationId: notificationId)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 详情页不在前台时不再接回滚通知；回页时 viewWillAppear 重读
        // 快照 reloadData，状态以源页为准。
        notifSource.onSingleReadRollback = nil
        // 容器恢复合并模式宿主（信件模态挂容器 view、toast 投容器 view）。
        onDetailWillDisappear?()
    }

    @objc private func backTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    /// 详情页回关钮状态刷新：只重配可见 follow 行的动作区，不 reloadRows
    ///（与子页 refreshFollowCardRows 同口径，避免整行闪一下）。
    func refreshFollowButtons(actorId: Int) {
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard path.row < items.count else { continue }
            let item = items[path.row]
            guard item.type == "follow", item.actorId == actorId,
                  let cell = tableView.cellForRow(at: path) as? BearyNotificationCell else { continue }
            cell.configureFollowCard(state: notifSource.followStateForDetail(actorId: actorId)) { [weak self] in
                self?.notifSource.performFollowBackForDetail(actorId: actorId)
            }
        }
    }

    /// 详情展开过渡的源行：带该 entryId 的通知行可见时返回 cell
    /// （供动画器快照 morph）；行不在视野内时返回 nil（动画器走兜底）。
    func detailSourceView(for entryId: String) -> UIView? {
        guard let row = items.firstIndex(where: { $0.entryId == entryId }) else { return nil }
        return tableView.cellForRow(at: IndexPath(row: row, section: 0))
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "BearyNotificationCell",
            for: indexPath
        ) as? BearyNotificationCell else {
            return UITableViewCell()
        }
        let item = items[indexPath.row]
        // 详情页行是顶层行（非嵌套）：头像 x=16、分隔线缩进 16、
        // 行高 72、头像垂直居中、标题／摘要间距 5，与私信行统一（mergedList）。
        cell.configure(with: item, nested: false, highlight: notifSource.highlightForDetail(item), mergedList: true)
        if item.type == "follow", let actorId = item.actorId {
            cell.configureFollowCard(state: notifSource.followStateForDetail(actorId: actorId)) { [weak self] in
                self?.notifSource.performFollowBackForDetail(actorId: actorId)
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        guard indexPath.row < items.count else { return }
        // 行点按全走子页原分流（乐观已读＋POST＋导航）：follow 行 → 容器
        // onOpenUser → 个人页（旧行为整行点按即进个人页，这里同口径，
        // 不另给人名／头像加独立按钮）；entry 行 → 日记详情；dm 行 →
        // 会话页；无 entry 的系统／信件行 → 信件模态（挂本页 view）。
        let tappedItem = items[indexPath.row]
        notifSource.openItemForDetail(tappedItem)
        // 乐观已读就地清点：源页 openNotification 只改源模型＋源表，
        // 本页 items 是 card.items 的值拷贝、源表也不在本页层级，点按后
        // 本页须自己同步本地拷贝并就地改该行 class（蓝点＋高亮），不
        // reloadRows；此前只靠 viewWillAppear 重进才 reloadData，故蓝点
        // 与高亮要点开、返回、再进才消失。
        applyLocalRead(itemId: tappedItem.id, at: indexPath)
    }

    /// 详情页乐观已读就地清点：只改本地拷贝与该可见行 class（与源页
    /// applyReadAppearanceToVisibleRows 同口径，不 reloadRows、不闪行）；
    /// 已读行／无 id 行不做任何事。
    private func applyLocalRead(itemId: Int?, at indexPath: IndexPath) {
        guard let itemId = itemId,
              indexPath.row < items.count,
              items[indexPath.row].id == itemId,
              (items[indexPath.row].read ?? true) == false else { return }
        items[indexPath.row].read = true
        guard let cell = tableView.cellForRow(at: indexPath) as? BearyNotificationCell else { return }
        let item = items[indexPath.row]
        let isSystemStyle = item.type == "system" || item.type == "letter"
        // 已读后高亮判定恒 false（shouldHighlight 先判 read），直接灭。
        cell.setReadAppearance(isUnread: false, isSystemStyle: isSystemStyle, highlight: false)
    }

    /// 左滑删除单条通知：只给「删除」一个红色动作（卡片本身不加左滑）。
    /// 无 id 的行不删。本地先行移除＋淡出，源页同步删（未读数／快照／缓存
    /// 一并走源页）；服务端失败时源页回滚＋toast，本页按 completion 把行
    /// 插回原位。减动效时行直接消失／出现，不播淡入淡出。
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < items.count,
              let notificationId = items[indexPath.row].id else { return nil }
        let item = items[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self = self else { done(false); return }
            BearyHaptics.press()
            self.items.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: BearyMotion.animated(true) ? .fade : .none)
            self.notifSource.deleteNotification(id: notificationId) { [weak self] success in
                guard let self = self else { return }
                if success { return }
                // 失败回滚：源页已把行插回源列表，本页按时间倒序插回本地拷贝；
                // 行已回来（重进页重读快照）时不重复插。
                guard self.items.firstIndex(where: { $0.id == notificationId }) == nil else { return }
                let insertAt = self.items.firstIndex(where: {
                    ($0.createdAt ?? 0) < (item.createdAt ?? 0)
                        || (($0.createdAt ?? 0) == (item.createdAt ?? 0) && ($0.id ?? 0) < notificationId)
                }) ?? self.items.count
                self.items.insert(item, at: insertAt)
                self.tableView.insertRows(at: [IndexPath(row: insertAt, section: 0)], with: BearyMotion.animated(true) ? .fade : .none)
            }
            done(true)
        }
        delete.accessibilityLabel = "删除这条通知"
        return UISwipeActionsConfiguration(actions: [delete])
    }

    /// 单条标已读失败回滚：把本地拷贝改回未读并重画该行（只改该行 class，
    /// 不 reloadRows）；行已不在本页列表时不做任何事（回页重读快照为准）。
    private func applyLocalReadRollback(notificationId: Int) {
        guard let row = items.firstIndex(where: { $0.id == notificationId }),
              (items[row].read ?? true) == true else { return }
        items[row].read = false
        let indexPath = IndexPath(row: row, section: 0)
        guard let cell = tableView.cellForRow(at: indexPath) as? BearyNotificationCell else { return }
        let item = items[row]
        let isSystemStyle = item.type == "system" || item.type == "letter"
        cell.setReadAppearance(isUnread: true, isSystemStyle: isSystemStyle, highlight: notifSource.highlightForDetail(item))
    }
}
