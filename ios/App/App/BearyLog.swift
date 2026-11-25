import Foundation

/// 诊断日志唯一入口（2026-11-22 Li 定）：全仓诊断日志只走这里。
///
/// 此前每处手写 `"[标签] ..."` 前缀（61 处），标签各写各的、同一标签内格式
/// 也不统一；现标签与格式只剩这一处。是否落盘／采样由这里定（目前只走
/// NSLog，行为与此前一字不动——日志内容与触发条件均未改）。
/// print 临时调试输出不在本次收口范围，另行分清删留。
enum BearyLog {

    /// 已拼好的消息（插值串）：原样记一行。
    static func debug(tag: String, message: String) {
        NSLog("%@", "[\(tag)] \(message)")
    }

    /// NSLog 风格格式串＋参数：格式串原样保留（`%d`/`%f` 等渲染与此前一致），
    /// 先拼串再记一行，避免消息里的 `%` 被当成格式符。
    static func debug(tag: String, _ format: String, _ args: CVarArg...) {
        NSLog("%@", "[\(tag)] " + String(format: format, arguments: args))
    }
}
