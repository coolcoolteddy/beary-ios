// ===== beary 设置页（2026-10-26：原独立账户页整体迁移为本页「账号与安全」分区；
// 齿轮菜单与头像菜单的“账户设置”入口均改开本页，旧 BearyAccountViewController 已删除，
// 不留两个入口、不留死代码页）=====
// 四分区：账号与安全（原账户页全量：ID 卡、Plus 明细、登录设备、退出其他设备、
// 退出登录、邮箱验证码登录行、注销、导出我的数据）、消息与通知、通用、隐私。
// 新增行一律真实能力：消息角标开关（本地 UserDefaults 门控底栏角标）、系统通知设置入口
// （打开 iOS 设置）、外观主题三选（复用 beary_theme_mode 存档键）、版本行（Bundle 实值）、
// 隐私政策 / 用户协议（App 内原生文字页，文本取自 teddyhn.com 现行 privacy/terms，不开网页）。
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

final class BearySettingsViewController: UIViewController {

    /// 点关闭钮：容器接线到关闭本页（本页不自己 dismiss）。
    var onClose: (() -> Void)?
    /// 未登录 / 会话失效：容器接线到登录页。
    var onRequireLogin: (() -> Void)?
    /// 注销发起成功且用户已看到“7 天后正式注销”提示后：容器接线到清 cookie、
    /// 本地退出并关闭本页（服务端在注销发起时已清全部会话）。
    var onAccountDeleted: (() -> Void)?
    /// F6/F12：编辑资料 / 退出登录的容器回调；容器未接线时页内以模态兜底
    /// （编辑页、退出后关闭本页），容器后续接线后走容器路径。
    var onEditProfile: (() -> Void)?
    var onLoggedOut: (() -> Void)?

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
    /// 设置页新增三区容器：登录态无关（主题/隐私/通知开关本地可用），
    /// 故不随 contentWrap 一起在未登录/加载失败时隐藏，恒可见。
    private let settingsExtraWrap = UIStackView()

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
    /// F4：内测限免行的分组卡包容器（藏行须藏包容器，否则内边距仍占位）。
    private var plusFreeWrapper: UIView?
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
    private var deleteRowWrapper: UIView?
    private let logoutRowButton = UIButton(type: .custom)
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
            for card in cardViews {
                card.layer.borderColor = BearyColors.line.cgColor
            }
            logoutOthersButton.layer.borderColor = BearyColors.alpha(BearyColors.red, 0.45).cgColor
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

    /// F4：组标题改走网页 group-title 口径——12px 灰、放卡内（不再是卡外 14 粗体）。
    /// 字距 1px（网页 letter-spacing:1px）用 kern 复现。
    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray)
        label.attributedText = NSAttributedString(string: text, attributes: [.kern: 1])
        return label
    }

    /// F3：行图标容器（网页 row-icon 口径：36 圆角 12、底色取页面 bg、内 18 灰 svg）。
    /// 图标一律走 BearyIconImages（官方 sprite 渲染的黑色描边 PNG + alwaysTemplate），
    /// 不用 SF Symbol；iconName 为 nil 的行（网页本身无图标的 Plus/ID 卡行）不补图标。
    private func makeRowIcon(_ iconName: String) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = BearyColors.bg
        container.layer.cornerRadius = 12
        container.clipsToBounds = true
        let imageViewValue = UIImageView()
        imageViewValue.translatesAutoresizingMaskIntoConstraints = false
        imageViewValue.image = BearyIconImages.image(named: iconName, pointSize: 18)
        imageViewValue.tintColor = BearyColors.gray
        imageViewValue.contentMode = .scaleAspectFit
        container.addSubview(imageViewValue)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 36),
            container.heightAnchor.constraint(equalToConstant: 36),
            imageViewValue.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageViewValue.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageViewValue.widthAnchor.constraint(equalToConstant: 18),
            imageViewValue.heightAnchor.constraint(equalToConstant: 18),
        ])
        return container
    }

    private func makeRow(title: String, detailLabel: UILabel, iconName: String? = nil) -> UIView {
        let titleLabelValue = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        titleLabelValue.text = title
        titleLabelValue.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabel.textAlignment = .right
        var parts: [UIView] = []
        if let icon = iconName {
            parts.append(makeRowIcon(icon))
        }
        parts.append(titleLabelValue)
        parts.append(detailLabel)
        let row = UIStackView(arrangedSubviews: parts)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    /// F8/F11：网页 row-text 两行式（标题 15 + 副文 12 灰，左对齐），用于
    /// 「邮箱验证码登录」「登录设备」两行（网页 account.html 安全组同款）。
    private func makeInfoRow(title: String, detailLabel: UILabel, iconName: String) -> UIView {
        let titleLabelValue = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        titleLabelValue.text = title
        detailLabel.font = UIFont.systemFont(ofSize: 12)
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .left
        let textStack = UIStackView(arrangedSubviews: [titleLabelValue, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill
        let row = UIStackView(arrangedSubviews: [makeRowIcon(iconName), textStack])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    /// 深浅切换时需重刷描边的卡片（CGColor 赋值时解析一次，不自动跟随）。
    private var cardViews: [UIView] = []

    private func makeCardView() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.surface
        card.layer.borderWidth = 1
        card.layer.borderColor = BearyColors.line.cgColor
        card.layer.cornerRadius = 20
        card.clipsToBounds = true
        cardViews.append(card)
        return card
    }

    private func makeCard(_ inner: UIStackView) -> UIView {
        let card = makeCardView()
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

    /// F4：分组卡（网页 .group 口径）：标题在卡内、卡为 card 底 + 1px 边框 +
    /// 圆角 20、行间 1px 分隔线（分隔线通宽，行内容左右 16、上下 14）。
    /// 返回卡片与每行的包容器（包容器用于显隐整行：隐藏行本身仍会留 28pt 内边距，
    /// 故 Plus「内测限免」行须改藏包容器，见 fillPlusDetail）。
    private func makeGroupCard(title: String?, rows: [UIView]) -> (card: UIView, wrappers: [UIView]) {
        let card = makeCardView()
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .fill
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        if let titleText = title {
            let titleLabelValue = makeSectionTitle(titleText)
            titleLabelValue.translatesAutoresizingMaskIntoConstraints = false
            let titleWrap = UIView()
            titleWrap.translatesAutoresizingMaskIntoConstraints = false
            titleWrap.addSubview(titleLabelValue)
            NSLayoutConstraint.activate([
                titleLabelValue.topAnchor.constraint(equalTo: titleWrap.topAnchor, constant: 16),
                titleLabelValue.leadingAnchor.constraint(equalTo: titleWrap.leadingAnchor, constant: 16),
                titleLabelValue.trailingAnchor.constraint(equalTo: titleWrap.trailingAnchor, constant: -16),
                titleLabelValue.bottomAnchor.constraint(equalTo: titleWrap.bottomAnchor, constant: -8),
            ])
            stack.addArrangedSubview(titleWrap)
        }
        var wrappers: [UIView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                NSLayoutConstraint.activate([
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
                stack.addArrangedSubview(separator)
            }
            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 14),
                row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
                row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -14),
            ])
            stack.addArrangedSubview(wrap)
            wrappers.append(wrap)
        }
        return (card, wrappers)
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
        closeButton.bearyAddPressFeedback()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "设置"

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
        retryButton.bearyAddPressFeedback()
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
        loginButton.bearyAddPressFeedback()
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

        contentWrap.addArrangedSubview(makeSectionTitle("账号与安全"))
        buildIdCard()
        buildPlusSection()
        buildAccountSection()
        buildSecuritySection()
        buildActionsSection()

        settingsExtraWrap.translatesAutoresizingMaskIntoConstraints = false
        settingsExtraWrap.axis = .vertical
        settingsExtraWrap.spacing = 20
        settingsExtraWrap.alignment = .fill
        buildNotificationSection()
        buildGeneralSection()
        buildPrivacySection()

        contentStack.addArrangedSubview(loadingView)
        contentStack.addArrangedSubview(failureWrap)
        contentStack.addArrangedSubview(loginWrap)
        contentStack.addArrangedSubview(contentWrap)
        contentStack.addArrangedSubview(settingsExtraWrap)

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
            toastWrap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -158),
            toastLabel.topAnchor.constraint(equalTo: toastWrap.topAnchor, constant: 10),
            toastLabel.leadingAnchor.constraint(equalTo: toastWrap.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastWrap.trailingAnchor, constant: -14),
            toastLabel.bottomAnchor.constraint(equalTo: toastWrap.bottomAnchor, constant: -10),
        ])
    }

    private func buildIdCard() {
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.backgroundColor = BearyColors.faint
        avatarContainer.layer.cornerRadius = 32
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
            avatarContainer.widthAnchor.constraint(equalToConstant: 64),
            avatarContainer.heightAnchor.constraint(equalToConstant: 64),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
        ])
        heroNameLabel.font = UIFont.systemFont(ofSize: 24, weight: .heavy)
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
        // F5：ID 值 mono 15/700 + 字距 2（网页 id-val 口径）；ID 标签 mono 10 + 字距 3。
        idValueLabel.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        idValueLabel.textColor = BearyColors.ink
        idValueLabel.numberOfLines = 0
        idValueLabel.lineBreakMode = .byCharWrapping
        let idTitleLabel = makeLabel(font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular), color: BearyColors.gray)
        idTitleLabel.attributedText = NSAttributedString(string: "ID", attributes: [.kern: 3])
        let idRow = UIStackView(arrangedSubviews: [idTitleLabel, idValueLabel])
        idRow.axis = .horizontal
        idRow.spacing = 12
        idRow.alignment = .center

        let createdRow = makeRow(title: "注册时间", detailLabel: idCreatedLabel)
        let plusRow = makeRow(title: "会员", detailLabel: idPlusLabel)
        // F5：ID 区顶边线（网页 id-badge border-top 口径：线上 18、线下 18）。
        let idSeparator = UIView()
        idSeparator.translatesAutoresizingMaskIntoConstraints = false
        idSeparator.backgroundColor = BearyColors.line
        NSLayoutConstraint.activate([
            idSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
        let cardStack = makeCardStack(spacing: 12)
        cardStack.addArrangedSubview(heroRow)
        cardStack.addArrangedSubview(createdRow)
        cardStack.addArrangedSubview(plusRow)
        cardStack.addArrangedSubview(idSeparator)
        cardStack.addArrangedSubview(idRow)
        cardStack.setCustomSpacing(18, after: plusRow)
        cardStack.setCustomSpacing(18, after: idSeparator)
        let idCard = makeCard(cardStack)
        // F5：熊头水印（网页 idcard watermark 口径：account.html 官方熊头描边、
        // 右 -150 / 上 -80、400×420、ink 5% 透明；卡片 overflow:hidden 裁剪）。
        if let watermarkImage = UIImage(named: "bear_watermark")?.withRenderingMode(.alwaysTemplate) {
            let watermarkView = UIImageView(image: watermarkImage)
            watermarkView.translatesAutoresizingMaskIntoConstraints = false
            watermarkView.tintColor = BearyColors.ink
            watermarkView.alpha = 0.05
            watermarkView.contentMode = .scaleAspectFit
            idCard.insertSubview(watermarkView, at: 0)
            NSLayoutConstraint.activate([
                watermarkView.widthAnchor.constraint(equalToConstant: 400),
                watermarkView.heightAnchor.constraint(equalToConstant: 420),
                watermarkView.trailingAnchor.constraint(equalTo: idCard.trailingAnchor, constant: 150),
                watermarkView.topAnchor.constraint(equalTo: idCard.topAnchor, constant: -80),
            ])
        }
        contentWrap.addArrangedSubview(idCard)
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
        plusFreeRow = makeRow(title: "内测限免", detailLabel: plusFreeLabel)
        // F4：标题入卡内（网页 Plus 会员 group-title 口径）；Plus 组网页行本身无图标，不补。
        let plusGroup = makeGroupCard(title: "Plus 会员", rows: [
            makeRow(title: "当前状态", detailLabel: plusStatusLabel),
            plusFreeRow,
            makeRow(title: "专属会员", detailLabel: plusPersonalLabel),
            grantsStack,
        ])
        if plusGroup.wrappers.count > 1 {
            plusFreeWrapper = plusGroup.wrappers[1]
        }
        contentWrap.addArrangedSubview(plusGroup.card)
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
        copyHandleButton.bearyAddPressFeedback()
        accountEmailLabel.font = UIFont.systemFont(ofSize: 14)
        accountEmailLabel.textColor = BearyColors.gray
        accountEmailLabel.numberOfLines = 0
        accountEmailLabel.textAlignment = .right
        accountCreatedLabel.font = UIFont.systemFont(ofSize: 14)
        accountCreatedLabel.textColor = BearyColors.gray
        accountCreatedLabel.numberOfLines = 0
        accountCreatedLabel.textAlignment = .right
        // F7：已验证改网页 badge-ok 口径——11/600 绿 pill（绿 12% 底、内边距 4/10、圆角 20）。
        let verifiedLabel = makeLabel(font: UIFont.systemFont(ofSize: 11, weight: .semibold), color: BearyColors.green)
        verifiedLabel.text = "已验证"
        let verifiedPill = UIView()
        verifiedPill.translatesAutoresizingMaskIntoConstraints = false
        verifiedPill.backgroundColor = BearyColors.alpha(BearyColors.green, 0.12)
        verifiedPill.layer.cornerRadius = 20
        verifiedPill.clipsToBounds = true
        verifiedLabel.translatesAutoresizingMaskIntoConstraints = false
        verifiedPill.addSubview(verifiedLabel)
        NSLayoutConstraint.activate([
            verifiedLabel.topAnchor.constraint(equalTo: verifiedPill.topAnchor, constant: 4),
            verifiedLabel.leadingAnchor.constraint(equalTo: verifiedPill.leadingAnchor, constant: 10),
            verifiedLabel.trailingAnchor.constraint(equalTo: verifiedPill.trailingAnchor, constant: -10),
            verifiedLabel.bottomAnchor.constraint(equalTo: verifiedPill.bottomAnchor, constant: -4),
        ])
        let emailRow = makeRow(title: "邮箱", detailLabel: accountEmailLabel, iconName: "icon_mail")
        if let stack = emailRow as? UIStackView {
            stack.addArrangedSubview(verifiedPill)
        }
        let handleRow = makeRow(title: "用户名", detailLabel: accountHandleLabel, iconName: "icon_link")
        if let stack = handleRow as? UIStackView {
            stack.addArrangedSubview(copyHandleButton)
            stack.addArrangedSubview(makeAccountActionButton(title: "修改", action: #selector(editHandleButtonTapped)))
        }
        // F6：显示名称行补「编辑」钮（与用户名行「修改」同款，接现有编辑资料入口）。
        let nameRow = makeRow(title: "显示名称", detailLabel: accountNameLabel, iconName: "icon_user")
        if let stack = nameRow as? UIStackView {
            stack.addArrangedSubview(makeAccountActionButton(title: "编辑", action: #selector(editNameButtonTapped)))
        }
        let createdRow = makeRow(title: "注册时间", detailLabel: accountCreatedLabel, iconName: "icon_clock")
        let accountGroup = makeGroupCard(title: "账户", rows: [nameRow, handleRow, emailRow, createdRow])
        contentWrap.addArrangedSubview(accountGroup.card)
    }

    /// 账户组行末文字钮（复制 / 编辑 / 修改同款：14 墨字，与网页 .btn 区分——
    /// 网页 .btn 为 36 高边框钮，App 本页行末既有用文字钮，沿用它不另起样式）。
    private func makeAccountActionButton(title: String, action: Selector) -> UIButton {
        let buttonValue = UIButton(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle(title, for: .normal)
        buttonValue.setTitleColor(BearyColors.ink, for: .normal)
        buttonValue.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        buttonValue.addTarget(self, action: action, for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }

    private func buildSecuritySection() {
        // F8/F11：设备不再单立「组头 + 刷新」分组，改为安全组内一行（网页
        // account.html 安全组口径：邮箱验证码登录行、登录设备行、会话列表、
        // 退出其他设备钮同卡；刷新钮随组头一并取消，失败态改行内重试钮）。
        let codeLoginDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        codeLoginDetail.text = "每次登录发送 6 位验证码，无需密码"
        let codeLoginRow = makeInfoRow(title: "邮箱验证码登录", detailLabel: codeLoginDetail, iconName: "icon_lock")
        deviceCountLabel.font = UIFont.systemFont(ofSize: 12)
        deviceCountLabel.textColor = BearyColors.gray
        deviceCountLabel.numberOfLines = 0
        deviceCountLabel.textAlignment = .left
        let deviceRow = makeInfoRow(title: "登录设备", detailLabel: deviceCountLabel, iconName: "icon_device")
        sessionsStack.axis = .vertical
        sessionsStack.spacing = 12
        sessionsStack.alignment = .fill
        logoutOthersButton.translatesAutoresizingMaskIntoConstraints = false
        logoutOthersButton.setTitle("退出其他设备", for: .normal)
        logoutOthersButton.setTitleColor(BearyColors.red, for: .normal)
        // F10：网页 .btn.danger 口径——36 高、13/600、红字红边（红 45% 透明边）。
        logoutOthersButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        logoutOthersButton.layer.borderWidth = 1
        logoutOthersButton.layer.borderColor = BearyColors.alpha(BearyColors.red, 0.45).cgColor
        logoutOthersButton.layer.cornerRadius = 12
        logoutOthersButton.addTarget(self, action: #selector(logoutOthersButtonTapped), for: .touchUpInside)
        logoutOthersButton.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            logoutOthersButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        let securityGroup = makeGroupCard(title: "安全", rows: [
            codeLoginRow,
            deviceRow,
            sessionsStack,
            logoutOthersButton,
        ])
        contentWrap.addArrangedSubview(securityGroup.card)
    }

    private func buildActionsSection() {
        // S9：动作卡补组标题「账户操作」（覆盖 F8 无标题口径），
        // 顺序与网页一致（退出登录在前）。
        let logoutTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.red)
        logoutTitle.text = "退出登录"
        let logoutRow = UIStackView(arrangedSubviews: [makeRowIcon("icon_logout"), logoutTitle])
        logoutRow.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.axis = .horizontal
        logoutRow.spacing = 12
        logoutRow.alignment = .center
        logoutRowButton.translatesAutoresizingMaskIntoConstraints = false
        logoutRowButton.addTarget(self, action: #selector(logoutButtonTapped), for: .touchUpInside)
        logoutRowButton.bearyAddPressHaptic()
        let logoutRowWrap = UIView()
        logoutRowWrap.translatesAutoresizingMaskIntoConstraints = false
        logoutRowWrap.addSubview(logoutRow)
        logoutRowWrap.addSubview(logoutRowButton)
        logoutRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logoutRow.topAnchor.constraint(equalTo: logoutRowWrap.topAnchor),
            logoutRow.leadingAnchor.constraint(equalTo: logoutRowWrap.leadingAnchor),
            logoutRow.trailingAnchor.constraint(equalTo: logoutRowWrap.trailingAnchor),
            logoutRow.bottomAnchor.constraint(equalTo: logoutRowWrap.bottomAnchor),
            logoutRowButton.topAnchor.constraint(equalTo: logoutRowWrap.topAnchor),
            logoutRowButton.leadingAnchor.constraint(equalTo: logoutRowWrap.leadingAnchor),
            logoutRowButton.trailingAnchor.constraint(equalTo: logoutRowWrap.trailingAnchor),
            logoutRowButton.bottomAnchor.constraint(equalTo: logoutRowWrap.bottomAnchor),
        ])

        let exportTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        exportTitle.text = "导出我的数据"
        let exportDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        exportDetail.text = "下载 JSON，含账户、日记、点赞记录"
        let exportStack = UIStackView(arrangedSubviews: [exportTitle, exportDetail])
        exportStack.axis = .vertical
        exportStack.spacing = 4
        exportRowButton.translatesAutoresizingMaskIntoConstraints = false
        exportRowButton.addTarget(self, action: #selector(exportButtonTapped), for: .touchUpInside)
        exportRowButton.bearyAddPressHaptic()
        let exportRow = UIStackView(arrangedSubviews: [makeRowIcon("icon_download"), exportStack])
        exportRow.translatesAutoresizingMaskIntoConstraints = false
        exportRow.axis = .horizontal
        exportRow.spacing = 12
        exportRow.alignment = .center
        let exportRowWrap = UIView()
        exportRowWrap.translatesAutoresizingMaskIntoConstraints = false
        exportRowWrap.addSubview(exportRow)
        exportRowWrap.addSubview(exportRowButton)
        exportRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            exportRow.topAnchor.constraint(equalTo: exportRowWrap.topAnchor),
            exportRow.leadingAnchor.constraint(equalTo: exportRowWrap.leadingAnchor),
            exportRow.trailingAnchor.constraint(equalTo: exportRowWrap.trailingAnchor),
            exportRow.bottomAnchor.constraint(equalTo: exportRowWrap.bottomAnchor),
            exportRowButton.topAnchor.constraint(equalTo: exportRowWrap.topAnchor),
            exportRowButton.leadingAnchor.constraint(equalTo: exportRowWrap.leadingAnchor),
            exportRowButton.trailingAnchor.constraint(equalTo: exportRowWrap.trailingAnchor),
            exportRowButton.bottomAnchor.constraint(equalTo: exportRowWrap.bottomAnchor),
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
        deleteRowButton.bearyAddPressHaptic()
        deleteRow.translatesAutoresizingMaskIntoConstraints = false
        deleteStack.translatesAutoresizingMaskIntoConstraints = false
        let deleteRowContent = UIStackView(arrangedSubviews: [makeRowIcon("icon_trash"), deleteStack])
        deleteRowContent.translatesAutoresizingMaskIntoConstraints = false
        deleteRowContent.axis = .horizontal
        deleteRowContent.spacing = 12
        deleteRowContent.alignment = .center
        deleteRow.addSubview(deleteRowContent)
        deleteRow.addSubview(deleteRowButton)
        NSLayoutConstraint.activate([
            deleteRowContent.topAnchor.constraint(equalTo: deleteRow.topAnchor),
            deleteRowContent.leadingAnchor.constraint(equalTo: deleteRow.leadingAnchor),
            deleteRowContent.trailingAnchor.constraint(equalTo: deleteRow.trailingAnchor),
            deleteRowContent.bottomAnchor.constraint(equalTo: deleteRow.bottomAnchor),
            deleteRowButton.topAnchor.constraint(equalTo: deleteRow.topAnchor),
            deleteRowButton.leadingAnchor.constraint(equalTo: deleteRow.leadingAnchor),
            deleteRowButton.trailingAnchor.constraint(equalTo: deleteRow.trailingAnchor),
            deleteRowButton.bottomAnchor.constraint(equalTo: deleteRow.bottomAnchor),
        ])

        let actionsGroup = makeGroupCard(title: "账户操作", rows: [logoutRowWrap, exportRowWrap, deleteRow])
        if actionsGroup.wrappers.count > 2 {
            deleteRowWrapper = actionsGroup.wrappers[2]
        }
        contentWrap.addArrangedSubview(actionsGroup.card)

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

    @objc private func retrySessionsButtonTapped() {
        loadSessions()
    }

    @objc private func editNameButtonTapped() {
        openEditPage()
    }

    @objc private func editHandleButtonTapped() {
        openEditPage()
    }

    /// F6：编辑 / 修改均接现有编辑资料入口；容器接线时走容器，容器未接线时
    /// 页内模态兜底（保存后刷新本页、取消仅关闭、登录失效转本页登录回调）。
    private func openEditPage() {
        if let handler = onEditProfile {
            handler()
            return
        }
        guard let user = meUser else {
            onRequireLogin?()
            return
        }
        let coverUrl: String?
        if let id = user.id, let ver = user.coverVer, ver != 0 {
            coverUrl = BearyImageURLs.base + "/beary/api/users/\(id)/cover?v=\(ver)"
        } else {
            coverUrl = nil
        }
        let editVC = BearyEditProfileViewController(displayName: user.displayName, handle: user.handle, avatarUrl: user.avatar, coverUrl: coverUrl)
        editVC.modalPresentationStyle = .fullScreen
        editVC.onSaved = { [weak self, weak editVC] in
            editVC?.dismiss(animated: true) {
                self?.loadAll()
            }
        }
        editVC.onCancel = { [weak editVC] in
            editVC?.dismiss(animated: true)
        }
        editVC.onRequireLogin = { [weak self, weak editVC] in
            editVC?.dismiss(animated: true) {
                self?.onRequireLogin?()
            }
        }
        present(editVC, animated: true)
    }

    /// F8：退出登录（网页 account.html logoutBtn 口径：直接 POST、无二次确认；
    /// App 现有退出逻辑 = BearyAPI.logout + 清本地 cookie + 本地退出）。
    @objc private func logoutButtonTapped() {
        BearyAPI.shared.logout { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    SessionManager.shared.clearLocalCookies()
                    SessionManager.shared.signOutLocally()
                    if let handler = self.onLoggedOut {
                        handler()
                    } else {
                        self.onClose?()
                    }
                case .failure:
                    self.showToast("退出失败，请重试")
                }
            }
        }
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
                    // 藏行须连包容器一起藏，否则分组卡内边距仍占位。
                    self.deleteRow.isHidden = userValue.isAdmin == true
                    self.deleteRowWrapper?.isHidden = userValue.isAdmin == true
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
        // F5：网页 heroName 就是名字本身，不带「你好，」前缀。
        heroNameLabel.text = displayName
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
        // F5：字距 2（网页 id-val letter-spacing:2px）走 attributedText。
        let idText: String
        if let serial = user.serialId, !serial.isEmpty {
            idText = serial
        } else if let handle = user.handle, !handle.isEmpty {
            idText = "@" + handle
        } else if let userId = user.id {
            idText = "ID \(userId)"
        } else {
            idText = "–"
        }
        idValueLabel.attributedText = NSAttributedString(string: idText, attributes: [.kern: 2])
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
            plusFreeWrapper?.isHidden = false
            plusFreeRow.isHidden = false
            if freeUntil > now {
                plusFreeLabel.text = "全体内测用户免费 · 至 " + BearyAccountText.dateString(ms: freeUntil)
            } else {
                plusFreeLabel.text = "已结束 · " + BearyAccountText.dateString(ms: freeUntil) + " 到期"
            }
        } else {
            // 网页口径：free_until 为 0 时整行隐藏（藏包容器，见 makeGroupCard）。
            plusFreeWrapper?.isHidden = true
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
            fadeInNewStackRows(grantsStack)
            return
        }
        guard let list = grants, !list.isEmpty else {
            let emptyLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            emptyLabel.text = "暂无发放记录"
            grantsStack.addArrangedSubview(emptyLabel)
            fadeInNewStackRows(grantsStack)
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
        fadeInNewStackRows(grantsStack)
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
            // F11：组头刷新钮已取消，失败态改行内「重试」钮（仍调 loadSessions）。
            let failedLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            failedLabel.text = "加载失败"
            let retryButton = UIButton(type: .system)
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.setTitle("重试", for: .normal)
            retryButton.setTitleColor(BearyColors.ink, for: .normal)
            retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            retryButton.contentHorizontalAlignment = .left
            retryButton.addTarget(self, action: #selector(retrySessionsButtonTapped), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            sessionsStack.addArrangedSubview(failedLabel)
            sessionsStack.addArrangedSubview(retryButton)
            fadeInNewStackRows(sessionsStack)
            return
        }
        guard let list = sessions, !list.isEmpty else {
            let emptyLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
            emptyLabel.text = "暂无登录设备"
            sessionsStack.addArrangedSubview(emptyLabel)
            fadeInNewStackRows(sessionsStack)
            return
        }
        for session in list {
            let devLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
            devLabel.text = BearyAccountText.deviceName(session: session)
            var lineParts: [UIView] = [devLabel]
            if session.isCurrent == true {
                // F9：当前设备改网页 sess-cur 口径——11/700 绿字绿边框 pill
                // （内边距 1/7、圆角 8），不再是 13 橙纯文字。
                let curLabel = makeLabel(font: UIFont.systemFont(ofSize: 11, weight: .bold), color: BearyColors.green)
                curLabel.text = "当前"
                let curPill = UIView()
                curPill.translatesAutoresizingMaskIntoConstraints = false
                curPill.layer.borderWidth = 1
                curPill.layer.borderColor = BearyColors.green.cgColor
                curPill.layer.cornerRadius = 8
                curPill.clipsToBounds = true
                curLabel.translatesAutoresizingMaskIntoConstraints = false
                curPill.addSubview(curLabel)
                NSLayoutConstraint.activate([
                    curLabel.topAnchor.constraint(equalTo: curPill.topAnchor, constant: 1),
                    curLabel.leadingAnchor.constraint(equalTo: curPill.leadingAnchor, constant: 7),
                    curLabel.trailingAnchor.constraint(equalTo: curPill.trailingAnchor, constant: -7),
                    curLabel.bottomAnchor.constraint(equalTo: curPill.bottomAnchor, constant: -1),
                ])
                lineParts.append(curPill)
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
        fadeInNewStackRows(sessionsStack)
    }

    /// 新规矩(b)：会话/发放行异步落袋时错峰淡入（回收站 stagger 同口径：
    /// 0.32 + 每行 0.03、上限 0.3、curveEaseOut；减动效直显）。
    /// 目标透明度按行原值取（已过期行 0.55 不被洗成 1）；重建即新视图，
    /// 不存在已有行重播问题。
    private func fadeInNewStackRows(_ stack: UIStackView) {
        guard UIAccessibility.isReduceMotionEnabled == false else { return }
        for (index, view) in stack.arrangedSubviews.enumerated() {
            let targetAlpha = view.alpha
            view.alpha = 0
            UIView.animate(withDuration: 0.32, delay: min(Double(index) * 0.03, 0.3), options: .curveEaseOut, animations: {
                view.alpha = targetAlpha
            }, completion: nil)
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
        // 第 7 项：分页结果不再静默丢弃——任一 scope 失败即整单 fail-closed，
        // 任一 scope 触顶即整单走部分导出标注；失败优先于触顶（先判失败）。
        var exportFailedReason: String?
        var exportTruncated = false
        group.enter()
        BearyAPI.shared.fetchAccountSessions { result in
            if case .success(let resp) = result { sessionsResp = resp }
            group.leave()
        }
        let scopes: [(BearyAPI.Scope, (BearyExportPageResult) -> Void)] = [
            (.mine, { result in
                mineEntries = result.entries
                if !result.complete {
                    if result.reason == "已达 20 页上限" {
                        exportTruncated = true
                    } else {
                        exportFailedReason = result.reason ?? "分页失败"
                    }
                }
            }),
            (.mailbox, { result in
                mailboxEntries = result.entries
                if !result.complete {
                    if result.reason == "已达 20 页上限" {
                        exportTruncated = true
                    } else {
                        exportFailedReason = result.reason ?? "分页失败"
                    }
                }
            }),
            (.liked, { result in
                likedEntries = result.entries
                if !result.complete {
                    if result.reason == "已达 20 页上限" {
                        exportTruncated = true
                    } else {
                        exportFailedReason = result.reason ?? "分页失败"
                    }
                }
            }),
        ]
        for item in scopes {
            group.enter()
            fetchAllEntries(scope: item.0) { result in
                item.1(result)
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isExporting = false
            self.exportRowButton.isEnabled = true
            // 失败 fail-closed：只 toast、不拼 JSON、不出文件、不出分享面板。
            if let failedReason = exportFailedReason {
                self.showToast("导出失败（\(failedReason)），未生成文件")
                return
            }
            // 触顶：分享前先弹明确标注，用户点“继续分享”才拼文件、出分享面板；
            // 点取消则不出文件。N = 三个 scope 已取篇数之和（即文件内总篇数）。
            if exportTruncated {
                let totalCount = mineEntries.count + mailboxEntries.count + likedEntries.count
                let alert = UIAlertController(title: "部分导出", message: "部分导出（已取 \(totalCount) 篇，已达 20 页上限），是否继续分享部分数据？", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
                alert.addAction(UIAlertAction(title: "继续分享", style: .default, handler: { [weak self] _ in
                    self?.buildAndShareExport(user: user, sessionsResp: sessionsResp, mineEntries: mineEntries, mailboxEntries: mailboxEntries, likedEntries: likedEntries)
                }))
                self.present(alert, animated: true)
                return
            }
            self.buildAndShareExport(user: user, sessionsResp: sessionsResp, mineEntries: mineEntries, mailboxEntries: mailboxEntries, likedEntries: likedEntries)
        }
    }

    /// 导出文件拼装 + 分享面板（原 exportWithUser 内 group.notify 后半段原样挪出，
    /// JSON/写文件两处“导出失败，请重试”文案与触发条件均不动；仅调用点改为
    /// 成功直出、触顶经用户确认后出，失败路径根本不进本方法）。
    private func buildAndShareExport(user: MeUser, sessionsResp: BearyAccountSessionsResponse?, mineEntries: [Entry], mailboxEntries: [Entry], likedEntries: [Entry]) {
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
        // S3：分享结束即删本次临时文件——完成、取消、失败路径都清，
        // 不留导出 JSON 在 tmp 里；完成回调在分享面板收起后才跑，活动方已读完文件。
        activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            try? FileManager.default.removeItem(at: fileURL)
            if completed { self?.showToast("导出完成") }
        }
        self.present(activity, animated: true)
    }

    /// 第 7 项分页结果：entries=已取条目；complete=true 时 reason 恒为 nil；
    /// complete=false 仅两种情形——某页请求失败（reason="第 X 页失败"，X=depth+1，
    /// depth 从 0 计故首失败页为“第 1 页失败”）或已取满 20 页仍可能有下一页
    /// （reason="已达 20 页上限”）。调用方据此 fail-closed（失败）/ 部分标注（触顶），
    /// 再不允许静默拿已取数据当完整备份出文件。
    private typealias BearyExportPageResult = (entries: [Entry], complete: Bool, reason: String?)

    /// 分页拉全一个 scope：limit=50、guard 20 页（网页 fetchAll 同口径），
    /// 游标 before + before_id（App fetchEntries 既有口径，服务端 created_at DESC, id DESC）。
    private func fetchAllEntries(scope: BearyAPI.Scope, completion: @escaping (BearyExportPageResult) -> Void) {
        fetchScopePage(scope: scope, before: nil, beforeId: nil, accumulated: [], depth: 0, completion: completion)
    }

    private func fetchScopePage(scope: BearyAPI.Scope, before: Int?, beforeId: String?, accumulated: [Entry], depth: Int, completion: @escaping (BearyExportPageResult) -> Void) {
        if depth >= 20 {
            completion((entries: accumulated, complete: false, reason: "已达 20 页上限"))
            return
        }
        BearyAPI.shared.fetchEntries(scope: scope, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else {
                completion((entries: accumulated, complete: false, reason: "第 \(depth + 1) 页失败"))
                return
            }
            switch result {
            case .success(let list):
                let entries = list.entries ?? []
                let all = accumulated + entries
                if entries.count < 50 {
                    completion((entries: all, complete: true, reason: nil))
                    return
                }
                guard let last = entries.last, let lastCreated = last.createdAt else {
                    completion((entries: all, complete: true, reason: nil))
                    return
                }
                self.fetchScopePage(scope: scope, before: lastCreated, beforeId: last.id, accumulated: all, depth: depth + 1, completion: completion)
            case .failure:
                completion((entries: accumulated, complete: false, reason: "第 \(depth + 1) 页失败"))
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

    // MARK: - 设置页新增三区（2026-10-26，第二阶段）

    /// 主题行右侧对勾（mode → label），选档后刷新显隐；本页每次呈现新建，无需跨呈现复用。
    private var themeCheckmarkLabels: [String: UILabel] = [:]

    private func settingsInterfaceStyle(for mode: String) -> UIUserInterfaceStyle {
        switch mode {
        case "light": return .light
        case "dark": return .dark
        default: return .unspecified
        }
    }

    /// 内层可点行包容器（沿用退出登录行的 wrap 口径：内容 + 全幅透明按钮）。
    private func makeSettingsTappableRow(content: UIView, button: UIButton) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(content)
        button.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(button)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrap.topAnchor),
            content.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            button.topAnchor.constraint(equalTo: wrap.topAnchor),
            button.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    private func buildNotificationSection() {
        // 消息角标：本地开关，门控底栏消息段未读数显示（SceneDelegate.chrome.updateBellBadge 内查档）。
        let badgeTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        badgeTitle.text = "消息角标"
        let badgeDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        badgeDetail.text = "底栏消息段显示未读数"
        let badgeTextStack = UIStackView(arrangedSubviews: [badgeTitle, badgeDetail])
        badgeTextStack.axis = .vertical
        badgeTextStack.spacing = 2
        badgeTextStack.alignment = .fill
        let badgeSwitch = UISwitch()
        badgeSwitch.isOn = UserDefaults.standard.object(forKey: "beary_unread_badge_enabled") as? Bool ?? true
        badgeSwitch.setContentHuggingPriority(.required, for: .horizontal)
        badgeSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeSwitch.addTarget(self, action: #selector(badgeSwitchValueChanged(_:)), for: .valueChanged)
        let badgeRow = UIStackView(arrangedSubviews: [badgeTextStack, badgeSwitch])
        badgeRow.translatesAutoresizingMaskIntoConstraints = false
        badgeRow.axis = .horizontal
        badgeRow.spacing = 12
        badgeRow.alignment = .center

        // 系统通知设置：无推送后端，不编推送开关；只给打开 iOS 设置的真实入口。
        let systemDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        systemDetail.text = "去系统设置"
        let systemContent = makeRow(title: "系统通知设置", detailLabel: systemDetail, iconName: "icon_settings")
        let systemButton = UIButton(type: .custom)
        systemButton.addTarget(self, action: #selector(openSystemSettings), for: .touchUpInside)
        systemButton.bearyAddPressHaptic()
        let systemRow = makeSettingsTappableRow(content: systemContent, button: systemButton)

        let group = makeGroupCard(title: "消息与通知", rows: [badgeRow, systemRow])
        settingsExtraWrap.addArrangedSubview(group.card)
    }

    private func buildGeneralSection() {
        let current = UserDefaults.standard.string(forKey: "beary_theme_mode") ?? "system"
        let modes: [(value: String, title: String)] = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
        var rows: [UIView] = []
        for (index, mode) in modes.enumerated() {
            let checkmark = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
            checkmark.text = "✓"
            checkmark.isHidden = (mode.value != current)
            themeCheckmarkLabels[mode.value] = checkmark
            let content = makeRow(title: mode.title, detailLabel: checkmark, iconName: "icon_theme_auto")
            let button = UIButton(type: .custom)
            button.tag = index
            button.addTarget(self, action: #selector(themeRowTapped(_:)), for: .touchUpInside)
            button.bearyAddPressHaptic()
            rows.append(makeSettingsTappableRow(content: content, button: button))
        }
        // 版本行：Bundle 实值，只展示不跳转。
        let versionDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        versionDetail.text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        rows.append(makeRow(title: "版本", detailLabel: versionDetail))
        let group = makeGroupCard(title: "通用", rows: rows)
        settingsExtraWrap.addArrangedSubview(group.card)
    }

    private func buildPrivacySection() {
        let privacyDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        privacyDetail.text = "查看"
        let privacyContent = makeRow(title: "隐私政策", detailLabel: privacyDetail)
        let privacyButton = UIButton(type: .custom)
        privacyButton.addTarget(self, action: #selector(openPrivacyText), for: .touchUpInside)
        privacyButton.bearyAddPressHaptic()
        let privacyRow = makeSettingsTappableRow(content: privacyContent, button: privacyButton)
        let termsDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        termsDetail.text = "查看"
        let termsContent = makeRow(title: "用户协议", detailLabel: termsDetail)
        let termsButton = UIButton(type: .custom)
        termsButton.addTarget(self, action: #selector(openTermsText), for: .touchUpInside)
        termsButton.bearyAddPressHaptic()
        let termsRow = makeSettingsTappableRow(content: termsContent, button: termsButton)
        let group = makeGroupCard(title: "隐私", rows: [privacyRow, termsRow])
        settingsExtraWrap.addArrangedSubview(group.card)
    }

    @objc private func badgeSwitchValueChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "beary_unread_badge_enabled")
        SceneDelegate.chrome?.reapplyBellBadge()
    }

    @objc private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func themeRowTapped(_ sender: UIButton) {
        let modes = ["system", "light", "dark"]
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        let mode = modes[sender.tag]
        UserDefaults.standard.set(mode, forKey: "beary_theme_mode")
        view.window?.overrideUserInterfaceStyle = settingsInterfaceStyle(for: mode)
        for (value, label) in themeCheckmarkLabels {
            label.isHidden = (value != mode)
        }
    }

    @objc private func openPrivacyText() {
        presentLegalText(title: "隐私政策", text: BearyLegalTexts.privacy)
    }

    @objc private func openTermsText() {
        presentLegalText(title: "用户协议", text: BearyLegalTexts.terms)
    }

    private func presentLegalText(title: String, text: String) {
        let vc = BearyLegalTextViewController(pageTitle: title, pageText: text)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }
}

/// 设置页隐私/协议原生文字页：纯原生 UITextView 渲染捆进 App 的文本，
/// 不开网页、不挂 WKWebView（App 独立化方向）。全屏 modal，关闭即 dismiss。
final class BearyLegalTextViewController: UIViewController {
    private let pageTitle: String
    private let pageText: String
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let textView = UITextView()

    init(pageTitle: String, pageText: String) {
        self.pageTitle = pageTitle
        self.pageText = pageText
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = pageTitle
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = UIFont.systemFont(ofSize: 15)
        textView.textColor = BearyColors.ink
        textView.backgroundColor = BearyColors.bg
        textView.text = pageText
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.addSubview(topBar)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            textView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

enum BearyLegalTexts {
    static let privacy = """
隐私政策

生效日期：2026 年 10 月 19 日 · 最后更新：2026 年 10 月 21 日

引言

欢迎使用 teddyhn.com（以下简称"本站"）。本站是 Teddy 运营的个人网站，包括主站、/news 新闻页、/account 账户页、/beary 日记、cat.teddyhn.com 猫岛等。

我们深知个人信息对你的重要性。本政策详细说明我们如何收集、使用、存储、共享你的信息，以及你享有的权利。请在使用本站前仔细阅读。

一、定义

个人信息：以电子或其他方式记录的与已识别或可识别的自然人有关的各种信息。

敏感个人信息：一旦泄露可能导致人身、财产安全受到损害的信息。本站不收集敏感个人信息。

匿名化信息：经过处理无法识别特定自然人的信息，不属于个人信息。

二、我们收集的信息

2.1 账户信息

信息用途必填

邮箱地址发送登录验证码、重要通知是

账户 ID系统自动生成，唯一标识系统生成

显示名称你自定义的昵称，可与他人相同选填

用户名系统自动分配，可修改（修改后 7 天内不可再改）；用于你的公开主页链接，全站唯一系统生成

头像你上传的头像图片，会展示在你的公开内容旁选填

注册时间账户管理系统生成

登录地区（粗略）安全审计自动

登录设备型号登录时由设备信号（浏览器标识、设备渲染信息、屏幕尺寸）推断，用于在账户页展示你的登录设备自动

说明：本站采用邮箱验证码登录，不设置、不存储任何密码。验证码为 6 位数字，有效期 10 分钟。

2.2 内容信息

信息说明

beary 日记文字、图片。私密期仅本人可见，7 天后只送达给自己，不自动公开；作者主动公开后进入 24 小时倒计时，期间可取消

点赞记录你点赞的日记 ID、时间

小熊回应记录你贴出的小熊回应、日记 ID、时间

收藏记录你收藏的日记 ID、时间。收藏列表仅你本人可见，但收藏动作会通知日记作者

通知记录点赞、收藏、回应产生的互动通知，以及我们发送的系统通知

MC 白名单申请Minecraft 用户名、申请时间、审批状态（站长可见，用于审批；保留 1 年）

2.3 设备与日志信息

信息用途保留期限

IP 地址限流防刷、安全审计、粗略定位（天气）90 天

User-Agent适配显示、排查兼容问题90 天

访问日志安全审计、故障排查90 天

2.4 Cookie

名称用途类型有效期

teddy_session登录会话凭证HttpOnly, Secure30 天

teddy-theme主题偏好普通1 年

管理：你可以在浏览器设置中清除 Cookie。清除 teddy_session 将退出登录；清除 teddy-theme 将重置主题偏好。

2.5 我们不收集的信息

真实姓名、身份证号、电话号码、家庭住址

精准 GPS 定位（天气功能仅使用 IP 粗略定位到城市级别）

密码、支付信息

通讯录、相册等设备权限信息

三、信息的使用目的

目的涉及信息

提供登录服务邮箱、验证码、会话

提供日记、点赞功能内容、点赞记录

提供互动通知与系统消息互动记录、账户信息

展示公开主页与分享预览你的公开资料、已公开日记

保障安全IP、日志、设备信息

记住偏好Cookie

改进服务匿名化使用统计

我们承诺：

不出售你的个人信息；

不用于广告投放或用户画像；

不超出上述目的使用。

四、信息的共享、转让与披露

4.1 共享

我们不会与任何第三方共享你的个人信息，除非：

获得你的明确同意；

为提供服务所必需（如服务器托管、邮件发送）；

法律法规要求。

4.2 转让

如发生合并、收购，本站会要求新主体继续遵守本政策，或重新征得你的同意。

4.3 公开披露

你的公开日记（经你主动公开的内容）对所有访客可见，这是功能设计而非"披露"。

你的公开主页（teddyhn.com/beary/@你的用户名）对所有访客可见，展示你的显示名、头像、加入时间、公开日记、获赞数与小熊回应统计；单篇日记分享链接的预览信息（作者、摘要、首图）同样仅来自已公开日记。

除上述外，未经你同意，我们不会公开你的个人信息。

五、信息的存储

5.1 存储位置

数据存储在云服务商的服务器上，可能分布在多个国家/地区。

5.2 存储期限

数据保留期限到期处理

账户信息账户存续期间注销申请后 7 天冷静期，期满自动软删除

私密日记你删除后立即清除

公开日记永久（设计如此）不可删除

互动与通知记录账户存续期间随账户注销处理

日志/IP90 天自动清除

Cookie见 2.4过期自动失效

5.3 安全措施

全站 HTTPS 加密传输；

会话 Cookie 设为 HttpOnly，JS 无法读取；

会话凭证以哈希形式存储，不存明文；

限流与防护措施，防止恶意请求；

定期审查访问权限。

声明：我们采取业界合理的安全措施，但互联网没有绝对安全。如发生数据泄露，我们将在 72 小时内通知受影响用户并报告监管部门。

六、你的权利

根据适用法律，你享有以下权利：

6.1 知情权与访问权

登录后访问 /account 查看你的账户信息（邮箱、注册时间、ID）。

6.2 更正权

账户信息有误，联系 hi@teddyhn.com 更正。

6.3 删除权

私密日记：beary 私密期内可自行删除；

账户注销：登录后在 /account 自助注销。注销有 7 天冷静期：期间登录可取消，7 天后正式生效。生效后你的邮箱将被清空，日记保留但作者显示为"已注销用户"；

注意：已公开的日记按设计不可删除，发布前请确认。

6.4 撤回同意权

清除 Cookie 即可撤回主题偏好、退出登录；

注销账户即撤回全部授权。

6.5 数据导出权

登录后在 /account 即可自助导出你的数据副本（账户信息、日记内容、互动记录）；也可以联系 hi@teddyhn.com 索取，我们将在 15 个工作日内以常用格式提供。

6.6 投诉权

如认为我们的处理侵犯你的权益，可向网信、工信部门投诉，或联系我们协商。

响应时限：收到你的请求后，我们将在 15 个工作日内回复。

七、未成年人保护

本站不面向 13 岁以下儿童，不主动收集儿童信息。

13-18 岁未成年人使用本站，应获得监护人同意。

如发现儿童信息被收集，请监护人联系 hi@teddyhn.com（请说明与儿童的关系），我们将在核实后 15 个工作日内删除相关信息。

八、Do Not Track

本站尊重浏览器的 Do Not Track 信号，但目前不做特殊处理（因为我们本来就不追踪）。

九、政策更新

本政策可能因功能变更、法律要求而更新。

重大变更（如收集范围扩大、目的变更）会在本站显著位置公告 30 天。

继续使用即视为接受新政策；如不同意，请停止使用并注销账户。

变更记录：

2026-10-21：新增用户名与公开主页、收藏与小熊回应、互动通知与系统通知、登录设备型号的收集与使用说明；数据导出改为可在账户页自助导出；修正显示名称唯一性的表述。

2026-10-20：移除邀请码必填说明，精简技术细节。

2026-10-20：新增内测名额、邀请码、显示名称唯一性说明。

2026-10-19：首版发布。

十、联系我们

邮箱：hi@teddyhn.com

我们将在 15 个工作日内回复你的隐私相关咨询。
"""

    static let terms = """
用户协议

生效日期：2026 年 10 月 19 日 · 最后更新：2026 年 10 月 21 日

引言

欢迎使用 teddyhn.com（以下简称"本站"）。本站是 Teddy 运营的个人网站。

请在使用前仔细阅读本协议。使用本站（包括浏览、注册、发布内容）即视为你已阅读、理解并同意本协议全部条款。如不同意，请勿使用。

第一章 账户

1.1 注册与登录

本站采用邮箱验证码登录，不设密码。6 位数字验证码，有效期 10 分钟。

注册即表示你确认该邮箱为你本人所有。

每个邮箱对应唯一账户，系统自动分配账户 ID。

显示名称（昵称）由你自定义，可与他人相同，可随时修改。

用户名是你的公开主页标识，格式为 3–20 位小写字母、数字或下划线，全站唯一；注册时由系统自动分配，你可以修改，修改后 7 天内不可再次修改。你的公开主页地址为 teddyhn.com/beary/@用户名。

请勿将验证码告知他人。因验证码泄露导致的损失由你自行承担。

本站可能拒绝明显为临时/一次性邮箱的注册。

1.2 内测说明

本站目前处于内测阶段，站长可能视情况开启注册名额限制或邀请码注册。

如开启名额限制：名额满后新注册将被拒绝，已注册用户不受影响，具体以站内显示为准。

如开启邀请码注册：邀请码一次性使用，用后即失效；邀请码可能与指定邮箱绑定，不可转让。

内测结束后，相关限制自动失效，届时将另行公告。

1.3 账户安全

如发现账户异常，请立即联系 hi@teddyhn.com。

本站有权在检测到异常登录时要求重新验证。

连续输错验证码将被临时限制（防暴力破解）。

1.4 账户注销

登录后在 /account 自助注销。注销设有 7 天冷静期：提交后立即退出登录，7 天内任意一次登录会弹出确认，选择登录即取消注销。

7 天冷静期满未取消，注销正式生效：你的邮箱将被清空、所有设备退出登录，但已公开的日记按设计保留，作者显示为"已注销用户"。

1.5 账户封禁

以下情形本站有权封禁账户且不另行通知：

冒用他人邮箱注册；

批量注册、机器注册；

发布违法违规内容（见 2.4）；

恶意攻击本站、对他人数据进行非法获取。

封禁分为限时封禁与永久封禁。被封禁用户登录时将看到封禁原因与期限；封禁期间所有设备将被强制退出登录。

第二章 beary 日记

2.1 基本规则

规则说明

发布登录后可发布，文字上限 2000 字，图片最多 9 张

私密期发布后 7 天，仅本人可见

送达与公开7 天到期只送达给自己，不自动公开；作者主动公开后进入 24 小时倒计时，期间可取消，倒计时到期公开后不可撤销

编辑期发布后 15 分钟内可编辑，超时锁死

删除私密期内可删；公开后不可删除、不可修改

评论本站不设文字评论功能

点赞需登录，仅可赞已公开的日记

小熊回应需登录，仅限已公开日记；每人每篇可贴多种回应，各自贴、撤

收藏需登录，仅限已公开日记；收藏列表仅你本人可见，但收藏动作会通知作者

分享已公开日记可通过单篇链接分享给任何人

主动公开已送达的私密日记可主动公开，公开前有 24 小时倒计时，期间可取消；倒计时到期公开后不可撤销、不可删除

通知点赞、收藏、小熊回应会生成通知告知作者；我们也可通过通知栏发送系统消息（如欢迎信、重要变更）

2.2 发布前确认

因公开后不可删除、不可修改，发布前请务必确认：

内容不含隐私信息（身份证号、住址、电话等）；

图片不含他人肖像（除非获得授权）；

你愿意在主动公开后将其公开展示。

2.3 公开内容的效力

一旦日记转为公开，即视为你同意：

任何访客均可查看；

本站有权在站内展示、推荐；

你不可要求删除或隐藏（设计如此，非本站拒绝服务）。

2.4 内容规范

不得发布以下内容：

违反中国法律法规的内容；

色情、暴力、血腥、恐怖内容；

人身攻击、侮辱诽谤、侵犯他人隐私；

广告、spam、钓鱼链接；

侵犯他人知识产权的内容；

煽动民族仇恨、破坏社会稳定的内容。

违规处理：删除内容 → 警告 → 封禁账户（视情节）。

2.5 内容责任

你对自己发布的内容承担全部法律责任。本站作为平台，不对用户发布的内容承担审查义务，但有权主动处置违规内容。

2.6 公开主页

每位用户都拥有公开主页（teddyhn.com/beary/@用户名），展示显示名、头像、加入时间、公开日记、获赞数与小熊回应统计，任何访客均可查看。

「喜欢」列表（你点赞过的公开日记）在你的主页上公开可见；「收藏」列表仅你本人可见。

请勿在显示名称、头像中包含违法违规内容或冒充他人，处理规则同 2.4。

第三章 MC 服务器

3.1 白名单申请

在本站提交 Minecraft Java 版用户名申请白名单。

申请信息将发送给站长，由站长手动审批。

审批不保证时效，请耐心等待。

服务器地址、版本要求以审批通过后的通知为准。

3.2 服务器规则

禁止作弊、外挂、利用漏洞；

禁止恶意破坏他人建筑、偷盗；

禁止在服内发布广告、引战；

违规者将被移除白名单，情节严重者永久封禁。

3.3 服务说明

MC 服务器为免费公益服，不保证 7×24 在线。

无人时服务器可能自动休眠，需手动启动。

存档定期备份，但不承诺数据永不丢失。

第四章 合理使用

4.1 禁止行为

对本站进行 DDoS 攻击、漏洞扫描、SQL 注入等恶意行为；

编写爬虫批量抓取（正常搜索引擎除外）；

批量注册账户、刷赞、刷量；

逆向工程、试图获取他人数据；

冒充站长或本站工作人员。

4.2 限流

为保障服务稳定，本站实施限流措施，超限将被临时限制，解封后恢复。

4.3 违规处理

视情节轻重：警告 → 限流 → 临时封禁 → 永久封禁。造成损失的，本站保留追究法律责任的权利。

第五章 免责声明

5.1 服务现状

本站是个人非商业项目，按"现状"（AS IS）提供。

不保证 7×24 不间断可用，不保证无 bug。

本站有权在不通知的情况下进行维护、升级、功能调整。

5.2 内容免责

新闻内容来自第三方聚合，仅供参考。时效性、准确性不作保证。

未来推演是 AI 生成的情景假设，不是预测，不构成任何建议。

加密货币行情存在延迟，不可作为交易依据。投资有风险，入市需谨慎。

每日壁纸、猫片版权归原作者，本站仅做聚合展示。

5.3 责任限制

在法律允许的最大范围内：

因不可抗力（自然灾害、战争、政策变化）导致的服务中断，本站不承担责任；

因第三方服务故障导致的问题，本站不承担责任；

本站不对间接损失（包括但不限于利润损失、数据丢失）承担责任；

本站的累计赔偿责任不超过你过去 12 个月向本站支付的费用总额（本站免费，故为 0 元）。

第六章 知识产权

6.1 本站权利

本站的域名、设计、代码、文案、logo（另有约定的除外）归 Teddy 所有。未经许可，不得复制、改编、用于商业用途。

6.2 用户内容授权

你发布的日记内容版权归你所有。但你授予本站：

展示权：在站内公开展示你的公开日记；

同步权：为提供服务所需的技术性复制（如缓存）；

授权期限：与公开状态存续期一致；授权范围：全球、免费、非独家。

6.3 第三方内容

每日壁纸、猫片等版权归原作者，本站已注明来源。如权利人认为侵权，请联系 hi@teddyhn.com，我们将及时处理。

6.4 侵权投诉

如认为本站内容侵犯你的权利，请发送邮件至 hi@teddyhn.com，附上：

权利证明；

侵权内容链接；

联系方式。

我们将在 15 个工作日内处理。

第七章 协议变更

本协议可能因功能调整、法律要求而更新。

重大变更将在本站显著位置公告 30 天。

继续使用即视为接受；如不同意，请停止使用并注销账户。

变更记录：

2026-10-21：新增用户名与公开主页条款、互动（小熊回应/收藏/分享/通知）规则；修正显示名称唯一性的表述。

2026-10-20：调整内测条款表述（改为按需开启），精简技术细节。

2026-10-20：新增内测名额、邀请码、显示名称唯一性条款。

2026-10-19：首版发布。

第八章 争议解决

本协议适用中华人民共和国法律。

因本协议引起的争议，双方应友好协商；协商不成的，提交Teddy 所在地人民法院管辖。

本协议任一条款无效，不影响其他条款效力（可分割性）。

第九章 联系方式

邮箱：hi@teddyhn.com

一般咨询：15 个工作日内回复

紧急安全问题：请在邮件标题注明
"""
}
