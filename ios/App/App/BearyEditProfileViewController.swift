import UIKit
import PhotosUI

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
// 批 D 签名行（2026-10-30）：表单在名字行下方加签名行（58 标签 + 单行输入，
// 占位“写一句属于你的话”，60 字）；保存与名字同走 PUT /api/account/profile
// （字段 signature，清空发 null）。调用方不改：初值由本页经 /me 取 id 后调
// 既有 fetchUserProfile 自取；个人页签名编辑同步移除、只留展示。
// 后端缺口（本 PR 不改后端、不部署）：现行 accounts Worker 的 PUT 分支不处理
// signature 字段，成功回包也不持久化；补分支后 App 无需再改，见 PR 说明。

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
    private var isSaving = false
    /// 批 D 签名行（2026-10-30：编辑统一到本页，个人页只做展示）：
    /// 初值不走调用方（/me 不下发 signature），本页经 /me 取 id 后调既有
    /// fetchUserProfile 自取（见 fetchInitialSignature）；拉不到初值时空输入
    /// 不发（防把未知旧值误删成空），非空输入仍按改动发。
    private var initialSignature: String?
    private var signatureLoaded = false
    private var signatureEdited = false
    private var signatureFetchStarted = false
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

    private lazy var closeButton: BearyHit44Button = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("关闭", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        buttonValue.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private lazy var saveButton: UIButton = {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("保存", for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        buttonValue.addTarget(self, action: #selector(saveButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    /// 1-8：保存进行态圈转指示（贴在保存钮左侧钮外空隙，不占钮内 44 宽，
    /// 故标题恒为“保存”，不再改“保存中…”而被裁字）。
    private let savingSpinner = BearyRefreshIconView()

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

    /// F14：头像包容器（80 头像 + 相机角标），封面下半压 40；头像点按钮
    /// 为 scrollView 级覆盖层（约束锚头像框、后加层级在封面之上，见 buildLayout 末尾），
    /// 故头像区点按仍走换头像、不与封面点按冲突。
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
        badge.layer.bearyDynamicBorderColor = BearyColors.bg
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

    /// 2026-10-29 第 14 项：封面透明点按钮（avatarTapButton 同款模式）——
    /// 封面区被提到最上层的内容列间隙盖住时，点按仍能走到换封面。
    private lazy var coverTapButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(coverTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        buttonValue.accessibilityLabel = "更换封面"
        return buttonValue
    }()

    /// F14：头像本身就是更换入口（网页 edAvaBtn 口径）；旧并排「更换头像」文字钮取消。
    private lazy var avatarTapButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.addTarget(self, action: #selector(avatarButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
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

    /// 批 D 签名行：与名字行同款单行输入（58 标签 + 16 字输入框）；占位与
    /// 个人页未设占位同文案（去 ›，输入框占位不带箭头）；60 字上限与原个人页
    /// 弹框截断口径一致（打字即截断见 delegate，保存时再校验一次）。
    /// 签名行不配图标（表单行统一只有文字标签，不自绘、不补新图标）。
    private let signatureField: UITextField = {
        let fieldValue = UITextField()
        fieldValue.translatesAutoresizingMaskIntoConstraints = false
        fieldValue.font = UIFont.systemFont(ofSize: 16)
        fieldValue.textColor = BearyColors.ink
        fieldValue.attributedPlaceholder = NSAttributedString(string: "写一句属于你的话", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        fieldValue.borderStyle = .none
        fieldValue.autocorrectionType = .no
        fieldValue.clearButtonMode = .whileEditing
        return fieldValue
    }()

    /// F15：网页 ed-subnote 口径——12 灰、仅「修改后 7 天内不能更改」一行；
    /// 旧三规则合并长提示取消（格式规则改由占位文案 + 保存校验承担）。
    private let hintLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 12)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        labelValue.lineBreakMode = .byCharWrapping
        labelValue.text = "修改后 7 天内不能更改"
        return labelValue
    }()

    // MARK: - F12 行（主页链接；id 由 /me 补）
    // C4：邮箱行与账户与安全行已删除，onOpenAccount 回调、emailLabel、
    // accountRowButton、openAccountPage 一并移除（全仓 grep 确认无调用方）。

    /// /me 补到的用户 id（主页链接优先 @handle、无 handle 才回退 /beary/u/<id>）。
    private var fetchedUserId: Int?
    /// 5-4：/me 加载失败标记（与“未登录”区分：失败=success(nil) 之外的 failure）。
    private var meFetchFailed = false

    private let linkLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
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
        buttonValue.layer.bearyDynamicBorderColor = BearyColors.line
        buttonValue.layer.cornerRadius = 16
        buttonValue.addTarget(self, action: #selector(copyLinkButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        // U3：输入框 Return 收起/切换 + 滑动收键盘 + 键盘顶起时调 inset（与登录页同口径）。
        nameField.delegate = self
        signatureField.delegate = self
        handleField.delegate = self
        nameField.returnKeyType = .next
        signatureField.returnKeyType = .next
        handleField.returnKeyType = .done
        signatureField.addTarget(self, action: #selector(signatureFieldChanged), for: .editingChanged)
        scrollView.keyboardDismissMode = .onDrag
        NotificationCenter.default.addObserver(self, selector: #selector(editKeyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editKeyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        nameField.text = initialDisplayName
        handleField.text = initialHandle
        if let avatarPath = initialAvatarUrl, !avatarPath.isEmpty {
            if avatarPath.hasPrefix("data:"),
               let commaIndex = avatarPath.firstIndex(of: ","),
               let avatarData = Data(base64Encoded: String(avatarPath[avatarPath.index(after: commaIndex)...])),
               let avatarImage = UIImage(data: avatarData) {
                // /me 下发的 avatar 本就是 data:image;base64（账户 Worker 直接存 dataURL），
                // BearyImageURLs.avatarURL 遇 data: 会返回 nil，故这里直接解码显示。
                avatarImageView.image = avatarImage
            } else if let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
                avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil)
            }
        }
        if let coverPath = initialCoverUrl, let coverURLValue = BearyImageURLs.avatarURL(coverPath) {
            coverImageView.bearySetImage(url: coverURLValue, placeholder: nil)
        }
        // F14：网页编辑页本就没有移除封面入口，移除钮整组删除（保存逻辑的
        // cover=null 路径保留作将来入口复用，但本页不再提供移除操作）。
        updateDynamicLayerColors()
        // F12：id 不在 init 入参里（不改容器调用点），页内调既有 /me 补齐；
        // C4：邮箱行已删，/me 不再为本页补邮箱（邮箱只在设置页 ID 卡呈现）。
        refreshLinkRowFromMe()
    }

    /// F12：/me 刷新链接行（首启与复制重试共用）：成功记 id、失败记
    /// meFetchFailed；thenCopy 时拿到 handle/id 即补复制，否则按
    /// “未登录”或“加载失败”分别提示，不静默。
    private func refreshLinkRowFromMe(thenCopy: Bool = false) {
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let user):
                    strongSelf.meFetchFailed = false
                    strongSelf.fetchedUserId = user?.id
                    strongSelf.updateLinkRow()
                    strongSelf.fetchInitialSignature()
                    if thenCopy {
                        if !strongSelf.effectiveHandle.isEmpty || strongSelf.fetchedUserId != nil {
                            strongSelf.copyLinkButtonTapped()
                        } else {
                            strongSelf.presentSimpleAlert(message: "先登录")
                        }
                    }
                case .failure:
                    strongSelf.meFetchFailed = true
                    if thenCopy {
                        strongSelf.presentSimpleAlert(message: "加载失败，请重试")
                    }
                }
            }
        }
    }

    /// F12：主页链接文案（@handle 优先口径：有 handle 用 @handle，无 handle
    /// 才回退 /u/id，再无回退 @用户名；与个人主页分享、设置页隐私文案一致）。
    /// 116 数据填入动效：链接行文案随 /me 到达或改名成功变化时只淡入
    /// 该 label 本身（alpha 0→1、0.25s，不动 transform／布局、不重建
    /// 节点、不缩放弹一下）；同值不赋值不重播；减动效或未进窗口时
    /// 直设终值。签名输入框内容为可编辑文档，不做淡入（与编辑器
    /// 表单回填同口径）。
    private func setLinkLabelTextFaded(_ text: String) {
        guard linkLabel.text != text else { return }
        linkLabel.text = text
        guard !UIAccessibility.isReduceMotionEnabled, linkLabel.window != nil else {
            linkLabel.alpha = 1
            return
        }
        linkLabel.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.linkLabel.alpha = 1
        })
    }

    private func updateLinkRow() {
        if !effectiveHandle.isEmpty {
            setLinkLabelTextFaded("主页链接 teddyhn.com/beary/@\(effectiveHandle)")
        } else if let id = fetchedUserId {
            setLinkLabelTextFaded("主页链接 teddyhn.com/beary/u/\(id)")
        } else {
            setLinkLabelTextFaded("主页链接 teddyhn.com/beary/@用户名")
        }
    }

    /// 批 D 签名初值：/me 不下发 signature，故用 /me 拿到的 id 调既有公开资料
    /// 读口（beary Worker profilePayload 已下发 signature，未设为 null）自取；
    /// 只取一次；回包前用户已动手输入时不覆盖已打内容（以 signatureEdited 为准）。
    /// 拉取失败不锁死：占位保留，用户现打的非空内容仍可按改动发。
    private func fetchInitialSignature() {
        guard !signatureFetchStarted, let id = fetchedUserId else { return }
        signatureFetchStarted = true
        BearyAPI.shared.fetchUserProfile(userIdValue: id) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                switch result {
                case .success(let profile):
                    strongSelf.initialSignature = profile.signature
                    strongSelf.signatureLoaded = true
                    if !strongSelf.signatureEdited {
                        strongSelf.signatureField.text = profile.signature
                    }
                case .failure:
                    break
                }
            }
        }
    }

    @objc private func signatureFieldChanged() {
        signatureEdited = true
    }

    /// 批 D 签名改动判定（trim 后比较）：已拉到初值时与初值比；未拉到初值时
    /// 只有非空输入才算改动——空输入不发，避免把未知的旧签名误删成空。
    private var signatureHasChange: Bool {
        let current = (signatureField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if signatureLoaded {
            let initial = (initialSignature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return current != initial
        }
        return !current.isEmpty
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
        copyLinkButton.layer.bearyDynamicBorderColor = BearyColors.line
        avatarCamBadge.layer.bearyDynamicBorderColor = BearyColors.bg
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
        // F14：头像包容器（80 头像 + 相机角标），封面下半压 40；头像点按钮
        // 改为 scrollView 级覆盖层（见本函数末尾），不放在 wrap 内。
        avatarWrap.translatesAutoresizingMaskIntoConstraints = false
        avatarWrap.addSubview(avatarImageView)
        avatarWrap.addSubview(avatarCamBadge)
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
        // 批 D 签名行：位置在名字行下方（与个人页名字下方签名行对应）、
        // 用户名行上方；与名字/用户名行同款 58 标签 + 输入框结构。
        let signatureRow = UIStackView(arrangedSubviews: [makeFormLabel("签名"), signatureField])
        signatureRow.translatesAutoresizingMaskIntoConstraints = false
        signatureRow.axis = .horizontal
        signatureRow.spacing = 14
        signatureRow.alignment = .center
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
            // 提示行下垫 8pt：文案不再贴着下方的分隔线（原 bottom 0 直贴分隔线）。
            hintRow.bottomAnchor.constraint(equalTo: hintWrap.bottomAnchor, constant: -8),
        ])
        // C4：只读邮箱行已删除（标签 + 灰值 + 「不在这里修改」整行移除；
        // 邮箱仍在设置页 ID 卡呈现，不在这里改）。
        let formStack = UIStackView()
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.axis = .vertical
        formStack.spacing = 0
        formStack.alignment = .fill
        formStack.addArrangedSubview(makeFormSeparator())
        formStack.addArrangedSubview(makeFormRowWrap(nameRow))
        formStack.addArrangedSubview(makeFormSeparator())
        formStack.addArrangedSubview(makeFormRowWrap(signatureRow))
        formStack.addArrangedSubview(makeFormSeparator())
        formStack.addArrangedSubview(makeFormRowWrap(handleRow))
        formStack.addArrangedSubview(hintWrap)
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
            copyLinkButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // C4：跳设置页的「账户与安全」行已删除（设置页入口现为个人主页齿轮
        // 直达，不再经编辑页中转；本页只保留 [封面与头像][昵称][用户名 @handle]
        // [主页链接复制]）。
        contentStack.addArrangedSubview(topRow)
        // 1-8：圈转贴在保存钮左侧钮外空隙（不挤占 44 宽标题）。
        // 保存处理转圈与下拉/加载同款 icon_refresh（#224 误用 icon_restore 已回退）。
        savingSpinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 32)
        saveButton.addSubview(savingSpinner)
        NSLayoutConstraint.activate([
            savingSpinner.widthAnchor.constraint(equalToConstant: 20),
            savingSpinner.heightAnchor.constraint(equalToConstant: 20),
            savingSpinner.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            savingSpinner.centerXAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -12),
        ])
        contentStack.addArrangedSubview(avatarWrap)
        contentStack.addArrangedSubview(formStack)
        contentStack.addArrangedSubview(linkWrap)
        // 封面已移出内容列（scrollView 级通栏，见下方 coverImageView 约束，不再吃
        // 内容列左右 20 内边距）；头像半压封面改由顶行后 156 间距实现
        // （180 封面高 + 16 行距 − 40 半压）。
        // F14：头像半压封面（网页 ed-ava-row margin-top:-40 口径），
        // 封面已在内容列外，故这里直接给定行后间距。
        contentStack.setCustomSpacing(156, after: topRow)
        // F12：表单→链接行距 0（链接包容器自带 14 上边距 = 网页 margin-top:14）；
        // C4：链接行已为末行，旧「链接行→账户行距 26」随账户行一并删除。
        contentStack.setCustomSpacing(0, after: formStack)
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
            signatureField.heightAnchor.constraint(equalToConstant: 28),
            handleField.heightAnchor.constraint(equalToConstant: 28),
        ])
        // 封面通栏 + 点按：封面挂 scrollView、左右贴 frameLayoutGuide（与个人主页
        // 封面同款通栏）；点封面走原更换流程（选图/裁剪/上传链路不变，见 coverTapped）。
        // 头像按钮后加（层级在封面之上），故头像区点按仍走换头像、不与封面冲突。
        coverImageView.isUserInteractionEnabled = true
        coverImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(coverTapped)))
        scrollView.addSubview(coverImageView)
        // 头像半压封面：封面后加会盖住头像的上半 40pt（内容列先加、封面后加，
        // 层级上封面在内容列之上），故内容列须提至封面之上，头像整圆才可见；
        // 点按按钮在其后加入、仍保持最上层，换头像点按不受影响。
        scrollView.bringSubviewToFront(contentStack)
        // 2026-10-29 第 14 项：封面点按钮贴整幅封面、层级在内容列之上、
        // 头像钮之下——间隙区点按走换封面，头像区仍走换头像；封面原手势保留作兜底
        // （按钮盖住整幅封面时手势实际不触发）。
        scrollView.addSubview(coverTapButton)
        scrollView.addSubview(avatarTapButton)
        NSLayoutConstraint.activate([
            coverImageView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 16),
            coverImageView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            coverTapButton.topAnchor.constraint(equalTo: coverImageView.topAnchor),
            coverTapButton.leadingAnchor.constraint(equalTo: coverImageView.leadingAnchor),
            coverTapButton.trailingAnchor.constraint(equalTo: coverImageView.trailingAnchor),
            coverTapButton.bottomAnchor.constraint(equalTo: coverImageView.bottomAnchor),
            avatarTapButton.topAnchor.constraint(equalTo: avatarImageView.topAnchor),
            avatarTapButton.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
            avatarTapButton.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor),
            avatarTapButton.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),
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
        if signatureHasChange {
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
        present(alert, animated: BearyMotion.animated(true), completion: nil)
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
        presentImagePicker()
    }

    @objc private func coverTapped() {
        pickingAvatar = false
        presentImagePicker()
    }

    /// F12：主页链接复制（@handle 优先口径：有 handle 复制 @handle 链，无 handle
    /// 才回退 /u/id，两者皆无时先登录；与个人主页分享口径一致）。
    @objc private func copyLinkButtonTapped() {
        if !effectiveHandle.isEmpty {
            UIPasteboard.general.string = "https://teddyhn.com/beary/@\(effectiveHandle)"
        } else if let id = fetchedUserId {
            UIPasteboard.general.string = "https://teddyhn.com/beary/u/\(id)"
        } else if meFetchFailed {
            // 5-4：已登录但 /me 加载失败时不误报“先登录”，给重试
            // （重新拉 /me 再刷新链接行，拿到 id/handle 即补复制）。
            let alert = UIAlertController(title: nil, message: "主页链接加载失败", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "重试", style: .default, handler: { [weak self] _ in
                self?.refreshLinkRowFromMe(thenCopy: true)
            }))
            present(alert, animated: BearyMotion.animated(true), completion: nil)
            return
        } else {
            presentSimpleAlert(message: "先登录")
            return
        }
        copyLinkButton.setTitle("已复制", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyLinkButton.setTitle("复制", for: .normal)
        }
    }

    /// 2026-10-29 第 13 项：老式 UIImagePickerController 进程内加载图库才出界面，
    /// 是“点头像等一会才弹出”的根源（点按与 present 之间并无权限/网络异步，
    /// 慢在 picker 自身的图库加载）。改走 PHPickerViewController（编辑器与反馈页
    /// 同款）：系统外进程、点按即 present、无权限门；图片加载放选后做。
    /// 选后仍走现有 presentCropEditor（头像 1:1、封面按预览比例）与上传链路。
    private func presentImagePicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: BearyMotion.animated(true), completion: nil)
    }

    private func presentSimpleAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default, handler: nil))
        present(alert, animated: BearyMotion.animated(true), completion: nil)
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
        let signatureValue = (signatureField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if signatureValue.count > 60 {
            presentSimpleAlert(message: "签名最多 60 个字")
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
                        // 5-3：改名成功后立即刷新链接行，否则复制新链、显示旧链分裂。
                        strongSelf.updateLinkRow()
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

    /// M14 改（1-8）：保存进行态标题恒为“保存”，只加左侧圈转指示；
    /// 旧“保存中…”4 字在 44 宽钮内会被裁字，故不再改标题，另加禁用。
    private func updateSaveButtonState() {
        saveButton.isEnabled = !isSaving
        saveButton.setTitle("保存", for: .normal)
        if isSaving {
            savingSpinner.startSpinning()
        } else {
            savingSpinner.stopSpinning()
        }
    }

    private func saveProfile(nameValue: String) {
        var body: [String: Any] = [:]
        if nameValue != (initialDisplayName ?? "") {
            body["display_name"] = nameValue
        }
        if avatarChanged, let avatarDataURL = pendingAvatarDataURL {
            body["avatar"] = avatarDataURL
        }
        // 批 D 签名：与名字/头像/封面同走 PUT /api/account/profile，字段名
        // signature，清空发 null（与原个人页弹框口径一致）；只在有改动时发，
        // 未改动不发，避免无意义写。注意后端缺口（见本文件顶注与 PR 说明）：
        // 现行 accounts Worker 的 PUT 分支不处理 signature，成功回包也不持久化；
        // 本页仍按字段名透传，后端补分支后 App 无需再改；保存成功后容器重拉
        // 个人页以服务端为准，未持久化时签名行即回落旧值，不本地谎报已改。
        if signatureHasChange {
            let signatureValue = (signatureField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if signatureValue.isEmpty {
                body["signature"] = NSNull()
            } else {
                body["signature"] = signatureValue
            }
        }
        if coverChanged {
            // 5-15 死分支标注：coverRemoved 当前不可达——移除入口已删
            // （见 viewDidLoad F14 注释），全文件没有任何地方置 true，
            // 仅在裁剪确认时复位 false；保留作将来移除入口复用，
            // 清理时须连同本分支的 cover = NSNull() 一起处理。
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
        // 保存失败：拒绝动效（卡片同款摇头 + warning 震动，减动效只跳过视觉抖动）；
        // 本地草稿保留在输入框内（不清空、不回滚输入），服务端未写入，可直接重试，
        // 改动不静默丢失；登录失效仍走 onRequireLogin（见 profileErrorMessage）。
        playDenyShake(on: saveButton)
        presentSimpleAlert(message: message)
    }

    /// 拒绝动效（卡片 playDenyShake 同口径：values [0,-8,8,-5,5,0] / 0.4s）。
    private func playDenyShake(on button: UIButton) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled { return }
        button.layer.removeAnimation(forKey: "bearyDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        button.layer.add(shake, forKey: "bearyDenyShake")
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
            case "signature_too_long": return "签名最多 60 个字"
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

extension BearyEditProfileViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: BearyMotion.animated(true))
        // 取消（空结果）不弹任何提示、不碰状态；选图后加载放选后做。
        guard let result = results.first else { return }
        let provider = result.itemProvider
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            presentSimpleAlert(message: "图片读取失败")
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                guard let image = object as? UIImage else {
                    strongSelf.presentSimpleAlert(message: "图片读取失败")
                    return
                }
                // 清单第 3 项（编辑资料部分）：选图后先过通用裁剪页，
                // 不再像以前那样直接用原图走压缩。裁剪确认才走原有换图/保存流程
                // （dataURL 压缩 + pending 标记 + 预览替换，保存仍走 PUT
                // /api/account/profile）；裁剪取消不回调、不碰任何待保存状态。
                // 裁剪走通用 BearyImageCropViewController（B 批合并）：
                // 头像 1:1、封面按本页预览比例，见下方 presentCropEditor。
                strongSelf.presentCropEditor(image: image)
            }
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
        let cropVC = BearyImageCropViewController(image: image, aspectRatio: aspectRatio)
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
        present(cropVC, animated: BearyMotion.animated(true))
    }
}

// MARK: - UITextFieldDelegate（U3：名字 Return 切到 handle，handle Return 收键盘）

extension BearyEditProfileViewController: UITextFieldDelegate {
    /// F13：网页 maxlength 口径——打字即截断（名字 30、签名 60、用户名 20；输入法
    /// 组字中不截断，组字结束后的超长部分在下一次输入时截断）。
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if textField.markedTextRange != nil { return true }
        let maxLength: Int
        if textField === nameField {
            maxLength = 30
        } else if textField === signatureField {
            maxLength = 60
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
            signatureField.becomeFirstResponder()
        } else if textField === signatureField {
            handleField.becomeFirstResponder()
        } else if textField === handleField {
            textField.resignFirstResponder()
        }
        return true
    }
}
