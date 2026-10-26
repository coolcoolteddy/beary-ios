import UIKit

// ===== beary 原生账户设置页（F 批新建；此前齿轮菜单与头像菜单的“账户设置”均为 presentComingSoon 占位）=====
// 对照源（动手前均已 grep 核实，以服务端与网页实现为准，不编造接口）：
// - 网页 ~/workspace/teddy_site/account.html：ID 卡（头像/名/邮箱/注册时间/会员/@handle）、
//   Plus 分组、登录设备列表 + 退出其他设备、导出我的数据、注销账户（两步确认 + 7 天冷静期）。
// - 账户 Worker ~/workspace/teddy_accounts_v2/worker.js（端点与字段均以它为准）：
//   GET /api/account/me → {ok, user: {id, is_admin, email, display_name, avatar, cover_ver,
//     created_at, handle, plus, plus_until, plus_free, invite_code, referral}}。
//     注意：现行 /me 不返回 serial_id（旧版备份里才有 TD-000001 式 serial_id），
//     故本页 ID 行不编造序列号：serial_id 若将来由服务端下发则显示它，
//     否则显示 @handle（与现行网页 heroId 口径一致），再无 handle 时显示“ID <id>”。
//   GET /api/account/plus-detail → {ok, personal_until, free_until, effective_until,
//     permanent, grants: [{days, source, created_at, until_after}]}（LIMIT 20，id DESC）。
//     结论：第 3 项 Plus 发放记录明细有现成接口，直接接它，不编造、不造假数据。
//   GET /api/account/sessions → {ok, sessions: [{id, is_current, created_at, expires_at,
//     expired, ua, device, ip, region, last_active}], active_count}（未过期数才计入 active_count）。
//   DELETE /api/account/sessions/others → {ok}：服务端单条 DELETE 排除当前会话
//     （token_hash != 当前 OR token_hash IS NULL），当前会话必保留；被踢设备下次 /me 领 kicked。
//   POST /api/account/delete → {ok, delete_at}（delete_at = 发起 + 7 天）；
//     服务端对管理员返回 403 {error: 'admin_cannot_delete'}，本页以该服务端判定为准，
//     客户端不写 id == 1 / 2 的判断，只用 /me 下发的 is_admin（服务端算出）隐藏注销入口，
//     且 403 透传为“管理员账号不能注销”，服务端仍是最终判定。
//   POST /api/account/session-device（网页 loadSessions 先补报当前设备型号）：本页不移植——
//     原生 URLSession 的 UA 不含 iPhone 标记，服务端 deviceLabel 的 iPhone 分支走不通，
//     补报恒得“浏览器”，无收益且可能覆盖登录时已有的设备标签；列表直接读 /sessions 的
//     device 字段，空时按网页同款 UA 回退（iPhone / iPad / Android / Mac / Windows / 浏览器）推断。
// - 导出（网页 exportDataBtn 口径，客户端拼 JSON，不新编服务端接口）：
//   profile = /me 的 user（data: 头像改写为 [avatar]）；sessions = /sessions 原样；
//   diaries = scope=mine（公开，is_private=false）+ scope=mailbox（私密，is_private=true）分页拉全；
//   liked_entries = scope=liked 分页拉全；图片 key 拼 https://teddyhn.com/beary/api/images/<key>；
//   时间戳转 ISO；分页每页 limit=50、guard 20 页（与网页 fetchAll 同口径）。
//     App 侧分页另带 before_id（服务端排序 created_at DESC, id DESC，App fetchEntries 既有口径），
//     比网页只传 before 更稳，不改变服务端语义。
// - 网络层：本文件只用 BearyAPI.request 通用请求（BearyAPI.swift 不新增方法；
//   唯一动 BearyAPI.swift 的地方是 MeUser 补一个可选 serialId 字段，见该文件处注释）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
// 不用 if-let 简写；颜色只走 BearyColors；不新增玻璃效果；不用 SF Symbol；
// 无 force unwrap；不用裸 `id` 作变量名（统一用带后缀的名字）；不改 tint 写法；
// 不碰徽章“暂无徽章”诊断文案；不碰 52/55 锚点；本页不自己 dismiss，关闭/登录/注销完成一律走回调，容器决定去向。

// MARK: - 账户接口响应模型（BearyAPI 的 decoder 用 convertFromSnakeCase，只写 camelCase 名）

struct BearyAccountSession: Decodable {
    var sessionIdValue: String?
    var isCurrent: Bool?
    var createdAt: Int?
    var expiresAt: Int?
    var expired: Bool?
    var ua: String?
    var device: String?
    var ip: String?
    var region: String?
    var lastActive: Int?

    enum CodingKeys: String, CodingKey {
        case sessionIdValue = "id"
        case isCurrent
        case createdAt
        case expiresAt
        case expired
        case ua
        case device
        case ip
        case region
        case lastActive
    }
}

struct BearyAccountSessionsResponse: Decodable {
    var ok: Bool?
    var sessions: [BearyAccountSession]?
    var activeCount: Int?
}

struct BearyPlusGrant: Decodable {
    var days: Int?
    var source: String?
    var createdAt: Int?
    var untilAfter: Int?
}

struct BearyPlusDetailResponse: Decodable {
    var ok: Bool?
    var personalUntil: Int?
    var freeUntil: Int?
    var effectiveUntil: Int?
    var permanent: Bool?
    var grants: [BearyPlusGrant]?
}

struct BearyAccountOkResponse: Decodable {
    var ok: Bool?
}

struct BearyAccountDeleteResponse: Decodable {
    var ok: Bool?
    var deleteAt: Int?
}

// MARK: - BearyAPI 账户扩展（只用既有 request 通用请求，不自创新网络层）

extension BearyAPI {
    /// GET /api/account/sessions（登录设备列表；未登录 401，走 onUnauthorized）。
    func fetchAccountSessions(completion: @escaping (Result<BearyAccountSessionsResponse, APIError>) -> Void) {
        request("/api/account/sessions", completion: completion)
    }

    /// GET /api/account/plus-detail（Plus 分层 + 发放账本；未登录 401）。
    func fetchPlusDetail(completion: @escaping (Result<BearyPlusDetailResponse, APIError>) -> Void) {
        request("/api/account/plus-detail", completion: completion)
    }

    /// DELETE /api/account/sessions/others（退出当前设备之外的全部会话；当前会话服务端必保留）。
    func revokeOtherSessions(completion: @escaping (Result<BearyAccountOkResponse, APIError>) -> Void) {
        request("/api/account/sessions/others", method: "DELETE", completion: completion)
    }

    /// POST /api/account/delete（注销发起；服务端返回 delete_at = 发起 + 7 天冷静期；
    /// 管理员 403 admin_cannot_delete，调用方须透传该判定，不得在客户端另造禁注销规则）。
    func requestAccountDelete(completion: @escaping (Result<BearyAccountDeleteResponse, APIError>) -> Void) {
        request("/api/account/delete", method: "POST", completion: completion)
    }
}

// MARK: - 账户页文案与时间口径（与网页 account.html 同款）

private enum BearyAccountText {
    /// 永久会员阈值：网页与服务端同款常量（plus_until >= 该值即永久）。
    static let permanentThreshold: Int = 4102444800000

    static func dateString(ms: Int?) -> String {
        guard let value = ms, value > 0 else { return "–" }
        let date = Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月d日"
        return fmt.string(from: date)
    }

    static func dateTimeString(ms: Int?) -> String {
        guard let value = ms, value > 0 else { return "–" }
        let date = Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月d日 HH:mm"
        return fmt.string(from: date)
    }

    /// 毫秒转 ISO（网页导出 toMs + toISOString 同口径：秒级值先 ×1000）。
    static func isoString(ms: Int?) -> String? {
        guard let value = ms, value != 0 else { return nil }
        let msValue = value < 1000000000000 ? value * 1000 : value
        let date = Date(timeIntervalSince1970: TimeInterval(msValue) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return fmt.string(from: date)
    }

    /// 网页 loadSessions 同款设备名回退：服务端 device 为空时按 UA 推断。
    static func deviceName(session: BearyAccountSession) -> String {
        if let dev = session.device, !dev.isEmpty { return dev }
        let ua = session.ua ?? ""
        if ua.contains("iPhone") { return "iPhone" }
        if ua.contains("iPad") { return "iPad" }
        if ua.contains("Android") { return "Android" }
        if ua.contains("Mac") { return "Mac" }
        if ua.contains("Windows") { return "Windows" }
        return "浏览器"
    }

    /// 网页 pdGrants 同款来源文案；未知来源一律“系统赠送”，不编造新来源名。
    static func grantSourceName(_ source: String?) -> String {
        switch source {
        case "admin": return "管理员开通"
        case "referral_inviter": return "邀请好友奖励"
        case "referral_invitee": return "受邀注册奖励"
        default: return "系统赠送"
        }
    }

    static func grantValueText(days: Int?) -> String {
        if days == -1 { return "永久" }
        if days == 0 { return "已取消专属会员" }
        if let value = days { return "+\(value) 天" }
        return "–"
    }
}

// MARK: - 账户设置页

final class BearyAccountViewController: UIViewController {

    /// 点关闭钮：容器接线到关闭本页（本页不自己 dismiss）。
    var onClose: (() -> Void)?
    /// 未登录 / 会话失效：容器接线到登录页。
    var onRequireLogin: (() -> Void)?
    /// 注销发起成功且用户已看到“7 天后正式注销”提示后：容器接线到清 cookie、
    /// 本地退出并关闭本页（服务端在注销发起时已清全部会话）。
    var onAccountDeleted: (() -> Void)?

    // MARK: - 状态

    private var meUser: MeUser?
    private var plusDetail: BearyPlusDetailResponse?
    private var accountSessions: [BearyAccountSession] = []
    private var isLoadingMe = false
    private var isLoggingOutOthers = false
    private var isDeleting = false
    private var isExporting = false
    private var toastTimer: Timer?
    private var contentColumnWidthCap: NSLayoutConstraint?

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let loadingView = UIActivityIndicatorView(style: .medium)
    private let failureWrap = UIStackView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let loginWrap = UIStackView()
    private let loginHintLabel = UILabel()
    private let loginButton = UIButton(type: .system)
    private let contentWrap = UIStackView()

    // ID 卡
    private let avatarContainer = UIView()
    private let avatarImageView = UIImageView()
    private let avatarInitialLabel = UILabel()
    private let heroNameLabel = UILabel()
    private let heroEmailLabel = UILabel()
    private let idCreatedLabel = UILabel()
    private let idPlusLabel = UILabel()
    private let idValueLabel = UILabel()

    // Plus 分组
    private let plusStatusLabel = UILabel()
    private var plusFreeRow: UIView = UIView()
    private let plusFreeLabel = UILabel()
    private let plusPersonalLabel = UILabel()
    private let grantsStack = UIStackView()

    // 账户分组
    private let accountNameLabel = UILabel()
    private let accountHandleLabel = UILabel()
    private let copyHandleButton = UIButton(type: .system)
    private let accountEmailLabel = UILabel()
    private let accountCreatedLabel = UILabel()

    // 设备分组
    private let deviceCountLabel = UILabel()
    private let sessionsStack = UIStackView()
    private let logoutOthersButton = UIButton(type: .system)

    // 操作分组
    private let exportRowButton = UIButton(type: .custom)
    private let deleteRow = UIView()
    private let deleteRowButton = UIButton(type: .custom)

    private let toastWrap = UIView()
    private let toastLabel = UILabel()

    init() {
        super.init(nibName: nil, bundle: nil)
        self.title = "账户设置"
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        toastTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        loadAll()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // P2-1 同款：宽 ≥821 才锁 600 上限；宽 ≤820 时停用，屏宽 -40 撑满。
        contentColumnWidthCap?.isActive = view.bounds.width >= 821
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷描边（背景色走动态色，自动跟随）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            logoutOthersButton.layer.borderColor = BearyColors.line.cgColor
        }
    }

    /// 容器重进本页时手动刷新（首屏重置由 loadAll 保证）。
    func reloadAccount() {
        loadAll()
    }

    // MARK: - 布局

    private func makeLabel(font: UIFont, color: UIColor, lines: Int = 1, alignment: NSTextAlignment = .left) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        label.textAlignment = alignment
        label.lineBreakMode = .byCharWrapping
        return label
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = makeLabel(font: UIFont.systemFont(ofSize: 14, weight: .bold), color: BearyColors.ink)
        label.text = text
        return label
    }

    private func makeRow(title: String, detailLabel: UILabel) -> UIView {
        let titleLabelValue = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        titleLabelValue.text = title
        titleLabelValue.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabel.textAlignment = .right
        let row = UIStackView(arrangedSubviews: [titleLabelValue, detailLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    private func makeCard(_ inner: UIStackView) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.faint
        card.layer.cornerRadius = 14
        card.clipsToBounds = true
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeCardStack(spacing: CGFloat = 12) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }

    private func buildLayout() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "账户设置"

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            topBar.heightAnchor.constraint(equalToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        view.addSubview(topBar)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
        ])
        let columnWidth = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        columnWidth.priority = UILayoutPriority(750)
        columnWidth.isActive = true
        contentColumnWidthCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentColumnWidthCap?.isActive = true

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.font = UIFont.systemFont(ofSize: 14)
        failureLabel.textColor = BearyColors.gray
        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .center
        failureLabel.text = "加载失败，请重试"
        retryButton.setTitle("重试", for: .normal)
        retryButton.setTitleColor(BearyColors.ink, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)
        failureWrap.translatesAutoresizingMaskIntoConstraints = false
        failureWrap.axis = .vertical
        failureWrap.spacing = 12
        failureWrap.alignment = .center
        failureWrap.addArrangedSubview(failureLabel)
        failureWrap.addArrangedSubview(retryButton)
        failureWrap.isHidden = true

        loginHintLabel.font = UIFont.systemFont(ofSize: 14)
        loginHintLabel.textColor = BearyColors.gray
        loginHintLabel.numberOfLines = 0
        loginHintLabel.textAlignment = .center
        loginHintLabel.text = "请先登录"
        loginButton.setTitle("去登录", for: .normal)
        loginButton.setTitleColor(BearyColors.ink, for: .normal)
        loginButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        loginButton.addTarget(self, action: #selector(loginButtonTapped), for: .touchUpInside)
        loginWrap.translatesAutoresizingMaskIntoConstraints = false
        loginWrap.axis = .vertical
        loginWrap.spacing = 12
        loginWrap.alignment = .center
        loginWrap.addArrangedSubview(loginHintLabel)
        loginWrap.addArrangedSubview(loginButton)
        loginWrap.isHidden = true

        contentWrap.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.axis = .vertical
        contentWrap.spacing = 20
        contentWrap.alignment = .fill
        contentWrap.isHidden = true

        buildIdCard()
        buildPlusSection()
        buildAccountSection()
        buildDevicesSection()
        buildActionsSection()

        contentStack.addArrangedSubview(loadingView)
        contentStack.addArrangedSubview(failureWrap)
        contentStack.addArrangedSubview(loginWrap)
        contentStack.addArrangedSubview(contentWrap)

        toastWrap.backgroundColor = BearyColors.ink
        toastWrap.layer.cornerRadius = 16
        toastWrap.clipsToBounds = true
        toastWrap.alpha = 0
        toastWrap.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.font = UIFont.systemFont(ofSize: 14)
        toastLabel.textColor = BearyColors.bg
        toastLabel.backgroundColor = .clear
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toastWrap)
        toastWrap.addSubview(toastLabel)
        NSLayoutConstraint.activate([
            toastWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toastWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            toastWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastWrap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            toastLabel.topAnchor.constraint(equalTo: toastWrap.topAnchor, constant: 10),
            toastLabel.leadingAnchor.constraint(equalTo: toastWrap.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastWrap.trailingAnchor, constant: -14),
            toastLabel.bottomAnchor.constraint(equalTo: toastWrap.bottomAnchor, constant: -10),
        ])
    }

    private func buildIdCard() {
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.backgroundColor = BearyColors.faint
        avatarContainer.layer.cornerRadius = 36
        avatarContainer.clipsToBounds = true
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarInitialLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarInitialLabel.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        avatarInitialLabel.textColor = BearyColors.ink
        avatarInitialLabel.textAlignment = .center
        avatarContainer.addSubview(avatarImageView)
        avatarContainer.addSubview(avatarInitialLabel)
        NSLayoutConstraint.activate([
            avatarContainer.widthAnchor.constraint(equalToConstant: 72),
            avatarContainer.heightAnchor.constraint(equalToConstant: 72),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
        ])
        heroNameLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        heroNameLabel.textColor = BearyColors.ink
        heroNameLabel.numberOfLines = 0
        heroNameLabel.lineBreakMode = .byCharWrapping
        heroEmailLabel.font = UIFont.systemFont(ofSize: 14)
        heroEmailLabel.textColor = BearyColors.gray
        heroEmailLabel.numberOfLines = 0
        heroEmailLabel.lineBreakMode = .byCharWrapping
        let nameStack = UIStackView(arrangedSubviews: [heroNameLabel, heroEmailLabel])
        nameStack.axis = .vertical
        nameStack.spacing = 4
        let heroRow = UIStackView(arrangedSubviews: [avatarContainer, nameStack])
        heroRow.axis = .horizontal
        heroRow.spacing = 16
        heroRow.alignment = .center

        idCreatedLabel.font = UIFont.systemFont(ofSize: 14)
        idCreatedLabel.textColor = BearyColors.gray
        idCreatedLabel.numberOfLines = 0
        idCreatedLabel.textAlignment = .right
        idPlusLabel.font = UIFont.systemFont(ofSize: 14)
        idPlusLabel.textColor = BearyColors.gray
        idPlusLabel.numberOfLines = 0
        idPlusLabel.textAlignment = .right
        idValueLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        idValueLabel.textColor = BearyColors.ink
        idValueLabel.numberOfLines = 0
        idValueLabel.lineBreakMode = .byCharWrapping
        let idTitleLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        idTitleLabel.text = "ID"
        let idRow = UIStackView(arrangedSubviews: [idTitleLabel, idValueLabel])
        idRow.axis = .horizontal
        idRow.spacing = 12
        idRow.alignment = .center

        let cardStack = makeCardStack(spacing: 12)
        cardStack.addArrangedSubview(heroRow)
        cardStack.addArrangedSubview(makeRow(title: "注册时间", detailLabel: idCreatedLabel))
        cardStack.addArrangedSubview(makeRow(title: "会员", detailLabel: idPlusLabel))
        cardStack.addArrangedSubview(idRow)
        contentWrap.addArrangedSubview(makeCard(cardStack))
    }

    private func buildPlusSection() {
        plusStatusLabel.font = UIFont.systemFont(ofSize: 14)
        plusStatusLabel.textColor = BearyColors.gray
        plusStatusLabel.numberOfLines = 0
        plusStatusLabel.textAlignment = .right
        plusFreeLabel.font = UIFont.systemFont(ofSize: 14)
        plusFreeLabel.textColor = BearyColors.gray
        plusFreeLabel.numberOfLines = 0
        plusFreeLabel.textAlignment = .right
        plusPersonalLabel.font = UIFont.systemFont(ofSize: 14)
        plusPersonalLabel.textColor = BearyColors.gray
        plusPersonalLabel.numberOfLines = 0
        plusPersonalLabel.textAlignment = .right
        grantsStack.axis = .vertical
        grantsStack.spacing = 12
        grantsStack.alignment = .fill
        let cardStack = makeCardStack(spacing: 12)
        cardStack.addArrangedSubview(makeRow(title: "当前状态", detailLabel: plusStatusLabel))
        plusFreeRow = makeRow(title: "内测限免", detailLabel: plusFreeLabel)
        cardStack.addArrangedSubview(plusFreeRow)
        cardStack.addArrangedSubview(makeRow(title: "专属会员", detailLabel: plusPersonalLabel))
        cardStack.addArrangedSubview(grantsStack)
        contentWrap.addArrangedSubview(makeSectionTitle("Plus 会员"))
        contentWrap.addArrangedSubview(makeCard(cardStack))
    }

    private func buildAccountSection() {
        accountNameLabel.font = UIFont.systemFont(ofSize: 14)
        accountNameLabel.textColor = BearyColors.gray
        accountNameLabel.numberOfLines = 0
        accountNameLabel.textAlignment = .right
        accountHandleLabel.font = UIFont.systemFont(ofSize: 14)
        accountHandleLabel.textColor = BearyColors.gray
        accountHandleLabel.numberOfLines = 0
        accountHandleLabel.textAlignment = .right
        copyHandleButton.setTitle("复制", for: .normal)
        copyHandleButton.setTitleColor(BearyColors.ink, for: .normal)
        copyHandleButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        copyHandleButton.addTarget(self, action: #selector(copyHandleButtonTapped), for: .touchUpInside)
        accountEmailLabel.font = UIFont.systemFont(ofSize: 14)
        accountEmailLabel.textColor = BearyColors.gray
        accountEmailLabel.numberOfLines = 0
        accountEmailLabel.textAlignment = .right
        accountCreatedLabel.font = UIFont.systemFont(ofSize: 14)
        accountCreatedLabel.textColor = BearyColors.gray
        accountCreatedLabel.numberOfLines = 0
        accountCreatedLabel.textAlignment = .right
        let verifiedLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.green)
        verifiedLabel.text = "已验证"
        let emailRow = makeRow(title: "邮箱", detailLabel: accountEmailLabel)
        if let stack = emailRow as? UIStackView {
            stack.addArrangedSubview(verifiedLabel)
        }
        let handleRow = makeRow(title: "用户名", detailLabel: accountHandleLabel)
        if let stack = handleRow as? UIStackView {
            stack.addArrangedSubview(copyHandleButton)
        }
        let cardStack = makeCardStack(spacing: 12)
        cardStack.addArrangedSubview(makeRow(title: "显示名称", detailLabel: accountNameLabel))
        cardStack.addArrangedSubview(handleRow)
        cardStack.addArrangedSubview(emailRow)
        cardStack.addArrangedSubview(makeRow(title: "注册时间", detailLabel: accountCreatedLabel))
        contentWrap.addArrangedSubview(makeSectionTitle("账户"))
        contentWrap.addArrangedSubview(makeCard(cardStack))
    }

    private func buildDevicesSection() {
        deviceCountLabel.font = UIFont.systemFont(ofSize: 14)
        deviceCountLabel.textColor = BearyColors.gray
        deviceCountLabel.numberOfLines = 0
        deviceCountLabel.textAlignment = .right
        let refreshButton = UIButton(type: .system)
        refreshButton.setTitle("刷新", for: .normal)
        refreshButton.setTitleColor(BearyColors.ink, for: .normal)
        refreshButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        refreshButton.addTarget(self, action: #selector(refreshSessionsButtonTapped), for: .touchUpInside)
        let headerRow = UIStackView(arrangedSubviews: [makeSectionTitle("登录设备"), deviceCountLabel, refreshButton])
        headerRow.axis = .horizontal
        headerRow.spacing = 12
        headerRow.alignment = .center
        sessionsStack.axis = .vertical
        sessionsStack.spacing = 12
        sessionsStack.alignment = .fill
        logoutOthersButton.translatesAutoresizingMaskIntoConstraints = false
        logoutOthersButton.setTitle("退出其他设备", for: .normal)
        logoutOthersButton.setTitleColor(BearyColors.red, for: .normal)
        logoutOthersButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        logoutOthersButton.layer.borderWidth = 1
        logoutOthersButton.layer.borderColor = BearyColors.line.cgColor
        logoutOthersButton.layer.cornerRadius = 10
        logoutOthersButton.addTarget(self, action: #selector(logoutOthersButtonTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            logoutOthersButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        let cardStack = makeCardStack(spacing: 12)
        cardStack.addArrangedSubview(sessionsStack)
        cardStack.addArrangedSubview(logoutOthersButton)
        contentWrap.addArrangedSubview(headerRow)
        contentWrap.addArrangedSubview(makeCard(cardStack))
    }

    private func buildActionsSection() {
        let exportTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        exportTitle.text = "导出我的数据"
        let exportDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        exportDetail.text = "下载 JSON，含账户、日记、点赞记录"
        let exportStack = UIStackView(arrangedSubviews: [exportTitle, exportDetail])
        exportStack.axis = .vertical
        exportStack.spacing = 4
        exportRowButton.translatesAutoresizingMaskIntoConstraints = false
        exportRowButton.addTarget(self, action: #selector(exportButtonTapped), for: .touchUpInside)
        let exportRow = UIView()
        exportRow.translatesAutoresizingMaskIntoConstraints = false
        exportRow.addSubview(exportStack)
        exportRow.addSubview(exportRowButton)
        exportStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            exportStack.topAnchor.constraint(equalTo: exportRow.topAnchor),
            exportStack.leadingAnchor.constraint(equalTo: exportRow.leadingAnchor),
            exportStack.trailingAnchor.constraint(equalTo: exportRow.trailingAnchor),
            exportStack.bottomAnchor.constraint(equalTo: exportRow.bottomAnchor),
            exportRowButton.topAnchor.constraint(equalTo: exportRow.topAnchor),
            exportRowButton.leadingAnchor.constraint(equalTo: exportRow.leadingAnchor),
            exportRowButton.trailingAnchor.constraint(equalTo: exportRow.trailingAnchor),
            exportRowButton.bottomAnchor.constraint(equalTo: exportRow.bottomAnchor),
        ])

        let deleteTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.red)
        deleteTitle.text = "注销账户"
        let deleteDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        deleteDetail.text = "7 天冷静期，期间登录可取消"
        let deleteStack = UIStackView(arrangedSubviews: [deleteTitle, deleteDetail])
        deleteStack.axis = .vertical
        deleteStack.spacing = 4
        deleteRowButton.translatesAutoresizingMaskIntoConstraints = false
        deleteRowButton.addTarget(self, action: #selector(deleteButtonTapped), for: .touchUpInside)
        deleteRow.translatesAutoresizingMaskIntoConstraints = false
        deleteStack.translatesAutoresizingMaskIntoConstraints = false
        deleteRow.addSubview(deleteStack)
        deleteRow.addSubview(deleteRowButton)
        NSLayoutConstraint.activate([
            deleteStack.topAnchor.constraint(equalTo: deleteRow.topAnchor),
            deleteStack.leadingAnchor.constraint(equalTo: deleteRow.leadingAnchor),
            deleteStack.trailingAnchor.constraint(equalTo: deleteRow.trailingAnchor),
            deleteStack.bottomAnchor.constraint(equalTo: deleteRow.bottomAnchor),
            deleteRowButton.topAnchor.constraint(equalTo: deleteRow.topAnchor),
            deleteRowButton.leadingAnchor.constraint(equalTo: deleteRow.leadingAnchor),
            deleteRowButton.trailingAnchor.constraint(equalTo: deleteRow.trailingAnchor),
            deleteRowButton.bottomAnchor.constraint(equalTo: deleteRow.bottomAnchor),
        ])

        let cardStack = makeCardStack(spacing: 12)
        cardStack.addArrangedSubview(exportRow)
        cardStack.addArrangedSubview(deleteRow)
        contentWrap.addArrangedSubview(makeSectionTitle("数据与安全"))
        contentWrap.addArrangedSubview(makeCard(cardStack))
    }

    // MARK: - 动作

    @objc private func closeButtonTapped() {
        onClose?()
    }

    @objc private func retryButtonTapped() {
        loadAll()
    }

    @objc private func loginButtonTapped() {
        onRequireLogin?()
    }

    @objc private func refreshSessionsButtonTapped() {
        loadSessions()
    }

    @objc private func copyHandleButtonTapped() {
        guard let handle = meUser?.handle, !handle.isEmpty else {
            showToast("还没设置用户名")
            return
        }
        UIPasteboard.general.string = "https://teddyhn.com/beary/@" + handle
        showToast("主页链接已复制")
    }

    // MARK: - 加载

    private func loadAll() {
        guard !isLoadingMe else { return }
        isLoadingMe = true
        loadingView.startAnimating()
        loadingView.isHidden = false
        failureWrap.isHidden = true
        loginWrap.isHidden = true
        contentWrap.isHidden = true
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoadingMe = false
                self.loadingView.stopAnimating()
                self.loadingView.isHidden = true
                switch result {
                case .success(let user):
                    guard let userValue = user else {
                        self.loginWrap.isHidden = false
                        return
                    }
                    self.meUser = userValue
                    self.contentWrap.isHidden = false
                    self.fillIdCard(user: userValue)
                    self.fillAccountRows(user: userValue)
                    // 注销入口：只用 /me 下发的 is_admin（服务端算出），客户端不写 id 判定；
                    // 服务端 403 admin_cannot_delete 仍是最终判定（见 delete 失败映射）。
                    self.deleteRow.isHidden = userValue.isAdmin == true
                    self.loadPlusDetail()
                    self.loadSessions()
                case .failure(let error):
                    if case .cancelled = error {
                        return
                    }
                    self.failureWrap.isHidden = false
                }
            }
        }
    }

    private func fillIdCard(user: MeUser) {
        let name = user.displayName ?? ""
        let emailPrefix = (user.email ?? "").components(separatedBy: "@").first ?? ""
        let displayName = !name.isEmpty ? name : (!emailPrefix.isEmpty ? emailPrefix : "–")
        heroNameLabel.text = "你好，" + displayName
        heroEmailLabel.text = user.email ?? "–"
        avatarInitialLabel.text = String(displayName.prefix(1))
        avatarImageView.image = nil
        if let avatar = user.avatar, !avatar.isEmpty, !avatar.hasPrefix("data:") {
            avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(avatar))
        }
        idCreatedLabel.text = BearyAccountText.dateString(ms: user.createdAt)
        // ID 卡会员行：用 /me 字段（网页 profilePlus 口径），不走 plus-detail。
        var plusText = "普通用户"
        if user.plus == true {
            plusText = "Plus 会员"
            if let until = user.plusUntil, until >= BearyAccountText.permanentThreshold {
                plusText += " · 永久"
            } else if let until = user.plusUntil, until > 0 {
                plusText += " · 至 " + BearyAccountText.dateString(ms: until)
            }
            if user.plusFree == true { plusText += "（内测限免）" }
        }
        idPlusLabel.text = plusText
        // ID 行：现行 /me 无 serial_id 时不编造；有则优先显示，否则 @handle，再无则数字 id。
        if let serial = user.serialId, !serial.isEmpty {
            idValueLabel.text = serial
        } else if let handle = user.handle, !handle.isEmpty {
            idValueLabel.text = "@" + handle
        } else if let userId = user.id {
            idValueLabel.text = "ID \(userId)"
        } else {
            idValueLabel.text = "–"
        }
    }

    private func fillAccountRows(user: MeUser) {
        let name = user.displayName ?? ""
        accountNameLabel.text = !name.isEmpty ? name : "–"
        if let handle = user.handle, !handle.isEmpty {
            accountHandleLabel.text = "@" + handle
        } else {
            accountHandleLabel.text = "未设置"
        }
        accountEmailLabel.text = user.email ?? "–"
        accountCreatedLabel.text = BearyAccountText.dateTimeString(ms: user.createdAt)
    }

    private func loadPlusDetail() {
        plusStatusLabel.text = "–"
        plusFreeLabel.text = "–"
        plusPersonalLabel.text = "–"
        rebuildGrants(grants: nil, failed: false)
        BearyAPI.shared.fetchPlusDetail { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let detail):
                    self.plusDetail = detail
                    self.fillPlusDetail(detail: detail)
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                        return
                    }
                    if case .cancelled = error { return }
                    self.plusStatusLabel.text = "加载失败"
                    self.rebuildGrants(grants: nil, failed: true)
                }
            }
        }
    }

    private func fillPlusDetail(detail: BearyPlusDetailResponse) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let permanent = detail.permanent == true
        let effective = detail.effectiveUntil ?? 0
        if permanent {
            plusStatusLabel.text = "Plus 会员 · 永久"
        } else if effective > now {
            plusStatusLabel.text = "Plus 会员 · 至 " + BearyAccountText.dateString(ms: effective)
        } else {
            plusStatusLabel.text = "普通用户"
        }
        let freeUntil = detail.freeUntil ?? 0
        if freeUntil > 0 {
            plusFreeRow.isHidden = false
            if freeUntil > now {
                plusFreeLabel.text = "全体内测用户免费 · 至 " + BearyAccountText.dateString(ms: freeUntil)
            } else {
                plusFreeLabel.text = "已结束 · " + BearyAccountText.dateString(ms: freeUntil) + " 到期"
            }
        } else {
            // 网页口径：free_until 为 0 时整行隐藏。
            plusFreeRow.isHidden = true
        }
        let personal = detail.personalUntil ?? 0
        if permanent {
            plusPersonalLabel.text = "永久会员"
        } else if personal > now {
            var text = "至 " + BearyAccountText.dateString(ms: personal)
            if freeUntil > 0 && personal > freeUntil {
                let days = (personal - freeUntil) / 86400000
                text += " · 限免结束后保留 \(days) 天"
            } else if freeUntil > now {
                text += " · 与限免期重叠"
            }
            plusPersonalLabel.text = text
        } else {
            plusPersonalLabel.text = "暂无（好友注册并绑定邀请码，双方各得 +30 天）"
        }
        rebuildGrants(grants: detail.grants, failed: false)
    }

    private func rebuildGrants(grants: [BearyPlusGrant]?, failed: Bool) {
        for view in grantsStack.arrangedSubviews {
            grantsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let titleLabelValue = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        titleLabelValue.text = "来源明细"
        grantsStack.addArrangedSubview(titleLabelValue)
        if failed {
            let failedLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            failedLabel.text = "加载失败"
            grantsStack.addArrangedSubview(failedLabel)
            return
        }
        guard let list = grants, !list.isEmpty else {
            let emptyLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            emptyLabel.text = "暂无发放记录"
            grantsStack.addArrangedSubview(emptyLabel)
            return
        }
        for grant in list {
            let nameLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
            nameLabel.text = BearyAccountText.grantSourceName(grant.source)
            let detailLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
            detailLabel.text = BearyAccountText.dateString(ms: grant.createdAt) + " · " + BearyAccountText.grantValueText(days: grant.days)
            let rowStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
            rowStack.axis = .vertical
            rowStack.spacing = 4
            grantsStack.addArrangedSubview(rowStack)
        }
    }

    private func loadSessions() {
        deviceCountLabel.text = "–"
        rebuildSessions(sessions: nil, failed: false)
        BearyAPI.shared.fetchAccountSessions { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    let list = resp.sessions ?? []
                    self.accountSessions = list
                    let count = resp.activeCount ?? list.count
                    self.deviceCountLabel.text = "共 \(count) 台设备"
                    self.rebuildSessions(sessions: list, failed: false)
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                        return
                    }
                    if case .cancelled = error { return }
                    self.rebuildSessions(sessions: nil, failed: true)
                }
            }
        }
    }

    private func rebuildSessions(sessions: [BearyAccountSession]?, failed: Bool) {
        for view in sessionsStack.arrangedSubviews {
            sessionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if failed {
            let failedLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            failedLabel.text = "加载失败，点“刷新”重试"
            sessionsStack.addArrangedSubview(failedLabel)
            return
        }
        guard let list = sessions, !list.isEmpty else {
            let emptyLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            emptyLabel.text = "暂无登录设备"
            sessionsStack.addArrangedSubview(emptyLabel)
            return
        }
        for session in list {
            let devLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
            devLabel.text = BearyAccountText.deviceName(session: session)
            var lineParts: [UIView] = [devLabel]
            if session.isCurrent == true {
                let curLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.orange)
                curLabel.text = "当前"
                lineParts.append(curLabel)
            }
            let lineRow = UIStackView(arrangedSubviews: lineParts)
            lineRow.axis = .horizontal
            lineRow.spacing = 8
            lineRow.alignment = .center
            let region = (session.region ?? "").isEmpty ? "未知地区" : (session.region ?? "")
            var meta = region + " · 上次活跃 " + BearyAccountText.dateTimeString(ms: session.lastActive)
            if session.expired == true { meta += " · 已过期" }
            let metaLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
            metaLabel.text = meta
            let rowStack = UIStackView(arrangedSubviews: [lineRow, metaLabel])
            rowStack.axis = .vertical
            rowStack.spacing = 4
            if session.expired == true { rowStack.alpha = 0.55 }
            sessionsStack.addArrangedSubview(rowStack)
        }
    }

    // MARK: - 退出其他设备

    @objc private func logoutOthersButtonTapped() {
        guard !isLoggingOutOthers else { return }
        let alert = UIAlertController(title: "退出其他设备", message: "将退出除当前设备外的所有登录，确定继续？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive, handler: { [weak self] _ in
            self?.confirmLogoutOthers()
        }))
        present(alert, animated: true)
    }

    private func confirmLogoutOthers() {
        isLoggingOutOthers = true
        BearyAPI.shared.revokeOtherSessions { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoggingOutOthers = false
                switch result {
                case .success:
                    self.showToast("已退出其他设备")
                    self.loadSessions()
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                        return
                    }
                    if case .cancelled = error { return }
                    self.showToast("操作失败，请重试")
                }
            }
        }
    }

    // MARK: - 注销账户（网页两步确认 + 7 天冷静期口径）

    @objc private func deleteButtonTapped() {
        guard !isDeleting else { return }
        let first = UIAlertController(
            title: "注销账户",
            message: "7 天冷静期内登录可取消注销。7 天后账户正式注销，日记保留但作者显示为“已注销用户”。\n\n注销后，你的 Plus、未到账的邀请奖励、BETA 徽章和收藏会一并作废。",
            preferredStyle: .alert
        )
        first.addAction(UIAlertAction(title: "再想想", style: .cancel, handler: nil))
        first.addAction(UIAlertAction(title: "继续注销", style: .destructive, handler: { [weak self] _ in
            self?.showDeleteSecondConfirm()
        }))
        present(first, animated: true)
    }

    private func showDeleteSecondConfirm() {
        let second = UIAlertController(title: "最后确认", message: "真的要注销吗？此操作 7 天后不可撤销。", preferredStyle: .alert)
        second.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        second.addAction(UIAlertAction(title: "确认注销", style: .destructive, handler: { [weak self] _ in
            self?.confirmDeleteAccount()
        }))
        present(second, animated: true)
    }

    private func confirmDeleteAccount() {
        isDeleting = true
        BearyAPI.shared.requestAccountDelete { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDeleting = false
                switch result {
                case .success:
                    // 网页口径：提示后 1.2 秒回首页；原生等价为提示后走 onAccountDeleted（容器清态并关闭本页）。
                    self.showToast("已提交注销申请，7 天后正式注销")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.onAccountDeleted?()
                    }
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                        return
                    }
                    if case .cancelled = error { return }
                    if case .server(let code) = error, code == "admin_cannot_delete" {
                        self.showToast("管理员账号不能注销")
                        return
                    }
                    self.showToast("注销失败，请重试")
                }
            }
        }
    }

    // MARK: - 导出我的数据（客户端拼 JSON，不新编服务端接口）

    @objc private func exportButtonTapped() {
        guard !isExporting else { return }
        isExporting = true
        exportRowButton.isEnabled = false
        showToast("正在导出…")
        BearyAPI.shared.fetchMe { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let user):
                guard let userValue = user else {
                    DispatchQueue.main.async {
                        self.finishExportFailed()
                        self.onRequireLogin?()
                    }
                    return
                }
                self.exportWithUser(userValue)
            case .failure(let error):
                DispatchQueue.main.async {
                    self.finishExportFailed()
                    if case .unauthorized = error { self.onRequireLogin?() }
                }
            }
        }
    }

    private func finishExportFailed() {
        isExporting = false
        exportRowButton.isEnabled = true
        showToast("导出失败，请重试")
    }

    private func exportWithUser(_ user: MeUser) {
        let group = DispatchGroup()
        var sessionsResp: BearyAccountSessionsResponse?
        var mineEntries: [Entry] = []
        var mailboxEntries: [Entry] = []
        var likedEntries: [Entry] = []
        group.enter()
        BearyAPI.shared.fetchAccountSessions { result in
            if case .success(let resp) = result { sessionsResp = resp }
            group.leave()
        }
        let scopes: [(BearyAPI.Scope, ( [Entry]) -> Void)] = [
            (.mine, { mineEntries = $0 }),
            (.mailbox, { mailboxEntries = $0 }),
            (.liked, { likedEntries = $0 }),
        ]
        for item in scopes {
            group.enter()
            fetchAllEntries(scope: item.0) { entries in
                item.1(entries)
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isExporting = false
            self.exportRowButton.isEnabled = true
            var data: [String: Any] = [:]
            data["exported_at"] = ISO8601DateFormatter().string(from: Date())
            data["site"] = "teddyhn.com"
            data["profile"] = self.exportProfileDict(user: user)
            if let resp = sessionsResp, let list = resp.sessions {
                data["sessions"] = list.map { self.exportSessionDict(session: $0) }
            }
            data["diaries"] = mineEntries.map { self.exportEntryDict(entry: $0, isPrivate: false) } +
                mailboxEntries.map { self.exportEntryDict(entry: $0, isPrivate: true) }
            data["liked_entries"] = likedEntries.map { self.exportEntryDict(entry: $0, isPrivate: false) }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else {
                self.showToast("导出失败，请重试")
                return
            }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            let fileName = "teddyhn-data-" + fmt.string(from: Date()) + ".json"
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            var text = "\u{feff}"
            text += String(data: jsonData, encoding: .utf8) ?? ""
            guard let fileData = text.data(using: .utf8), (try? fileData.write(to: fileURL)) != nil else {
                self.showToast("导出失败，请重试")
                return
            }
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let pop = activity.popoverPresentationController {
                pop.sourceView = self.exportRowButton
                pop.sourceRect = self.exportRowButton.bounds
            }
            activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                if completed { self?.showToast("导出完成") }
            }
            self.present(activity, animated: true)
        }
    }

    /// 分页拉全一个 scope：limit=50、guard 20 页（网页 fetchAll 同口径），
    /// 游标 before + before_id（App fetchEntries 既有口径，服务端 created_at DESC, id DESC）。
    private func fetchAllEntries(scope: BearyAPI.Scope, completion: @escaping ([Entry]) -> Void) {
        fetchScopePage(scope: scope, before: nil, beforeId: nil, accumulated: [], depth: 0, completion: completion)
    }

    private func fetchScopePage(scope: BearyAPI.Scope, before: Int?, beforeId: String?, accumulated: [Entry], depth: Int, completion: @escaping ([Entry]) -> Void) {
        if depth >= 20 {
            completion(accumulated)
            return
        }
        BearyAPI.shared.fetchEntries(scope: scope, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else {
                completion(accumulated)
                return
            }
            switch result {
            case .success(let list):
                let entries = list.entries ?? []
                let all = accumulated + entries
                if entries.count < 50 {
                    completion(all)
                    return
                }
                guard let last = entries.last, let lastCreated = last.createdAt else {
                    completion(all)
                    return
                }
                self.fetchScopePage(scope: scope, before: lastCreated, beforeId: last.id, accumulated: all, depth: depth + 1, completion: completion)
            case .failure:
                completion(accumulated)
            }
        }
    }

    private func exportProfileDict(user: MeUser) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let value = user.id { dict["id"] = value }
        if let value = user.email { dict["email"] = value }
        if let value = user.displayName { dict["display_name"] = value }
        if let value = user.handle { dict["handle"] = value }
        if let avatar = user.avatar {
            // 网页口径：data: 头像只留 [avatar] 标记，不把 base64 体积带进导出文件。
            dict["avatar"] = avatar.hasPrefix("data:") ? "[avatar]" : avatar
        }
        if let value = user.coverVer { dict["cover_ver"] = value }
        if let value = user.createdAt { dict["created_at"] = value }
        if let value = user.plus { dict["plus"] = value }
        if let value = user.plusUntil { dict["plus_until"] = value }
        if let value = user.plusFree { dict["plus_free"] = value }
        if let value = user.inviteCode { dict["invite_code"] = value }
        if let ref = user.referral {
            var refDict: [String: Any] = [:]
            if let value = ref.bound { refDict["bound"] = value }
            if let value = ref.bindOpen { refDict["bind_open"] = value }
            if let value = ref.bindDeadline { refDict["bind_deadline"] = value }
            if let value = ref.invitedCount { refDict["invited_count"] = value }
            if let value = ref.rewardMonths { refDict["reward_months"] = value }
            if let value = ref.enabled { refDict["enabled"] = value }
            if let value = ref.inviterName { refDict["inviter_name"] = value }
            if let value = ref.status { refDict["status"] = value }
            if let value = ref.boundAt { refDict["bound_at"] = value }
            dict["referral"] = refDict
        }
        return dict
    }

    private func exportSessionDict(session: BearyAccountSession) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let value = session.sessionIdValue { dict["id"] = value }
        if let value = session.isCurrent { dict["is_current"] = value }
        if let value = session.createdAt { dict["created_at"] = value }
        if let value = session.expiresAt { dict["expires_at"] = value }
        if let value = session.expired { dict["expired"] = value }
        if let value = session.ua { dict["ua"] = value }
        if let value = session.device { dict["device"] = value }
        if let value = session.ip { dict["ip"] = value }
        if let value = session.region { dict["region"] = value }
        if let value = session.lastActive { dict["last_active"] = value }
        return dict
    }

    private func exportEntryDict(entry: Entry, isPrivate: Bool) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let value = entry.id { dict["id"] = value }
        if let value = entry.authorId { dict["author_id"] = value }
        if let value = entry.authorName { dict["author_name"] = value }
        if let avatar = entry.authorAvatar {
            dict["author_avatar"] = avatar.hasPrefix("data:") ? "[avatar]" : avatar
        }
        if let value = entry.content { dict["content"] = value }
        if let images = entry.images {
            dict["images"] = images.map { key in
                let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
                return BearyImageURLs.base + "/beary/api/images/" + encoded
            }
        }
        if let value = entry.mood { dict["mood"] = value }
        if let value = entry.weather { dict["weather"] = value }
        if let value = BearyAccountText.isoString(ms: entry.createdAt) { dict["created_at"] = value }
        if let value = BearyAccountText.isoString(ms: entry.publishAt) { dict["publish_at"] = value }
        if let value = BearyAccountText.isoString(ms: entry.editDeadline) { dict["edit_deadline"] = value }
        if let value = entry.isPublic { dict["is_public"] = value }
        if let value = entry.likeCount { dict["like_count"] = value }
        if let value = entry.likedByMe { dict["liked_by_me"] = value }
        if let value = entry.bookmarkedByMe { dict["bookmarked_by_me"] = value }
        if let emotes = entry.emotes {
            dict["emotes"] = emotes.map { item -> [String: Any] in
                var emoteDict: [String: Any] = [:]
                if let value = item.emote { emoteDict["emote"] = value }
                if let value = item.count { emoteDict["count"] = value }
                if let value = item.mine { emoteDict["mine"] = value }
                return emoteDict
            }
        }
        dict["is_private"] = isPrivate
        return dict
    }

    // MARK: - 轻提示（Trash 同款：ink 底白字，1.6 秒淡出）

    private func showToast(_ text: String) {
        toastTimer?.invalidate()
        toastLabel.text = text
        toastWrap.alpha = 0
        UIView.animate(withDuration: 0.2, animations: {
            self.toastWrap.alpha = 1
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            self.toastTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false, block: { [weak self] _ in
                UIView.animate(withDuration: 0.3, animations: {
                    self?.toastWrap.alpha = 0
                }, completion: nil)
            })
        })
    }
}
