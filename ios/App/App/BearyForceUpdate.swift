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

    // MARK: - 强制更新：全屏遮罩

    /// 全屏遮罩：force_message 说明文案＋[去更新]按钮（打开 update_url）。
    /// 点外面关不掉、没有跳过、没有关闭按钮；present 后除非更新否则一直在。
    static func showForce(from presenter: UIViewController, message: String, updateURL: String, notes: BearyAnnouncement?) {
        let vc = BearyForceUpdateViewController(message: message, updateURL: updateURL, notes: notes)
        vc.modalPresentationStyle = .fullScreen
        vc.isModalInPresentation = true
        presenter.present(vc, animated: BearyMotion.animated(true))
    }

    // MARK: - 柔性提醒：可关底 sheet

    /// “有新版本”底 sheet：走共享底部弹窗容器 BearyBottomSheet（与公告底 sheet
    /// 同款：弹簧 0.38s 上升、背后缩 0.92、遮罩 0.45、下拖关/弹回）。
    /// [立即更新]（打开 update_url）／[稍后再说]（关闭）。
    static func showSoft(from presenter: UIViewController, updateURL: String, notes: BearyAnnouncement?) {
        let sheet = BearySoftUpdateSheetViewController(updateURL: updateURL, notes: notes)
        let delegate = BearyBottomSheetTransitioningDelegate()
        sheet.sheetDelegate = delegate
        sheet.transitioningDelegate = delegate
        sheet.modalPresentationStyle = .custom
        sheet.loadViewIfNeeded()
        let presenterWidth = presenter.view.bounds.width
        let sheetWidth: CGFloat = presenterWidth >= 821 ? min(600, presenterWidth - 32) : presenterWidth
        sheet.view.frame = CGRect(x: 0, y: 0, width: max(sheetWidth, 1), height: 800)
        sheet.view.setNeedsLayout()
        sheet.view.layoutIfNeeded()
        sheet.updatePreferredContentSize(extraBottomInset: presenter.view.safeAreaInsets.bottom)
        presenter.present(sheet, animated: BearyMotion.animated(true))
    }
}

// MARK: - 强制更新全屏页

final class BearyForceUpdateViewController: UIViewController {

    private let message: String
    private let updateURL: String
    private let notes: BearyAnnouncement?

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let notesTitleLabel = UILabel()
    private let notesBodyLabel = UILabel()
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
        view.backgroundColor = BearyColors.bg

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "需要更新"
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        view.addSubview(titleLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.text = message.isEmpty ? "当前版本过低，请更新到最新版本后继续使用。" : message
        bodyLabel.font = BearyDynamicType.smallBodyFont()
        bodyLabel.textColor = BearyColors.gray
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        view.addSubview(bodyLabel)

        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.setTitle("去更新", for: .normal)
        updateButton.addTarget(self, action: #selector(updateTapped), for: .touchUpInside)
        updateButton.bearyAddPressFeedback()
        view.addSubview(updateButton)

        var lastAnchor: NSLayoutYAxisAnchor = bodyLabel.bottomAnchor
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
                notesTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
                notesTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
                notesBodyLabel.topAnchor.constraint(equalTo: notesTitleLabel.bottomAnchor, constant: 8),
                notesBodyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
                notesBodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            ])
            lastAnchor = notesBodyLabel.bottomAnchor
            lastConstant = 24
        }

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            bodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            updateButton.topAnchor.constraint(equalTo: lastAnchor, constant: lastConstant),
            updateButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            updateButton.widthAnchor.constraint(equalToConstant: 200),
            updateButton.heightAnchor.constraint(equalToConstant: updateButton.style.height),
        ])
        // 宽屏（≥821）不另收窄：32 边距贴边，与窄屏同一版式，保持最小实现。
    }

    @objc private func updateTapped() {
        if let url = URL(string: updateURL) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - 柔性提醒底 sheet

final class BearySoftUpdateSheetViewController: UIViewController {

    private let updateURL: String
    private let notes: BearyAnnouncement?

    /// transitioningDelegate 是弱引用，须由本页自己强持有（公告 sheet 同款做法）。
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?

    private let grabberView = UIView()
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
        view.backgroundColor = BearyColors.surface3
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        grabberView.translatesAutoresizingMaskIntoConstraints = false
        grabberView.backgroundColor = BearyColors.gray
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        view.addSubview(grabberView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "有新版本"
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
        buttonStack.spacing = 8
        let updateButton = BearyButton(style: .primaryPill(.ink))
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.setTitle("立即更新", for: .normal)
        updateButton.addTarget(self, action: #selector(updateTapped), for: .touchUpInside)
        updateButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(updateButton)
        updateButton.heightAnchor.constraint(equalToConstant: updateButton.style.height).isActive = true
        let laterButton = BearyButton(style: .secondaryOutline(.regular))
        laterButton.translatesAutoresizingMaskIntoConstraints = false
        laterButton.setTitle("稍后再说", for: .normal)
        laterButton.addTarget(self, action: #selector(laterTapped), for: .touchUpInside)
        laterButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(laterButton)
        laterButton.heightAnchor.constraint(equalToConstant: laterButton.style.height).isActive = true
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),

            titleLabel.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: lastView.bottomAnchor, constant: lastConstant),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给容器当 sheet 高（公告 sheet 同款）。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height) + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
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
