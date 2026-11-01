import Foundation

// ===== 会话管理（第一阶段；批一删网页同步）=====
// 原生侧独占 teddy_session（Domain=.teddyhn.com，30 天，HttpOnly），走共享 HTTPCookieStorage：
// 批一之前网页登录/退出还要与 WK 同步 cookie，批一 App 不再含网页视图，同步函数整段删掉，
// 只剩原生侧：refreshMe 恢复登录态、logout 清服务端会话与本地 cookie。
// 401 只清原生用户态，不动 cookie（避免误踢尚有效的登录态）。
// G26：refreshMe 网络失败时不按游客处理——置 authUnknown 并回调
// onNetworkUnstable（容器接“网络不稳定，请稍后再试”提示），currentUser 保持旧值。
// 5-29：5xx 与解析失败同此口径（同样未证实游客），4xx（除 401 外）与业务码沿旧口径。
// 回调一律回主线程发，界面层不用再 dispatch。

final class SessionManager {
    static let shared = SessionManager()

    private(set) var currentUser: MeUser?
    var isLoggedIn: Bool { currentUser != nil }
    /// 游客模式（只读）：用户在登录页点“先逛逛”进入的无账号浏览态，只能看公开日记。
    /// 内存态，不持久化（重开 App 回登录页）；登录成功与显式退出时清零。
    /// 游客态与未登录态的区别：未登录可能是会话过期等被动状态，游客是用户主动选的浏览态；
    /// 容器据此决定顶栏（只留登录）、FAB（隐藏）、受限动作（走登录提示 Sheet 而非直弹登录页）。
    var isGuestMode = false
    /// 64 包反馈修（第 17 项）：本地有效会话 cookie（teddy_session 且未过期）——
    /// 首帧缓存态依据，同步读存储、不发网络；后台 refreshMe 验出 401 才切游客态。
    /// 注意：只判断 cookie 存在与过期，不证明服务端会话仍有效，401 回来即纠正。
    var hasCachedSession: Bool {
        let store = HTTPCookieStorage.shared
        return (store.cookies ?? []).contains { cookie in
            cookie.name == "teddy_session" && self.isBearyCookie(cookie)
                && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
    }
    /// 401 时调用（界面层可接登录页；默认只清用户）。
    var onUnauthorized: (() -> Void)?
    /// 用户变化时调用（登录/退出/刷新后）。
    var onUserChanged: ((MeUser?) -> Void)?

    /// G26：最近一次 refreshMe 是否因“登录态未知”而未证实游客。
    /// 401 不走这里（401 由 api.onUnauthorized 清用户态、走游客路径）；
    /// 网络失败、5xx、解析失败置 true，成功或 401 后清零。顶栏/操作处
    /// 见到 authUnknown 为真时，须给“网络不稳定，请稍后再试”式提示，
    /// 不得直接按游客处理（接线归容器 lane，本文件只提供状态与回调；
    /// 失败时 currentUser 保持旧值不动，同样不得按游客渲染）。
    /// 5-29：5xx 与解析失败与网络失败同口径（同置未知、同调
    /// onNetworkUnstable），仍不按游客处理、不弹登录页。
    private(set) var authUnknown: Bool = false
    /// G26：网络失败时的回调（容器可接 toast；默认不弹登录页）。
    var onNetworkUnstable: (() -> Void)?

    private let api = BearyAPI.shared

    /// 账号隔离 3 号：登录代际。每次权威登录态变迁（显式退出、401 清态、
    /// refreshMe 成功且用户 id 变化）+1；refreshMe 回包与 BearyAPI 的 401
    /// 回调只认当前代际，过期回包一律丢弃，不得覆盖当前态。
    private var sessionGeneration = 0
    /// refreshMe 请求序号：每次调用 +1，回包只认最新一次，旧请求回包
    /// （含成功与 401 映射的 success(nil)）直接丢弃、不调 completion。
    /// 显式退出时同样 +1（见 signOutLocally），使退出时在途的旧 /me
    /// 成功回包被 seq 守卫丢弃，不得把旧用户写回。
    private var meSeq = 0

    /// 账号隔离改造：会话状态写回统一到主线程。本类所有公开入口
    /// （refreshMe/switchToAccount/removeAccount/signOutLocally）只在主
    /// 线程执行：非主线程调用时整段重派到主线程再跑（主队列 FIFO 保序）；
    /// 所有网络回调（fetchMe、隔离预检、隔离登出、401 回调）先跳回主线
    /// 程再写 currentUser/authUnknown/sessionGeneration/meSeq/isGuestMode。
    /// 此前只有 notifyUserChanged 走了主线程，回调本体直接写状态——后台
    /// 线程与主线程双写是本改造要收掉的口。读方（各页读 currentUser）
    /// 不动；meSeq/userId/epoch 守卫全部保留，见各方法内注释。
    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private init() {
        api.onUnauthorized = { [weak self] in
            guard let self = self else { return }
            // 401 回调来自 BearyAPI 回包后台线程：先回主线程再清态，
            // 不得在后台直接写 currentUser/sessionGeneration。
            self.runOnMain {
                self.purgeImageCacheForCurrentAccount()
                self.purgeLocalSnapshotsForCurrentAccount()
                self.sessionGeneration += 1
                self.api.setAuthAccountId(nil)
                self.currentUser = nil
                self.authUnknown = false
                self.notifyUserChanged(nil)
                self.notifyUnauthorized()
            }
        }
    }

    private func notifyUserChanged(_ user: MeUser?) {
        DispatchQueue.main.async { [weak self] in self?.onUserChanged?(user) }
    }

    private func notifyUnauthorized() {
        DispatchQueue.main.async { [weak self] in self?.onUnauthorized?() }
    }

    private func notifyNetworkUnstable() {
        DispatchQueue.main.async { [weak self] in self?.onNetworkUnstable?() }
    }

    func refreshMe(completion: ((Result<MeUser?, APIError>) -> Void)? = nil) {
        // 主线程收敛：非主线程调用整段重派主线程，meSeq 递增与后续
        // 状态写回都在主线程发生；原有调用方全是 UI 线程，本分支只防
        // 将来后台调用方，不改现行时序。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshMe(completion: completion) }
            return
        }
        meSeq += 1
        let seq = meSeq
        let previousUserId = currentUser?.id
        api.fetchMe { [weak self] result in
            guard let self = self else { return }
            // 回包先回主线程再写状态：此前回调本体在后台线程直接写
            // currentUser/authUnknown/sessionGeneration，本处收掉。
            // 完成回调同样落主线程（原调用方或已回主线程、或自己再派
            // 主线程，主线程上再派一次无害）。
            DispatchQueue.main.async {
                // 账号隔离 3 号：旧 refreshMe 回包直接丢弃（新登录后的旧请求
                // 成功回包不得把旧用户写回，旧 401 映射的 nil 也不得清掉新态）。
                guard seq == self.meSeq else { return }
                self.applyRefreshMeResult(result, previousUserId: previousUserId, completion: completion)
            }
        }
    }

    /// refreshMe 回包的主线程应用体（原回调本体原样挪入，只补
    /// setAuthAccountId 两处：成功立账号、authFailure 清账号；其余
    /// 分流、meSeq/userId/epoch 守卫一字不动）。
    private func applyRefreshMeResult(_ result: Result<MeUser?, APIError>, previousUserId: Int?, completion: ((Result<MeUser?, APIError>) -> Void)?) {
        switch result {
        case .success(let user):
            self.authUnknown = false
            // 用户 id 变化即权威登录态变迁：先应用新态，再推代际，
            // 使此前在途请求的 401 回调（BearyAPI 侧 epoch 校验）失效。
            if user?.id != previousUserId {
                self.currentUser = user
                self.sessionGeneration += 1
                self.api.bumpAuthEpoch()
                self.api.setAuthAccountId(user?.id)
            } else {
                self.currentUser = user
                self.api.setAuthAccountId(user?.id)
            }
                // 游客模式结束：登录成功即不再是游客（容器随后恢复完整 chrome）。
                if user != nil {
                    self.isGuestMode = false
                }
                // 多账号快照：每次 /me 成功都把当前 cookie token 与用户信息
                // 写进钥匙串保管库（按 userId 去重）。冷启动的老单账号由此
                // 自动进列表，无需迁移；添加账号时容器 refreshMe 同样走这里，
                // 设置页添加前再显式快照一次旧号即可（见 snapshotCurrentAccount）。
                if user != nil {
                    self.snapshotCurrentAccount()
                }
                self.notifyUserChanged(user)
                completion?(.success(user))
            case .failure(let e):
                switch e {
                case .network:
                    // G26：网络失败≠未登录：标记未知并给提示路径，
                    // currentUser 保持旧值，不按游客处理。
                    self.authUnknown = true
                    self.notifyNetworkUnstable()
                case .unauthorized:
                    // fetchMe 已把无 reason 的 401 映射为 success(nil)，此处理论上到不了；
                    // 万一到达，按已证实的游客处理并清未知标记。
                    self.authUnknown = false
                case .authFailure:
                    // 审计 P1-7：封禁/踢下线/过期——与 success(nil) 同口径清用户态
                    // （id 变化即代际推进，防在途旧请求 401 回调误踢新号），
                    // 原因与文案经 completion 透传给容器分流提示（见 SceneDelegate 冷启动处）。
                    self.authUnknown = false
                    if previousUserId != nil {
                        self.sessionGeneration += 1
                        self.api.bumpAuthEpoch()
                    }
                    self.api.setAuthAccountId(nil)
                    self.currentUser = nil
                    self.notifyUserChanged(nil)
                case .cancelled:
                    break
                case .http(let status, _):
                    // 5-29：5xx 同网络失败口径——置未知并给轻提示（容器
                    // onNetworkUnstable 的 toast，不弹登录页）；4xx（/me
                    // 除 401 外的异常码）沿旧口径：不置未知、不提示，
                    // 只保持旧用户态不动。
                    if status >= 500 {
                        self.authUnknown = true
                        self.notifyNetworkUnstable()
                    }
                case .decoding:
                    // 5-29：解析失败同样未证实游客（体已到但解不出，不能
                    // 反推会话过期），与网络失败同口径给轻提示。
                    self.authUnknown = true
                    self.notifyNetworkUnstable()
                case .server, .notFound:
                    // 业务码 / 404 同样未证实游客：保持旧用户态不动，
                    // 不置未知、不弹登录页（沿旧口径）。
                    break
                }
                completion?(.failure(e))
            }
        }

    /// 编辑资料保存成功后统一更新当前用户快照（名字 / 用户名 / 头像）：
    /// 只覆盖调用方传入的已提交值（displayName / handle 传快照里的完整当前值，
    /// avatar 只在换图时传新 dataURL、未换图传 nil 保持原值），不碰 id /
    /// 邮箱 / Plus 等其他字段；无实际变化时不发通知。随后走现行 onUserChanged
    /// 通知（容器按 id 去重：id 未变不触发换号分支，只刷新顶栏与个人页；
    /// 信息流刷新仍由编辑页容器的 onSaved 接线负责）。保管库快照同步刷新，
    /// 使设置页账号列表里的名字 / 头像不滞后。封面不在 MeUser 字段里
    /// （只有 coverVer，且 PUT 回包不下发新 ver），故这里不碰封面——封面
    /// ver 仍靠下一次 refreshMe 同步，见 PR 残留风险。
    func applyEditedProfile(displayName: String, handle: String, avatarDataURL: String?) {
        guard var user = currentUser else { return }
        var changed = false
        if user.displayName != displayName {
            user.displayName = displayName
            changed = true
        }
        if user.handle != handle {
            user.handle = handle
            changed = true
        }
        if let avatarValue = avatarDataURL, user.avatar != avatarValue {
            user.avatar = avatarValue
            changed = true
        }
        guard changed else { return }
        currentUser = user
        snapshotCurrentAccount()
        notifyUserChanged(user)
    }

    /// 显式退出：服务端会话已清后调（登出接口成功后），清本地用户态并通知界面。
    /// 同步递增 meSeq：在途旧 /me 成功回包到达时 seq 已变、被守卫丢弃，
    /// 不得把旧用户写回（登录/切号路径本就靠 refreshMe 调用递增，不动）。
    /// 审计 P2-22：退出/注销时清该账号服务端派生落盘（广场快照、时间线快照、
    /// 日记缓存、回收站缓存、图片缓存）；草稿桶刻意保留——草稿是用户未发布的本地作品，退出即删
    /// 属丢数据，且草稿按账号分桶、换号不可见，留存情况在设置页账号操作卡下明示。
    func signOutLocally() {
        // 主线程收敛：非主线程调用整段重派主线程再跑。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.signOutLocally() }
            return
        }
        // 显式退出才清保管库：本函数只走显式登出路径（登录页 performLogout、
        // 容器登出、注销后清理），401 清态走 init 里的 onUnauthorized 内联
        // 分支、不调本函数，故 401 不删任何账号的 token，切回死会话时
        // 仍能走到“重新登录”而不是列表里直接消失。
        if let id = currentUser?.id {
            BearyAccountVault.shared.remove(userId: id)
        }
        purgeImageCacheForCurrentAccount()
        purgeLocalSnapshotsForCurrentAccount()
        if let id = currentUser?.id {
            // 盲盒次数串账号修法：显式退出删该号全部盲盒桶，退出后不残留；
            // 切号不走这里（旧号桶保留、切回可复用），切号隔离靠分桶本身。
            BlindBoxState.shared.clearAccount(accountId: id)
        }
        sessionGeneration += 1
        meSeq += 1
        api.bumpAuthEpoch()
        api.setAuthAccountId(nil)
        currentUser = nil
        authUnknown = false
        isGuestMode = false
        notifyUserChanged(nil)
    }

    /// 账号隔离 4 号：退出/401 清态时清掉该账号的图片缓存（内存全清 +
    /// 该账号磁盘目录删除）。切换账号（不退出）不走这里，旧账号磁盘保留、
    /// 仅由容器 setAccount 切键 + 清内存，见 SceneDelegate onUserChanged。
    private func purgeImageCacheForCurrentAccount() {
        // 秒开-网络层：先清共享 URLCache（与当前用户无关，任何调用路径都清）。
        // API 与图片会话现已 urlCache=nil，理论上不再向它写；但历史版本 /
        // 其他 .shared 调用仍可能留有私密体，退出/401 时一并清掉，杜绝
        // 账号无关的共享缓存层在换号后命中旧图。
        URLCache.shared.removeAllCachedResponses()
        guard let id = currentUser?.id else { return }
        BearyImageLoader.shared.purgeAccount(id)
    }

    /// 秒开-本地持久化：退出 / 401 清态时清掉该账号的全部日记快照，
    /// 与图片缓存同口径；切换账号不走这里，旧账号磁盘保留、仅由
    /// 桶隔离，切回可复用（见 BearyFeedCache 说明）。
    /// 清单（缺一即私密内容留盘）：广场快照、时间线快照（含私密日记，
    /// 此前无 purge 入口是本批补的缺口）、日落盘、回收站落盘，另加
    /// 冷启动桶提示（forgetUserId，避免下次冷启动先画旧号桶）。
    /// 401 口径变化（特意统一，不再只清广场）：401 即会话已死，与显式
    /// 退出同等对待；唯一保留的区别仍是保管库 token 不删（见
    /// signOutLocally 注释），切回死会话仍能走“重新登录”。
    private func purgeLocalSnapshotsForCurrentAccount() {
        guard let id = currentUser?.id else { return }
        BearyFeedCache.purge(bucket: "\(id)")
        BearyTimelineCache.purge(bucket: "\(id)")
        BearyEntrySyncStore.purgeAccount(accountId: id)
        BearyTrashSyncStore.purgeAccount(accountId: id)
        BearyFeedCache.forgetUserId()
    }

    private func isBearyCookie(_ cookie: HTTPCookie) -> Bool {
        // 严格匹配：去前导点、大小写规范化后，仅 == teddyhn.com 或以 .teddyhn.com 结尾。
        // contains 会误伤 evilteddyhn.com / teddyhn.com.evil.com；正常 Cookie 的
        // domain 正是 teddyhn.com 或 .teddyhn.com 两种形态，不会被误伤。
        var domain = cookie.domain.lowercased()
        while domain.hasPrefix(".") {
            domain.removeFirst()
        }
        return domain == "teddyhn.com" || domain.hasSuffix(".teddyhn.com")
    }

    // MARK: - 多账号切换（设置页账号分组，2026-10-31）

    /// 切换结果：调用方只按结果给 toast / 弹登录页，不另猜原因。
    enum AccountSwitchResult {
        case switched(MeUser)
        case alreadyCurrent
        case expired
        case network
        case failed
        case unavailable
    }

    /// 移除结果：removedAndSwitched 带切过去的账号；removedAndLoggedOut
    /// 表示已无账号可切，调用方走现有退出后路径（关设置页 + 弹登录页）。
    enum AccountRemoveResult {
        case removed
        case removedAndSwitched(MeUser)
        case removedAndLoggedOut
        case failed
    }

    /// 当前会话 cookie（共享存储里唯一的 teddy_session）。
    private func currentSessionCookie() -> HTTPCookie? {
        let store = HTTPCookieStorage.shared
        return (store.cookies ?? []).first { cookie in
            cookie.name == "teddy_session" && isBearyCookie(cookie)
        }
    }

    /// 把一枚 token 写回共享 cookie 桶（先清旧 beary cookie，再建新 cookie；
    /// domain/path 与服务端 Set-Cookie 口径一致：.teddyhn.com / / / Secure）。
    private func installSessionCookie(token: String, expiresDate: Date?) {
        clearLocalCookies()
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".teddyhn.com",
            .path: "/",
            .name: "teddy_session",
            .value: token,
            .secure: true,
        ]
        if let expiresDate = expiresDate {
            properties[.expires] = expiresDate
        }
        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// 快照当前账号进保管库：currentUser + 当前 cookie token 同时具备才写。
    /// 上限口径（2026-10-31 Li 定，上限 3 个）：库里已有 3 个且当前账号
    /// 不在库里时不写（不顶掉旧账号）；当前会话照常可用，腾出空位后
    /// 下次 refreshMe 成功时自动补进。调用方（设置页添加前）同样先调
    /// 本函数快照旧号，再弹登录页。
    func snapshotCurrentAccount() {
        guard let user = currentUser, let userId = user.id,
              let cookie = currentSessionCookie(), !cookie.value.isEmpty else {
            return
        }
        let vault = BearyAccountVault.shared
        if vault.load(userId: userId) == nil && vault.loadAll().count >= BearyAccountVault.maxAccounts {
            return
        }
        let expiresMs: Double? = cookie.expiresDate.map { $0.timeIntervalSince1970 * 1000 }
        _ = vault.save(user: user, token: cookie.value, tokenExpiresAtMs: expiresMs)
    }

    /// 添加账号会话守卫（2026-11-01：取消添加丢原号修法）。
    /// 根因：进添加账号登录页本身不碰会话，但登录页打开期间任何一路
    /// 在途请求回 401（设置页自己的 loadPlusDetail/loadSessions/fetchMe、
    /// 或其他页后台刷新）都会走全局 onUnauthorized 清掉 currentUser 并
    /// 清该号磁盘快照；验码成功换号还会直接覆盖共享桶里的原 cookie。
    /// 此前取消/返回/失败路径没有任何恢复原会话的代码，登录态一丢就
    /// 只能重输验证码——用户视角就是“没新增账号、返回后原号掉线”。
    /// 修法：进添加/过期重登登录页前抓拍原会话（用户 + token），取消时
    /// 若当前态已偏离抓拍就原样装回并通知界面；新号登录成功则只解 arm，
    /// 不恢复（当前态即新号）。守卫只活在内存里：App 重启即失效，
    /// 原号仍可凭保管库 token 切回；移除才真退出的口径不动。
    private struct PendingAccountAddSession {
        let user: MeUser
        let token: String
        let tokenExpiresAtMs: Double?
    }
    private var pendingAccountAddSession: PendingAccountAddSession?

    /// 进添加/过期重登登录页前调用：抓拍当前会话。已 arm 时不覆盖外层
    /// 抓拍（登录页内再弹登录页不重置恢复点）；无当前用户或既无共享
    /// cookie 又无保管库 token 时不 arm（本就无原会话可恢复）。
    func beginAccountAddSession() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.beginAccountAddSession() }
            return
        }
        guard pendingAccountAddSession == nil else { return }
        guard let user = currentUser, user.id != nil else { return }
        let userId = user.id!
        let live = currentSessionCookie()
        let token = (live?.value.isEmpty == false ? live?.value : nil)
            ?? BearyAccountVault.shared.load(userId: userId)?.token
        guard let tokenValue = token, !tokenValue.isEmpty else { return }
        let expiresMs = live?.expiresDate.map { $0.timeIntervalSince1970 * 1000 }
            ?? BearyAccountVault.shared.load(userId: userId)?.tokenExpiresAtMs
        pendingAccountAddSession = PendingAccountAddSession(user: user, token: tokenValue, tokenExpiresAtMs: expiresMs)
    }

    /// 新号登录成功后调用：只解 arm，不恢复（当前态即新号；容器随后
    /// refreshMe 立新态并快照新号）。未 arm 时是空操作，故容器通用登录
    /// 路径（未登录直登）可直接调，不影响原有流程。
    func completeAccountAddSession() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.completeAccountAddSession() }
            return
        }
        pendingAccountAddSession = nil
    }

    /// 取消/返回时调用：当前态与抓拍一致时只解 arm，不发多余通知；
    /// 偏离时（401 清态、cookie 被覆盖等）装回原 token 与原用户，推代际
    /// 与 epoch 使在途旧 401 回调失效，并通知界面重建（与切换提交同
    /// 口径：cookie 与 currentUser 同一主线程段落内一次提交）。
    func cancelAccountAddSession() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.cancelAccountAddSession() }
            return
        }
        guard let pending = pendingAccountAddSession else { return }
        pendingAccountAddSession = nil
        let cookieValue = currentSessionCookie()?.value
        guard currentUser?.id != pending.user.id || cookieValue != pending.token else { return }
        installSessionCookie(token: pending.token, expiresDate: pending.tokenExpiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) })
        sessionGeneration += 1
        api.bumpAuthEpoch()
        api.setAuthAccountId(pending.user.id)
        currentUser = pending.user
        authUnknown = false
        notifyUserChanged(pending.user)
    }

    /// 当前会话 token（共享桶里的 teddy_session 值，供导出钉住凭据用；
    /// 导出与切换预检一律用隔离请求，不经本值以外的共享 cookie）。
    /// 主线程调用（设置页导出按钮在主线程）；后台调用方不得用它拼请求。
    func currentSessionToken() -> String? {
        let value = currentSessionCookie()?.value
        return (value?.isEmpty == false) ? value : nil
    }

    /// 切换账号：换 cookie，不注销旧账号。
    /// 账号隔离改造：预检不再先临时换共享 cookie 再验证。流程改为——
    /// 先快照旧号并把 meSeq +1（在途旧 /me 回包被 seq 守卫丢弃，不
    /// 得覆盖新态）；用目标 token 走隔离请求 fetchMeWithToken 预检
    /// （隔离会话不读不写共享桶，预检在途时后台正常请求仍按原账号
    /// cookie 发，不串号）；预检成功且 user.id 与目标一致、且预检期间
    /// 当前账号未变，才统一提交新态（共享 cookie 与 currentUser、
    /// 代际、epoch、账号身份一次提交，onUserChanged——容器据此切草
    /// 稿桶/图片桶/时间线缓存，与现行账号变化路径同一条）；预检失败
    /// 或身份对不上时，共享 cookie 与 currentUser 一字不动——没有回
    /// 滚可做，也就不存在回滚窗口里后台请求错用临时 cookie 的问题。
    /// 磁盘缓存口径：切换不走 signOutLocally 的磁盘清除，旧账号磁盘
    /// 保留、切回可复用（现行注释口径）；内存态由容器 onUserChanged
    /// 切桶时清掉，不跨账号。
    func switchToAccount(userId: Int, completion: @escaping (AccountSwitchResult) -> Void) {
        // 主线程收敛：非主线程调用整段重派主线程。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.switchToAccount(userId: userId, completion: completion) }
            return
        }
        let vault = BearyAccountVault.shared
        if currentUser?.id == userId {
            completion(.alreadyCurrent)
            return
        }
        guard let target = vault.load(userId: userId), !target.token.isEmpty else {
            completion(.unavailable)
            return
        }
        let startUserId = currentUser?.id
        snapshotCurrentAccount()
        meSeq += 1
        api.fetchMeWithToken(target.token) { [weak self] result in
            guard let self = self else { return }
            // 预检回包先回主线程再判定与提交；失败分支不碰任何状态。
            DispatchQueue.main.async {
                let finish: (AccountSwitchResult) -> Void = { outcome in
                    completion(outcome)
                }
                switch result {
                case .success(let user):
                    guard let user = user, user.id == userId else {
                        // 401 无原因回空（会话已死）或 token 归属对不上：
                        // 原账号原样不动（无回滚），只报过期。
                        finish(.expired)
                        return
                    }
                    guard self.currentUser?.id == startUserId else {
                        // 预检期间当前账号已被另一路切换/退出改掉：不覆盖
                        // 更新的态，本次切换作废（调用方 toast 失败口径）。
                        finish(.failed)
                        return
                    }
                    // 统一提交：共享 cookie 与 currentUser 同一主线程段落
                    // 内一次提交，中间没有后台请求能看到半提交态。
                    self.installSessionCookie(token: target.token, expiresDate: target.tokenExpiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) })
                    self.sessionGeneration += 1
                    self.api.bumpAuthEpoch()
                    self.api.setAuthAccountId(user.id)
                    self.currentUser = user
                    self.authUnknown = false
                    self.isGuestMode = false
                    _ = vault.save(user: user, token: target.token, tokenExpiresAtMs: target.tokenExpiresAtMs)
                    self.notifyUserChanged(user)
                    finish(.switched(user))
                case .failure(let error):
                    switch error {
                    case .authFailure:
                        finish(.expired)
                    case .network, .cancelled, .http, .decoding:
                        // 网络/5xx/解析失败 = 未证实过期（G26 口径）：只
                        // 报告网络问题，不按游客处理、不清旧号、不动 cookie。
                        finish(.network)
                    default:
                        finish(.failed)
                    }
                }
            }
        }
    }

    /// 移除账号：该账号真退出（清它服务端会话 + 本地 token），其他账号不动。
    /// 账号隔离改造：非当前账号不再先装它的 token 调登出再装回——
    /// 用目标 token 走隔离请求 logoutWithToken，只清目标账号的服务端
    /// 会话；共享 cookie 与 currentUser 全程不动，成功时只删保管库项，
    /// 失败时保管库项与当前账号都原样保留。当前账号：登出成功后走
    /// signOutLocally（清该号磁盘缓存 + 保管库项），有下一账号时切
    /// 过去，无账号时报告 loggedOut（调用方走现有退出后路径）。
    func removeAccount(userId: Int, completion: @escaping (AccountRemoveResult) -> Void) {
        // 主线程收敛：非主线程调用整段重派主线程。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.removeAccount(userId: userId, completion: completion) }
            return
        }
        let vault = BearyAccountVault.shared
        let isCurrent = currentUser?.id == userId
        if !isCurrent {
            guard let target = vault.load(userId: userId) else {
                completion(.removed)
                return
            }
            api.logoutWithToken(target.token) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        _ = vault.remove(userId: userId)
                        completion(.removed)
                    case .failure:
                        // 隔离登出失败：不删保管库项、不动当前 cookie 与
                        // currentUser（旧代码失败时也要装回 cookie，本处
                        // 根本没动过，无需恢复）。
                        completion(.failed)
                    }
                }
            }
            return
        }
        api.logout { [weak self] result in
            guard let self = self else { return }
            // 当前账号登出回包先回主线程：后续 clearLocalCookies +
            // signOutLocally（删保管库项）+ loadAll（取下一账号）+
            // switchToAccount 必须按序在主线程跑，否则 signOut 的主
            // 线程重派会跑在 loadAll 之后、下一账号会错取到刚移除的号。
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.clearLocalCookies()
                    self.signOutLocally()
                    let remaining = vault.loadAll()
                    if let next = remaining.first {
                        self.switchToAccount(userId: next.userId) { switchResult in
                            switch switchResult {
                            case .switched(let user):
                                completion(.removedAndSwitched(user))
                            default:
                                completion(.removedAndLoggedOut)
                            }
                        }
                    } else {
                        completion(.removedAndLoggedOut)
                    }
                case .failure:
                    completion(.failed)
                }
            }
        }
    }

    /// 清共享存储里的 beary cookie（显式退出用；401 过期不用它）。
    func clearLocalCookies() {
        let store = HTTPCookieStorage.shared
        for c in (store.cookies ?? []) where isBearyCookie(c) {
            store.deleteCookie(c)
        }
    }
}
