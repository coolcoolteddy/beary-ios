import Foundation

/// 行内记号 `[mood:xxx]` / `[gif:xxx]` 的纯逻辑处理（Foundation only）。
///
/// BearyNativeCommon 不进测试 target，而本文件的调用点（搜索摘要、星图字数、
/// 离线标题）都在测试 target 里，故不用 BearyText.stripTrailingPartialInlineToken，
/// 把同一口径的正则收在一处；广场标题（仅 App target）为求一致也走这里。
/// 记号形态与 BearyText.inlineAttributedText 一致：mood key 全小写字母，
/// gif key 小写字母/数字。未知 mood key 渲染时原文保留，此处按语法形态一律
/// 视作记号——手打未知 key 极少，且往“看不见”处理比半截原文露出更安全。
enum BearyInlineToken {

    /// 完整记号。
    static let pattern = #"\[mood:[a-z]+\]|\[gif:[a-z0-9]+\]"#

    /// 尾部半截记号（截断口可能正好切在记号中间）。
    /// 比 BearyText.stripTrailingPartialInlineToken 多一档：后者只认冒号之后
    /// 的半截（`\[(mood|gif):[a-z0-9]*$`），截断口落在冒号之前（如 "[moo"）
    /// 时仍会漏；此处把 "[mood:" / "[gif:" 的任一真前缀都认作半截。
    /// 完整记号以 ] 结尾，不会被误伤；"[go"、"[moodx" 这类非记号前缀也不动。
    private static let trailingPartialPattern = #"\[(m(o(o(d)?)?)?|g(i(f)?)?)?(:[a-z0-9]*)?$"#
    private static func regex(for pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// 全部完整记号的范围（按出现顺序，不重叠）。
    static func ranges(in text: String) -> [Range<String.Index>] {
        guard let regex = regex(for: pattern) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: range).compactMap { Range($0.range, in: text) }
    }

    /// 去掉全部完整记号（计数用：记号不占字数）。
    static func strippingTokens(_ text: String) -> String {
        guard let regex = regex(for: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// 去掉尾部半截记号（截断用：切点落在记号中间时不留半截原文）。
    /// 完整记号以 ] 结尾，不会被误伤。
    static func stripTrailingPartial(_ text: String) -> String {
        guard let regex = regex(for: trailingPartialPattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
