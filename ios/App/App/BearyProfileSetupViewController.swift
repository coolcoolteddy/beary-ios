import UIKit
import PhotosUI

/// 资料页（登录改版 2026-11-26，Luma 式欢迎页的第三页；登录完新注册用户进）：
/// 头像（可点换，带＋角标）＋「完善你的个人资料」＋「向别人介绍一下你自己。」＋
/// 姓名框＋简介框＋右上黑圆勾。城市和生日不在这里问（只在编辑资料里填）。
///
/// 保存走 PUT /api/account/profile（名字／头像 dataURL／简介，与编辑资料页
/// 同款字段；简介服务端现行 PUT 分支不持久化——与编辑资料页同款已知缺口，
/// 本页仍按字段名透传，后端补分支后 App 无需再改）。
/// 名字留空 = 沿用服务端已有名字（不发 display_name），不卡住用户。
/// 本页不自己 dismiss：存完调 onFinished，由容器关页进 App。
final class BearyProfileSetupViewController: UIViewController {

    // MARK: - 容器契约

    var onFinished: (() -> Void)?

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    /// C7（完整复查）：821 断点——仅 iPad 且宽 ≥821 时内容列 600 居中（反馈页同款）；600 上限只在宽屏激活。
    private var contentWidthCap: NSLayoutConstraint?
    private var profileColumnIsWide = false
    private let checkButton = BearyHit44Button()

    private let avatarWrap = UIView()
    private let avatarImageView = UIImageView()
    private let avatarButton = BearyHit44Button()
    private let avatarBadge = UIView()
    private let avatarBadgeIcon = UIImageView()
    /// 头像渐变底（预览 v3：淡紫径向渐变 #EFEDF7→#DDD9EC→#CFC9E2；深浅同值）。
    private var avatarGradientLayer: CAGradientLayer?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private let nameContainer: BearyInputContainer
    private let nameField = UITextField()
    private let nameLabel = UILabel()
    private let nameErrorLabel = UILabel()

    private let bioContainer: BearyInputContainer
    private let bioTextView = UITextView()
    private let bioPlaceholderLabel = UILabel()
    private let bioLabel = UILabel()
    private let bioErrorLabel = UILabel()

    // MARK: - 状态

    private var isSaving = false
    private var avatarChanged = false
    private var pendingAvatarDataURL: String?
    private var initialDisplayName = ""
    private var initialBio = ""
    /// 当前头像区是否正在显示占位笑脸（深浅切换时只刷新占位，不动真头像）。
    private var isShowingAvatarPlaceholder = false

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        nameContainer = BearyInputContainer(content: nameField)
        bioContainer = BearyInputContainer(content: bioTextView)
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        configureFields()
        prefillFromCurrentUser()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // C7：821 断点——仅 iPad 且宽 ≥821 时内容列 600 居中，状态不变不开关，避免布局循环（反馈页同款）。
        let wide = BearyDesktop.isWide(view.bounds.width)
        if wide != profileColumnIsWide {
            profileColumnIsWide = wide
            contentWidthCap?.isActive = wide
        }
        avatarImageView.layer.cornerRadius = avatarImageView.bounds.height / 2
        avatarBadge.layer.cornerRadius = avatarBadge.bounds.height / 2
        checkButton.layer.cornerRadius = checkButton.bounds.height / 2
        avatarGradientLayer?.frame = avatarWrap.bounds
        avatarGradientLayer?.cornerRadius = avatarWrap.bounds.height / 2
        avatarGradientLayer?.masksToBounds = true
    }

    // MARK: - 布局

    private func buildLayout() {
        // 右上黑圆勾（手绘包 icon_check，白字）：保存并进 App。
        checkButton.translatesAutoresizingMaskIntoConstraints = false
        checkButton.backgroundColor = BearyColors.ink
        checkButton.bearyAddPressFeedback()
        checkButton.accessibilityLabel = NSLocalizedString("login.profile.save", comment: "")
        let checkIcon = UIImageView(image: BearyIconImages.image(named: "icon_check", pointSize: 24))
        checkIcon.tintColor = BearyColors.bg
        checkIcon.contentMode = .scaleAspectFit
        checkIcon.isUserInteractionEnabled = false
        checkButton.addSubview(checkIcon)
        NSLayoutConstraint.activate([
            checkIcon.centerXAnchor.constraint(equalTo: checkButton.centerXAnchor),
            checkIcon.centerYAnchor.constraint(equalTo: checkButton.centerYAnchor),
            checkIcon.widthAnchor.constraint(equalToConstant: 24),
            checkIcon.heightAnchor.constraint(equalToConstant: 24),
        ])
        checkButton.addTarget(self, action: #selector(checkButtonTapped), for: .touchUpInside)
        view.addSubview(checkButton)
        NSLayoutConstraint.activate([
            checkButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 60),
            checkButton.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            checkButton.widthAnchor.constraint(equalToConstant: 54),
            checkButton.heightAnchor.constraint(equalToConstant: 54),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = BearySpace.md
        scrollView.addSubview(contentStack)
        // C7：iPad 600 居中（反馈页同款，含 750 宽度等式防短内容压塌；600 上限只在宽屏激活，见 viewDidLayoutSubviews）。
        let contentWidthEquality = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        contentWidthEquality.priority = UILayoutPriority(750)
        contentWidthCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentWidthCap?.isActive = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 33),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentWidthEquality,
        ])

        // 头像（可点换）：圆图＋右下＋角标（手绘包 icon_plus，白字）。
        // 未设头像时显官方表情资产 happy 小熊脸（不是手绘图标，是表情）。
        avatarWrap.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.backgroundColor = .clear
        // 头像渐变底（预览 v3：淡紫径向渐变，圆心 32%/28%，半径取 CSS farthest-corner 99px）。
        let avatarGradient = CAGradientLayer()
        avatarGradient.type = .radial
        avatarGradient.colors = [
            UIColor(red: 239.0 / 255.0, green: 237.0 / 255.0, blue: 247.0 / 255.0, alpha: 1).cgColor,
            UIColor(red: 221.0 / 255.0, green: 217.0 / 255.0, blue: 236.0 / 255.0, alpha: 1).cgColor,
            UIColor(red: 207.0 / 255.0, green: 201.0 / 255.0, blue: 226.0 / 255.0, alpha: 1).cgColor,
        ]
        avatarGradient.locations = [0, 0.45, 1]
        avatarGradient.startPoint = CGPoint(x: 0.32, y: 0.28)
        avatarGradient.endPoint = CGPoint(x: 0.896, y: 0.89)
        avatarWrap.layer.insertSublayer(avatarGradient, at: 0)
        avatarGradientLayer = avatarGradient
        avatarWrap.addSubview(avatarImageView)
        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.backgroundColor = .clear
        avatarButton.accessibilityLabel = NSLocalizedString("login.profile.change_avatar", comment: "")
        avatarButton.addTarget(self, action: #selector(avatarButtonTapped), for: .touchUpInside)
        avatarWrap.addSubview(avatarButton)
        avatarBadge.translatesAutoresizingMaskIntoConstraints = false
        avatarBadge.backgroundColor = .white
        avatarBadge.layer.borderWidth = 1
        avatarBadge.layer.borderColor = UIColor(red: 229.0 / 255.0, green: 229.0 / 255.0, blue: 229.0 / 255.0, alpha: 1).cgColor
        avatarBadge.isUserInteractionEnabled = false
        avatarBadgeIcon.translatesAutoresizingMaskIntoConstraints = false
        avatarBadgeIcon.image = BearyIconImages.image(named: "icon_plus", pointSize: 16)
        avatarBadgeIcon.tintColor = UIColor(red: 85.0 / 255.0, green: 85.0 / 255.0, blue: 85.0 / 255.0, alpha: 1)
        avatarBadgeIcon.contentMode = .scaleAspectFit
        avatarBadge.addSubview(avatarBadgeIcon)
        avatarWrap.addSubview(avatarBadge)
        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: avatarWrap.topAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarWrap.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarWrap.trailingAnchor),
            avatarButton.topAnchor.constraint(equalTo: avatarWrap.topAnchor),
            avatarButton.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor),
            avatarButton.leadingAnchor.constraint(equalTo: avatarWrap.leadingAnchor),
            avatarButton.trailingAnchor.constraint(equalTo: avatarWrap.trailingAnchor),
            avatarBadge.widthAnchor.constraint(equalToConstant: 30),
            avatarBadge.heightAnchor.constraint(equalToConstant: 30),
            avatarBadge.trailingAnchor.constraint(equalTo: avatarWrap.trailingAnchor),
            avatarBadge.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor),
            avatarBadgeIcon.centerXAnchor.constraint(equalTo: avatarBadge.centerXAnchor),
            avatarBadgeIcon.centerYAnchor.constraint(equalTo: avatarBadge.centerYAnchor),
            avatarBadgeIcon.widthAnchor.constraint(equalToConstant: 16),
            avatarBadgeIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
        // 头像居中：stack 默认拉伸，包一层居中容器。
        let avatarOuter = UIView()
        avatarOuter.translatesAutoresizingMaskIntoConstraints = false
        avatarOuter.addSubview(avatarWrap)
        NSLayoutConstraint.activate([
            avatarWrap.centerXAnchor.constraint(equalTo: avatarOuter.centerXAnchor),
            avatarWrap.topAnchor.constraint(equalTo: avatarOuter.topAnchor),
            avatarWrap.bottomAnchor.constraint(equalTo: avatarOuter.bottomAnchor),
            avatarWrap.widthAnchor.constraint(equalToConstant: 118),
            avatarWrap.heightAnchor.constraint(equalToConstant: 118),
        ])
        contentStack.addArrangedSubview(avatarOuter)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = NSLocalizedString("login.profile.title", comment: "")
        titleLabel.font = BearyDynamicType.loginPageTitleFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        contentStack.addArrangedSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = NSLocalizedString("login.profile.subtitle", comment: "")
        subtitleLabel.font = BearyDynamicType.smallBodyFont()
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        contentStack.addArrangedSubview(subtitleLabel)

        // 姓名字段标签（预览 v3：15px 灰，框上 10pt；stack 默认间距 md 12，近似）。
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.text = NSLocalizedString("login.profile.name_label", comment: "")
        nameLabel.font = BearyDynamicType.smallBodyFont()
        nameLabel.textColor = BearyColors.gray
        contentStack.addArrangedSubview(nameLabel)

        // 姓名框＋行内错误。
        contentStack.addArrangedSubview(nameContainer)
        nameContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        nameErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        nameErrorLabel.font = BearyDynamicType.captionFont()
        nameErrorLabel.textColor = BearyColors.destructiveText
        nameErrorLabel.numberOfLines = 0
        nameErrorLabel.isHidden = true
        contentStack.addArrangedSubview(nameErrorLabel)

        // 简介框（多行）＋占位文案＋行内错误。
        bioTextView.textContainerInset = UIEdgeInsets(top: BearySpace.md, left: 0, bottom: BearySpace.md, right: 0)
        bioTextView.textContainer.lineFragmentPadding = 0
        // 简介字段标签（预览 v3：15px 灰，框上 10pt；stack 默认间距 md 12，近似）。
        bioLabel.translatesAutoresizingMaskIntoConstraints = false
        bioLabel.text = NSLocalizedString("login.profile.bio_label", comment: "")
        bioLabel.font = BearyDynamicType.smallBodyFont()
        bioLabel.textColor = BearyColors.gray
        contentStack.addArrangedSubview(bioLabel)

        contentStack.addArrangedSubview(bioContainer)
        bioContainer.heightAnchor.constraint(equalToConstant: 112).isActive = true
        bioPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        bioPlaceholderLabel.text = NSLocalizedString("login.profile.bio_placeholder", comment: "")
        bioPlaceholderLabel.font = BearyDynamicType.fieldFont()
        bioPlaceholderLabel.textColor = BearyColors.gray
        bioPlaceholderLabel.isUserInteractionEnabled = false
        bioContainer.addSubview(bioPlaceholderLabel)
        NSLayoutConstraint.activate([
            bioPlaceholderLabel.leadingAnchor.constraint(equalTo: bioContainer.leadingAnchor, constant: 14),
            bioPlaceholderLabel.topAnchor.constraint(equalTo: bioContainer.topAnchor, constant: BearySpace.md),
        ])
        bioErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        bioErrorLabel.font = BearyDynamicType.captionFont()
        bioErrorLabel.textColor = BearyColors.destructiveText
        bioErrorLabel.numberOfLines = 0
        bioErrorLabel.isHidden = true
        contentStack.addArrangedSubview(bioErrorLabel)

        contentStack.setCustomSpacing(BearySpace.xxl, after: avatarOuter)
        contentStack.setCustomSpacing(BearySpace.sm, after: titleLabel)
        contentStack.setCustomSpacing(BearySpace.xxl, after: subtitleLabel)
        contentStack.setCustomSpacing(BearySpace.xxl, after: nameErrorLabel)
    }

    private func configureFields() {
        nameField.font = BearyDynamicType.fieldFont()
        nameField.adjustsFontForContentSizeCategory = true
        nameField.textColor = BearyColors.ink
        nameField.attributedPlaceholder = NSAttributedString(string: NSLocalizedString("login.profile.name_placeholder", comment: ""), attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.fieldFont(),
        ])
        nameField.autocapitalizationType = .none
        nameField.autocorrectionType = .no
        nameField.returnKeyType = .next
        nameField.delegate = self
        nameField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        bioTextView.font = BearyDynamicType.fieldFont()
        bioTextView.adjustsFontForContentSizeCategory = true
        bioTextView.textColor = BearyColors.ink
        bioTextView.backgroundColor = .clear
        bioTextView.delegate = self
        bioTextView.returnKeyType = .done
    }

    /// 初值：名字取 /me 的 displayName（新注册多半已有服务端默认名）；
    /// 头像取 /me 的 avatar（dataURL 直接解码，否则走头像 URL）；
    /// 没有头像时显官方表情 happy 小熊脸。简介 /me 不下发，留空。
    private func prefillFromCurrentUser() {
        let user = SessionManager.shared.currentUser
        initialDisplayName = (user?.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        nameField.text = initialDisplayName
        updateAvatarPlaceholder()
        guard let avatarPath = user?.avatar, !avatarPath.isEmpty else { return }
        if avatarPath.hasPrefix("data:"),
           let commaIndex = avatarPath.firstIndex(of: ","),
           let avatarData = Data(base64Encoded: String(avatarPath[avatarPath.index(after: commaIndex)...])),
           let avatarImage = UIImage(data: avatarData) {
            // /me 下发的 avatar 本就是 data:image;base64（账户 Worker 直接存 dataURL），
            // BearyImageURLs.avatarURL 遇 data: 会返回 nil，故这里直接解码显示。
            isShowingAvatarPlaceholder = false
            avatarImageView.contentMode = .scaleAspectFill
            avatarImageView.image = avatarImage
        } else if let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            BearyImageLoader.shared.load(url: avatarURLValue, downsampleToWidth: 192) { [weak self] image in
                DispatchQueue.main.async {
                    guard let strongSelf = self, let image = image else { return }
                    strongSelf.isShowingAvatarPlaceholder = false
                    strongSelf.avatarImageView.contentMode = .scaleAspectFill
                    strongSelf.avatarImageView.image = image
                }
            }
        }
    }

    /// 头像占位：显官方表情 happy 小熊脸（深浅跟随）。
    private func updateAvatarPlaceholder() {
        let dark = traitCollection.userInterfaceStyle == .dark
        guard let placeholder = BearyEmoteImages.image(for: "happy", dark: dark) else { return }
        isShowingAvatarPlaceholder = true
        avatarImageView.contentMode = .scaleAspectFit
        avatarImageView.image = placeholder
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 深浅切换时只刷新占位笑脸，已换真实头像的不动。
        guard isShowingAvatarPlaceholder else { return }
        updateAvatarPlaceholder()
    }

    // MARK: - 保存

    @objc private func checkButtonTapped() {
        guard !isSaving else { return }
        let nameValue = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameValue.isEmpty && nameValue.utf16.count > 30 {
            showNameError(NSLocalizedString("login.profile.name_too_long", comment: ""))
            return
        }
        if !nameValue.isEmpty && nameValue.rangeOfCharacter(from: .alphanumerics) == nil {
            showNameError(NSLocalizedString("login.profile.name_needs_text", comment: ""))
            return
        }
        let bioValue = (bioTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if bioValue.utf16.count > 60 {
            bioErrorLabel.text = NSLocalizedString("login.profile.bio_too_long", comment: "")
            bioErrorLabel.isHidden = false
            bioContainer.isError = true
            BearyHaptics.rejectionWarning()
            return
        }
        var body: [String: Any] = [:]
        // 名字留空 = 沿用服务端已有名字，不发 display_name，不卡住用户。
        if !nameValue.isEmpty && nameValue != initialDisplayName {
            body["display_name"] = nameValue
        }
        if avatarChanged, let avatarDataURL = pendingAvatarDataURL {
            body["avatar"] = avatarDataURL
        }
        if bioValue != initialBio {
            if bioValue.isEmpty {
                body["signature"] = NSNull()
            } else {
                body["signature"] = bioValue
            }
        }
        guard !body.isEmpty else {
            // 什么都没改：直接进 App，不发空请求。
            finish()
            return
        }
        isSaving = true
        checkButton.isEnabled = false
        BearyAPI.shared.request("/api/account/profile", method: "PUT", jsonBody: body) { [weak self] (result: Result<BearyProfileSetupResponse, APIError>) in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isSaving = false
                strongSelf.checkButton.isEnabled = true
                switch result {
                case .success:
                    // 存完重拉 /me（新名字／头像进会话），再进 App。
                    SessionManager.shared.refreshMe { _ in
                        strongSelf.finish()
                    }
                case .failure(let err):
                    BearyHaptics.rejectionWarning()
                    BearyToast.show(in: strongSelf.view, message: strongSelf.profileErrorMessage(err: err))
                }
            }
        }
    }

    private func finish() {
        onFinished?()
    }

    private func showNameError(_ message: String) {
        nameErrorLabel.text = message
        nameErrorLabel.isHidden = false
        nameContainer.isError = true
        BearyHaptics.rejectionWarning()
    }

    private func profileErrorMessage(err: APIError) -> String {
        switch err {
        case .server(let message, _) where !message.isEmpty:
            return message
        case .network:
            return NSLocalizedString("login.profile.network_error", comment: "")
        default:
            return NSLocalizedString("login.profile.save_failed", comment: "")
        }
    }

    @objc private func textChanged() {
        nameErrorLabel.isHidden = true
        nameContainer.isError = false
        updateBioPlaceholder()
    }

    private func updateBioPlaceholder() {
        let empty = (bioTextView.text ?? "").isEmpty
        bioPlaceholderLabel.isHidden = !empty
        bioErrorLabel.isHidden = true
        bioContainer.isError = false
    }

    // MARK: - 换头像

    @objc private func avatarButtonTapped() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: BearyMotion.animated(true))
    }

    /// 头像压缩（编辑资料页同款口径）：居中裁 1:1 → 最长边 256 → JPEG，
    /// dataURL ≤ 200000 字符（0.85／0.7／0.5 三档质量依次试）。
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

    private func normalizeImage(image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
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

    // MARK: - 键盘

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInView = view.convert(value.cgRectValue, from: nil)
        let bottom = max(0, view.bounds.height - frameInView.minY - view.safeAreaInsets.bottom)
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? BearyMotion.normal
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curveRaw << 16)) { [weak self] in
            self?.scrollView.contentInset.bottom = bottom
            self?.scrollView.scrollIndicatorInsets.bottom = bottom
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? BearyMotion.normal
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curveRaw << 16)) { [weak self] in
            self?.scrollView.contentInset.bottom = 0
            self?.scrollView.scrollIndicatorInsets.bottom = 0
        }
    }
}

// MARK: - 图片选择

extension BearyProfileSetupViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let result = results.first else {
            picker.dismiss(animated: BearyMotion.animated(true))
            return
        }
        let provider = result.itemProvider
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            picker.dismiss(animated: BearyMotion.animated(true)) { [weak self] in
                guard let strongSelf = self else { return }
                BearyToast.show(in: strongSelf.view, message: NSLocalizedString("login.profile.image_load_failed", comment: ""))
            }
            return
        }
        // 相册退场与图片读取并行，两者都完成才处理（编辑资料页同款口径）。
        var dismissFinished = false
        var loadFinished = false
        var loadedImage: UIImage?
        let deliver: () -> Void = { [weak self] in
            guard dismissFinished, loadFinished else { return }
            guard let strongSelf = self else { return }
            guard let image = loadedImage else {
                BearyToast.show(in: strongSelf.view, message: NSLocalizedString("login.profile.image_load_failed", comment: ""))
                return
            }
            guard let dataURL = strongSelf.dataURLForAvatar(image: image) else {
                BearyToast.show(in: strongSelf.view, message: NSLocalizedString("login.profile.image_load_failed", comment: ""))
                return
            }
            strongSelf.pendingAvatarDataURL = dataURL
            strongSelf.avatarChanged = true
            strongSelf.isShowingAvatarPlaceholder = false
            strongSelf.avatarImageView.contentMode = .scaleAspectFill
            strongSelf.avatarImageView.image = image
        }
        picker.dismiss(animated: BearyMotion.animated(true)) {
            dismissFinished = true
            deliver()
        }
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            DispatchQueue.main.async {
                loadFinished = true
                loadedImage = object as? UIImage
                deliver()
            }
        }
    }
}

// MARK: - UITextFieldDelegate / UITextViewDelegate

extension BearyProfileSetupViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == nameField {
            bioTextView.becomeFirstResponder()
            return true
        }
        return true
    }
}

extension BearyProfileSetupViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateBioPlaceholder()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // 简介框里的回车 = 收键盘（不换行，简介一行足矣）。
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        }
        return true
    }
}

/// PUT /api/account/profile 回包（只取 ok；签名是否落库的诚实判定见编辑资料页，
/// 本页不阻塞进 App——简介服务端缺口见文件头注释）。
private struct BearyProfileSetupResponse: Decodable {
    var ok: Bool?
}
