import UIKit
import PhotosUI

// ===== beary 原生编辑器（第二阶段）=====
// 只负责写日记：正文 + 心情 + 图片（上限 9 张），不含天气。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。
// 文案一律中文；深浅色一律用 BearyColors 的动态色（超字数红字提示除外，见文末注）。
// 网络数据一律不用 force unwrap；图片移除只动本地与 key 列表，不调服务端。

final class BearyComposerViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate {

    // MARK: - 公开接口

    /// 发布成功，传新日记 id。
    var onPublished: ((String) -> Void)?
    /// 关闭编辑器（保留草稿或丢弃后均走这里）。
    var onCancelled: (() -> Void)?
    /// 发布时未登录走这里，不发请求。
    var onRequireLogin: (() -> Void)?

    // MARK: - 心情顺序（硬编码，勿用 moodNames.keys.sorted()，会打乱原顺序）

    private let moodOrder: [String] = [
        "agree", "happy", "applause", "cheer", "comfort", "confused", "love", "determined",
        "facepalm", "shy", "goodnight", "hug", "wink", "idea", "kiss", "thinking",
        "listening", "lonely", "speechless", "nope", "surprised", "pat", "peek", "sleepy",
        "proud", "shrug", "sorry", "cry", "angry", "thanks", "zap", "wave",
        "candle", "flower", "letter", "paperplane", "sprout", "tea", "umbrella", "wish",
    ]

    private static let maxLength = 2000
    private static let maxImages = 9

    // MARK: - 状态

    private var selectedMood: String?
    private var draftClientReq: String?
    private var isPublishing = false
    private var draftTimer: Timer?
    private var imageItems: [ComposerImageItem] = []
    private var moodButtons: [(key: String, button: UIButton)] = []

    // MARK: - 视图

    private let topBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let publishButton = UIButton(type: .system)
    private let topSeparator = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let countLabel = UILabel()
    private let moodTitleLabel = UILabel()
    private let moodScrollView = UIScrollView()
    private let moodStackView = UIStackView()
    private let imageTitleLabel = UILabel()
    private let imageScrollView = UIScrollView()
    private let imageStackView = UIStackView()
    private let addImageContainer = UIView()
    private let addImageButton = UIButton(type: .system)

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        buildTopBar()
        buildTextArea()
        buildMoodRow()
        buildImageRow()
        restoreDraft()
        updateCountLabel()
        updatePublishState()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        draftTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 布局

    private func buildLayout() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func buildTopBar() {
        topBar.backgroundColor = BearyColors.surface
        topSeparator.backgroundColor = BearyColors.line
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(BearyColors.blue, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        titleLabel.text = "写日记"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        publishButton.setTitle("发布", for: .normal)
        publishButton.setTitleColor(BearyColors.orange, for: .normal)
        publishButton.setTitleColor(BearyColors.gray, for: .disabled)
        publishButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        publishButton.addTarget(self, action: #selector(didTapPublish), for: .touchUpInside)
        for v in [cancelButton, titleLabel, publishButton, topSeparator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            publishButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            publishButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    private func buildTextArea() {
        textView.delegate = self
        textView.font = UIFont.systemFont(ofSize: 17)
        textView.textColor = BearyColors.ink
        textView.backgroundColor = BearyColors.faint
        textView.layer.cornerRadius = 12
        textView.layer.masksToBounds = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        placeholderLabel.text = "写下今天…"
        placeholderLabel.font = UIFont.systemFont(ofSize: 17)
        placeholderLabel.textColor = BearyColors.gray
        countLabel.font = UIFont.systemFont(ofSize: 13)
        countLabel.textColor = BearyColors.gray
        countLabel.textAlignment = .right
        for v in [textView, placeholderLabel, countLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(textView)
        textView.addSubview(placeholderLabel)
        contentView.addSubview(countLabel)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 280),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -8),
            countLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
        ])
    }

    private func buildMoodRow() {
        moodTitleLabel.text = "心情"
        moodTitleLabel.font = UIFont.systemFont(ofSize: 14)
        moodTitleLabel.textColor = BearyColors.gray
        moodScrollView.showsHorizontalScrollIndicator = false
        moodStackView.axis = .horizontal
        moodStackView.spacing = 8
        moodStackView.alignment = .center
        for v in [moodTitleLabel, moodScrollView, moodStackView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(moodTitleLabel)
        contentView.addSubview(moodScrollView)
        moodScrollView.addSubview(moodStackView)
        NSLayoutConstraint.activate([
            moodTitleLabel.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 20),
            moodTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            moodScrollView.topAnchor.constraint(equalTo: moodTitleLabel.bottomAnchor, constant: 8),
            moodScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            moodScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            moodScrollView.heightAnchor.constraint(equalToConstant: 36),
            moodStackView.topAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.topAnchor),
            moodStackView.bottomAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.bottomAnchor),
            moodStackView.leadingAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            moodStackView.trailingAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            moodStackView.heightAnchor.constraint(equalTo: moodScrollView.frameLayoutGuide.heightAnchor),
        ])
        for key in moodOrder {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            let name = BearyText.moodNames[key] ?? key
            button.setTitle(name, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            button.layer.cornerRadius = 16
            button.layer.masksToBounds = true
            button.layer.borderWidth = 1
            button.addTarget(self, action: #selector(didTapMood(_:)), for: .touchUpInside)
            moodButtons.append((key: key, button: button))
            moodStackView.addArrangedSubview(button)
        }
        refreshMoodButtons()
    }

    private func buildImageRow() {
        imageTitleLabel.text = "图片"
        imageTitleLabel.font = UIFont.systemFont(ofSize: 14)
        imageTitleLabel.textColor = BearyColors.gray
        imageScrollView.showsHorizontalScrollIndicator = false
        imageStackView.axis = .horizontal
        imageStackView.spacing = 8
        imageStackView.alignment = .center
        addImageButton.setTitle("+", for: .normal)
        addImageButton.titleLabel?.font = UIFont.systemFont(ofSize: 28)
        addImageButton.setTitleColor(BearyColors.gray, for: .normal)
        addImageButton.addTarget(self, action: #selector(didTapAddImage), for: .touchUpInside)
        addImageContainer.backgroundColor = BearyColors.faint
        addImageContainer.layer.cornerRadius = 12
        addImageContainer.layer.masksToBounds = true
        addImageContainer.layer.borderWidth = 1
        addImageContainer.layer.borderColor = BearyColors.line.cgColor
        for v in [imageTitleLabel, imageScrollView, imageStackView, addImageContainer, addImageButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(imageTitleLabel)
        contentView.addSubview(imageScrollView)
        imageScrollView.addSubview(imageStackView)
        imageStackView.addArrangedSubview(addImageContainer)
        addImageContainer.addSubview(addImageButton)
        NSLayoutConstraint.activate([
            imageTitleLabel.topAnchor.constraint(equalTo: moodScrollView.bottomAnchor, constant: 20),
            imageTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            imageScrollView.topAnchor.constraint(equalTo: imageTitleLabel.bottomAnchor, constant: 8),
            imageScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageScrollView.heightAnchor.constraint(equalToConstant: 80),
            imageScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            imageStackView.topAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.topAnchor),
            imageStackView.bottomAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.bottomAnchor),
            imageStackView.leadingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            imageStackView.trailingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            imageStackView.heightAnchor.constraint(equalTo: imageScrollView.frameLayoutGuide.heightAnchor),
            addImageContainer.widthAnchor.constraint(equalToConstant: 72),
            addImageContainer.heightAnchor.constraint(equalToConstant: 72),
            addImageButton.topAnchor.constraint(equalTo: addImageContainer.topAnchor),
            addImageButton.bottomAnchor.constraint(equalTo: addImageContainer.bottomAnchor),
            addImageButton.leadingAnchor.constraint(equalTo: addImageContainer.leadingAnchor),
            addImageButton.trailingAnchor.constraint(equalTo: addImageContainer.trailingAnchor),
        ])
    }

    // MARK: - 正文与字数

    func textViewDidChange(_ textView: UITextView) {
        updateCountLabel()
        updatePublishState()
        scheduleDraftSave()
    }

    private func trimmedContent() -> String {
        return textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateCountLabel() {
        let count = textView.text.count
        countLabel.text = "\(count) / \(BearyComposerViewController.maxLength)"
        if count > BearyComposerViewController.maxLength {
            countLabel.textColor = UIColor.systemRed
        } else {
            countLabel.textColor = BearyColors.gray
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private func hasUploadingImage() -> Bool {
        for item in imageItems {
            if item.uploading {
                return true
            }
        }
        return false
    }

    private func updatePublishState() {
        let trimmed = trimmedContent()
        let overLimit = textView.text.count > BearyComposerViewController.maxLength
        publishButton.isEnabled = !isPublishing && !trimmed.isEmpty && !overLimit && !hasUploadingImage()
    }

    // MARK: - 心情

    private func refreshMoodButtons() {
        for pair in moodButtons {
            let button = pair.button
            if pair.key == selectedMood {
                button.backgroundColor = BearyColors.orange
                button.setTitleColor(UIColor.white, for: .normal)
                button.layer.borderColor = BearyColors.orange.cgColor
            } else {
                button.backgroundColor = BearyColors.faint
                button.setTitleColor(BearyColors.ink, for: .normal)
                button.layer.borderColor = BearyColors.line.cgColor
            }
        }
    }

    @objc private func didTapMood(_ sender: UIButton) {
        var tappedKey: String?
        for pair in moodButtons {
            if pair.button == sender {
                tappedKey = pair.key
            }
        }
        guard let key = tappedKey else { return }
        if selectedMood == key {
            selectedMood = nil
        } else {
            selectedMood = key
        }
        refreshMoodButtons()
        scheduleDraftSave()
    }

    // MARK: - 图片条

    private func createImageItem(localImage: UIImage?, key: String?, uploading: Bool, localFile: String?, failed: Bool) -> ComposerImageItem {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.faint
        container.layer.cornerRadius = 12
        container.layer.masksToBounds = true
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = localImage
        imageView.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapImageItem(_:)))
        imageView.addGestureRecognizer(tap)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        // 失败态：半透明图 + “重试”标签，点图重试，不弹全局框。
        let retryLabel = UILabel()
        retryLabel.translatesAutoresizingMaskIntoConstraints = false
        retryLabel.text = "重试"
        retryLabel.font = UIFont.boldSystemFont(ofSize: 12)
        retryLabel.textColor = UIColor.white
        retryLabel.backgroundColor = BearyColors.ink.withAlphaComponent(0.6)
        retryLabel.textAlignment = .center
        retryLabel.layer.cornerRadius = 8
        retryLabel.layer.masksToBounds = true
        retryLabel.isHidden = !failed
        let removeButton = UIButton(type: .system)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setTitle("×", for: .normal)
        removeButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        removeButton.setTitleColor(UIColor.white, for: .normal)
        removeButton.backgroundColor = BearyColors.ink.withAlphaComponent(0.6)
        removeButton.layer.cornerRadius = 10
        removeButton.layer.masksToBounds = true
        removeButton.addTarget(self, action: #selector(didTapRemoveImage(_:)), for: .touchUpInside)
        container.addSubview(imageView)
        container.addSubview(spinner)
        container.addSubview(retryLabel)
        container.addSubview(removeButton)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 72),
            container.heightAnchor.constraint(equalToConstant: 72),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            retryLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            retryLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            retryLabel.widthAnchor.constraint(equalToConstant: 44),
            retryLabel.heightAnchor.constraint(equalToConstant: 22),
            removeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            removeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            removeButton.widthAnchor.constraint(equalToConstant: 20),
            removeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        if uploading {
            spinner.startAnimating()
        }
        if failed {
            imageView.alpha = 0.55
        }
        let item = ComposerImageItem(key: key, uploading: uploading, localFile: localFile, failed: failed, container: container, imageView: imageView, spinner: spinner, retryLabel: retryLabel, removeButton: removeButton)
        return item
    }

    // MARK: - 上传状态（上传中 / 已传 / 失败三态；失败只亮重试态，不弹框）

    private func markUploading(_ item: ComposerImageItem) {
        item.uploading = true
        item.failed = false
        item.retryLabel.isHidden = true
        item.imageView.alpha = 1.0
        item.spinner.startAnimating()
    }

    private func markUploaded(_ item: ComposerImageItem, key: String) {
        item.key = key
        item.uploading = false
        item.failed = false
        item.retryLabel.isHidden = true
        item.imageView.alpha = 1.0
        item.spinner.stopAnimating()
    }

    private func markFailed(_ item: ComposerImageItem) {
        item.uploading = false
        item.failed = true
        item.retryLabel.isHidden = false
        item.imageView.alpha = 0.55
        item.spinner.stopAnimating()
    }

    @objc private func didTapImageItem(_ gesture: UITapGestureRecognizer) {
        guard let tappedView = gesture.view else { return }
        for item in imageItems {
            if item.imageView === tappedView {
                if item.failed {
                    if let name = item.localFile, let image = BearyDraftImageStore.image(for: name) {
                        startUpload(for: item, image: image)
                    } else if item.localFile == nil {
                        // 无本地文件又无 key：无物可传，移除该项。
                        removeImageItem(item)
                    }
                    // 本地文件读不出：保持失败态，下次点图再试。
                }
                return
            }
        }
    }

    private func insertImageItem(_ item: ComposerImageItem) {
        imageItems.append(item)
        if let addIndex = imageStackView.arrangedSubviews.firstIndex(of: addImageContainer) {
            imageStackView.insertArrangedSubview(item.container, at: addIndex)
        } else {
            imageStackView.addArrangedSubview(item.container)
        }
        refreshAddButtonVisibility()
        updatePublishState()
    }

    private func refreshAddButtonVisibility() {
        addImageContainer.isHidden = imageItems.count >= BearyComposerViewController.maxImages
    }

    private func removeImageItem(_ item: ComposerImageItem) {
        var kept: [ComposerImageItem] = []
        for existing in imageItems {
            if existing !== item {
                kept.append(existing)
            }
        }
        imageItems = kept
        if let name = item.localFile {
            BearyDraftImageStore.deletePair(fullName: name)
        }
        imageStackView.removeArrangedSubview(item.container)
        item.container.removeFromSuperview()
        refreshAddButtonVisibility()
        updatePublishState()
        scheduleDraftSave()
    }

    @objc private func didTapRemoveImage(_ sender: UIButton) {
        for item in imageItems {
            if item.removeButton == sender {
                // 只去本地与 key 列表，不调服务端；未发布的孤 key 残留是已知可接受项。
                removeImageItem(item)
                return
            }
        }
    }

    @objc private func didTapAddImage() {
        if imageItems.count >= BearyComposerViewController.maxImages {
            return
        }
        var config = PHPickerConfiguration()
        config.selectionLimit = BearyComposerViewController.maxImages - imageItems.count
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            if imageItems.count >= BearyComposerViewController.maxImages {
                break
            }
            let provider = result.itemProvider
            if !provider.canLoadObject(ofClass: UIImage.self) {
                continue
            }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let image = object as? UIImage else { return }
                    if self.imageItems.count >= BearyComposerViewController.maxImages {
                        return
                    }
                    // 先落盘再建项：选完图立刻有本地文件，杀 App 也不丢图。
                    // 落盘失败则按无本地文件降级（与旧行为一致，草稿里只有 key）。
                    var localFile: String?
                    if let full = BearyImagePrep.jpegData(image, maxSide: 1600, quality: 0.85),
                       let thumb = BearyImagePrep.thumbData(image, maxSide: 480),
                       let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb) {
                        localFile = saved
                    }
                    let item = self.createImageItem(localImage: image, key: nil, uploading: true, localFile: localFile, failed: false)
                    self.insertImageItem(item)
                    self.saveDraftNow()
                    self.startUpload(for: item, image: image)
                }
            }
        }
    }

    private func startUpload(for item: ComposerImageItem, image: UIImage) {
        markUploading(item)
        guard let full = BearyImagePrep.jpegData(image, maxSide: 1600, quality: 0.85) else {
            markFailed(item)
            saveDraftNow()
            updatePublishState()
            return
        }
        guard let thumb = BearyImagePrep.thumbData(image, maxSide: 480) else {
            markFailed(item)
            saveDraftNow()
            updatePublishState()
            return
        }
        BearyAPI.shared.uploadImage(dataUrl: BearyImagePrep.dataURL(full.data), width: full.w, height: full.h, thumbDataUrl: BearyImagePrep.dataURL(thumb)) { [weak self, weak item] result in
            DispatchQueue.main.async {
                guard let self = self, let item = item else { return }
                var stillThere = false
                for existing in self.imageItems {
                    if existing === item {
                        stillThere = true
                    }
                }
                if !stillThere {
                    return
                }
                switch result {
                case .success(let resp):
                    if let key = resp.key {
                        self.markUploaded(item, key: key)
                        item.imageView.image = image
                        self.scheduleDraftSave()
                        self.updatePublishState()
                    } else {
                        self.markFailed(item)
                        self.saveDraftNow()
                        self.updatePublishState()
                    }
                case .failure:
                    // 失败只亮重试态：图留在条里，点图重试；不弹全局框、不删项。
                    self.markFailed(item)
                    self.saveDraftNow()
                    self.updatePublishState()
                }
            }
        }
    }

    /// 重开编辑器时续传：有本地文件、无 key、非失败态的项自动重新上传。
    /// 失败态的项不自动续传，等用户点图重试；本地文件读不出的项置失败态。
    private func resumePendingUploads() {
        for item in imageItems {
            if item.key != nil || item.uploading || item.failed {
                continue
            }
            if let name = item.localFile, let image = BearyDraftImageStore.image(for: name) {
                startUpload(for: item, image: image)
            } else if item.localFile != nil {
                markFailed(item)
            }
        }
    }

    private func uploadedImageKeys() -> [String] {
        var keys: [String] = []
        for item in imageItems {
            if let key = item.key {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: - 草稿

    private func scheduleDraftSave() {
        draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.saveDraftNow()
        }
    }

    private func saveDraftNow() {
        // clientReq 本篇草稿创建时生成一次，之后全程复用（含发布重试），
        // 成功拿到 entry id 前绝不换——服务端靠它做发布幂等。
        if draftClientReq == nil {
            draftClientReq = BearyDraftStore.newClientReq()
        }
        guard let req = draftClientReq else { return }
        var images: [BearyDraftImageItem] = []
        for item in imageItems {
            let state: BearyDraftImageState
            if item.key != nil {
                state = .uploaded
            } else if item.failed {
                state = .failed
            } else {
                state = .pending
            }
            images.append(BearyDraftImageItem(localFile: item.localFile, serverKey: item.key, state: state))
        }
        let draft = BearyDraft(content: textView.text, mood: selectedMood, images: images, clientReq: req, updatedAt: Date().timeIntervalSince1970)
        BearyDraftStore.save(draft)
    }

    private func restoreDraft() {
        guard let draft = BearyDraftStore.load() else { return }
        draftClientReq = draft.clientReq
        textView.text = draft.content
        selectedMood = draft.mood
        refreshMoodButtons()
        var referenced = Set<String>()
        for img in draft.images {
            var localImage: UIImage?
            if let name = img.localFile {
                localImage = BearyDraftImageStore.image(for: name)
                referenced.insert(name)
            }
            let failed = (img.state == .failed)
            let item = createImageItem(localImage: localImage, key: img.serverKey, uploading: false, localFile: img.localFile, failed: failed)
            insertImageItem(item)
            // 有本地图优先显示本地图；只有 key 的老项（v1 迁移而来）走远程缩略图。
            if localImage == nil, let key = img.serverKey,
               let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                item.imageView.bearySetImage(url: url, placeholder: nil)
            }
        }
        // 回收无主文件（杀 App 后、首存前产生的孤文件），只保留本篇引用的。
        BearyDraftImageStore.sweep(keeping: referenced)
        resumePendingUploads()
    }

    /// 发布成功 / 丢弃草稿时：清草稿文件 + 本篇全部本地图片文件 + 换掉 clientReq。
    /// 服务端孤 key 无删除接口，残留是已知可接受项（见文末注）。
    private func clearDraftAndFiles() {
        for item in imageItems {
            if let name = item.localFile {
                BearyDraftImageStore.deletePair(fullName: name)
            }
        }
        BearyDraftStore.clear()
        draftClientReq = nil
    }

    // MARK: - 取消与发布

    @objc private func didTapCancel() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "继续写", style: .cancel, handler: nil))
        sheet.addAction(UIAlertAction(title: "保留并关闭", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.saveDraftNow()
            self.onCancelled?()
        })
        sheet.addAction(UIAlertAction(title: "丢弃并关闭", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.clearDraftAndFiles()
            self.onCancelled?()
        })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = cancelButton
            pop.sourceRect = cancelButton.bounds
        }
        present(sheet, animated: true)
    }

    @objc private func didTapPublish() {
        if isPublishing {
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        let trimmed = trimmedContent()
        if trimmed.isEmpty || trimmed.count > BearyComposerViewController.maxLength {
            updatePublishState()
            return
        }
        // 有上传失败的图片：先确认，避免用户在不知情下丢图发布。
        var hasFailed = false
        for item in imageItems {
            if item.failed {
                hasFailed = true
            }
        }
        if hasFailed {
            let alert = UIAlertController(title: nil, message: "有图片上传失败，发布时不会包含这些图片，仍要发布吗？", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "仍要发布", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.performPublish(trimmed: trimmed)
            })
            present(alert, animated: true)
            return
        }
        performPublish(trimmed: trimmed)
    }

    private func performPublish(trimmed: String) {
        if draftClientReq == nil {
            draftClientReq = BearyDraftStore.newClientReq()
        }
        guard let req = draftClientReq else { return }
        // 先把本次 clientReq 落盘：服务端已落库但回包丢了，重试用同一 clientReq，
        // 服务端直接返回已落库的那篇，不重复发。
        saveDraftNow()
        isPublishing = true
        updatePublishState()
        BearyAPI.shared.publishEntry(content: trimmed, images: uploadedImageKeys(), mood: selectedMood, clientReq: req) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success(let resp):
                    if let entryId = resp.id {
                        // 只有拿到 entry id 才清草稿与本地图片。
                        self.clearDraftAndFiles()
                        self.onPublished?(entryId)
                    } else {
                        self.saveDraftNow()
                        self.showAlert(message: "发布失败，请重试")
                    }
                case .failure(let error):
                    // 失败一律保留草稿；离线/网络错误给明确文案。
                    self.saveDraftNow()
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .network = error {
                        self.showAlert(message: "网络不可用，已保存为草稿，联网后可重试")
                    } else {
                        self.showAlert(message: self.message(forPublishError: error))
                    }
                }
            }
        }
    }

    private func message(forPublishError error: APIError) -> String {
        if case .server(let code) = error {
            switch code {
            case "create_gap":
                return "发得有点快，歇一下再写"
            case "create_day_limit":
                return "今天写够了，明天再继续吧"
            case "create_dup":
                return "这篇和你写过的一篇一模一样"
            case "content too long":
                return "正文最多 2000 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
            default:
                return "发布失败，请重试"
            }
        }
        return "发布失败，请重试"
    }

    // MARK: - 键盘

    @objc private func keyboardWillShow(_ notification: Notification) {
        applyKeyboard(notification, showing: true)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        applyKeyboard(notification, showing: false)
    }

    private func applyKeyboard(_ notification: Notification, showing: Bool) {
        var height: CGFloat = 0
        if showing {
            if let userInfo = notification.userInfo {
                if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                    let frame = view.convert(frameValue.cgRectValue, from: nil)
                    height = max(0, view.bounds.maxY - frame.minY)
                }
            }
        }
        var duration: TimeInterval = 0.25
        var curveRaw: UInt = 0
        if let userInfo = notification.userInfo {
            if let d = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
                duration = d
            }
            if let c = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
                curveRaw = c.uintValue
            }
        }
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: { [weak self] in
            guard let self = self else { return }
            self.scrollView.contentInset.bottom = height
            self.scrollView.scrollIndicatorInsets.bottom = height
            self.textView.contentInset.bottom = height
        }, completion: nil)
    }

    // MARK: - 通用

    private func showAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: true)
    }
}

// MARK: - 图片条单项（class，便于上传回调按身份认领，不受数组顺序变化影响）

private final class ComposerImageItem {
    var key: String?
    var uploading: Bool
    var localFile: String?
    var failed: Bool
    let container: UIView
    let imageView: UIImageView
    let spinner: UIActivityIndicatorView
    let retryLabel: UILabel
    let removeButton: UIButton

    init(key: String?, uploading: Bool, localFile: String?, failed: Bool, container: UIView, imageView: UIImageView, spinner: UIActivityIndicatorView, retryLabel: UILabel, removeButton: UIButton) {
        self.key = key
        self.uploading = uploading
        self.localFile = localFile
        self.failed = failed
        self.container = container
        self.imageView = imageView
        self.spinner = spinner
        self.retryLabel = retryLabel
        self.removeButton = removeButton
    }
}

// 注：
// 1. 天气（weather）本片不做：publishEntry 签名本身不接受 weather，服务端置 null，属缺口。
// 2. 超 2000 字红字提示用了 UIColor.systemRed——BearyColors 里没有红色，主题色之外仅此一处语义红。
// 3. 图片 × 只移除本地与 key 列表，不调服务端；未发布的孤 key 残留是已知可接受项。
// 4. 草稿 v2（BearyDraftFiles.swift）：正文 + 心情 + 图片项（本地文件名 / 服务端 key / 上传状态）
//    + clientReq（创建时生成一次，发布重试全程复用）+ updatedAt；JSON 文件原子写；
//    v1 草稿首次读取迁移为无本地文件的 key 项，走远程图显示。
// 5. 丢弃草稿 / 发布成功会删本地图片文件；服务端孤 key 无删除接口，残留是已知可接受项。
// 6. 发布时有上传失败的图片会先弹确认（防静默丢图）；离线/网络错误文案为“网络不可用，
//    已保存为草稿，联网后可重试”，失败一律保留草稿。
