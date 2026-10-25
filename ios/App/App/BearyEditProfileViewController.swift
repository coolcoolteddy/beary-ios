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
        imageViewValue.layer.cornerRadius = 14
        return imageViewValue
    }()

    private lazy var changeCoverButton: UIButton = {
        return makeSecondaryButton(title: "更换封面", action: #selector(changeCoverButtonTapped))
    }()

    private lazy var removeCoverButton: UIButton = {
        return makeSecondaryButton(title: "移除封面", action: #selector(removeCoverButtonTapped))
    }()

    private let avatarImageView: UIImageView = {
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.backgroundColor = BearyColors.faint
        imageViewValue.contentMode = .scaleAspectFill
        imageViewValue.clipsToBounds = true
        imageViewValue.layer.cornerRadius = 42
        return imageViewValue
    }()

    private lazy var changeAvatarButton: UIButton = {
        return makeSecondaryButton(title: "更换头像", action: #selector(changeAvatarButtonTapped))
    }()

    private let nameField: UITextField = {
        let fieldValue = UITextField()
        fieldValue.translatesAutoresizingMaskIntoConstraints = false
        fieldValue.font = UIFont.systemFont(ofSize: 15)
        fieldValue.textColor = BearyColors.ink
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径）。
        fieldValue.attributedPlaceholder = NSAttributedString(string: "名字", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 15),
        ])
        fieldValue.borderStyle = .roundedRect
        fieldValue.autocorrectionType = .no
        return fieldValue
    }()

    private let handlePrefixLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 15)
        labelValue.textColor = BearyColors.gray
        labelValue.text = "@"
        return labelValue
    }()

    private let handleField: UITextField = {
        let fieldValue = UITextField()
        fieldValue.translatesAutoresizingMaskIntoConstraints = false
        fieldValue.font = UIFont.systemFont(ofSize: 15)
        fieldValue.textColor = BearyColors.ink
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径）。
        fieldValue.attributedPlaceholder = NSAttributedString(string: "用户名", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 15),
        ])
        fieldValue.borderStyle = .roundedRect
        fieldValue.autocapitalizationType = .none
        fieldValue.autocorrectionType = .no
        return fieldValue
    }()

    private let hintLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = UIFont.systemFont(ofSize: 13)
        labelValue.textColor = BearyColors.gray
        labelValue.numberOfLines = 0
        labelValue.text = "用户名 3–20 位小写字母、数字或下划线；改名后 7 天内不能再改。名字最多 30 个字。"
        return labelValue
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        nameField.text = initialDisplayName
        handleField.text = initialHandle
        if let avatarPath = initialAvatarUrl, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            avatarImageView.bearySetImage(url: avatarURLValue, placeholder: nil)
        }
        if let coverPath = initialCoverUrl, let coverURLValue = BearyImageURLs.avatarURL(coverPath) {
            coverImageView.bearySetImage(url: coverURLValue, placeholder: nil)
        }
        updateDynamicLayerColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDynamicLayerColors()
    }

    private func updateDynamicLayerColors() {
        changeCoverButton.layer.borderColor = BearyColors.line.cgColor
        removeCoverButton.layer.borderColor = BearyColors.line.cgColor
        changeAvatarButton.layer.borderColor = BearyColors.line.cgColor
    }

    private func buildLayout() {
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        let topRow = UIStackView(arrangedSubviews: [closeButton, titleLabel, saveButton])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.axis = .horizontal
        topRow.alignment = .center
        let coverButtonsRow = UIStackView(arrangedSubviews: [changeCoverButton, removeCoverButton])
        coverButtonsRow.translatesAutoresizingMaskIntoConstraints = false
        coverButtonsRow.axis = .horizontal
        coverButtonsRow.spacing = 8
        let avatarRow = UIStackView(arrangedSubviews: [avatarImageView, changeAvatarButton])
        avatarRow.translatesAutoresizingMaskIntoConstraints = false
        avatarRow.axis = .horizontal
        avatarRow.spacing = 12
        avatarRow.alignment = .center
        let handleRow = UIStackView(arrangedSubviews: [handlePrefixLabel, handleField])
        handleRow.translatesAutoresizingMaskIntoConstraints = false
        handleRow.axis = .horizontal
        handleRow.spacing = 4
        handleRow.alignment = .center
        contentStack.addArrangedSubview(topRow)
        contentStack.addArrangedSubview(coverImageView)
        contentStack.addArrangedSubview(coverButtonsRow)
        contentStack.addArrangedSubview(avatarRow)
        contentStack.addArrangedSubview(nameField)
        contentStack.addArrangedSubview(handleRow)
        contentStack.addArrangedSubview(hintLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            saveButton.widthAnchor.constraint(equalToConstant: 44),
            coverImageView.heightAnchor.constraint(equalToConstant: 160),
            changeCoverButton.heightAnchor.constraint(equalToConstant: 40),
            removeCoverButton.heightAnchor.constraint(equalToConstant: 40),
            avatarImageView.widthAnchor.constraint(equalToConstant: 84),
            avatarImageView.heightAnchor.constraint(equalToConstant: 84),
            changeAvatarButton.heightAnchor.constraint(equalToConstant: 40),
            nameField.heightAnchor.constraint(equalToConstant: 44),
            handleField.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - 动作

    @objc private func closeButtonTapped() {
        onCancel?()
    }

    @objc private func changeAvatarButtonTapped() {
        pickingAvatar = true
        lastPickerSourceView = changeAvatarButton
        presentImagePicker()
    }

    @objc private func changeCoverButtonTapped() {
        pickingAvatar = false
        lastPickerSourceView = changeCoverButton
        presentImagePicker()
    }

    @objc private func removeCoverButtonTapped() {
        coverImageView.image = nil
        pendingCoverDataURL = nil
        coverChanged = true
        coverRemoved = true
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
        let handleChanged = handleValue != (initialHandle ?? "")
        if handleChanged {
            if !isValidHandle(handleValue) {
                presentSimpleAlert(message: "用户名需 3–20 位小写字母、数字或下划线")
                return
            }
        }
        isSaving = true
        saveButton.isEnabled = false
        if handleChanged {
            BearyAPI.shared.request("/api/account/handle", method: "POST", jsonBody: ["handle": handleValue]) { [weak self] (result: Result<BearyHandleUpdateResponse, APIError>) in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    switch result {
                    case .success:
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
        saveButton.isEnabled = true
        onSaved?()
    }

    private func finishSavingWithError(message: String) {
        isSaving = false
        saveButton.isEnabled = true
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
            if strongSelf.pickingAvatar {
                guard let dataURL = strongSelf.dataURLForAvatar(image: image) else {
                    strongSelf.presentSimpleAlert(message: "头像太大了，换一张小一点的吧")
                    return
                }
                strongSelf.pendingAvatarDataURL = dataURL
                strongSelf.avatarChanged = true
                strongSelf.avatarImageView.image = image
            } else {
                guard let dataURL = strongSelf.dataURLForCover(image: image) else {
                    strongSelf.presentSimpleAlert(message: "这张图太大了，换一张小一点的吧")
                    return
                }
                strongSelf.pendingCoverDataURL = dataURL
                strongSelf.coverChanged = true
                strongSelf.coverRemoved = false
                strongSelf.coverImageView.image = image
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
    }
}
