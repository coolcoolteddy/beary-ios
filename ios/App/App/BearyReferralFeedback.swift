import Foundation

// MARK: - 审计登录杂项：邀请绑定 toast 文案（含 Plus 到期日补全）

/// 容器在登录页 dismiss + refreshMe 后调本方法，把登录页回调带回的基础文案
/// 补成最终 toast 文案：仅 granted 基础文案补到期日（邀请页 granted 同款口径，
/// 永久阈值 4102444800000）；plusUntil 缺失 / 非 granted 时原样返回，不编造日期。
enum BearyReferralFeedback {
    /// 与登录页邀请绑定成功文案同一 key（login.email.invite_granted）：toastText
    /// 的 base 即登录页回调带回的该本地化文案，两边同一 key，比较在任何语言下都成立。
    /// 不另起新 key——另起 key 的英文译法若与 login.email.invite_granted 不一致，
    /// 比较会在英文下失效。计算属性：跟随当前语言，不缓存旧语言的值。
    static var grantedBaseText: String { NSLocalizedString("login.email.invite_granted", comment: "") }

    static func toastText(base: String, plusUntil: Int?) -> String {
        guard base == grantedBaseText, let until = plusUntil, until > 0 else { return base }
        if until >= 4102444800000 {
            return base + NSLocalizedString("referral.plus_forever_suffix", comment: "")
        }
        // 2026-11-21 日期完全本地化：“Plus 至 <短日期>”走共享 helper（跟 App
        // 语言；非中文为草稿 Plus until <短日期>，待 Li 定稿）。
        return base + BearyLocalizedDate.plusUntilSuffix(untilMs: until)
    }
}
