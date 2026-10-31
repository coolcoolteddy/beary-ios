// ===== beary 设置页（2026-10-26：原独立账户页整体迁移为本页「账号与安全」分区；
// 齿轮菜单与头像菜单的“账户设置”入口均改开本页，旧 BearyAccountViewController 已删除，
// 不留两个入口、不留死代码页）=====
// C 批（C2/C3/C4）：模块顺序改为 [ID 概览卡 & Plus 状态] → [通用与通知
// （外观切换、消息角标、使用指南入口）] → [账户与安全（登录设备管理、导出数据；
// 个人资料入口为 ID 卡右侧“编辑资料”钮，旧账户组四行已按 C4 删除）] → [隐私与协议]；
// 退出登录为独立居中常规钮（BearyButton 工厂），注销账户下沉至页底弱化灰字，
// 两者行为一字不动；齿轮直达本页，不再经 ActionSheet / 外观 Popover 中转。
// 新增行一律真实能力：消息角标开关（本地 UserDefaults 门控底栏角标）、外观主题三选
// （复用 beary_theme_mode 存档键）、版本行（Bundle 实值）；全修 3-4 已删“系统通知设置”行
// （全仓无通知调用，系统通知开关对本 App 无效，不留无效入口）、
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

/// 2026-10-29 第 7、11 项：本格式化 helper 改 internal，供独立子页
/// BearySettingsSubpages.swift 复用（原 private 致子页编译失败）；纯格式化，无状态。
enum BearyAccountText {
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
    /// C2：通用组内「使用指南」行的容器回调；容器接线到教程重播页。
    var onShowTutorial: (() -> Void)?

    // MARK: - 状态

    private var meUser: MeUser?
    private var plusDetail: BearyPlusDetailResponse?
    private var accountSessions: [BearyAccountSession] = []
    private var isLoadingMe = false
    /// 切换账号卡容器（buildAccountSwitchSection 建，refreshAccountSwitchSection
    /// 重建卡片；登录态无关的通用/隐私组不受影响）。
    private let accountSwitchWrap = UIView()
    private var isSwitchingAccount = false
    private var isRemovingAccount = false
    private var isLoggingOutOthers = false
    private var isDeleting = false
    private var isExporting = false
    private var exportDetailLabel: UILabel? // 2026-10-29：导出进度提示落点（导出行副文案）
    /// 内容列宽：直接由 view.bounds 派生的必需约束（替代旧的
    /// frameLayoutGuide 750 宽约束 + 600 上限开关两约束协商）。列宽是
    /// view.bounds 的纯函数，首个布局轮次即最终值，不再经多轮约束收敛
    /// 分段变宽；最终口径不变（iPhone 屏宽 -40，宽 ≥821 锁 600 居中）。
    private var contentColumnWidth: NSLayoutConstraint?
    /// 115 设置页空白守卫（根因未证实，见下）：view 帧复位只做一次，避免布局环。
    private var settingsFrameResetDone = false
    /// 115 设置页空白守卫：进场诊断日志每出现一次只记一次。
    private var settingsLayoutLogged = false

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let closeButton = BearyHit44Button(type: .system)
    private let titleLabel = UILabel()
    private let loadingView = BearyRefreshIconView()
    private let failureWrap = UIStackView()
    private let failureLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let loginWrap = UIStackView()
    private let loginHintLabel = UILabel()
    private let loginButton = UIButton(type: .system)
    /// C2：登录态相关容器。contentWrap = [ID 概览卡 & Plus 状态]；
    /// accountSecurityWrap = [账户与安全]（安全组 + 导出行）；两者未登录 /
    /// 加载失败时隐藏。generalNotifyWrap = [通用与通知]、privacyWrap =
    /// [隐私与协议] 登录态无关（主题/隐私/通知开关本地可用），恒可见。
    private let contentWrap = UIStackView()
    private let generalNotifyWrap = UIStackView()
    private let accountSecurityWrap = UIStackView()
    private let privacyWrap = UIStackView()
    /// 数据与反馈组（2026-10-28 反馈 v3）：只剩「反馈与改进」一行；与通用 /
    /// 隐私组同款恒可见，不随登录态切换（游客进不了设置页，见任务说明）。
    private let dataFeedbackWrap = UIStackView()
    /// 2026-10-29 第 12 项（合并 B）：退出登录与注销账户并入「账号操作」卡
    /// （仍登录态相关，未登录 / 加载失败时整卡隐藏；注销行另按 is_admin 隐藏，
    /// 连同其前分隔线一并藏，不留 stray 线）。
    private let accountActionWrap = UIView()
    private var accountActionDeleteSeparator: UIView?
    private var accountActionDeleteWrap: UIView?
    /// 2026-10-29 第 10 项：页底版本脚注（通用组版本行移至页底，Bundle 动态读）。
    private let versionFooterWrap = UIView()

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
    /// 2026-10-29 第 7 项：来源明细已抽成独立页（BearyPlusGrantsViewController），
    /// 设置页只缓存数据、不再内联建发放行；grantsStack 已随之删除。
    private var cachedGrants: [BearyPlusGrant]?
    private var grantsLoadFailed = false

    // ID 卡右侧编辑资料钮（C4：账户组四行删除后，个人资料唯一入口）。
    private let editProfileButton = UIButton(type: .system)

    // 设备分组
    private let deviceCountLabel = UILabel()
    /// 2026-10-29 第 11 项：设备列表已抽成独立页（BearyDevicesViewController），
    /// 设置页只缓存数据（accountSessions 既有）与失败态、不再内联展开；
    /// sessionsStack 已随之删除。退出其他设备钮仍留在设置页。
    private var sessionsLoadFailed = false
    private let logoutOthersButton = UIButton(type: .system)

    // C3：退出登录独立居中常规钮（#74 BearyButton 工厂 secondaryOutline 常规款，
    // 不另起样式）；导出行复用 exportRowButton（安全组内行，isEnabled 由导出流程控制）；
    // 注销账户复用 deleteRowButton，改弱化灰字文本钮置于页底（行为一字不动）。
    private let logoutStandaloneButton = BearyButton(style: .secondaryOutline(.regular))
    private let exportRowButton = UIButton(type: .custom)
    private let deleteRowButton = UIButton(type: .custom)

    init() {
        super.init(nibName: nil, bundle: nil)
        self.title = "账户设置"
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildLayout()
        loadAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settingsFrameResetDone = false
        settingsLayoutLogged = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        logSettingsLayout(tag: "appear")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateColumnWidth()
        applySettingsLayoutGuard()
    }

    /// 115 设置页空白守卫（根因未证实，针对两类未证实原因）：
    /// ① 呈现时 view 帧 / 安全区异常导致顶栏被顶到屏中部；
    /// ② 约束冲突时 solver 弃锚点导致 scrollView 可见高度归零。
    /// 只做帧复位 + 一次重布局，不整页重建、不重播动效、不改字号
    /// 跟随与 loadAll / 各分组 isHidden 口径。顶栏是 buildLayout 的
    /// 局部变量，这里经 closeButton.superview 取到，不新增存储属性。
    private func applySettingsLayoutGuard() {
        guard !settingsFrameResetDone, let window = view.window else { return }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0, view.bounds.width > 0 else { return }
        let topBar = closeButton.superview
        let topBarMinY = topBar?.frame.minY ?? 0
        let safeTop = view.safeAreaInsets.top
        let viewFrameOff = abs(view.frame.origin.x) > 0.5 || abs(view.frame.origin.y) > 0.5
            || abs(view.frame.width - bounds.width) > 0.5 || abs(view.frame.height - bounds.height) > 0.5
        let topBarOff = topBar != nil && abs(topBarMinY - safeTop) > 20
        let scrollCollapsed = scrollView.frame.height <= 0
        guard viewFrameOff || topBarOff || scrollCollapsed else { return }
        settingsFrameResetDone = true
        if viewFrameOff {
            view.frame = bounds
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        logSettingsLayout(tag: "guard-reset")
    }

    /// 115 设置页空白诊断：进场与守卫触发时各记一行，进现有 NSLog
    /// "[Diag]" 诊断通道，不弹 toast、不改 UI。复现时凭此行一次定位
    /// （顶栏 frame.y 是否偏离安全区顶、scrollView 是否有可见高度）。
    private func logSettingsLayout(tag: String) {
        guard !settingsLayoutLogged || tag == "guard-reset" else { return }
        if tag == "appear" { settingsLayoutLogged = true }
        let topBar = closeButton.superview
        NSLog("[Diag] settings-layout tag=%@ view=%@ topBar=%@ scrollView=%@ safeArea=%@",
              tag, NSCoder.string(for: view.frame),
              topBar.map { NSCoder.string(for: $0.frame) } ?? "nil",
              NSCoder.string(for: scrollView.frame),
              NSCoder.string(for: view.safeAreaInsets))
    }

    /// 容器（登录页）关掉回到本页时刷新切换列表：添加账号走登录页回来
    /// 后，新号经 refreshMe 快照进保管库，此处重建卡片即见新行；登录页
    /// 取消则列表不变。只读保管库 + 重建本卡，不发网络。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshAccountSwitchSection()
    }

    /// 列宽只由 view.bounds 定：宽 ≥821 锁 600（P2-1 同款），宽 ≤820 时
    /// 屏宽 -40 撑满；bounds 为 0 时跳过不钉死；值不变时不写，避免布局环。
    private func updateColumnWidth() {
        let w = view.bounds.width
        guard w > 0 else { return }
        let target: CGFloat = w >= 821 ? 600 : max(w - 40, 0)
        if contentColumnWidth?.constant != target {
            contentColumnWidth?.constant = target
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷描边（背景色走动态色，自动跟随）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            for card in cardViews {
                card.layer.bearyDynamicBorderColor = BearyColors.line
            }
            logoutOthersButton.layer.bearyDynamicBorderColor = BearyColors.alpha(BearyColors.red, 0.45)
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
        // P1-7：设置页正文 / 辅助 / 分组标题一律走动态字体入口（默认字号下
        // 与原值一致，大字号档跟随系统缩放）；本工厂只产出上述三类文字，
        // 故集中在此接 scaledFont + adjusts，不逐处重复。
        label.font = BearyDynamicType.scaledFont(for: font)
        label.adjustsFontForContentSizeCategory = true
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
        // P1-7：分组标题多行自适应——大字号下可换行，卡内标题包容器
        // 上下约束已定，行高随文字自动撑开，不钉固定高度。
        label.numberOfLines = 0
        label.attributedText = NSAttributedString(string: text, attributes: [.kern: 1, .font: label.font])
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
        // P1-7：行正文标题与行尾辅助文案均可多行，行高由栈自动撑开。
        titleLabelValue.numberOfLines = 0
        detailLabel.numberOfLines = 0
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
        // P1-7：两行式行的标题多行、辅助文案走动态字体（工厂标题已接入口，
        // 直建的 detail 在此接入口，不在工厂外重复缩放已缩放过的字）。
        titleLabelValue.numberOfLines = 0
        detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        detailLabel.adjustsFontForContentSizeCategory = true
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
        card.layer.bearyDynamicBorderColor = BearyColors.line
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
        closeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "设置"

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            // 115 设置页空白守卫（根因未证实）：顶栏保留 #343 跟随字号，
            // 但加覆盖最大无障碍字号的上界。17pt 粗体在最大档缩放后约
            // 51pt + 上下各 6pt 内边距 ≈ 63pt，88pt 留足余量；上界只防
            // solver 在异常组合下把顶栏撑到把 scrollView 顶出屏，不改常规
            // 字号下的 52pt，也不动字号跟随逻辑本身。
            topBar.heightAnchor.constraint(lessThanOrEqualToConstant: 88),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        view.addSubview(topBar)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        // 补缺 P2-17：主页顶栏与内容列同宽居中（内容列为 600／屏宽-40，见 updateColumnWidth）。
        let mainTopBarWidthEquality = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40)
        mainTopBarWidthEquality.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            mainTopBarWidthEquality,
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
        contentColumnWidth = contentStack.widthAnchor.constraint(equalToConstant: 0)
        contentColumnWidth?.isActive = true
        updateColumnWidth()

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        // 栈内固有尺寸与旧 medium 圈一致（20pt 图）。
        loadingView.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
        // P1-7：失败辅助文案走动态字体（已是 0 行，下同：只改字，不改布局）。
        failureLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        failureLabel.adjustsFontForContentSizeCategory = true
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

        // P1-7：登录提示辅助文案走动态字体。
        loginHintLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        loginHintLabel.adjustsFontForContentSizeCategory = true
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

        // C2 模块顺序：[ID 概览卡 & Plus 状态] → [通用与通知] →
        // [账户与安全] → [隐私与协议]，其后依次为独立退出钮与页底注销入口。
        buildIdCard()
        buildPlusSection()

        generalNotifyWrap.translatesAutoresizingMaskIntoConstraints = false
        generalNotifyWrap.axis = .vertical
        generalNotifyWrap.spacing = 20
        generalNotifyWrap.alignment = .fill
        buildGeneralSection()
        buildNotificationSection()

        accountSecurityWrap.translatesAutoresizingMaskIntoConstraints = false
        accountSecurityWrap.axis = .vertical
        accountSecurityWrap.spacing = 20
        accountSecurityWrap.alignment = .fill
        accountSecurityWrap.isHidden = true
        // 全修 8-17：标题收进卡内（见 buildSecuritySection 的 makeGroupCard），
        // 与 Plus/通用/消息与通知/隐私四组一致，不再卡外单立标题。
        buildSecuritySection()
        // 切换账号卡（2026-10-31）：同属账户与安全组，列在安全卡之后。
        buildAccountSwitchSection()

        privacyWrap.translatesAutoresizingMaskIntoConstraints = false
        privacyWrap.axis = .vertical
        privacyWrap.spacing = 20
        privacyWrap.alignment = .fill
        buildPrivacySection()

        dataFeedbackWrap.translatesAutoresizingMaskIntoConstraints = false
        dataFeedbackWrap.axis = .vertical
        dataFeedbackWrap.spacing = 20
        dataFeedbackWrap.alignment = .fill
        buildDataFeedbackSection()

        buildAccountActionSection()
        buildVersionFooter()

        contentStack.addArrangedSubview(loadingView)
        contentStack.addArrangedSubview(failureWrap)
        contentStack.addArrangedSubview(loginWrap)
        contentStack.addArrangedSubview(contentWrap)
        contentStack.addArrangedSubview(generalNotifyWrap)
        contentStack.addArrangedSubview(accountSecurityWrap)
        contentStack.addArrangedSubview(privacyWrap)
        contentStack.addArrangedSubview(dataFeedbackWrap)
        contentStack.addArrangedSubview(accountActionWrap)
        contentStack.addArrangedSubview(versionFooterWrap)
        // 2026-10-29 第 10 项：版本只留页底脚注一处（通用组版本行已删，
        // 见 buildGeneralSection；同值同格式，避免同一页出现两个版本号）。

        // toast 已委托 B 批统一 BearyToast（见 showToast），此处不再建常驻容器。
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
        // P1-7：ID 卡邮箱辅助文案走动态字体（已是 0 行）。
        heroEmailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        heroEmailLabel.adjustsFontForContentSizeCategory = true
        heroEmailLabel.textColor = BearyColors.gray
        heroEmailLabel.numberOfLines = 0
        heroEmailLabel.lineBreakMode = .byCharWrapping
        let nameStack = UIStackView(arrangedSubviews: [heroNameLabel, heroEmailLabel])
        nameStack.axis = .vertical
        nameStack.spacing = 4
        // C4：ID 卡右侧直接提供“编辑资料”钮（旧账户组四行已删，个人资料
        // 唯一入口走这里；行末文字钮口径与旧账户组编辑 / 修改同款 14 墨字）。
        editProfileButton.translatesAutoresizingMaskIntoConstraints = false
        editProfileButton.setTitle("编辑资料", for: .normal)
        editProfileButton.setTitleColor(BearyColors.ink, for: .normal)
        editProfileButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        editProfileButton.setContentHuggingPriority(.required, for: .horizontal)
        editProfileButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        editProfileButton.addTarget(self, action: #selector(editProfileButtonTapped), for: .touchUpInside)
        editProfileButton.bearyAddPressFeedback()
        let heroRow = UIStackView(arrangedSubviews: [avatarContainer, nameStack, editProfileButton])
        heroRow.axis = .horizontal
        heroRow.spacing = 16
        heroRow.alignment = .center

        // P1-7：ID 卡行尾辅助文案（注册时间 / 会员）走动态字体。
        idCreatedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        idCreatedLabel.adjustsFontForContentSizeCategory = true
        idCreatedLabel.textColor = BearyColors.gray
        idCreatedLabel.numberOfLines = 0
        idCreatedLabel.textAlignment = .right
        idPlusLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        idPlusLabel.adjustsFontForContentSizeCategory = true
        idPlusLabel.textColor = BearyColors.gray
        idPlusLabel.numberOfLines = 0
        idPlusLabel.textAlignment = .right
        // F5：ID 值 mono 15/700 + 字距 2（网页 id-val 口径）；ID 标签 mono 10 + 字距 3。
        idValueLabel.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        idValueLabel.textColor = BearyColors.ink
        idValueLabel.numberOfLines = 0
        idValueLabel.lineBreakMode = .byCharWrapping
        let idTitleLabel = makeLabel(font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular), color: BearyColors.gray)
        idTitleLabel.attributedText = NSAttributedString(string: "ID", attributes: [.kern: 3, .font: idTitleLabel.font])
        let idRow = UIStackView(arrangedSubviews: [idTitleLabel, idValueLabel])
        idRow.axis = .horizontal
        idRow.spacing = 12
        idRow.alignment = .center

        let createdRow = makeRow(title: "注册时间", detailLabel: idCreatedLabel, iconName: "icon_clock")
        let plusRow = makeRow(title: "会员", detailLabel: idPlusLabel, iconName: "icon_sparkles")
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
        // P1-7：Plus 组行尾辅助文案走动态字体（以下三行同）。
        plusStatusLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        plusStatusLabel.adjustsFontForContentSizeCategory = true
        plusStatusLabel.textColor = BearyColors.gray
        plusStatusLabel.numberOfLines = 0
        plusStatusLabel.textAlignment = .right
        plusFreeLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        plusFreeLabel.adjustsFontForContentSizeCategory = true
        plusFreeLabel.textColor = BearyColors.gray
        plusFreeLabel.numberOfLines = 0
        plusFreeLabel.textAlignment = .right
        plusPersonalLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        plusPersonalLabel.adjustsFontForContentSizeCategory = true
        plusPersonalLabel.textColor = BearyColors.gray
        plusPersonalLabel.numberOfLines = 0
        plusPersonalLabel.textAlignment = .right
        plusFreeRow = makeRow(title: "内测限免", detailLabel: plusFreeLabel, iconName: "icon_gift")
        // 2026-10-29 第 7 项：来源明细抽成独立页——组内只留一行（标题 + 行尾
        // 官方包右箭头），点击进 BearyPlusGrantsViewController；原内联发放卡已删。
        let grantsTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        grantsTitle.text = "来源明细"
        grantsTitle.numberOfLines = 0 // P1-7：行正文标题多行
        grantsTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let grantsContent = UIStackView(arrangedSubviews: [grantsTitle, makeRowSpacer(), makeRowChevron()])
        grantsContent.translatesAutoresizingMaskIntoConstraints = false
        grantsContent.axis = .horizontal
        grantsContent.spacing = 12
        grantsContent.alignment = .center
        let grantsButton = UIButton(type: .custom)
        grantsButton.accessibilityLabel = "会员来源明细"
        grantsButton.addTarget(self, action: #selector(openPlusGrantsPage), for: .touchUpInside)
        grantsButton.bearyAddPressHaptic()
        let grantsRow = makeSettingsTappableRow(content: grantsContent, button: grantsButton)
        // F4：标题入卡内（网页 Plus 会员 group-title 口径）；Plus 组网页行本身无图标，不补。
        let plusGroup = makeGroupCard(title: "Plus 会员", rows: [
            makeRow(title: "当前状态", detailLabel: plusStatusLabel, iconName: "icon_info"),
            plusFreeRow,
            makeRow(title: "专属会员", detailLabel: plusPersonalLabel, iconName: "icon_star"),
            grantsRow,
        ])
        if plusGroup.wrappers.count > 1 {
            plusFreeWrapper = plusGroup.wrappers[1]
        }
        contentWrap.addArrangedSubview(plusGroup.card)
    }

    // C4：旧「账户」组整组删除——显示名称 / 用户名 / 邮箱 / 注册时间四行
    // 均与编辑资料重复（昵称、用户名 @handle 在编辑页内，邮箱与注册时间
    // 已在 ID 卡呈现），四行删完后组内无剩余行，故卡片一并移除，不留空组；
    // 账户组其余行本就不存在，安全组与导出行不受影响（见 buildSecuritySection）。
    // 个人资料入口改为 ID 卡右侧“编辑资料”钮（见 buildIdCard）。

    private func buildSecuritySection() {
        // F8/F11：设备不再单立「组头 + 刷新」分组，改为安全组内一行（网页
        // account.html 安全组口径：邮箱验证码登录行、登录设备行、会话列表、
        // 退出其他设备钮同卡；刷新钮随组头一并取消，失败态改行内重试钮）。
        let codeLoginDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        codeLoginDetail.text = "每次登录发送 6 位验证码，无需密码"
        let codeLoginRow = makeInfoRow(title: "邮箱验证码登录", detailLabel: codeLoginDetail, iconName: "icon_lock")
        // P1-7：登录设备行辅助文案走动态字体；makeInfoRow 会以同基值
        // systemFont(12) 重写一次（非对已缩放字再缩放），最终只缩放一次。
        deviceCountLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        deviceCountLabel.adjustsFontForContentSizeCategory = true
        deviceCountLabel.textColor = BearyColors.gray
        deviceCountLabel.numberOfLines = 0
        deviceCountLabel.textAlignment = .left
        // 2026-10-29 第 11 项：设备列表抽成独立页——安全组只留「登录设备 ·
        // 共 N 台设备」一行（行尾官方包右箭头），点击进 BearyDevicesViewController；
        // 原内联展开列表已摘掉，设置页不再内联展开。
        let deviceRowContent = makeInfoRow(title: "登录设备", detailLabel: deviceCountLabel, iconName: "icon_device")
        if let deviceStack = deviceRowContent as? UIStackView {
            deviceStack.addArrangedSubview(makeRowSpacer())
            deviceStack.addArrangedSubview(makeRowChevron())
        }
        let deviceButton = UIButton(type: .custom)
        deviceButton.accessibilityLabel = "登录设备"
        deviceButton.addTarget(self, action: #selector(openDevicesPage), for: .touchUpInside)
        deviceButton.bearyAddPressHaptic()
        let deviceRow = makeSettingsTappableRow(content: deviceRowContent, button: deviceButton)
        logoutOthersButton.translatesAutoresizingMaskIntoConstraints = false
        logoutOthersButton.setTitle("退出其他设备", for: .normal)
        logoutOthersButton.setTitleColor(BearyColors.red, for: .normal)
        // F10：网页 .btn.danger 口径——36 高、13/600、红字红边（红 45% 透明边）。
        logoutOthersButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        logoutOthersButton.layer.borderWidth = 1
        logoutOthersButton.layer.bearyDynamicBorderColor = BearyColors.alpha(BearyColors.red, 0.45)
        logoutOthersButton.layer.cornerRadius = 12
        logoutOthersButton.addTarget(self, action: #selector(logoutOthersButtonTapped), for: .touchUpInside)
        logoutOthersButton.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            logoutOthersButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        // C2：导出我的数据归入账户与安全模块（原动作卡行，视觉与行为不动，
        // 仅换组；exportRowButton 的 isEnabled 仍由导出流程控制）。
        let exportTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        exportTitle.text = "导出我的数据"
        exportTitle.numberOfLines = 0 // P1-7：行正文标题多行
        let exportDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        exportDetail.text = "下载 JSON，含账户、日记、点赞记录"
        exportDetailLabel = exportDetail
        let exportStack = UIStackView(arrangedSubviews: [exportTitle, exportDetail])
        exportStack.axis = .vertical
        exportStack.spacing = 4
        exportRowButton.translatesAutoresizingMaskIntoConstraints = false
        exportRowButton.accessibilityLabel = "导出我的数据"
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
        // 全修 8-17：标题收进卡内，与其余四组一致（旧“卡外标题 + 卡内 nil”
        // 口径已废，卡外标题行随之删除）。
        let securityGroup = makeGroupCard(title: "账号与安全", rows: [
            codeLoginRow,
            deviceRow,
            logoutOthersButton,
            exportRowWrap,
        ])
        accountSecurityWrap.addArrangedSubview(securityGroup.card)
    }

    // MARK: - 切换账号（2026-10-31，仅 App 设置页；网页端不做）

    /// 切换列表行展示模型：保管库行带 token（可切），当前账号若尚未
    /// 快照进库（冷启动后首次进设置页且 refreshMe 尚未跑完的极小窗口）
    /// 以无 token 行展示——点按即已是当前账号，移除仍走正常退出流程。
    private struct SwitchRowModel {
        var userId: Int
        var title: String
        var handle: String?
        var email: String?
        var avatarURL: String?
        var hasToken: Bool
    }

    private func buildAccountSwitchSection() {
        accountSwitchWrap.translatesAutoresizingMaskIntoConstraints = false
        accountSwitchWrap.isHidden = true
        accountSecurityWrap.addArrangedSubview(accountSwitchWrap)
    }

    /// 重建切换账号卡：只读保管库，不发网络；未登录时整卡隐藏。
    /// 当前账号优先排第一位（其余按首次保存顺序），当前行打勾；
    /// “添加账号”行恒可见，满 3 个时点按只弹上限提示、不进登录页。
    private func refreshAccountSwitchSection() {
        for subview in accountSwitchWrap.subviews {
            subview.removeFromSuperview()
        }
        let currentUser = SessionManager.shared.currentUser ?? meUser
        guard let currentUserValue = currentUser, currentUserValue.id != nil else {
            accountSwitchWrap.isHidden = true
            return
        }
        SessionManager.shared.snapshotCurrentAccount()
        let vault = BearyAccountVault.shared
        let stored = vault.loadAll()
        var models: [SwitchRowModel] = stored.map { account in
            SwitchRowModel(userId: account.userId, title: account.displayTitle, handle: account.handle, email: account.email, avatarURL: account.avatarURL, hasToken: true)
        }
        if let currentId = currentUserValue.id, !models.contains(where: { $0.userId == currentId }) {
            models.append(SwitchRowModel(userId: currentId, title: currentUserValue.displayName ?? currentUserValue.email ?? "ID \(currentId)", handle: currentUserValue.handle, email: currentUserValue.email, avatarURL: nil, hasToken: false))
        }
        // 当前账号排首位，其余保持首次保存顺序（sort 稳定性：先按是否当前分两段）。
        let currentIdValue = currentUserValue.id
        models.sort { (first, second) -> Bool in
            let firstIsCurrent = first.userId == currentIdValue
            let secondIsCurrent = second.userId == currentIdValue
            if firstIsCurrent != secondIsCurrent { return firstIsCurrent }
            return false
        }
        var rows: [UIView] = []
        for model in models {
            rows.append(makeAccountSwitchRow(model: model, isCurrent: model.userId == currentIdValue))
        }
        rows.append(makeAddAccountRow())
        let group = makeGroupCard(title: "切换账号", rows: rows)
        group.card.translatesAutoresizingMaskIntoConstraints = false
        accountSwitchWrap.addSubview(group.card)
        NSLayoutConstraint.activate([
            group.card.topAnchor.constraint(equalTo: accountSwitchWrap.topAnchor),
            group.card.leadingAnchor.constraint(equalTo: accountSwitchWrap.leadingAnchor),
            group.card.trailingAnchor.constraint(equalTo: accountSwitchWrap.trailingAnchor),
            group.card.bottomAnchor.constraint(equalTo: accountSwitchWrap.bottomAnchor),
        ])
        accountSwitchWrap.isHidden = false
    }

    private func makeAccountSwitchRow(model: SwitchRowModel, isCurrent: Bool) -> UIView {
        let avatarContainer = UIView()
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.backgroundColor = BearyColors.faint
        avatarContainer.layer.cornerRadius = 18
        avatarContainer.clipsToBounds = true
        let avatarImageView = UIImageView()
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        let avatarInitialLabel = UILabel()
        avatarInitialLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarInitialLabel.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        avatarInitialLabel.textColor = BearyColors.ink
        avatarInitialLabel.textAlignment = .center
        avatarInitialLabel.text = String(model.title.prefix(1))
        avatarContainer.addSubview(avatarImageView)
        avatarContainer.addSubview(avatarInitialLabel)
        NSLayoutConstraint.activate([
            avatarContainer.widthAnchor.constraint(equalToConstant: 36),
            avatarContainer.heightAnchor.constraint(equalToConstant: 36),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
        ])
        if let avatarURL = model.avatarURL, let url = BearyImageURLs.avatarURL(avatarURL) {
            avatarImageView.bearySetImage(url: url)
        }
        let nameLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        nameLabel.text = model.title
        let detailText: String
        if let handle = model.handle, !handle.isEmpty {
            detailText = "@" + handle + " · " + BearyAccountVault.maskedEmail(model.email)
        } else {
            detailText = BearyAccountVault.maskedEmail(model.email)
        }
        let detailLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        detailLabel.text = detailText
        let textStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        let rowContent = UIStackView(arrangedSubviews: [avatarContainer, textStack])
        rowContent.axis = .horizontal
        rowContent.spacing = 12
        rowContent.alignment = .center
        rowContent.translatesAutoresizingMaskIntoConstraints = false
        if isCurrent {
            let checkView = UIImageView(image: BearyIconImages.image(named: "icon_check", pointSize: 18))
            checkView.translatesAutoresizingMaskIntoConstraints = false
            checkView.tintColor = BearyColors.ink
            checkView.contentMode = .scaleAspectFit
            NSLayoutConstraint.activate([
                checkView.widthAnchor.constraint(equalToConstant: 18),
                checkView.heightAnchor.constraint(equalToConstant: 18),
            ])
            rowContent.addArrangedSubview(checkView)
        }
        let rowView = UIView()
        rowView.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(rowContent)
        let switchButton = UIButton(type: .system)
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        switchButton.tag = model.userId
        switchButton.addTarget(self, action: #selector(switchAccountButtonTapped(_:)), for: .touchUpInside)
        switchButton.bearyAddPressFeedback()
        rowView.addSubview(switchButton)
        let removeButton = UIButton(type: .system)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setTitle("移除", for: .normal)
        removeButton.setTitleColor(BearyColors.gray, for: .normal)
        removeButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        removeButton.tag = model.userId
        removeButton.addTarget(self, action: #selector(removeAccountButtonTapped(_:)), for: .touchUpInside)
        removeButton.bearyAddPressFeedback()
        rowView.addSubview(removeButton)
        NSLayoutConstraint.activate([
            rowContent.topAnchor.constraint(equalTo: rowView.topAnchor),
            rowContent.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            rowContent.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -52),
            rowContent.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
            switchButton.topAnchor.constraint(equalTo: rowView.topAnchor),
            switchButton.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            switchButton.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -52),
            switchButton.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
            removeButton.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 44),
            removeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        return rowView
    }

    private func makeAddAccountRow() -> UIView {
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        titleLabel.text = "添加账号"
        let detailLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        detailLabel.text = "登录另一个账号，当前账号保持登录"
        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        let content = UIStackView(arrangedSubviews: [textStack, makeRowSpacer(), makeRowChevron()])
        content.axis = .horizontal
        content.spacing = 8
        content.alignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false
        let addButton = UIButton(type: .system)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.addTarget(self, action: #selector(addAccountButtonTapped), for: .touchUpInside)
        addButton.bearyAddPressFeedback()
        return makeSettingsTappableRow(content: content, button: addButton)
    }

    /// 有效账号数 = 保管库 + 尚未快照的当前账号（去重）；满 3 个即满额。
    private func effectiveAccountCount() -> Int {
        var ids = Set(BearyAccountVault.shared.loadAll().map { $0.userId })
        if let currentId = SessionManager.shared.currentUser?.id ?? meUser?.id {
            ids.insert(currentId)
        }
        return ids.count
    }

    @objc private func switchAccountButtonTapped(_ sender: UIButton) {
        let accountIdValue = sender.tag
        guard !isSwitchingAccount else { return }
        if SessionManager.shared.currentUser?.id == accountIdValue {
            return
        }
        isSwitchingAccount = true
        SessionManager.shared.switchToAccount(userId: accountIdValue) { [weak self] result in
            guard let self = self else { return }
            self.isSwitchingAccount = false
            switch result {
            case .switched:
                self.loadAll()
                self.refreshAccountSwitchSection()
            case .alreadyCurrent:
                self.refreshAccountSwitchSection()
            case .expired:
                self.showToast("登录已过期，请重新登录")
                self.openLoginForAccountSwitch()
            case .network:
                self.showToast("网络不稳定，请稍后再试")
            case .failed, .unavailable:
                self.showToast("切换失败，请稍后再试")
            }
        }
    }

    @objc private func addAccountButtonTapped() {
        SessionManager.shared.snapshotCurrentAccount()
        if effectiveAccountCount() >= BearyAccountVault.maxAccounts {
            let alert = UIAlertController(title: "添加账号", message: "最多 3 个账号，先移除一个", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: BearyMotion.animated(true))
            return
        }
        openLoginForAccountSwitch()
    }

    /// 添加 / 过期重登都走容器登录页（与 onRequireLogin 同路径）；容器
    /// 未接线时页内模态兜底（编辑页同款），登录成功后刷新本页与列表。
    private func openLoginForAccountSwitch() {
        if let handler = onRequireLogin {
            handler()
            return
        }
        let loginVC = BearyLoginViewController()
        loginVC.modalPresentationStyle = .fullScreen
        loginVC.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        loginVC.onCancelled = { [weak loginVC] in loginVC?.dismiss(animated: BearyMotion.animated(true)) }
        loginVC.onLoggedIn = { [weak self, weak loginVC] in
            loginVC?.dismiss(animated: BearyMotion.animated(true)) {
                SessionManager.shared.refreshMe()
                self?.loadAll()
                self?.refreshAccountSwitchSection()
            }
        }
        present(loginVC, animated: BearyMotion.animated(true))
    }

    @objc private func removeAccountButtonTapped(_ sender: UIButton) {
        let accountIdValue = sender.tag
        guard !isRemovingAccount else { return }
        let isCurrent = SessionManager.shared.currentUser?.id == accountIdValue
        let title = isCurrent ? "移除当前账号" : "移除账号"
        let message = "该账号将在本设备退出登录，其他账号不受影响。"
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.isRemovingAccount = true
            SessionManager.shared.removeAccount(userId: accountIdValue) { [weak self] result in
                guard let self = self else { return }
                self.isRemovingAccount = false
                switch result {
                case .removed:
                    self.refreshAccountSwitchSection()
                case .removedAndSwitched:
                    self.loadAll()
                    self.refreshAccountSwitchSection()
                case .removedAndLoggedOut:
                    if let handler = self.onLoggedOut {
                        handler()
                    } else {
                        self.onClose?()
                    }
                case .failed:
                    self.showToast("退出失败，请重试")
                }
            }
        })
        present(alert, animated: BearyMotion.animated(true))
    }

    /// 2026-10-29 第 12 项（合并 B）：退出登录 + 注销账户并入「账号操作」卡片，
    /// 仍列在设置页内（页底、版本脚注之上）。行为一字不动：退出仍走
    /// logoutButtonTapped（BearyAPI.logout + 清 cookie + 本地退出）；注销仍走
    /// deleteButtonTapped（两步确认 + 7 天冷静期软删除）；管理员隐藏注销行
    /// （连同其前分隔线一并藏，不留 stray 线，见 setAccountActionDeleteHidden）。
    private func buildAccountActionSection() {
        accountActionWrap.translatesAutoresizingMaskIntoConstraints = false
        accountActionWrap.isHidden = true
        logoutStandaloneButton.translatesAutoresizingMaskIntoConstraints = false
        logoutStandaloneButton.setTitle("退出登录", for: .normal)
        logoutStandaloneButton.addTarget(self, action: #selector(logoutButtonTapped), for: .touchUpInside)
        logoutStandaloneButton.bearyAddPressHaptic()
        deleteRowButton.translatesAutoresizingMaskIntoConstraints = false
        deleteRowButton.setTitle("注销账户", for: .normal)
        deleteRowButton.setTitleColor(BearyColors.gray, for: .normal)
        deleteRowButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        deleteRowButton.addTarget(self, action: #selector(deleteButtonTapped), for: .touchUpInside)
        deleteRowButton.bearyAddPressHaptic()
        let logoutRow = UIView()
        logoutRow.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.addSubview(logoutStandaloneButton)
        NSLayoutConstraint.activate([
            logoutStandaloneButton.topAnchor.constraint(equalTo: logoutRow.topAnchor),
            logoutStandaloneButton.centerXAnchor.constraint(equalTo: logoutRow.centerXAnchor),
            logoutStandaloneButton.widthAnchor.constraint(equalToConstant: 220),
            logoutStandaloneButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.regular).height),
            logoutStandaloneButton.bottomAnchor.constraint(equalTo: logoutRow.bottomAnchor),
        ])
        let deleteRow = UIView()
        deleteRow.translatesAutoresizingMaskIntoConstraints = false
        deleteRow.addSubview(deleteRowButton)
        NSLayoutConstraint.activate([
            deleteRowButton.topAnchor.constraint(equalTo: deleteRow.topAnchor),
            deleteRowButton.centerXAnchor.constraint(equalTo: deleteRow.centerXAnchor),
            deleteRowButton.bottomAnchor.constraint(equalTo: deleteRow.bottomAnchor),
        ])
        let group = makeGroupCard(title: "账号操作", rows: [logoutRow, deleteRow])
        accountActionDeleteWrap = group.wrappers.count > 1 ? group.wrappers[1] : nil
        // 注销行前的分隔线：卡内栈里注销包容器前一位即分隔线，管理员隐藏时一并藏。
        if let stack = group.card.subviews.first(where: { $0 is UIStackView }) as? UIStackView,
           let deleteWrap = accountActionDeleteWrap,
           let deleteIndex = stack.arrangedSubviews.firstIndex(of: deleteWrap),
           deleteIndex > 0 {
            accountActionDeleteSeparator = stack.arrangedSubviews[deleteIndex - 1]
        }
        group.card.translatesAutoresizingMaskIntoConstraints = false
        accountActionWrap.addSubview(group.card)
        // 审计 P2-22：退出后本机残留明示——日记/回收站/图片缓存随退出清除，
        // 未发布草稿仍保存在本设备（按账号分桶，换号不可见），登录同一账号可继续编辑。
        let logoutFootnote = UILabel()
        logoutFootnote.translatesAutoresizingMaskIntoConstraints = false
        // P1-7：账号操作组脚注辅助文案走动态字体（已是 0 行）。
        logoutFootnote.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        logoutFootnote.adjustsFontForContentSizeCategory = true
        logoutFootnote.textColor = BearyColors.gray
        logoutFootnote.numberOfLines = 0
        logoutFootnote.text = "退出登录后，已同步的日记与回收站缓存会从本设备清除；未发布的草稿仍保存在本设备，登录同一账号后可继续编辑。"
        accountActionWrap.addSubview(logoutFootnote)
        NSLayoutConstraint.activate([
            group.card.topAnchor.constraint(equalTo: accountActionWrap.topAnchor),
            group.card.leadingAnchor.constraint(equalTo: accountActionWrap.leadingAnchor),
            group.card.trailingAnchor.constraint(equalTo: accountActionWrap.trailingAnchor),
            logoutFootnote.topAnchor.constraint(equalTo: group.card.bottomAnchor, constant: 8),
            logoutFootnote.leadingAnchor.constraint(equalTo: accountActionWrap.leadingAnchor, constant: 16),
            logoutFootnote.trailingAnchor.constraint(equalTo: accountActionWrap.trailingAnchor, constant: -16),
            logoutFootnote.bottomAnchor.constraint(equalTo: accountActionWrap.bottomAnchor),
        ])
    }

    /// 注销行显隐（管理员隐藏）：行包容器 + 其前分隔线一并藏，不留 stray 线。
    private func setAccountActionDeleteHidden(_ hidden: Bool) {
        accountActionDeleteWrap?.isHidden = hidden
        accountActionDeleteSeparator?.isHidden = hidden
    }

    /// 2026-10-29 第 10 项：页底版本脚注——版本唯一出处（通用组版本行已删），
    /// Bundle 动态读，不写死；格式与旧行同值（对外版本 + 构建号）。
    private func buildVersionFooter() {
        versionFooterWrap.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        // P1-7：页底版本脚注辅助文案走动态字体 + 多行（默认 1 行会截断大字号）。
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        let versionShort = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let versionBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        label.text = "版本 \(versionShort)（构建号 \(versionBuild)）"
        versionFooterWrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: versionFooterWrap.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: versionFooterWrap.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: versionFooterWrap.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: versionFooterWrap.bottomAnchor, constant: -16),
        ])
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



    /// C4：ID 卡右侧“编辑资料”钮（旧账户组编辑 / 修改钮已随组删除）。
    @objc private func editProfileButtonTapped() {
        openEditPage()
    }

    /// C2：通用组内「使用指南」行，容器接线到教程重播页。
    @objc private func tutorialButtonTapped() {
        onShowTutorial?()
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
        // 审计 P2-16：全屏 modal 补 fadeRise。
        editVC.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        editVC.onSaved = { [weak self, weak editVC] in
            editVC?.dismiss(animated: BearyMotion.animated(true)) {
                self?.loadAll()
            }
        }
        editVC.onCancel = { [weak editVC] in
            editVC?.dismiss(animated: BearyMotion.animated(true))
        }
        editVC.onRequireLogin = { [weak self, weak editVC] in
            editVC?.dismiss(animated: BearyMotion.animated(true)) {
                self?.onRequireLogin?()
            }
        }
        present(editVC, animated: BearyMotion.animated(true))
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

    // MARK: - 加载

    private func loadAll() {
        guard !isLoadingMe else { return }
        isLoadingMe = true
        // 缓存优先：登录态下本机已有同一份用户信息（SessionManager.currentUser），
        // 先显缓存、不转菊花，随后静默 fetchMe 对齐；无缓存时走现行加载态路径。
        if let cached = SessionManager.shared.currentUser {
            meUser = cached
            failureWrap.isHidden = true
            loginWrap.isHidden = true
            loadingView.stopSpinning()
            loadingView.isHidden = true
            contentWrap.isHidden = false
            accountSecurityWrap.isHidden = false
            accountActionWrap.isHidden = false
            fillIdCard(user: cached)
            // 注销入口：只用 is_admin，缓存与刷新后同一口径（见下）。
            setAccountActionDeleteHidden(cached.isAdmin == true)
            loadPlusDetail()
            loadSessions()
            BearyAPI.shared.fetchMe { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isLoadingMe = false
                    switch result {
                    case .success(let user):
                        guard let userValue = user else {
                            // 服务端回空：保持缓存内容不变，不弹登录态
                            // （会话存亡走全局 401 流程，不由本页静默刷新改写）。
                            return
                        }
                        self.meUser = userValue
                        self.fillIdCard(user: userValue)
                        self.setAccountActionDeleteHidden(userValue.isAdmin == true)
                        self.loadPlusDetail()
                        self.loadSessions()
                        // 切换卡跟随用户信息刷新（首次进页时 viewWillAppear 已跑
                        // 在异步 /me 之前，缓存路径靠 viewWillAppear、非缓存
                        // 路径靠这里，否则卡片首屏缺失）。
                        self.refreshAccountSwitchSection()
                    case .failure(let error):
                        if case .cancelled = error { return }
                        // 静默刷新失败：保持缓存内容不变，不显示 failureWrap。
                        return
                    }
                }
            }
            return
        }
        loadingView.startSpinning()
        loadingView.isHidden = false
        failureWrap.isHidden = true
        loginWrap.isHidden = true
        contentWrap.isHidden = true
        accountSecurityWrap.isHidden = true
        accountActionWrap.isHidden = true
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoadingMe = false
                self.loadingView.stopSpinning()
                self.loadingView.isHidden = true
                switch result {
                case .success(let user):
                    guard let userValue = user else {
                        self.loginWrap.isHidden = false
                        return
                    }
                    self.meUser = userValue
                    self.contentWrap.isHidden = false
                    self.accountSecurityWrap.isHidden = false
                    self.accountActionWrap.isHidden = false
                    self.fillIdCard(user: userValue)
                    self.refreshAccountSwitchSection()
                    // 注销入口：只用 /me 下发的 is_admin（服务端算出），客户端不写 id 判定；
                    // 服务端 403 admin_cannot_delete 仍是最终判定（见 delete 失败映射）。
                    // C3：注销行隐藏（行包容器 + 其前分隔线一并藏，见 setAccountActionDeleteHidden）。
                    self.setAccountActionDeleteHidden(userValue.isAdmin == true)
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
        // 审计追加：与编辑页同法——/me 下发的 avatar 本就是 data:image;base64，
        // 直接解码显示，不再跳过 data: 只剩首字母占位；解码失败回落原路径。
        if let avatar = user.avatar, !avatar.isEmpty, avatar.hasPrefix("data:"),
           let commaIndex = avatar.firstIndex(of: ","),
           let avatarData = Data(base64Encoded: String(avatar[avatar.index(after: commaIndex)...])),
           let avatarImage = UIImage(data: avatarData) {
            avatarImageView.image = avatarImage
        } else if let avatar = user.avatar, !avatar.isEmpty {
            avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(avatar))
        }
        idCreatedLabel.text = BearyAccountText.dateString(ms: user.createdAt)
        // ID 卡会员行：只留状态词（Plus 会员 / 普通用户），不走 plus-detail；
        // 全修 3-2：到期日、永久、内测限免一律只留在 Plus 组，不在此重复。
        idPlusLabel.text = user.plus == true ? "Plus 会员" : "普通用户"
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

    // C4：fillAccountRows 已随旧账户组删除（显示名称 / 用户名 / 邮箱 /
    // 注册时间四行不再渲染；ID 卡 fillIdCard 仍呈现名 / 邮箱 / 注册时间 / 会员）。

    private func loadPlusDetail() {
        // 静默刷新：已有旧值时不先清标签/发放行，新值到了再覆盖；
        // 首拉（plusDetail 为 nil）才走现行置“–”+ 空发放态。
        if plusDetail == nil {
            plusStatusLabel.text = "–"
            plusFreeLabel.text = "–"
            plusPersonalLabel.text = "–"
            rebuildGrants(grants: nil, failed: false)
        }
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
                    if self.plusDetail != nil { return }
                    self.plusStatusLabel.text = "加载失败"
                    self.grantsLoadFailed = true
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

    /// 2026-10-29 第 7 项：来源明细已抽成独立页——本函数不再内联建发放行，
    /// 只缓存数据与失败态（子页打开时传入；未拉到时子页自己拉一次）。
    /// 行格式（来源名 15 墨 + 「日期 · +N 天」13 灰、空态「暂无发放记录」、
    /// 失败态「加载失败」+ 重试）已原样搬进 BearyPlusGrantsViewController。
    private func rebuildGrants(grants: [BearyPlusGrant]?, failed: Bool) {
        cachedGrants = grants
        grantsLoadFailed = failed
    }

    private func loadSessions() {
        // 首拉前不再预先 rebuildSessions(nil)：空标签只在拉取返回空后出现，
        // 失败态只在拉取失败后出现（现行失败分支不动）；静默刷新不再先清旧内容。
        BearyAPI.shared.fetchAccountSessions { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    let list = resp.sessions ?? []
                    self.accountSessions = list
                    self.sessionsLoadFailed = false
                    // 全修 4-4（二选一取“计数文案标活跃、列表不过滤”）：/api/account/sessions
                    // 下发 activeCount（与 sessions 全量分开的字段，过期行以 expired 另标灰化），
                    // 故计数用 activeCount 并标“（活跃）”，列表仍含过期行（灰化 + “已过期”注，
                    // 用户可见完整登录史，不过滤）；activeCount 缺失时才回落全量计数，此时不标
                    // “（活跃）”（回落值含过期行，标活跃会误导）。
                    if let active = resp.activeCount {
                        self.deviceCountLabel.text = "共 \(active) 台设备（活跃）"
                    } else {
                        self.deviceCountLabel.text = "共 \(list.count) 台设备"
                    }
                    self.rebuildSessions(sessions: list, failed: false)
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                        return
                    }
                    if case .cancelled = error { return }
                    self.sessionsLoadFailed = true
                    self.rebuildSessions(sessions: nil, failed: true)
                }
            }
        }
    }

    /// 2026-10-29 第 11 项：设备列表已抽成独立页——本函数不再内联建设备行，
    /// 只缓存失败态（列表数据走既有 accountSessions；子页打开时传入，未拉到
    /// 时子页自己拉一次）。行格式（设备名 15 墨 + 当前绿 pill + 「地区 ·
    /// 上次活跃 dateTime」13 灰、过期行 alpha 0.55、空态与失败重试）已原样
    /// 搬进 BearyDevicesViewController；原错峰淡入 fadeInNewStackRows 随内联
    /// 列表一并删除（子页内无此动效）。
    private func rebuildSessions(sessions: [BearyAccountSession]?, failed: Bool) {
        sessionsLoadFailed = failed
    }

    // MARK: - 退出其他设备

    @objc private func logoutOthersButtonTapped() {
        guard !isLoggingOutOthers else { return }
        let alert = UIAlertController(title: "退出其他设备", message: "将退出除当前设备外的所有登录，确定继续？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive, handler: { [weak self] _ in
            self?.confirmLogoutOthers()
        }))
        present(alert, animated: BearyMotion.animated(true))
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
        present(first, animated: BearyMotion.animated(true))
    }

    private func showDeleteSecondConfirm() {
        let second = UIAlertController(title: "最后确认", message: "真的要注销吗？此操作 7 天后不可撤销。", preferredStyle: .alert)
        second.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        second.addAction(UIAlertAction(title: "确认注销", style: .destructive, handler: { [weak self] _ in
            self?.confirmDeleteAccount()
        }))
        present(second, animated: BearyMotion.animated(true))
    }

    private func confirmDeleteAccount() {
        isDeleting = true
        BearyAPI.shared.requestAccountDelete { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    // 验证组④：注销返回的 delete_at 必须持久化——/me 不下发该字段，
                    // 不存则退出后冷静期截止日无从得知；登录成功（注销取消）时清除，见登录页。
                    if let deleteAt = resp.deleteAt {
                        UserDefaults.standard.set(deleteAt, forKey: "bearyPendingDeleteAt")
                    }
                    // 网页口径：提示后 1.2 秒回首页；原生等价为提示后走 onAccountDeleted（容器清态并关闭本页）。
                    // 审计 P2：1.2 秒窗口内 isDeleting 保持 true，直至 onAccountDeleted 执行后才复位，
                    // 防止窗口内重复点注销。
                    self.showToast("已提交注销申请，7 天后正式注销")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.onAccountDeleted?()
                        self?.isDeleting = false
                    }
                case .failure(let error):
                    self.isDeleting = false
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
        setExportProgress("正在导出…")
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
        setExportProgress(nil)
        showToast("导出失败，请重试")
    }

    /// 2026-10-29（P2-13）：导出进度提示——串行四阶段在行副文案上轮换，结束（失败/触顶确认前）复原；
    /// 只改副文案文字，不重建行、不播动效；nil = 复原默认文案。
    /// 审计三轮第 24 项：直出成功路径不再于四阶段结束时复原，buildAndShareExport
    /// 置“正在生成文件…”、文件写完（成功 present 前 / 失败 toast 前）才复原。
    private func setExportProgress(_ text: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.exportDetailLabel?.text = text ?? "下载 JSON，含账户、日记、点赞记录"
        }
    }

    private func exportWithUser(_ user: MeUser) {
        var sessionsResp: BearyAccountSessionsResponse?
        var mineEntries: [Entry] = []
        var mailboxEntries: [Entry] = []
        var likedEntries: [Entry] = []
        // 第 7 项：分页结果不再静默丢弃——任一 scope 失败即整单 fail-closed，
        // 任一 scope 触顶即整单走部分导出标注；失败优先于触顶（先判失败）。
        var exportFailedReason: String?
        var exportTruncated = false
        var sessionsFailed = false
        // 审计 B 批：4 路并行回调改串行汇集——会话 → 我的 → 信箱 → 赞过依次
        // 拉取，共享变量只在同一串行链上写，不再并发；判定口径不变（失败
        // 优先于触顶；分页失败与触顶同现时以失败为准，不出文件）。
        let applyScopeResult: (BearyExportPageResult, inout [Entry]) -> Void = { result, entries in
            entries = result.entries
            if !result.complete {
                if result.reason == "已达 20 页上限" {
                    exportTruncated = true
                } else {
                    exportFailedReason = result.reason ?? "分页失败"
                }
            }
        }
        let finish: () -> Void = { [weak self] in
            guard let self = self else { return }
            // 失败 fail-closed：只 toast、不拼 JSON、不出文件、不出分享面板。
            if sessionsFailed {
                self.isExporting = false
                self.exportRowButton.isEnabled = true
                self.setExportProgress(nil)
                self.showToast("导出失败（登录设备拉取失败），未生成文件")
                return
            }
            if let failedReason = exportFailedReason {
                self.isExporting = false
                self.exportRowButton.isEnabled = true
                self.setExportProgress(nil)
                self.showToast("导出失败（\(failedReason)），未生成文件")
                return
            }
            // 触顶：分享前先弹明确标注，用户点“继续分享”才拼文件、出分享面板；
            // 点取消则不出文件。N = 三个 scope 已取篇数之和（即文件内总篇数）。
            // 确认前先复原（与旧口径一致）；确认后 buildAndShareExport 会重新
            // 置“正在生成文件…”并在文件写完后复原，取消则保持复原态。
            if exportTruncated {
                self.isExporting = false
                self.exportRowButton.isEnabled = true
                self.setExportProgress(nil)
                let totalCount = mineEntries.count + mailboxEntries.count + likedEntries.count
                let alert = UIAlertController(title: "部分导出", message: "部分导出（已取 \(totalCount) 篇，已达 20 页上限），是否继续分享部分数据？", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
                alert.addAction(UIAlertAction(title: "继续分享", style: .default, handler: { [weak self] _ in
                    self?.buildAndShareExport(user: user, sessionsResp: sessionsResp, mineEntries: mineEntries, mailboxEntries: mailboxEntries, likedEntries: likedEntries)
                }))
                self.present(alert, animated: BearyMotion.animated(true))
                return
            }
            self.buildAndShareExport(user: user, sessionsResp: sessionsResp, mineEntries: mineEntries, mailboxEntries: mailboxEntries, likedEntries: likedEntries)
        }
        setExportProgress("正在导出（1/4）登录设备…")
        BearyAPI.shared.fetchAccountSessions { [weak self] result in
            guard let self = self else { return }
            // 审计 P1-23：会话拉取失败不得静默丢弃 sessions 让 JSON 看似完整——
            // 整单 fail-closed，只 toast、不拼 JSON、不出文件（与三个日记 scope 同口径）。
            if case .success(let resp) = result {
                sessionsResp = resp
            } else {
                sessionsFailed = true
            }
            self.setExportProgress("正在导出（2/4）我的日记…")
            self.fetchAllEntries(scope: .mine) { result in
                applyScopeResult(result, &mineEntries)
                self.setExportProgress("正在导出（3/4）信箱…")
                self.fetchAllEntries(scope: .mailbox) { result in
                    applyScopeResult(result, &mailboxEntries)
                    self.setExportProgress("正在导出（4/4）赞过…")
                    self.fetchAllEntries(scope: .liked) { result in
                        applyScopeResult(result, &likedEntries)
                        DispatchQueue.main.async { finish() }
                    }
                }
            }
        }
    }

    /// 导出文件拼装 + 分享面板（原 exportWithUser 内 group.notify 后半段原样挪出，
    /// JSON/写文件两处“导出失败，请重试”文案与触发条件均不动；仅调用点改为
    /// 成功直出、触顶经用户确认后出，失败路径根本不进本方法）。
    /// 审计三轮第 24 项：字典映射、JSONSerialization、String 转码、fileData.write
    /// 全移后台队列（userInitiated），主线程只做进度文案、复原与 present 分享面板；
    /// 后台失败回主线程走原失败分支（同文案 toast + 复原），成功回主线程复原后 present。
    /// 拼装函数只读传入的模型值（export*Dict 均为纯字典映射，不碰 UI），可安全离主线程。
    private func buildAndShareExport(user: MeUser, sessionsResp: BearyAccountSessionsResponse?, mineEntries: [Entry], mailboxEntries: [Entry], likedEntries: [Entry]) {
        // 主线程：进入生成阶段——直出路径沿用已置的 isExporting/禁用态，触顶确认
        // 路径在此重新置位；两种路径都在文件写完后统一复原。
        isExporting = true
        exportRowButton.isEnabled = false
        setExportProgress("正在生成文件…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
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
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isExporting = false
                    self.exportRowButton.isEnabled = true
                    self.setExportProgress(nil)
                    self.showToast("导出失败，请重试")
                }
                return
            }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd-HHmmss"
            // 审计 P2：文件名加时间戳 + UUID 后缀，分享面板未收起时再导出不互相覆盖/删除。
            let fileName = "teddyhn-data-" + fmt.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8)) + ".json"
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            var text = "\u{feff}"
            text += String(data: jsonData, encoding: .utf8) ?? ""
            guard let fileData = text.data(using: .utf8), (try? fileData.write(to: fileURL)) != nil else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isExporting = false
                    self.exportRowButton.isEnabled = true
                    self.setExportProgress(nil)
                    self.showToast("导出失败，请重试")
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isExporting = false
                self.exportRowButton.isEnabled = true
                self.setExportProgress(nil)
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
                self.present(activity, animated: BearyMotion.animated(true))
            }
        }
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

    // MARK: - 轻提示：委托统一 BearyToast。旧 Timer 重置语义由统一
    // 组件“新 toast 先清旧 toast”承接。设置页是全屏模态，盖住 Chrome，
    // 落点由组件回落安全区 -32；展示时长由旧 1.6s 统一为 2.0s，
    // 调用签名与文案、触发时机不变。

    private func showToast(_ text: String) {
        BearyToast.show(in: view, message: text)
    }

    // MARK: - 设置页新增三区（2026-10-26，第二阶段）

    private func settingsInterfaceStyle(for mode: String) -> UIUserInterfaceStyle {
        switch mode {
        case "light": return .light
        case "dark": return .dark
        default: return .unspecified
        }
    }

    /// 内层可点行包容器（沿用退出登录行的 wrap 口径：内容 + 全幅透明按钮）。
    /// 2026-10-29 第 7、11 项：行尾官方包右箭头（icon_chevron_right 16pt 灰，
    /// pickers/search 同款），不要自绘；配 makeRowSpacer 吸剩余宽度、把箭头顶到行尾。
    private func makeRowChevron() -> UIImageView {
        let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
        ])
        return chevron
    }

    private func makeRowSpacer() -> UIView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        return spacer
    }

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
        // 消息角标：本地开关，门控顶栏消息铃铛未读数显示（SceneDelegate.chrome.updateBellBadge 内查档）。
        let badgeTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        badgeTitle.text = "消息角标"
        badgeTitle.numberOfLines = 0 // P1-7：开关行正文标题多行
        let badgeDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        badgeDetail.text = "顶栏消息铃铛显示未读数"
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

        // 全修 3-4：全仓 grep 无任何本地/远程通知调用（无 UNUserNotificationCenter、
        // UserNotifications import、registerForRemoteNotifications、推送 entitlement），
        // App 不发任何通知，系统设置里的通知开关对本 App 无效，故“系统通知设置”行
        // 整行删除，不留无效入口；消息角标开关是应用内铃铛未读数门控，与系统推送无关，保留。
        let group = makeGroupCard(title: "消息与通知", rows: [badgeRow])
        generalNotifyWrap.addArrangedSubview(group.card)
    }

    private func buildGeneralSection() {
        let current = UserDefaults.standard.string(forKey: "beary_theme_mode") ?? "system"
        let modes: [(value: String, title: String)] = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
        // 主题三行合并为一段三段滑块：跟随系统 / 浅色 / 深色全保留，
        // 选中档位与旧三行同款持久化与应用路径（见 themeSegmentChanged），
        // 滑块指示动画只走系统分段动画。
        let themeSegmented = UISegmentedControl(items: modes.map { $0.title })
        themeSegmented.translatesAutoresizingMaskIntoConstraints = false
        themeSegmented.selectedSegmentIndex = modes.firstIndex(where: { $0.value == current }) ?? 0
        themeSegmented.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 15)], for: .normal)
        // 三色制：选中段走墨底 + 反色字（2026-10-28 定版：墨=行动/选中，橙底已改回墨；反色字取 bg，浅白深黑，与 ink 互为反色，深浅两态都可读）。
        themeSegmented.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: BearyColors.bg], for: .selected)
        themeSegmented.selectedSegmentTintColor = BearyColors.ink
        themeSegmented.addTarget(self, action: #selector(themeSegmentChanged(_:)), for: .valueChanged)
        var rows: [UIView] = [themeSegmented]
        // C2：使用指南行（原齿轮菜单项，改由设置页承载；容器接线到教程重播页）。
        let tutorialDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        tutorialDetail.text = "查看"
        let tutorialContent = makeRow(title: "使用指南", detailLabel: tutorialDetail, iconName: "icon_help")
        let tutorialButton = UIButton(type: .custom)
        tutorialButton.accessibilityLabel = "使用指南"
        tutorialButton.addTarget(self, action: #selector(tutorialButtonTapped), for: .touchUpInside)
        tutorialButton.bearyAddPressHaptic()
        rows.append(makeSettingsTappableRow(content: tutorialContent, button: tutorialButton))
        // 2026-10-29 音效包接入：音效开关行（默认开，关后全部音效静默；只门控音效，不动震动）。
        let soundSwitchTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        soundSwitchTitle.text = "音效"
        soundSwitchTitle.numberOfLines = 0 // P1-7：开关行正文标题多行
        let soundSwitchDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        soundSwitchDetail.text = "点按、发布等操作的提示音"
        let soundSwitchTextStack = UIStackView(arrangedSubviews: [soundSwitchTitle, soundSwitchDetail])
        soundSwitchTextStack.axis = .vertical
        soundSwitchTextStack.spacing = 2
        soundSwitchTextStack.alignment = .fill
        let soundSwitch = UISwitch()
        soundSwitch.isOn = BearySoundPlayer.isEnabled
        soundSwitch.setContentHuggingPriority(.required, for: .horizontal)
        soundSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        soundSwitch.addTarget(self, action: #selector(soundSwitchValueChanged(_:)), for: .valueChanged)
        let soundSwitchRow = UIStackView(arrangedSubviews: [soundSwitchTextStack, soundSwitch])
        soundSwitchRow.translatesAutoresizingMaskIntoConstraints = false
        soundSwitchRow.axis = .horizontal
        soundSwitchRow.spacing = 12
        soundSwitchRow.alignment = .center
        rows.append(soundSwitchRow)
        // 2026-10-29 第 10 项：通用组版本行已删，版本只留页底脚注一处
        // （见 buildVersionFooter，Bundle 动态读，不写死）。
        // D2：诊断日志开关行（复用消息角标开关行样式：标题 + 说明 + UISwitch；
        // 放在诊断日志查看行正上方，开关关闭时 DiagFile 不再写入，默认开）。
        let diagSwitchTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        diagSwitchTitle.text = "记录诊断日志"
        diagSwitchTitle.numberOfLines = 0 // P1-7：开关行正文标题多行
        let diagSwitchDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        diagSwitchDetail.text = "关闭后不再写入日志文件"
        let diagSwitchTextStack = UIStackView(arrangedSubviews: [diagSwitchTitle, diagSwitchDetail])
        diagSwitchTextStack.axis = .vertical
        diagSwitchTextStack.spacing = 2
        diagSwitchTextStack.alignment = .fill
        let diagSwitch = UISwitch()
        diagSwitch.isOn = DiagFile.isEnabled
        diagSwitch.setContentHuggingPriority(.required, for: .horizontal)
        diagSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        diagSwitch.addTarget(self, action: #selector(diagSwitchValueChanged(_:)), for: .valueChanged)
        let diagSwitchRow = UIStackView(arrangedSubviews: [diagSwitchTextStack, diagSwitch])
        diagSwitchRow.translatesAutoresizingMaskIntoConstraints = false
        diagSwitchRow.axis = .horizontal
        diagSwitchRow.spacing = 12
        diagSwitchRow.alignment = .center
        // 94 包：诊断日志行（点进专门页面看全部日志，不再只给 20 行尾巴）。
        let diagDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        diagDetail.text = "查看"
        let diagContent = makeRow(title: "诊断日志", detailLabel: diagDetail, iconName: "icon_list")
        let diagButton = UIButton(type: .custom)
        diagButton.accessibilityLabel = "诊断日志"
        diagButton.addTarget(self, action: #selector(openDiagnosticsPage), for: .touchUpInside)
        diagButton.bearyAddPressHaptic()
        let diagRow = makeSettingsTappableRow(content: diagContent, button: diagButton)
        let group = makeGroupCard(title: "通用", rows: rows)
        generalNotifyWrap.addArrangedSubview(group.card)
        // 2026-10-29 第 12 项（合并 A）：诊断日志两行（开关 + 查看）主题相关、
        // 原在通用组内零散成行，抽出并成独立的「诊断日志」卡片，仍列在设置页内
        // （通用卡之后、消息与通知卡之前，顺序由 buildLayout 的 wrap 顺序定）。
        let diagGroup = makeGroupCard(title: "诊断日志", rows: [diagSwitchRow, diagRow])
        generalNotifyWrap.addArrangedSubview(diagGroup.card)
    }

    private func buildPrivacySection() {
        let privacyDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        privacyDetail.text = "查看"
        let privacyContent = makeRow(title: "隐私政策", detailLabel: privacyDetail, iconName: "icon_eye_off")
        let privacyButton = UIButton(type: .custom)
        privacyButton.accessibilityLabel = "隐私政策"
        privacyButton.addTarget(self, action: #selector(openPrivacyText), for: .touchUpInside)
        privacyButton.bearyAddPressHaptic()
        let privacyRow = makeSettingsTappableRow(content: privacyContent, button: privacyButton)
        let termsDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        termsDetail.text = "查看"
        let termsContent = makeRow(title: "用户协议", detailLabel: termsDetail, iconName: "icon_file_text")
        let termsButton = UIButton(type: .custom)
        termsButton.accessibilityLabel = "用户协议"
        termsButton.addTarget(self, action: #selector(openTermsText), for: .touchUpInside)
        termsButton.bearyAddPressHaptic()
        let termsRow = makeSettingsTappableRow(content: termsContent, button: termsButton)
        // iCity：已拉黑用户行（解除入口，不放他人主页）。
        let blockedDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        blockedDetail.text = "查看"
        let blockedContent = makeRow(title: "已拉黑用户", detailLabel: blockedDetail, iconName: "icon_block")
        let blockedButton = UIButton(type: .custom)
        blockedButton.accessibilityLabel = "已拉黑用户"
        blockedButton.addTarget(self, action: #selector(openBlockedUsers), for: .touchUpInside)
        blockedButton.bearyAddPressHaptic()
        let blockedRow = makeSettingsTappableRow(content: blockedContent, button: blockedButton)
        let group = makeGroupCard(title: "隐私", rows: [privacyRow, termsRow, blockedRow])
        privacyWrap.addArrangedSubview(group.card)
    }

    @objc private func openBlockedUsers() {
        let vc = BearyBlockedUsersViewController()
        vc.modalPresentationStyle = .fullScreen
        // 审计 P2-16：全屏 modal 补 fadeRise（与诊断/反馈/明细页同款）。
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    @objc private func badgeSwitchValueChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "beary_unread_badge_enabled")
        SceneDelegate.chrome?.reapplyBellBadge()
    }

    @objc private func soundSwitchValueChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: BearySoundPlayer.enabledDefaultsKey)
    }

    /// D2：诊断日志开关——只存档；DiagFile 每次写入时实时读档，关后新写入即停
    ///（关前已入队的一两条在途写入可能仍落盘，属队列时序，不新产生写入）。
    @objc private func diagSwitchValueChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: DiagFile.enabledDefaultsKey)
    }

    /// 94 包：诊断日志专门页（与设置页同款淡入 + 上移；chrome 不在时退系统过渡）。
    @objc private func openDiagnosticsPage() {
        let vc = BearyDiagnosticsViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    // MARK: - 数据与反馈（2026-10-28 反馈 v3，路线 A）

    private func buildDataFeedbackSection() {
        let feedbackDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        feedbackDetail.text = "查看"
        let feedbackContent = makeRow(title: "反馈与改进", detailLabel: feedbackDetail, iconName: "icon_comment")
        let feedbackButton = UIButton(type: .custom)
        feedbackButton.accessibilityLabel = "反馈与改进"
        feedbackButton.addTarget(self, action: #selector(openFeedbackPage), for: .touchUpInside)
        feedbackButton.bearyAddPressHaptic()
        // 补缺第 21 项：功能许愿墙入口（反馈相邻行；官方包 icon_star，右箭头走 tappableRow 既有口径）。
        let wishDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        wishDetail.text = "查看"
        let wishContent = makeRow(title: "功能许愿墙", detailLabel: wishDetail, iconName: "icon_star")
        let wishButton = UIButton(type: .custom)
        wishButton.accessibilityLabel = "功能许愿墙"
        wishButton.addTarget(self, action: #selector(openWishWallPage), for: .touchUpInside)
        wishButton.bearyAddPressHaptic()
        let rows: [UIView] = [
            makeSettingsTappableRow(content: feedbackContent, button: feedbackButton),
            makeSettingsTappableRow(content: wishContent, button: wishButton),
        ]
        let group = makeGroupCard(title: "数据与反馈", rows: rows)
        dataFeedbackWrap.addArrangedSubview(group.card)
    }

    @objc private func openFeedbackPage() {
        let vc = BearyFeedbackViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    /// 补缺第 21 项：功能许愿墙列表页（反馈页同款全屏 modal + fadeRise）。
    @objc private func openWishWallPage() {
        let vc = BearyWishWallViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    /// 2026-10-29 第 7 项：会员来源明细独立页——优先用设置页已拉到的
    /// plusDetail（状态文案取现行标签值、发放取缓存）；未拉到时子页自己拉一次。
    @objc private func openPlusGrantsPage() {
        let vc = BearyPlusGrantsViewController(
            statusText: plusStatusLabel.text ?? "–",
            personalText: plusPersonalLabel.text ?? "–",
            grants: cachedGrants,
            failed: grantsLoadFailed)
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    /// 2026-10-29 第 11 项：登录设备独立页——优先用设置页已拉到的
    /// accountSessions；未拉到时子页自己拉一次；退出其他设备钮仍留在设置页。
    @objc private func openDevicesPage() {
        let vc = BearyDevicesViewController(
            sessions: accountSessions.isEmpty ? nil : accountSessions,
            failed: sessionsLoadFailed,
            countText: deviceCountLabel.text)
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    /// 主题滑块档位变化：与旧三行同款持久化与应用路径
    ///（写 beary_theme_mode + 窗口 overrideUserInterfaceStyle），仅去掉了对勾刷新
    ///（选中态改由滑块自身的 selectedSegmentIndex 呈现）。
    @objc private func themeSegmentChanged(_ sender: UISegmentedControl) {
        let modes = ["system", "light", "dark"]
        guard sender.selectedSegmentIndex >= 0, sender.selectedSegmentIndex < modes.count else { return }
        let mode = modes[sender.selectedSegmentIndex]
        UserDefaults.standard.set(mode, forKey: "beary_theme_mode")
        view.window?.overrideUserInterfaceStyle = settingsInterfaceStyle(for: mode)
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
        // 审计 P2-16：全屏 modal 补 fadeRise。
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }
}

/// 设置页隐私/协议原生文字页：纯原生 UITextView 渲染捆进 App 的文本，
/// 不开网页、不挂 WKWebView（App 独立化方向）。全屏 modal，关闭即 dismiss。
final class BearyLegalTextViewController: UIViewController {
    private let pageTitle: String
    private let pageText: String
    private let closeButton = BearyHit44Button(type: .system)
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
        closeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
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
        // 补缺 P2-17：子页内容列 600 居中、顶栏同宽居中（iPhone 全宽不变）。
        let legalTopBarWidthEquality = topBar.widthAnchor.constraint(equalTo: view.widthAnchor)
        legalTopBarWidthEquality.priority = UILayoutPriority(750)
        let legalTextWidthEquality = textView.widthAnchor.constraint(equalTo: view.widthAnchor)
        legalTextWidthEquality.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            legalTopBarWidthEquality,
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            textView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            textView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            legalTextWidthEquality,
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
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

beary 日记文字、图片。默认私密，仅本人可见；写完即按所选可见，公开与私密可随时切换

点赞记录你点赞的日记 ID、时间

小熊回应记录你贴出的小熊回应、日记 ID、时间

收藏记录你收藏的日记 ID、时间。收藏列表仅你本人可见，但收藏动作会通知日记作者

通知记录点赞、收藏、回应产生的互动通知，以及我们发送的系统通知

行为记录仅记操作类型、目标 ID 与时间（如打开 App、详情阅读停留时长、搜索结果点按），不记日记正文、标题与搜索词原文；游客阅读仅记匿名计数，用于年度报告与风控

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

管理：在 App 设置页退出登录即可清除登录会话；在 App 设置页外观主题中切换档位即可重置主题偏好。

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

私密日记删除后进回收站 30 天，期满彻底删除

公开日记删除后进回收站 30 天，期满彻底删除

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

私密日记与公开日记：均可自行删除，进回收站 30 天；

账户注销：登录后在 /account 自助注销。注销有 7 天冷静期：期间登录可取消，7 天后正式生效。生效后你的邮箱将被清空，日记保留但作者显示为"已注销用户"；

注意：公开后仍可改回私密，但公开期间已被查看或转载的内容无法收回，发布前请确认。

6.4 撤回同意权

在 App 设置页切换外观主题档位即可重置主题偏好，退出登录即可退出登录；

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

私密期默认私密，仅本人可见，可随时公开或改回私密

公开与私密写完选公开或私密，默认私密；公开与私密可随时切换

编辑期发布后 15 分钟内可编辑，超时锁死

删除公开与私密均可删除，进回收站 30 天；编辑仅 15 分钟内

评论本站不设文字评论功能

点赞需登录，仅可赞已公开的日记

小熊回应需登录，仅限已公开日记；每人每篇可贴多种回应，各自贴、撤

收藏需登录，仅限已公开日记；收藏列表仅你本人可见，但收藏动作会通知作者

分享已公开日记可通过单篇链接分享给任何人

主动公开私密日记可随时公开，公开后仍可改回私密；但公开期间已被查看或转载的内容无法收回

通知点赞、收藏、小熊回应会生成通知告知作者；我们也可通过通知栏发送系统消息（如欢迎信、重要变更）

2.2 发布前确认

因公开后仍可改回私密，但公开期间已被查看或转载的内容无法收回，发布前请务必确认：

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

// 94 包：诊断日志专门页（设置页通用分区进入；显示 DiagFile 全部保留日志，
// 打开时重读最新；复制全部进剪贴板，清空需二次确认）。
private final class BearyDiagnosticsViewController: UIViewController {
    private let textView = UITextView()
    private let copyButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "诊断日志"

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
        ])

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setTitle("复制全部", for: .normal)
        copyButton.setTitleColor(BearyColors.ink, for: .normal)
        copyButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.bearyAddPressFeedback()
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setTitle("清空", for: .normal)
        clearButton.setTitleColor(BearyColors.red, for: .normal)
        clearButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.bearyAddPressFeedback()
        let actionRow = UIStackView(arrangedSubviews: [copyButton, clearButton])
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.axis = .horizontal
        actionRow.spacing = 24
        actionRow.alignment = .center

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = BearyColors.ink
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        view.addSubview(topBar)
        view.addSubview(actionRow)
        view.addSubview(textView)
        // 补缺 P2-17：子页内容列 600 居中、顶栏同宽居中（iPhone 全宽不变；操作行跟顶栏左缘 +20）。
        let logTopBarWidthEquality = topBar.widthAnchor.constraint(equalTo: view.widthAnchor)
        logTopBarWidthEquality.priority = UILayoutPriority(750)
        let logTextWidthEquality = textView.widthAnchor.constraint(equalTo: view.widthAnchor)
        logTextWidthEquality.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            logTopBarWidthEquality,
            actionRow.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            actionRow.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 20),
            textView.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: 8),
            textView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            logTextWidthEquality,
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reloadLog()
    }

    private func reloadLog() {
        DiagFile.linesAsync { [weak self] lines in
            guard let self = self else { return }
            if lines.isEmpty {
                self.textView.text = "暂无诊断日志"
                self.textView.textColor = BearyColors.gray
                // 审计 P1-24：空日志时复制钮即显示无日志可复制，不留“复制全部”误导。
                self.copyButton.setTitle("暂无日志可复制", for: .normal)
            } else {
                self.textView.text = lines.joined(separator: "\n")
                self.textView.textColor = BearyColors.ink
                self.copyButton.setTitle("复制全部", for: .normal)
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    @objc private func copyTapped() {
        DiagFile.linesAsync { [weak self] lines in
            // 审计 P1-24：日志为空时不写剪贴板（不清空用户原有剪贴内容），只提示无日志可复制。
            guard !lines.isEmpty else {
                self?.copyButton.setTitle("暂无日志可复制", for: .normal)
                return
            }
            UIPasteboard.general.string = lines.joined(separator: "\n")
            self?.copyButton.setTitle("已复制", for: .normal)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.copyButton.setTitle("复制全部", for: .normal)
            }
        }
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(title: "确定清空诊断日志？", message: "清空后无法恢复。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            DiagFile.clear()
            self?.reloadLog()
        })
        present(alert, animated: BearyMotion.animated(true))
    }
}

/// iCity 已拉黑用户列表（设置页内页，不新开文件）：GET /beary/api/blocks 只返回 id，
/// 无用户查询接口，故行内仅显示“用户 + id”；每行“解除拉黑”调 DELETE 后刷新列表。
/// 解除成功同时发 bearyDidBlockUser 广播？不——解除是反向操作，不触发各页清理；
/// 各页的拉黑清理只由拉黑广播驱动，解除后下次拉取即恢复显示。
final class BearyBlockedUsersViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let closeButton = BearyHit44Button(type: .system)
    private let titleLabel = UILabel()
    private let emptyLabel = UILabel()
    private var blockedIds: [Int] = []
    private var unblockingIds: Set<Int> = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "已拉黑用户"
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = UIFont.systemFont(ofSize: 15)
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.text = "暂无已拉黑用户"
        emptyLabel.isHidden = true
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorColor = BearyColors.line
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BearyBlockedCell")
        view.addSubview(topBar)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        // 补缺 P2-17：拉黑列表顶栏与内容列同宽居中（iPhone 全宽不变）。
        let blockedTopBarWidthEquality = topBar.widthAnchor.constraint(equalTo: view.widthAnchor)
        blockedTopBarWidthEquality.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            blockedTopBarWidthEquality,
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tableView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            {
                let c = tableView.widthAnchor.constraint(equalTo: view.widthAnchor)
                c.priority = UILayoutPriority(750)
                return c
            }(),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        reloadBlocked()
    }

    private func reloadBlocked() {
        BearyAPI.shared.fetchBlocks { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    self.blockedIds = resp.blocked ?? []
                    self.emptyLabel.isHidden = !self.blockedIds.isEmpty
                    self.tableView.reloadData()
                case .failure:
                    BearyToast.show(in: self.view, message: "加载失败，请重试")
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return blockedIds.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyBlockedCell", for: indexPath)
        cell.backgroundColor = BearyColors.bg
        cell.selectionStyle = .none
        let userId = blockedIds[indexPath.row]
        cell.textLabel?.text = "用户 \(userId)"
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15)
        cell.textLabel?.textColor = BearyColors.ink
        let button = UIButton(type: .system)
        button.setTitle("解除拉黑", for: .normal)
        button.setTitleColor(BearyColors.blue, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        button.tag = userId
        button.isEnabled = !unblockingIds.contains(userId)
        button.addTarget(self, action: #selector(unblockTapped(_:)), for: .touchUpInside)
        button.bearyAddPressFeedback()
        button.sizeToFit()
        cell.accessoryView = button
        return cell
    }

    @objc private func unblockTapped(_ sender: UIButton) {
        let userId = sender.tag
        guard !unblockingIds.contains(userId) else { return }
        unblockingIds.insert(userId)
        sender.isEnabled = false
        BearyAPI.shared.unblockUser(userId: userId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.unblockingIds.remove(userId)
                switch result {
                case .success:
                    BearyBlockedStore.removeBlocked(userId)
                    self.blockedIds.removeAll { $0 == userId }
                    self.emptyLabel.isHidden = !self.blockedIds.isEmpty
                    self.tableView.reloadData()
                    BearyToast.show(in: self.view, message: "已解除拉黑")
                case .failure:
                    BearyToast.show(in: self.view, message: "解除失败，请重试")
                    self.tableView.reloadData()
                }
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }
}
