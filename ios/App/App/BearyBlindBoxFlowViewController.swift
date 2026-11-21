import UIKit

// ===== 盲盒交换流程页（全屏 modal，反馈页 / 许愿墙同款：fullScreen + fadeRise）=====
// 步骤（2026-11-18 Li 批准重设计预览，Space mang-he-ye-zhong-she-ji-yu-lan）：
// 登录提示（游客）→ 开始屏（去交换：三步说明＋“选一篇日记”）→ 选篇底 sheet
// （自己的旧公开篇，私密 / 当日新公开置灰禁用）→ 点篇即入池并立即开盒
// → 收到匿名卡（仅小熊回应；无评论、无作者名、无主页入口、无追踪、无私信、
// 无分享、无引用、无点赞、无收藏）→ 撤回 / 举报；池空时进等待屏（已投出卡＋
// “刷新状态”重试开盒＋撤回）。先入池再开盒的口径不变（U5），只是两次点按并成
// 一次；等待屏的撤回需服务端新端点 POST /beary/api/blindbox/unpool（未部署
// 前点按报“撤回失败，请重试”，见 BearyBlindBox.swift）。
// 匿名保证：本页永不渲染作者信息，也不调用通用 /entries/:id/emote（见 BearyBlindBox
// 文件头 U1）；举报走既有 BearyReportFlow（只传 entry_id），举报成功后本篇对举报人
// 变占位；拉黑需要作者 id，匿名卡上无法提供——举报后消失即为匿名场景下的等价防护，
// 见回报里的拉黑口径说明。收到篇图片只走站内 BearyImageURLs（白名单内），不拼外链。
// 失败诚实口径：404 时显示“盲盒暂时无法加载”，不编造开盒结果；
// 每日已换（409）时 toast 并重拉当日状态；撤回后计数不返还（暂定 U2）。
// 交换池空：POST /open 无可抽对象时服务端回 400 {error: "pool_empty"}（经
// BearyAPI.mapStatus 解为 .server("pool_empty")），开盒失败分支特判它，toast +
// 开盒提示行同文持久显示，不落通用“开盒失败，请重试”；池空不消耗次数、
// 不清已入池的自己那篇，重进 / 再入池后提示行由原有逻辑复写。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。

/// 小熊回应 chip：BearyButton 工厂款 + emoteKey 属性（不用 accessibilityLabel 夹带 key，
/// 无障碍文案保持“小熊回应”可读）。
private final class BlindBoxEmoteChipButton: BearyButton {
    var emoteKey = ""
}

/// 选篇底 sheet 里的日记行（重设计预览口径）：透明底、无卡片，行顶一条发丝线
/// （首行无）；上行日期（12.5 弱文）、下行正文（15.5 两行截断）；不可入池的行
/// 另附一行灰字原因并整行降透明度、点按无反应。可入池的行不挂 pill（入池资格
/// 即公开，无需再标）；点按即入池＋开盒，不留选中态。
private final class BlindBoxPoolRowView: UIView {
    var onTap: (() -> Void)?

    private let hairline = UIView()
    private let mainLabel = UILabel()
    private let subLabel = UILabel()
    private let reasonLabel = UILabel()
    private let tapButton = BearyHit44Button(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.cornerRadius = 0
        layer.borderWidth = 0
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = BearyColors.blindBoxLineSoft

        mainLabel.translatesAutoresizingMaskIntoConstraints = false
        mainLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        mainLabel.adjustsFontForContentSizeCategory = true
        mainLabel.textColor = BearyColors.blindBoxMuted
        mainLabel.numberOfLines = 1

        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15.5))
        subLabel.adjustsFontForContentSizeCategory = true
        subLabel.textColor = BearyColors.ink
        subLabel.numberOfLines = 2

        reasonLabel.translatesAutoresizingMaskIntoConstraints = false
        reasonLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        reasonLabel.adjustsFontForContentSizeCategory = true
        reasonLabel.textColor = BearyColors.blindBoxMuted
        reasonLabel.numberOfLines = 1
        reasonLabel.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [mainLabel, subLabel, reasonLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        addSubview(textStack)

        tapButton.translatesAutoresizingMaskIntoConstraints = false
        tapButton.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        tapButton.bearyAddPressFeedback()
        addSubview(tapButton)

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap?()
    }

    /// showsHairline 为假时首行不画顶线；selected 参数已无选中态，仅保留调用方
    /// 签名兼容（调用处传 false），内部不使用。
    func configure(entry: Entry, selected: Bool, showsHairline: Bool = true) {
        hairline.isHidden = !showsHairline
        let flat = (entry.content ?? "").replacingOccurrences(of: "\n", with: " ")
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = title.isEmpty ? (flat.isEmpty ? "（无正文）" : flat) : title
        subLabel.text = body
        let dateText = BlindBoxDate.displayString(ms: entry.publishedAt ?? entry.createdAt)
        mainLabel.text = dateText
        let eligibility = BlindBoxPool.eligibility(for: entry)
        switch eligibility {
        case .eligible:
            reasonLabel.isHidden = true
            alpha = 1
            tapButton.isEnabled = true
        case .privateEntry, .tooNew:
            reasonLabel.text = eligibility.disabledReason
            reasonLabel.isHidden = false
            alpha = 0.55
            tapButton.isEnabled = false
        }
    }
}

/// 盲盒 sheet 通用 chrome：顶圆角 20＋抓手（BearySheetChrome），底色预览 sheet 底。
/// 调用方在 viewDidLoad 里调一次，返回抓手视图（内容顶缘贴它）。
private func blindBoxSheetAddChrome(to view: UIView) -> UIView {
    view.backgroundColor = BearyColors.blindBoxSheetBg
    view.layer.cornerRadius = BearySheetChrome.topCornerRadius
    view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    view.layer.masksToBounds = true
    let grabber = UIView()
    grabber.translatesAutoresizingMaskIntoConstraints = false
    grabber.backgroundColor = BearyColors.gray
    grabber.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
    view.addSubview(grabber)
    NSLayoutConstraint.activate([
        grabber.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
        grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        grabber.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
        grabber.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),
    ])
    return grabber
}

/// 盲盒 sheet 内容高：按当前宽度算压缩高（调用方在 viewDidLayoutSubviews
/// 与内容变化后调，推给 preferredContentSize；容器按它定 sheet 高、88% 封顶）。
private func blindBoxSheetFittingHeight(for view: UIView) -> CGFloat {
    let width = view.bounds.width > 0 ? view.bounds.width : 375
    let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
    let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    return ceil(size.height)
}

/// 盲盒 sheet 呈现（共享底 sheet 容器口径，与 BearyConfirmSheet.show 同款）：
/// .custom＋BearyBottomSheetTransitioningDelegate（sheet 自己强持有 delegate）。
private protocol BlindBoxSheetPresentable: AnyObject {
    var sheetDelegate: BearyBottomSheetTransitioningDelegate? { get set }
}

private func showBlindBoxSheet<T: UIViewController>(_ sheet: T, from presenter: UIViewController) where T: BlindBoxSheetPresentable {
    guard presenter.presentedViewController == nil, presenter.view.window != nil else { return }
    let delegate = BearyBottomSheetTransitioningDelegate()
    sheet.sheetDelegate = delegate
    sheet.modalPresentationStyle = .custom
    sheet.transitioningDelegate = delegate
    presenter.present(sheet, animated: BearyMotion.animated(true))
}

/// 小熊回应 chip（重设计预览口径）：44 高药丸，左 34 圆面（熊脸圆面底＋30 熊脸图），
/// 右侧名字＋计数（15 semibold）；自己贴过的走墨底＋浅字。点按即切换自己的回应。
private final class BlindBoxEmoteChipView: UIControl {
    var emoteKey = ""
    var onTap: (() -> Void)?

    private let discView = UIView()
    private let faceView = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 22
        layer.borderWidth = 1
        layer.masksToBounds = true
        backgroundColor = BearyColors.blindBoxSurface2
        layer.bearyDynamicBorderColor = BearyColors.blindBoxLine

        discView.translatesAutoresizingMaskIntoConstraints = false
        discView.backgroundColor = BearyColors.blindBoxBearDisc
        discView.layer.cornerRadius = 17
        discView.clipsToBounds = true
        faceView.translatesAutoresizingMaskIntoConstraints = false
        faceView.contentMode = .scaleAspectFit
        discView.addSubview(faceView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.ink
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = BearyColors.ink
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [discView, nameLabel, countLabel])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            discView.widthAnchor.constraint(equalToConstant: 34),
            discView.heightAnchor.constraint(equalToConstant: 34),
            faceView.widthAnchor.constraint(equalToConstant: 30),
            faceView.heightAnchor.constraint(equalToConstant: 30),
            faceView.centerXAnchor.constraint(equalTo: discView.centerXAnchor),
            faceView.centerYAnchor.constraint(equalTo: discView.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        bearyAddPressFeedback()
        accessibilityLabel = "小熊回应"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap?()
    }

    /// face 为调用方按底色缩好的 30pt 熊脸图（mine 态按墨底取深色版，其余按主题取）。
    func configure(key: String, name: String, count: Int, mine: Bool, face: UIImage?) {
        emoteKey = key
        nameLabel.text = name
        countLabel.text = "\(count)"
        faceView.image = face
        if mine {
            backgroundColor = BearyColors.blindBoxChipDark
            layer.bearyDynamicBorderColor = BearyColors.blindBoxChipDark
            nameLabel.textColor = BearyColors.blindBoxChipDarkText
            countLabel.textColor = BearyColors.blindBoxChipDarkText
        } else {
            backgroundColor = BearyColors.blindBoxSurface2
            layer.bearyDynamicBorderColor = BearyColors.blindBoxLine
            nameLabel.textColor = BearyColors.ink
            countLabel.textColor = BearyColors.ink
        }
    }
}

/// chip 自动换行容器（预览口径 flex-wrap）：横向排布、间距 8、行距 8，超宽换行；
/// 高度随内容走（intrinsicContentSize）。
private final class BlindBoxChipFlowView: UIView {
    private var cachedHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func flowHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0, subviews.isEmpty == false else { return 0 }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(CGSize(width: width, height: 44))
            let w = min(size.width, width)
            if x > 0, x + w > width {
                x = 0
                y += lineHeight + 8
                lineHeight = 0
            }
            x += w + 8
            lineHeight = max(lineHeight, 44)
        }
        return y + lineHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        let maxWidth = bounds.width
        for sub in subviews {
            let size = sub.sizeThatFits(CGSize(width: maxWidth, height: 44))
            let w = min(size.width, maxWidth)
            if x > 0, x + w > maxWidth {
                x = 0
                y += lineHeight + 8
                lineHeight = 0
            }
            sub.frame = CGRect(x: x, y: y, width: w, height: 44)
            x += w + 8
            lineHeight = max(lineHeight, 44)
        }
        let total = subviews.isEmpty ? 0 : y + lineHeight
        if total != cachedHeight {
            cachedHeight = total
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: flowHeight(forWidth: bounds.width > 0 ? bounds.width : 0))
    }
}

/// 贴小熊选择器（重设计预览口径）：6 只熊 3 列网格，每格 96 高、46 圆面＋名字；
/// 点按即选（调用方 onPick 拿 key），无最近使用区。6 只 key 按官方资产像素核对，
/// 名字走预览文案（与 moodNames 不完全同名：爱心／开心／微笑／惊喜）。
private final class BlindBoxBearPickerSheetViewController: UIViewController, BlindBoxSheetPresentable {
    var onPick: ((String) -> Void)?
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?

    private let bears: [(key: String, name: String)] = [
        ("hug", "抱抱"), ("love", "爱心"), ("wink", "开心"),
        ("happy", "微笑"), ("comfort", "安慰"), ("surprised", "惊喜"),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        let grabber = blindBoxSheetAddChrome(to: view)
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "贴一只小熊"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        let subLabel = UILabel()
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.text = "选一只，贴到这篇日记上"
        subLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5))
        subLabel.adjustsFontForContentSizeCategory = true
        subLabel.textColor = BearyColors.blindBoxMuted
        subLabel.textAlignment = .center
        view.addSubview(titleLabel)
        view.addSubview(subLabel)

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        for rowIndex in 0..<2 {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for colIndex in 0..<3 {
                let bear = bears[rowIndex * 3 + colIndex]
                row.addArrangedSubview(makeCell(key: bear.key, name: bear.name))
            }
            grid.addArrangedSubview(row)
        }
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            subLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            grid.topAnchor.constraint(equalTo: subLabel.bottomAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            grid.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = blindBoxSheetFittingHeight(for: view)
        if preferredContentSize.height != height {
            preferredContentSize = CGSize(width: view.bounds.width, height: height)
        }
    }

    private func makeCell(key: String, name: String) -> UIView {
        let cell = UIView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.backgroundColor = BearyColors.blindBoxSurface2
        cell.layer.cornerRadius = 16
        cell.layer.borderWidth = 1
        cell.layer.bearyDynamicBorderColor = BearyColors.blindBoxLineSoft
        cell.clipsToBounds = true
        let disc = UIView()
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.backgroundColor = BearyColors.blindBoxBearDisc
        disc.layer.cornerRadius = 23
        disc.clipsToBounds = true
        let face = UIImageView()
        face.translatesAutoresizingMaskIntoConstraints = false
        face.contentMode = .scaleAspectFit
        // 圆面恒为浅色熊脸底：恒取浅色版（深色线稿），深浅两模式皆然。
        if let image = BearyEmoteImages.image(for: key, dark: false) {
            face.image = BearyBlindBoxFlowViewController.chipEmoteImage(image, side: 40)
        }
        disc.addSubview(face)
        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.text = name
        nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.blindBoxInk2
        nameLabel.textAlignment = .center
        cell.addSubview(disc)
        cell.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            cell.heightAnchor.constraint(equalToConstant: 96),
            disc.widthAnchor.constraint(equalToConstant: 46),
            disc.heightAnchor.constraint(equalToConstant: 46),
            disc.topAnchor.constraint(equalTo: cell.topAnchor, constant: 14),
            disc.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            face.widthAnchor.constraint(equalToConstant: 40),
            face.heightAnchor.constraint(equalToConstant: 40),
            face.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            face.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            nameLabel.topAnchor.constraint(equalTo: disc.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -11),
        ])
        let tap = BearyHit44Button(type: .custom)
        tap.translatesAutoresizingMaskIntoConstraints = false
        tap.accessibilityLabel = "贴一只「\(name)」小熊"
        tap.addTarget(self, action: #selector(cellTouchDown(_:)), for: .touchDown)
        tap.addTarget(self, action: #selector(cellTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        tap.addTarget(self, action: #selector(cellTouchUp(_:)), for: .touchDragEnter)
        tap.bearyAddPressFeedback()
        tap.tag = bears.firstIndex(where: { $0.key == key }) ?? 0
        tap.addTarget(self, action: #selector(cellTapped(_:)), for: .touchUpInside)
        cell.addSubview(tap)
        NSLayoutConstraint.activate([
            tap.topAnchor.constraint(equalTo: cell.topAnchor),
            tap.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            tap.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            tap.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }

    @objc private func cellTouchDown(_ sender: UIButton) {
        sender.superview?.layer.bearyDynamicBorderColor = BearyColors.blindBoxAccent
    }

    @objc private func cellTouchUp(_ sender: UIButton) {
        sender.superview?.layer.bearyDynamicBorderColor = BearyColors.blindBoxLineSoft
    }

    @objc private func cellTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < bears.count else { return }
        dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            self?.onPick?(self?.bears[index].key ?? "")
        }
    }
}

/// 选一篇旧日记底 sheet（重设计预览口径）：标题＋副文案＋可滚列表（BlindBoxPoolRowView
/// 行，发丝线分隔）；列表由流程页驱动渲染（行／加载更多／空态／加载态），点行即选。
private final class BlindBoxPickDiarySheetViewController: UIViewController, BlindBoxSheetPresentable {
    var onPick: ((Entry) -> Void)?
    var onLoadMore: (() -> Void)?
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?

    private let stateArea = UIView()
    private let scrollView = UIScrollView()
    private let listStack = UIStackView()
    private let loadMoreButton = BearyButton(style: .secondaryOutline(.compact))
    private let emptyLabel = UILabel()
    private let spinner = BearyRefreshIconView()
    private var stateHeightConstraint: NSLayoutConstraint?
    private var scrollBottomConstraint: NSLayoutConstraint?
    private var loadMoreBottomConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        let grabber = blindBoxSheetAddChrome(to: view)
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "选一篇旧日记"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        let subLabel = UILabel()
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.text = "只有你选的这一篇会被送出去"
        subLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5))
        subLabel.adjustsFontForContentSizeCategory = true
        subLabel.textColor = BearyColors.blindBoxMuted
        subLabel.textAlignment = .center
        view.addSubview(titleLabel)
        view.addSubview(subLabel)

        // 状态区：列表／空态／加载态三者同一块位置，高度由内容定（列表拟合高封顶、
        // 空态与加载态固定 120），超限时列表内部滚动。
        stateArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateArea)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        listStack.axis = .vertical
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(listStack)
        stateArea.addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = BearyColors.blindBoxMuted
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.text = "还没有可入池的日记：先写一篇并公开它（当日公开的需等明日）。"
        emptyLabel.isHidden = true
        stateArea.addSubview(emptyLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.tintColor = BearyColors.ink
        spinner.widthAnchor.constraint(equalToConstant: 20).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 20).isActive = true
        spinner.isHidden = true
        stateArea.addSubview(spinner)

        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false
        loadMoreButton.addTarget(self, action: #selector(loadMoreTapped), for: .touchUpInside)
        loadMoreButton.bearyAddPressFeedback()
        loadMoreButton.isHidden = true
        view.addSubview(loadMoreButton)

        stateHeightConstraint = stateArea.heightAnchor.constraint(equalToConstant: 0)
        scrollBottomConstraint = stateArea.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        loadMoreBottomConstraint = loadMoreButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        loadMoreBottomConstraint?.isActive = false
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            subLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stateArea.topAnchor.constraint(equalTo: subLabel.bottomAnchor, constant: 10),
            stateArea.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stateArea.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stateHeightConstraint!,
            scrollBottomConstraint!,
            scrollView.topAnchor.constraint(equalTo: stateArea.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: stateArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stateArea.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: stateArea.bottomAnchor),
            listStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            listStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: stateArea.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: stateArea.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: stateArea.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: stateArea.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: stateArea.centerYAnchor),
            loadMoreButton.topAnchor.constraint(equalTo: stateArea.bottomAnchor, constant: 12),
            loadMoreButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadMoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 状态区高度：列表时为行栈拟合高（上限 70% 屏高减去标题区与底部留白），
    /// 空态／加载态固定 120；超限时列表内部滚动。
    private func updatePreferredContentSize() {
        let maxSheetHeight = UIScreen.main.bounds.height * 0.7
        let chromeHeight: CGFloat = 10 + 4 + 14 + 21 + 6 + 18 + 10 + 12 + 36 + 20
        let stackWidth = view.bounds.width > 0 ? view.bounds.width - 44 : 331
        let stackHeight = listStack.systemLayoutSizeFitting(
            CGSize(width: stackWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        let listHeight: CGFloat
        if scrollView.isHidden {
            listHeight = 120
        } else {
            listHeight = min(stackHeight, max(0, maxSheetHeight - chromeHeight))
        }
        if stateHeightConstraint?.constant != listHeight {
            stateHeightConstraint?.constant = listHeight
        }
        let height = blindBoxSheetFittingHeight(for: view)
        if preferredContentSize.height != height {
            preferredContentSize = CGSize(width: view.bounds.width, height: height)
        }
    }

    /// 渲染行（调用方在列表变化时调；空列表走空态，加载态时调 showLoading）。
    /// 点按回调走 onPick 属性（presentPickSheet 处一次性挂好），不在每次渲染时重传。
    func setRows(_ entries: [Entry]) {
        guard entries.isEmpty == false else {
            showEmpty()
            return
        }
        for sub in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        emptyLabel.isHidden = true
        spinner.isHidden = true
        spinner.stopSpinning()
        scrollView.isHidden = entries.isEmpty
        for (index, entry) in entries.enumerated() {
            let row = BlindBoxPoolRowView()
            row.configure(entry: entry, selected: false, showsHairline: index > 0)
            row.onTap = { [weak self] in self?.onPick?(entry) }
            listStack.addArrangedSubview(row)
        }
        updatePreferredContentSize()
    }

    func showEmpty() {
        for sub in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        scrollView.isHidden = true
        spinner.isHidden = true
        spinner.stopSpinning()
        emptyLabel.isHidden = false
        setLoadMoreVisible(false, title: nil)
        updatePreferredContentSize()
    }

    func showLoading() {
        for sub in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        scrollView.isHidden = true
        emptyLabel.isHidden = true
        spinner.isHidden = false
        spinner.startSpinning()
        setLoadMoreVisible(false, title: nil)
        updatePreferredContentSize()
    }

    func setLoadMoreVisible(_ visible: Bool, title: String?) {
        loadMoreButton.isHidden = !visible
        // 加载更多隐藏时状态区直贴底边，不留按钮空位；显示时按钮接在状态区下方。
        scrollBottomConstraint?.isActive = !visible
        loadMoreBottomConstraint?.isActive = visible
        if let title = title {
            loadMoreButton.setTitle(title, for: .normal)
        }
        updatePreferredContentSize()
    }

    @objc private func loadMoreTapped() {
        onLoadMore?()
    }
}

/// 撤回／举报确认底 sheet（重设计预览口径）：居中标题＋居中副文案，纵排两钮——
/// 上为危险钮（危险浅底＋危险字），下为“再想想”（次面底＋墨字）。
private final class BlindBoxConfirmSheetViewController: UIViewController, BlindBoxSheetPresentable {
    var onConfirm: (() -> Void)?
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?

    private let sheetTitle: String
    private let sheetMessage: String
    private let confirmTitle: String

    init(title: String, message: String, confirmTitle: String, onConfirm: (() -> Void)? = nil) {
        self.sheetTitle = title
        self.sheetMessage = message
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let grabber = blindBoxSheetAddChrome(to: view)
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = sheetTitle
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        let messageLabel = UILabel()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = sheetMessage
        messageLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5))
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = BearyColors.blindBoxMuted
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        view.addSubview(titleLabel)
        view.addSubview(messageLabel)

        let confirmButton = UIButton(type: .custom)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.setTitle(confirmTitle, for: .normal)
        confirmButton.setTitleColor(BearyColors.blindBoxDanger, for: .normal)
        confirmButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15.5, weight: .semibold))
        confirmButton.titleLabel?.adjustsFontForContentSizeCategory = true
        confirmButton.backgroundColor = BearyColors.blindBoxDangerTint
        confirmButton.layer.cornerRadius = 13
        confirmButton.layer.masksToBounds = true
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.bearyAddPressFeedback()
        let cancelButton = UIButton(type: .custom)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("再想想", for: .normal)
        cancelButton.setTitleColor(BearyColors.ink, for: .normal)
        cancelButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15.5, weight: .semibold))
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.backgroundColor = BearyColors.blindBoxSurface2
        cancelButton.layer.cornerRadius = 13
        cancelButton.layer.masksToBounds = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.bearyAddPressFeedback()
        view.addSubview(confirmButton)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            confirmButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 18),
            confirmButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            confirmButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            confirmButton.heightAnchor.constraint(equalToConstant: 50),
            cancelButton.topAnchor.constraint(equalTo: confirmButton.bottomAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            cancelButton.heightAnchor.constraint(equalToConstant: 50),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = blindBoxSheetFittingHeight(for: view)
        if preferredContentSize.height != height {
            preferredContentSize = CGSize(width: view.bounds.width, height: height)
        }
    }

    @objc private func confirmTapped() {
        dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            self?.onConfirm?()
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }
}

final class BearyBlindBoxFlowViewController: UIViewController {

    private enum Step {
        case loading
        case login
        case pool
        case waiting
        case received
        case placeholder(String)
        case mineWithdrawn
        case error(String)
    }

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var colCapConstraints: [NSLayoutConstraint] = []

    private let spinner = BearyRefreshIconView()
    private let spinnerWrap = UIView()
    /// 加载容器高度：有状态文案时 50（转圈 20＋文案行），只有转圈时 30。
    private var spinnerWrapHeightConstraint: NSLayoutConstraint?
    /// 加载态文案——只有交换 ID、还没拿到正文时写「已换到，
    /// 正在加载」；其余加载不写文案、只有转圈。由 setStep(.loading) 消费一次。
    private let loadingLabel = UILabel()
    private var loadingStatusText: String?
    /// 导航栏右上角刷新（重设计预览口径）：44 圆钮＋19pt 官方刷新图标，
    /// 点按旋转一圈并静默刷新当前状态；三屏共用。
    private let refreshNavButton = BearyHit44Button(type: .system)

    // 开始屏（去交换：hero＋大标题＋导语＋三步＋“选一篇日记”墨底主钮）
    private let startView = UIView()
    private let pickButton = UIButton(type: .custom)

    // 等待屏（已投出卡＋“刷新状态”墨底主钮＋撤回文字钮＋等待配对状态行）
    private let waitingView = UIView()
    private let sentCard = UIView()
    private let sentMetaLabel = UILabel()
    private let sentBodyLabel = UILabel()
    private let waitingRefreshButton = UIButton(type: .custom)
    private let waitingWithdrawButton = UIButton(type: .system)
    private let waitingStatusLabel = UILabel()
    private let waitingStatusDot = UIView()

    // 收到屏（陌生人 meta 行＋正文＋发丝线＋收到的小熊＋chip＋贴熊主钮＋
    // 举报／撤回文字钮＋交换已完成状态行）；无灰卡，内容直接落纸面。
    private let receivedView = UIView()
    private let receivedAvatarView = UIView()
    private let receivedMetaNameLabel = UILabel()
    private let receivedDateLabel = UILabel()
    private let receivedTitleLabel = UILabel()
    private let receivedContentLabel = UILabel()
    private let imagesStack = UIStackView()
    private let receivedHairline = UIView()
    private let emoteSectionLabel = UILabel()
    private let emoteFlowView = BlindBoxChipFlowView()
    private let emotePrimaryButton = UIButton(type: .custom)
    private let reportTextButton = UIButton(type: .system)
    private let withdrawTextButton = UIButton(type: .system)
    private let receivedStatusLabel = UILabel()
    private let receivedStatusDot = UIView()
    /// 收到屏竖栈与 meta 行（showReceived／renderReceivedImages 按标题／图片
    /// 有无改自定义间距时要拿到它们）。
    private let receivedStack = UIStackView()
    private let receivedMetaRow = UIStackView()
    /// 三屏最小高度（预览 .actions{margin-top:auto} 的 App 版：屏高至少
    /// scrollView 高 −24，屏内弹性空白把主钮推到底；内容长时自然撑高、
    /// 页内可滚）。setStep 里只激活当前屏那条，隐藏屏的不激活。
    private var startMinHeightConstraint: NSLayoutConstraint?
    private var waitingMinHeightConstraint: NSLayoutConstraint?
    private var receivedMinHeightConstraint: NSLayoutConstraint?

    private let placeholderLabel = UILabel()
    private let placeholderView = UIView()
    private let mineWithdrawnLabel = UILabel()
    private let mineWithdrawnView = UIView()
    private let loginView = UIView()
    private let loginButton = BearyButton.make(style: .primaryPill(.ink), title: "登录")
    // 失败态走 BearyStateView（文案随 .error 文本走副文案、常规描边重试钮，动作复用 retryTapped）。
    private let errorStateView = BearyStateView()

    /// 选篇底 sheet（打开时持有，关闭后置空；列表渲染以它为目标）。
    private weak var pickSheet: BlindBoxPickDiarySheetViewController?
    /// 状态更新时间（收到／等待两屏状态行“状态更新于 H:mm”）：进入两屏与每次
    /// 刷新成功时记为当前时间；预览初始 14:13 为写死演示数据，真机走实际时间。
    private var lastStatusUpdate: Date?
    /// 刚贴上的小熊 key：renderEmoteChips 后对它播一次 chipIn 弹入，随即清掉。
    private var justAddedEmoteKey: String?
    /// 选篇列表是否正在拉取（sheet 打开时据此显示加载态／空态）。
    private var poolListLoading = false
    /// 状态刷新在途守卫（导航刷新／等待屏“刷新状态”共用，防重复点按）。
    private var statusRefreshing = false
    /// 等待屏已投出卡直取兜底的去重键：已按该入池 id 直取过一次后不再重复取。
    private var waitingCardFetchedEntryId: String?

    private var step: Step = .loading
    private var poolEntries: [Entry] = []
    /// R22 #10：入池分页上限与“够选即停”目标——每页 50 篇；集满 20 篇可入池篇
    /// 即停（常见账号 1~2 页收尾），否则续拉到 40 页（2000 篇）或服务端短页为止。
    private static let poolMaxPages = 40
    private static let poolEligibleTarget = 20
    /// 审计登录杂项：入池分页代次 / 收集集 / 去重集（照搬星图页游标分页口径）。
    private var poolLoadGeneration = 0
    private var poolCollected: [Entry] = []
    private var poolSeenIds = Set<String>()
    /// 选篇分页触顶/中断状态（第八轮审计 02，地图 #944 同款口径）：每批上限
    /// 40 页（poolMaxPages）防无界；触顶时记 poolCapped 并留游标，页内留“加载更多”入口供按需
    /// 续拉新一批；分页中途失败时记 poolInterrupted 并留失败页游标，页内留
    /// “重试”入口从中断处续拉，不直接把部分结果当完整。
    private var poolCapped = false
    private var poolInterrupted = false
    private var poolResumeBefore: Int?
    private var poolResumeBeforeId: String?
    private var poolResumePage = 1
    private var pooledEntryId: String?
    private var exchangeId: String?
    private var received: BlindBoxReceivedEntry?
    private var receivedEmotes: [EmoteCount] = []
    /// 选篇点按在途守卫（入池＋开盒同一轮）：点按即入池并立即开盒，整轮未完不接受再点。
    private var poolBusy = false
    private var withdrawBusy = false
    private var reactBusy = false
    /// 审计新一轮 02：详情请求代次——每次发详情请求即 +1，撤回成功再 +1；
    /// 在途旧回包凭代次丢弃，不再把已撤回的界面倒退回 .received
    ///（只比交换 ID 不够——同一交换的旧回包仍可能带着撤回前的状态回来）。
    private var exchangeDetailGeneration: UInt64 = 0
    private var hasLoadedOnce = false
    /// 盲盒请求代次（第九轮 #1＋#3）：每次新发盲盒请求（today / 详情 /
    /// 入池 / 开盒 / 撤回 / 回应）递增；回包先核对发起账号与代次，过期
    /// 回包一律丢弃，不更新 UI、不写 BlindBoxState。
    private var blindBoxGeneration = 0
    /// 当前交换被举报 / 撤回后置 true：旧详情回包不得再把页面翻回 .received。
    private var exchangeHidden = false

    /// A2：请求快照——发请求时绑定账号、会话代次与北京日期；回包先比对，
    /// 任一变化即旧回包作废、重查当前状态，不写进当前桶。只在调用方比对，
    /// 不改传输层重试逻辑（BearyAPI 首发捕获的 epoch / 账号只用于重试与
    /// 401 压制，成功路径的比对在这里做）。
    private struct BlindBoxRequestSnapshot {
        var epoch: Int
        var accountId: Int?
        var dateKey: String
    }

    private static func captureBlindBoxSnapshot() -> BlindBoxRequestSnapshot {
        return BlindBoxRequestSnapshot(epoch: BearyAPI.shared.authEpoch, accountId: BearyAPI.shared.authAccountId, dateKey: BlindBoxDate.todayKey())
    }

    private func isStaleBlindBoxSnapshot(_ snapshot: BlindBoxRequestSnapshot) -> Bool {
        return snapshot.epoch != BearyAPI.shared.authEpoch
            || snapshot.accountId != BearyAPI.shared.authAccountId
            || snapshot.dateKey != BlindBoxDate.todayKey()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.blindBoxSurface
        buildChrome()
        buildSections()
        NotificationCenter.default.addObserver(self, selector: #selector(handleReported), name: .bearyDidReportEntry, object: nil)
        loadInitial()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 仅 iPad 且宽 ≥821 才激活 600 上限（iPhone 横屏走全宽）。
        let wantCap = BearyDesktop.isWide(view.bounds.width)
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        // 回应 chip 创建时按当时 trait 取了深浅两套独立 PNG（原色图、非
        // template 图，tint 改不了它），此前全文件无 trait handler，主题
        // 变化后仍是旧深浅素材。主题变时重建 chips，重选现有官方素材；
        // 已选态仍走原墨色底，橙色点缀在原色图里不受影响，不整体染色。
        // 正文内联熊脸附件同理随主题重建（详情页同款 handler 口径）。
        // 辨识度需真机验证。
        guard case .received = step else { return }
        renderEmoteChips()
        renderReceivedContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 回到收到页时重拉一次详情：对方撤回后本页应及时变占位，不靠用户手动刷新。
        if hasLoadedOnce, case .received = step, let exchangeId = exchangeId {
            refreshExchangeDetail(id: exchangeId, silent: true)
        }
    }

    // MARK: - 布局（重设计预览口径：衬线标题＋右上角刷新图标＋底发丝线＋600 上限列）

    private func buildChrome() {
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let backButton = BearyHit44Button(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        if let back = BearyIconImages.image(named: "icon_back", pointSize: 22) {
            backButton.setImage(back, for: .normal)
        } else {
            backButton.setTitle("返回", for: .normal)
        }
        backButton.tintColor = BearyColors.ink
        backButton.setTitleColor(BearyColors.ink, for: .normal)
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "盲盒交换"
        titleLabel.font = BearyDynamicType.serifDesign(for: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 19, weight: .semibold)))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        refreshNavButton.translatesAutoresizingMaskIntoConstraints = false
        if let refresh = BearyIconImages.image(named: "icon_refresh", pointSize: 19) {
            refreshNavButton.setImage(refresh, for: .normal)
        } else {
            refreshNavButton.setTitle("刷新", for: .normal)
        }
        refreshNavButton.tintColor = BearyColors.blindBoxInk2
        refreshNavButton.setTitleColor(BearyColors.blindBoxInk2, for: .normal)
        refreshNavButton.accessibilityLabel = "刷新交换状态"
        refreshNavButton.addTarget(self, action: #selector(refreshTapped), for: .touchUpInside)
        refreshNavButton.bearyAddPressFeedback()
        let hairline = UIView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = BearyColors.blindBoxLineSoft
        topBar.addSubview(backButton)
        topBar.addSubview(titleLabel)
        topBar.addSubview(refreshNavButton)
        topBar.addSubview(hairline)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        view.addSubview(topBar)
        view.addSubview(scrollView)

        let topBarWidth = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        topBarWidth.priority = .defaultHigh
        let topBarCap = topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        let scrollWidth = scrollView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        scrollWidth.priority = .defaultHigh
        let scrollCap = scrollView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints = [topBarCap, scrollCap]
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBarCap, topBarWidth,
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 68),
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            refreshNavButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            refreshNavButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            refreshNavButton.widthAnchor.constraint(equalToConstant: 44),
            refreshNavButton.heightAnchor.constraint(equalToConstant: 44),
            hairline.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scrollCap, scrollWidth,
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func buildSections() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        // 与原系统 medium 转圈同尺寸（RefreshIconView 图为 32pt，框定 20pt 渲染）。
        spinner.tintColor = BearyColors.ink
        spinner.widthAnchor.constraint(equalToConstant: 20).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 20).isActive = true
        // 填充式竖栈（.fill）会把子视图横向拉满整行，固定 20pt 的转圈不能
        // 直接进栈：改由普通容器承接，容器填满整行、转圈在容器内居中。
        // r17-m4：容器内再加一行加载文案（只有交换 ID 时由
        // refreshExchangeDetail 改写「已换到，正在加载」，其余加载不写文案、
        // 只有转圈，容器随之收窄）；容器随之加高。
        spinnerWrap.translatesAutoresizingMaskIntoConstraints = false
        spinnerWrap.addSubview(spinner)
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingLabel.textColor = BearyColors.gray
        loadingLabel.textAlignment = .center
        loadingLabel.text = ""
        spinnerWrap.addSubview(loadingLabel)
        spinnerWrapHeightConstraint = spinnerWrap.heightAnchor.constraint(equalToConstant: 50)
        NSLayoutConstraint.activate([
            spinner.topAnchor.constraint(equalTo: spinnerWrap.topAnchor, constant: 4),
            spinner.centerXAnchor.constraint(equalTo: spinnerWrap.centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 6),
            loadingLabel.leadingAnchor.constraint(equalTo: spinnerWrap.leadingAnchor),
            loadingLabel.trailingAnchor.constraint(equalTo: spinnerWrap.trailingAnchor),
            loadingLabel.bottomAnchor.constraint(equalTo: spinnerWrap.bottomAnchor, constant: -2),
            spinnerWrapHeightConstraint!,
        ])

        buildStartSection()
        buildWaitingSection()
        buildReceivedSection()
        buildPlaceholderSections()

        loginView.translatesAutoresizingMaskIntoConstraints = false
        let loginLabel = label("登录后可参与盲盒交换", size: 14, weight: .regular, color: BearyColors.gray)
        loginLabel.textAlignment = .center
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        loginButton.bearyAddPressFeedback()
        let loginStack = UIStackView(arrangedSubviews: [loginLabel, loginButton])
        loginStack.axis = .vertical
        loginStack.spacing = 12
        loginStack.translatesAutoresizingMaskIntoConstraints = false
        loginView.addSubview(loginStack)
        NSLayoutConstraint.activate([
            loginStack.topAnchor.constraint(equalTo: loginView.topAnchor, constant: 24),
            loginStack.leadingAnchor.constraint(equalTo: loginView.leadingAnchor),
            loginStack.trailingAnchor.constraint(equalTo: loginView.trailingAnchor),
            loginStack.bottomAnchor.constraint(equalTo: loginView.bottomAnchor),
            loginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.primaryPill(.ink).height),
        ])

        errorStateView.translatesAutoresizingMaskIntoConstraints = false
        errorStateView.isHidden = true

        contentStack.addArrangedSubview(spinnerWrap)
        contentStack.addArrangedSubview(startView)
        contentStack.addArrangedSubview(waitingView)
        contentStack.addArrangedSubview(receivedView)
        contentStack.addArrangedSubview(placeholderView)
        contentStack.addArrangedSubview(mineWithdrawnView)
        contentStack.addArrangedSubview(loginView)
        contentStack.addArrangedSubview(errorStateView)
    }

    // MARK: - 三屏结构（重设计预览口径，文案与间距逐字取自 inspection b4ded4e2）

    /// 三屏共用内边距（预览 .pad{padding:22px 22px 26px}）：scrollView 已在
    /// 两侧各留 16、contentStack 顶 8 底 16，此处再补 6／14／10，合计两侧 22、
    /// 顶 22、底 26。
    private func blindBoxScreenStack(in view: UIView) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        return stack
    }

    /// 主按钮共用样式（预览 .btn-ink／.btn-primary：min-height 52、圆角 14、
    /// 标题 16 semibold；App 工厂钮高 44 圆角 12，不合预览，故此处手写）。
    private func styleBlindBoxMainButton(_ button: UIButton, title: String, background: UIColor, textColor: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.backgroundColor = background
        button.setTitleColor(textColor, for: .normal)
        button.tintColor = textColor
        button.layer.cornerRadius = 14
        button.layer.masksToBounds = true
        button.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    /// 状态行（预览 .status-line：12.5 字、绿点 6、间距 7）：文案由
    /// updateStatusTime 写，build 时先给无时间的 fallback。
    private func blindBoxStatusRow(dot: UIView, label: UILabel, fallback: String) -> UIStackView {
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = BearyColors.blindBoxStatusDot
        dot.layer.cornerRadius = 3
        dot.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.blindBoxMuted
        label.text = fallback
        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.spacing = 7
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        return row
    }

    /// 弹性空白（预览 .actions{margin-top:auto}）：最小 28 高，内容短时撑开、
    /// 把主钮推到底；内容长时收成 28，页内可滚。
    private func blindBoxSpacer() -> UIView {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return spacer
    }

    /// hero 图标块（预览 .hero-mark：64×64、圆角 20、accentTint2 底、1pt line 边、
    /// 内 30 图标、margin-top 6——6 已含在屏内边距顶 14 里，此处不再另加）。
    /// 外包一层容器：竖栈 .fill 会把 64 宽的块拉满行宽，容器吃满宽、块贴左。
    private func blindBoxHero(image: UIImage?) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let hero = UIView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.backgroundColor = BearyColors.blindBoxAccentTint2
        hero.layer.cornerRadius = 20
        hero.layer.borderWidth = 1
        hero.layer.bearyDynamicBorderColor = BearyColors.blindBoxLine
        let iconView = UIImageView(image: image)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = BearyColors.blindBoxAccent
        hero.addSubview(iconView)
        wrap.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.widthAnchor.constraint(equalToConstant: 64),
            hero.heightAnchor.constraint(equalToConstant: 64),
            hero.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            hero.topAnchor.constraint(equalTo: wrap.topAnchor),
            hero.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            iconView.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
        ])
        return wrap
    }

    /// 三步说明行（预览 .steps li：上下 13、首行上 2 无顶线、序号圆 22 下移 4、
    /// 圆文间距 14、15 字；加粗段走 semibold）。
    /// 序号圆底色预览未写明，沿用 hero 的 accentTint2＋accentDeep 字。
    private func blindBoxStepRow(number: String, text: String, bold: String, isFirst: Bool) -> UIView {
        let item = UIView()
        item.translatesAutoresizingMaskIntoConstraints = false
        if isFirst == false {
            let hairline = UIView()
            hairline.translatesAutoresizingMaskIntoConstraints = false
            hairline.backgroundColor = BearyColors.blindBoxLineSoft
            item.addSubview(hairline)
            NSLayoutConstraint.activate([
                hairline.topAnchor.constraint(equalTo: item.topAnchor),
                hairline.leadingAnchor.constraint(equalTo: item.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: item.trailingAnchor),
                hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            ])
        }
        let disc = UIView()
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.backgroundColor = BearyColors.blindBoxAccentTint2
        disc.layer.cornerRadius = 11
        disc.clipsToBounds = true
        let digit = UILabel()
        digit.translatesAutoresizingMaskIntoConstraints = false
        digit.text = number
        digit.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12, weight: .semibold))
        digit.adjustsFontForContentSizeCategory = true
        digit.textColor = BearyColors.blindBoxAccentDeep
        digit.textAlignment = .center
        disc.addSubview(digit)
        let textLabel = UILabel()
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.numberOfLines = 0
        let baseFont = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont, .foregroundColor: BearyColors.ink,
        ])
        if let range = text.range(of: bold) {
            attributed.addAttribute(.font, value: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold)), range: NSRange(range, in: text))
        }
        textLabel.attributedText = attributed
        item.addSubview(disc)
        item.addSubview(textLabel)
        NSLayoutConstraint.activate([
            digit.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            digit.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: 22),
            disc.heightAnchor.constraint(equalToConstant: 22),
            disc.leadingAnchor.constraint(equalTo: item.leadingAnchor),
            disc.topAnchor.constraint(equalTo: item.topAnchor, constant: (isFirst ? 2 : 13) + 4),
            textLabel.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 14),
            textLabel.trailingAnchor.constraint(equalTo: item.trailingAnchor),
            textLabel.topAnchor.constraint(equalTo: item.topAnchor, constant: isFirst ? 2 : 13),
            textLabel.bottomAnchor.constraint(equalTo: item.bottomAnchor, constant: -13),
        ])
        return item
    }

    private func buildStartSection() {
        startView.translatesAutoresizingMaskIntoConstraints = false
        // hero 图：官方 icon_exchange 30pt；预览为内联 SVG 交换箭头，无官方信封
        // 以外的替代资产时不自绘，沿用已注册的交换图标。
        let (exchangeIcon, _) = BlindBoxIcons.exchange(pointSize: 30)
        let hero = blindBoxHero(image: exchangeIcon)
        let titleLabel = label("交换一篇旧日记", size: 24, weight: .semibold, color: BearyColors.ink)
        let ledeLabel = UILabel()
        ledeLabel.translatesAutoresizingMaskIntoConstraints = false
        ledeLabel.numberOfLines = 0
        let ledeParagraph = NSMutableParagraphStyle()
        ledeParagraph.lineHeightMultiple = 1.7
        ledeParagraph.lineBreakMode = .byWordWrapping
        ledeLabel.attributedText = NSAttributedString(string: "把一篇旧日记交给一位陌生人，同时收下对方的一篇。彼此看不到名字，也没有评论，只能贴小熊回应。", attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15)),
            .foregroundColor: BearyColors.blindBoxInk2,
            .paragraphStyle: ledeParagraph,
        ])
        let stepsStack = UIStackView(arrangedSubviews: [
            blindBoxStepRow(number: "1", text: "选一篇你愿意给陌生人看的旧日记", bold: "选一篇", isFirst: true),
            blindBoxStepRow(number: "2", text: "随机配对，对方的一篇送到你这里", bold: "对方的一篇", isFirst: false),
            blindBoxStepRow(number: "3", text: "读完贴一只小熊，就这么多", bold: "贴一只小熊", isFirst: false),
        ])
        stepsStack.axis = .vertical
        stepsStack.spacing = 0
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        styleBlindBoxMainButton(pickButton, title: "选一篇日记", background: BearyColors.blindBoxChipDark, textColor: BearyColors.blindBoxChipDarkText)
        pickButton.addTarget(self, action: #selector(presentPickSheet), for: .touchUpInside)
        let stack = blindBoxScreenStack(in: startView)
        stack.addArrangedSubview(hero)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(ledeLabel)
        stack.addArrangedSubview(stepsStack)
        stack.addArrangedSubview(blindBoxSpacer())
        stack.addArrangedSubview(pickButton)
        stack.setCustomSpacing(18, after: hero)
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(22, after: ledeLabel)
        startMinHeightConstraint = startView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.heightAnchor, constant: -24)
    }

    private func buildWaitingSection() {
        waitingView.translatesAutoresizingMaskIntoConstraints = false
        // hero 图：官方包里无信封资产，预览的信封为内联 SVG 占位；不自绘，
        // 改用已注册的 icon_blind_box 30pt（已投出＝盒子已寄出）。
        let (boxIcon, _) = BlindBoxIcons.blindBox(pointSize: 30)
        let hero = blindBoxHero(image: boxIcon)
        let titleLabel = label("已经投出去了", size: 24, weight: .semibold, color: BearyColors.ink)
        let ledeLabel = UILabel()
        ledeLabel.translatesAutoresizingMaskIntoConstraints = false
        ledeLabel.numberOfLines = 0
        let ledeParagraph = NSMutableParagraphStyle()
        ledeParagraph.lineHeightMultiple = 1.7
        ledeParagraph.lineBreakMode = .byWordWrapping
        ledeLabel.attributedText = NSAttributedString(string: "你的一篇旧日记正在等一位陌生人。配对成功后，对方的一篇旧日记会送到这里。", attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15)),
            .foregroundColor: BearyColors.blindBoxInk2,
            .paragraphStyle: ledeParagraph,
        ])
        // 已投出卡（预览 .sent-card：上 22、1pt line 边、圆角 16、内边距 16／18；
        // 底色预览未写明，App 底色已是面色，故卡用 surface2 分层）。
        sentCard.translatesAutoresizingMaskIntoConstraints = false
        sentCard.backgroundColor = BearyColors.blindBoxSurface2
        sentCard.layer.cornerRadius = 16
        sentCard.layer.borderWidth = 1
        sentCard.layer.bearyDynamicBorderColor = BearyColors.blindBoxLine
        sentMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        sentMetaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        sentMetaLabel.adjustsFontForContentSizeCategory = true
        sentMetaLabel.textColor = BearyColors.blindBoxMuted
        sentBodyLabel.translatesAutoresizingMaskIntoConstraints = false
        sentBodyLabel.numberOfLines = 0
        sentCard.addSubview(sentMetaLabel)
        sentCard.addSubview(sentBodyLabel)
        NSLayoutConstraint.activate([
            sentMetaLabel.topAnchor.constraint(equalTo: sentCard.topAnchor, constant: 16),
            sentMetaLabel.leadingAnchor.constraint(equalTo: sentCard.leadingAnchor, constant: 18),
            sentMetaLabel.trailingAnchor.constraint(equalTo: sentCard.trailingAnchor, constant: -18),
            sentBodyLabel.topAnchor.constraint(equalTo: sentMetaLabel.bottomAnchor, constant: 6),
            sentBodyLabel.leadingAnchor.constraint(equalTo: sentCard.leadingAnchor, constant: 18),
            sentBodyLabel.trailingAnchor.constraint(equalTo: sentCard.trailingAnchor, constant: -18),
            sentBodyLabel.bottomAnchor.constraint(equalTo: sentCard.bottomAnchor, constant: -16),
        ])
        styleBlindBoxMainButton(waitingRefreshButton, title: "刷新状态", background: BearyColors.blindBoxChipDark, textColor: BearyColors.blindBoxChipDarkText)
        waitingRefreshButton.addTarget(self, action: #selector(refreshWaiting), for: .touchUpInside)
        waitingWithdrawButton.translatesAutoresizingMaskIntoConstraints = false
        waitingWithdrawButton.setTitle("撤回交换", for: .normal)
        waitingWithdrawButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        waitingWithdrawButton.titleLabel?.adjustsFontForContentSizeCategory = true
        waitingWithdrawButton.setTitleColor(BearyColors.blindBoxDanger, for: .normal)
        waitingWithdrawButton.addTarget(self, action: #selector(waitingWithdrawTapped), for: .touchUpInside)
        waitingWithdrawButton.bearyAddPressFeedback()
        let withdrawRow = UIView()
        withdrawRow.translatesAutoresizingMaskIntoConstraints = false
        withdrawRow.addSubview(waitingWithdrawButton)
        NSLayoutConstraint.activate([
            waitingWithdrawButton.centerXAnchor.constraint(equalTo: withdrawRow.centerXAnchor),
            waitingWithdrawButton.centerYAnchor.constraint(equalTo: withdrawRow.centerYAnchor),
            waitingWithdrawButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let statusRow = blindBoxStatusRow(dot: waitingStatusDot, label: waitingStatusLabel, fallback: "等待配对")
        let actionsStack = UIStackView(arrangedSubviews: [waitingRefreshButton, withdrawRow, statusRow])
        actionsStack.axis = .vertical
        actionsStack.spacing = 0
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.setCustomSpacing(10, after: waitingRefreshButton)
        actionsStack.setCustomSpacing(16, after: withdrawRow)
        let stack = blindBoxScreenStack(in: waitingView)
        stack.addArrangedSubview(hero)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(ledeLabel)
        stack.addArrangedSubview(sentCard)
        stack.addArrangedSubview(blindBoxSpacer())
        stack.addArrangedSubview(actionsStack)
        stack.setCustomSpacing(18, after: hero)
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(22, after: ledeLabel)
        waitingMinHeightConstraint = waitingView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.heightAnchor, constant: -24)
    }

    private func buildReceivedSection() {
        receivedView.translatesAutoresizingMaskIntoConstraints = false
        // 陌生人头像（预览 36 圆）：匿名无真头像，surface2 圆底＋系统 person.fill
        // 18pt muted 色；不用官方熊头（那是本人／小熊回应的脸）。
        receivedAvatarView.translatesAutoresizingMaskIntoConstraints = false
        receivedAvatarView.backgroundColor = BearyColors.blindBoxSurface2
        receivedAvatarView.layer.cornerRadius = 18
        receivedAvatarView.clipsToBounds = true
        let avatarIcon = UIImageView(image: UIImage(systemName: "person.fill"))
        avatarIcon.translatesAutoresizingMaskIntoConstraints = false
        avatarIcon.contentMode = .scaleAspectFit
        avatarIcon.tintColor = BearyColors.blindBoxMuted
        receivedAvatarView.addSubview(avatarIcon)
        receivedMetaNameLabel.translatesAutoresizingMaskIntoConstraints = false
        receivedMetaNameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        receivedMetaNameLabel.adjustsFontForContentSizeCategory = true
        receivedMetaNameLabel.textColor = BearyColors.ink
        receivedMetaNameLabel.numberOfLines = 0
        receivedDateLabel.translatesAutoresizingMaskIntoConstraints = false
        receivedDateLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        receivedDateLabel.adjustsFontForContentSizeCategory = true
        receivedDateLabel.textColor = BearyColors.blindBoxMuted
        let metaTextStack = UIStackView(arrangedSubviews: [receivedMetaNameLabel, receivedDateLabel])
        metaTextStack.axis = .vertical
        metaTextStack.spacing = 1
        metaTextStack.translatesAutoresizingMaskIntoConstraints = false
        receivedMetaRow.axis = .horizontal
        receivedMetaRow.spacing = 10
        receivedMetaRow.alignment = .center
        receivedMetaRow.translatesAutoresizingMaskIntoConstraints = false
        receivedMetaRow.addArrangedSubview(receivedAvatarView)
        receivedMetaRow.addArrangedSubview(metaTextStack)
        NSLayoutConstraint.activate([
            avatarIcon.widthAnchor.constraint(equalToConstant: 18),
            avatarIcon.heightAnchor.constraint(equalToConstant: 18),
            avatarIcon.centerXAnchor.constraint(equalTo: receivedAvatarView.centerXAnchor),
            avatarIcon.centerYAnchor.constraint(equalTo: receivedAvatarView.centerYAnchor),
            receivedAvatarView.widthAnchor.constraint(equalToConstant: 36),
            receivedAvatarView.heightAnchor.constraint(equalToConstant: 36),
        ])
        // 标题行：预览未单列标题（示例篇无标题）；有标题时 16 semibold 夹在
        // meta 行与正文之间，无标题时整行收掉（showReceived 按有无改间距）。
        receivedTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        receivedTitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .semibold))
        receivedTitleLabel.adjustsFontForContentSizeCategory = true
        receivedTitleLabel.textColor = BearyColors.ink
        receivedTitleLabel.numberOfLines = 0
        receivedContentLabel.translatesAutoresizingMaskIntoConstraints = false
        receivedContentLabel.numberOfLines = 0
        imagesStack.axis = .vertical
        imagesStack.spacing = 8
        imagesStack.translatesAutoresizingMaskIntoConstraints = false
        receivedHairline.translatesAutoresizingMaskIntoConstraints = false
        receivedHairline.backgroundColor = BearyColors.blindBoxLineSoft
        // “收到的小熊”小标题（预览 .sec-label：12.5 muted、字距 .06em）。
        emoteSectionLabel.translatesAutoresizingMaskIntoConstraints = false
        let secParagraph = NSMutableParagraphStyle()
        secParagraph.lineBreakMode = .byWordWrapping
        emoteSectionLabel.attributedText = NSAttributedString(string: "收到的小熊", attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5)),
            .foregroundColor: BearyColors.blindBoxMuted,
            .kern: 12.5 * 0.06,
            .paragraphStyle: secParagraph,
        ])
        emoteFlowView.translatesAutoresizingMaskIntoConstraints = false
        // 贴熊主钮（预览 .btn-primary：橙底、52 高、钮文前 24 happy 熊、图左文 9）。
        styleBlindBoxMainButton(emotePrimaryButton, title: "贴一只小熊", background: BearyColors.blindBoxAccent, textColor: BearyColors.blindBoxChipDarkText)
        if let happy = BearyEmoteImages.image(for: "happy", dark: false) {
            emotePrimaryButton.setImage(Self.chipEmoteImage(happy, side: 24), for: .normal)
            // 图文间距 9：两侧各分 4.5，整对仍居中。
            emotePrimaryButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4.5, bottom: 0, right: 4.5)
            emotePrimaryButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4.5, bottom: 0, right: -4.5)
        }
        emotePrimaryButton.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
        reportTextButton.translatesAutoresizingMaskIntoConstraints = false
        reportTextButton.setTitle("举报", for: .normal)
        reportTextButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        reportTextButton.titleLabel?.adjustsFontForContentSizeCategory = true
        reportTextButton.setTitleColor(BearyColors.ink, for: .normal)
        reportTextButton.addTarget(self, action: #selector(reportTapped), for: .touchUpInside)
        reportTextButton.bearyAddPressFeedback()
        withdrawTextButton.translatesAutoresizingMaskIntoConstraints = false
        withdrawTextButton.setTitle("撤回交换", for: .normal)
        withdrawTextButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        withdrawTextButton.titleLabel?.adjustsFontForContentSizeCategory = true
        withdrawTextButton.setTitleColor(BearyColors.blindBoxDanger, for: .normal)
        withdrawTextButton.addTarget(self, action: #selector(withdrawTapped), for: .touchUpInside)
        withdrawTextButton.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            reportTextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            withdrawTextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let subRow = UIStackView(arrangedSubviews: [reportTextButton, withdrawTextButton])
        subRow.axis = .horizontal
        subRow.distribution = .equalSpacing
        subRow.translatesAutoresizingMaskIntoConstraints = false
        let statusRow = blindBoxStatusRow(dot: receivedStatusDot, label: receivedStatusLabel, fallback: "交换已完成")
        let actionsStack = UIStackView(arrangedSubviews: [emotePrimaryButton, subRow, statusRow])
        actionsStack.axis = .vertical
        actionsStack.spacing = 0
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.setCustomSpacing(10, after: emotePrimaryButton)
        actionsStack.setCustomSpacing(16, after: subRow)
        receivedStack.axis = .vertical
        receivedStack.spacing = 0
        receivedStack.translatesAutoresizingMaskIntoConstraints = false
        receivedView.addSubview(receivedStack)
        NSLayoutConstraint.activate([
            receivedStack.topAnchor.constraint(equalTo: receivedView.topAnchor, constant: 14),
            receivedStack.leadingAnchor.constraint(equalTo: receivedView.leadingAnchor, constant: 6),
            receivedStack.trailingAnchor.constraint(equalTo: receivedView.trailingAnchor, constant: -6),
            receivedStack.bottomAnchor.constraint(equalTo: receivedView.bottomAnchor, constant: -10),
            receivedHairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        receivedStack.addArrangedSubview(receivedMetaRow)
        receivedStack.addArrangedSubview(receivedTitleLabel)
        receivedStack.addArrangedSubview(receivedContentLabel)
        receivedStack.addArrangedSubview(imagesStack)
        receivedStack.addArrangedSubview(receivedHairline)
        receivedStack.addArrangedSubview(emoteSectionLabel)
        receivedStack.addArrangedSubview(emoteFlowView)
        receivedStack.addArrangedSubview(blindBoxSpacer())
        receivedStack.addArrangedSubview(actionsStack)
        receivedStack.setCustomSpacing(20, after: receivedMetaRow)
        receivedStack.setCustomSpacing(12, after: receivedTitleLabel)
        receivedStack.setCustomSpacing(24, after: receivedContentLabel)
        receivedStack.setCustomSpacing(24, after: imagesStack)
        receivedStack.setCustomSpacing(18, after: receivedHairline)
        receivedStack.setCustomSpacing(10, after: emoteSectionLabel)
        receivedMinHeightConstraint = receivedView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.heightAnchor, constant: -24)
    }

    private func buildPlaceholderSections() {
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        // 占位框：无外框，靠 surface1 明度分层（§7）；不另起 shape 图层画虚线。
        placeholderView.backgroundColor = BearyColors.surface1
        placeholderView.layer.cornerRadius = BearyCorners.single
        placeholderView.layer.borderWidth = 0
        placeholderView.layer.bearyDynamicBorderColor = BearyColors.line
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textAlignment = .center
        placeholderView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: placeholderView.topAnchor, constant: 20),
            placeholderLabel.leadingAnchor.constraint(equalTo: placeholderView.leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(equalTo: placeholderView.trailingAnchor, constant: -16),
            placeholderLabel.bottomAnchor.constraint(equalTo: placeholderView.bottomAnchor, constant: -20),
        ])

        mineWithdrawnView.translatesAutoresizingMaskIntoConstraints = false
        mineWithdrawnLabel.translatesAutoresizingMaskIntoConstraints = false
        mineWithdrawnLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        mineWithdrawnLabel.adjustsFontForContentSizeCategory = true
        mineWithdrawnLabel.textColor = BearyColors.gray
        mineWithdrawnLabel.numberOfLines = 0
        mineWithdrawnLabel.textAlignment = .center
        mineWithdrawnLabel.text = "你已撤回交换。今日次数不返还，明天再来。"
        mineWithdrawnView.addSubview(mineWithdrawnLabel)
        NSLayoutConstraint.activate([
            mineWithdrawnLabel.topAnchor.constraint(equalTo: mineWithdrawnView.topAnchor, constant: 20),
            mineWithdrawnLabel.leadingAnchor.constraint(equalTo: mineWithdrawnView.leadingAnchor, constant: 16),
            mineWithdrawnLabel.trailingAnchor.constraint(equalTo: mineWithdrawnView.trailingAnchor, constant: -16),
            mineWithdrawnLabel.bottomAnchor.constraint(equalTo: mineWithdrawnView.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - 步骤渲染

    /// r17-m4（重设计后只剩收到入场）：receivedTransition 为真时，收到屏短距
    /// 下入＋淡入 0.26 秒（减动效时直切）；其余步骤沿用原直切，再次进页、
    /// 静默校验与撤回分支直接显示对应状态，一字不动。
    private func setStep(_ next: Step, receivedTransition: Bool = false) {
        // 审计新一轮 02：撤回是当日终态——已撤回的页不再回 .received；
        // 旧详情回包倒退界面的最后一道防线（回调侧已有代次＋终态校验）。
        // 本页实例内 .mineWithdrawn → .received 没有合法路径（开盒只在
        // 选篇点按、静默刷新只在 received 态触发），故直接拦住。
        if case .mineWithdrawn = step, case .received = next { return }
        step = next
        hasLoadedOnce = true
        spinnerWrap.isHidden = true
        spinner.stopSpinning()
        startView.isHidden = true
        waitingView.isHidden = true
        receivedView.isHidden = true
        placeholderView.isHidden = true
        mineWithdrawnView.isHidden = true
        loginView.isHidden = true
        errorStateView.isHidden = true
        switch next {
        case .loading:
            spinnerWrap.isHidden = false
            spinner.startSpinning()
            // 只有交换 ID 时留一行状态文案（「已换到，正在加载」）；其余加载
            // 只有转圈、不再配「加载中…」文字（转圈本身即加载态），容器随之收窄。
            if let status = loadingStatusText {
                loadingLabel.text = status
                loadingLabel.isHidden = false
                spinnerWrapHeightConstraint?.constant = 50
            } else {
                // 扫荡 130（#1254 回归）：无文案时容器高度不能是 30——约束链
                // 要求转圈 20 + 上 4 + 间距 6 + 下 2 = 32（label 高度为 0 时），
                // 30 满足不了，逢无文案加载即报 Auto Layout 冲突；且隐藏的
                // label 若留着上次「已换到，正在加载」文案，固有高度还会把
                // 需求顶到约 50。清文案、高度改 32（视觉上与 30 无差别）。
                loadingLabel.text = ""
                loadingLabel.isHidden = true
                spinnerWrapHeightConstraint?.constant = 32
            }
            loadingStatusText = nil
        case .login:
            loginView.isHidden = false
        case .pool:
            startView.isHidden = false
            pickButton.isEnabled = poolBusy == false
        case .waiting:
            waitingView.isHidden = false
            waitingRefreshButton.isEnabled = statusRefreshing == false
        case .received:
            receivedView.isHidden = false
            if receivedTransition, BearyMotion.animated(true) {
                // 动效只走 transform 与 opacity，不动布局。
                receivedView.alpha = 0
                receivedView.transform = CGAffineTransform(translationX: 0, y: 12)
                UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                    self.receivedView.alpha = 1
                    self.receivedView.transform = .identity
                }, completion: nil)
            } else {
                receivedView.alpha = 1
                receivedView.transform = .identity
            }
        case .placeholder(let text):
            placeholderLabel.text = text
            placeholderView.isHidden = false
        case .mineWithdrawn:
            mineWithdrawnView.isHidden = false
        case .error(let text):
            errorStateView.configure(kind: .error, title: nil, subtitle: text, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.retryTapped() })
            errorStateView.isHidden = false
        }
        updateScreenMinHeight()
    }

    /// 三屏最小高度只激活当前屏那条：隐藏屏的约束不激活，避免与竖栈
    /// 收起隐藏子视图冲突；其余步骤三条全不激活。
    private func updateScreenMinHeight() {
        var startActive = false
        var waitingActive = false
        var receivedActive = false
        switch step {
        case .pool: startActive = true
        case .waiting: waitingActive = true
        case .received: receivedActive = true
        default: break
        }
        startMinHeightConstraint?.isActive = startActive
        waitingMinHeightConstraint?.isActive = waitingActive
        receivedMinHeightConstraint?.isActive = receivedActive
    }

    // MARK: - 载入

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func retryTapped() {
        loadInitial()
    }

    @objc private func loginTapped() {
        let login = BearyLoginSheet.make()
        login.onLoggedIn = { [weak self] referralText in
            // 添加账号会话守卫：正常是空操作；防迂回路径下守卫仍 armed 时
            // 后续一次取消把新号恢复成旧号，成功先解 arm。
            SessionManager.shared.completeAccountAddSession()
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
            SessionManager.shared.refreshMe { _ in
                DispatchQueue.main.async {
                    self?.loadInitial()
                    // 审计登录杂项：邀请绑定反馈落点——进 App 后 BearyToast 一次。
                    if let text = referralText, !text.isEmpty, let view = self?.view {
                        BearyToast.show(in: view, message: BearyReferralFeedback.toastText(base: text, plusUntil: SessionManager.shared.currentUser?.plusUntil))
                    }
                }
            }
        }
        login.onCancelled = { [weak self] in
            SessionManager.shared.cancelAccountAddSession()
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
        present(login, animated: BearyMotion.animated(true), completion: nil)
    }

    /// 新发一轮盲盒请求前调用：递增代次，返回（发起账号， 代次）。
    private func beginBlindBoxRequest() -> (accountId: Int?, generation: Int) {
        blindBoxGeneration += 1
        return (SessionManager.shared.currentUser?.id, blindBoxGeneration)
    }

    /// 回包守卫：发起账号仍是当前账号、且代次仍是最新一轮，才允许更新
    /// UI 或 BlindBoxState；切号 / 新请求发出后，旧回包一律丢弃。
    private func isCurrentBlindBoxResponse(accountId: Int?, generation: Int) -> Bool {
        guard let accountId = accountId, accountId == SessionManager.shared.currentUser?.id else { return false }
        return generation == blindBoxGeneration
    }

    private func loadInitial() {
        guard SessionManager.shared.isLoggedIn else {
            setStep(.login)
            return
        }
        // 新一轮载入：此前交换的举报 / 撤回占位不带到新交换。
        exchangeHidden = false
        setStep(.loading)
        // 第八轮审计 03/04：发起时拍下账号与北京时间日期键；回包先校验，
        // 任一失配（切号或跨日）即丢弃旧结果、重新为当前账号/新一天拉一次，
        // 不写旧桶、不路由旧状态。
        let identity = BlindBoxRequestIdentity.capture()
        // A2：再拍一份快照（账号 + 会话代次 + 北京日期）：代次变化也作废重查
        //（identity 只看账号与日期）。
        let snapshot = Self.captureBlindBoxSnapshot()
        BearyAPI.shared.fetchBlindBoxToday { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    // 跨日 / 切号后旧回包作废：不写当前桶，重查当前状态。
                    self.loadInitial()
                    return
                }
                switch result {
                case .success(let body):
                    guard BlindBoxState.shared.applyServerState(body, for: identity) else {
                        self.loadInitial()
                        return
                    }
                    self.routeFromToday(body)
                case .failure(let error):
                    self.setStep(.error(self.todayErrorText(error)))
                }
            }
        }
    }

    /// silent 为真时（导航刷新／等待屏“刷新状态”）：收到屏路径走静默详情，
    /// 不闪加载页；其余路由与首次载入一致。
    private func routeFromToday(_ body: BlindBoxStateBody, silent: Bool = false) {
        if body.myWithdrawn == true {
            setStep(.mineWithdrawn)
            return
        }
        if body.receivedWithdrawn == true {
            setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
            return
        }
        if let exchangeId = body.exchangeId, body.used == true {
            self.exchangeId = exchangeId
            refreshExchangeDetail(id: exchangeId, silent: silent)
            return
        }
        if body.used == true {
            setStep(.placeholder(BearyRepeatedCopy.blindBoxAlreadySwappedToday))
            return
        }
        if let pooled = body.pooledEntryId, pooled.isEmpty == false {
            pooledEntryId = pooled
            // 重设计预览口径：已入池未开盒进等待屏（先入池再开盒的口径不变，
            // 只是两次点按并成一次；池空开盒失败同样落这里，见 poolAndOpen）。
            lastStatusUpdate = Date()
            updateStatusTime()
            setStep(.waiting)
            updateWaitingSentCard()
            // 候选列表后台补：已投出卡就靠它找入池篇（见 updateWaitingSentCard）。
            loadPoolEntries()
            return
        } else {
            // /today 未给入池 id 时清掉旧值：同一 VC 生命周期内再次拉取，
            // 旧入池态不得保留到新回包里。
            pooledEntryId = nil
        }
        // 未入池：直接进开始屏，候选列表后台补（选篇 sheet 打开时再渲染，
        // 未就绪时 sheet 显示加载态，不拿列表阻塞开始屏）。
        setStep(.pool)
        loadPoolEntries()
    }

    private func loadPoolEntries() {
        // B1：候选列表先从本人日记存档（时间线缓存，本账号桶）生成小索引、
        // 立即渲染；存档缺数据（无快照 / 还有更多页）时再补页，不再每次都
        // 从第 1 页全量拉起。网络补页仍照搬星图页游标分页（before / beforeId、
        // 去重、代次门控）；行内仍按入池资格显 pill（公开 / 私密 /
        // 今日公开），选中时再按资格过滤（见 renderPoolRows onTap）。
        // R22 #10：网络补页不再 10 页（500 篇）即停——前 500 篇含私密、仅好友、
        // 今日公开等不可入池篇时，真正可选的旧公开篇可能在更后面。改为增量
        // 分页按需续拉：每页 50 篇照旧，集满 20 篇可入池篇即停（常见账号
        // 1~2 页收尾），否则一直续拉到 40 页（2000 篇）或服务端短页为止；
        // 代次门控与去重、分页中途断网“已收集到的页不作废，照常进池”口径均不动。
        // 服务端「可入池日记」筛选接口是后续优化，不在本支改后端接口。
        poolListLoading = true
        poolLoadGeneration += 1
        poolCollected = []
        poolSeenIds = []
        poolCapped = false
        poolInterrupted = false
        poolResumeBefore = nil
        poolResumeBeforeId = nil
        poolResumePage = 1
        let generation = poolLoadGeneration
        let bucket = BearyFeedCache.bucket(userId: SessionManager.shared.currentUser?.id ?? BearyFeedCache.lastKnownUserId())
        BearyTimelineCache.load(bucket: bucket) { [weak self] snap in
            guard let self = self, generation == self.poolLoadGeneration else { return }
            var needsNetwork = true
            if let snap = snap, snap.entries.isEmpty == false {
                for entry in snap.entries {
                    if let id = entry.id, id.isEmpty == false {
                        if self.poolSeenIds.contains(id) { continue }
                        self.poolSeenIds.insert(id)
                    }
                    self.poolCollected.append(entry)
                }
                self.poolEntries = self.poolCollected
                self.renderPoolRows()
                // 存档已含全量（hasMore 为假）时不再发网络请求。
                needsNetwork = snap.hasMore
                if needsNetwork == false {
                    self.poolListLoading = false
                }
                // 盲盒 #40：快照只覆盖到上次缓存的头，快照头之后的新日记
                // （另一设备新建或改公开）不在快照里；只向更早翻页永远拉
                // 不到它们。有快照时仍拉一次首屏做增量对齐，只把快照头之后
                // 的新条目并到队首并刷新列表；失败时静默保留缓存，不报错、
                // 不清空。向更早翻页仍走下面的旧逻辑。
                self.refreshPoolHead(generation: generation)
            }
            if needsNetwork {
                // 存档有内容时从窗口末条续拉，只补窗口外的旧篇，不重拉第 1 页。
                if let last = self.poolCollected.last, let cursor = last.createdAt, let lastId = last.id, lastId.isEmpty == false {
                    self.loadPoolEntriesPage(before: cursor, beforeId: lastId, page: 1, generation: generation)
                } else {
                    self.loadPoolEntriesPage(before: nil, beforeId: nil, page: 1, generation: generation)
                }
            }
        }
    }

    /// 盲盒 #40：快照头增量对齐。先显示缓存，同时拉一次首屏：只把快照头之后
    /// 的新条目（另一设备新建或改公开）按服务端顺序并到队首并刷新列表；
    /// 回包失败时静默保留缓存，不报错、不清空。向更早翻页的逻辑不动。
    private func refreshPoolHead(generation: Int) {
        guard let headCreatedAt = poolCollected.first?.createdAt else { return }
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50, before: nil, beforeId: nil) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.poolLoadGeneration else { return }
                guard case .success(let list) = result else { return }
                let fresh = (list.entries ?? []).filter { entry in
                    guard let id = entry.id, id.isEmpty == false, self.poolSeenIds.contains(id) == false,
                          let createdAt = entry.createdAt, createdAt >= headCreatedAt else { return false }
                    return true
                }
                guard fresh.isEmpty == false else { return }
                for entry in fresh {
                    if let id = entry.id, id.isEmpty == false { self.poolSeenIds.insert(id) }
                }
                self.poolCollected.insert(contentsOf: fresh, at: 0)
                self.poolEntries = self.poolCollected
                self.renderPoolRows()
            }
        }
    }

    /// 选篇分页入口显隐（第八轮审计 02）：触顶留“加载更多”、中断留“重试”，
    /// 游标不在时不留入口；其余时候隐藏。目标是选篇底 sheet 里的按钮
    ///（重设计预览口径，页内已无分页入口）；sheet 未打开时只记状态，
    /// 打开时由 renderPoolRows 同步。
    private func updatePoolLoadMoreButton() {
        guard let sheet = pickSheet else { return }
        let show = (poolCapped || poolInterrupted) && poolResumeBefore != nil && poolResumeBeforeId != nil
        sheet.setLoadMoreVisible(show, title: poolInterrupted ? "重试" : "加载更多")
    }

    /// 选篇分页续拉入口（第八轮审计 02，地图 #944 同款口径）：中断时从失败页
    /// 游标续拉（页码不动），触顶时从触顶页末尾游标续拉新一批（page 从 1
    /// 重新计、最多再 40 页）；已收页与去重集保留、成功后整批成表；点按后先
    /// 藏入口防重复点按，代次 +1 作废旧回包。
    private func didTapPoolLoadMore() {
        pickSheet?.setLoadMoreVisible(false, title: nil)
        guard let before = poolResumeBefore, let beforeId = poolResumeBeforeId else { return }
        poolLoadGeneration += 1
        poolListLoading = true
        let page = poolInterrupted ? poolResumePage : 1
        loadPoolEntriesPage(before: before, beforeId: beforeId, page: page, generation: poolLoadGeneration)
    }

    private func loadPoolEntriesPage(before: Int?, beforeId: String?, page: Int, generation: Int) {
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.poolLoadGeneration else { return }
                switch result {
                case .success(let list):
                    let pageEntries = list.entries ?? []
                    for entry in pageEntries {
                        if let id = entry.id, !id.isEmpty {
                            if self.poolSeenIds.contains(id) { continue }
                            self.poolSeenIds.insert(id)
                        }
                        self.poolCollected.append(entry)
                    }
                    let last = pageEntries.last
                    let eligibleCount = self.poolCollected.filter { BlindBoxPool.eligibility(for: $0) == .eligible }.count
                    if pageEntries.count >= 50, page < Self.poolMaxPages, eligibleCount < Self.poolEligibleTarget, let cursor = last?.createdAt, let lastId = last?.id {
                        self.loadPoolEntriesPage(before: cursor, beforeId: lastId, page: page + 1, generation: generation)
                        return
                    }
                    // 触顶（第八轮审计 02，地图 #944 同款口径）：末页仍满页，后面
                    // 可能还有——记 poolCapped，留末页游标供按需续拉新一批；末页
                    // 满页却无游标时清旧游标、不留入口。是否满页只看末页篇数，
                    // 不看停在哪一页：找够 20 篇提前停时末页也可能满页，游标同
                    // 样要留，否则更早的日记再也进不来（审计 16 项第 4 项）。
                    // 本批拉完即清中断态（续拉成功说明链已接上）。
                    self.poolInterrupted = false
                    self.poolCapped = pageEntries.count >= 50
                    if self.poolCapped, let cursor = last?.createdAt, let lastId = last?.id {
                        self.poolResumeBefore = cursor
                        self.poolResumeBeforeId = lastId
                        self.poolResumePage = 1
                    } else {
                        self.poolResumeBefore = nil
                        self.poolResumeBeforeId = nil
                    }
                    self.poolEntries = self.poolCollected
                    self.poolListLoading = false
                    self.renderPoolRows()
                case .failure(let error):
                    // 分页中途断网（第八轮审计 02）：已收集到的页不作废，照常进池，
                    // 但不再当作完整——记 poolInterrupted 并留失败页游标，页内留
                    // “重试”入口从中断处续拉（失败页的 before / beforeId 即本次
                    // 调用的入参）；一页未得才走失败态。
                    if !self.poolCollected.isEmpty {
                        self.poolInterrupted = true
                        self.poolCapped = false
                        self.poolResumeBefore = before
                        self.poolResumeBeforeId = beforeId
                        self.poolResumePage = page
                        self.poolEntries = self.poolCollected
                        self.poolListLoading = false
                        self.renderPoolRows()
                    } else {
                        self.poolListLoading = false
                        if case .waiting = self.step {
                            // 等待屏不走失败态：已投出卡走直取兜底（见 updateWaitingSentCard）。
                            self.updateWaitingSentCard()
                        } else {
                            self.setStep(.error(self.todayErrorText(error)))
                        }
                    }
                }
            }
        }
    }

    /// 选篇渲染目标改为底 sheet（重设计预览口径）：列表变化时推给 sheet；
    /// sheet 未打开时只留数据，打开时再渲染（见 presentPickSheet）；同时
    /// 联动等待屏已投出卡与 sheet 里的加载更多入口。
    private func renderPoolRows() {
        updateWaitingSentCard()
        updatePoolLoadMoreButton()
        pickSheet?.setRows(poolEntries)
    }

    /// completion(true) 仅在拿到新鲜服务端状态并已落到界面时调（收到屏／
    /// 我方撤回／对方撤回）；旧回包丢弃、失败、静默丢弃时调 completion(false)。
    /// 供导航刷新／等待屏刷新在成功时记状态更新时间。
    private func refreshExchangeDetail(id: String, silent: Bool, completion: ((Bool) -> Void)? = nil) {
        if silent == false {
            // r17-m4：只有交换 ID、还没拿到正文时，先写「已换到，正在加载」
            //（setStep(.loading) 消费这行文案；静默校验不显示加载态，不动）。
            loadingStatusText = "已换到，正在加载"
            setStep(.loading)
        }
        // 审计新一轮 02：拍下请求代次与发起账号——每次新请求即让旧请求失效，
        // 撤回成功还会再 +1；旧回包凭代次／交换 ID／账号三重校验丢弃，
        // 不再把已撤回的界面倒退回 .received。
        exchangeDetailGeneration += 1
        let generation = exchangeDetailGeneration
        let requestAccountId = SessionManager.shared.currentUser?.id
        // A2：再拍一份快照（账号 + 会话代次 + 北京日期）：跨日/切号的旧回包
        // 作废重查；代次/交换 ID 的失配仍走下面的三重校验静默丢弃。
        let snapshot = Self.captureBlindBoxSnapshot()
        BearyAPI.shared.fetchBlindBoxExchange(id: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    // 跨日 / 切号后旧回包作废：不写当前桶，重查当前状态。
                    self.loadInitial()
                    completion?(false)
                    return
                }
                guard generation == self.exchangeDetailGeneration else {
                    completion?(false)
                    return
                }
                guard self.exchangeId == id else {
                    completion?(false)
                    return
                }
                guard let accountId = requestAccountId, accountId == SessionManager.shared.currentUser?.id else {
                    completion?(false)
                    return
                }
                // 第九轮 #3：本交换已举报 / 撤回占位，旧回包不得复活正文与图片。
                guard self.exchangeHidden == false else {
                    completion?(false)
                    return
                }
                switch result {
                case .success(let body):
                    // 终态守卫：本地已确认撤回时，只认同说已撤回的回包；旧回包
                    //（myWithdrawn=false）直接丢弃——既不倒退界面，也不拿它
                    // 的 false 覆掉本地撤回旗（applyServerState 在此之后才调）。
                    if BlindBoxState.shared.myWithdrawn, body.myWithdrawn != true {
                        completion?(false)
                        return
                    }
                    BlindBoxState.shared.applyServerState(body, forAccountId: accountId)
                    if body.myWithdrawn == true {
                        BlindBoxState.shared.markMyWithdrawn(forAccountId: accountId)
                        self.exchangeHidden = true
                        self.setStep(.mineWithdrawn)
                        completion?(true)
                        return
                    }
                    if body.receivedWithdrawn == true {
                        BlindBoxState.shared.markReceivedWithdrawn(forAccountId: accountId)
                        self.exchangeHidden = true
                        self.setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
                        completion?(true)
                        return
                    }
                    if let bodyExchangeId = body.exchangeId, bodyExchangeId.isEmpty == false, bodyExchangeId != id {
                        if silent {
                            completion?(false)
                            return
                        }
                        self.setStep(.error("交换记录已变化，请重新进入。"))
                        completion?(false)
                        return
                    }
                    guard let received = body.received, let entryId = received.entryId, entryId.isEmpty == false else {
                        if silent {
                            completion?(false)
                            return
                        }
                        self.setStep(.error("交换记录已变化，请重新进入。"))
                        completion?(false)
                        return
                    }
                    self.exchangeId = body.exchangeId ?? id
                    self.showReceived(received, forExchangeId: id)
                    completion?(true)
                case .failure(let error):
                    if silent {
                        completion?(false)
                        return
                    }
                    self.setStep(.error(self.todayErrorText(error)))
                    completion?(false)
                }
            }
        }
    }

    /// 拿到有效正文后进收到页：从开盒区来（开盒区正在显示）时一出一进
    /// 共用 0.25 秒；再次进页／静默校验时开盒区本就隐藏，直接显示。
    private func showReceived(_ received: BlindBoxReceivedEntry, forExchangeId exchangeId: String) {
        // 渲染前最后一次校验：交换已变、或已举报 / 撤回占位，不渲染、不翻页。
        guard exchangeId == self.exchangeId, exchangeHidden == false else { return }
        self.received = received
        receivedEmotes = received.emotes ?? []
        // 预览头像旁第一行：“一位陌生人”14 semibold 墨色 ＋ “ · 旧日记”
        // 14 常规 muted；第二行日期由 receivedDateLabel 另起一行。
        let whoText = NSMutableAttributedString(string: "一位陌生人", attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold)),
            .foregroundColor: BearyColors.ink,
        ])
        whoText.append(NSAttributedString(string: " · 旧日记", attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14)),
            .foregroundColor: BearyColors.blindBoxMuted,
        ]))
        receivedMetaNameLabel.attributedText = whoText
        let title = (received.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        receivedTitleLabel.text = title.isEmpty ? nil : title
        receivedTitleLabel.isHidden = title.isEmpty
        // 无标题时 meta 行到正文 20；有标题时 meta 到标题 8、标题到正文 12。
        receivedStack.setCustomSpacing(title.isEmpty ? 20 : 8, after: receivedMetaRow)
        receivedDateLabel.text = BlindBoxDate.displayString(ms: received.publishedAt)
        receivedDateLabel.isHidden = receivedDateLabel.text?.isEmpty != false
        renderReceivedContent()
        renderReceivedImages(keys: received.images ?? [])
        renderEmoteChips()
        lastStatusUpdate = Date()
        updateStatusTime()
        setStep(.received, receivedTransition: true)
    }

    /// 正文走共享内联小熊解析器（详情 / 卡片同款）：`[mood:<key>]` 记号转回
    /// 熊脸附件，未知 key 原样留文字。重设计预览口径：18.5 字号、1.75 行距。
    /// 复现未证实：需用一篇含内联小熊的盲盒日记验证（后端是否预处理、
    /// 含记号的盲盒日记是否真露出原串均未核查）。
    private func renderReceivedContent() {
        let content = received?.content ?? ""
        let font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 18.5))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.75
        paragraph.lineBreakMode = .byWordWrapping
        receivedContentLabel.attributedText = BearyText.inlineAttributedText(from: content, font: font, color: BearyColors.ink, paragraphStyle: paragraph, dark: traitCollection.userInterfaceStyle == .dark)
    }

    private func renderReceivedImages(keys: [String]) {
        for sub in imagesStack.arrangedSubviews {
            imagesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for key in keys {
            // 失败不再只剩空框：复用广场 / 详情同款图片失败重试组件
            //（bearyFeedRetryButton：28pt + 官方 icon_refresh，失败时才出现），
            //点按就地重试该图（bearyFeedPerformRetry），不整页重拉。
            let frame = UIView()
            frame.translatesAutoresizingMaskIntoConstraints = false
            frame.backgroundColor = BearyColors.blindBoxSurface2
            frame.layer.cornerRadius = 12
            frame.clipsToBounds = true
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            frame.addSubview(imageView)
            let retry = bearyFeedRetryButton(target: self, action: #selector(receivedImageRetryTapped(_:)))
            frame.addSubview(retry)
            imagesStack.addArrangedSubview(frame)
            NSLayoutConstraint.activate([
                frame.heightAnchor.constraint(equalToConstant: 200),
                imageView.topAnchor.constraint(equalTo: frame.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
                retry.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                retry.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
                retry.widthAnchor.constraint(equalToConstant: 28),
                retry.heightAnchor.constraint(equalToConstant: 28),
            ])
            bearyFeedLoadImage(into: imageView, url: BearyImageURLs.imageURL(key: key, thumb: true), retryButton: retry, downsampleToWidth: nil)
        }
        imagesStack.isHidden = keys.isEmpty
        // 无图时正文到发丝线 24；有图时正文到图 12、图到发丝线 24。
        receivedStack.setCustomSpacing(keys.isEmpty ? 24 : 12, after: receivedContentLabel)
        receivedStack.setCustomSpacing(24, after: imagesStack)
    }

    @objc private func receivedImageRetryTapped(_ sender: BearyFeedRetryButton) {
        bearyFeedPerformRetry(sender)
    }

    // MARK: - 选篇 / 入池 / 开盒（重设计预览口径：点篇即入池并立即开盒）

    /// 开始屏主钮：打开选篇底 sheet。候选列表已在后台拉取；未就绪时 sheet
    /// 显示加载态，无可入池篇时显示空态，不阻塞开始屏。
    @objc private func presentPickSheet() {
        guard presentedViewController == nil else { return }
        let sheet = BlindBoxPickDiarySheetViewController()
        sheet.onPick = { [weak self] entry in self?.pickDiary(entry) }
        sheet.onLoadMore = { [weak self] in self?.didTapPoolLoadMore() }
        pickSheet = sheet
        if poolEntries.isEmpty == false {
            sheet.setRows(poolEntries)
            updatePoolLoadMoreButton()
        } else if poolListLoading {
            sheet.showLoading()
        } else {
            sheet.showEmpty()
        }
        showBlindBoxSheet(sheet, from: self)
    }

    /// 选篇行点按：关 sheet，随即入池并立即开盒（两次点按并成一次；
    /// 先入池再开盒的口径不变，U5）。行本身已按资格禁用，不可入池的行点按无反应。
    private func pickDiary(_ entry: Entry) {
        guard poolBusy == false, let entryId = entry.id, entryId.isEmpty == false else { return }
        guard BlindBoxPool.eligibility(for: entry) == .eligible else { return }
        dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            self?.poolAndOpen(entry)
        }
    }

    /// 入池＋开盒同一轮（旧 poolTapped＋openTapped 合并）：点按即入池，
    /// 成功立即开盒；整轮未完不接受再点（poolBusy 守卫）。
    private func poolAndOpen(_ entry: Entry) {
        guard poolBusy == false, let entryId = entry.id, entryId.isEmpty == false else { return }
        // 点入池时重新校验资格——选中后条目状态可能已变（转私密 /
        // 限时到期等），只靠选中时的一次检查不够；不合格就地拦截并
        // 不发请求、不靠服务端 409 兜底。
        guard let live = poolEntries.first(where: { $0.id == entryId }) else {
            renderPoolRows()
            BearyToast.show(in: self.view, message: "该日记已不在列表中，请重新选择")
            return
        }
        let eligibility = BlindBoxPool.eligibility(for: live)
        guard eligibility == .eligible else {
            renderPoolRows()
            BearyToast.show(in: self.view, message: eligibility.disabledReason ?? "该日记现在不可入池")
            return
        }
        poolBusy = true
        // A2：入池也拍快照（账号 + 会话代次 + 北京日期），与开盒同口径：
        // 跨日 / 切号后旧回包作废重查，不拿旧成功写当前桶。
        let snapshot = Self.captureBlindBoxSnapshot()
        let request = beginBlindBoxRequest()
        BearyAPI.shared.poolBlindBoxEntry(entryId: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    // 跨日 / 切号后旧回包作废：不写当前桶，重查当前状态。
                    self.poolBusy = false
                    self.loadInitial()
                    return
                }
                guard let accountId = request.accountId, self.isCurrentBlindBoxResponse(accountId: accountId, generation: request.generation) else {
                    self.poolBusy = false
                    return
                }
                switch result {
                case .success(let resp):
                    self.pooledEntryId = resp.pooledEntryId ?? entryId
                    self.openBlindBoxAfterPool()
                case .failure(let error):
                    self.poolBusy = false
                    var alreadyPooled = self.isAlreadyPooledError(error)
                    if case .http(let code, _) = error, code == 409 {
                        // 入池侧裸 409 只可能是已入池（入池无“已换过”态），同款重拉。
                        alreadyPooled = true
                    }
                    if alreadyPooled {
                        // 清单 11（跨设备已入池，B 方案）：本机 pooledEntryId 仍为空、
                        // 开盒区仍隐藏，光改 toast 纠不正状态；重拉 today，以服务端
                        // 为准同步 pooledEntryId 与开盒态（多一次往返，拍板接受）。
                        // today 回包经 routeFromToday 路由：已入池→等待屏；
                        // 已换过→占位；已撤回→对应态。
                        BearyToast.show(in: self.view, message: "已在其他设备放进池子，正在同步")
                        self.loadInitial()
                        return
                    }
                    BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "放进池子失败，请重试"))
                    self.setStep(.pool)
                }
            }
        }
    }

    /// 入池成功后立即开盒（poolAndOpen 的第二段）：开盒回包走完整替换，
    /// 入池 / 开盒 / 撤回态与 /today 同口径一次写全。
    private func openBlindBoxAfterPool() {
        let snapshot = Self.captureBlindBoxSnapshot()
        let request = beginBlindBoxRequest()
        BearyAPI.shared.openBlindBox { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.poolBusy = false
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    // 跨日 / 切号后旧回包作废：不写当前桶，重查当前状态。
                    self.loadInitial()
                    return
                }
                guard let openAccountId = request.accountId, self.isCurrentBlindBoxResponse(accountId: openAccountId, generation: request.generation) else { return }
                switch result {
                case .success(let body):
                    BlindBoxState.shared.applyServerState(body)
                    if body.receivedWithdrawn == true {
                        self.exchangeHidden = true
                        self.setStep(.placeholder("对方撤回了交换，这篇日记不再显示。"))
                        return
                    }
                    if let exchangeId = body.exchangeId {
                        BlindBoxState.shared.markOpened(exchangeId: exchangeId, forAccountId: openAccountId)
                        self.exchangeId = exchangeId
                    }
                    if let received = body.received, let exchangeId = self.exchangeId {
                        self.showReceived(received, forExchangeId: exchangeId)
                        return
                    }
                    if let exchangeId = self.exchangeId {
                        self.refreshExchangeDetail(id: exchangeId, silent: false)
                        return
                    }
                    self.setStep(.error("开盒成功但未收到日记，请重新进入。"))
                case .failure(let error):
                    if self.isAlreadyPooledError(error) {
                        // 清单 11（开盒侧已入池）：与入池侧同款——已入池不是已换过，
                        // 不报“今日已换过 1 次”误导；重拉 today 同步开盒态（多一次
                        // 往返，拍板接受），路由结果见 routeFromToday。
                        BearyToast.show(in: self.view, message: "正在同步今日盲盒状态")
                        self.loadInitial()
                        return
                    }
                    if case .http(let code, _) = error, code == 409 {
                        BearyToast.show(in: self.view, message: BearyRepeatedCopy.blindBoxAlreadySwappedToday)
                        self.loadInitial()
                        return
                    }
                    if self.isPoolEmptyError(error) {
                        // 池空：自己那篇仍在池里，不消耗次数——进等待屏（已投出卡
                        // ＋“刷新状态”重试开盒＋撤回），不弹 toast、不重拉、
                        // 不清 pooledEntryId。
                        self.lastStatusUpdate = Date()
                        self.updateStatusTime()
                        self.setStep(.waiting)
                        self.updateWaitingSentCard()
                        return
                    }
                    BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "开盒失败，请重试"))
                    self.setStep(.pool)
                }
            }
        }
    }

    // MARK: - 匿名小熊回应（仅熊脸选择器；乐观更新、失败回滚）

    /// 6 只小熊 key→名字（重设计预览口径，与 BlindBoxBearPickerSheetViewController
    /// 同表；chip 上显示的名字与选择器一致，未知 key 回落 key 本身）。
    private static let blindBoxBearNames: [String: String] = [
        "hug": "抱抱", "love": "爱心", "wink": "开心",
        "happy": "微笑", "comfort": "安慰", "surprised": "惊喜",
    ]

    /// chip 用小图：原图 72pt 直接设给按钮，UIButton 不替调用方缩图，
    /// imageView 72pt 高塞进 36pt chip、又被 masksToBounds 切掉，只剩顶部
    ///（133 真机：只看得见爱心、熊脸基本在 chip 外）。缩到 22pt 再设，
    /// 熊脸完整可见、与 chip 高度匹配。
    private static func chipEmoteImage(_ face: UIImage, side: CGFloat = 22) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = face.scale > 0 ? face.scale : UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in face.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
    }

    /// 小熊回应 chip（重设计预览口径）：44 高药丸，左 34 圆面（熊脸圆面底＋
    /// 30 熊脸图），右侧名字＋计数；自己贴过的走墨底＋浅字。取图按 chip 底色、
    /// 不按系统主题：已选态底是墨色（浅色下近黑、深色下近白），未选态底是
    /// surface2（浅色下浅灰、深色下深灰）；线稿须与底色反色才可见。
    /// 浅色原图是深色线稿，在墨底上看不见（133 真机三 chip 全已选，熊脸只剩
    /// 橙色点缀），已选态浅色下改取深色版（白色线稿），其余组合沿用原按主题取图的口径。
    private func renderEmoteChips() {
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        var visibleEmoteCount = 0
        let isDarkTrait = traitCollection.userInterfaceStyle == .dark
        for count in receivedEmotes {
            guard let key = count.emote, let total = count.count, total > 0 else { continue }
            visibleEmoteCount += 1
            let mine = count.mine == true
            let darkAsset = mine != isDarkTrait
            let face: UIImage?
            if let raw = BearyEmoteImages.image(for: key, dark: darkAsset) {
                face = Self.chipEmoteImage(raw, side: 30)
            } else {
                face = nil
            }
            let chip = BlindBoxEmoteChipView()
            chip.configure(key: key, name: Self.blindBoxBearNames[key] ?? key, count: total, mine: mine, face: face)
            chip.accessibilityLabel = "小熊回应"
            chip.onTap = { [weak self] in self?.emoteChipTapped(key: key) }
            emoteFlowView.addSubview(chip)
        }
        emoteSectionLabel.isHidden = visibleEmoteCount == 0
        emoteFlowView.isHidden = visibleEmoteCount == 0
        // 刚贴上的 chip 播一次 chipIn 弹入（卡片／详情同款口径：0.38s 关键帧
        // 0.4→1.12→1；减动效时不播），随即清掉标记。收到屏未显示时不播
        //（布局宽为 0，位置算不准；贴的动作只发生在收到屏显示时）。
        guard let key = justAddedEmoteKey else { return }
        justAddedEmoteKey = nil
        guard UIAccessibility.isReduceMotionEnabled == false,
              receivedView.window != nil, receivedView.isHidden == false else { return }
        emoteFlowView.layoutIfNeeded()
        guard let chip = emoteFlowView.subviews.compactMap({ $0 as? BlindBoxEmoteChipView }).first(where: { $0.emoteKey == key }) else { return }
        chip.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        chip.alpha = 0
        UIView.animateKeyframes(withDuration: BearyMotion.screen, delay: 0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.6) {
                chip.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                chip.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                chip.transform = .identity
                chip.alpha = 1
            }
        }, completion: nil)
    }

    /// 盲盒回应失败的拒绝动效：0.38s 摇头＋warning 震动＋拒绝音效（与详情/卡片 playDenyShake 同口径；
    /// 减动效时只跳过视觉抖动，震动与音效照常给）。
    private func playDenyShake(on view: UIView) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled { return }
        view.layer.removeAnimation(forKey: "bearyBlindBoxDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = BearyMotion.screen
        view.layer.add(shake, forKey: "bearyBlindBoxDenyShake")
    }

    /// 摇头目标必须是当前在树上的 chip：renderEmoteChips() 全量重建，
    /// 回调闭包里捕获的旧 chip 在乐观渲染时已离树，摇它看不见。
    /// 失败回滚重渲染后按 emoteKey 找新 chip；已摘下（计数归 0）时摇整行。
    private func shakeEmoteChip(forKey key: String) {
        for sub in emoteFlowView.subviews {
            if let chip = sub as? BlindBoxEmoteChipView, chip.emoteKey == key {
                playDenyShake(on: chip)
                return
            }
        }
        playDenyShake(on: emoteFlowView)
    }

    /// chip 点按即切换自己的回应（乐观更新、失败回滚；新增时播 chipIn）。
    private func emoteChipTapped(key: String) {
        guard key.isEmpty == false, reactBusy == false, withdrawBusy == false, let exchangeId = exchangeId else { return }
        let previous = receivedEmotes
        let wasMine = previous.first(where: { $0.emote == key })?.mine == true
        receivedEmotes = toggledEmotes(previous, key: key)
        justAddedEmoteKey = wasMine ? nil : key
        renderEmoteChips()
        reactBusy = true
        let request = beginBlindBoxRequest()
        BearyAPI.shared.reactBlindBoxExchange(id: exchangeId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reactBusy = false
                guard self.isCurrentBlindBoxResponse(accountId: request.accountId, generation: request.generation) else { return }
                switch result {
                case .success(let resp):
                    if let emotes = resp.emotes {
                        self.receivedEmotes = emotes
                        self.renderEmoteChips()
                    }
                case .failure:
                    self.receivedEmotes = previous
                    self.renderEmoteChips()
                    self.shakeEmoteChip(forKey: key)
                    BearyToast.show(in: self.view, message: "回应失败，请重试")
                }
            }
        }
    }

    private func toggledEmotes(_ list: [EmoteCount], key: String) -> [EmoteCount] {
        var next = list
        if let index = next.firstIndex(where: { $0.emote == key }) {
            if next[index].mine == true {
                var item = next[index]
                item.mine = false
                item.count = max(0, (item.count ?? 1) - 1)
                if item.count == 0 {
                    next.remove(at: index)
                } else {
                    next[index] = item
                }
            } else {
                var item = next[index]
                item.mine = true
                item.count = (item.count ?? 0) + 1
                next[index] = item
            }
        } else {
            next.append(EmoteCount(emote: key, count: 1, mine: true))
        }
        return next
    }

    /// 贴一只小熊（重设计预览口径）：新 6 熊选择器底 sheet（3 列网格，
    /// 抱抱／爱心／开心／微笑／安慰／惊喜）；点按即选，乐观更新、失败回滚；
    /// 成功且本次确为“贴上”时 toast 预览文案。
    @objc private func emoteAddTapped() {
        guard let exchangeId = exchangeId, reactBusy == false, withdrawBusy == false else { return }
        guard presentedViewController == nil else { return }
        let sheet = BlindBoxBearPickerSheetViewController()
        sheet.onPick = { [weak self] pickedKey in
            guard let self = self else { return }
            // 2026-10-29 即时性口径：点按瞬间先改填色与计数，服务端回包只做确认，失败回滚。
            let previous = self.receivedEmotes
            let wasMine = previous.first(where: { $0.emote == pickedKey })?.mine == true
            self.receivedEmotes = self.toggledEmotes(previous, key: pickedKey)
            self.justAddedEmoteKey = wasMine ? nil : pickedKey
            self.renderEmoteChips()
            self.reactBusy = true
            let request = self.beginBlindBoxRequest()
            // 审计登录杂项：API 回调改 [weak self]，离页后 VC 不再被留存到回包结束。
            BearyAPI.shared.reactBlindBoxExchange(id: exchangeId, emote: pickedKey) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.reactBusy = false
                    guard self.isCurrentBlindBoxResponse(accountId: request.accountId, generation: request.generation) else { return }
                    switch result {
                    case .success(let resp):
                        if let emotes = resp.emotes {
                            self.receivedEmotes = emotes
                            self.renderEmoteChips()
                        }
                        if self.receivedEmotes.first(where: { $0.emote == pickedKey })?.mine == true {
                            BearyToast.show(in: self.view, message: "贴好了一只「\(Self.blindBoxBearNames[pickedKey] ?? pickedKey)」小熊")
                        }
                    case .failure:
                        self.receivedEmotes = previous
                        self.renderEmoteChips()
                        self.playDenyShake(on: self.emoteFlowView)
                        BearyToast.show(in: self.view, message: "回应失败，请重试")
                    }
                }
            }
        }
        showBlindBoxSheet(sheet, from: self)
    }

    // MARK: - 举报 / 撤回

    /// 举报（重设计预览口径）：一键确认 sheet，不选理由；reason 暂用“其他”
    ///（接口必填，见 BearyReportReason.all）；成功后 toast＋回开始屏。
    @objc private func reportTapped() {
        guard let entryId = received?.entryId, entryId.isEmpty == false else { return }
        guard presentedViewController == nil else { return }
        let sheet = BlindBoxConfirmSheetViewController(
            title: "举报这篇日记",
            message: "举报后这篇日记会从你的盲盒里移除，我们会尽快核看。",
            confirmTitle: "确认举报") { [weak self] in
            guard let self = self else { return }
            // 只传 entry_id：举报流程不接触作者身份；成功后本篇对举报人变占位（见 handleReported）。
            let request = self.beginBlindBoxRequest()
            BearyAPI.shared.reportEntry(entryId: entryId, reason: "其他") { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard self.isCurrentBlindBoxResponse(accountId: request.accountId, generation: request.generation) else { return }
                    switch result {
                    case .success:
                        BearyReportedStore.markReported(entryId: entryId)
                        // 举报即让在途的详情请求失效，并标记本交换已隐藏：迟到的旧回包
                        // 不得把已占位的页面翻回 .received（第九轮 #3）。
                        self.blindBoxGeneration += 1
                        self.exchangeHidden = true
                        self.pooledEntryId = nil
                        NotificationCenter.default.post(name: .bearyDidReportEntry, object: entryId)
                        BearyToast.show(in: self.view, message: "已举报，这篇日记已移除")
                        self.setStep(.pool)
                    case .failure:
                        BearyToast.show(in: self.view, message: "举报失败，请重试")
                    }
                }
            }
        }
        showBlindBoxSheet(sheet, from: self)
    }

    /// 举报广播（他处举报同篇时）：已在收到屏时同样 toast＋回开始屏；
    /// 本页自己发起的举报已在 reportTapped 成功分支里处理完，step 已是
    /// .pool，本守卫直接返回，不重复弹 toast。
    @objc private func handleReported(_ note: Notification) {
        guard case .received = step else { return }
        guard let reportedId = note.object as? String, reportedId == received?.entryId else { return }
        blindBoxGeneration += 1
        exchangeHidden = true
        pooledEntryId = nil
        BearyToast.show(in: self.view, message: "已举报，这篇日记已移除")
        setStep(.pool)
    }

    /// 已收到屏撤回（重设计预览口径）：确认 sheet → 撤回交换；成功后
    /// toast＋进 mineWithdrawn 终态（预览的“回开始屏”会在真实状态机下绕回
    /// mineWithdrawn，故不绕路）。
    @objc private func withdrawTapped() {
        guard withdrawBusy == false, let exchangeId = exchangeId else { return }
        guard presentedViewController == nil else { return }
        let sheet = BlindBoxConfirmSheetViewController(
            title: "撤回交换？",
            message: "撤回后，这篇日记会从你的盲盒里移除，对方贴的小熊也会一起收回。",
            confirmTitle: "撤回交换") { [weak self] in
            guard let self = self else { return }
            self.withdrawBusy = true
            // 撤回即让此前在途的详情请求失效：旧回包不得再翻回 .received。
            let request = self.beginBlindBoxRequest()
            BearyAPI.shared.withdrawBlindBoxExchange(id: exchangeId) { result in
                DispatchQueue.main.async {
                    self.withdrawBusy = false
                    // 审计 26-38：撤回终态不与回应共用代次——撤回确认后发出
                    // 的回应会把共享代次推后，旧守卫会把已成功的撤回回包
                    // 当旧回包丢掉（服务端已撤回、客户端却停在原日记）。
                    // 撤回回包只认账号与交换 ID，不认共享代次；切号 /
                    // 换交换后旧撤回回包仍丢弃。
                    guard let accountId = request.accountId,
                          accountId == SessionManager.shared.currentUser?.id,
                          exchangeId == self.exchangeId else { return }
                    switch result {
                    case .success:
                        // 审计新一轮 02：撤回成功即让此前全部在途详情请求失效
                        //（代次 +1，旧回包凭代次丢弃），再置本地撤回旗、切终态。
                        self.exchangeDetailGeneration += 1
                        BlindBoxState.shared.markMyWithdrawn(forAccountId: accountId)
                        self.exchangeHidden = true
                        BearyToast.show(in: self.view, message: "已撤回这次交换")
                        self.setStep(.mineWithdrawn)
                    case .failure(let error):
                        BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "撤回失败，请重试"))
                    }
                }
            }
        }
        showBlindBoxSheet(sheet, from: self)
    }

    /// 等待屏撤回（重设计预览口径）：确认 sheet → POST /beary/api/blindbox/unpool
    ///（服务端端点待部署，未部署前报“撤回失败，请重试”）；成功后 toast＋回开始屏。
    @objc private func waitingWithdrawTapped() {
        guard withdrawBusy == false, let pooledId = pooledEntryId, pooledId.isEmpty == false else { return }
        guard presentedViewController == nil else { return }
        let sheet = BlindBoxConfirmSheetViewController(
            title: "撤回这次交换？",
            message: "撤回后，这篇日记会从你的盲盒里移除，对方贴的小熊也会一起收回。",
            confirmTitle: "撤回交换") { [weak self] in
            guard let self = self else { return }
            self.withdrawBusy = true
            let request = self.beginBlindBoxRequest()
            BearyAPI.shared.unpoolBlindBoxEntry { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.withdrawBusy = false
                    guard let accountId = request.accountId,
                          accountId == SessionManager.shared.currentUser?.id,
                          pooledId == self.pooledEntryId else { return }
                    switch result {
                    case .success(let body):
                        BlindBoxState.shared.applyServerState(body, forAccountId: accountId)
                        self.pooledEntryId = nil
                        BearyToast.show(in: self.view, message: "已撤回这次交换")
                        self.setStep(.pool)
                    case .failure(let error):
                        BearyToast.show(in: self.view, message: self.actionErrorText(error, fallback: "撤回失败，请重试"))
                    }
                }
            }
        }
        showBlindBoxSheet(sheet, from: self)
    }

    // MARK: - 刷新 / 状态时间（重设计预览口径）

    /// 状态更新时间格式（预览口径“状态更新于 14:13”）：24 小时制 H:mm，北京时间。
    private static let statusTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.timeZone = BlindBoxDate.shanghai
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "H:mm"
        return fmt
    }()

    /// 两屏状态行文案（等待：等待配对；收到：交换已完成）＋更新时间；
    /// lastStatusUpdate 为空时不写（进入两屏与每次刷新成功时记，见 showReceived／
    /// routeFromToday／refreshWaiting）。
    private func updateStatusTime() {
        guard let date = lastStatusUpdate else { return }
        let time = Self.statusTimeFormatter.string(from: date)
        waitingStatusLabel.text = "等待配对 · 状态更新于 \(time)"
        receivedStatusLabel.text = "交换已完成 · 状态更新于 \(time)"
    }

    /// 刷新图标转 0.6s（预览口径）；减动效时不转。
    private func spinRefreshIcon() {
        guard UIAccessibility.isReduceMotionEnabled == false else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 0.6
        rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        refreshNavButton.imageView?.layer.add(rotation, forKey: "bearyBlindBoxRefreshSpin")
    }

    /// 刷新入口共用前置：防重复点按＋转 0.6s；返回 false 表示已有刷新在途。
    private func beginStatusRefresh() -> Bool {
        guard statusRefreshing == false else { return false }
        statusRefreshing = true
        spinRefreshIcon()
        return true
    }

    /// 导航栏右上角刷新（三屏共用）：开始屏／等待屏静默重查今日状态，
    /// 收到屏静默重拉详情；成功时记状态更新时间。加载／登录／占位／
    /// 终态屏不响应（失败态走自己的重试钮）。
    @objc private func refreshTapped() {
        switch step {
        case .pool:
            guard beginStatusRefresh() else { return }
            silentRefreshToday { [weak self] didUpdate in
                guard let self = self else { return }
                self.statusRefreshing = false
                if didUpdate {
                    self.lastStatusUpdate = Date()
                    self.updateStatusTime()
                }
            }
        case .waiting:
            refreshWaiting()
        case .received:
            guard let exchangeId = exchangeId, beginStatusRefresh() else { return }
            refreshExchangeDetail(id: exchangeId, silent: true) { [weak self] didUpdate in
                guard let self = self else { return }
                self.statusRefreshing = false
                if didUpdate {
                    self.lastStatusUpdate = Date()
                    self.updateStatusTime()
                }
            }
        case .error:
            loadInitial()
        default:
            return
        }
    }

    /// 等待屏“刷新状态”：静默重查今日状态（不闪加载页、不弹失败态）；
    /// 配对成功则进收到屏，仍在等待则只记状态更新时间。
    @objc private func refreshWaiting() {
        guard case .waiting = step, beginStatusRefresh() else { return }
        silentRefreshToday { [weak self] didUpdate in
            guard let self = self else { return }
            self.statusRefreshing = false
            if didUpdate {
                self.lastStatusUpdate = Date()
                self.updateStatusTime()
            }
        }
    }

    /// 静默重查今日状态：不闪加载页、不弹失败态；回包走 routeFromToday（静默）。
    /// completion(true) 表示拿到新状态并已路由，false 表示失败／旧回包。
    private func silentRefreshToday(completion: ((Bool) -> Void)? = nil) {
        guard SessionManager.shared.isLoggedIn else {
            completion?(false)
            return
        }
        let identity = BlindBoxRequestIdentity.capture()
        let snapshot = Self.captureBlindBoxSnapshot()
        BearyAPI.shared.fetchBlindBoxToday { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isStaleBlindBoxSnapshot(snapshot) {
                    self.loadInitial()
                    completion?(false)
                    return
                }
                switch result {
                case .success(let body):
                    guard BlindBoxState.shared.applyServerState(body, for: identity) else {
                        self.loadInitial()
                        completion?(false)
                        return
                    }
                    self.routeFromToday(body, silent: true)
                    completion?(true)
                case .failure:
                    completion?(false)
                }
            }
        }
    }

    /// 等待屏已投出卡联动：按 pooledEntryId 在候选列表里找入池篇填卡
    ///（日期＋标题／正文摘录）；列表里没有时（跨设备入池、本地缓存无此篇）
    /// 直取一次该篇（去重一次，失败时留空、不弹失败态）。
    private func updateWaitingSentCard() {
        guard case .waiting = step, let pooledId = pooledEntryId, pooledId.isEmpty == false else { return }
        if let entry = poolEntries.first(where: { $0.id == pooledId }) {
            applySentCard(dateMs: entry.publishedAt ?? entry.createdAt, body: sentCardBody(for: entry))
            waitingCardFetchedEntryId = pooledId
            return
        }
        guard waitingCardFetchedEntryId != pooledId else { return }
        waitingCardFetchedEntryId = pooledId
        BearyAPI.shared.fetchEntry(id: pooledId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, case .waiting = self.step, self.pooledEntryId == pooledId else { return }
                guard case .success(let entry) = result else {
                    self.waitingCardFetchedEntryId = nil
                    return
                }
                self.applySentCard(dateMs: entry.publishedAt ?? entry.createdAt, body: self.sentCardBody(for: entry))
            }
        }
    }

    /// 已投出卡填值（预览 .sent-card：首行 12.5 muted“你投出的 · M月d日 H:mm”，
    /// 次行 16 字、行距 1.65）。
    private func applySentCard(dateMs: Int?, body: String) {
        let dateText = BlindBoxDate.displayString(ms: dateMs)
        sentMetaLabel.text = dateText.isEmpty ? "你投出的" : "你投出的 · \(dateText)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.65
        paragraph.lineBreakMode = .byWordWrapping
        sentBodyLabel.attributedText = NSAttributedString(string: body, attributes: [
            .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16)),
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ])
    }

    /// 已投出卡正文行：有标题写标题，否则写正文摘录（与选篇行同口径）。
    private func sentCardBody(for entry: Entry) -> String {
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty == false { return title }
        let flat = (entry.content ?? "").replacingOccurrences(of: "\n", with: " ")
        return flat.isEmpty ? "（无正文）" : String(flat.prefix(40))
    }

    // MARK: - 错误文案（404 未必是服务端未上线，也可能是路由或单据不存在，不谎称网络问题）

    private func todayErrorText(_ error: APIError) -> String {
        switch error {
        case .unauthorized, .authFailure:
            return "登录已过期，请重新登录"
        case .notFound:
            return BearyRepeatedCopy.blindBoxLoadFailed
        case .http(let code, _):
            if code == 404 { return BearyRepeatedCopy.blindBoxLoadFailed }
            if code == 409 { return BearyRepeatedCopy.blindBoxAlreadySwappedToday }
            return "加载失败，请重试"
        default:
            return "网络不稳定，请稍后再试"
        }
    }

    /// 池空提示：三点齐全——池子里暂时没有可交换的旧公开日记、不是自己
    /// 的日记有问题、晚点 / 明天再来试；不编造具体补货时间与数量。
    /// 只认服务端既有码 pool_empty（.server 直传，或 .http 原始片段含该码
    /// 的兜底），不凭“开盒失败”等通用失败反推池空，不改交换规则与次数口径。
    private static let poolEmptyText = "暂时没有可交换的日记，不是你的日记有问题，晚点再试。"

    /// 清单 11：跨设备已入池码 already_pooled（.server 直传，或 .http 原始片段
    /// 含该码的兜底；与 isPoolEmptyError 同款认码方式）。裸 409 不进本函数——
    /// 开盒侧裸 409 仍走现行“今日已换过 1 次”分支；入池侧裸 409 由
    /// poolAndOpen 单独并入已入池分支（入池无“已换过”态）。
    private func isAlreadyPooledError(_ error: APIError) -> Bool {
        switch error {
        case .server(let code, _):
            return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "already_pooled"
        case .http(_, let snippet):
            if let snippet = snippet {
                return snippet.lowercased().contains("already_pooled")
            }
            return false
        default:
            return false
        }
    }

    private func isPoolEmptyError(_ error: APIError) -> Bool {
        switch error {
        case .server(let code, _):
            return code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pool_empty"
        case .http(_, let snippet):
            if let snippet = snippet {
                return snippet.lowercased().contains("pool_empty")
            }
            return false
        default:
            return false
        }
    }

    private func actionErrorText(_ error: APIError, fallback: String) -> String {
        switch error {
        case .unauthorized, .authFailure:
            return "登录已过期，请重新登录"
        case .notFound:
            return BearyRepeatedCopy.blindBoxLoadFailed
        case .server(let code, _):
            return fallback
        case .http(let code, let snippet):
            if code == 404 { return BearyRepeatedCopy.blindBoxLoadFailed }
            if code == 409 { return BearyRepeatedCopy.blindBoxAlreadySwappedToday }
            return fallback
        default:
            return fallback
        }
    }
}
