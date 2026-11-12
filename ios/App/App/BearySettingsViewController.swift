// ===== beary 设置页（2026-10-26：原独立账户页整体迁移为本页「账号与安全」分区；
// 齿轮菜单与头像菜单的“账户设置”入口均改开本页，旧 BearyAccountViewController 已删除，
// 不留两个入口、不留死代码页）=====
// C 批（C2/C3/C4）：模块顺序改为 [ID 概览卡 & Plus 状态] → [通用与通知
// （外观切换、使用指南入口）] → [账户与安全（登录设备管理、导出数据；
// 个人资料入口为 ID 卡右侧“编辑资料”钮，旧账户组四行已按 C4 删除）] → [隐私与协议]；
// 退出登录为独立居中常规钮（BearyButton 工厂），注销账户下沉至页底弱化灰字，
// 两者行为一字不动；齿轮直达本页，不再经 ActionSheet / 外观 Popover 中转。
// 新增行一律真实能力：外观主题三选
// （复用 beary_theme_mode 存档键）、版本行（Bundle 实值）；全修 3-4 已删“系统通知设置”行
// （全仓无通知调用，系统通知开关对本 App 无效，不留无效入口）、
// 隐私政策 / 用户协议（方案一：服务器下发文字、App 内原生排版，不开网页；
// 打开时先显示缓存或包内文本，后台拉 GET /beary/api/legal 最新版，刷新后只换文字不重建页面）。
import UIKit

// ===== beary 原生账户设置页（F 批新建；此前齿轮菜单与头像菜单的“账户设置”均为 presentComingSoon 占位）=====
// 对照源（动手前均已 grep 核实，以服务端与网页实现为准，不编造接口）：
// - 网页 ~/workspace/teddy_site/account.html：ID 卡（头像/名/邮箱/注册时间/会员/@handle）、
//   Plus 分组、登录设备列表 + 退出其他设备、导出我的数据、注销账户（两步确认 + 7 天冷静期）。
// - 账户 Worker ~/workspace/teddy_accounts_v2/worker.js（端点与字段均以它为准）：
//   GET /api/account/me → {ok, user: {id, is_admin, email, display_name, avatar, cover_ver,
//     created_at, handle, plus, plus_until, plus_free, invite_code, referral}}。
//     注意：现行 /me 不返回 serial_id，
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

    /// 导出专用 GET /api/account/sessions：与上法同口径，但走隔离请求、
    /// 凭据固定为导出账号的 token；401 只返回 .unauthorized，永不触发
    /// onUnauthorized（见 BearyAPI.requestWithToken 说明）。
    func fetchAccountSessionsWithToken(_ token: String, completion: @escaping (Result<BearyAccountSessionsResponse, APIError>) -> Void) {
        requestWithToken("/api/account/sessions", token: token, completion: completion)
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
    /// keepPublic：第 5 条定版显式勾选——默认 false（全部日记随注销删除）；true 时
    /// 只保留公开过的日记、作者匿名显示为“用户已注销”，以 keep_public 下发服务端。
    func requestAccountDelete(keepPublic: Bool = false, completion: @escaping (Result<BearyAccountDeleteResponse, APIError>) -> Void) {
        request("/api/account/delete", method: "POST", jsonBody: ["keep_public": keepPublic], completion: completion)
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

/// A2：同会话内共用的一份在途加载结果（Plus / 登录设备各一份）。
/// 并发调用只发一次网络请求，回包后逐个通知等候方；成功结果在本轮内
/// 缓存复用（设置主页 loadAll 的两次调用点——缓存路径先拉 + /me 成功
/// 后再拉——与两明细子页都接同一份结果，同账号同轮次内各只发一次请求）；
/// 失败不缓存，下次调用重新拉取；新一轮 loadAll / 账号切换 / 撤销后刷新
/// 时由调用方 invalidate 丢弃旧结果，旧代次回包按代次丢弃（不通知本轮
/// 等候方、不写入缓存）。回包一律回主线程再通知等候方
/// （BearyAPI.request 的 completion 不在主线程，见各调用点的既有转主线程）。
/// 注：invalidate 的调用点全在设置主页自身动作（loadAll 开头、撤销后刷新），
/// 子页 present 期间不会触发，故不存在子页等候方被丢弃后转圈卡住的情况。
final class BearySharedLoad<Value> {
    private struct InFlight {
        let generation: Int
        var waiters: [(Result<Value, APIError>) -> Void]
    }
    private var loadedValue: Value?
    private var inFlight: InFlight?
    private var generation = 0
    private let fetch: (@escaping (Result<Value, APIError>) -> Void) -> Void

    init(fetch: @escaping (@escaping (Result<Value, APIError>) -> Void) -> Void) {
        self.fetch = fetch
    }

    /// 本轮已取到的成功结果（无则为 nil）；子页凭它区分「还没取到」
    /// 与「确认是空」（取到空列表时这里是 []，不是 nil）。
    var currentValue: Value? { loadedValue }

    /// 取一份结果：在途则排队等同一份回包；本轮已取到则直接回缓存；
    /// 未取或上次失败则发一次请求。
    func load(completion: @escaping (Result<Value, APIError>) -> Void) {
        if let value = loadedValue {
            completion(.success(value))
            return
        }
        if var flight = inFlight, flight.generation == generation {
            flight.waiters.append(completion)
            inFlight = flight
            return
        }
        let gen = generation
        inFlight = InFlight(generation: gen, waiters: [completion])
        fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let flight = self.inFlight, flight.generation == gen else { return }
                self.inFlight = nil
                if case .success(let value) = result {
                    self.loadedValue = value
                }
                for waiter in flight.waiters { waiter(result) }
            }
        }
    }

    /// 丢弃本轮已缓存的成功结果并作废在途旧请求（新一轮 loadAll、账号切换、
    /// 撤销后刷新时调用）；新轮次调用 load 时另发请求，不接旧代次回包。
    func invalidate() {
        loadedValue = nil
        generation += 1
        inFlight = nil
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
    /// A2：Plus / 登录设备各一份同会话在途结果（见 BearySharedLoad）——
    /// 设置主页 loadAll 的两次调用点（缓存路径先拉 + /me 成功后再拉）与
    /// 两明细子页都接同一份结果，同账号同轮次内各只发一次请求。
    private let plusDetailLoad = BearySharedLoad<BearyPlusDetailResponse>(fetch: { BearyAPI.shared.fetchPlusDetail(completion: $0) })
    private let accountSessionsLoad = BearySharedLoad<BearyAccountSessionsResponse>(fetch: { BearyAPI.shared.fetchAccountSessions(completion: $0) })
    private var isLoadingMe = false
    /// /me 代次：切换账号成功时 +1 作废旧请求，旧回包凭代次丢弃，
    /// 不再把旧账号写回 ID 卡（旧请求发在切换前，回包体仍是旧账号）。
    private var meLoadGeneration = 0
    /// 第三轮审计 13：Plus/设备列表已请求代次——同一次页面加载（同一
    /// meLoadGeneration）各只请求一次，第二轮调用直接跳过；重进页/切号
    /// 时 meLoadGeneration 递增，自然重拉。
    private var plusDetailRequestedGeneration = -1
    private var sessionsRequestedGeneration = -1
    /// 第七轮审计 02：附属加载（Plus 详情／设备会话）的回包守卫——
    /// /me 只守自己的两处回包，这两处各拍自己的发起代次＋鉴权态，
    /// 切号／退出后旧回包整单丢弃，不再把旧账号数据写回界面。
    /// 同一账号内重拉（loadAll 缓存路径＋/me 成功路径各发一次）时，
    /// 后发的一轮作废先发的一轮，只留最新回包写界面。
    private var plusDetailGeneration = 0
    private var sessionsGeneration = 0
    /// 当前屏上 Plus／设备展示数据归属的账号（成功回包落盘时记）；
    /// 切号广播到达时与当前账号比对，不一致即旧账号数据，立即清掉。
    /// 注意：只凭这一项清展示，不在广播里 bump 上面两代次——广播是
    /// async 投递，切换完成后 loadAll 刚发的新请求可能已先跑，
    /// handler 里 bump 会把新请求一并作废；旧在途请求由发起时拍的
    /// 鉴权代次＋账号 ID 拦（SessionManager 在身份提交时已同步 bump）。
    private var auxDataAccountId: Int?

    /// 第七轮审计 02：附属回包三重门——发起代次＋鉴权代次＋账号 ID，
    /// 任一失配即旧账号／旧一轮的回包，整单丢弃（成功与失败分支同守，
    /// 旧号 401 也不得触发新号的登录门）。
    private func isCurrentAuxResponse(generation: Int, currentGeneration: Int, accountId: Int?, epoch: Int) -> Bool {
        generation == currentGeneration
            && accountId == BearyAPI.shared.authAccountId
            && epoch == BearyAPI.shared.authEpoch
    }
    /// 切换账号卡容器（buildAccountSwitchSection 建，refreshAccountSwitchSection
    /// 重建卡片；登录态无关的通用/隐私组不受影响）。
    private let accountSwitchWrap = UIView()
    /// 扫 bug 第 9 项：切换卡缓存（只缓存展示用模型，不缓存 token）。
    /// cachedSwitchModels = 上次 loadAll 映射的保管库模型（保管库顺序，
    /// 未含“当前账号不在库内”补位行、未排序）；cachedSwitchGeneration
    /// = 取数时的保管库代际，代际不变即库内容未变，复用模型、不再
    /// 全量读钥匙串。cachedSwitchFingerprint = 上次建成卡片的模型
    /// 指纹（id/标题/handle/邮箱/头像/当前勾选全在内）；指纹不变即
    /// 卡片内容与现行完全一致，跳过拆卡重建、保留现卡（头像加载态
    /// 也不丢）。切换/移除/添加/快照写入都会推高代际或改指纹，
    /// 故账号变化时必重建；切换逻辑本身一字不动。
    private var cachedSwitchModels: [SwitchRowModel]?
    private var cachedSwitchGeneration: Int?
    private var cachedSwitchFingerprint: String?
    /// 切换时预检 401 证实已死的账号（内存态，不进保管库）：列表不再
    /// 把这类账号装成可直接切换，行上标“登录已过期”、点按直走重登。
    /// 账号回到当前（重登成功）或从列表消失时由刷新处剪掉。
    private var expiredSwitchUserIds = Set<Int>()
    private var switchCardBuilt = false
    private var isSwitchingAccount = false
    private var isRemovingAccount = false
    private var isLoggingOutOthers = false
    private var isDeleting = false
    private var isExporting = false
    private var exportDetailLabel: UILabel? // 2026-10-29：导出进度提示落点（导出行副文案）
    /// 内容列宽：直接由 view.bounds 派生的必需约束（替代旧的
    /// frameLayoutGuide 750 宽约束 + 600 上限开关两约束协商）。列宽是
    /// view.bounds 的纯函数，首个布局轮次即最终值，不再经多轮约束收敛
    /// 分段变宽；最终口径不变（iPhone 屏宽 -32，宽 ≥821 锁 600 居中）。
    private var contentColumnWidth: NSLayoutConstraint?
    /// 审计第 1 项：主设置页顶栏与正文列共用同一宽度入口（见 columnWidth(forViewWidth:)）。
    /// 旧口径是顶栏 width = view − 40（priority 750）+ width ≤ 600（必需），
    /// 在 641…820pt 区间必需的 600 上限先胜出，顶栏 600pt、正文列 view − 40，
    /// 两者左缘错开；现顶栏改为与正文列同一等值约束，600 上限只在 ≥821pt 时由计算入口给出。
    private var topBarColumnWidth: NSLayoutConstraint?
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
    // C5：主失败态走统一 BearyStateView（旧 failureWrap/failureLabel/文字重试钮退役；
    // 标题“加载失败”＋紧凑描边“重试”钮，动作仍是 loadAll；“请”字随旧文案并入动作）。
    private let failureStateView = BearyStateView()
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
    /// 反馈与建议组（2026-10-28 反馈 v3）：只剩「反馈与改进」一行；与通用 /
    /// 隐私组同款恒可见，不随登录态切换（游客进不了设置页，见任务说明）。
    private let dataFeedbackWrap = UIStackView()
    /// 2026-10-29 第 12 项（合并 B）：退出登录与注销账户并入「账号操作」卡
    /// （仍登录态相关，未登录 / 加载失败时整卡隐藏；注销行另按 is_admin 隐藏，
    /// 连同其前分隔线一并藏，不留 stray 线）。
    private let accountActionWrap = UIView()
    private var accountActionDeleteSeparator: UIView?
    private var accountActionDeleteWrap: UIView?
    /// 视觉批：设置页渐进披露（规范 §3）——三组折叠的持有者，由
    /// makeDisclosureCard 建、toggle 方法翻转；默认收起。
    private var diagDisclosure: SettingsDisclosure?
    private var plusDisclosure: SettingsDisclosure?
    private var accountDisclosure: SettingsDisclosure?
    /// 导出行：仍在 buildSecuritySection 内建（导出按钮与副文案属性
    /// 的接线不动），只改承载位置——不再进安全组，改交账号披露组；
    /// buildLayout 先调 buildSecuritySection、后调 buildAccountActionSection，
    /// 故账号披露组建时本值必已就位。
    private var exportRowForDisclosure: UIView?
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
    /// 第四轮审计 15：同步状态行尾文案（使用本地内容／正在同步／已同步／同步失败，
    /// 随 BearyEntrySync.currentSyncState 更新；失败不弹提示，只改本行）。
    private let syncStateLabel = UILabel()
    private let idValueLabel = UILabel()

    // Plus 分组
    private let plusStatusLabel = UILabel()
    /// Plus 页入口行尾文案（未开通／至到期日／永久有效，随 fillPlusDetail 更新）。
    private let plusEntryLabel = UILabel()
    private var plusFreeRow: UIView = UIView()
    /// F4：内测限免行的分组卡包容器（藏行须藏包容器，否则内边距仍占位）。
    private var plusFreeWrapper: UIView?
    /// 内测限免行与来源明细行之间的分隔线（随限免行同隐同显，否则限免行藏后留双线）。
    private var plusFreeSeparator: UIView?
    private let plusFreeLabel = UILabel()
    private let plusPersonalLabel = UILabel()
    /// 2026-10-29 第 7 项：来源明细已抽成独立页（BearyPlusGrantsViewController），
    /// 设置页只缓存数据、不再内联建发放行；grantsStack 已随之删除。
    private var cachedGrants: [BearyPlusGrant]?
    private var grantsLoadFailed = false

    // ID 卡右侧编辑资料钮（C4：账户组四行删除后，个人资料唯一入口）。
    // 第五轮审计：普通 UIButton 无 44pt 热区，改 BearyHit44Button——视觉
    // 大小不动，仅 point(inside:) 把热区纵向扩到 44pt（按钮宽 >44 故横向
    // 不扩；扩区落在 hero 行 64pt 头像高度内，不抢邻行点击）。
    private let editProfileButton = BearyHit44Button(type: .system)

    // 设备分组
    private let deviceCountLabel = UILabel()
    /// 2026-10-29 第 11 项：设备列表已抽成独立页（BearyDevicesViewController），
    /// 设置页只缓存数据（accountSessions 既有）与失败态、不再内联展开；
    /// sessionsStack 已随之删除。退出其他设备钮仍留在设置页。
    private var sessionsLoadFailed = false
    // 设置“退出其他设备”热区：普通 UIButton 高钉死 36、无 Hit44，
    // 上下各缺 4pt 可点区。改 BearyHit44Button——视觉高仍钉死 36、
    // 圆角 12、13/600 红字红边（45%）与文案/目标/按压反馈/忙碌态一律不动，
    // 仅 point(inside:) 把热区上下各扩 4pt 至 44pt（扩区落在
    // makeGroupCard 每行上下各 14pt 的 wrap 留白内，不抢邻行点击）。
    // 不要把视觉高改成 44，也不要换 BearyButton 工厂（会改圆角/字号）。
    private let logoutOthersButton = BearyHit44Button(type: .system)
    /// 审计 E2 第 23 项：退出其他设备请求期的原入口忙碌图标（既有刷新图标，
    /// 红 tint 贴合本钮红字；请求终结时停转隐藏，标题文案不动）。
    private let logoutOthersSpinner: BearyRefreshIconView = {
        let view = BearyRefreshIconView()
        view.tintColor = BearyColors.red
        return view
    }()
    /// 审计 E2 第 23 项：注销请求期的忙碌图标（既有刷新图标，灰 tint 贴合注销灰字）。
    private let deleteSpinner = BearyRefreshIconView()

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
        // 切号后私信权限行跟新账号走（设置页内切换账号时 viewWillAppear 不触发）。
        // r25-4：切号先清空旧档位、文案回“加载中…”、在途请求代次作废，再按新号重读。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserChangedForDMLevel), name: .bearyUserDidChange, object: nil)
        // 添加账号回设置页时 viewWillAppear 跑在 refreshMe 完成之前（dismiss 动画
        // 起始即触发，refreshMe 在 dismiss 完成回调里才跑），当时 currentUser 仍是
        // 旧号、快照不变、指纹不变，旧卡被保留；refreshMe 完成后 id 真变才广播
        // bearyUserDidChange——此前本页只拿它刷私信档位行，切换卡没跟上，
        // 于是新号要退出重进才出现。这里补上切换卡刷新（指纹守卫保证无变
        // 化时不重建；切换／移除的直接刷新路径不受影响）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleUserChangedForAccountSwitch), name: .bearyUserDidChange, object: nil)
        // 第四轮审计 15：同步进行中状态变迁时刷新 ID 卡同步状态行
        // （广播在主线程发出；本页关掉时 deinit 统一移除监听）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleSyncStateChanged), name: .bearySyncStateDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settingsFrameResetDone = false
        settingsLayoutLogged = false
        refreshAccountSwitchSection()
        refreshDMLevelRow()
        refreshNotificationHintRow()
        refreshDeveloperModeRow()
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


    /// 列宽唯一计算入口：宽 ≥821 锁 600（P2-1 同款），宽 ≤820 时
    /// 屏宽 -32 撑满（两侧各 16）。顶栏与正文列共用此值，600 上限不再以独立约束形式存在。
    private func columnWidth(forViewWidth w: CGFloat) -> CGFloat {
        w >= 821 ? 600 : max(w - 32, 0)
    }

    /// 列宽只由 view.bounds 定（见 columnWidth(forViewWidth:)）；顶栏与正文列
    /// 在同一入口算出同一目标值、写入各自等值约束；bounds 为 0 时跳过不钉死；
    /// 值不变时不写，避免布局环。viewDidLayoutSubviews 每轮调用，故分屏 /
    /// 旋转改宽时顶栏与正文列同步跟进。
    private func updateColumnWidth() {
        let w = view.bounds.width
        guard w > 0 else { return }
        let target = columnWidth(forViewWidth: w)
        if contentColumnWidth?.constant != target {
            contentColumnWidth?.constant = target
        }
        if topBarColumnWidth?.constant != target {
            topBarColumnWidth?.constant = target
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor 只在赋值时解析一次：深浅切换时重刷描边（背景色走动态色，自动跟随）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
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

    // 第十轮审计文案 a：可点行删「查看」二字——行标题＋行尾箭头已表达可进入。
    // detailLabel 传 nil 时不占位；showChevron 时行尾补官方右箭头（与 Plus
    // 入口行同款：spacer 吸剩余宽度、箭头顶到行尾）。
    private func makeRow(title: String, detailLabel: UILabel? = nil, iconName: String? = nil, showChevron: Bool = false) -> UIView {
        let titleLabelValue = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（15 regular scaled；入口本身已
        // scaled，覆写而非经工厂再缩放，避免二次缩放）。
        titleLabelValue.font = BearyDynamicType.smallBodyFont()
        titleLabelValue.text = title
        // P1-7：行正文标题与行尾辅助文案均可多行，行高由栈自动撑开。
        titleLabelValue.numberOfLines = 0
        if let detailLabel = detailLabel {
            detailLabel.numberOfLines = 0
            detailLabel.textAlignment = .right
        }
        titleLabelValue.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        var parts: [UIView] = []
        if let icon = iconName {
            parts.append(makeRowIcon(icon))
        }
        parts.append(titleLabelValue)
        if let detailLabel = detailLabel {
            parts.append(detailLabel)
        }
        if showChevron {
            parts.append(makeRowSpacer())
            parts.append(makeRowChevron())
        }
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
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        titleLabelValue.font = BearyDynamicType.smallBodyFont()
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

    private func makeCardView() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        // 卡片底色走 surface1（页上卡片层；2026-11-07 微明度定版：1px 外框已去掉）。
        card.backgroundColor = BearyColors.surface1
        card.layer.borderWidth = 0
        card.layer.cornerRadius = BearyCorners.single
        card.clipsToBounds = true
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
    /// 一并返回行间分隔线：separators[i] 位于 wrappers[i] 与 wrappers[i + 1] 之间；
    /// 隐藏第 i（i > 0）行时须连同其前分隔线 separators[i - 1] 一并藏，否则留 stray 线
    /// （第十一轮审计 1：通知提示行与开发者模式行只藏 row，残留 wrap 内边距与分隔线）。
    private func makeGroupCard(title: String?, rows: [UIView]) -> (card: UIView, wrappers: [UIView], separators: [UIView]) {
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
        var separators: [UIView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                NSLayoutConstraint.activate([
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
                stack.addArrangedSubview(separator)
                separators.append(separator)
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
            // 审计三轮第 4 项：可点行的覆盖按钮改钉外层 wrap 四边（含 14pt 留白），
            // 视觉内边距仍由内容容器控制。判定标准：按钮已零边距钉满内层四边
            // （即整行覆盖钮）；居中独立钮（退出/注销）、带 -52 避让的切号钮、
            // 开关行（无 UIButton）一律不动——开关行仍只响应控件本身。
            // 外层 wrap 每行只包一行，按钮原已盖满整行，扩到外框只多出留白区，
            // 不会盖住任何同行控件；按钮目标与按压反馈跟随按钮本身。
            let coverButtons = row.subviews.compactMap { $0 as? UIButton }.filter { button in
                let edgeAttrs: [NSLayoutConstraint.Attribute] = [.top, .leading, .trailing, .bottom]
                return edgeAttrs.allSatisfy { attr in
                    row.constraints.contains { c in
                        (c.firstItem as? UIButton) === button && c.firstAttribute == attr
                            && (c.secondItem as? UIView) === row && c.constant == 0
                    }
                }
            }
            if coverButtons.count == 1, let button = coverButtons.first {
                NSLayoutConstraint.deactivate(row.constraints.filter { ($0.firstItem as? UIButton) === button || ($0.secondItem as? UIButton) === button })
                wrap.addSubview(button)
                NSLayoutConstraint.activate([
                    button.topAnchor.constraint(equalTo: wrap.topAnchor),
                    button.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                    button.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                ])
            }
            stack.addArrangedSubview(wrap)
            wrappers.append(wrap)
        }
        return (card, wrappers, separators)
    }

    private func makeCardStack(spacing: CGFloat = 12) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }

    /// 视觉批：设置页渐进披露的一组折叠（规范 §3：点按展开，展开动效走
    /// 局部状态 0.18s、箭头旋转指示）。卡内结构 = 标题行 + 可折叠体：
    /// 标题行走组标题口径（12 灰 kern 1，见 makeSectionTitle）+ 行尾下箭头
    /// （官方包 icon_chevron_down 16 灰，通知卡同款）；体是行栈，初始收起
    /// （isHidden，栈自动归零高度），行包容器与分隔线口径与 makeGroupCard
    /// 一致（行上下 14、左右 16、行间 1pt 细线），可点行的覆盖按钮按
    /// makeGroupCard 的审计口径改钉包容器四边（只扩留白区，不盖同行控件）。
    private final class SettingsDisclosure {
        let card: UIView
        let headerButton: UIButton
        let bodyStack: UIStackView
        let bodyWrappers: [UIView]
        /// 行间分隔线（与 bodyWrappers 平行：第 i 条位于 wrapper[i] 与 wrapper[i + 1] 之间）。
        let bodySeparators: [UIView]
        let chevron: UIImageView
        var isExpanded = false
        init(card: UIView, headerButton: UIButton, bodyStack: UIStackView, bodyWrappers: [UIView], bodySeparators: [UIView], chevron: UIImageView) {
            self.card = card
            self.headerButton = headerButton
            self.bodyStack = bodyStack
            self.bodyWrappers = bodyWrappers
            self.bodySeparators = bodySeparators
            self.chevron = chevron
        }
    }

    private func makeDisclosureCard(title: String, rows: [UIView]) -> SettingsDisclosure {
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
        // 标题行：组标题 + 吸宽 spacer + 下箭头，可点区域盖满整行留白。
        let titleLabelValue = makeSectionTitle(title)
        titleLabelValue.translatesAutoresizingMaskIntoConstraints = false
        let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_down", pointSize: 16))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
        ])
        let headerContent = UIStackView(arrangedSubviews: [titleLabelValue, makeRowSpacer(), chevron])
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        headerContent.axis = .horizontal
        headerContent.spacing = 12
        headerContent.alignment = .center
        let headerWrap = UIView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        headerWrap.addSubview(headerContent)
        let headerButton = UIButton(type: .custom)
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.accessibilityLabel = title
        headerButton.accessibilityValue = "已收起"
        headerButton.bearyAddPressHaptic()
        headerWrap.addSubview(headerButton)
        headerButton.addTarget(self, action: #selector(settingsRowPressDown(_:)), for: .touchDown)
        headerButton.addTarget(self, action: #selector(settingsRowPressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        NSLayoutConstraint.activate([
            headerContent.topAnchor.constraint(equalTo: headerWrap.topAnchor, constant: 14),
            headerContent.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor, constant: 16),
            headerContent.trailingAnchor.constraint(equalTo: headerWrap.trailingAnchor, constant: -16),
            headerContent.bottomAnchor.constraint(equalTo: headerWrap.bottomAnchor, constant: -14),
            headerButton.topAnchor.constraint(equalTo: headerWrap.topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: headerWrap.trailingAnchor),
            headerButton.bottomAnchor.constraint(equalTo: headerWrap.bottomAnchor),
        ])
        stack.addArrangedSubview(headerWrap)
        // 体：首位是标题行与体之间的分隔线，随体一并显隐，收起时不留 stray 线。
        let bodyStack = UIStackView()
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.spacing = 0
        bodyStack.alignment = .fill
        bodyStack.isHidden = true
        let headerSeparator = UIView()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.backgroundColor = BearyColors.line
        NSLayoutConstraint.activate([
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
        bodyStack.addArrangedSubview(headerSeparator)
        var wrappers: [UIView] = []
        var separators: [UIView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                NSLayoutConstraint.activate([
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
                bodyStack.addArrangedSubview(separator)
                separators.append(separator)
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
            // 与 makeGroupCard 同款：整行覆盖钮改钉包容器四边。
            let coverButtons = row.subviews.compactMap { $0 as? UIButton }.filter { button in
                let edgeAttrs: [NSLayoutConstraint.Attribute] = [.top, .leading, .trailing, .bottom]
                return edgeAttrs.allSatisfy { attr in
                    row.constraints.contains { c in
                        (c.firstItem as? UIButton) === button && c.firstAttribute == attr
                            && (c.secondItem as? UIView) === row && c.constant == 0
                    }
                }
            }
            if coverButtons.count == 1, let button = coverButtons.first {
                NSLayoutConstraint.deactivate(row.constraints.filter { ($0.firstItem as? UIButton) === button || ($0.secondItem as? UIButton) === button })
                wrap.addSubview(button)
                NSLayoutConstraint.activate([
                    button.topAnchor.constraint(equalTo: wrap.topAnchor),
                    button.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                    button.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                ])
            }
            bodyStack.addArrangedSubview(wrap)
            wrappers.append(wrap)
        }
        stack.addArrangedSubview(bodyStack)
        return SettingsDisclosure(card: card, headerButton: headerButton, bodyStack: bodyStack, bodyWrappers: wrappers, bodySeparators: separators, chevron: chevron)
    }

    /// 视觉批：折叠翻转——体显隐 + 箭头旋转 π（通知卡 setChevronExpanded
    /// 同款）同在局部状态 0.18s 内完成；减动效时直落终态（BearyMotion 门控）。
    private func setDisclosureExpanded(_ disclosure: SettingsDisclosure, _ expanded: Bool, animated: Bool) {
        disclosure.isExpanded = expanded
        disclosure.headerButton.accessibilityValue = expanded ? "已展开" : "已收起"
        let apply = {
            disclosure.bodyStack.isHidden = !expanded
            disclosure.chevron.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : CGAffineTransform.identity
        }
        guard animated, BearyMotion.animated(true) else {
            apply()
            view.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
            apply()
            self.view.layoutIfNeeded()
        })
    }

    @objc private func diagDisclosureTapped() {
        guard let disclosure = diagDisclosure else { return }
        setDisclosureExpanded(disclosure, !disclosure.isExpanded, animated: true)
    }

    @objc private func plusDisclosureTapped() {
        guard let disclosure = plusDisclosure else { return }
        setDisclosureExpanded(disclosure, !disclosure.isExpanded, animated: true)
    }

    @objc private func accountDisclosureTapped() {
        guard let disclosure = accountDisclosure else { return }
        setDisclosureExpanded(disclosure, !disclosure.isExpanded, animated: true)
    }

    private func buildLayout() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
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
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // 115 设置页空白守卫（根因未证实）：顶栏保留 #343 跟随字号，
            // 但加覆盖最大无障碍字号的上界。17pt 粗体在最大档缩放后约
            // 51pt + 上下各 6pt 内边距 ≈ 63pt，88pt 留足余量；上界只防
            // solver 在异常组合下把顶栏撑到把 scrollView 顶出屏，常规
            // 字号下为 44pt，也不动字号跟随逻辑本身。
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
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        view.addSubview(topBar)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        // 审计第 1 项：主页顶栏与内容列同宽居中，宽度由 updateColumnWidth
        // 经 columnWidth(forViewWidth:) 统一算出（≥821pt 时 600、其余屏宽 −32），
        // 不再用 view − 40（priority 750）+ ≤600（必需）两约束协商——后者在
        // 641…820pt 区间会把顶栏卡在 600pt、与正文列错开。左右 ≥16 不等式保留作兜底
        // （与 w−32 居中时边距 16 一致，不再冲突）。
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
        ])
        contentColumnWidth = contentStack.widthAnchor.constraint(equalToConstant: 0)
        contentColumnWidth?.isActive = true
        topBarColumnWidth = topBar.widthAnchor.constraint(equalToConstant: 0)
        topBarColumnWidth?.isActive = true
        updateColumnWidth()

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        // 栈内固有尺寸与旧 medium 圈一致（20pt 图）。
        loadingView.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
        // P1-7：失败辅助文案走统一状态视图（回收站失败态同款组件；无图标行，
        // 标题＋紧凑描边重试钮，动作复用 retryButtonTapped = loadAll）。
        failureStateView.translatesAutoresizingMaskIntoConstraints = false
        failureStateView.configure(kind: .error, title: "加载失败", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.retryButtonTapped() })
        failureStateView.isHidden = true

        // P1-7：登录提示辅助文案走动态字体。
        loginHintLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        loginHintLabel.adjustsFontForContentSizeCategory = true
        loginHintLabel.textColor = BearyColors.gray
        loginHintLabel.numberOfLines = 0
        loginHintLabel.textAlignment = .center
        loginHintLabel.text = "请先登录"
        loginButton.setTitle("去登录", for: .normal)
        loginButton.setTitleColor(BearyColors.ink, for: .normal)
        loginButton.titleLabel?.font = BearyDynamicType.smallActionFont()
        loginButton.titleLabel?.adjustsFontForContentSizeCategory = true
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
        // 本地通知（2026-11-08 新增）：四种开关 + 系统权限未开启提示行，
        // 挂在「通用与通知」组之后（原消息与通知卡在诊断之后的位置）。
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
        contentStack.addArrangedSubview(failureStateView)
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
        avatarContainer.backgroundColor = BearyColors.surface2
        avatarContainer.layer.cornerRadius = 32
        avatarContainer.clipsToBounds = true
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarInitialLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarInitialLabel.font = BearyDynamicType.avatarInitialFont()
        avatarInitialLabel.adjustsFontForContentSizeCategory = true
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
        heroNameLabel.font = BearyDynamicType.heroNameFont()
        heroNameLabel.adjustsFontForContentSizeCategory = true
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
        editProfileButton.titleLabel?.font = BearyDynamicType.buttonRegularFont()
        editProfileButton.titleLabel?.adjustsFontForContentSizeCategory = true
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
        // 第四轮审计 15：同步状态行尾文案与注册时间／会员行同款式。
        syncStateLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        syncStateLabel.adjustsFontForContentSizeCategory = true
        syncStateLabel.textColor = BearyColors.gray
        syncStateLabel.numberOfLines = 0
        syncStateLabel.textAlignment = .right
        syncStateLabel.text = BearyEntrySync.shared.currentSyncState.displayText
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
        // 第四轮审计 15：同步状态行（ID 卡内，会员行之下）：只读展示四态，
        // 不可点按、不弹提示；失败时本行只改文案，下次触发重跑后自动更新。
        let syncStateRow = makeRow(title: "同步状态", detailLabel: syncStateLabel, iconName: "icon_info")
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
        cardStack.addArrangedSubview(syncStateRow)
        cardStack.addArrangedSubview(idSeparator)
        cardStack.addArrangedSubview(idRow)
        cardStack.setCustomSpacing(18, after: syncStateRow)
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
        plusEntryLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        plusEntryLabel.adjustsFontForContentSizeCategory = true
        plusEntryLabel.textColor = BearyColors.gray
        plusEntryLabel.numberOfLines = 0
        plusEntryLabel.textAlignment = .right
        plusFreeRow = makeRow(title: "内测限免", detailLabel: plusFreeLabel, iconName: "icon_gift")
        // Plus 页入口行（组内首行）：标题“Plus 会员”＋行尾状态（未开通／到期日／
        // 永久有效），点按进 Plus 展示页；到期日只留 Plus 组，不进 ID 卡（全修 3-2）。
        let plusEntryTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        plusEntryTitle.font = BearyDynamicType.smallBodyFont()
        plusEntryTitle.text = "Plus 会员"
        plusEntryTitle.numberOfLines = 0
        plusEntryTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let plusEntryContent = UIStackView(arrangedSubviews: [plusEntryTitle, makeRowSpacer(), plusEntryLabel, makeRowChevron()])
        plusEntryContent.translatesAutoresizingMaskIntoConstraints = false
        plusEntryContent.axis = .horizontal
        plusEntryContent.spacing = 12
        plusEntryContent.alignment = .center
        let plusEntryButton = UIButton(type: .custom)
        plusEntryButton.accessibilityLabel = "Plus 会员"
        plusEntryButton.addTarget(self, action: #selector(openPlusPage), for: .touchUpInside)
        plusEntryButton.bearyAddPressHaptic()
        let plusEntryRow = makeSettingsTappableRow(content: plusEntryContent, button: plusEntryButton)
        // 2026-10-29 第 7 项：来源明细抽成独立页——组内只留一行（标题 + 行尾
        // 官方包右箭头），点击进 BearyPlusGrantsViewController；原内联发放卡已删。
        let grantsTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        grantsTitle.font = BearyDynamicType.smallBodyFont()
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
        // 视觉批：渐进披露——一级只留入口／状态／专属会员，内测限免与
        // 来源明细收进紧随其后的「Plus 更多」折叠（点按展开；两行原相对
        // 顺序不变：限免在前、来源明细在后）。
        let plusGroup = makeGroupCard(title: "Plus 会员", rows: [
            plusEntryRow,
            makeRow(title: "当前状态", detailLabel: plusStatusLabel, iconName: "icon_info"),
            makeRow(title: "专属会员", detailLabel: plusPersonalLabel, iconName: "icon_star"),
        ])
        contentWrap.addArrangedSubview(plusGroup.card)
        let plusDisclosureValue = makeDisclosureCard(title: "Plus 更多", rows: [plusFreeRow, grantsRow])
        plusDisclosureValue.headerButton.addTarget(self, action: #selector(plusDisclosureTapped), for: .touchUpInside)
        // 视觉批：限免行显隐（freeUntil 为 0 时藏整行）改指披露体内的限免行
        // 包容器；旧索引 wrappers[1] 实际指向「当前状态」行（Plus 组行序为
        // 入口／状态／限免／专属／来源明细），藏它会误藏状态行、限免行只藏
        // 内容留 28pt 空位，故此处一并纠为限免行本身。
        if plusDisclosureValue.bodyWrappers.count > 0 {
            plusFreeWrapper = plusDisclosureValue.bodyWrappers[0]
        }
        // 限免行与来源明细行之间的分隔线（bodySeparators[0]）随限免行同隐同显。
        if plusDisclosureValue.bodySeparators.count > 0 {
            plusFreeSeparator = plusDisclosureValue.bodySeparators[0]
        }
        plusDisclosure = plusDisclosureValue
        contentWrap.addArrangedSubview(plusDisclosureValue.card)
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
        logoutOthersButton.setTitleColor(BearyColors.destructiveText, for: .normal)
        // F10：网页 .btn.danger 口径——36 高、13/600、红字红边（红 45% 透明边）。
        logoutOthersButton.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        logoutOthersButton.titleLabel?.adjustsFontForContentSizeCategory = true
        logoutOthersButton.layer.borderWidth = 1
        logoutOthersButton.layer.bearyDynamicBorderColor = BearyColors.alpha(BearyColors.red, 0.45)
        logoutOthersButton.layer.cornerRadius = 12
        logoutOthersButton.addTarget(self, action: #selector(logoutOthersButtonTapped), for: .touchUpInside)
        logoutOthersButton.bearyAddPressFeedback()
        // 审计 E2 第 23 项：忙碌图标挂在原入口内右侧（不改标题、不改钮尺寸）。
        logoutOthersButton.addSubview(logoutOthersSpinner)
        NSLayoutConstraint.activate([
            logoutOthersButton.heightAnchor.constraint(equalToConstant: 36),
            logoutOthersSpinner.widthAnchor.constraint(equalToConstant: 20),
            logoutOthersSpinner.heightAnchor.constraint(equalToConstant: 20),
            logoutOthersSpinner.trailingAnchor.constraint(equalTo: logoutOthersButton.trailingAnchor, constant: -12),
            logoutOthersSpinner.centerYAnchor.constraint(equalTo: logoutOthersButton.centerYAnchor),
        ])
        // 2026-10-31 冷启动生物识别锁：开关行（标题按设备生物识别走——
        // iPhone“面容识别解锁”、iPad“触控 ID 解锁”，绝不写死面容）。
        // 开关默认关；未录入生物识别时置灰并给原因，不硬开。
        // 开启/关闭都要先验一次生物识别（见 lockSwitchValueChanged），
        // 验证失败/取消时开关视觉回滚，不写存档。
        let lockAvailability = BearyAppLockSettings.availability
        let lockTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        lockTitle.font = BearyDynamicType.smallBodyFont()
        lockTitle.text = "\(BearyAppLockSettings.biometryName)解锁"
        lockTitle.numberOfLines = 0
        let lockDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        // 审计-个人页设置：置灰陷阱——旧口径未录入时开关一律置灰，已开启的锁
        // 永远关不掉（只能一直走设备密码）；现已开启时开关保持可点，关闭走
        // 一次设备密码验证（.deviceOwnerAuthentication 本就含密码兜底），
        // 文案同步说明可关闭；未开启且不可用时仍置灰（开不了，不硬开）。
        // “只冷启动锁一次”规则不动。
        lockDetail.text = lockAvailability.available ? BearyAppLockSettings.coldStartNote : (BearyAppLockSettings.isEnabled ? "已开启，当前设备未录入生物识别，重新启动 beary 时改用设备密码验证，点按开关可关闭" : (lockAvailability.reason ?? "此设备暂无法使用生物识别"))
        let lockTextStack = UIStackView(arrangedSubviews: [lockTitle, lockDetail])
        lockTextStack.axis = .vertical
        lockTextStack.spacing = 2
        lockTextStack.alignment = .fill
        let lockSwitch = UISwitch()
        lockSwitch.isOn = BearyAppLockSettings.isEnabled
        lockSwitch.isEnabled = lockAvailability.available || BearyAppLockSettings.isEnabled
        lockSwitch.setContentHuggingPriority(.required, for: .horizontal)
        lockSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        lockSwitch.addTarget(self, action: #selector(lockSwitchValueChanged(_:)), for: .valueChanged)
        let lockRow = UIStackView(arrangedSubviews: [makeRowIcon("icon_lock"), lockTextStack, lockSwitch])
        lockRow.translatesAutoresizingMaskIntoConstraints = false
        lockRow.axis = .horizontal
        lockRow.spacing = 12
        lockRow.alignment = .center
        // 2026-11-04 隐私遮罩开关：独立于锁开关；默认开（保持现行行为），
        // 关了切后台不再显示仅官方 logo 纯色遮罩。开关即时生效，无需验证。
        let maskTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        maskTitle.font = BearyDynamicType.smallBodyFont()
        maskTitle.text = "隐私遮罩"
        maskTitle.numberOfLines = 0
        let maskDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        maskDetail.text = "在多任务切换界面中隐藏日记内容"
        let maskTextStack = UIStackView(arrangedSubviews: [maskTitle, maskDetail])
        maskTextStack.axis = .vertical
        maskTextStack.spacing = 2
        maskTextStack.alignment = .fill
        let maskSwitch = UISwitch()
        maskSwitch.isOn = BearyAppLockSettings.isMaskEnabled
        maskSwitch.setContentHuggingPriority(.required, for: .horizontal)
        maskSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        maskSwitch.addTarget(self, action: #selector(maskSwitchValueChanged(_:)), for: .valueChanged)
        let maskRow = UIStackView(arrangedSubviews: [makeRowIcon("icon_shield"), maskTextStack, maskSwitch])
        maskRow.translatesAutoresizingMaskIntoConstraints = false
        maskRow.axis = .horizontal
        maskRow.spacing = 12
        maskRow.alignment = .center
        // C2：导出我的数据行仍在此建（视觉与行为不动；exportRowButton 的
        // isEnabled 仍由导出流程控制），视觉批起承载改账号披露组（与注销
        // 同组），不再进安全组，见 buildAccountActionSection。
        let exportTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        exportTitle.font = BearyDynamicType.smallBodyFont()
        exportTitle.text = "导出我的数据"
        exportTitle.numberOfLines = 0 // P1-7：行正文标题多行
        let exportDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        exportDetail.text = "导出 JSON，包含账户资料、日记和点赞记录"
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
        // 视觉批：导出行交账号披露组承载（见上），安全组一级只留验证码
        // 登录／登录设备／生物识别锁／隐私遮罩／退出其他设备。
        exportRowForDisclosure = exportRowWrap
        let securityGroup = makeGroupCard(title: "账号与安全", rows: [
            codeLoginRow,
            deviceRow,
            lockRow,
            maskRow,
            logoutOthersButton,
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
        var isExpired: Bool = false
    }

    private func buildAccountSwitchSection() {
        accountSwitchWrap.translatesAutoresizingMaskIntoConstraints = false
        accountSwitchWrap.isHidden = true
        accountSecurityWrap.addArrangedSubview(accountSwitchWrap)
    }

    /// 账号真变广播到达时补刷切换卡（见 viewDidLoad 的注释：添加账号后
    /// viewWillAppear 跑早了，真正的新号要等这条广播才进卡）。
    /// 第七轮审计 02：同账号的广播（/me 静默刷新成功、编辑资料改名改
    /// 头像）不动展示；切号／退出时屏上若还挂着旧号的 Plus／设备数据，
    /// 立即清掉，不等新请求返回。只清展示，不 bump 附属加载代次——
    /// 见 auxDataAccountId 注释，旧在途请求由回包三重门拦。
    @objc private func handleUserChangedForAccountSwitch() {
        let currentAccountId = SessionManager.shared.currentUser?.id
        if let displayed = auxDataAccountId, displayed != currentAccountId {
            plusDetail = nil
            auxDataAccountId = nil
            cachedGrants = nil
            grantsLoadFailed = false
            plusEntryLabel.text = "–"
            plusStatusLabel.text = "–"
            plusFreeLabel.text = "–"
            plusPersonalLabel.text = "–"
            accountSessions = []
            sessionsLoadFailed = false
            // 设备计数文案初始即空（未拉到时子页不渲染该行），清展示时
            // 回空，不置“–”（子页会把 countText 原样当标题渲染）。
            deviceCountLabel.text = nil
        }
        refreshAccountSwitchSection()
    }

    /// 重建切换账号卡：只读保管库，不发网络；未登录时整卡隐藏。
    /// 当前账号优先排第一位（其余按首次保存顺序），当前行打勾；
    /// “添加账号”行恒可见，满 3 个时点按只弹上限提示、不进登录页。
    private func refreshAccountSwitchSection() {
        let currentUser = SessionManager.shared.currentUser ?? meUser
        guard let currentUserValue = currentUser, currentUserValue.id != nil else {
            // 未登录：旧卡必须清掉（此前拆卡发生在 guard 之前，现挪到这里，
            // 语义不变）；已建成标记同步清零，下次登录必重建。
            for subview in accountSwitchWrap.subviews {
                subview.removeFromSuperview()
            }
            switchCardBuilt = false
            cachedSwitchFingerprint = nil
            accountSwitchWrap.isHidden = true
            return
        }
        SessionManager.shared.snapshotCurrentAccount()
        let vault = BearyAccountVault.shared
        // 扫 bug 第 9 项：钥匙串读结果缓存——代际未变即库内容未变，
        // 复用上次 loadAll 映射的模型，不再每次进页全量读钥匙串；
        // 代际变了（切换/移除/添加/快照写入）才重读。注意模型里只有
        // 展示字段（token 不进缓存）；快照本身仍每次调用（内容不变
        // 时 vault.save 已跳过写盘、不推代际，故缓存能命中）。
        let storedModels: [SwitchRowModel]
        if let cached = cachedSwitchModels, cachedSwitchGeneration == vault.generation {
            storedModels = cached
        } else {
            let stored = vault.loadAll()
            let mapped: [SwitchRowModel] = stored.map { account in
                SwitchRowModel(userId: account.userId, title: account.displayTitle, handle: account.handle, email: account.email, avatarURL: account.avatarURL, hasToken: true)
            }
            cachedSwitchModels = mapped
            cachedSwitchGeneration = vault.generation
            storedModels = mapped
        }
        var models: [SwitchRowModel] = storedModels
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
        // 切换过期标记：只保留仍在列表里的非当前账号（当前账号会话
        // 刚被证实有效、移除的账号不再展示，标记随之失效）；标记打到
        // 行模型上、进指纹，标记变化时卡片必重建、不被指纹守卫吞掉。
        expiredSwitchUserIds = expiredSwitchUserIds.intersection(Set(models.map { $0.userId }))
        if let currentId = currentIdValue { expiredSwitchUserIds.remove(currentId) }
        for index in models.indices {
            models[index].isExpired = expiredSwitchUserIds.contains(models[index].userId)
        }
        // 扫 bug 第 9 项：切换卡只在账号变化时重建——指纹含每行
        // id/标题/handle/邮箱/头像/当前勾选，指纹不变即卡片内容与现行
        // 完全一致，直接保留现卡（不拆卡、不重建头像加载、不丢行态）；
        // 指纹变了（切号、增删号、改名/改头像）才走下面原有重建。
        // 切换/移除/添加的调用点仍调本函数，逻辑本身一字不动。
        let fingerprint = models.map { model in
            "\(model.userId)|\(model.title)|\(model.handle ?? "")|\(model.email ?? "")|\(model.avatarURL ?? "")|\(model.hasToken)|\(model.userId == currentIdValue)|\(model.isExpired)"
        }.joined(separator: ";")
        if switchCardBuilt, fingerprint == cachedSwitchFingerprint {
            accountSwitchWrap.isHidden = false
            return
        }
        for subview in accountSwitchWrap.subviews {
            subview.removeFromSuperview()
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
        cachedSwitchFingerprint = fingerprint
        switchCardBuilt = true
        accountSwitchWrap.isHidden = false
    }

    private func makeAccountSwitchRow(model: SwitchRowModel, isCurrent: Bool) -> UIView {
        let avatarContainer = UIView()
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.backgroundColor = BearyColors.surface2
        avatarContainer.layer.cornerRadius = 18
        avatarContainer.clipsToBounds = true
        let avatarImageView = UIImageView()
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        let avatarInitialLabel = UILabel()
        avatarInitialLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarInitialLabel.font = BearyDynamicType.smallActionFont()
        avatarInitialLabel.adjustsFontForContentSizeCategory = true
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
            // 06：有头像 URL 时先藏首字母（图到了只显图）；bearySetImage 无成功
            // 回调，加载失败时靠 onFailure 把字母放回来继续兜底。
            avatarInitialLabel.isHidden = true
            avatarImageView.bearySetImage(url: url, onFailure: { [weak avatarInitialLabel] _ in
                avatarInitialLabel?.isHidden = false
            })
        }
        let nameLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        nameLabel.font = BearyDynamicType.smallBodyFont()
        nameLabel.text = model.title
        var detailText: String
        if let handle = model.handle, !handle.isEmpty {
            detailText = "@" + handle + " · " + BearyAccountVault.maskedEmail(model.email)
        } else {
            detailText = BearyAccountVault.maskedEmail(model.email)
        }
        if model.isExpired {
            detailText += " · 登录已过期"
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
        // 按钮普查：裸 13pt 改 scaledFont，跟随系统字号（账号行高足，最大档不裁剪）。
        removeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        removeButton.titleLabel?.adjustsFontForContentSizeCategory = true
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
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        titleLabel.font = BearyDynamicType.smallBodyFont()
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
        // 账号隔离改造：导出进行中禁止切换——旧代码只查 isSwitchingAccount，
        // 导出按钮置灰但账号行照常可点，导出链中途切号会让 profile 与
        // entries 分属两个账号。导出中点切换行直接提示、不启动切换。
        guard !isExporting else {
            showToast("正在导出，请稍后再切换账号")
            return
        }
        if SessionManager.shared.currentUser?.id == accountIdValue {
            return
        }
        // 第八轮审计 01：注销与切换互斥——注销 POST 在途或 1.2 秒提示窗口内
        // 不许切号，否则注销成功回调会清当时当前账号（见 confirmDeleteAccount）。
        // 放在同号早退之后：点自己当前行不是切换，不应弹提示。
        guard !isDeleting else {
            showToast("正在注销，请稍后再切换账号")
            return
        }
        if expiredSwitchUserIds.contains(accountIdValue) {
            // 该号会话已被上次切换预检证实失效：不再发注定 401 的预检，
            // 直走过期重登（与下面 .expired 分支同一入口）。
            showToast("登录已过期，请重新登录")
            openLoginForAccountSwitch()
            return
        }
        isSwitchingAccount = true
        // 116 后扫查：切换要等一次 /me 网络往返，旧代码这段时间按钮毫无变化，
        // 点按像没点中。点下立刻置灰+禁用（成功时整组行重建，失败时下面复原）。
        sender.isEnabled = false
        sender.alpha = 0.5
        SessionManager.shared.switchToAccount(userId: accountIdValue) { [weak self] result in
            guard let self = self else { return }
            self.isSwitchingAccount = false
            sender.isEnabled = true
            sender.alpha = 1
            switch result {
            case .switched:
                // 先作废在途旧 /me（并放行 loadAll 的 isLoadingMe 守卫），
                // 再重拉新账号；否则 loadAll 被守卫丢弃、旧回包随后写回旧账号。
                self.meLoadGeneration += 1
                self.isLoadingMe = false
                self.loadAll()
                self.refreshAccountSwitchSection()
            case .alreadyCurrent:
                self.refreshAccountSwitchSection()
            case .expired:
                // 会话已死：先把该号标成过期并刷新卡片（行上见“登录已过期”，
                // 不再装成可直接切换），再弹重登页；取消回来时标记仍在。
                self.expiredSwitchUserIds.insert(accountIdValue)
                self.refreshAccountSwitchSection()
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
            // 第四轮审计 12：居中 Alert 改底部弹窗（文案不变）。
            BearyConfirmSheet.show(from: self, title: "添加账号", message: "最多 3 个账号，先移除一个", actions: [
                BearyConfirmSheet.Action(title: "知道了", style: .default),
            ])
            return
        }
        openLoginForAccountSwitch()
    }

    /// 添加 / 过期重登都走容器登录页（与 onRequireLogin 同路径）；容器
    /// 未接线时页内底 sheet 兜底（BearyLoginSheet.make），登录成功后刷新本页与列表。
    private func openLoginForAccountSwitch() {
        // 添加账号会话守卫：添加与切换过期重登共用本入口，进登录页前先
        // 抓拍原会话；取消时由登录页 onCancelled 恢复（容器通用登录页
        // 的 onCancelled 同样接了恢复，未登录直登时守卫未 arm、是空操作）。
        SessionManager.shared.beginAccountAddSession()
        if let handler = onRequireLogin {
            handler()
            return
        }
        let loginVC = BearyLoginSheet.make()
        loginVC.onCancelled = { [weak loginVC] in
            SessionManager.shared.cancelAccountAddSession()
            loginVC?.dismiss(animated: BearyMotion.animated(true))
        }
        loginVC.onLoggedIn = { [weak self, weak loginVC] referralText in
            // 新号登录成功先解 arm（当前态即新号，不得再恢复原号），
            // 再 dismiss + refreshMe 立新态、快照新号。
            SessionManager.shared.completeAccountAddSession()
            loginVC?.dismiss(animated: BearyMotion.animated(true)) {
                SessionManager.shared.refreshMe { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.loadAll()
                        self.refreshAccountSwitchSection()
                        // 审计登录杂项：邀请绑定反馈落点——进 App 后 BearyToast 一次。
                        if let text = referralText, !text.isEmpty {
                            BearyToast.show(in: self.view, message: BearyReferralFeedback.toastText(base: text, plusUntil: SessionManager.shared.currentUser?.plusUntil))
                        }
                    }
                }
            }
        }
        presentSettingsPage(loginVC)
    }

    @objc private func removeAccountButtonTapped(_ sender: UIButton) {
        let accountIdValue = sender.tag
        guard !isRemovingAccount else { return }
        let isCurrent = SessionManager.shared.currentUser?.id == accountIdValue
        let title = isCurrent ? "移除当前账号" : "移除账号"
        let message = "该账号将在本设备退出登录，其他账号不受影响。"
        // 第四轮审计 12：居中 Alert 改底部弹窗（文案与移除流程不变）。
        BearyConfirmSheet.show(from: self, title: title, message: message, actions: [
            BearyConfirmSheet.Action(title: "移除", style: .destructive) { [weak self] in
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
            },
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }

    /// 2026-10-29 第 12 项（合并 B）：退出登录 + 注销账户并入「账号操作」卡片，
    /// 仍列在设置页内（页底、版本脚注之上）。行为一字不动：退出仍走
    /// logoutButtonTapped（BearyAPI.logout + 清 cookie + 本地退出）；注销仍走
    /// deleteButtonTapped（两步确认 + 7 天冷静期软删除）；管理员隐藏注销行
    /// （连同其前分隔线一并藏，不留 stray 线，见 setAccountActionDeleteHidden）。
    /// 视觉批：账号操作卡一级只留退出登录，导出数据与注销收进其后
    /// 的「账号更多」折叠（点按展开）；退出／注销行为与管理员隐藏口径不动。
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
        deleteRowButton.titleLabel?.font = BearyDynamicType.secondaryFont()
        deleteRowButton.titleLabel?.adjustsFontForContentSizeCategory = true
        deleteRowButton.addTarget(self, action: #selector(deleteButtonTapped), for: .touchUpInside)
        deleteRowButton.bearyAddPressHaptic()
        let logoutRow = UIView()
        logoutRow.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.addSubview(logoutStandaloneButton)
        NSLayoutConstraint.activate([
            logoutStandaloneButton.topAnchor.constraint(equalTo: logoutRow.topAnchor),
            logoutStandaloneButton.centerXAnchor.constraint(equalTo: logoutRow.centerXAnchor),
            logoutStandaloneButton.widthAnchor.constraint(equalToConstant: 220),
            logoutStandaloneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.secondaryOutline(.regular).height),
            logoutStandaloneButton.bottomAnchor.constraint(equalTo: logoutRow.bottomAnchor),
        ])
        let deleteRow = UIView()
        deleteRow.translatesAutoresizingMaskIntoConstraints = false
        deleteRow.addSubview(deleteRowButton)
        // 审计 E2 第 23 项：忙碌图标挂在注销行内、原入口右侧（不改标题、不新增弹窗）。
        deleteRow.addSubview(deleteSpinner)
        NSLayoutConstraint.activate([
            deleteRowButton.topAnchor.constraint(equalTo: deleteRow.topAnchor),
            deleteRowButton.centerXAnchor.constraint(equalTo: deleteRow.centerXAnchor),
            deleteRowButton.bottomAnchor.constraint(equalTo: deleteRow.bottomAnchor),
            deleteSpinner.widthAnchor.constraint(equalToConstant: 20),
            deleteSpinner.heightAnchor.constraint(equalToConstant: 20),
            deleteSpinner.leadingAnchor.constraint(equalTo: deleteRowButton.trailingAnchor, constant: 8),
            deleteSpinner.centerYAnchor.constraint(equalTo: deleteRowButton.centerYAnchor),
        ])
        let group = makeGroupCard(title: "账号操作", rows: [logoutRow])
        group.card.translatesAutoresizingMaskIntoConstraints = false
        accountActionWrap.addSubview(group.card)
        // 视觉批：账号披露组——导出数据（安全组建、此处承载）＋注销，
        // 体内排布为 [分隔线，导出行包容器，分隔线，注销行包容器]。
        var disclosureRows: [UIView] = []
        if let exportRow = exportRowForDisclosure {
            disclosureRows.append(exportRow)
        }
        disclosureRows.append(deleteRow)
        let accountDisclosureValue = makeDisclosureCard(title: "账号更多", rows: disclosureRows)
        accountDisclosureValue.headerButton.addTarget(self, action: #selector(accountDisclosureTapped), for: .touchUpInside)
        // 注销行前的分隔线：披露体栈里注销包容器前一位即分隔线，管理员隐藏时一并藏。
        if let deleteWrap = accountDisclosureValue.bodyWrappers.last {
            accountActionDeleteWrap = deleteWrap
            if let deleteIndex = accountDisclosureValue.bodyStack.arrangedSubviews.firstIndex(of: deleteWrap),
               deleteIndex > 0 {
                accountActionDeleteSeparator = accountDisclosureValue.bodyStack.arrangedSubviews[deleteIndex - 1]
            }
        }
        accountDisclosure = accountDisclosureValue
        accountDisclosureValue.card.translatesAutoresizingMaskIntoConstraints = false
        accountActionWrap.addSubview(accountDisclosureValue.card)
        // 审计 P2-22：退出后本机残留明示——日记/回收站/图片缓存随退出清除，
        // 未发布草稿仍保存在本设备（按账号分桶，换号不可见），登录同一账号可继续编辑。
        let logoutFootnote = UILabel()
        logoutFootnote.translatesAutoresizingMaskIntoConstraints = false
        // P1-7：账号操作组脚注辅助文案走动态字体（已是 0 行）。
        logoutFootnote.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        logoutFootnote.adjustsFontForContentSizeCategory = true
        logoutFootnote.textColor = BearyColors.gray
        logoutFootnote.numberOfLines = 0
        logoutFootnote.text = "退出登录后，已同步的日记与回收站缓存会从本设备清除；未发布的草稿仍保留，登录同一账号后可继续编辑。"
        accountActionWrap.addSubview(logoutFootnote)
        NSLayoutConstraint.activate([
            group.card.topAnchor.constraint(equalTo: accountActionWrap.topAnchor),
            group.card.leadingAnchor.constraint(equalTo: accountActionWrap.leadingAnchor),
            group.card.trailingAnchor.constraint(equalTo: accountActionWrap.trailingAnchor),
            accountDisclosureValue.card.topAnchor.constraint(equalTo: group.card.bottomAnchor, constant: 20),
            accountDisclosureValue.card.leadingAnchor.constraint(equalTo: accountActionWrap.leadingAnchor),
            accountDisclosureValue.card.trailingAnchor.constraint(equalTo: accountActionWrap.trailingAnchor),
            logoutFootnote.topAnchor.constraint(equalTo: accountDisclosureValue.card.bottomAnchor, constant: 8),
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
        // 开发者模式入口（2026-11-08 新增）：版本号连点 5 次进入，平时完全看不见；
        // 手势挂在 wrap 上（label 是局部变量，不存引用）。
        let devTap = UITapGestureRecognizer(target: self, action: #selector(versionFooterTapped))
        versionFooterWrap.addGestureRecognizer(devTap)
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

    private func retryButtonTapped() {
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
        let editVC = BearyEditProfileViewController(displayName: user.displayName, handle: user.handle, avatarUrl: user.avatar, coverUrl: coverUrl, userId: user.id)
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
        presentSettingsPage(editVC)
    }

    /// F8：退出登录（网页 account.html logoutBtn 口径：直接 POST、无二次确认；
    /// App 现有退出逻辑 = BearyAPI.logout + 清本地 cookie + 本地退出）。
    @objc private func logoutButtonTapped() {
        // 第七轮审计 03：登出回包账号绑定——发起时捕获账号 ID＋authEpoch，
        // 回包先校验；已切号时只定向清发起账号，不碰当前号、不清 cookie、
        // 不关页/弹登录（本次退出对当前会话无事可做）。
        let accountId = SessionManager.shared.currentUser?.id
        let epoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.logout { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    guard SessionManager.shared.isCurrentAuthSession(accountId: accountId, epoch: epoch) else {
                        if let accountId = accountId {
                            SessionManager.shared.purgeLocalState(forAccountId: accountId)
                        }
                        return
                    }
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

    /// 116 数据填入动效：文案变化时只淡入该元素本身（alpha 0→1、
    /// 0.25s，不动 transform／布局、不重建节点、不缩放弹一下）；同值
    /// 不赋值不重播；减动效或未进窗口时直设终值。容器首次出现时
    /// 只淡入容器本身，已可见时不重播。
    private func setLabelTextFaded(_ label: UILabel, _ text: String) {
        guard label.text != text else { return }
        label.text = text
        guard !UIAccessibility.isReduceMotionEnabled, label.window != nil else {
            label.alpha = 1
            return
        }
        label.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            label.alpha = 1
        })
    }

    private func fadeView(_ view: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            view.alpha = 1
            return
        }
        view.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            view.alpha = 1
        })
    }

    private func fadeViewIfAppearing(_ view: UIView, wasHidden: Bool) {
        guard wasHidden, !view.isHidden else { return }
        fadeView(view)
    }

    private func loadAll() {
        guard !isLoadingMe else { return }
        isLoadingMe = true
        meLoadGeneration += 1
        let meGeneration = meLoadGeneration
        // A2：新一轮 loadAll 丢弃上一轮的 Plus/设备缓存结果（账号切换后
        // 不复用旧号数据）；本轮内 loadPlusDetail/loadSessions 的两次调用点
        // （缓存路径先拉 + /me 成功后再拉）共用 loader 的同一份在途结果，
        // 各只发一次请求。
        plusDetailLoad.invalidate()
        accountSessionsLoad.invalidate()
        // 缓存优先：登录态下本机已有同一份用户信息（SessionManager.currentUser），
        // 先显缓存、不转菊花，随后静默 fetchMe 对齐；无缓存时走现行加载态路径。
        if let cached = SessionManager.shared.currentUser {
            meUser = cached
            failureStateView.isHidden = true
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
                    // 旧代次回包（切换前发出）：整段丢弃，不碰 isLoadingMe
                    //（新一轮正在飞，它的回包自会复位），不写回旧账号。
                    guard meGeneration == self.meLoadGeneration else { return }
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
                        // 静默刷新失败：保持缓存内容不变，不显示 failureStateView。
                        return
                    }
                }
            }
            return
        }
        loadingView.startSpinning()
        loadingView.isHidden = false
        failureStateView.isHidden = true
        loginWrap.isHidden = true
        contentWrap.isHidden = true
        accountSecurityWrap.isHidden = true
        accountActionWrap.isHidden = true
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard meGeneration == self.meLoadGeneration else { return }
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
                    // 116：三组容器随 /me 到达首次出现时只淡入容器本身。
                    let contentWasHidden = self.contentWrap.isHidden
                    let securityWasHidden = self.accountSecurityWrap.isHidden
                    let actionWasHidden = self.accountActionWrap.isHidden
                    self.contentWrap.isHidden = false
                    self.accountSecurityWrap.isHidden = false
                    self.accountActionWrap.isHidden = false
                    self.fadeViewIfAppearing(self.contentWrap, wasHidden: contentWasHidden)
                    self.fadeViewIfAppearing(self.accountSecurityWrap, wasHidden: securityWasHidden)
                    self.fadeViewIfAppearing(self.accountActionWrap, wasHidden: actionWasHidden)
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
                    self.failureStateView.isHidden = false
                }
            }
        }
    }

    /// 第四轮审计 15：同步状态行只按 BearyEntrySync.currentSyncState 写文案；
    /// 变化时只淡入本 label（与 ID 卡其他行同口径）。
    private func refreshSyncStateRow() {
        setLabelTextFaded(syncStateLabel, BearyEntrySync.shared.currentSyncState.displayText)
    }

    @objc private func handleSyncStateChanged() {
        refreshSyncStateRow()
    }

    private func fillIdCard(user: MeUser) {
        let name = user.displayName ?? ""
        let emailPrefix = (user.email ?? "").components(separatedBy: "@").first ?? ""
        let displayName = !name.isEmpty ? name : (!emailPrefix.isEmpty ? emailPrefix : "–")
        // F5：网页 heroName 就是名字本身，不带「你好，」前缀。
        // 116：ID 卡各文案随 /me 到达变化时只淡入该 label 本身。
        setLabelTextFaded(heroNameLabel, displayName)
        setLabelTextFaded(heroEmailLabel, user.email ?? "–")
        setLabelTextFaded(avatarInitialLabel, String(displayName.prefix(1)))
        avatarImageView.image = nil
        // 审计追加：与编辑页同法——/me 下发的 avatar 本就是 data:image;base64，
        // 直接解码显示，不再跳过 data: 只剩首字母占位；解码失败回落原路径。
        // 首字母 label 压在照片上层：有图时藏字、无图时显字、URL 加载失败时回显字兜底。
        if let avatar = user.avatar, !avatar.isEmpty, avatar.hasPrefix("data:"),
           let commaIndex = avatar.firstIndex(of: ","),
           let avatarData = Data(base64Encoded: String(avatar[avatar.index(after: commaIndex)...])),
           let avatarImage = UIImage(data: avatarData) {
            avatarImageView.image = avatarImage
            avatarInitialLabel.isHidden = true
        } else if let avatar = user.avatar, !avatar.isEmpty {
            avatarInitialLabel.isHidden = true
            avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(avatar)) { [weak self] _ in
                self?.avatarInitialLabel.isHidden = false
            }
        } else {
            avatarInitialLabel.isHidden = false
        }
        setLabelTextFaded(idCreatedLabel, BearyAccountText.dateString(ms: user.createdAt))
        // ID 卡会员行：只留状态词（Plus 会员 / 普通用户），不走 plus-detail；
        // 全修 3-2：到期日、永久、内测限免一律只留在 Plus 组，不在此重复。
        setLabelTextFaded(idPlusLabel, user.plus == true ? "Plus 会员" : "普通用户")
        // 第四轮审计 15：同步状态行跟 /me 到达一起刷新（进页时 buildIdCard
        // 已按快照写过初值；同步进行中变迁靠广播补刷，见 viewDidLoad）。
        refreshSyncStateRow()
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
        // 116：ID 号变化时只淡入该 label（字距属性不变，只换文案）。
        let oldIdText = idValueLabel.attributedText?.string
        idValueLabel.attributedText = NSAttributedString(string: idText, attributes: [.kern: 2])
        if oldIdText != idText { fadeView(idValueLabel) }
    }

    // C4：fillAccountRows 已随旧账户组删除（显示名称 / 用户名 / 邮箱 /
    // 注册时间四行不再渲染；ID 卡 fillIdCard 仍呈现名 / 邮箱 / 注册时间 / 会员）。

    private func loadPlusDetail(force: Bool = false) {
        // 第三轮审计 13：同一代次内只请求一次（loadAll 缓存路径里 /me 成功
        // 后的第二轮调用直接跳过，第二轮不依赖 /me 的任何字段）；force 供
        // 明确变更后的刷新用。
        guard force || plusDetailRequestedGeneration != meLoadGeneration else { return }
        plusDetailRequestedGeneration = meLoadGeneration
        // 静默刷新：已有旧值时不先清标签/发放行，新值到了再覆盖；
        // 首拉（plusDetail 为 nil）才走现行置“–”+ 空发放态。
        if plusDetail == nil {
            plusEntryLabel.text = "–"
            plusStatusLabel.text = "–"
            plusFreeLabel.text = "–"
            plusPersonalLabel.text = "–"
            rebuildGrants(grants: nil, failed: false)
        }
        // A2：force 时先丢弃本轮缓存再拉取（与 loadSessions 同款）；
        // 其余调用点（loadAll 两次调用）共用同一份在途结果，同轮次内
        // 只发一次请求。
        if force { plusDetailLoad.invalidate() }
        // 第七轮审计 02：发起时拍代次＋账号 ID＋鉴权代次，回包三重门
        // 校验——切号／退出后旧回包整单丢弃，不写界面、不弹登录门。
        // A2 的 loader 回包同样过这道门（缓存值若是旧号的，由 loadAll
        // 开头的 invalidate 丢弃，不会走到这里）。
        plusDetailGeneration += 1
        let requestGeneration = plusDetailGeneration
        let requestAccountId = BearyAPI.shared.authAccountId
        let requestEpoch = BearyAPI.shared.authEpoch
        // A2：同轮次内第二次调用（/me 成功后）不再另发请求——在途则排队
        // 等同一份回包，已取到则直接回缓存填表；失败不缓存，下次可重拉。
        plusDetailLoad.load { [weak self] result in
            guard let self = self else { return }
            guard self.isCurrentAuxResponse(generation: requestGeneration, currentGeneration: self.plusDetailGeneration, accountId: requestAccountId, epoch: requestEpoch) else { return }
            switch result {
            case .success(let detail):
                self.plusDetail = detail
                self.auxDataAccountId = requestAccountId
                self.fillPlusDetail(detail: detail)
            case .failure(let error):
                if case .unauthorized = error {
                    self.onRequireLogin?()
                    return
                }
                if case .cancelled = error { return }
                if self.plusDetail != nil { return }
                self.setLabelTextFaded(self.plusStatusLabel, "加载失败")
                self.grantsLoadFailed = true
                self.rebuildGrants(grants: nil, failed: true)
            }
        }
    }

    private func fillPlusDetail(detail: BearyPlusDetailResponse) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let permanent = detail.permanent == true
        let effective = detail.effectiveUntil ?? 0
        // 116：Plus 组各文案随数据到达变化时只淡入该 label 本身（文案
        // 先算后一次赋值，分支逻辑与原口径一字不动）。
        let statusText: String
        if permanent {
            statusText = "Plus 会员 · 永久"
        } else if effective > now {
            statusText = "Plus 会员 · 至 " + BearyAccountText.dateString(ms: effective)
        } else {
            statusText = "普通用户"
        }
        setLabelTextFaded(plusStatusLabel, statusText)
        // 入口行尾与当前状态同源：永久→永久有效、有期→到期日、无期→未开通。
        let plusEntryText: String
        if permanent {
            plusEntryText = "永久有效"
        } else if effective > now {
            plusEntryText = "至 " + BearyAccountText.dateString(ms: effective)
        } else {
            plusEntryText = "未开通"
        }
        setLabelTextFaded(plusEntryLabel, plusEntryText)
        let freeUntil = detail.freeUntil ?? 0
        if freeUntil > 0 {
            let freeRowWasHidden = plusFreeRow.isHidden
            plusFreeWrapper?.isHidden = false
            plusFreeSeparator?.isHidden = false
            plusFreeRow.isHidden = false
            if freeUntil > now {
                setLabelTextFaded(plusFreeLabel, "全体内测用户免费 · 至 " + BearyAccountText.dateString(ms: freeUntil))
            } else {
                setLabelTextFaded(plusFreeLabel, "已结束 · " + BearyAccountText.dateString(ms: freeUntil) + " 到期")
            }
            fadeViewIfAppearing(plusFreeRow, wasHidden: freeRowWasHidden)
        } else {
            // 网页口径：free_until 为 0 时整行隐藏（藏包容器，见 makeGroupCard）。
            // 其与来源明细行之间的分隔线一并收起，否则展开态留双线。
            plusFreeWrapper?.isHidden = true
            plusFreeSeparator?.isHidden = true
            plusFreeRow.isHidden = true
        }
        let personal = detail.personalUntil ?? 0
        let personalText: String
        if permanent {
            personalText = "永久会员"
        } else if personal > now {
            var text = "至 " + BearyAccountText.dateString(ms: personal)
            if freeUntil > 0 && personal > freeUntil {
                let days = (personal - freeUntil) / 86400000
                text += " · 限免结束后保留 \(days) 天"
            } else if freeUntil > now {
                text += " · 与限免期重叠"
            }
            personalText = text
        } else {
            personalText = "暂无（好友注册并绑定邀请码，双方各得 +30 天）"
        }
        setLabelTextFaded(plusPersonalLabel, personalText)
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

    /// A2：force 仅撤销其他设备成功后用（现行单独刷新口径不变）——
    /// 先丢弃本轮缓存再拉取；其余调用点（loadAll 两次调用）共用同一份
    /// 在途结果，同轮次内只发一次请求。
    private func loadSessions(force: Bool = false) {
        // 第三轮审计 13：与 loadPlusDetail 同款——同一代次内只请求一次；
        // 退出其他设备成功后的刷新走 force: true。
        guard force || sessionsRequestedGeneration != meLoadGeneration else { return }
        sessionsRequestedGeneration = meLoadGeneration
        // 首拉前不再预先 rebuildSessions(nil)：空标签只在拉取返回空后出现，
        // 失败态只在拉取失败后出现（现行失败分支不动）；静默刷新不再先清旧内容。
        // 第七轮审计 02：发起时拍代次＋账号 ID＋鉴权代次，回包三重门
        // 校验——切号／退出后旧回包整单丢弃，不写界面、不弹登录门。
        // A2 的 loader 回包同样过这道门（缓存值若是旧号的，由 loadAll
        // 开头的 invalidate 丢弃，不会走到这里）。
        sessionsGeneration += 1
        let requestGeneration = sessionsGeneration
        let requestAccountId = BearyAPI.shared.authAccountId
        let requestEpoch = BearyAPI.shared.authEpoch
        if force { accountSessionsLoad.invalidate() }
        accountSessionsLoad.load { [weak self] result in
            guard let self = self else { return }
            guard self.isCurrentAuxResponse(generation: requestGeneration, currentGeneration: self.sessionsGeneration, accountId: requestAccountId, epoch: requestEpoch) else { return }
            switch result {
            case .success(let resp):
                let list = resp.sessions ?? []
                self.accountSessions = list
                self.auxDataAccountId = requestAccountId
                self.sessionsLoadFailed = false
                // 全修 4-4（二选一取“计数文案标活跃、列表不过滤”）：/api/account/sessions
                // 下发 activeCount（与 sessions 全量分开的字段，过期行以 expired 另标灰化），
                // 故计数用 activeCount 并标“（活跃）”，列表仍含过期行（灰化 + “已过期”注，
                // 用户可见完整登录史，不过滤）；activeCount 缺失时才回落全量计数，此时不标
                // “（活跃）”（回落值含过期行，标活跃会误导）。
                if let active = resp.activeCount {
                    self.setLabelTextFaded(self.deviceCountLabel, "共 \(active) 台设备（活跃）")
                } else {
                    self.setLabelTextFaded(self.deviceCountLabel, "共 \(list.count) 台设备")
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

    /// 2026-10-29 第 11 项：设备列表已抽成独立页——本函数不再内联建设备行，
    /// 只缓存失败态（列表数据走既有 accountSessions；子页打开时传入，未拉到
    /// 时子页自己拉一次）。行格式（设备名 15 墨 + 状态 pill：「当前」绿、
    /// 「已过期」灰 + 「地区 · 上次活跃 dateTime」13 灰，过期行不再降
    /// 透明度、副文案不再拼「· 已过期」）已原样搬进 BearyDevicesViewController；
    /// 原错峰淡入 fadeInNewStackRows 随内联列表一并删除（子页内无此动效）。
    private func rebuildSessions(sessions: [BearyAccountSession]?, failed: Bool) {
        sessionsLoadFailed = failed
    }

    // MARK: - 退出其他设备

    @objc private func logoutOthersButtonTapped() {
        guard !isLoggingOutOthers else { return }
        // 第四轮审计 12：居中 Alert 改底部弹窗（文案与退出流程不变）。
        BearyConfirmSheet.show(from: self, title: "退出其他设备", message: "将退出除当前设备外的所有登录，确定继续？", actions: [
            BearyConfirmSheet.Action(title: "退出", style: .destructive, handler: { [weak self] in
                self?.confirmLogoutOthers()
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }

    /// 审计 E2 第 23 项：请求期原入口忙碌外观——钮禁用 + 半透明 + 既有
    /// 加载图标旋转；终结时恢复。标题文案、成功失败提示与确认步骤不变。
    private func setLogoutOthersBusy(_ busy: Bool) {
        logoutOthersButton.isEnabled = !busy
        logoutOthersButton.alpha = busy ? 0.6 : 1
        if busy { logoutOthersSpinner.startSpinning() } else { logoutOthersSpinner.stopSpinning() }
    }

    private func setDeleteBusy(_ busy: Bool) {
        deleteRowButton.isEnabled = !busy
        deleteRowButton.alpha = busy ? 0.6 : 1
        if busy { deleteSpinner.startSpinning() } else { deleteSpinner.stopSpinning() }
    }

    private func confirmLogoutOthers() {
        isLoggingOutOthers = true
        setLogoutOthersBusy(true)
        BearyAPI.shared.revokeOtherSessions { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoggingOutOthers = false
                self.setLogoutOthersBusy(false)
                switch result {
                case .success:
                    self.showToast("已退出其他设备")
                    self.loadSessions(force: true)
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
        // 第 5 条定版：默认删除全部日记；显式勾选（默认不勾）才保留公开过的日记。
        var keepPublicDiaries = false
        BearyConfirmSheet.show(from: self, title: "注销账户", message: "7 天冷静期内登录可取消注销。7 天后账户正式注销，全部日记将被删除。\n\n注销后，你的 Plus、未到账的邀请奖励和收藏会一并作废。", actions: [
            BearyConfirmSheet.Action(title: "继续注销", style: .destructive, handler: { [weak self] in
                self?.showDeleteSecondConfirm(keepPublicDiaries: keepPublicDiaries)
            }),
            BearyConfirmSheet.Action(title: "再想想", style: .cancel),
        ], toggle: BearyConfirmSheet.Toggle(title: "保留我公开过的日记", subtitle: "供曾读过的人回看，作者显示为“用户已注销”", isOn: false, onChange: { isOn in
            keepPublicDiaries = isOn
        }))
    }

    private func showDeleteSecondConfirm(keepPublicDiaries: Bool) {
        BearyConfirmSheet.show(from: self, title: "最后确认", message: "真的要注销吗？此操作 7 天后不可撤销。", actions: [
            BearyConfirmSheet.Action(title: "确认注销", style: .destructive, handler: { [weak self] in
                self?.confirmDeleteAccount(keepPublicDiaries: keepPublicDiaries)
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }

    private func confirmDeleteAccount(keepPublicDiaries: Bool) {
        isDeleting = true
        setDeleteBusy(true)
        // 第八轮审计 01：注销成功回调验证发起时身份——只拦切换入口不够，
        // 1.2 秒提示窗口内仍可能切号；onAccountDeleted 清的是当时当前账号，
        // 失配时放弃清理、只复位。代次只在登录/切号/退出/401 清态时推进，
        // 同一登录态内日常 /me 成功不推进，不会误判。
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.requestAccountDelete(keepPublic: keepPublicDiaries) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    // 回包前已切号：A 的注销服务端已生效，但本地不再是 A 的
                    // 会话——不写 A 的冷静期、不排清理定时器，只复位。
                    guard SessionManager.shared.currentUser?.id == requestAccountId,
                          BearyAPI.shared.authEpoch == requestEpoch else {
                        self.isDeleting = false
                        self.setDeleteBusy(false)
                        return
                    }
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
                        guard let self = self else { return }
                        // 1.2 秒窗口内又切了号：同上，放弃清理，只复位。
                        guard SessionManager.shared.currentUser?.id == requestAccountId,
                              BearyAPI.shared.authEpoch == requestEpoch else {
                            self.isDeleting = false
                            self.setDeleteBusy(false)
                            return
                        }
                        self.onAccountDeleted?()
                        self.isDeleting = false
                        // 忙碌态与 isDeleting 同窗口复位（1.2 秒内仍防重入）。
                        self.setDeleteBusy(false)
                    }
                case .failure(let error):
                    self.isDeleting = false
                    self.setDeleteBusy(false)
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                        return
                    }
                    if case .cancelled = error { return }
                    if case .server(let code, _) = error, code == "admin_cannot_delete" {
                        self.showToast("管理员账号不能注销")
                        return
                    }
                    self.showToast("注销失败，请重试")
                }
            }
        }
    }

    // MARK: - 导出我的数据（客户端拼 JSON，不新编服务端接口）

    /// 导出钉住的账号与凭据：token = 导出开始时共享桶里的当前会话
    /// token（只读一次，之后全程用它发隔离请求）；epoch = 同一时刻的
    /// 鉴权代际；userId = 隔离 /me 回包确认后的账号 id（导出开始时
    /// currentUser 可能尚未刷新，故先以 /me 为准，之后各步再比对）。
    private typealias BearyExportPin = (userId: Int?, token: String, epoch: Int)

    /// 导出账号是否已变（主线程调用）：epoch 变化（切换/退出/新登录/
    /// 401 清态都会推 epoch）即变；currentUser 已存在且与钉住 id 不
    /// 同也算变。currentUser 为 nil 时不以 id 判（导出开始时可能尚未
    /// 刷新，epoch 已覆盖切换/退出情形），避免误杀。
    private func exportPinChanged(_ pin: BearyExportPin) -> Bool {
        if BearyAPI.shared.authEpoch != pin.epoch { return true }
        if let pinnedId = pin.userId, let currentId = SessionManager.shared.currentUser?.id, currentId != pinnedId {
            return true
        }
        return false
    }

    /// 账号变化取消整次导出：只 toast、不拼文件、不出分享面板。
    /// 调用时导出链尚未产生文件（文件只在 buildAndShareExport 写盘，
    /// 该处取消另行删已写文件，见该方法）；分享面板尚未 present，
    /// 故无“停止分享”动作可做——已 present 的分享不在导出进行中，
    /// 不属本取消口径（见 PR 残留风险）。
    private func cancelExportForAccountChange() {
        isExporting = false
        exportRowButton.isEnabled = true
        setExportProgress(nil)
        showToast("账号已切换，导出已取消")
    }

    @objc private func exportButtonTapped() {
        guard !isExporting else { return }
        // 账号隔离改造：导出全程固定导出账号与凭据。旧流程开头用共享
        // cookie 的 /me 拿 user，之后分页全走共享 cookie——中途切号
        // 会让 profile 是 A、entries 是 B。本流程：先读当前会话 token
        // 并钉住 epoch，再用该 token 走隔离 /me 确认账号；之后会话、
        // 我的、信箱、赞过四步全走该 token 的隔离请求，任一步（主线程
        // 边界）发现 epoch/账号变化即取消整单、不出文件。
        // 无当前会话 token 时不启动导出、直接走登录门（旧流程此时会
        // 先 toast“正在导出…”再失败+弹登录，本处直接弹登录、不留
        // “导出失败”的误导 toast）。
        guard let token = SessionManager.shared.currentSessionToken(), !token.isEmpty else {
            onRequireLogin?()
            return
        }
        let startEpoch = BearyAPI.shared.authEpoch
        isExporting = true
        exportRowButton.isEnabled = false
        showToast("正在导出…")
        setExportProgress("正在导出…")
        BearyAPI.shared.fetchMeWithToken(token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // 隔离 /me 在途时切号/退出都会推 epoch：先判变化再认回包。
                if BearyAPI.shared.authEpoch != startEpoch {
                    self.cancelExportForAccountChange()
                    return
                }
                switch result {
                case .success(let user):
                    guard let userValue = user, let userId = userValue.id else {
                        self.finishExportFailed()
                        self.onRequireLogin?()
                        return
                    }
                    self.exportWithUser(userValue, pin: (userId: userId, token: token, epoch: startEpoch))
                case .failure(let error):
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
            self?.exportDetailLabel?.text = text ?? "导出 JSON，包含账户资料、日记和点赞记录"
        }
    }

    private func exportWithUser(_ user: MeUser, pin: BearyExportPin) {
        var sessionsResp: BearyAccountSessionsResponse?
        var mineEntries: [Entry] = []
        var mailboxEntries: [Entry] = []
        var likedEntries: [Entry] = []
        // 第 7 项：分页结果不再静默丢弃——任一 scope 失败即整单 fail-closed，
        // 任一 scope 触顶即整单走部分导出标注；失败优先于触顶（先判失败）。
        var exportFailedReason: String?
        var exportTruncated = false
        var sessionsFailed = false
        // 账号隔离改造：分页中途发现账号变化时 fetchScopePage 以
        // reason="账号已切换" 回包（见该方法）；各 scope 边界的主线程
        // 检查（下）在下一步开始前就停链，不等整条链跑完，finish 处
        // 的 exportPinChanged 复查兜底最后一 scope 回包后才变的情形。
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
            // 账号变化取消优先于失败/触顶：只 toast 取消、不拼 JSON、
            // 不出文件、不出分享面板；无残留文件（文件只在
            // buildAndShareExport 写盘，本处根本没进该方法）。
            if self.exportPinChanged(pin) {
                self.cancelExportForAccountChange()
                return
            }
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
                // 第四轮审计 12：居中 Alert 改底部弹窗（文案不变；点“继续分享”
                // 先关 sheet 再拼文件出分享面板，不叠层）。
                BearyConfirmSheet.show(from: self, title: "部分导出", message: "本次仅导出 \(totalCount) 篇，未包含全部数据。文件包含账户资料、私密日记与登录设备信息，请只分享给可信的对象。是否继续分享这部分数据？", actions: [
                    BearyConfirmSheet.Action(title: "继续分享", style: .default, handler: { [weak self] in
                        self?.buildAndShareExport(user: user, pin: pin, sessionsResp: sessionsResp, mineEntries: mineEntries, mailboxEntries: mailboxEntries, likedEntries: likedEntries, sensitiveNoticeShown: true)
                    }),
                    BearyConfirmSheet.Action(title: "取消", style: .cancel),
                ])
                return
            }
            self.buildAndShareExport(user: user, pin: pin, sessionsResp: sessionsResp, mineEntries: mineEntries, mailboxEntries: mailboxEntries, likedEntries: likedEntries)
        }
        setExportProgress("正在导出（1/4）登录设备…")
        // 账号隔离改造：会话步走钉住 token 的隔离请求；回包先回主线程
        // 查钉住账号，变了即取消停链、不进下一 scope。三个日记 scope
        // 同理：fetchAllEntries 全程用钉住 token，scope 回包先回主线程
        // 查一次再进下一步；分页内部另有 epoch 检查（见 fetchScopePage）。
        BearyAPI.shared.fetchAccountSessionsWithToken(pin.token) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.exportPinChanged(pin) {
                    self.cancelExportForAccountChange()
                    return
                }
                // 审计 P1-23：会话拉取失败不得静默丢弃 sessions 让 JSON 看似完整——
                // 整单 fail-closed，只 toast、不拼 JSON、不出文件（与三个日记 scope 同口径）。
                if case .success(let resp) = result {
                    sessionsResp = resp
                } else {
                    sessionsFailed = true
                }
                self.setExportProgress("正在导出（2/4）我的日记…")
                self.fetchAllEntries(scope: .mine, pin: pin) { result in
                    DispatchQueue.main.async {
                        if self.exportPinChanged(pin) || result.reason == "账号已切换" {
                            self.cancelExportForAccountChange()
                            return
                        }
                        applyScopeResult(result, &mineEntries)
                        self.setExportProgress("正在导出（3/4）私密日记…")
                        self.fetchAllEntries(scope: .mailbox, pin: pin) { result in
                            DispatchQueue.main.async {
                                if self.exportPinChanged(pin) || result.reason == "账号已切换" {
                                    self.cancelExportForAccountChange()
                                    return
                                }
                                applyScopeResult(result, &mailboxEntries)
                                self.setExportProgress("正在导出（4/4）赞过…")
                                self.fetchAllEntries(scope: .liked, pin: pin) { result in
                                    DispatchQueue.main.async {
                                        if self.exportPinChanged(pin) || result.reason == "账号已切换" {
                                            self.cancelExportForAccountChange()
                                            return
                                        }
                                        applyScopeResult(result, &likedEntries)
                                        finish()
                                    }
                                }
                            }
                        }
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
    private func buildAndShareExport(user: MeUser, pin: BearyExportPin, sessionsResp: BearyAccountSessionsResponse?, mineEntries: [Entry], mailboxEntries: [Entry], likedEntries: [Entry], sensitiveNoticeShown: Bool = false) {
        // 主线程：进入生成阶段——直出路径沿用已置的 isExporting/禁用态，触顶确认
        // 路径在此重新置位；两种路径都在文件写完后统一复原。
        // 账号隔离改造：生成前（触顶确认后才进本方法，确认到生成之间
        // 可能已切号）先查钉住账号，变了即取消、不写文件；写盘后、
        // present 分享面板前再查一次，变了即删已写文件、不 present。
        if exportPinChanged(pin) {
            cancelExportForAccountChange()
            return
        }
        // 第十轮审计 #9：分享前提示敏感内容——文件含账户资料、私密日记与
        // 登录设备信息。直出路径在此先弹一次确认再生成；触顶路径已在
        // “部分导出”确认里带过同一句，不再重复弹。取消／直接关闭只复原
        // 导出态、不出文件、不出分享面板（不 toast，用户主动取消）。
        if !sensitiveNoticeShown {
            BearyConfirmSheet.show(from: self, title: "导出包含敏感内容", message: "文件包含账户资料、私密日记与登录设备信息，请只分享给可信的对象。", actions: [
                BearyConfirmSheet.Action(title: "继续分享", style: .default, handler: { [weak self] in
                    self?.buildAndShareExport(user: user, pin: pin, sessionsResp: sessionsResp, mineEntries: mineEntries, mailboxEntries: mailboxEntries, likedEntries: likedEntries, sensitiveNoticeShown: true)
                }),
                BearyConfirmSheet.Action(title: "取消", style: .cancel, handler: { [weak self] in
                    guard let self = self else { return }
                    self.isExporting = false
                    self.exportRowButton.isEnabled = true
                    self.setExportProgress(nil)
                }),
            ], onDismissWithoutAction: { [weak self] in
                guard let self = self else { return }
                self.isExporting = false
                self.exportRowButton.isEnabled = true
                self.setExportProgress(nil)
            })
            return
        }
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
                // 生成期间切号：删刚写的文件、不出分享面板（分享面板
                // 一旦 present 即不在导出进行中，见 cancel 说明）。
                if self.exportPinChanged(pin) {
                    try? FileManager.default.removeItem(at: fileURL)
                    self.cancelExportForAccountChange()
                    return
                }
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

    /// 审计四轮 16：启动时清掉过期导出临时文件——只认 teddyhn-data- 前缀、
    /// 只清超过 24 小时的文件，不碰 tmp 里其他东西。分享收起即删仍是主路径，
    /// 本处只兜中途退出残留。
    /// AppDelegate 启动时在后台调一次。
    enum BearyExportTempFileCleanup {
        private static let staleInterval: TimeInterval = 24 * 60 * 60

        static func cleanStaleExportFiles() {
            DispatchQueue.global(qos: .utility).async {
                let fileManager = FileManager.default
                let tmp = fileManager.temporaryDirectory
                guard let names = try? fileManager.contentsOfDirectory(atPath: tmp.path) else { return }
                let now = Date()
                for name in names where name.hasPrefix("teddyhn-data-") {
                    let url = tmp.appendingPathComponent(name)
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue else { continue }
                    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                    let stamp = (attributes?[.creationDate] as? Date)
                        ?? (attributes?[.modificationDate] as? Date)
                    if let stamp = stamp, now.timeIntervalSince(stamp) > staleInterval {
                        try? fileManager.removeItem(at: url)
                    }
                }
            }
        }
    }

    /// 第 7 项分页结果：entries=已取条目；complete=true 时 reason 恒为 nil；
    /// complete=false 的情形——某页请求失败（reason="第 X 页失败"，X=depth+1，
    /// depth 从 0 计故首失败页为“第 1 页失败”；回包缺 entries 键、满页末条缺
    /// createdAt 游标均视同本页失败，同 reason）或已取满 20 页仍可能有下一页
    /// （reason="已达 20 页上限”）。调用方据此 fail-closed（失败）/ 部分标注（触顶），
    /// 再不允许静默拿已取数据当完整文件出。
    private typealias BearyExportPageResult = (entries: [Entry], complete: Bool, reason: String?)

    /// 分页拉全一个 scope：limit=50、guard 20 页（网页 fetchAll 同口径），
    /// 游标 before + before_id（App fetchEntries 既有口径，服务端 created_at DESC, id DESC）。
    /// 账号隔离改造：分页全程走钉住 token 的隔离请求；每页发出前与回包
    /// 后各查一次 epoch——切换/退出/401 都会推 epoch，故 epoch 变化即
    /// 账号变化，以 reason="账号已切换" 回包，调用方（主线程边界）据
    /// 此取消整单。epoch 读取走 BearyAPI 的串行队列，分页后台线程读
    /// 安全；id 比对留给主线程边界（exportPinChanged），不在此做。
    /// complete=false 另有情形——账号已切换（reason 如上），
    /// 调用方不得把它当失败/触顶处理（见 exportWithUser 链）。
    private func fetchAllEntries(scope: BearyAPI.Scope, pin: BearyExportPin, completion: @escaping (BearyExportPageResult) -> Void) {
        fetchScopePage(scope: scope, pin: pin, before: nil, beforeId: nil, accumulated: [], depth: 0, completion: completion)
    }

    private func fetchScopePage(scope: BearyAPI.Scope, pin: BearyExportPin, before: Int?, beforeId: String?, accumulated: [Entry], depth: Int, completion: @escaping (BearyExportPageResult) -> Void) {
        if depth >= 20 {
            completion((entries: accumulated, complete: false, reason: "已达 20 页上限"))
            return
        }
        if BearyAPI.shared.authEpoch != pin.epoch {
            completion((entries: accumulated, complete: false, reason: "账号已切换"))
            return
        }
        BearyAPI.shared.fetchEntriesWithToken(pin.token, scope: scope, limit: 50, before: before, beforeId: beforeId) { [weak self] result in
            guard let self = self else {
                completion((entries: accumulated, complete: false, reason: "第 \(depth + 1) 页失败"))
                return
            }
            if BearyAPI.shared.authEpoch != pin.epoch {
                completion((entries: accumulated, complete: false, reason: "账号已切换"))
                return
            }
            switch result {
            case .success(let list):
                // 第 7 项（审计三轮）：entries 键缺失 ≠ 空页——服务端回包结构异常，
                // 视同本页失败（reason="第 X 页失败"），调用方 fail-closed 整单
                // 不出文件；不得以 `?? []` 视为空页出“完整”备份。
                guard let entries = list.entries else {
                    completion((entries: accumulated, complete: false, reason: "第 \(depth + 1) 页失败"))
                    return
                }
                let all = accumulated + entries
                if entries.count < 50 {
                    completion((entries: all, complete: true, reason: nil))
                    return
                }
                // 第 7 项（审计三轮）：满 50 条且末条缺 createdAt 时无游标可续翻，
                // 视同本页失败、整单 fail-closed；与日记腿／回收站腿
                // （BearyEntrySync.fetchDiaryPage／fetchTrashPage）“游标缺失中止且不写盘”同口径，
                // 不得当完整页收尾出文件。
                guard let last = entries.last, let lastCreated = last.createdAt else {
                    completion((entries: all, complete: false, reason: "第 \(depth + 1) 页失败"))
                    return
                }
                self.fetchScopePage(scope: scope, pin: pin, before: lastCreated, beforeId: last.id, accumulated: all, depth: depth + 1, completion: completion)
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

    /// 设置行按压视觉反馈：只走 opacity（不动布局、不缩放），与原有
    /// touchDown 轻震叠加；关了系统触感时仍能看到行面变暗，点按不再像没点中。
    /// 全宽行不用 bearyAddPressFeedback 的缩放（整行抖动），故只降 wrap 透明度。
    @objc private func settingsRowPressDown(_ sender: UIButton) {
        sender.superview?.alpha = 0.55
    }

    @objc private func settingsRowPressUp(_ sender: UIButton) {
        sender.superview?.alpha = 1
    }

    private func makeSettingsTappableRow(content: UIView, button: UIButton) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(content)
        button.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(button)
        button.addTarget(self, action: #selector(settingsRowPressDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(settingsRowPressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
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


    private func buildGeneralSection() {
        let current = UserDefaults.standard.string(forKey: "beary_theme_mode") ?? "system"
        let modes: [(value: String, title: String)] = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
        // 主题三行合并为一段三段滑块：跟随系统 / 浅色 / 深色全保留，
        // 选中档位与旧三行同款持久化与应用路径（见 themeSegmentChanged），
        // 滑块指示动画只走系统分段动画。
        let themeSegmented = UISegmentedControl(items: modes.map { $0.title })
        themeSegmented.translatesAutoresizingMaskIntoConstraints = false
        themeSegmented.selectedSegmentIndex = modes.firstIndex(where: { $0.value == current }) ?? 0
        themeSegmented.setTitleTextAttributes([.font: BearyDynamicType.smallBodyFont()], for: .normal)
        // 三色制：选中段走墨底 + 反色字（2026-10-28 定版：墨=行动/选中，橙底已改回墨；反色字取 bg，浅白深黑，与 ink 互为反色，深浅两态都可读）。
        themeSegmented.setTitleTextAttributes([.font: BearyDynamicType.smallSemiboldFont(), .foregroundColor: BearyColors.bg], for: .selected)
        themeSegmented.selectedSegmentTintColor = BearyColors.ink
        themeSegmented.addTarget(self, action: #selector(themeSegmentChanged(_:)), for: .valueChanged)
        var rows: [UIView] = [themeSegmented]
        // C2：使用指南行（原齿轮菜单项，改由设置页承载；容器接线到教程重播页）。
        let tutorialContent = makeRow(title: "使用指南", iconName: "icon_help", showChevron: true)
        let tutorialButton = UIButton(type: .custom)
        tutorialButton.accessibilityLabel = "使用指南"
        tutorialButton.addTarget(self, action: #selector(tutorialButtonTapped), for: .touchUpInside)
        tutorialButton.bearyAddPressHaptic()
        rows.append(makeSettingsTappableRow(content: tutorialContent, button: tutorialButton))
        // 2026-10-29 音效包接入：音效开关行（默认开，关后全部音效静默；只门控音效，不动震动）。
        let soundSwitchTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        soundSwitchTitle.font = BearyDynamicType.smallBodyFont()
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
        // 视觉批：行标题归位 smallBodyFont（覆写，见 makeRow 的注释）。
        diagSwitchTitle.font = BearyDynamicType.smallBodyFont()
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
        let diagContent = makeRow(title: "诊断日志", iconName: "icon_list", showChevron: true)
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
        // 视觉批：渐进披露——该卡改点按展开的折叠（标题沿用原卡名，两行
        // 本身与跳转／开关行为一字不动）。
        let diagDisclosureValue = makeDisclosureCard(title: "诊断日志", rows: [diagSwitchRow, diagRow])
        diagDisclosureValue.headerButton.addTarget(self, action: #selector(diagDisclosureTapped), for: .touchUpInside)
        diagDisclosure = diagDisclosureValue
        generalNotifyWrap.addArrangedSubview(diagDisclosureValue.card)
    }

    // 本地通知（2026-11-08 新增）：四种开关 + 系统权限未开启提示行。
    // 开关行沿用音效 / 诊断日志行的样式（标题 15 + 说明 12 灰 + UISwitch，无图标）。
    private var notificationSwitches: [BearyLocalNotifications.Kind: UISwitch] = [:]
    private var notificationHintRow: UIView?
    /// 通知提示行的包容器与其前分隔线（随提示行同隐同显，见 buildNotificationSection）。
    private var notificationHintWrapper: UIView?
    private var notificationHintSeparator: UIView?

    private func buildNotificationSection() {
        let items: [(kind: BearyLocalNotifications.Kind, title: String, detail: String)] = [
            (.dailyReminder, "写日记提醒", "每天 21:00，还没写才提醒"),
            (.limitedExpiry, "限时日记到期", "限时结束、转回私密时提醒"),
            (.pastDay, "那年今日", "早上 9:00，往年今天有日记才提醒"),
            (.pastSelfDelivery, "留给明年的自己", "留言送达当天早上 9:00 提醒"),
        ]
        var rows: [UIView] = []
        for (index, item) in items.enumerated() {
            let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
            titleLabel.font = BearyDynamicType.smallBodyFont()
            titleLabel.text = item.title
            titleLabel.numberOfLines = 0
            let detailLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
            detailLabel.text = item.detail
            let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
            textStack.axis = .vertical
            textStack.spacing = 2
            textStack.alignment = .fill
            let toggle = UISwitch()
            toggle.isOn = BearyLocalNotifications.shared.isEnabled(item.kind)
            toggle.setContentHuggingPriority(.required, for: .horizontal)
            toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
            toggle.tag = index
            toggle.addTarget(self, action: #selector(notificationSwitchValueChanged(_:)), for: .valueChanged)
            notificationSwitches[item.kind] = toggle
            let row = UIStackView(arrangedSubviews: [textStack, toggle])
            row.translatesAutoresizingMaskIntoConstraints = false
            row.axis = .horizontal
            row.spacing = 12
            row.alignment = .center
            rows.append(row)
        }
        // 系统通知权限被拒时才显示的提示行（点按进系统设置）。
        let hintDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        hintDetail.text = "去系统设置里打开"
        let hintContent = makeRow(title: "通知权限未开启", detailLabel: hintDetail)
        let hintButton = UIButton(type: .custom)
        hintButton.accessibilityLabel = "通知权限未开启，去系统设置里打开"
        hintButton.addTarget(self, action: #selector(notificationHintTapped), for: .touchUpInside)
        hintButton.bearyAddPressHaptic()
        let hintRow = makeSettingsTappableRow(content: hintContent, button: hintButton)
        hintRow.isHidden = true
        notificationHintRow = hintRow
        rows.append(hintRow)
        let group = makeGroupCard(title: "通知", rows: rows)
        generalNotifyWrap.addArrangedSubview(group.card)
        // 第十一轮审计 1：提示行是组内末行——只藏 row 会留 wrap 的 28pt 内边距
        // 与其前分隔线；改藏 wrapper＋separator＋row 三者（Plus 限免行同款口径）。
        // 初始即与 row 同藏，权限回包前的异步窗口也不留空白。
        if let hintIndex = rows.firstIndex(where: { $0 === hintRow }) {
            notificationHintWrapper = group.wrappers[hintIndex]
            notificationHintWrapper?.isHidden = true
            if hintIndex > 0 {
                notificationHintSeparator = group.separators[hintIndex - 1]
                notificationHintSeparator?.isHidden = true
            }
        }
        refreshNotificationHintRow()
    }

    @objc private func notificationSwitchValueChanged(_ sender: UISwitch) {
        let kinds = BearyLocalNotifications.Kind.allCases
        guard kinds.indices.contains(sender.tag) else { return }
        let kind = kinds[sender.tag]
        BearyLocalNotifications.shared.setEnabled(sender.isOn, for: kind)
        // 权限被拒时开关照常记偏好，只提示一次：进系统打开后即生效。
        if sender.isOn {
            BearyLocalNotifications.shared.fetchAuthorizationStatus { [weak self] status in
                guard status == .denied else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    BearyToast.show(in: self.view, message: "通知权限未开启，去系统设置里打开才生效")
                }
            }
        }
    }

    @objc private func notificationHintTapped() {
        BearyLocalNotifications.shared.openSystemSettings()
    }

    private func refreshNotificationHintRow() {
        BearyLocalNotifications.shared.fetchAuthorizationStatus { [weak self] status in
            DispatchQueue.main.async { [weak self] in
                let hidden = (status != .denied)
                self?.notificationHintRow?.isHidden = hidden
                self?.notificationHintWrapper?.isHidden = hidden
                self?.notificationHintSeparator?.isHidden = hidden
            }
        }
    }

    // 私信权限档位行（四档开放）：当前档位、行内文案与按钮引用，刷新走 refreshDMLevelRow。
    private var dmLevelDetailLabel: UILabel?
    private var dmLevelRowButton: UIButton?
    private var dmLevel: String?
    private var dmLevelLoading = false
    private var dmLevelPosting = false
    /// 第三轮审计 02：私信档位本地修改代次——保存时 +1，GET 回包先校验代次，
    /// 晚到的旧 GET 不得覆写已保存的新档位。
    private var dmLevelGeneration = 0
    // r25-4：私信权限回包账号守卫——拉取与提交各拍代次＋账号＋鉴权代次，
    // 切号后旧回包丢弃；在途请求被切号作废时新请求不被 loading 标志挡掉。
    private var dmLevelFetchGeneration = 0
    private var dmLevelPostGeneration = 0
    private var dmLevelRequestAccountId: Int?

    private func buildPrivacySection() {
        let privacyContent = makeRow(title: "隐私政策", iconName: "icon_eye_off", showChevron: true)
        let privacyButton = UIButton(type: .custom)
        privacyButton.accessibilityLabel = "隐私政策"
        privacyButton.addTarget(self, action: #selector(openPrivacyText), for: .touchUpInside)
        privacyButton.bearyAddPressHaptic()
        let privacyRow = makeSettingsTappableRow(content: privacyContent, button: privacyButton)
        let termsContent = makeRow(title: "用户协议", iconName: "icon_file_text", showChevron: true)
        let termsButton = UIButton(type: .custom)
        termsButton.accessibilityLabel = "用户协议"
        termsButton.addTarget(self, action: #selector(openTermsText), for: .touchUpInside)
        termsButton.bearyAddPressHaptic()
        let termsRow = makeSettingsTappableRow(content: termsContent, button: termsButton)
        // iCity：已拉黑用户行（解除入口，不放他人主页）。
        let blockedContent = makeRow(title: "已拉黑用户", iconName: "icon_user_block", showChevron: true)
        let blockedButton = UIButton(type: .custom)
        blockedButton.accessibilityLabel = "已拉黑用户"
        blockedButton.addTarget(self, action: #selector(openBlockedUsers), for: .touchUpInside)
        blockedButton.bearyAddPressHaptic()
        let blockedRow = makeSettingsTappableRow(content: blockedContent, button: blockedButton)
        // 私信权限行：当前档位中文，点按弹四档 ActionSheet（当前档打勾），选中即 POST。
        let dmDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        dmDetail.text = "加载中…"
        let dmContent = makeRow(title: "谁可以私信我", detailLabel: dmDetail, iconName: "icon_comment")
        let dmButton = UIButton(type: .custom)
        dmButton.accessibilityLabel = "谁可以私信我"
        dmButton.addTarget(self, action: #selector(dmLevelRowTapped), for: .touchUpInside)
        dmButton.bearyAddPressHaptic()
        let dmRow = makeSettingsTappableRow(content: dmContent, button: dmButton)
        dmLevelDetailLabel = dmDetail
        dmLevelRowButton = dmButton
        let group = makeGroupCard(title: "隐私", rows: [privacyRow, termsRow, blockedRow, dmRow])
        privacyWrap.addArrangedSubview(group.card)
    }

    /// 私信权限行刷新：打开/切号时 GET 当前档位并刷新行文案；失败时已有值保持，
    /// 从未拿到值则文案置“获取失败，点按重试”（点按仍可进档位选择重发 POST）。
    /// r25-4：账号真变时先清空旧档位、文案回“加载中…”、在途拉取/提交代次
    /// 作废（旧回包由守卫丢弃），再按新号重读；切号后新请求不被旧 loading 挡掉。
    @objc private func handleUserChangedForDMLevel() {
        // 同一账号的重复广播（/me 成功也会发）不清空、不重读，行文案保持；
        // 账号真变或首次加载时才清空重读。
        if dmLevel != nil, SessionManager.shared.currentUser?.id == dmLevelRequestAccountId {
            return
        }
        dmLevel = nil
        if SessionManager.shared.isLoggedIn {
            dmLevelDetailLabel?.text = "加载中…"
        }
        dmLevelFetchGeneration += 1
        dmLevelPostGeneration += 1
        dmLevelLoading = false
        dmLevelPosting = false
        dmLevelRequestAccountId = nil
        dmLevelRowButton?.isEnabled = true
        refreshDMLevelRow()
    }

    @objc private func refreshDMLevelRow() {
        // 开发者模式速切（仅内存，只改行文案）：不调接口、不改 dmLevel；点按改档已禁（见 dmLevelRowTapped）。
        if let override = BearyDevPreviewState.dmLevelOverride {
            dmLevelDetailLabel?.text = dmLevelText(override) + "（预览）"
            return
        }
        guard SessionManager.shared.isLoggedIn,
              let accountId = SessionManager.shared.currentUser?.id else { return }
        // 同一账号在途时不重复发；切号后（账号变了）允许重发，旧回包由代次守卫丢弃。
        if dmLevelLoading, dmLevelRequestAccountId == accountId { return }
        dmLevelFetchGeneration += 1
        let fetchGeneration = dmLevelFetchGeneration
        // 第三轮审计 02：记下发出时的保存代次；保存已递增代次时，晚到回包直接丢弃。
        let saveGeneration = dmLevelGeneration
        let epoch = BearyAPI.shared.authEpoch
        dmLevelRequestAccountId = accountId
        dmLevelLoading = true
        BearyAPI.shared.fetchDMLevel { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 三重门：代次（切号/重发已作废）＋账号＋鉴权代次，任一不符即旧回包，丢弃。
                guard fetchGeneration == self.dmLevelFetchGeneration,
                      accountId == SessionManager.shared.currentUser?.id,
                      epoch == BearyAPI.shared.authEpoch else { return }
                self.dmLevelLoading = false
                // 第三轮审计 02：保存已递增代次时，晚到的旧 GET 不得覆写已保存的新档位。
                guard saveGeneration == self.dmLevelGeneration else { return }
                switch result {
                case .success(let resp):
                    if let level = resp.dmLevel {
                        self.dmLevel = level
                        self.dmLevelDetailLabel?.text = self.dmLevelText(level)
                    }
                case .failure:
                    if self.dmLevel == nil {
                        self.dmLevelDetailLabel?.text = "获取失败，点按重试"
                    }
                }
            }
        }
    }

    private func dmLevelText(_ level: String) -> String {
        switch level {
        case "anyone": return "所有人都可私信我"
        case "followers": return "仅关注我的人"
        case "friends": return "仅好友"
        case "none": return "任何人都不可私信我"
        default: return "获取失败，点按重试"
        }
    }

    @objc private func dmLevelRowTapped() {
        // 开发者模式速切：预览态不弹档位选择、不调 saveDMLevel。
        if BearyDevPreviewState.dmLevelOverride != nil {
            showToast("预览态，档位切换已禁用")
            return
        }
        guard !dmLevelPosting else { return }
        let options: [(value: String, title: String)] = [
            ("anyone", "所有人都可私信我"),
            ("followers", "仅关注我的人"),
            ("friends", "仅好友"),
            ("none", "任何人都不可私信我"),
        ]
        var actions: [BearyConfirmSheet.Action] = options.map { option in
            let title = option.value == dmLevel ? "✓ " + option.title : option.title
            return BearyConfirmSheet.Action(title: title, style: .default) { [weak self] in
                self?.saveDMLevel(option.value)
            }
        }
        actions.append(BearyConfirmSheet.Action(title: "取消", style: .cancel))
        BearyConfirmSheet.show(from: self, title: "谁可以私信我", message: nil, actions: actions)
    }

    private func saveDMLevel(_ level: String) {
        guard level != dmLevel, !dmLevelPosting, SessionManager.shared.isLoggedIn,
              let accountId = SessionManager.shared.currentUser?.id else { return }
        // r25-4：提交回包账号守卫——拍代次＋账号＋鉴权代次，切号后旧回包
        // 不写新号行；posting 标志只由最新提交的回包复位。
        dmLevelPostGeneration += 1
        let generation = dmLevelPostGeneration
        let epoch = BearyAPI.shared.authEpoch
        dmLevelPosting = true
        dmLevelRowButton?.isEnabled = false
        // 第三轮审计 02：乐观更新——先显新档位并递增代次，此前在途的 GET
        // 回包失效；保存失败才回滚并反馈（摇头＋toast）。
        let previousLevel = dmLevel
        dmLevel = level
        dmLevelDetailLabel?.text = dmLevelText(level)
        dmLevelGeneration += 1
        BearyAPI.shared.saveDMLevel(level) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard generation == self.dmLevelPostGeneration,
                      accountId == SessionManager.shared.currentUser?.id,
                      epoch == BearyAPI.shared.authEpoch else { return }
                self.dmLevelPosting = false
                self.dmLevelRowButton?.isEnabled = true
                switch result {
                case .success(let resp):
                    let saved = resp.dmLevel ?? level
                    self.dmLevel = saved
                    self.dmLevelDetailLabel?.text = self.dmLevelText(saved)
                case .failure:
                    self.dmLevel = previousLevel
                    self.dmLevelDetailLabel?.text = previousLevel.map { self.dmLevelText($0) } ?? "获取失败，点按重试"
                    if let button = self.dmLevelRowButton {
                        self.playDenyShake(on: button)
                    }
                    self.showToast("保存失败，请重试")
                }
            }
        }
    }

    /// 保存失败拒绝动效（详情页同款：摇头＋warning 震动＋拒绝音效；
    /// 减动效时只跳过视觉抖动，震动与音效照常给）。
    private func playDenyShake(on button: UIButton) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled { return }
        button.layer.removeAnimation(forKey: "bearySettingsDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        button.layer.add(shake, forKey: "bearySettingsDenyShake")
    }

    /// 设置页点出新页的统一呈现口（117 终态偏离兜底，公共路径修法）：
    /// 设置主页 presentSettings 已有两道保险（呈现前定帧 + 完成回调复位），
    /// 但下面各子页一直是裸 present、无完成回调——偏移若落在呈现完成时，
    /// 页内守卫又早已在动画中途消费掉，就没有任何一处再校正。本 helper 把
    /// 两道保险收到一处：呈现前先在最终帧布局一次，呈现完成时帧偏离窗口
    /// bounds 或 transform 非单位阵就复位 + 重布局；动画已结束，复位无跳变。
    /// 不改转场类型、方向、时长，不重建节点、不重播动效。
    /// 审计-个人页设置：设置页 present 连点守卫（真机是丢弃还是叠页未证实，
    /// 守卫本身安全：呈现动画在途时后续点按直接忽略，动画结束自动解禁，
    /// 不改转场、不改目标页；已 present 出子页时同样忽略，避免叠页）。
    private var isPresentingSettingsPage = false
    /// 设置子页的 EdgeDismiss 强持有（transitioningDelegate 弱引用；各子页
    /// 开页时原先各设 fadeRise，本函数统一改走 EdgeDismiss，见下）。
    private var settingsPageEdgeDismiss: BearyEdgeDismissController?

    private func presentSettingsPage(_ vc: UIViewController) {
        guard !isPresentingSettingsPage, presentedViewController == nil else { return }
        isPresentingSettingsPage = true
        // 全站返回手势补齐：设置子页（拉黑、诊断、反馈、许愿墙、Plus 明细、
        // 设备、法律文字、设置页路编辑资料）此前全是 fadeRise、没有左边缘右滑；
        // 在此集中改走 EdgeDismiss，各开页处原先设的 fadeRise 在此被覆盖，
        // 子页自身的关闭钮行为一字不动。
        // 设置页路编辑资料例外：容器路编辑资料（SceneDelegate.presentEditProfile）
        // 的手势接了 requestExit 未保存拦截；本路若不接，边缘滑会绕过未保存
        // 确认直接关页，故同款接上（无改动时返回 true，手势照常）。
        vc.loadViewIfNeeded()
        // 审计补漏（#829 回归）：仅原转场为 fadeRise 的子页改走 EdgeDismiss。
        // 登录页自带底 sheet 转场（BearyLoginSheet：尺寸/拖动条/点遮罩关闭），
        // 若在此被覆盖，底 sheet 会变成全屏滑入、叉叉落在全屏页上，故原样放行。
        let useEdgeDismiss: Bool
        if let fadeRise = SceneDelegate.chrome?.fadeRiseTransitionDelegate {
            useEdgeDismiss = (vc.transitioningDelegate === fadeRise)
        } else {
            useEdgeDismiss = false
        }
        if useEdgeDismiss {
            let settingsPageEdgeDismiss = BearyEdgeDismissController()
            if let editVC = vc as? BearyEditProfileViewController {
                settingsPageEdgeDismiss.shouldAllowInteractiveDismiss = { [weak editVC] in
                    editVC?.requestExit(interactive: true) ?? true
                }
            }
            if let feedbackVC = vc as? BearyFeedbackViewController {
                // 反馈页无 requestExit：shouldAllowInteractiveDismiss 只有允许/
                // 拒绝两种语义，返回 false 时手势在 .began 即被拦下、不弹确认；
                // 有内容（文字或附件）时拒绝滑走，用户走顶栏关闭钮弹
                // “放弃这份反馈？”确认（与编辑资料页同款取舍，见 PR 描述）。
                settingsPageEdgeDismiss.shouldAllowInteractiveDismiss = { [weak feedbackVC] in
                    !(feedbackVC?.hasFeedbackContent ?? false)
                }
            }
            settingsPageEdgeDismiss.attach(to: vc)
            vc.transitioningDelegate = settingsPageEdgeDismiss
            self.settingsPageEdgeDismiss = settingsPageEdgeDismiss
            let preBounds = view.window?.bounds ?? UIScreen.main.bounds
            vc.view.frame = preBounds
            vc.view.setNeedsLayout()
            vc.view.layoutIfNeeded()
        }
        present(vc, animated: BearyMotion.animated(true)) { [weak self, weak vc] in
            self?.isPresentingSettingsPage = false
            guard useEdgeDismiss, let vc = vc, let window = vc.view.window else { return }
            let bounds = window.bounds
            if vc.view.frame != bounds || !vc.view.transform.isIdentity {
                vc.view.transform = .identity
                vc.view.frame = bounds
                vc.view.setNeedsLayout()
                vc.view.layoutIfNeeded()
            }
        }
    }

    @objc private func openBlockedUsers() {
        let vc = BearyBlockedUsersViewController()
        vc.modalPresentationStyle = .fullScreen
        // 审计 P2-16：全屏 modal 补 fadeRise（与诊断/反馈/明细页同款）。
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(vc)
    }

    @objc private func soundSwitchValueChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: BearySoundPlayer.enabledDefaultsKey)
        // 第三轮审计 14：重新开启音效时补一次预热（启动时因关闭而跳过时，
        // 一次门控尚未消耗；已预热过时本调用是空操作）。
        if sender.isOn {
            BearySoundPlayer.prewarmAll()
        }
    }

    /// 2026-10-31 冷启动锁开关：先验身份再写档。开启/关闭都要验一次
    /// （防已解锁手机被他人随手关掉）；验证失败或取消时开关视觉回滚、
    /// 不写存档。审计-个人页设置：未录入生物识别但锁已开启时开关仍可点，
    /// 关闭走设备密码验证（evaluate 用 .deviceOwnerAuthentication，生物识别
    /// 不可用时系统直接走设备密码）；关闭成功后开关回到置灰（已关且不可用，
    /// 再开须先录入生物识别）。
    @objc private func lockSwitchValueChanged(_ sender: UISwitch) {
        let desired = sender.isOn
        let name = BearyAppLockSettings.biometryName
        let verb = desired ? "开启" : "关闭"
        BearyAppLockSettings.evaluate(reason: "\(verb)\(name)解锁前请先验证") { [weak sender] success in
            guard let sender = sender else { return }
            if success {
                BearyAppLockSettings.setEnabled(desired)
                if !desired && !BearyAppLockSettings.availability.available {
                    sender.isEnabled = false
                }
            } else {
                sender.isOn = !desired
                self.showToast("验证未通过，设置未更改")
            }
        }
    }

    /// 2026-11-04 隐私遮罩开关：独立于锁开关；只写档、即时生效，下一次
    /// 切后台起按新值执行（已显示的遮罩不受影响，回前台时照常撤掉）。
    @objc private func maskSwitchValueChanged(_ sender: UISwitch) {
        BearyAppLockSettings.setMaskEnabled(sender.isOn)
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
        presentSettingsPage(vc)
    }

    // MARK: - 反馈与建议（2026-10-28 反馈 v3，路线 A）

    // 开发者模式入口：版本号 2 秒窗内连点 5 次进入（并打开总开关）；
    // 已开启时连点只打开页面。平时设置页里没有任何入口行。
    private var versionTapCount = 0
    private var versionTapWindowStart: Date?

    @objc private func versionFooterTapped() {
        let now = Date()
        if let start = versionTapWindowStart, now.timeIntervalSince(start) > 2.0 {
            versionTapCount = 0
        }
        if versionTapCount == 0 {
            versionTapWindowStart = now
        }
        versionTapCount += 1
        guard versionTapCount >= 5 else { return }
        versionTapCount = 0
        versionTapWindowStart = nil
        BearyDeveloperMode.shared.setEnabled(true, window: view.window)
        refreshDeveloperModeRow()
        openDeveloperModePage()
    }

    @objc private func openDeveloperModePage() {
        let vc = BearyDeveloperModeViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(vc)
    }

    // 开发者模式行（仅开启时可见）：开着时在「反馈与建议」组内出现，点按进开发者模式页。
    private var developerModeRow: UIView?
    /// 开发者模式行的包容器与其前分隔线（随开发者模式行同隐同显）。
    private var developerModeWrapper: UIView?
    private var developerModeSeparator: UIView?

    private func refreshDeveloperModeRow() {
        let hidden = !BearyDeveloperMode.shared.isEnabled
        developerModeRow?.isHidden = hidden
        developerModeWrapper?.isHidden = hidden
        developerModeSeparator?.isHidden = hidden
    }

    private func buildDataFeedbackSection() {
        let feedbackContent = makeRow(title: "反馈与改进", iconName: "icon_comment", showChevron: true)
        let feedbackButton = UIButton(type: .custom)
        feedbackButton.accessibilityLabel = "反馈与改进"
        feedbackButton.addTarget(self, action: #selector(openFeedbackPage), for: .touchUpInside)
        feedbackButton.bearyAddPressHaptic()
        // 补缺第 21 项：功能许愿墙入口（反馈相邻行；官方包 icon_star，右箭头走 tappableRow 既有口径）。
        let wishContent = makeRow(title: "功能许愿墙", iconName: "icon_star", showChevron: true)
        let wishButton = UIButton(type: .custom)
        wishButton.accessibilityLabel = "功能许愿墙"
        wishButton.addTarget(self, action: #selector(openWishWallPage), for: .touchUpInside)
        wishButton.bearyAddPressHaptic()
        let devDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        devDetail.text = "已开启"
        let devContent = makeRow(title: "开发者模式", detailLabel: devDetail, iconName: "icon_sliders")
        let devButton = UIButton(type: .custom)
        devButton.accessibilityLabel = "开发者模式，已开启"
        devButton.addTarget(self, action: #selector(openDeveloperModePage), for: .touchUpInside)
        devButton.bearyAddPressHaptic()
        let devRow = makeSettingsTappableRow(content: devContent, button: devButton)
        devRow.isHidden = !BearyDeveloperMode.shared.isEnabled
        developerModeRow = devRow
        let rows: [UIView] = [
            makeSettingsTappableRow(content: feedbackContent, button: feedbackButton),
            makeSettingsTappableRow(content: wishContent, button: wishButton),
            devRow,
        ]
        let group = makeGroupCard(title: "反馈与建议", rows: rows)
        dataFeedbackWrap.addArrangedSubview(group.card)
        // 第十一轮审计 1：开发者模式行是组内末行——只藏 row 会留 wrap 的 28pt
        // 内边距与其前分隔线；改藏 wrapper＋separator＋row 三者（Plus 限免行同款口径）。
        if let devIndex = rows.firstIndex(where: { $0 === devRow }) {
            developerModeWrapper = group.wrappers[devIndex]
            developerModeWrapper?.isHidden = devRow.isHidden
            if devIndex > 0 {
                developerModeSeparator = group.separators[devIndex - 1]
                developerModeSeparator?.isHidden = devRow.isHidden
            }
        }
    }

    @objc private func openFeedbackPage() {
        let vc = BearyFeedbackViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(vc)
    }

    /// 补缺第 21 项：功能许愿墙列表页（反馈页同款全屏 modal + fadeRise）。
    @objc private func openWishWallPage() {
        let vc = BearyWishWallViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(vc)
    }

    /// Plus 页入口②：设置页 Plus 组首行点按进 Plus 展示页。状态与入口行尾同源
    /// （plusDetail 已到时用永久／有效期判定，未到时退回 /me 的 plus）。
    private var isPlusMember: Bool {
        if let detail = plusDetail {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            return detail.permanent == true || (detail.effectiveUntil ?? 0) > now
        }
        return SessionManager.shared.currentUser?.plus == true
    }

    @objc private func openPlusPage() {
        let page = BearyPlusPageViewController(isPlus: isPlusMember)
        page.modalPresentationStyle = .fullScreen
        page.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(page)
    }

    /// 2026-10-29 第 7 项：会员来源明细独立页——优先用设置页已拉到的
    /// plusDetail（状态文案取现行标签值、发放取缓存）；未拉到时子页接
    /// 设置页同一份在途结果（A2：不再自己另发请求）。
    @objc private func openPlusGrantsPage() {
        let vc = BearyPlusGrantsViewController(
            statusText: plusStatusLabel.text ?? "–",
            personalText: plusPersonalLabel.text ?? "–",
            grants: cachedGrants,
            failed: grantsLoadFailed,
            sharedLoad: plusDetailLoad)
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(vc)
    }

    /// 2026-10-29 第 11 项：登录设备独立页——优先用设置页已拉到的
    /// accountSessions；未拉到时子页接设置页同一份在途结果（A2：不再
    /// 自己另发请求）。A2：sessions 凭 loader 的 currentValue 区分「还没
    /// 取到」（nil，子页接在途结果）与「确认是空」（[]，子页直接显空态，
    /// 不再因空数组被当成 nil 而自发请求）；退出其他设备钮仍留在设置页。
    @objc private func openDevicesPage() {
        let vc = BearyDevicesViewController(
            sessions: accountSessionsLoad.currentValue.map { $0.sessions ?? [] },
            failed: sessionsLoadFailed,
            countText: deviceCountLabel.text,
            sharedLoad: accountSessionsLoad)
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(vc)
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
        presentLegalText(title: "隐私政策", doc: .privacy)
    }

    @objc private func openTermsText() {
        presentLegalText(title: "用户协议", doc: .terms)
    }

    private func presentLegalText(title: String, doc: BearyLegalServerText.Doc) {
        // 先显示缓存（或包内兜底），页面立刻打开不阻塞；后台刷新到最新版后只换文字与更新日期。
        let vc = BearyLegalTextViewController(pageTitle: title, pageText: BearyLegalServerText.displayText(for: doc), pageVersion: BearyLegalServerText.cachedUpdatedAt(for: doc))
        vc.modalPresentationStyle = .fullScreen
        // 审计 P2-16：全屏 modal 补 fadeRise。
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        presentSettingsPage(vc)
        BearyLegalServerText.refresh(doc: doc) { [weak vc] text in
            guard let text = text, let vc = vc, vc.isViewLoaded else { return }
            vc.updateText(text)
            vc.updateVersionText(BearyLegalServerText.cachedUpdatedAt(for: doc))
        }
    }
}

/// 设置页隐私/协议原生文字页：纯原生 UITextView 渲染服务器下发文字，
/// 不开网页、不挂 WKWebView（App 独立化方向）。全屏 modal，关闭即 dismiss。
/// updateText 只换 textView 文字，不重建页面、不重播动效。
final class BearyLegalTextViewController: UIViewController {
    private let pageTitle: String
    private let pageText: String
    /// 已存的服务器更新日期（BearyLegalServerText.cachedUpdatedAt）；无值时该行不占高度。
    private var currentVersionText: String?
    private let closeButton = BearyHit44Button(type: .system)
    private let titleLabel = UILabel()
    private let textView = UITextView()
    /// 法律页版本行：顶栏与正文之间的小字灰行（“更新日期：…”），供用户比对版本。
    /// 无版本时高度约束生效（0 高）、有版本时放开由文字固有高度撑开；顶栏到该行的间距同理切换。
    private let versionLabel = UILabel()
    private var versionTopConstraint: NSLayoutConstraint?
    private var versionHeightConstraint: NSLayoutConstraint?
    /// 审计第 2 项：顶栏与正文列共用同一等值宽度约束，宽度由
    /// updateSubpageColumnWidths 按当前屏宽算出（见 columnWidth(forViewWidth:)）。
    private var topBarColumnWidth: NSLayoutConstraint?
    private var contentColumnWidth: NSLayoutConstraint?
    /// 116 子页空白守卫（同 BearySettingsSubpages.swift 守卫说明）。
    private let subpageLayoutGuard = BearySubpageLayoutGuard()
    private var topBarView: UIView?

    init(pageTitle: String, pageText: String, pageVersion: String? = nil) {
        self.pageTitle = pageTitle
        self.pageText = pageText
        self.currentVersionText = pageVersion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        // 全屏页左上角统一左箭头：此前是文字“关闭”，现改 icon_back 图标钮
        // （左上角位置与 44pt 热区不动，行为仍是 closeTapped 关页；本页由
        // 设置页路与登录页路共用，两路的 EdgeDismiss 各自在开页处接）。
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
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
        // 扫查组：此前裸 15pt，隐私/条款长文本不跟随系统字号（本页顶栏已
        // 在 #343 跟随，只剩正文漏网）；UITextView 配 scaledFont + adjusts
        // 后档位变化自动重算字号，滚动区高度自适应，无固定高可撑破。
        textView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = BearyColors.ink
        textView.backgroundColor = BearyColors.bg
        textView.text = pageText
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        versionLabel.adjustsFontForContentSizeCategory = true
        versionLabel.textColor = BearyColors.gray
        versionLabel.numberOfLines = 0
        view.addSubview(topBar)
        view.addSubview(versionLabel)
        view.addSubview(textView)
        topBarView = topBar
        // 审计第 2 项：顶栏与正文列同宽居中，宽度由 updateSubpageColumnWidths
        // 经 columnWidth(forViewWidth:) 统一算出，不再用全宽（priority 750）
        // ＋ ≤600（必需）两约束协商——后者在 601…820pt 区间会把两列都提前
        // 卡在 600pt，顶栏与正文列的 600 上限只在 ≥821pt 时由计算入口给出。
        versionTopConstraint = versionLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor)
        versionHeightConstraint = versionLabel.heightAnchor.constraint(equalToConstant: 0)
        applyVersionText(currentVersionText)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            versionTopConstraint!,
            // 与正文列同宽同左：iPhone 全宽、iPad 600 居中时都与正文左缘对齐。
            versionLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 16),
            versionLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: versionLabel.bottomAnchor),
            textView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ] + BearySubpageTopBarHeight.constraints(for: topBar))
        topBarColumnWidth = topBar.widthAnchor.constraint(equalToConstant: 0)
        topBarColumnWidth?.isActive = true
        contentColumnWidth = textView.widthAnchor.constraint(equalToConstant: 0)
        contentColumnWidth?.isActive = true
        updateSubpageColumnWidths()
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    /// 服务器刷新回包后只换文字：不重建视图、不动滚动位置以外的状态。
    func updateText(_ text: String) {
        guard textView.text != text else { return }
        textView.text = text
    }

    /// 刷新已存更新日期的展示：有值显一行小字灰字、无值整行不占高度。
    /// 调用时若视图未加载，只记值、viewDidLoad 时再按记的值布局。
    func updateVersionText(_ version: String?) {
        applyVersionText(version)
    }

    private func applyVersionText(_ version: String?) {
        currentVersionText = version
        if let version = version, !version.isEmpty {
            versionLabel.text = "更新日期：\(version)"
            versionLabel.isHidden = false
            versionTopConstraint?.constant = 8
            versionHeightConstraint?.isActive = false
        } else {
            versionLabel.text = nil
            versionLabel.isHidden = true
            versionTopConstraint?.constant = 0
            versionHeightConstraint?.isActive = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subpageLayoutGuard.resetForAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSubpageColumnWidths()
        subpageLayoutGuard.applyIfNeeded(page: pageTitle, view: view, topView: topBarView, contentViews: [textView], presentation: "fullScreen+fadeRise")
    }

    /// 列宽唯一计算入口：BearySettingsSubpages.updateSubpageColumnWidths
    /// 同款 ≥821 门禁——宽 ≥821 锁 600 居中，≤820 全宽减 32（规范 §3 内容列）。
    /// 本页顶栏与正文列原即同宽居中，故共用此值；600 上限不再以独立约束形式存在。
    private func columnWidth(forViewWidth w: CGFloat) -> CGFloat {
        w >= 821 ? 600 : max(w - 32, 0)
    }

    /// 列宽只由 view.bounds 定；顶栏与正文列在同一入口算出同一目标值、
    /// 写入各自等值约束；bounds 为 0 时跳过不钉死；值不变时不写，避免布局环。
    /// viewDidLayoutSubviews 每轮调用，故分屏 / 旋转改宽时两列同步跟进。
    private func updateSubpageColumnWidths() {
        let w = view.bounds.width
        guard w > 0 else { return }
        let target = columnWidth(forViewWidth: w)
        if topBarColumnWidth?.constant != target {
            topBarColumnWidth?.constant = target
        }
        if contentColumnWidth?.constant != target {
            contentColumnWidth?.constant = target
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 117 终态偏离兜底：动画结束后的最终帧再校一次。
        subpageLayoutGuard.applyAfterAppearance(page: pageTitle, view: view, topView: topBarView, contentViews: [textView], presentation: "fullScreen+fadeRise")
    }
}

/// 方案一：隐私政策 / 用户协议服务器下发文字（2026-11-01）。
/// 缓存按 doc 分开存（privacy / terms 各一键 + 各一个 updated_at 键）；
/// 有网每次打开都拉，拉取失败或没网就用缓存，再没有缓存才用包内 BearyLegalTexts 兜底；
/// 登录页协议链接同走本路径（见 BearyLoginViewController.openLegalPage）。
enum BearyLegalServerText {
    enum Doc: String {
        case privacy
        case terms
    }

    private struct Response: Decodable {
        let ok: Bool
        let doc: String
        let title: String?
        let updated_at: String?
        let text: String?
    }

    private static func textKey(for doc: Doc) -> String { "beary_legal_text_" + doc.rawValue }
    private static func updatedKey(for doc: Doc) -> String { "beary_legal_updated_at_" + doc.rawValue }

    static func cachedText(for doc: Doc) -> String? {
        UserDefaults.standard.string(forKey: textKey(for: doc))
    }

    static func bundledText(for doc: Doc) -> String {
        doc == .privacy ? BearyLegalTexts.privacy : BearyLegalTexts.terms
    }

    static func displayText(for doc: Doc) -> String {
        cachedText(for: doc) ?? bundledText(for: doc)
    }

    /// 已存的服务器更新日期（refresh 成功时随正文一起存；未拉到过则为 nil，法律页不展示该行）。
    static func cachedUpdatedAt(for doc: Doc) -> String? {
        UserDefaults.standard.string(forKey: updatedKey(for: doc))
    }

    static func refresh(doc: Doc, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://teddyhn.com/beary/api/legal?doc=" + doc.rawValue) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("https://teddyhn.com", forHTTPHeaderField: "Origin")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data = data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(Response.self, from: data),
                  decoded.ok, decoded.doc == doc.rawValue,
                  let text = decoded.text, !text.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            UserDefaults.standard.set(text, forKey: textKey(for: doc))
            if let updated = decoded.updated_at {
                UserDefaults.standard.set(updated, forKey: updatedKey(for: doc))
            }
            DispatchQueue.main.async { completion(text) }
        }.resume()
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

收藏记录你收藏的日记 ID、时间。收藏是私人书签：收藏列表仅你本人可见，也不会通知日记作者

通知记录点赞、回应产生的互动通知，以及我们发送的系统通知

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

通讯录等设备权限信息（相册不批量读取，仅上传你主动选择的图片）

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

账户注销：登录后在 /account 自助注销。注销有 7 天冷静期：期间登录可取消，7 天后正式生效。生效后你的邮箱将被清空，日记保留但作者显示为"用户已注销"；

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

7 天冷静期满未取消，注销正式生效：你的邮箱将被清空、所有设备退出登录，但已公开的日记按设计保留，作者显示为"用户已注销"。

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

编辑期随时可编辑，永久可改

删除公开与私密均可删除，进回收站 30 天

评论本站不设文字评论功能

点赞需登录，仅可赞已公开的日记

小熊回应需登录，仅限已公开日记；每人每篇可贴多种回应，各自贴、撤

收藏需登录，仅限已公开日记；收藏是私人书签，仅你本人可见，不会通知作者

分享已公开日记可通过单篇链接分享给任何人

主动公开私密日记可随时公开，公开后仍可改回私密；但公开期间已被查看或转载的内容无法收回

通知点赞、小熊回应会生成通知告知作者；我们也可通过通知栏发送系统消息（如欢迎信、重要变更）

2.2 发布前确认

因公开后仍可改回私密，但公开期间已被查看或转载的内容无法收回，发布前请务必确认：

内容不含隐私信息（身份证号、住址、电话等）；

图片不含他人肖像（除非获得授权）；

你愿意在主动公开后将其公开展示。

2.3 公开内容的效力

一旦日记转为公开，即视为你同意：

任何访客均可查看；

本站有权在站内展示、推荐；

公开后仍可改回私密或删除；他人已保存或转载的内容无法一并收回。

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

「喜欢」是你公开的认可：点赞过的公开日记在你的主页上公开可见；「收藏」是私人书签，仅你本人可见，不会通知作者。

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
    // 审计-个人页设置：诊断页复制/清空钮改 BearyHit44Button——视觉（字号/
    // 颜色/间距）不动，仅热区扩到 44pt（旧约 20pt 高）。
    private let copyButton = BearyHit44Button(type: .system)
    private let clearButton = BearyHit44Button(type: .system)
    /// 审计第 2 项：顶栏与正文列共用同一等值宽度约束，宽度由
    /// updateSubpageColumnWidths 按当前屏宽算出（见 columnWidth(forViewWidth:)）。
    private var topBarColumnWidth: NSLayoutConstraint?
    private var contentColumnWidth: NSLayoutConstraint?
    /// 116 子页空白守卫（同 BearySettingsSubpages.swift 守卫说明）。
    private let subpageLayoutGuard = BearySubpageLayoutGuard()
    private var topBarView: UIView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "诊断日志"

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topBar.topAnchor, constant: 6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -6),
        ] + BearySubpageTopBarHeight.constraints(for: topBar))

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setTitle("复制全部", for: .normal)
        copyButton.setTitleColor(BearyColors.ink, for: .normal)
        // 第十轮审计文案 g：未读到日志前先隐藏，reloadLog 按有无日志决定显隐；
        // 按钮标题恒为「复制全部」，不把说明文字塞进操作按钮。
        copyButton.isHidden = true
        copyButton.titleLabel?.font = BearyDynamicType.smallActionFont()
        copyButton.titleLabel?.adjustsFontForContentSizeCategory = true
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.bearyAddPressFeedback()
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setTitle("清空", for: .normal)
        clearButton.setTitleColor(BearyColors.destructiveText, for: .normal)
        clearButton.titleLabel?.font = BearyDynamicType.smallBodyFont()
        clearButton.titleLabel?.adjustsFontForContentSizeCategory = true
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
        topBarView = topBar
        // 审计第 2 项：顶栏与正文列同宽居中，宽度由 updateSubpageColumnWidths
        // 经 columnWidth(forViewWidth:) 统一算出，不再用全宽（priority 750）
        // ＋ ≤600（必需）两约束协商——后者在 601…820pt 区间会把两列都提前
        // 卡在 600pt；操作行跟顶栏左缘 +20 不变。
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionRow.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            actionRow.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 20),
            textView.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: 8),
            textView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        topBarColumnWidth = topBar.widthAnchor.constraint(equalToConstant: 0)
        topBarColumnWidth?.isActive = true
        contentColumnWidth = textView.widthAnchor.constraint(equalToConstant: 0)
        contentColumnWidth?.isActive = true
        updateSubpageColumnWidths()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subpageLayoutGuard.resetForAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSubpageColumnWidths()
        subpageLayoutGuard.applyIfNeeded(page: "诊断日志", view: view, topView: topBarView, contentViews: [textView], presentation: "fullScreen+fadeRise")
    }

    /// 列宽唯一计算入口：BearySettingsSubpages.updateSubpageColumnWidths
    /// 同款 ≥821 门禁——宽 ≥821 锁 600 居中，≤820 全宽减 32（规范 §3 内容列）。
    /// 本页顶栏与正文列原即同宽居中，故共用此值；600 上限不再以独立约束形式存在。
    private func columnWidth(forViewWidth w: CGFloat) -> CGFloat {
        w >= 821 ? 600 : max(w - 32, 0)
    }

    /// 列宽只由 view.bounds 定；顶栏与正文列在同一入口算出同一目标值、
    /// 写入各自等值约束；bounds 为 0 时跳过不钉死；值不变时不写，避免布局环。
    /// viewDidLayoutSubviews 每轮调用，故分屏 / 旋转改宽时两列同步跟进。
    private func updateSubpageColumnWidths() {
        let w = view.bounds.width
        guard w > 0 else { return }
        let target = columnWidth(forViewWidth: w)
        if topBarColumnWidth?.constant != target {
            topBarColumnWidth?.constant = target
        }
        if contentColumnWidth?.constant != target {
            contentColumnWidth?.constant = target
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 117 终态偏离兜底：动画结束后的最终帧再校一次。
        subpageLayoutGuard.applyAfterAppearance(page: "诊断日志", view: view, topView: topBarView, contentViews: [textView], presentation: "fullScreen+fadeRise")
        reloadLog()
    }

    private func reloadLog() {
        DiagFile.linesAsync { [weak self] lines in
            guard let self = self else { return }
            if lines.isEmpty {
                self.textView.text = "暂无诊断日志"
                self.textView.textColor = BearyColors.gray
                // 第十轮审计文案 g：无日志时隐藏「复制全部」钮（规范 §12），
                // 空态说明只由正文区「暂无诊断日志」承担，不把说明文字塞进操作按钮。
                self.copyButton.isHidden = true
            } else {
                self.textView.text = lines.joined(separator: "\n")
                self.textView.textColor = BearyColors.ink
                self.copyButton.isHidden = false
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    @objc private func copyTapped() {
        DiagFile.linesAsync { [weak self] lines in
            // 第十轮审计文案 g：无日志时按钮已隐藏，此处仅防异步竞态——
            // 不写剪贴板（不清空用户原有剪贴内容），也不改按钮标题。
            guard !lines.isEmpty else {
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
        // 第四轮审计 12：居中 Alert 改底部弹窗（文案与清空流程不变）。
        BearyConfirmSheet.show(from: self, title: "确定清空诊断日志？", message: "清空后无法恢复。", actions: [
            BearyConfirmSheet.Action(title: "清空", style: .destructive, handler: { [weak self] in
                DiagFile.clear()
                self?.reloadLog()
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }
}

/// iCity 已拉黑用户列表（设置页内页，不新开文件）：GET /beary/api/blocks 只返回 id，
/// 故行内资料另调既有公开资料读口 GET /beary/api/users/:id/profile 补齐
/// （头像＋名字＋handle，复用好友列表行同款 44 头像＋名字/handle 布局；
/// BearyFriendCell 为好友文件私有且带 ⋯ 菜单接线，本页另起同款 cell，不跨文件改好友组）。
/// 资料拉不到时行内回落“用户 + id”，不阻塞解除；解除前弹底部弹窗二次确认。
/// 解除成功同时发 bearyDidBlockUser 广播？不——解除是反向操作，不触发各页清理；
/// 各页的拉黑清理只由拉黑广播驱动，解除后下次拉取即恢复显示。
final class BearyBlockedUsersViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let closeButton = BearyHit44Button(type: .system)
    private let titleLabel = UILabel()
    // C5：空态/失败态走统一 BearyStateView（旧 emptyLabel＋blockedRetryButton
    // 退役；空态无动作、失败态“重新加载”动作仍调 reloadBlocked，失败 toast 保留）。
    private let blockedStateView = BearyStateView()
    /// 审计第 2 项：顶栏与列表列共用同一等值宽度约束，宽度由
    /// updateSubpageColumnWidths 按当前屏宽算出（见 columnWidth(forViewWidth:)）。
    private var topBarColumnWidth: NSLayoutConstraint?
    private var contentColumnWidth: NSLayoutConstraint?
    /// 116 子页空白守卫（同 BearySettingsSubpages.swift 守卫说明）。
    private let subpageLayoutGuard = BearySubpageLayoutGuard()
    private var topBarView: UIView?
    private var blockedIds: [Int] = []
    private var unblockingIds: Set<Int> = []
    /// 审计-个人页设置：拉黑行资料缓存（id → 公开资料，含名字/handle/头像；
    /// 资料拉不到时行内回落“用户 id”，不阻塞解除）；在途去重，避免复用抖动多发。
    private var blockedProfiles: [Int: BearyUserProfile] = [:]
    private var blockedProfileFetching: Set<Int> = []
    /// 第七轮审计 02：拉黑列表的回包守卫——发起时拍代次＋账号 ID＋
    /// 鉴权代次，回包三重门校验；切号／退出后旧回包整单丢弃。
    /// 拉黑行资料逐行拉取共用同一代次：列表重拉即作废上一轮的行资料请求。
    private var blockedLoadGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        // 全屏页左上角统一左箭头：此前是文字“关闭”，现改 icon_back 图标钮
        // （左上角位置与 44pt 热区不动，行为仍是 closeTapped 关页）。
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "已拉黑用户"
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        blockedStateView.translatesAutoresizingMaskIntoConstraints = false
        blockedStateView.isHidden = true
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        tableView.delaysContentTouches = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorColor = BearyColors.line
        tableView.register(BearyBlockedUserCell.self, forCellReuseIdentifier: "BearyBlockedCell")
        view.addSubview(topBar)
        view.addSubview(tableView)
        view.addSubview(blockedStateView)
        topBarView = topBar
        // 审计第 2 项：顶栏与列表列同宽居中，宽度由 updateSubpageColumnWidths
        // 经 columnWidth(forViewWidth:) 统一算出，不再用全宽（priority 750）
        // ＋ ≤600（必需）两约束协商——后者在 601…820pt 区间会把两列都提前
        // 卡在 600pt，600 上限只在 ≥821pt 时由计算入口给出。
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
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
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            blockedStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            blockedStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            blockedStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            blockedStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ] + BearySubpageTopBarHeight.constraints(for: topBar))
        topBarColumnWidth = topBar.widthAnchor.constraint(equalToConstant: 0)
        topBarColumnWidth?.isActive = true
        contentColumnWidth = tableView.widthAnchor.constraint(equalToConstant: 0)
        contentColumnWidth?.isActive = true
        updateSubpageColumnWidths()
        // 第七轮审计 02：本页全屏 modal 盖在设置页上时切号／退出也可能
        // 发生（401 清态），订阅账号变化：旧号列表立即清掉，仍登录时
        // 为新号重拉，退出时只清不拉（全局未登录流程接管）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserChanged), name: .bearyUserDidChange, object: nil)
        reloadBlocked()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 第七轮审计 02：拉黑列表回包三重门——发起代次＋鉴权代次＋账号 ID，
    /// 任一失配即旧账号／旧一轮的回包，整单丢弃。
    private func isCurrentBlockedResponse(generation: Int, accountId: Int?, epoch: Int) -> Bool {
        generation == blockedLoadGeneration
            && accountId == BearyAPI.shared.authAccountId
            && epoch == BearyAPI.shared.authEpoch
    }

    /// 第七轮审计 02：账号变化时旧号的拉黑列表不得继续展示——先清
    /// 列表与行资料缓存；仍登录时为新号重拉（reloadBlocked 自带三重门）。
    /// 退出时只清不拉，不在本页再弹一次“加载失败”。
    @objc private func handleBlockedUserChanged() {
        blockedIds = []
        blockedProfiles = [:]
        blockedProfileFetching = []
        blockedStateView.isHidden = true
        tableView.reloadData()
        if SessionManager.shared.currentUser?.id != nil {
            reloadBlocked()
        }
    }

    private func blockedRetryTapped() {
        blockedStateView.isHidden = true
        reloadBlocked()
    }

    /// 拉黑空态显隐（成功路径专用）：空则显统一空态、无则藏；失败态由
    /// reloadBlocked 另行配置，不走这里（防解除成功把失败态误写成空态）。
    private func updateBlockedEmptyState() {
        if blockedIds.isEmpty {
            blockedStateView.configure(kind: .empty, title: "暂无已拉黑用户", subtitle: nil, iconName: nil, actionTitle: nil, onAction: nil)
            blockedStateView.isHidden = false
        } else {
            blockedStateView.isHidden = true
        }
    }

    private func reloadBlocked() {
        // 第七轮审计 02：发起时拍代次＋账号 ID＋鉴权代次，回包三重门
        // 校验——切号／退出后旧回包整单丢弃，不写列表、不弹失败态。
        blockedLoadGeneration += 1
        let requestGeneration = blockedLoadGeneration
        let requestAccountId = BearyAPI.shared.authAccountId
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchBlocks { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.isCurrentBlockedResponse(generation: requestGeneration, accountId: requestAccountId, epoch: requestEpoch) else { return }
                switch result {
                case .success(let resp):
                    self.blockedIds = resp.blocked ?? []
                    self.updateBlockedEmptyState()
                    self.tableView.reloadData()
                case .failure:
                    // 页内重试：失败态改走统一状态视图（标题“加载失败”＋
                    // “重新加载”动作，旧 toast 口径同步保留一次提示）。
                    self.blockedStateView.configure(kind: .error, title: "加载失败", subtitle: nil, iconName: nil, actionTitle: "重新加载", onAction: { [weak self] in self?.blockedRetryTapped() })
                    self.blockedStateView.isHidden = false
                    BearyToast.show(in: self.view, message: "加载失败，请重试")
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return blockedIds.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyBlockedCell", for: indexPath) as! BearyBlockedUserCell
        let userId = blockedIds[indexPath.row]
        cell.configure(
            userId: userId,
            profile: blockedProfiles[userId],
            isUnblocking: unblockingIds.contains(userId),
            onUnblock: { [weak self] in self?.confirmUnblock(userId: userId) })
        if blockedProfiles[userId] == nil, !blockedProfileFetching.contains(userId) {
            blockedProfileFetching.insert(userId)
            // 第七轮审计 02：行资料回包同守三重门（列表重拉即作废上一轮
            // 的行请求）；写缓存前再确认该行仍在当前列表里，否则旧号的
            // 名字／头像会写进新号的行。
            let requestGeneration = blockedLoadGeneration
            let requestAccountId = BearyAPI.shared.authAccountId
            let requestEpoch = BearyAPI.shared.authEpoch
            BearyAPI.shared.fetchUserProfile(userIdValue: userId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.blockedProfileFetching.remove(userId)
                    guard self.isCurrentBlockedResponse(generation: requestGeneration, accountId: requestAccountId, epoch: requestEpoch) else { return }
                    if case .success(let profile) = result {
                        guard let row = self.blockedIds.firstIndex(of: userId) else { return }
                        self.blockedProfiles[userId] = profile
                        self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
                    }
                }
            }
        }
        return cell
    }

    /// 审计-个人页设置：解除前弹底部弹窗二次确认（确认后才调解除接口；
    /// 防重入仍由 unblockingIds 守，确认框本身不改防重入口径）。
    private func confirmUnblock(userId: Int) {
        guard !unblockingIds.contains(userId) else { return }
        let name = blockedProfiles[userId]?.displayName
        let title = (name?.isEmpty == false) ? "解除对“\(name!)”的拉黑？" : "解除拉黑？"
        // 第四轮审计 12：居中 Alert 改底部弹窗（文案与解除流程不变）。
        BearyConfirmSheet.show(from: self, title: title, message: "解除后对方的日记将不再被屏蔽。", actions: [
            BearyConfirmSheet.Action(title: "解除拉黑", style: .destructive, handler: { [weak self] in
                self?.performUnblock(userId: userId)
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }

    private func performUnblock(userId: Int) {
        guard !unblockingIds.contains(userId) else { return }
        unblockingIds.insert(userId)
        tableView.reloadData()
        // 第六轮审计 02：发起时拍身份快照，成功回包先校验——切号/退出/重登
        // 夹在请求与回包之间时，旧回包不得从新账号的拉黑缓存里删人、不得改
        // 本页 blockedIds、不得弹提示（在途标记照常清除，失败分支不动）。
        let identity = BearyIdentityGuard.capture()
        BearyAPI.shared.unblockUser(userId: userId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.unblockingIds.remove(userId)
                switch result {
                case .success:
                    guard BearyIdentityGuard.stillValid(identity) else { return }
                    BearyBlockedStore.removeBlocked(userId)
                    self.blockedIds.removeAll { $0 == userId }
                    self.updateBlockedEmptyState()
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subpageLayoutGuard.resetForAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSubpageColumnWidths()
        subpageLayoutGuard.applyIfNeeded(page: "已拉黑用户", view: view, topView: topBarView, contentViews: [tableView], presentation: "fullScreen+fadeRise")
    }

    /// 列宽唯一计算入口：BearySettingsSubpages.updateSubpageColumnWidths
    /// 同款 ≥821 门禁——宽 ≥821 锁 600 居中，≤820 全宽减 32（规范 §3 内容列）。
    /// 本页顶栏与列表列原即同宽居中，故共用此值；600 上限不再以独立约束形式存在。
    private func columnWidth(forViewWidth w: CGFloat) -> CGFloat {
        w >= 821 ? 600 : max(w - 32, 0)
    }

    /// 列宽只由 view.bounds 定；顶栏与列表列在同一入口算出同一目标值、
    /// 写入各自等值约束；bounds 为 0 时跳过不钉死；值不变时不写，避免布局环。
    /// viewDidLayoutSubviews 每轮调用，故分屏 / 旋转改宽时两列同步跟进。
    private func updateSubpageColumnWidths() {
        let w = view.bounds.width
        guard w > 0 else { return }
        let target = columnWidth(forViewWidth: w)
        if topBarColumnWidth?.constant != target {
            topBarColumnWidth?.constant = target
        }
        if contentColumnWidth?.constant != target {
            contentColumnWidth?.constant = target
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 117 终态偏离兜底：动画结束后的最终帧再校一次。
        subpageLayoutGuard.applyAfterAppearance(page: "已拉黑用户", view: view, topView: topBarView, contentViews: [tableView], presentation: "fullScreen+fadeRise")
    }
}

// MARK: - 拉黑行 Cell（审计-个人页设置：好友列表行同款布局）

/// 头像 44＋名字＋handle＋解除钮；解除钮为 BearyHit44Button（旧 accessoryView
/// 普通钮热区不足）。头像加载走好友行同款 BearyImageLoader.loadDetailed，
/// 复用时取消在途任务；无头像时首字母兜底（与好友行同款橙底淡底色占位）。
/// C3：头像三件套改走统一 BearyAvatarView；旧失败态留空白头像且无重试，
/// 改走组件后失败态同为首字母占位＋重试钮（见 BearyAvatarView 注释第 4 条）。
private final class BearyBlockedUserCell: UITableViewCell {

    private let avatarView = BearyAvatarView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private var unblockHandler: (() -> Void)?

    private lazy var unblockButton: BearyHit44Button = {
        let button = BearyHit44Button(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("解除拉黑", for: .normal)
        button.setTitleColor(BearyColors.ink, for: .normal)
        button.titleLabel?.font = BearyDynamicType.smallBodyFont()
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: #selector(unblockTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .none
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.cardTitleFont()
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = BearyColors.gray
        handleLabel.numberOfLines = 1
        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(handleLabel)
        contentView.addSubview(unblockButton)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: unblockButton.leadingAnchor, constant: -8),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            handleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: unblockButton.leadingAnchor, constant: -8),
            handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            unblockButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            unblockButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.reset()
        unblockHandler = nil
    }

    func configure(userId: Int, profile: BearyUserProfile?, isUnblocking: Bool, onUnblock: @escaping () -> Void) {
        unblockHandler = onUnblock
        unblockButton.isEnabled = !isUnblocking
        var displayName = "用户 \(userId)"
        if let name = profile?.displayName, !name.isEmpty {
            displayName = name
        }
        nameLabel.text = displayName
        if let handle = profile?.handle, !handle.isEmpty {
            handleLabel.text = "@\(handle)"
            handleLabel.isHidden = false
        } else {
            handleLabel.isHidden = true
        }
        // C3：头像加载/占位/重试全走 BearyAvatarView（无图首字母占位；
        // 有图失败时占位＋重试，旧“失败留空白”不再出现）。
        avatarView.configure(displayName: displayName, avatarURL: profile?.avatarUrl.flatMap { BearyImageURLs.avatarURL($0) })
    }

    @objc private func unblockTapped() {
        unblockHandler?()
    }
}
