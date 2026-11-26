import Foundation

/// 字数上限小件（扫查第 6 遍第 5 条收口）：日记正文／私信／许愿详情三域共用的
/// “上限值＋计数＋超限判定” plumbing，各域留自己的上限值与计数样式。
/// 上限值不写死共享常量 2000——三域以后可能分叉，改一域只改该域的构造值。
/// 计数口径与服务端一致：服务端与网页版均按 JS `.length`（UTF-16 码元数）
/// 判上限，Swift `.count` 是字素簇数（单个 astral 表情占 1 簇、2 码元），
/// 表情多时 `.count` 会少算、致客户端放行而服务端 400。
/// 纯逻辑、无 UIKit。
struct BearyCharLimit {

    /// 该域的字数上限（UTF-16 码元数）。
    let value: Int

    init(_ value: Int) {
        self.value = value
    }

    /// 文本的 UTF-16 码元数。
    func count(of text: String) -> Int {
        text.utf16.count
    }

    /// 计数是否超限。
    func isOverLimit(count: Int) -> Bool {
        count > value
    }

    /// 文本是否超限。
    func isOverLimit(_ text: String) -> Bool {
        text.utf16.count > value
    }

    /// “n/limit”计数文（如 "123/2000"）。
    func countText(for count: Int) -> String {
        "\(count)/\(value)"
    }
}
