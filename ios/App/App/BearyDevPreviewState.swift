import Foundation

/// 开发者模式预览态（2026-11-08 新增）：全部只放内存，不写 UserDefaults、不写本地库、不上云。
/// 本文件只依赖 Foundation，故同时注册 app target 与测试 target；
/// 被测试 target 编译的文件（BearyBeijingDay / BearyAPI / BearyDynamicType）
/// 只能读这里，不可引用 app-only 的 BearyDeveloperMode 单例。
/// 开关本身（isEnabled）持久化在 UserDefaults，见 BearyDeveloperMode；
/// 这里的模拟态一律内存，重启 App 即清、退出开发者模式即清。
enum BearyDevPreviewState {

    // MARK: - 时间旅行

    /// 假“今天”（年月日）；nil = 真实今天。
    /// 时间线 / 热力图读北京口径（BearyBeijingDay.todayComponents），
    /// 个人页那年今日 / 过去的自己读本地口径（fakeTodayDate），两者同取此处。
    static var fakeDay: (year: Int, month: Int, day: Int)?

    /// 假今天（本地日历 Date，正午，避开 DST 边界）；nil = 不旅行。
    static func fakeTodayDate() -> Date? {
        guard let fake = fakeDay else { return nil }
        var comps = DateComponents()
        comps.year = fake.year
        comps.month = fake.month
        comps.day = fake.day
        comps.hour = 12
        comps.minute = 0
        comps.second = 0
        return Calendar.current.date(from: comps)
    }

    /// 假时刻（毫秒）：假日北京午夜 + 真实北京钟点；nil = 不旅行。
    /// 限时日记 BearyEphemeral 的默认 now 读这里；本地通知排程与写操作
    /// 一律不读这里（保持真实时间，见各调用点注释）。
    static func fakeNowMs() -> Int? {
        guard let fake = fakeDay,
              let midnight = BearyBeijingDay.date(year: fake.year, month: fake.month, day: fake.day) else { return nil }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // 真实北京钟点（毫秒，自北京午夜起；北京无夏令时，直接取模）。
        let beijingMsOfDay = (nowMs + 8 * 3600 * 1000) % 86400000
        return Int(midnight.timeIntervalSince1970 * 1000) + beijingMsOfDay
    }

    // MARK: - 限时日记

    /// 限时日记强制按已到期渲染（仅内存）；只影响无显式 nowMs 的读路径，
    /// 通知重算传显式真实 nowMs，不受此影响。
    static var forceLimitedExpired = false

    // MARK: - 字号

    /// 字号倍率（仅内存，1.0 = 不变）。只放大走 BearyDynamicType 入口的字号；
    /// 505 处裸 UIFont.systemFont 不受影响，固定容器仍截在 20pt。
    static var fontScale: Double = 1.0

    // MARK: - 网络模拟

    enum NetworkSimulation {
        case normal
        case offline
        case slow
        case serverError
    }

    /// 网络模拟（仅内存，重启 App 自动关）。只拦 BearyAPI 三个入口
    /// （request / requestVoid / requestWithToken）；登录验证码
    /// （sendCode / verify 直调 perform）与图片 / 天气 / 法务文本旁路不在模拟内。
    static var networkSimulation: NetworkSimulation = .normal

    // MARK: - 账号 / 关系速切（只改显示）

    /// 游客预览（仅内存）：只拦 showPage 的进页门，不碰 SessionManager。
    /// 只能复现“页进不去 + 弹登录门”；页内仍是登录态。
    static var guestPreview = false

    /// 关注态速切（仅内存，nil = 真实）：0 未关注 / 1 已关注 / 2 被关注 / 3 互关。
    /// 只改个人页与搜索页关注钮的渲染；点按已禁，真实关系与仅好友篇过滤不动。
    static var followStateOverride: Int?

    /// 自己私信档位速切（仅内存，nil = 真实）："anyone" / "followers" / "friends" / "none"。
    /// 只改设置页档位行的文案；点按改档已禁，不调 saveDMLevel。
    static var dmLevelOverride: String?

    /// 对方允许私信速切（仅内存，nil = 真实）。只改个人页私信钮显隐与
    /// 聊天页权限横幅；真发送仍按服务端档位走，403 即失败回滚。
    static var dmCanOverride: Bool?

    // MARK: - 假数据预览（只放内存）

    /// 那年今日假数据预览（仅内存）：无往年日记时也亮一张假卡。
    static var pastDayPreview = false

    /// 过去的自己模拟送达卡（仅内存）：在模块栈顶插一张假送达卡。
    static var pastSelfDeliveryPreview = false

    /// 模拟送达卡挂的原篇 id（渲染时记下，回复提交时凭此拦截写操作）。
    static var fakePastSelfChainId: String?

    /// 塞 1000 篇假日记（仅内存）：各列表取数成功后写内存模型，不写磁盘快照。
    static var fakeEntriesEnabled = false

    // MARK: - 空态 / 报错态预览

    enum ForcedState {
        case none
        case empty
        case error
        case loading
    }

    /// 时间线 / 回收站 / 搜索 / 地图强制态（仅内存，none = 真实）。
    static var forcedTimeline: ForcedState = .none
    static var forcedTrash: ForcedState = .none
    static var forcedSearch: ForcedState = .none
    static var forcedMap: ForcedState = .none

    // MARK: - 清理

    /// 清掉全部内存模拟态（退出开发者模式 / 关闭总开关时调）。
    /// 不碰 isEnabled 本身（那是 UserDefaults 持久开关）。
    static func resetAllSimulations() {
        fakeDay = nil
        forceLimitedExpired = false
        fontScale = 1.0
        networkSimulation = .normal
        guestPreview = false
        followStateOverride = nil
        dmLevelOverride = nil
        dmCanOverride = nil
        pastDayPreview = false
        pastSelfDeliveryPreview = false
        fakePastSelfChainId = nil
        fakeEntriesEnabled = false
        forcedTimeline = .none
        forcedTrash = .none
        forcedSearch = .none
        forcedMap = .none
    }
}
