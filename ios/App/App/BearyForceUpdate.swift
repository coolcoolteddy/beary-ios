import UIKit

// ===== 强制更新 / 柔性提醒 / 远程开关（2026-11-19）=====
// 后端 GET /beary/api/app-announcements 响应带 config 对象：
// { min_build, force_message, update_url, latest_build, disabled_features }。
// 全空（min_build/latest_build 均为 0、disabled_features 为空）时完全无行为。
// 拉取与公告同一次请求（BearyAnnouncementCenter.checkOnLaunch）；最近一次
// 拉到的 min_build/latest_build/disabled_features 存 UserDefaults，离线时
// 仍按上次拉到的值判断；从没拉到过（无存值）则放行。
// 设置页不设“检查更新”入口。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await。

struct BearyAppConfig: Decodable {
    let minBuild: Int?
    let forceMessage: String?
    let updateUrl: String?
    let latestBuild: Int?
    let disabledFeatures: [String]?

    // 不写显式 CodingKeys：BearyAPI 的 decoder 用 convertFromSnakeCase，
    // 会把服务端 min_build/force_message/update_url/latest_build/
    // disabled_features 转成这些 camelCase 名再匹配（同 BearyAnnouncement）。
}

enum BearyDisabledFeature: String {
    case blindbox
    case wishwall
    case starmap
    case publish
    case dm
    case invite
}

final class BearyForceUpdateCenter {
    static let shared = BearyForceUpdateCenter()

    static let defaultUpdateURL = "https://github.com/coolcoolteddy/beary-ios/releases"

    private let minBuildKey = "beary_appconfig_min_build"
    private let latestBuildKey = "beary_appconfig_latest_build"
    private let disabledFeaturesKey = "beary_appconfig_disabled_features"
    private let updateURLKey = "beary_appconfig_update_url"
    private let forceMessageKey = "beary_appconfig_force_message"
    private let softShownBuildKey = "beary_soft_update_shown_build"

    private init() {}

    static func currentBuild() -> Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return Int(raw) ?? 0
    }

    /// 收到 config 即全量存下（字段缺失按 0/空计）；config 本身缺失时不动旧值。
    func store(config: BearyAppConfig) {
        let defaults = UserDefaults.standard
        defaults.set(config.minBuild ?? 0, forKey: minBuildKey)
        defaults.set(config.latestBuild ?? 0, forKey: latestBuildKey)
        defaults.set(config.disabledFeatures ?? [], forKey: disabledFeaturesKey)
        defaults.set(config.updateUrl ?? "", forKey: updateURLKey)
        defaults.set(config.forceMessage ?? "", forKey: forceMessageKey)
    }

    var storedMinBuild: Int { UserDefaults.standard.integer(forKey: minBuildKey) }
    var storedLatestBuild: Int { UserDefaults.standard.integer(forKey: latestBuildKey) }
    var storedDisabledFeatures: [String] {
        UserDefaults.standard.stringArray(forKey: disabledFeaturesKey) ?? []
    }
    var storedUpdateURL: String {
        let url = UserDefaults.standard.string(forKey: updateURLKey) ?? ""
        return url.isEmpty ? Self.defaultUpdateURL : url
    }
    var storedForceMessage: String {
        UserDefaults.standard.string(forKey: forceMessageKey) ?? ""
    }

    var isForceRequired: Bool {
        let min = storedMinBuild
        return min > 0 && Self.currentBuild() < min
    }

    var isSoftUpdateAvailable: Bool {
        let latest = storedLatestBuild
        return latest > 0 && Self.currentBuild() < latest
    }

    func isFeatureDisabled(_ feature: BearyDisabledFeature) -> Bool {
        storedDisabledFeatures.contains(feature.rawValue)
    }

    /// 强制 > 柔性 > 无。返回 true 表示已弹出更新 UI，调用方不再弹公告。
    /// 须在主线程调用；冷启动锁还挂着、或已有 modal 在上时不弹、不记状态。
    @discardableResult
    func tryPresentUpdate(from presenter: UIViewController, announcements: [BearyAnnouncement]) -> Bool {
        guard !BearyAppLockManager.shared.isColdLocked,
              presenter.presentedViewController == nil else { return false }
        if isForceRequired {
            let notes = releaseNotes(for: storedLatestBuild, in: announcements)
            BearyForceUpdateSheet.showForce(from: presenter, message: storedForceMessage, updateURL: storedUpdateURL, notes: notes)
            return true
        }
        if isSoftUpdateAvailable {
            let latest = storedLatestBuild
            // 每构建号只弹一次：先记再弹，关掉后本启动不再重弹。
            guard UserDefaults.standard.integer(forKey: softShownBuildKey) != latest else { return false }
            UserDefaults.standard.set(latest, forKey: softShownBuildKey)
            let notes = releaseNotes(for: latest, in: announcements)
            BearyForceUpdateSheet.showSoft(from: presenter, updateURL: storedUpdateURL, notes: notes)
            return true
        }
        return false
    }

    /// target_build == latest_build 的那条 after-update 公告（标题＋内容）；
    /// 没有对应公告时返回 nil，调用方不显示说明区、不另写文案源。
    private func releaseNotes(for latestBuild: Int, in list: [BearyAnnouncement]) -> BearyAnnouncement? {
        guard latestBuild > 0 else { return nil }
        return list.first { $0.isAfterUpdate && $0.targetBuild == latestBuild }
    }
}

enum BearyForceUpdateSheet {

    // MARK: - 强制更新：不可关闭的底 sheet

    /// 不可关闭的底 sheet：force_message 说明文案＋[去更新]按钮（打开 update_url）。
    /// 走系统 sheet（BearySystemSheet.present，dismissable: false）：禁止下滑关闭、
    /// 禁止点外关闭、隐藏抓手、没有跳过、没有关闭按钮；present 后除非更新否则一直在。
    static func showForce(from presenter: UIViewController, message: String, updateURL: String, notes: BearyAnnouncement?) {
        let vc = BearyForceUpdateViewController(message: message, updateURL: updateURL, notes: notes)
        BearySystemSheet.present(vc, from: presenter, dismissable: false)
    }

    // MARK: - 柔性提醒：可关底 sheet

    /// “有新版本”底 sheet：走系统底部 sheet（UISheetPresentationController，见
    /// BearySystemSheet）。
    /// [立即更新]（打开 update_url）／[稍后再说]（关闭）。
    static func showSoft(from presenter: UIViewController, updateURL: String, notes: BearyAnnouncement?) {
        let sheet = BearySoftUpdateSheetViewController(updateURL: updateURL, notes: notes)
        BearySystemSheet.present(sheet, from: presenter)
    }
}

// MARK: - 强制更新底 sheet（不可关闭）

final class BearyForceUpdateViewController: UIViewController, BearySystemSheetSizing {

    private let message: String
    private let updateURL: String
    private let notes: BearyAnnouncement?

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let notesTitleLabel = UILabel()
    private let notesBodyLabel = UILabel()
    private let buttonStack = UIStackView()
    private let updateButton = BearyButton(style: .primaryPill(.ink))

    init(message: String, updateURL: String, notes: BearyAnnouncement?) {
        self.message = message
        self.updateURL = updateURL
        self.notes = notes
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = NSLocalizedString("force_update.required_title", comment: "")
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        view.addSubview(titleLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.text = message.isEmpty ? NSLocalizedString("force_update.too_old_body", comment: "") : message
        bodyLabel.font = BearyDynamicType.smallBodyFont()
        bodyLabel.textColor = BearyColors.gray
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        view.addSubview(bodyLabel)

        var lastView: UIView = bodyLabel
        var lastConstant: CGFloat = 24
        if let notes = notes {
            notesTitleLabel.translatesAutoresizingMaskIntoConstraints = false
            notesTitleLabel.text = notes.title
            notesTitleLabel.font = BearyDynamicType.smallActionFont()
            notesTitleLabel.textColor = BearyColors.ink
            notesTitleLabel.textAlignment = .center
            notesTitleLabel.numberOfLines = 0
            view.addSubview(notesTitleLabel)

            notesBodyLabel.translatesAutoresizingMaskIntoConstraints = false
            notesBodyLabel.text = notes.content
            notesBodyLabel.font = BearyDynamicType.smallBodyFont()
            notesBodyLabel.textColor = BearyColors.gray
            notesBodyLabel.textAlignment = .center
            notesBodyLabel.numberOfLines = 0
            view.addSubview(notesBodyLabel)

            NSLayoutConstraint.activate([
                notesTitleLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 24),
                notesTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                notesTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                notesBodyLabel.topAnchor.constraint(equalTo: notesTitleLabel.bottomAnchor, constant: 8),
                notesBodyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                notesBodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            ])
            lastView = notesBodyLabel
            lastConstant = 24
        }

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .vertical
        buttonStack.spacing = BearySpace.sm
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.setTitle(NSLocalizedString("force_update.go_update", comment: ""), for: .normal)
        updateButton.addTarget(self, action: #selector(updateTapped), for: .touchUpInside)
        updateButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(updateButton)
        updateButton.heightAnchor.constraint(equalToConstant: updateButton.style.height).isActive = true
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            // 抓手已隐藏（不可关闭，不暗示能关）：标题直接顶 16，不留抓手区。
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: lastConstant),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        // 宽屏（≥821）不另收窄：sheet 宽由 BearySystemSheet.present 按 600 居中定。
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高（柔性提醒 sheet 同款）。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height) + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    @objc private func updateTapped() {
        if let url = URL(string: updateURL) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - 柔性提醒底 sheet

final class BearySoftUpdateSheetViewController: UIViewController, BearySystemSheetSizing {

    private let updateURL: String
    private let notes: BearyAnnouncement?

    private let titleLabel = UILabel()
    private let notesTitleLabel = UILabel()
    private let notesBodyLabel = UILabel()
    private let buttonStack = UIStackView()

    init(updateURL: String, notes: BearyAnnouncement?) {
        self.updateURL = updateURL
        self.notes = notes
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = NSLocalizedString("force_update.new_version_title", comment: "")
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        view.addSubview(titleLabel)

        var lastView: UIView = titleLabel
        var lastConstant: CGFloat = 8
        if let notes = notes {
            notesTitleLabel.translatesAutoresizingMaskIntoConstraints = false
            notesTitleLabel.text = notes.title
            notesTitleLabel.font = BearyDynamicType.smallActionFont()
            notesTitleLabel.textColor = BearyColors.ink
            notesTitleLabel.numberOfLines = 0
            view.addSubview(notesTitleLabel)

            notesBodyLabel.translatesAutoresizingMaskIntoConstraints = false
            notesBodyLabel.text = notes.content
            notesBodyLabel.font = BearyDynamicType.smallBodyFont()
            notesBodyLabel.textColor = BearyColors.gray
            notesBodyLabel.numberOfLines = 0
            view.addSubview(notesBodyLabel)

            NSLayoutConstraint.activate([
                notesTitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
                notesTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                notesTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                notesBodyLabel.topAnchor.constraint(equalTo: notesTitleLabel.bottomAnchor, constant: 8),
                notesBodyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                notesBodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            ])
            lastView = notesBodyLabel
            lastConstant = 16
        }

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .vertical
        buttonStack.spacing = BearySpace.sm
        let updateButton = BearyButton(style: .primaryPill(.ink))
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.setTitle(NSLocalizedString("force_update.update_now", comment: ""), for: .normal)
        updateButton.addTarget(self, action: #selector(updateTapped), for: .touchUpInside)
        updateButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(updateButton)
        updateButton.heightAnchor.constraint(equalToConstant: updateButton.style.height).isActive = true
        let laterButton = BearyButton(style: .secondaryOutline(.regular))
        laterButton.translatesAutoresizingMaskIntoConstraints = false
        laterButton.setTitle(NSLocalizedString("force_update.later", comment: ""), for: .normal)
        laterButton.addTarget(self, action: #selector(laterTapped), for: .touchUpInside)
        laterButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(laterButton)
        laterButton.heightAnchor.constraint(equalToConstant: laterButton.style.height).isActive = true
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            // 顶部留白与旧抓手区等高（抓手顶 10＋高 4＋标题间距 16）：系统抓手
            // 占顶区，标题位置不动。
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: lastConstant),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -BearySystemSheet.contentBottomPadding),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高（公告 sheet 同款）。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height) + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    @objc private func updateTapped() {
        if let url = URL(string: updateURL) {
            UIApplication.shared.open(url)
        }
        dismiss(animated: BearyMotion.animated(true))
    }

    @objc private func laterTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }
}
