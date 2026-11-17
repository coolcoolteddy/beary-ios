import Foundation
import UIKit

extension Notification.Name {
    /// 开发者模式变化广播；userInfo["kind"] 说明变了哪一项，
    /// 各页按 kind 决定是轻量重渲染还是走网络重拉：
    /// enabled / date / font / appearance / fakeEntries /
    /// forcedTimeline / forcedTrash / forcedSearch / forcedMap / account / preview。
    static let bearyDeveloperModeChanged = Notification.Name("bearyDeveloperModeChanged")
}

/// 开发者模式外观（2026-11-08 新增，app target only）：
/// 总开关持久化在 UserDefaults，其余模拟态全在 BearyDevPreviewState（内存）。
/// 退出开发者模式即清掉全部内存模拟态、恢复外观与字号、刷新各页。
final class BearyDeveloperMode {
    static let shared = BearyDeveloperMode()

    private static let enabledKey = "beary_developer_mode_enabled"

    /// 开发者模式总开关（持久化；模拟态本身不持久，重启即清）。
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// 横幅条高度（开着 36pt，关着 0）；各页 applyHeaderTopInset 叠加此值。
    var devBannerInset: CGFloat { isEnabled ? 36 : 0 }

    /// 外观一键切之前存下的窗口样式，退出时恢复（内存，不持久化）。
    private var savedWindowStyle: UIUserInterfaceStyle?

    /// 当前开发者模式外观选择（内存，不持久化；.unspecified = 跟随系统）。
    /// 开发者模式页的分段初值读它（viewDidLoad 时 view.window 尚为 nil，读不到窗口样式）。
    private(set) var appearanceStyle: UIUserInterfaceStyle = .unspecified

    private init() {}

    // MARK: - 总开关

    func setEnabled(_ enabled: Bool, window: UIWindow?) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            // 进模式时记下窗口当前外观，供开发者模式页分段取初值。
            appearanceStyle = window?.overrideUserInterfaceStyle ?? .unspecified
        } else {
            BearyDevPreviewState.resetAllSimulations()
            restoreAppearance(on: window)
            appearanceStyle = .unspecified
        }
        postChange(kind: "enabled")
    }

    /// 退出开发者模式：清模拟态、恢复外观，刷新各页与横幅。
    func exit(window: UIWindow?) {
        setEnabled(false, window: window)
    }

    // MARK: - 变化广播

    func postChange(kind: String) {
        NotificationCenter.default.post(
            name: .bearyDeveloperModeChanged,
            object: nil,
            userInfo: ["kind": kind]
        )
    }

    // MARK: - 外观一键切

    /// 深 / 浅色一键切：只改 window.overrideUserInterfaceStyle，
    /// 不写 beary_theme_mode；退出时恢复进开发者模式前的值。
    func applyAppearance(_ style: UIUserInterfaceStyle, on window: UIWindow?) {
        guard let window = window else { return }
        if savedWindowStyle == nil {
            savedWindowStyle = window.overrideUserInterfaceStyle
        }
        appearanceStyle = style
        window.overrideUserInterfaceStyle = style
        postChange(kind: "appearance")
    }

    func restoreAppearance(on window: UIWindow?) {
        guard let window = window, let saved = savedWindowStyle else { return }
        window.overrideUserInterfaceStyle = saved
        savedWindowStyle = nil
    }

    // MARK: - 假日记（仅内存）

    /// 1000 篇假日记：id 一律 "dev-fake-xxxx"（确定性编号，重拉不抖动 diff），
    /// createdAt 按天递减；作者取当前用户；公开态。只写内存模型，不写磁盘。
    func makeFakeEntries(count: Int) -> [Entry] {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let me = SessionManager.shared.currentUser
        return (0..<count).map { i in
            var e = Entry()
            e.id = "dev-fake-\(String(format: "%04d", i))"
            e.authorId = me?.id
            e.authorName = me?.displayName ?? "我"
            e.content = "开发者模式假日记 \(i + 1)（仅内存预览，退出即清）"
            e.createdAt = nowMs - i * 86_400_000
            e.publishedAt = e.createdAt
            e.isPublic = true
            e.visibility = "public"
            e.isMine = true
            e.likeCount = i % 7
            return e
        }
    }

    /// 那年今日假数据：一篇去年同月同日的假日记（id "dev-pastday"）。
    func makeFakePastDayEntry(fakeYear: Int, month: Int, day: Int) -> Entry {
        var e = Entry()
        e.id = "dev-pastday"
        e.authorId = SessionManager.shared.currentUser?.id
        e.authorName = SessionManager.shared.currentUser?.displayName ?? "我"
        e.title = nil
        e.content = "这是去年今天写的日记（开发者模式预览，假数据）。"
        if let date = BearyBeijingDay.date(year: fakeYear, month: month, day: day) {
            e.createdAt = Int(date.timeIntervalSince1970 * 1000)
            e.publishedAt = e.createdAt
        }
        e.isPublic = true
        e.visibility = "public"
        e.isMine = true
        return e
    }

    /// 过去的自己模拟送达卡：一句今天送达的假留话（id "dev-pastself-1"）。
    /// chainId 须是真实可见原篇的 id（调用方取 visible.first），否则
    /// 送达卡按“原篇已删”只显占位。
    func makeFakePastSelfMessage(chainId: String, today: String) -> PastSelfMessage {
        PastSelfMessage(
            id: "dev-pastself-1",
            originEntryId: chainId,
            chainId: chainId,
            authorId: SessionManager.shared.currentUser?.id ?? -1,
            body: "（开发者模式预览）一年前留给自己的话，今天到了。",
            createdAtMs: Int(Date().timeIntervalSince1970 * 1000),
            deliverOn: today,
            revokedAtMs: nil,
            replyToMessageId: nil,
            localOnly: true
        )
    }
}
