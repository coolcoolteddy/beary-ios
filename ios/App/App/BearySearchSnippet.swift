import Foundation

/// 搜索摘要：优先显示命中词附近的句子，而不是正文开头。
///
/// 服务端未下发 `snippet` 时客户端就地算（全文已在搜索回包里，不多发请求）；
/// 服务端下发后（见后端备 diff）优先用服务端字段，本函数只作回退。
/// 纯逻辑、无 UIKit，可进 BearyCoreTests。
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
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    private static func windowSnippet(_ text: String, hitRange: Range<String.Index>) -> String {
        // 起点：命中句的句首；该句在命中词前超过 40 字时只往前取 40 字，
        // 避免一整段长句把窗口撑满、命中词被挤出 120 字上限。
        var start = sentenceStart(in: text, before: hitRange.lowerBound)
        if text.distance(from: start, to: hitRange.lowerBound) > contextBeforeHit {
            start = text.index(hitRange.lowerBound, offsetBy: -contextBeforeHit, limitedBy: text.startIndex) ?? text.startIndex
        }
        // 终点：命中句的句尾；句尾超出上限时在上限处截断。
        var end = sentenceEnd(in: text, after: hitRange.upperBound)
        if text.distance(from: start, to: end) > maxLength {
            end = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
        }
        var result = String(text[start..<end])
        if start > text.startIndex {
            result = "…" + result
        }
        if end < text.endIndex {
            result += "…"
        }
        return result
    }

    private static func isSentenceEnd(_ character: Character) -> Bool {
        return character == "。" || character == "！" || character == "？" || character == "!" || character == "?" || character == "；"
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
