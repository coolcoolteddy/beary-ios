import Foundation

/// Plus 统一控制门（2026-11-24 Li 定，已写进日记规范 v29）：
/// Plus 功能先全部免费，后续统一装一个控制门，不再每个功能各写一个门。
/// 全 App 5 个 Plus 功能门（九宫格、原图上传、景深背景、编辑时限、许愿墙发起）
/// 一律调 `canUsePlusFeature` 判断；以后要收 Plus 时只改 `isOpenForAll` 这一处，
/// 各调用方不用动。
///
/// 真实 Plus 口径（唯一）：/me 下发的 plus 为 true，或 plusUntil 未过期
///（许愿墙旧口径：永久阈值 4102444800000，即 2100-01-01；plusFree 服务端
/// 下发但 App 无人读，暂不纳入——以后服务端明确口径后再并进来）。
///
/// 展示逻辑不走这扇门：个人页／日记卡作者／ID 卡皇冠、设置页 Plus 入口、Plus 页
/// 本身继续读真实 plus（见 `isRealPlus`），统一门全开时皇冠也不跟着亮。
enum BearyPlusGate {

    /// 全开开关：现在 true，所有人都能用 5 个 Plus 功能。
    /// 以后收 Plus 时改成 false，`canUsePlusFeature` 即走真实判断。
    static var isOpenForAll: Bool { true }

    /// 真实 Plus（三态）：true 已确认是 Plus；false 已确认不是；
    /// nil 未确认——plus 与 plusUntil 两个字段都缺失，调用方不得直接判非 Plus。
    static func realPlusState(user: MeUser?) -> Bool? {
        if user?.plus == true { return true }
        if let until = user?.plusUntil {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            return until >= 4102444800000 || until > now
        }
        if user?.plus == false { return false }
        return nil
    }

    /// 展示用真实 Plus（皇冠等）：未确认按 false 计；开发者模式覆盖仍走
    /// BearyDeveloperMode.effectivePlus，与旧口径一致。
    static func isRealPlus(user: MeUser?) -> Bool {
        BearyDeveloperMode.effectivePlus(realPlusState(user: user) ?? false)
    }

    /// 功能门唯一入口：现在全开；以后收 Plus 时把这里改成 isRealPlus(user:)。
    static func canUsePlusFeature(user: MeUser?) -> Bool {
        if isOpenForAll { return true }
        return isRealPlus(user: user)
    }
}
