import Foundation

/// 搜索摘要：优先显示命中词附近的句子，而不是正文开头。
///
/// 服务端未下发 `snippet` 时客户端就地算（全文已在搜索回包里，不多发请求）；
/// 服务端下发后（见后端备 diff）优先用服务端字段，本函数只作回退。
/// 纯逻辑、无 UIKit，可进 BearyCoreTests。
///
/// 记号口径：一切切片按“可见字”算——一个完整 `[mood:]/[gif:]` 记号算 1 字，
/// 切片只在可见单元边界上落刀，记号永不被切开（切口落在记号中间时整段记号
/// 不取，不留半截原文给 highlightedMoodText 渲染露出）。
enum BearySearchSnippet {

    /// 摘要上限（字符数；含首尾省略号）。
    static let maxLength = 120

    /// 命中词前后各留约 40 字作上下文；单句过长时不整句吞进窗口。
    private static let contextBeforeHit = 40

    static func snippet(for text: String, query: String) -> String {
        let collapsed = collapseWhitespace(text)
        guard !collapsed.isEmpty else { return "" }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return prefixSnippet(collapsed) }
        guard let hitRange = firstHitRange(in: collapsed, query: trimmedQuery) else {
            return prefixSnippet(collapsed)
        }
        return windowSnippet(collapsed, hitRange: hitRange)
    }

    // MARK: - 内部

    private static func collapseWhitespace(_ text: String) -> String {
        let parts = text.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// 先整词找，找不到再按空白拆词、取最早命中的分词。
    private static func firstHitRange(in text: String, query: String) -> Range<String.Index>? {
        if let range = text.range(of: query, options: [.caseInsensitive]) {
            return range
        }
        var earliest: Range<String.Index>?
        for token in query.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter({ !$0.isEmpty }) {
            guard let range = text.range(of: token, options: [.caseInsensitive]) else { continue }
            if let current = earliest {
                if range.lowerBound < current.lowerBound {
                    earliest = range
                }
            } else {
                earliest = range
            }
        }
        return earliest
    }

    private static func prefixSnippet(_ text: String) -> String {
        let units = visibleUnits(in: text)
        guard units.count > maxLength else { return text }
        return units.prefix(maxLength).map { String(text[$0]) }.joined() + "…"
    }

    private static func windowSnippet(_ text: String, hitRange: Range<String.Index>) -> String {
        let units = visibleUnits(in: text)
        // 命中词所在的可见单元；命中词落在记号里时命中单元即该记号本身。
        let hitUnit = units.firstIndex(where: { $0.contains(hitRange.lowerBound) }) ?? 0
        // 起点：命中句的句首；该句在命中词前超过 40 字时只往前取 40 字，
        // 避免一整段长句把窗口撑满、命中词被挤出 120 字上限。
        // 长度按可见字算，落点只在单元边界上。
        var startUnit = unitIndex(at: sentenceStart(in: text, before: hitRange.lowerBound), in: units)
        if hitUnit - startUnit > contextBeforeHit {
            startUnit = hitUnit - contextBeforeHit
        }
        // 终点：命中句的句尾；句尾超出上限时在上限处截断（同上按可见字）。
        var endUnit = unitIndex(at: sentenceEnd(in: text, after: hitRange.upperBound), in: units)
        if endUnit - startUnit > maxLength {
            endUnit = startUnit + maxLength
        }
        var result = units[startUnit..<endUnit].map { String(text[$0]) }.joined()
        if startUnit > 0 {
            result = "…" + result
        }
        if endUnit < units.count {
            result += "…"
        }
        return result
    }

    private static func isSentenceEnd(_ character: Character) -> Bool {
        return character == "。" || character == "！" || character == "？" || character == "!" || character == "?" || character == "；"
    }

    /// 可见单元：一个完整记号为一单元，其余每字（grapheme）一单元。
    /// 一切切片只在单元边界上落刀，记号永不被切开。
    private static func visibleUnits(in text: String) -> [Range<String.Index>] {
        let tokenRanges = BearyInlineToken.ranges(in: text)
        var units: [Range<String.Index>] = []
        var cursor = text.startIndex
        var tokenIdx = 0
        while cursor < text.endIndex {
            while tokenIdx < tokenRanges.count && tokenRanges[tokenIdx].upperBound <= cursor {
                tokenIdx += 1
            }
            if tokenIdx < tokenRanges.count && tokenRanges[tokenIdx].lowerBound == cursor {
                units.append(tokenRanges[tokenIdx])
                cursor = tokenRanges[tokenIdx].upperBound
                tokenIdx += 1
            } else {
                let next = text.index(after: cursor)
                units.append(cursor..<next)
                cursor = next
            }
        }
        return units
    }

    /// index 之前已完整的可见单元数（index 本身是单元边界时即其序号；
    /// 落在单元内部时退到该单元起点——不留半截记号）。
    private static func unitIndex(at index: String.Index, in units: [Range<String.Index>]) -> Int {
        for (i, unit) in units.enumerated() {
            if index <= unit.lowerBound { return i }
            if index < unit.upperBound { return i }
        }
        return units.count
    }

    /// 命中词之前最后一个句末标点之后的位置；没有则全文开头。
    private static func sentenceStart(in text: String, before index: String.Index) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let prev = text.index(before: cursor)
            if isSentenceEnd(text[prev]) {
                return cursor
            }
            cursor = prev
        }
        return text.startIndex
    }

    /// 命中词之后第一个句末标点之后的位置；没有则全文结尾。
    private static func sentenceEnd(in text: String, after index: String.Index) -> String.Index {
        var cursor = index
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if isSentenceEnd(text[cursor]) {
                return next
            }
            cursor = next
        }
        return text.endIndex
    }
}
