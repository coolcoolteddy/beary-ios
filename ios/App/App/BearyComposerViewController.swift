import UIKit
import PhotosUI

// ===== beary 原生编辑器（第二阶段 + 主线闭环第一块）=====
// 只负责写日记：正文 + 心情 + 天气 + 写给 + 引用 + 图片（上限 9 张）。
// 编辑模式复用同一界面：正文/心情/天气/图片可改，写给与引用锁定不可改，
// 不走新日记草稿流（不读不写 beary_draft_v2、不复用新篇 client_req）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。
// 文案一律中文；深浅色一律用 BearyColors 的动态色（含语义红 red 与图片上深色衬底 scrim）。
// 网络数据一律不用 force unwrap；图片移除只动本地与 key 列表，不调服务端。

final class BearyComposerViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate {

    // MARK: - 公开接口

    /// 发布成功，传新日记 id。
    var onPublished: ((String) -> Void)?
    /// 编辑保存成功：传（日记 id、新正文、新图片 key 列表、新心情 key）。
    /// 调用方据此定向刷新列表该行（不整表刷新），详情自行重拉单篇。
    var onUpdated: ((String, String, [String], String?) -> Void)?
    /// 关闭编辑器（保留草稿或丢弃后均走这里；编辑模式取消也走这里，不删原日记）。
    var onCancelled: (() -> Void)?
    /// 发布时未登录走这里，不发请求。
    var onRequireLogin: (() -> Void)?

    // MARK: - 编辑模式

    /// 非 nil 即编辑模式：回填正文/心情/天气/图片；写给与引用只展示不改。
    private var editingEntry: Entry?
    private var isEditMode: Bool { editingEntry != nil }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    init(entry: Entry) {
        self.editingEntry = entry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 心情顺序（硬编码，勿用 moodNames.keys.sorted()，会打乱原顺序）

    private let moodOrder: [String] = [
        "agree", "happy", "applause", "cheer", "comfort", "confused", "love", "determined",
        "facepalm", "shy", "goodnight", "hug", "wink", "idea", "kiss", "thinking",
        "listening", "lonely", "speechless", "nope", "surprised", "pat", "peek", "sleepy",
        "proud", "shrug", "sorry", "cry", "angry", "thanks", "zap", "wave",
        "candle", "flower", "letter", "paperplane", "sprout", "tea", "umbrella", "wish",
    ]

    /// 天气顺序：与 BearyText.weatherNames 字面顺序一致（勿用字典 keys 排序，会打乱顺序）。
    private let weatherOrder: [String] = [
        "sun", "cloud", "cloudy", "rain", "snow", "fog", "thunder", "wind", "night",
    ]

    /// 引用纸片状态：只存展示用的三字段（id/content/createdAt），不存整条 Entry。
    private struct SelectedQuote {
        let entryId: String
        let content: String
        let createdAt: Int?
    }

    private static let maxLength = 2000
    private static let maxImages = 9

    // MARK: - 状态

    private var selectedMood: String?
    private var selectedWeather: String?
    /// 新建模式的收信人（编辑模式不用它，写给锁定，见 lockedRecipientName）。
    private var selectedRecipient: SearchUser?
    /// 通知对方：默认开；只在新建且已选收信人时有意义，复选框只改它，不触发重渲染。
    private var notifyRecipient = true
    /// 新建模式的引用（编辑模式不用它，引用锁定，见 lockedQuote）。
    private var selectedQuote: SelectedQuote?
    /// 编辑模式锁定的写给展示名（服务端 PUT 不接受 recipient，改不了，只展示）。
    private var lockedRecipientName: String?
    /// 编辑模式锁定的引用（服务端 PUT 接受 quote_id，但本片按 brief 锁定原值，不改）。
    private var lockedQuote: SelectedQuote?
    private var draftClientReq: String?
    private var isPublishing = false
    private var didAutoFocus = false
    private var draftTimer: Timer?
    private var imageItems: [ComposerImageItem] = []
    private var moodButtons: [(key: String, button: UIButton)] = []
    private var weatherButtons: [(key: String, button: UIButton)] = []

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
    private let weatherTitleLabel = UILabel()
    private let weatherScrollView = UIScrollView()
    private let weatherStackView = UIStackView()
    private let recipientRow = UIView()
    private let recipientLabel = UILabel()
    private let recipientPickButton = UIButton(type: .system)
    private let recipientClearButton = UIButton(type: .system)
    private let notifyGroup = UIStackView()
    private let notifyCheckButton = UIButton(type: .system)
    private let notifyLabel = UILabel()
    private let quoteSection = UIStackView()
    private let pickQuoteButton = UIButton(type: .system)
    private let quoteCard = UIView()
    private let quoteContentLabel = UILabel()
    private let quoteDateLabel = UILabel()
    private let quoteRemoveButton = UIButton(type: .system)
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
        buildWeatherRow()
        buildRecipientRow()
        buildQuoteSection()
        buildImageRow()
        if isEditMode {
            setupEditContent()
        } else {
            restoreDraft()
        }
        updateCountLabel()
        updatePublishState()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 打开即聚焦正文：编辑器唯一目的就是写，首屏就绪后直接可打字；只做一次，
        // 从选图/弹窗回来不抢焦点；有草稿时光标置末尾，接着写。
        // 与草稿恢复/图片续传无冲突：恢复在 viewDidLoad 已完成，续传是后台任务。
        if !didAutoFocus {
            didAutoFocus = true
            if !textView.text.isEmpty {
                textView.selectedRange = NSRange(location: textView.text.count, length: 0)
            }
            textView.becomeFirstResponder()
        }
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
        titleLabel.text = isEditMode ? "编辑日记" : "写日记"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        publishButton.setTitle(isEditMode ? "保存" : "发布", for: .normal)
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

    // MARK: - 天气（与心情行同款横向 chip；选中态是墨色，与网页天气已选态一致）

    private func buildWeatherRow() {
        weatherTitleLabel.text = "天气"
        weatherTitleLabel.font = UIFont.systemFont(ofSize: 14)
        weatherTitleLabel.textColor = BearyColors.gray
        weatherScrollView.showsHorizontalScrollIndicator = false
        weatherStackView.axis = .horizontal
        weatherStackView.spacing = 8
        weatherStackView.alignment = .center
        for v in [weatherTitleLabel, weatherScrollView, weatherStackView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(weatherTitleLabel)
        contentView.addSubview(weatherScrollView)
        weatherScrollView.addSubview(weatherStackView)
        NSLayoutConstraint.activate([
            weatherTitleLabel.topAnchor.constraint(equalTo: moodScrollView.bottomAnchor, constant: 20),
            weatherTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            weatherScrollView.topAnchor.constraint(equalTo: weatherTitleLabel.bottomAnchor, constant: 8),
            weatherScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            weatherScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            weatherScrollView.heightAnchor.constraint(equalToConstant: 36),
            weatherStackView.topAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.topAnchor),
            weatherStackView.bottomAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.bottomAnchor),
            weatherStackView.leadingAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            weatherStackView.trailingAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            weatherStackView.heightAnchor.constraint(equalTo: weatherScrollView.frameLayoutGuide.heightAnchor),
        ])
        for key in weatherOrder {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            let name = BearyText.weatherNames[key] ?? key
            button.setTitle(name, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            button.layer.cornerRadius = 16
            button.layer.masksToBounds = true
            button.layer.borderWidth = 1
            button.addTarget(self, action: #selector(didTapWeather(_:)), for: .touchUpInside)
            weatherButtons.append((key: key, button: button))
            weatherStackView.addArrangedSubview(button)
        }
        refreshWeatherButtons()
    }

    private func refreshWeatherButtons() {
        for pair in weatherButtons {
            let button = pair.button
            if pair.key == selectedWeather {
                button.backgroundColor = BearyColors.ink
                button.setTitleColor(UIColor.white, for: .normal)
                button.layer.borderColor = BearyColors.ink.cgColor
            } else {
                button.backgroundColor = BearyColors.faint
                button.setTitleColor(BearyColors.ink, for: .normal)
                button.layer.borderColor = BearyColors.line.cgColor
            }
        }
    }

    @objc private func didTapWeather(_ sender: UIButton) {
        var tappedKey: String?
        for pair in weatherButtons {
            if pair.button == sender {
                tappedKey = pair.key
            }
        }
        guard let key = tappedKey else { return }
        if selectedWeather == key {
            selectedWeather = nil
        } else {
            selectedWeather = key
        }
        refreshWeatherButtons()
        // 天气不在草稿 v2 字段里（草稿格式冻结），只留本会话，不触发草稿保存。
    }

    // MARK: - 写给（只选一人；发布后锁定，编辑模式只展示）

    private func buildRecipientRow() {
        recipientLabel.text = "写给"
        recipientLabel.font = UIFont.systemFont(ofSize: 14)
        recipientLabel.textColor = BearyColors.gray
        recipientPickButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        recipientPickButton.contentHorizontalAlignment = .left
        recipientPickButton.addTarget(self, action: #selector(didTapPickRecipient), for: .touchUpInside)
        recipientClearButton.setTitle("×", for: .normal)
        recipientClearButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        recipientClearButton.setTitleColor(BearyColors.gray, for: .normal)
        recipientClearButton.addTarget(self, action: #selector(didTapClearRecipient), for: .touchUpInside)
        notifyCheckButton.layer.cornerRadius = 6
        notifyCheckButton.layer.masksToBounds = true
        notifyCheckButton.layer.borderWidth = 1.5
        notifyCheckButton.layer.borderColor = BearyColors.line.cgColor
        notifyCheckButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        notifyCheckButton.addTarget(self, action: #selector(didTapNotifyCheck), for: .touchUpInside)
        notifyLabel.text = "通知对方"
        notifyLabel.font = UIFont.systemFont(ofSize: 14)
        notifyLabel.textColor = BearyColors.ink
        notifyGroup.axis = .horizontal
        notifyGroup.spacing = 6
        notifyGroup.alignment = .center
        notifyGroup.addArrangedSubview(notifyCheckButton)
        notifyGroup.addArrangedSubview(notifyLabel)
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 8
        rowStack.alignment = .center
        rowStack.addArrangedSubview(recipientLabel)
        rowStack.addArrangedSubview(recipientPickButton)
        rowStack.addArrangedSubview(recipientClearButton)
        rowStack.addArrangedSubview(notifyGroup)
        recipientPickButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [recipientRow, rowStack, notifyCheckButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(recipientRow)
        recipientRow.addSubview(rowStack)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recipientRow.topAnchor.constraint(equalTo: weatherScrollView.bottomAnchor, constant: 20),
            recipientRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            recipientRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            recipientRow.heightAnchor.constraint(equalToConstant: 44),
            rowStack.topAnchor.constraint(equalTo: recipientRow.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: recipientRow.bottomAnchor),
            rowStack.leadingAnchor.constraint(equalTo: recipientRow.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: recipientRow.trailingAnchor),
            notifyCheckButton.widthAnchor.constraint(equalToConstant: 22),
            notifyCheckButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        refreshRecipientRow()
    }

    /// 写给行状态：新建未选 → “选择收信人”；新建已选 → 名 + × + 通知复选框；
    /// 编辑模式 → 锁定的名（或“未写给任何人”），不可点、无 ×、无通知复选框。
    private func refreshRecipientRow() {
        if isEditMode {
            recipientPickButton.isEnabled = false
            recipientPickButton.setTitleColor(BearyColors.gray, for: .normal)
            if let name = lockedRecipientName {
                recipientPickButton.setTitle("写给 " + name, for: .normal)
            } else {
                recipientPickButton.setTitle("未写给任何人", for: .normal)
            }
            recipientClearButton.isHidden = true
            notifyGroup.isHidden = true
            return
        }
        recipientPickButton.isEnabled = true
        recipientPickButton.setTitleColor(BearyColors.blue, for: .normal)
        if let user = selectedRecipient {
            let name: String
            if let display = user.displayName {
                name = display
            } else if let handle = user.handle {
                name = "@" + handle
            } else {
                name = "用户"
            }
            recipientPickButton.setTitle("写给 " + name, for: .normal)
            recipientClearButton.isHidden = false
            notifyGroup.isHidden = false
        } else {
            recipientPickButton.setTitle("选择收信人", for: .normal)
            recipientClearButton.isHidden = true
            notifyGroup.isHidden = true
        }
        refreshNotifyCheck()
    }

    /// 通知复选框只改本地状态与自身外观，不重建行（网页版同款规矩）。
    private func refreshNotifyCheck() {
        if notifyRecipient {
            notifyCheckButton.backgroundColor = BearyColors.ink
            notifyCheckButton.setTitle("✓", for: .normal)
            notifyCheckButton.setTitleColor(UIColor.white, for: .normal)
        } else {
            notifyCheckButton.backgroundColor = UIColor.clear
            notifyCheckButton.setTitle("", for: .normal)
        }
    }

    @objc private func didTapPickRecipient() {
        if isEditMode { return }
        let picker = BearyRecipientPickerViewController()
        picker.onPick = { [weak self] user in
            guard let self = self else { return }
            self.selectedRecipient = user
            self.notifyRecipient = true
            self.refreshRecipientRow()
        }
        let nav = UINavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    @objc private func didTapClearRecipient() {
        if isEditMode { return }
        selectedRecipient = nil
        refreshRecipientRow()
    }

    @objc private func didTapNotifyCheck() {
        if isEditMode { return }
        notifyRecipient.toggle()
        refreshNotifyCheck()
    }

    // MARK: - 引用（新建可挑自己的时间线；编辑模式锁定原值）

    private func buildQuoteSection() {
        quoteSection.axis = .vertical
        quoteSection.spacing = 0
        pickQuoteButton.setTitle("引用一篇日记", for: .normal)
        pickQuoteButton.setTitleColor(BearyColors.blue, for: .normal)
        pickQuoteButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        pickQuoteButton.backgroundColor = BearyColors.faint
        pickQuoteButton.layer.cornerRadius = 12
        pickQuoteButton.layer.masksToBounds = true
        pickQuoteButton.addTarget(self, action: #selector(didTapPickQuote), for: .touchUpInside)
        quoteCard.backgroundColor = BearyColors.faint
        quoteCard.layer.cornerRadius = 12
        quoteCard.layer.masksToBounds = true
        quoteContentLabel.numberOfLines = 2
        quoteContentLabel.font = UIFont.systemFont(ofSize: 15)
        quoteContentLabel.textColor = BearyColors.ink
        quoteDateLabel.font = UIFont.systemFont(ofSize: 13)
        quoteDateLabel.textColor = BearyColors.gray
        quoteRemoveButton.setTitle("×", for: .normal)
        quoteRemoveButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        quoteRemoveButton.setTitleColor(BearyColors.gray, for: .normal)
        quoteRemoveButton.addTarget(self, action: #selector(didTapRemoveQuote), for: .touchUpInside)
        for v in [quoteSection, pickQuoteButton, quoteCard, quoteContentLabel, quoteDateLabel, quoteRemoveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(quoteSection)
        quoteSection.addArrangedSubview(pickQuoteButton)
        quoteSection.addArrangedSubview(quoteCard)
        quoteCard.addSubview(quoteContentLabel)
        quoteCard.addSubview(quoteDateLabel)
        quoteCard.addSubview(quoteRemoveButton)
        NSLayoutConstraint.activate([
            quoteSection.topAnchor.constraint(equalTo: recipientRow.bottomAnchor, constant: 16),
            quoteSection.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            quoteSection.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            pickQuoteButton.heightAnchor.constraint(equalToConstant: 44),
            quoteContentLabel.topAnchor.constraint(equalTo: quoteCard.topAnchor, constant: 12),
            quoteContentLabel.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 12),
            quoteContentLabel.trailingAnchor.constraint(equalTo: quoteCard.trailingAnchor, constant: -40),
            quoteDateLabel.topAnchor.constraint(equalTo: quoteContentLabel.bottomAnchor, constant: 4),
            quoteDateLabel.leadingAnchor.constraint(equalTo: quoteCard.leadingAnchor, constant: 12),
            quoteDateLabel.trailingAnchor.constraint(equalTo: quoteCard.trailingAnchor, constant: -12),
            quoteDateLabel.bottomAnchor.constraint(equalTo: quoteCard.bottomAnchor, constant: -12),
            quoteRemoveButton.topAnchor.constraint(equalTo: quoteCard.topAnchor, constant: 8),
            quoteRemoveButton.trailingAnchor.constraint(equalTo: quoteCard.trailingAnchor, constant: -8),
            quoteRemoveButton.widthAnchor.constraint(equalToConstant: 28),
            quoteRemoveButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        refreshQuoteSection()
    }

    /// 引用区状态：stack 内的隐藏项自动塌掉（UIStackView 口径），无需改约束。
    /// 新建未选 → 挑按钮；新建已选 → 纸片 + ×；编辑 → 锁定的纸片（无 ×）或都不显示。
    private func refreshQuoteSection() {
        if isEditMode {
            pickQuoteButton.isHidden = true
            quoteRemoveButton.isHidden = true
            if let quote = lockedQuote {
                quoteContentLabel.text = quote.content
                quoteDateLabel.text = quote.createdAt.map { BearyText.timeString(ms: $0) }
                quoteCard.isHidden = false
            } else {
                quoteCard.isHidden = true
            }
            return
        }
        if let quote = selectedQuote {
            pickQuoteButton.isHidden = true
            quoteRemoveButton.isHidden = false
            quoteContentLabel.text = quote.content
            quoteDateLabel.text = quote.createdAt.map { BearyText.timeString(ms: $0) }
            quoteCard.isHidden = false
        } else {
            pickQuoteButton.isHidden = false
            quoteCard.isHidden = true
        }
    }

    @objc private func didTapPickQuote() {
        if isEditMode { return }
        let picker = BearyQuotePickerViewController()
        picker.onPick = { [weak self] entry in
            guard let self = self, let entryId = entry.id, let content = entry.content else { return }
            self.selectedQuote = SelectedQuote(entryId: entryId, content: content, createdAt: entry.createdAt)
            self.refreshQuoteSection()
        }
        let nav = UINavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    @objc private func didTapRemoveQuote() {
        if isEditMode { return }
        selectedQuote = nil
        refreshQuoteSection()
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
            imageTitleLabel.topAnchor.constraint(equalTo: quoteSection.bottomAnchor, constant: 20),
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
            countLabel.textColor = BearyColors.red
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
        retryLabel.backgroundColor = BearyColors.scrim
        retryLabel.textAlignment = .center
        retryLabel.layer.cornerRadius = 8
        retryLabel.layer.masksToBounds = true
        retryLabel.isHidden = !failed
        let removeButton = UIButton(type: .system)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setTitle("×", for: .normal)
        removeButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        removeButton.setTitleColor(UIColor.white, for: .normal)
        removeButton.backgroundColor = BearyColors.scrim
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
        config.selection = .ordered
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
            // 先按选择顺序占位建项（转圈态），加载完成后再填图上传：
            // 异步加载各图快慢不一，旧写法按完成顺序建项会打乱用户选图顺序。
            // 占位项计入 9 张上限，发布在上传完成前保持禁用，与原有联动一致。
            let item = createImageItem(localImage: nil, key: nil, uploading: true, localFile: nil, failed: false)
            insertImageItem(item)
            provider.loadObject(ofClass: UIImage.self) { [weak self, weak item] object, _ in
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
                    guard let image = object as? UIImage else {
                        // 读不出图：占位项直接移除，不留转圈、不留误导的重试态。
                        self.removeImageItem(item)
                        return
                    }
                    item.imageView.image = image
                    // 先落盘再上传：选完图立刻有本地文件，杀 App 也不丢图。
                    // 落盘失败则按无本地文件降级（与旧行为一致，草稿里只有 key）。
                    if let full = BearyImagePrep.jpegData(image, maxSide: 1600, quality: 0.85),
                       let thumb = BearyImagePrep.thumbData(image, maxSide: 480),
                       let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb) {
                        item.localFile = saved
                    }
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

    // MARK: - 编辑模式回填（只读原值，不碰草稿）

    private func setupEditContent() {
        guard let entry = editingEntry else { return }
        textView.text = entry.content ?? ""
        selectedMood = entry.mood
        refreshMoodButtons()
        selectedWeather = entry.weather
        refreshWeatherButtons()
        lockedRecipientName = entry.recipientName
        if let quote = entry.quote, let quoteId = quote.id, let content = quote.content {
            // 内容为空的引用 = 已删（服务端 gone 只剩 id，网页版同款：已删引用不回填，保存时即丢弃）。
            lockedQuote = SelectedQuote(entryId: quoteId, content: content, createdAt: quote.createdAt)
        }
        refreshRecipientRow()
        refreshQuoteSection()
        for key in entry.images ?? [] {
            let item = createImageItem(localImage: nil, key: key, uploading: false, localFile: nil, failed: false)
            insertImageItem(item)
            if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                item.imageView.bearySetImage(url: url, placeholder: nil)
            }
        }
        refreshAddButtonVisibility()
    }

    /// 编辑期内的本地文件（本轮新选的图）：取消/保存成功后删本地文件，不留孤文件；
    /// 原日记的图 localFile 为 nil，不受影响。失败时不删，留着给重试用。
    private func deleteEditLocalFiles() {
        for item in imageItems {
            if let name = item.localFile {
                BearyDraftImageStore.deletePair(fullName: name)
            }
        }
    }

    /// 编辑是否改过东西（正文按 trim 后比，服务端落库时同样 trim）。
    private func isEditDirty() -> Bool {
        guard let entry = editingEntry else { return false }
        if trimmedContent() != (entry.content ?? "") { return true }
        if selectedMood != entry.mood { return true }
        if selectedWeather != entry.weather { return true }
        if uploadedImageKeys() != (entry.images ?? []) { return true }
        return false
    }

    // MARK: - 草稿

    private func scheduleDraftSave() {
        // 编辑模式不走草稿流：任何编辑中的改动都不写 beary_draft_v2。
        if isEditMode { return }
        draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.saveDraftNow()
        }
    }

    private func saveDraftNow() {
        // 编辑模式不写草稿（scheduleDraftSave 已拦，这里再拦一道，防以后新增调用点漏拦）。
        if isEditMode { return }
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
        if isEditMode {
            // 编辑模式不走草稿三选：没改过直接关，改过先确认，两种情况都不删原日记、不碰草稿。
            if isEditDirty() {
                let alert = UIAlertController(title: nil, message: "放弃对这篇日记的修改吗？", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel, handler: nil))
                alert.addAction(UIAlertAction(title: "放弃修改", style: .destructive) { [weak self] _ in
                    guard let self = self else { return }
                    self.deleteEditLocalFiles()
                    self.onCancelled?()
                })
                present(alert, animated: true)
            } else {
                deleteEditLocalFiles()
                onCancelled?()
            }
            return
        }
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
        // 有上传失败的图片：只弹失败图确认，不再叠加发布/保存确认。
        if hasFailedImage() {
            let alert = UIAlertController(title: nil, message: "有图片上传失败，发布时不会包含这些图片，仍要发布吗？", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: isEditMode ? "仍要保存" : "仍要发布", style: .default) { [weak self] _ in
                guard let self = self else { return }
                if self.isEditMode {
                    self.performUpdate(trimmed: trimmed)
                } else {
                    self.performPublish(trimmed: trimmed)
                }
            })
            present(alert, animated: true)
            return
        }
        if isEditMode {
            let alert = UIAlertController(title: "保存修改", message: "保存后仍可在编辑期内继续修改，公开后不能再改。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.performUpdate(trimmed: trimmed)
            })
            present(alert, animated: true)
            return
        }
        let alert = UIAlertController(title: "发布", message: "发布后 7 天自动公开，15 分钟内可修改。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "发布", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.performPublish(trimmed: trimmed)
        })
        present(alert, animated: true)
    }

    private func hasFailedImage() -> Bool {
        for item in imageItems {
            if item.failed {
                return true
            }
        }
        return false
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
        BearyAPI.shared.publishEntry(content: trimmed, images: uploadedImageKeys(), mood: selectedMood, weather: selectedWeather, quoteId: selectedQuote?.entryId, recipientId: selectedRecipient?.id, notifyRecipient: selectedRecipient != nil ? (notifyRecipient ? 1 : 0) : nil, clientReq: req) { [weak self] result in
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
            case "recipient_invalid":
                return "收信人无效，请重新选择"
            default:
                return "发布失败，请重试"
            }
        }
        return "发布失败，请重试"
    }

    // MARK: - 编辑保存（PUT；15 分钟规则只由服务端判定，App 只展示与转文案）

    private func performUpdate(trimmed: String) {
        guard let entryId = editingEntry?.id, !entryId.isEmpty else {
            showAlert(message: "找不到要编辑的日记")
            return
        }
        isPublishing = true
        updatePublishState()
        BearyAPI.shared.updateEntry(id: entryId, content: trimmed, images: uploadedImageKeys(), mood: selectedMood, weather: selectedWeather, quoteId: lockedQuote?.entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success:
                    self.deleteEditLocalFiles()
                    self.onUpdated?(entryId, trimmed, self.uploadedImageKeys(), self.selectedMood)
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .server(let code) = error, ["edit window expired", "already public", "already public or expired"].contains(code) {
                        // 编辑期已过：再存也一定失败，告知后直接关编辑器（详情重拉后显示最新态）。
                        let alert = UIAlertController(title: nil, message: "已超过 15 分钟编辑期或日记已公开，无法再修改", preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
                            guard let self = self else { return }
                            self.deleteEditLocalFiles()
                            self.onCancelled?()
                        })
                        self.present(alert, animated: true)
                    } else if case .network = error {
                        self.showAlert(message: "网络不可用，修改未保存，请联网后重试")
                    } else {
                        self.showAlert(message: self.message(forUpdateError: error))
                    }
                }
            }
        }
    }

    private func message(forUpdateError error: APIError) -> String {
        if case .server(let code) = error {
            switch code {
            case "content too long":
                return "正文最多 2000 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
            case "invalid image ownership":
                return "图片归属异常，请重新添加"
            default:
                return "保存失败，请重试"
            }
        }
        return "保存失败，请重试"
    }

    // MARK: - 键盘

    @objc private func keyboardWillShow(_ notification: Notification) {
        applyKeyboard(notification, showing: true)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        applyKeyboard(notification, showing: false)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        // 旋转、表情/听写键盘高度变化、悬浮键盘拖动只发 WillChangeFrame，不发 WillShow：
        // 同一套 inset 计算跟随最终帧；出现时与 WillShow 同值、beginFromCurrentState 保证幂等，不叠加；
        // 键盘收起时最终帧在屏外，算出的高度为 0，与 WillHide 一致。
        applyKeyboard(notification, showing: true)
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
// 1. 天气（weather）主线闭环第一块已补：9 天气单选 chip（选中态墨色，与网页天气已选态一致），
//    publish 传 weather；不选不传（服务端 validWeather 对缺失值置 null，与网页同口径）。
//    publishEntry 同步补齐 quote_id/recipient_id/notify_recipient（默认参数，旧调用点不受影响）。
// 2. 写给：新建模式只选一人（搜索接口 users 组），标签 + 通知对方复选框（默认开；复选框只写
//    本地状态，不触发重渲染）；编辑模式锁定只展示（服务端 PUT 不接受 recipient，改不了）。
//    引用：新建模式只挑自己的时间线（服务端 validQuoteId 只接受本人日记，赞过/收藏的他人日记
//    会被服务端静默丢弃，故不做 liked/saved tab）；编辑模式锁定原值；内容为空的引用视为已删，
//    不回填、保存时即丢弃（与网页编辑同款）。
// 3. 编辑模式：init(entry:) 进入；正文/心情/天气/图片可改；不读不写 beary_draft_v2（
//    scheduleDraftSave/saveDraftNow 在编辑模式直接 return）；取消时不删原日记，改过先确认；
//    保存走 PUT，15 分钟规则只由服务端判定（403 三种过期码统一转“已超过编辑期”文案后关编辑器）；
//    成功后删本轮新选图的本地文件（原日记的图 localFile 为 nil，不受影响），失败不删、留着重试。
// 4. 草稿 v2 字段冻结：天气/写给/引用不在草稿字段里，杀 App 后这三项不恢复（正文/心情/图片照常恢复）；
//    要持久化它们须另起草稿 v3 + 迁移，本片不做。
// 5. 发布确认：新建无失败图时弹一次（标题“发布”，写清 7 天公开与 15 分钟可改）；有失败图时只弹
//    失败图确认，不叠加；编辑模式弹“保存修改”确认。
// 6. 超 2000 字红字提示用 BearyColors.red（网页 --red #e5484d，浅深同值）；图片上的
//    “重试”/× 衬底用 BearyColors.scrim（固定深色半透明，深色下 ink 是近白、白字会看不清）。
//    其余白字只出现在恒定橙底上（选中心情）与墨底上（选中天气），浅深皆可读。
// 3. 图片 × 只移除本地与 key 列表，不调服务端；未发布的孤 key 残留是已知可接受项。
// 4. 草稿 v2（BearyDraftFiles.swift）：正文 + 心情 + 图片项（本地文件名 / 服务端 key / 上传状态）
//    + clientReq（创建时生成一次，发布重试全程复用）+ updatedAt；JSON 文件原子写；
//    v1 草稿首次读取迁移为无本地文件的 key 项，走远程图显示。
// 5. 丢弃草稿 / 发布成功会删本地图片文件；服务端孤 key 无删除接口，残留是已知可接受项。
// 6. 发布时有上传失败的图片会先弹确认（防静默丢图）；离线/网络错误文案为“网络不可用，
//    已保存为草稿，联网后可重试”，失败一律保留草稿。
// 7. 第四项：键盘跟随 WillChangeFrame（旋转/表情键盘/悬浮键盘拖动）；打开编辑器自动聚焦一次，
//    有草稿时光标置末尾；选图按选择顺序占位插入（.ordered + 先建项后填图），读图失败直接移除占位项。
