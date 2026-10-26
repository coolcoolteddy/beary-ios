import UIKit

// ===== beary 原生编辑资料页（只此一文件；不改 BearyAPI.swift、不改 SceneDelegate、不改 pbxproj）=====
// 对照源（均已先读核实，以服务端为准）：
// - 网页站内编辑页 ~/workspace/teddy_site/beary.html openEditPage / edSaveAll：
//   表单 = 头像 / 封面 / 名字 / handle；保存顺序先 handle、后名字。
// - 账户 Worker ~/workspace/teddy_accounts_v2/worker.js：
//   POST /api/account/handle：body {handle}，格式 ^[a-z0-9_]{3,20}$，7 天冷却
//   （首次改名免冷却：服务端仅当已有 handle 且在冷却内才拦；占用返回 taken）。
//   PUT /api/account/profile：body 按需带 display_name / avatar / cover，
//   名字 ≤30 字且非空时至少含一个文字；头像须为 data:image/*;base64 且
//   长度 ≤200000；封面可为 null（移除）或 data:image/*;base64 且 ≤400000。
//   注意：头像 / 封面没有独立上传端点，网页 edUploadCover / 头像上传同样走
//   PUT /api/account/profile 的 dataURL 字段，本页与之一致。
// - 图片压缩口径照网页：头像居中裁正方形 → 256px JPEG 0.85；
//   封面按 [1280/0.8, 1024/0.72, 880/0.62] 逐档试，取首个 ≤400000 的结果。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；颜色只走 BearyColors；不新增玻璃效果；无 force unwrap；
// 本页不自己 dismiss，保存 / 取消 / 登录失效一律走回调，容器决定去向与刷新。

private struct BearyHandleUpdateResponse: Decodable {
    var ok: Bool?
    var handle: String?
}

private struct BearyProfileUpdateResponse: Decodable {
    var ok: Bool?
}

class BearyEditProfileViewController: UIViewController {

    /// 保存成功后调用：容器接线到刷新个人主页（与关闭编辑页）。
    var onSaved: (() -> Void)?

    /// 点关闭时调用：容器接线到关闭编辑页。
    var onCancel: (() -> Void)?

    /// 保存时会话失效：容器接线到登录页。
    var onRequireLogin: (() -> Void)?

    private let initialDisplayName: String?
    private let initialHandle: String?
    private let initialAvatarUrl: String?
    private let initialCoverUrl: String?

    init(displayName: String?, handle: String?, avatarUrl: String?, coverUrl: String?) {
        self.initialDisplayName = displayName
        self.initialHandle = handle
        self.initialAvatarUrl = avatarUrl
        self.initialCoverUrl = coverUrl
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private var pendingAvatarDataURL: String?
    private var avatarChanged = false
    private var pendingCoverDataURL: String?
    private var coverChanged = false
    private var coverRemoved = false
    private var pickingAvatar = false
    private var lastPickerSourceView: UIView?
    private var isSaving = false
    /// G3：handle POST 成功后立即记下的已提交 handle（initialHandle 是 let，不可改；
    /// 重试时以它为准，不再重发已成功的 handle 步）。
    private var submittedHandle: String?
    /// G3/U1 共用的 handle 比较基线：已提交的优先于初始值。
    private var effectiveHandle: String {
        return submittedHandle ?? initialHandle ?? ""
    }
    /// P2-1：600 列上限约束（宽 ≥821 才激活；宽 ≤820 时停用，改由 750 优先级的
    /// 屏宽 -40 约束撑满，与个人主页 isDesktopColumn 同口径；开关见 viewDidLayoutSubviews）。
    private var contentColumnWidthCap: NSLayoutConstraint?

    private let scrollView: UIScrollView = {
        let scrollViewValue = UIScrollView()
        scrollViewValue.translatesAutoresizingMaskIntoConstraints = false
        return scrollViewValue
    }()

    private let contentStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 16
        stackValue.alignment = .fill
        return stackValue
    }()

    private lazy var closeButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("关闭", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        buttonValue.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private lazy var saveButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("保存", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        buttonValue.addTarget(self, action: #selector(saveButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private let titleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "编辑资料"
        return labelValue
    }()

    private let coverImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        // F14：网页 ed-banner 口径——180 高、无圆角。
        imageViewValue.layer.cornerRadius = 0
        return imageViewValue
    }()

    private lazy var changeCoverButton: UIButton = {
        return makeSecondaryButton(title: "更换封面", action: #selector(changeCoverButtonTapped))
    }()

    /// F14：头像包容器（80 半压封面 + 右下角相机角标，网页 ed-ava 口径）。
    private let avatarWrap = UIView()

    private let avatarImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        imageViewValue.layer.cornerRadius = 40
        return imageViewValue
    }()

    /// F14：相机角标（网页 ed-ava-cam 口径：27 圆、ink 底、2pt bg 边、内 14 相机图）。
    private let avatarCamBadge: UIView = {
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = BearyColors.ink
        badge.layer.cornerRadius = 13.5
        badge.layer.borderWidth = 2
        badge.layer.borderColor = BearyColors.bg.cgColor
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = BearyIconImages.image(named: "icon_camera", pointSize: 14)
        icon.tintColor = BearyColors.bg
        icon.contentMode = .scaleAspectFit
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        return badge
    }()

    /// F14：头像本身就是更换入口（网页 edAvaBtn 口径）；旧并排「更换头像」文字钮取消。
    private lazy var avatarTapButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(avatarButtonTapped), for: .touchUpInside)
        buttonValue.accessibilityLabel = "更换头像"
        return buttonValue
    }()

    private let nameField: UITextField = {
        let fieldValue = UITextField()
        fieldValue.translatesAutoresizingMaskIntoConstraints = false
        // F15：网页 ed-rinput 口径——16 字、无边框矩形框；占位文案同网页。
        fieldValue.font = UIFont.systemFont(ofSize: 16)
        fieldValue.textColor = BearyColors.ink
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径）。
        fieldValue.attributedPlaceholder = NSAttributedString(string: "给自己起个名字", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        fieldValue.borderStyle = .none
        fieldValue.autocorrectionType = .no
        return fieldValue
    }()

    private let handlePrefixLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16)
        labelValue.textColor = BearyColors.gray
        labelValue.text = "@"
        return labelValue
    }()

    private let handleField: UITextField = {
        let fieldValue = UITextField()
        fieldValue.translatesAutoresizingMaskIntoConstraints = false
        fieldValue.font = UIFont.systemFont(ofSize: 16)
        fieldValue.textColor = BearyColors.ink
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径）。
        fieldValue.attributedPlaceholder = NSAttributedString(string: "小写字母、数字或下划线", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        fieldValue.borderStyle = .none
        fieldValue.autocapitalizationType = .none
        fieldValue.autocorrectionType = .no
        return fieldValue
    }()

    /// F15：网页 ed-subnote 口径——12 灰、仅「改名后 7 天内不能再改」一行；
    /// 旧三规则合并长提示取消（格式规则改由占位文案 + 保存校验承担）。
    private let hintLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 12)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        labelValue.lineBreakMode = .byCharWrapping
        labelValue.text = "改名后 7 天内不能再改"
        return labelValue
    }()

    // MARK: - F12 行（主页链接 / 邮箱 / 账户与安全；id 与邮箱由 /me 补）

    /// 账户与安全的容器回调；容器未接线时页内模态兜底（见 openAccountPage）。
    var onOpenAccount: (() -> Void)?

    /// /me 补到的用户 id（主页链接用 /beary/u/<id> 口径，网页 edCopyLink 同款）。
    private var fetchedUserId: Int?

    private let emailLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 16)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 1
        labelValue.lineBreakMode = .byTruncatingTail
        labelValue.text = "–"
        return labelValue
    }()

    private let linkLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 12.5)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 1
        labelValue.lineBreakMode = .byTruncatingTail
        labelValue.text = "主页链接 teddyhn.com/beary/@用户名"
        return labelValue
    }()

    private lazy var copyLinkButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("复制", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        buttonValue.layer.borderWidth = 1
        buttonValue.layer.borderColor = BearyColors.line.cgColor
        buttonValue.layer.cornerRadius = 16
        buttonValue.addTarget(self, action: #selector(copyLinkButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private lazy var accountRowButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(accountRowButtonTapped), for: .touchUpInside)
        return buttonValue
    }()

    private func makeSecondaryButton(title: String, action: Selector) -> UIButton {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle(title, for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        buttonValue.layer.borderWidth = 1
        buttonValue.layer.cornerRadius = 20
        buttonValue.addTarget(self, action: action, for: .touchUpInside)
        return buttonValue
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        // U3：输入框 Return 收起/切换 + 滑动收键盘 + 键盘顶起时调 inset（与登录页同口径）。
        nameField.delegate = self
        handleField.delegate = self
        nameField.returnKeyType = .next
        handleField.returnKeyType = .done
        scrollView.keyboardDismissMode = .onDrag
        NotificationCenter.default.addObserver(self, selector: #selector(editKeyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editKeyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        nameField.text = initialDisplayName
        handleField.text = initialHandle
        if let avatarPath = initialAvatarUrl, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil)
        }
        if let coverPath = initialCoverUrl, let coverURLValue = BearyImageURLs.avatarURL(coverPath) {
            coverImageView.bearySetImage(url: coverURLValue, placeholder: nil)
        }
        // F14：网页编辑页本就没有移除封面入口，移除钮整组删除（保存逻辑的
        // cover=null 路径保留作将来入口复用，但本页不再提供移除操作）。
        updateDynamicLayerColors()
        // F12：id 与邮箱不在 init 入参里（不改容器调用点），页内调既有 /me 补齐。
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                if case .success(let user) = result, let userValue = user {
                    strongSelf.fetchedUserId = userValue.id
                    strongSelf.emailLabel.text = userValue.email ?? "–"
                    strongSelf.updateLinkRow()
                }
            }
        }
    }

    /// F12：主页链接文案（网页 edFillForm/edCopyLink 口径：有 id 用 /u/id，
    /// 无 id 回退 @handle，再无回退 @用户名；复制只认 /u/id，无 id 时先登录）。
    private func updateLinkRow() {
        if let id = fetchedUserId {
            linkLabel.text = "主页链接 teddyhn.com/beary/u/\(id)"
        } else if !effectiveHandle.isEmpty {
            linkLabel.text = "主页链接 teddyhn.com/beary/@\(effectiveHandle)"
        } else {
            linkLabel.text = "主页链接 teddyhn.com/beary/@用户名"
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // P2-1：宽 ≥821 才锁 600 上限；宽 ≤820 时停用上限，屏宽 -40 约束撑满。
        contentColumnWidthCap?.isActive = view.bounds.width >= 821
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDynamicLayerColors()
    }

    private func updateDynamicLayerColors() {
        changeCoverButton.layer.borderColor = BearyColors.line.cgColor
        copyLinkButton.layer.borderColor = BearyColors.line.cgColor
        avatarCamBadge.layer.borderColor = BearyColors.bg.cgColor
    }

    /// F15：表单标签（网页 ed-rlabel 口径：宽 58、15/600）。
    private func makeFormLabel(_ text: String) -> UILabel {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        labelValue.textColor = BearyColors.ink
        labelValue.text = text
        NSLayoutConstraint.activate([
            labelValue.widthAnchor.constraint(equalToConstant: 58),
        ])
        return labelValue
    }

    /// F15：表单行包容器（网页 ed-row 口径：上下 15 内边距）。
    private func makeFormRowWrap(_ inner: UIView) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 15),
            inner.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -15),
        ])
        return wrap
    }

    private func makeFormSeparator() -> UIView {
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = BearyColors.line
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        return separator
    }

    private func buildLayout() {
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        let topRow = UIStackView(arrangedSubviews: [closeButton, titleLabel, saveButton])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.axis = .horizontal
        topRow.alignment = .center
        // F14：头像包容器（80 头像 + 相机角标 + 全幅点按），封面下半压 40。
        avatarWrap.translatesAutoresizingMaskIntoConstraints = false
        avatarWrap.addSubview(avatarImageView)
        avatarWrap.addSubview(avatarCamBadge)
        avatarWrap.addSubview(avatarTapButton)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: avatarWrap.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarWrap.leadingAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: 80),
            avatarImageView.heightAnchor.constraint(equalToConstant: 80),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor),
            avatarCamBadge.widthAnchor.constraint(equalToConstant: 27),
            avatarCamBadge.heightAnchor.constraint(equalToConstant: 27),
            avatarCamBadge.trailingAnchor.constraint(equalTo: avatarWrap.leadingAnchor, constant: 80 + 2),
            avatarCamBadge.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor, constant: 2),
            avatarTapButton.topAnchor.constraint(equalTo: avatarWrap.topAnchor),
            avatarTapButton.leadingAnchor.constraint(equalTo: avatarWrap.leadingAnchor),
            avatarTapButton.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor),
            avatarTapButton.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor),
        ])
        // F14：更换封面钮保留（仅移除「移除封面」钮），移到头像行下方。
        let coverButtonWrap = UIView()
        coverButtonWrap.translatesAutoresizingMaskIntoConstraints = false
        coverButtonWrap.addSubview(changeCoverButton)
        changeCoverButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            changeCoverButton.topAnchor.constraint(equalTo: coverButtonWrap.topAnchor),
            changeCoverButton.leadingAnchor.constraint(equalTo: coverButtonWrap.leadingAnchor),
            changeCoverButton.bottomAnchor.constraint(equalTo: coverButtonWrap.bottomAnchor),
            changeCoverButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        // F15：表单（网页 ed-form 口径：顶边线 + 58 标签行 + 行分隔线）。
        let nameRow = UIStackView(arrangedSubviews: [makeFormLabel("昵称"), nameField])
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.axis = .horizontal
        nameRow.spacing = 14
        nameRow.alignment = .center
        let handleInner = UIStackView(arrangedSubviews: [handlePrefixLabel, handleField])
        handleInner.translatesAutoresizingMaskIntoConstraints = false
        handleInner.axis = .horizontal
        handleInner.spacing = 0
        handleInner.alignment = .center
        let handleRow = UIStackView(arrangedSubviews: [makeFormLabel("用户名"), handleInner])
        handleRow.translatesAutoresizingMaskIntoConstraints = false
        handleRow.axis = .horizontal
        handleRow.spacing = 14
        handleRow.alignment = .center
        // F15：提示行与标签同宽占位（网页 ed-subnote 左 90 = 页边 18 + 标签 58 + 间隙 14；
        // 本页内容列左 20，故占位取 58 + 间隙 14，与标签结构对齐）。
        let hintSpacer = UIView()
        hintSpacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hintSpacer.widthAnchor.constraint(equalToConstant: 58),
        ])
        let hintRow = UIStackView(arrangedSubviews: [hintSpacer, hintLabel])
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        hintRow.axis = .horizontal
        hintRow.spacing = 14
        hintRow.alignment = .center
        let hintWrap = UIView()
        hintWrap.translatesAutoresizingMaskIntoConstraints = false
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        hintWrap.addSubview(hintRow)
        NSLayoutConstraint.activate([
            hintRow.topAnchor.constraint(equalTo: hintWrap.topAnchor, constant: 8),
            hintRow.leadingAnchor.constraint(equalTo: hintWrap.leadingAnchor),
            hintRow.trailingAnchor.constraint(equalTo: hintWrap.trailingAnchor),
            hintRow.bottomAnchor.constraint(equalTo: hintWrap.bottomAnchor),
        ])
        // F12：邮箱行（网页 ed-row 口径：标签 + 灰值 + 「不在这里修改」）。
        let emailSubLabel = UILabel()
        emailSubLabel.translatesAutoresizingMaskIntoConstraints = false
        emailSubLabel.font = UIFont.systemFont(ofSize: 12)
        emailSubLabel.textColor = BearyColors.gray
        emailSubLabel.text = "不在这里修改"
        emailSubLabel.setContentHuggingPriority(.required, for: .horizontal)
        let emailRow = UIStackView(arrangedSubviews: [makeFormLabel("邮箱"), emailLabel, emailSubLabel])
        emailRow.translatesAutoresizingMaskIntoConstraints = false
        emailRow.axis = .horizontal
        emailRow.spacing = 14
        emailRow.alignment = .center
        let formStack = UIStackView()
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.axis = .vertical
        formStack.spacing = 0
        formStack.alignment = .fill
        formStack.addArrangedSubview(makeFormSeparator())
        formStack.addArrangedSubview(makeFormRowWrap(nameRow))
        formStack.addArrangedSubview(makeFormSeparator())
        formStack.addArrangedSubview(makeFormRowWrap(handleRow))
        formStack.addArrangedSubview(hintWrap)
        formStack.addArrangedSubview(makeFormRowWrap(emailRow))
        formStack.addArrangedSubview(makeFormSeparator())
        // F12：主页链接行（网页 ed-linkrow 口径：灰文案 + 复制钮）。
        let linkRow = UIStackView(arrangedSubviews: [linkLabel, copyLinkButton])
        linkRow.translatesAutoresizingMaskIntoConstraints = false
        linkRow.axis = .horizontal
        linkRow.spacing = 10
        linkRow.alignment = .center
        let linkWrap = UIView()
        linkWrap.translatesAutoresizingMaskIntoConstraints = false
        linkRow.translatesAutoresizingMaskIntoConstraints = false
        linkWrap.addSubview(linkRow)
        NSLayoutConstraint.activate([
            linkRow.topAnchor.constraint(equalTo: linkWrap.topAnchor, constant: 14),
            linkRow.leadingAnchor.constraint(equalTo: linkWrap.leadingAnchor),
            linkRow.trailingAnchor.constraint(equalTo: linkWrap.trailingAnchor),
            linkRow.bottomAnchor.constraint(equalTo: linkWrap.bottomAnchor),
            copyLinkButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        // F12：账户与安全行（网页 ed-link-row 口径：标题 + 副文 + 右 chevron，上下边线）。
        let accountTitle = UILabel()
        accountTitle.translatesAutoresizingMaskIntoConstraints = false
        accountTitle.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        accountTitle.textColor = BearyColors.ink
        accountTitle.text = "账户与安全"
        let accountSub = UILabel()
        accountSub.translatesAutoresizingMaskIntoConstraints = false
        accountSub.font = UIFont.systemFont(ofSize: 13)
        accountSub.textColor = BearyColors.gray
        accountSub.text = "登录设备、注销账号"
        let accountChevron = UIImageView()
        accountChevron.translatesAutoresizingMaskIntoConstraints = false
        accountChevron.image = BearyIconImages.image(named: "icon_chevron_right", pointSize: 16)
        accountChevron.tintColor = BearyColors.gray
        accountChevron.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            accountChevron.widthAnchor.constraint(equalToConstant: 16),
            accountChevron.heightAnchor.constraint(equalToConstant: 16),
        ])
        let accountRow = UIStackView(arrangedSubviews: [accountTitle, accountSub, accountChevron])
        accountRow.translatesAutoresizingMaskIntoConstraints = false
        accountRow.axis = .horizontal
        accountRow.spacing = 8
        accountRow.alignment = .center
        let accountWrap = UIView()
        accountWrap.translatesAutoresizingMaskIntoConstraints = false
        accountRow.translatesAutoresizingMaskIntoConstraints = false
        accountWrap.addSubview(accountRow)
        accountWrap.addSubview(accountRowButton)
        NSLayoutConstraint.activate([
            accountRow.topAnchor.constraint(equalTo: accountWrap.topAnchor, constant: 16),
            accountRow.leadingAnchor.constraint(equalTo: accountWrap.leadingAnchor),
            accountRow.trailingAnchor.constraint(equalTo: accountWrap.trailingAnchor),
            accountRow.bottomAnchor.constraint(equalTo: accountWrap.bottomAnchor, constant: -16),
            accountRowButton.topAnchor.constraint(equalTo: accountWrap.topAnchor),
            accountRowButton.leadingAnchor.constraint(equalTo: accountWrap.leadingAnchor),
            accountRowButton.trailingAnchor.constraint(equalTo: accountWrap.trailingAnchor),
            accountRowButton.bottomAnchor.constraint(equalTo: accountWrap.bottomAnchor),
        ])
        let accountStack = UIStackView()
        accountStack.translatesAutoresizingMaskIntoConstraints = false
        accountStack.axis = .vertical
        accountStack.spacing = 0
        accountStack.alignment = .fill
        accountStack.addArrangedSubview(makeFormSeparator())
        accountStack.addArrangedSubview(accountWrap)
        accountStack.addArrangedSubview(makeFormSeparator())
        contentStack.addArrangedSubview(topRow)
        contentStack.addArrangedSubview(coverImageView)
        contentStack.addArrangedSubview(avatarWrap)
        contentStack.addArrangedSubview(coverButtonWrap)
        contentStack.addArrangedSubview(formStack)
        contentStack.addArrangedSubview(linkWrap)
        contentStack.addArrangedSubview(accountStack)
        // F14：头像半压封面（网页 ed-ava-row margin-top:-40 口径）。
        contentStack.setCustomSpacing(-40, after: coverImageView)
        // F12：表单→链接行距 0（链接包容器自带 14 上边距 = 网页 margin-top:14）；
        // 链接行→账户行距 26（网页 ed-link-row margin-top:26 口径）。
        contentStack.setCustomSpacing(0, after: formStack)
        contentStack.setCustomSpacing(26, after: linkWrap)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // L2：底边改走安全区。
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            // L2：内容列最大宽 600 居中——窄屏时宽 = 屏宽 - 40（750 优先级），
            // 宽 ≥821 时被 600 上限压住并居中（P2-1 开关），宽 ≤820 时上限停用、列宽 = 屏宽 -40 撑满。
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            saveButton.widthAnchor.constraint(equalToConstant: 44),
            coverImageView.heightAnchor.constraint(equalToConstant: 180),
            nameField.heightAnchor.constraint(equalToConstant: 28),
            handleField.heightAnchor.constraint(equalToConstant: 28),
        ])
        // L2（续）：窄屏时内容列宽 = 屏宽 - 40（750 优先级；宽 ≥821 时被 600 上限压住）。
        let columnWidth = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        columnWidth.priority = UILayoutPriority(750)
        columnWidth.isActive = true
        // P2-1：600 上限改为可开关约束（初始激活，viewDidLayoutSubviews 按实际宽度纠正）。
        contentColumnWidthCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentColumnWidthCap?.isActive = true
    }

    // MARK: - 动作

    /// U1：未保存改动 = 头像/封面动过，或名字/handle 文本与初始（或已提交 handle）不一致。
    private var hasUnsavedChanges: Bool {
        if avatarChanged || coverChanged {
            return true
        }
        let nameValue = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if nameValue != (initialDisplayName ?? "") {
            return true
        }
        let handleValue = (handleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if handleValue != effectiveHandle {
            return true
        }
        return false
    }

    @objc private func closeButtonTapped() {
        // U1：有关改动时先弹“放弃未保存的改动？”确认，无改动直接关。
        guard hasUnsavedChanges else {
            onCancel?()
            return
        }
        let alert = UIAlertController(title: "放弃未保存的改动？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "放弃", style: .destructive, handler: { [weak self] _ in
            self?.onCancel?()
        }))
        present(alert, animated: true, completion: nil)
    }

    // U3：键盘顶起时调 inset（与登录页同口径：扣掉底部安全区后的键盘高）。
    @objc private func editKeyboardWillShow(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let inset = max(0, frame.height - view.safeAreaInsets.bottom)
        scrollView.contentInset.bottom = inset
        scrollView.verticalScrollIndicatorInsets.bottom = inset
    }

    @objc private func editKeyboardWillHide(_ notification: Notification) {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    @objc private func avatarButtonTapped() {
        pickingAvatar = true
        lastPickerSourceView = avatarTapButton
        presentImagePicker()
    }

    @objc private func changeCoverButtonTapped() {
        pickingAvatar = false
        lastPickerSourceView = changeCoverButton
        presentImagePicker()
    }

    /// F12：主页链接复制（网页 edCopyLink 口径：只认 /u/id，无 id 时先登录）。
    @objc private func copyLinkButtonTapped() {
        guard let id = fetchedUserId else {
            presentSimpleAlert(message: "先登录")
            return
        }
        UIPasteboard.general.string = "https://teddyhn.com/beary/u/\(id)"
        copyLinkButton.setTitle("已复制", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyLinkButton.setTitle("复制", for: .normal)
        }
    }

    /// F12：账户与安全行（网页 ed-link-row → /account 口径）。
    @objc private func accountRowButtonTapped() {
        openAccountPage()
    }

    private func openAccountPage() {
        if let handler = onOpenAccount {
            handler()
            return
        }
        let accountVC = BearySettingsViewController()
        accountVC.modalPresentationStyle = .fullScreen
        accountVC.onClose = { [weak accountVC] in
            accountVC?.dismiss(animated: true)
        }
        accountVC.onRequireLogin = { [weak self, weak accountVC] in
            accountVC?.dismiss(animated: true) {
                self?.onRequireLogin?()
            }
        }
        accountVC.onAccountDeleted = { [weak self, weak accountVC] in
            accountVC?.dismiss(animated: true) {
                self?.onRequireLogin?()
            }
        }
        accountVC.onLoggedOut = { [weak self, weak accountVC] in
            accountVC?.dismiss(animated: true) {
                self?.onRequireLogin?()
            }
        }
        present(accountVC, animated: true)
    }

    private func presentImagePicker() {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
            presentSimpleAlert(message: "相册不可用")
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        if let popover = picker.popoverPresentationController, let sourceView = lastPickerSourceView {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(picker, animated: true, completion: nil)
    }

    private func presentSimpleAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    // MARK: - 保存（网页 edSaveAll 顺序：先 handle、后 profile）

    @objc private func saveButtonTapped() {
        guard !isSaving else { return }
        let nameValue = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let handleValue = (handleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !nameValue.isEmpty && nameValue.count > 30 {
            presentSimpleAlert(message: "显示名称最多 30 个字")
            return
        }
        if !nameValue.isEmpty && nameValue.rangeOfCharacter(from: .alphanumerics) == nil {
            presentSimpleAlert(message: "名字里至少要有一个文字")
            return
        }
        let handleChanged = handleValue != effectiveHandle
        if handleChanged {
            if !isValidHandle(handleValue) {
                presentSimpleAlert(message: "用户名需 3–20 位小写字母、数字或下划线")
                return
            }
        }
        isSaving = true
        updateSaveButtonState()
        if handleChanged {
            BearyAPI.shared.request("/api/account/handle", method: "POST", jsonBody: ["handle": handleValue]) { [weak self] (result: Result<BearyHandleUpdateResponse, APIError>) in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    switch result {
                    case .success:
                        // G3：handle 成功后立即记下已提交 handle；第二步资料失败时
                        // 重试以它为准，跳过已成功的 handle 步，不再重发同一 handle。
                        strongSelf.submittedHandle = handleValue
                        strongSelf.saveProfile(nameValue: nameValue)
                    case .failure(let err):
                        strongSelf.finishSavingWithError(message: strongSelf.handleErrorMessage(err: err))
                    }
                }
            }
        } else {
            saveProfile(nameValue: nameValue)
        }
    }

    /// M14：保存进行态 = “保存中…”文案 + 禁用，不再只有禁用/alpha 变化。
    private func updateSaveButtonState() {
        saveButton.isEnabled = !isSaving
        saveButton.setTitle(isSaving ? "保存中…" : "保存", for: .normal)
    }

    private func saveProfile(nameValue: String) {
        var body: [String: Any] = [:]
        if nameValue != (initialDisplayName ?? "") {
            body["display_name"] = nameValue
        }
        if avatarChanged, let avatarDataURL = pendingAvatarDataURL {
            body["avatar"] = avatarDataURL
        }
        if coverChanged {
            if coverRemoved {
                body["cover"] = NSNull()
            } else if let coverDataURL = pendingCoverDataURL {
                body["cover"] = coverDataURL
            }
        }
        if body.isEmpty {
            finishSavingSuccess()
            return
        }
        BearyAPI.shared.request("/api/account/profile", method: "PUT", jsonBody: body) { [weak self] (result: Result<BearyProfileUpdateResponse, APIError>) in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success:
                    strongSelf.finishSavingSuccess()
                case .failure(let err):
                    strongSelf.finishSavingWithError(message: strongSelf.profileErrorMessage(err: err))
                }
            }
        }
    }

    private func finishSavingSuccess() {
        isSaving = false
        updateSaveButtonState()
        onSaved?()
    }

    private func finishSavingWithError(message: String) {
        isSaving = false
        updateSaveButtonState()
        presentSimpleAlert(message: message)
    }

    private func handleErrorMessage(err: APIError) -> String {
        switch err {
        case .unauthorized:
            onRequireLogin?()
            return "登录已过期，请重新登录"
        case .server(let code):
            switch code {
            case "taken": return "这个用户名已被占用"
            case "cooldown": return "改名冷却中，还不能改"
            case "bad_handle": return "用户名需 3–20 位小写字母、数字或下划线"
            default: return "用户名修改失败"
            }
        default:
            return "用户名修改失败"
        }
    }

    private func profileErrorMessage(err: APIError) -> String {
        switch err {
        case .unauthorized:
            onRequireLogin?()
            return "登录已过期，请重新登录"
        case .server(let code):
            switch code {
            case "name_taken": return "该用户名已被使用"
            case "name_too_long": return "显示名称最多 30 个字"
            case "name_no_text": return "名字里至少要有一个文字"
            case "avatar_too_large": return "头像太大了，换一张小一点的吧"
            case "cover_too_large": return "这张图太大了，换一张小一点的吧"
            default: return "保存失败，请重试"
            }
        default:
            return "保存失败，请重试"
        }
    }

    private func isValidHandle(_ value: String) -> Bool {
        guard value.count >= 3, value.count <= 20 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - 图片压缩（网页 edUploadCover / 头像 256px 口径）

    private func dataURLForAvatar(image: UIImage) -> String? {
        let image = normalizeImage(image: image)
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        guard let cropped = cropImage(image: image, rect: crop) else { return nil }
        let resized = resizeImage(image: cropped, maxDimension: 256)
        for quality in [CGFloat(0.85), CGFloat(0.7), CGFloat(0.5)] {
            if let data = resized.jpegData(compressionQuality: quality) {
                let dataURL = "data:image/jpeg;base64," + data.base64EncodedString()
                if dataURL.count <= 200000 {
                    return dataURL
                }
            }
        }
        return nil
    }

    private func dataURLForCover(image: UIImage) -> String? {
        let image = normalizeImage(image: image)
        let tries: [(CGFloat, CGFloat)] = [(1280, 0.8), (1024, 0.72), (880, 0.62)]
        for (maxWidth, quality) in tries {
            let resized = resizeImage(image: image, maxDimension: maxWidth)
            if let data = resized.jpegData(compressionQuality: quality) {
                let dataURL = "data:image/jpeg;base64," + data.base64EncodedString()
                if dataURL.count <= 400000 {
                    return dataURL
                }
            }
        }
        return nil
    }

    /// 把带方向信息的照片先画成方向朝上的图，避免 cgImage 裁剪坐标错位。
    private func normalizeImage(image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func cropImage(image: UIImage, rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = image.scale
        let pixelRect = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale, width: rect.size.width * scale, height: rect.size.height * scale)
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }

    private func resizeImage(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let ratio = maxDimension / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - 图片选择

extension BearyEditProfileViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        dismiss(animated: true) { [weak self] in
            guard let strongSelf = self else { return }
            guard let image = info[.originalImage] as? UIImage else {
                strongSelf.presentSimpleAlert(message: "图片读取失败")
                return
            }
            // 清单第 3 项（编辑资料部分）：选图后先过本文件内的裁剪页，
            // 不再像以前那样直接用原图走压缩。裁剪确认才走原有换图/保存流程
            // （dataURL 压缩 + pending 标记 + 预览替换，保存仍走 PUT
            // /api/account/profile）；裁剪取消不回调、不碰任何待保存状态。
            // 复用结论见文件末尾 BearyEditProfileCropViewController 注释：
            // 编辑器的 BearyComposerCropViewController 是该文件内的 private 类，
            // 本文件不可见，且写死方形窗，封面宽窗无法用它。
            strongSelf.presentCropEditor(image: image)
        }
    }

    /// 选图 → 裁剪：头像方形窗（1:1），封面按本页封面预览比例
    /// （coverImageView 宽 / 160 高；布局未出时按内容列宽推算）。
    /// 取消：裁剪页自己 dismiss，不回调，本页状态全程不动。
    private func presentCropEditor(image: UIImage) {
        if presentedViewController != nil { return }
        let aspectRatio: CGFloat
        if pickingAvatar {
            aspectRatio = 1
        } else {
            // F14：封面预览高已改 180，裁剪窗比例同步。
            let previewWidth = coverImageView.bounds.width
            if previewWidth > 0 {
                aspectRatio = previewWidth / 180
            } else {
                let columnWidth = min(max(view.bounds.width - 40, 0), 600)
                aspectRatio = columnWidth > 0 ? columnWidth / 180 : 2
            }
        }
        let cropVC = BearyEditProfileCropViewController(image: image, aspectRatio: aspectRatio)
        cropVC.modalPresentationStyle = .fullScreen
        cropVC.onConfirm = { [weak self] cropped in
            guard let strongSelf = self else { return }
            if strongSelf.pickingAvatar {
                guard let dataURL = strongSelf.dataURLForAvatar(image: cropped) else {
                    strongSelf.presentSimpleAlert(message: "头像太大了，换一张小一点的吧")
                    return
                }
                strongSelf.pendingAvatarDataURL = dataURL
                strongSelf.avatarChanged = true
                strongSelf.avatarImageView.image = cropped
            } else {
                guard let dataURL = strongSelf.dataURLForCover(image: cropped) else {
                    strongSelf.presentSimpleAlert(message: "这张图太大了，换一张小一点的吧")
                    return
                }
                strongSelf.pendingCoverDataURL = dataURL
                strongSelf.coverChanged = true
                strongSelf.coverRemoved = false
                strongSelf.coverImageView.image = cropped
            }
        }
        present(cropVC, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
    }
}

// MARK: - UITextFieldDelegate（U3：名字 Return 切到 handle，handle Return 收键盘）

extension BearyEditProfileViewController: UITextFieldDelegate {
    /// F13：网页 maxlength 口径——打字即截断（名字 30、用户名 20；输入法
    /// 组字中不截断，组字结束后的超长部分在下一次输入时截断）。
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if textField.markedTextRange != nil { return true }
        let maxLength: Int
        if textField === nameField {
            maxLength = 30
        } else if textField === handleField {
            maxLength = 20
        } else {
            return true
        }
        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return true }
        let proposed = current.replacingCharacters(in: swiftRange, with: string)
        if proposed.count > maxLength {
            textField.text = String(proposed.prefix(maxLength))
            return false
        }
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField {
            handleField.becomeFirstResponder()
        } else if textField === handleField {
            textField.resignFirstResponder()
        }
        return true
    }
}

// MARK: - 本页裁剪器（清单第 3 项的编辑资料部分；不复用编辑器裁剪器，原因如下）
//
// 未复用 BearyComposerCropViewController 的两个硬原因（均已读 BearyComposerViewController.swift 核实）：
// 1. 不可见：它是该文件内的 `private final class`，Swift private 限本文件，
//    本文件无法引用；改成 internal 需要改编辑器文件，本 lane 只许改本文件，故不能改。
// 2. 窗口写死方形：它的 layoutCropWindow 边长 = 滚动区短边 - 32，
//    头像可用，封面宽窗用它会把封面裁成方形再被预览 aspectFill 拉伸，
//    用户在裁剪页看到的与保存后预览不一致。
// 因此在本文件内实现一个最小通用裁剪器：结构与编辑器裁剪器同款
// （滚动区缩放/拖动 + 四块遮罩 + 白框 + 按窗裁像素，方向先归一化），
// 只多一个 aspectRatio 参数（头像 1，封面按本页预览比例）。
// 取消不回调（调用方状态不动）；确认只回传裁剪图，压缩/待保存标记/保存
// 仍走调用方原有流程，不另起上传链。

private final class BearyEditProfileCropViewController: UIViewController, UIScrollViewDelegate {

    /// 确认回传裁剪图（调用方负责压缩、替换预览与待保存标记；取消不回调）。
    var onConfirm: ((UIImage) -> Void)?

    private let sourceImage: UIImage
    private let aspectRatio: CGFloat
    private let topBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let confirmButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let hintLabel = UILabel()
    private var dimViews: [UIView] = []
    private let cropBorderView = UIView()
    /// 裁剪窗（view 坐标；每布局重算，确认时以它为准）。
    private var cropRect = CGRect.zero
    private var didSetupZoom = false
    private var lastZoomBounds = CGSize.zero

    init(image: UIImage, aspectRatio: CGFloat) {
        self.sourceImage = image
        self.aspectRatio = aspectRatio > 0 ? aspectRatio : 1
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        topBar.backgroundColor = UIColor.black
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(UIColor.white, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        titleLabel.text = "裁剪"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = UIColor.white
        titleLabel.textAlignment = .center
        confirmButton.setTitle("确认", for: .normal)
        confirmButton.setTitleColor(BearyColors.orange, for: .normal)
        confirmButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        confirmButton.addTarget(self, action: #selector(didTapConfirm), for: .touchUpInside)
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = UIColor.black
        imageView.image = sourceImage
        imageView.contentMode = .scaleAspectFit
        hintLabel.text = "双指缩放，拖动调整"
        hintLabel.font = UIFont.systemFont(ofSize: 13)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        hintLabel.textAlignment = .center
        cropBorderView.layer.borderWidth = 1
        cropBorderView.layer.borderColor = UIColor.white.cgColor
        cropBorderView.isUserInteractionEnabled = false
        for v in [topBar, scrollView, hintLabel, cancelButton, titleLabel, confirmButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(topBar)
        topBar.addSubview(cancelButton)
        topBar.addSubview(titleLabel)
        topBar.addSubview(confirmButton)
        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
        view.addSubview(hintLabel)
        // 遮罩四块先加、白框最后加（白框须在遮罩之上；两者均按帧定位，不走约束）。
        for _ in 0..<4 {
            let dim = UIView()
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            dim.isUserInteractionEnabled = false
            view.addSubview(dim)
            dimViews.append(dim)
        }
        view.addSubview(cropBorderView)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            cancelButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            confirmButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            confirmButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            hintLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCropWindow()
        // 首帧与旋转后（滚动区尺寸变了）都重算缩放、回到盖满居中。
        if !didSetupZoom || scrollView.bounds.size != lastZoomBounds {
            didSetupZoom = true
            setupImageZoom()
        }
    }

    /// 裁剪窗：按 aspectRatio（宽/高），在滚动区内留 16pt 边距的前提下
    /// 取最大窗并居中；遮罩四块 + 白框按窗定位。
    private func layoutCropWindow() {
        let bounds = scrollView.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let maxWidth = max(bounds.width - 32, 0)
        let maxHeight = max(bounds.height - 32, 0)
        var windowWidth = maxWidth
        var windowHeight = windowWidth / aspectRatio
        if windowHeight > maxHeight {
            windowHeight = maxHeight
            windowWidth = windowHeight * aspectRatio
        }
        let rectInScroll = CGRect(x: (bounds.width - windowWidth) / 2, y: (bounds.height - windowHeight) / 2, width: windowWidth, height: windowHeight)
        let origin = scrollView.frame.origin
        cropRect = CGRect(x: origin.x + rectInScroll.minX, y: origin.y + rectInScroll.minY, width: windowWidth, height: windowHeight)
        cropBorderView.frame = cropRect
        if dimViews.count == 4 {
            let scrollFrame = scrollView.frame
            dimViews[0].frame = CGRect(x: scrollFrame.minX, y: scrollFrame.minY, width: scrollFrame.width, height: cropRect.minY - scrollFrame.minY)
            dimViews[1].frame = CGRect(x: scrollFrame.minX, y: cropRect.maxY, width: scrollFrame.width, height: scrollFrame.maxY - cropRect.maxY)
            dimViews[2].frame = CGRect(x: scrollFrame.minX, y: cropRect.minY, width: cropRect.minX - scrollFrame.minX, height: cropRect.height)
            dimViews[3].frame = CGRect(x: cropRect.maxX, y: cropRect.minY, width: scrollFrame.maxX - cropRect.maxX, height: cropRect.height)
        }
    }

    /// 图按滚动区等比适配；最小缩放 = 刚好盖满裁剪窗（窗内永不露底），初始即该缩放并居中。
    private func setupImageZoom() {
        let bounds = scrollView.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let imageSize = sourceImage.size
        guard imageSize.width > 0 && imageSize.height > 0 else { return }
        lastZoomBounds = bounds.size
        let fitScale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        let windowWidth = cropRect.width > 0 ? cropRect.width : bounds.width
        let windowHeight = cropRect.height > 0 ? cropRect.height : bounds.height
        let coverScale = max(windowWidth / fitted.width, windowHeight / fitted.height)
        scrollView.minimumZoomScale = coverScale
        scrollView.maximumZoomScale = max(coverScale * 4, coverScale + 1)
        scrollView.zoomScale = coverScale
        let offsetX = max((scrollView.contentSize.width - bounds.width) / 2, 0)
        let offsetY = max((scrollView.contentSize.height - bounds.height) / 2, 0)
        scrollView.contentOffset = CGPoint(x: offsetX, y: offsetY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 内容小于滚动区时居中（否则缩放后图会贴一边）；center 不受缩放变换影响。
        let boundsSize = scrollView.bounds.size
        let offsetX = max((boundsSize.width - scrollView.contentSize.width) * 0.5, 0)
        let offsetY = max((boundsSize.height - scrollView.contentSize.height) * 0.5, 0)
        imageView.center = CGPoint(x: scrollView.contentSize.width * 0.5 + offsetX, y: scrollView.contentSize.height * 0.5 + offsetY)
    }

    @objc private func didTapConfirm() {
        if let cropped = croppedImage() {
            onConfirm?(cropped)
        }
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func didTapCancel() {
        // 取消不回调：调用方 pending/预览/移除钮状态全程不动。
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 按窗裁：窗（view 坐标）→ 滚动区坐标 → 图视图坐标（convert 计入缩放变换）
    /// → 点坐标 → 像素坐标；先把原图方向归一化再裁，避免朝向图的像素坐标错位。
    private func croppedImage() -> UIImage? {
        guard cropRect.width > 0 && cropRect.height > 0 else { return nil }
        guard imageView.bounds.width > 0 && imageView.bounds.height > 0 else { return nil }
        let rectInScroll = scrollView.convert(cropRect, from: view)
        let rectInImageView = imageView.convert(rectInScroll, from: scrollView)
        // 方向归一化：按 size 重绘，原朝向 baked 进像素，cgImage 尺寸即 size×scale。
        let format = UIGraphicsImageRendererFormat()
        format.scale = sourceImage.scale
        let normalized = UIGraphicsImageRenderer(size: sourceImage.size, format: format).image { _ in
            sourceImage.draw(in: CGRect(origin: .zero, size: sourceImage.size))
        }
        guard let cgImage = normalized.cgImage else { return nil }
        let scaleX = normalized.size.width / imageView.bounds.width
        let scaleY = normalized.size.height / imageView.bounds.height
        var pixelRect = CGRect(
            x: rectInImageView.minX * scaleX,
            y: rectInImageView.minY * scaleY,
            width: rectInImageView.width * scaleX,
            height: rectInImageView.height * scaleY
        )
        pixelRect = pixelRect.integral
        pixelRect = pixelRect.intersection(CGRect(origin: .zero, size: normalized.size))
        guard pixelRect.width > 0 && pixelRect.height > 0 else { return nil }
        // cgImage 按像素裁：点坐标须乘 scale（size 是 pt，cgImage 是像素）。
        let cgRect = CGRect(
            x: pixelRect.minX * normalized.scale,
            y: pixelRect.minY * normalized.scale,
            width: pixelRect.width * normalized.scale,
            height: pixelRect.height * normalized.scale
        )
        guard let croppedCG = cgImage.cropping(to: cgRect) else { return nil }
        return UIImage(cgImage: croppedCG, scale: normalized.scale, orientation: .up)
    }
}
