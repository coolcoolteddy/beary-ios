import Foundation

/// Plus 统一控制门（2026-11-24 Li 定，已写进日记规范 v29）：
/// Plus 功能先全部免费，后续统一装一个控制门，不再每个功能各写一个门。
/// 全 App 5 个 Plus 功能门（九宫格、原图上传、景深背景、编辑时限、许愿墙发起）
/// 一律调 `canUsePlusFeature` 判断；以后要收 Plus 时只改 `isOpenForAll` 这一处，
/// 各调用方不用动。
///
/// 真实 Plus 口径（唯一）：与服务端 isPlusEffective 同口径
/// max(plus_until, plus_free_until) > now——/me 下发的 plus 为 true，
/// 或 plusUntil 未过期，或 plusFree 为 true（限免期内）。
///（许愿墙旧口径：永久阈值 4102444800000，即 2100-01-01；/me 的
/// plus_until 本身已是 max 后的有效值，plusFree 是限免期是否在期内的
/// 布尔值，并进来与服务端同口径。）
///
/// TF 本地 Plus（2026-11-26 Li 定）：测试版上买 Plus 只在本地生效；购买
/// 完成仍发一次 plus-verify 只记账（服务端先记账、沙盒非白名单不发权益），
/// 记账成败不影响本地 Plus。正式版只认服务端。本地标记见 `isLocalTestFlightPlus`，只在
/// 测试版构建里读到真值，正式版永远读 false，带不进商店包。
///
/// 展示逻辑不走这扇门：个人页／日记卡作者／ID 卡皇冠、设置页 Plus 入口、Plus 页
/// 本身继续读真实 plus（见 `isRealPlus`），统一门全开时皇冠也不跟着亮。
enum BearyPlusGate {

    /// 全开开关：现在 true，所有人都能用 5 个 Plus 功能。
    /// 以后收 Plus 时改成 false，`canUsePlusFeature` 即走真实判断。
    static var isOpenForAll: Bool { true }

    /// 测试版判定：与 beta 徽标同款口径（SceneDelegate.shouldShowBetaBadge）——
    /// Info.plist 的 BearyDistributionChannel 为 "appstore" 即商店版，其余
    /// （beta／缺失）即测试版（TF）。商店版打包时把该值改成 "appstore"。
    static var isTestFlight: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "BearyDistributionChannel") as? String) != "appstore"
    }

    /// TF 本地 Plus 标记（UserDefaults 键；只在本机生效，不动服务端）。
    /// getter 只在测试版返回真值——正式版永远读 false，TF 时的本地标记
    /// 绝不会带进商店包；setter 只由 TF 购买／恢复／续订路径调用。
    private static let localTestFlightPlusKey = "beary_plus_local_testflight"

    static var isLocalTestFlightPlus: Bool {
        isTestFlight && UserDefaults.standard.bool(forKey: localTestFlightPlusKey)
    }

    static func setLocalTestFlightPlus(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: localTestFlightPlusKey)
    }

    /// 真实 Plus（三态）：true 已确认是 Plus；false 已确认不是；
    /// nil 未确认——plus、plusUntil 与 plusFree 三个字段都缺失，
    /// 调用方不得直接判非 Plus。
    static func realPlusState(user: MeUser?) -> Bool? {
        if user?.plus == true { return true }
        if user?.plusFree == true { return true }
        if let until = user?.plusUntil {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            return until >= 4102444800000 || until > now
        }
        if user?.plus == false { return false }
        return nil
    }

    /// 展示用真实 Plus（皇冠等）：未确认按 false 计；开发者模式覆盖仍走
    /// BearyDeveloperMode.effectivePlus，与旧口径一致。
    /// TF 构建上本地 Plus 标记也算开通（只在 TF 生效——正式版里
    /// isLocalTestFlightPlus 恒为 false，本地标记带不进商店包）。
    static func isRealPlus(user: MeUser?) -> Bool {
        if isLocalTestFlightPlus { return true }
        return BearyDeveloperMode.effectivePlus(realPlusState(user: user) ?? false)
    }

    /// 功能门唯一入口：现在全开；以后收 Plus 时把这里改成 isRealPlus(user:)。
    static func canUsePlusFeature(user: MeUser?) -> Bool {
        if isOpenForAll { return true }
        return isRealPlus(user: user)
    }
}
