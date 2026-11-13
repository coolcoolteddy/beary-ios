import UIKit

// ===== App 公告栏（2026-11-08）：App 端公告单独一批，不与网页横幅共用 =====
// 后端 GET /beary/api/app-announcements（公开，不用登录）：只返回 site='app'
// 且当前有效的公告（event 在时间窗内；after-update 带 target_build）。
// 触发只做两种：更新后（构建号变了且跨过目标构建号）、特殊活动（时间窗内）。
// “有更新了”（发现新版本）不做：无版本比较、无更新提示。
// 每条公告只弹一次（已展示 id 记 UserDefaults）；拉取失败静默，不拦启动。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await。

struct BearyAnnouncement: Decodable {
    let id: Int
    let title: String
    let content: String
    let kind: String
    let startsAt: Int?
    let endsAt: Int?
    let targetBuild: Int?
    let createdAt: Int

    // 不写显式 CodingKeys：BearyAPI 的 decoder 用 convertFromSnakeCase，
    // 会把服务端 starts_at/ends_at/target_build/created_at 转成这些 camelCase
    // 名再匹配；写 snake_case rawValue 会与策略叠加后匹配失败，必填的
    // createdAt 缺键会使整个非空列表解码失败（见 BearyAPI.swift 的同款注释）。

    var isAfterUpdate: Bool { kind == "after-update" }
}

private struct BearyAnnouncementListResponse: Decodable {
    let ok: Bool
    let list: [BearyAnnouncement]
}

final class BearyAnnouncementCenter {
    static let shared = BearyAnnouncementCenter()

    private let lastBuildKey = "beary_announcement_last_build"
    private let shownIdsKey = "beary_announcement_shown_ids"

    private var fetchInFlight = false
    private var cachedList: [BearyAnnouncement]?

    private init() {}

    /// 启动时调用（chrome viewDidAppear veil 已去时、veil 揭开完成时各一处；
    /// 拉取每进程只发一次，重复调用直接用缓存再试呈现）。
    /// 拉取失败静默，不弹、不记状态，下次启动再拉。
    func checkOnLaunch(from presenter: UIViewController) {
        if let list = cachedList {
            tryPresent(list: list, from: presenter)
            return
        }
        guard !fetchInFlight else { return }
        fetchInFlight = true
        BearyAPI.shared.request("/beary/api/app-announcements", suppressUnauthorized: true) { [weak self] (result: Result<BearyAnnouncementListResponse, APIError>) in
            guard let self = self else { return }
            self.fetchInFlight = false
            switch result {
            case .success(let response):
                guard response.ok else { return }
                self.cachedList = response.list
                self.tryPresent(list: response.list, from: presenter)
            case .failure:
                // 弱网/失败静默：不弹、不记状态，下次启动再拉。
                break
            }
        }
    }

    private func currentBuild() -> Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return Int(raw) ?? 0
    }

    private func shownIds() -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: shownIdsKey) as? [Int] ?? [])
    }

    private func tryPresent(list: [BearyAnnouncement], from presenter: UIViewController) {
        // BearyAPI 回调不在主线程，呈现一律回主线程。
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self, weak presenter] in
                guard let self = self, let presenter = presenter else { return }
                self.tryPresent(list: list, from: presenter)
            }
            return
        }
        // 冷启动锁还挂着、或已有 modal 在上时不弹：不记状态，下次启动
        // （或下次 viewDidAppear）再试，避免公告被锁屏/引导盖住后直接丢触发。
        guard !BearyAppLockManager.shared.isColdLocked,
              presenter.presentedViewController == nil else { return }
        let current = currentBuild()
        let lastBuild = UserDefaults.standard.object(forKey: lastBuildKey) as? Int ?? current
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let shown = shownIds()
        let candidate = list.first { ann in
            guard !shown.contains(ann.id) else { return false }
            if ann.isAfterUpdate {
                // 更新后：本地有过上一构建号、本次跨过目标构建号才弹；
                // target_build 为空时退化为“构建号变了就弹”。
                // 全新安装（无上一构建号）时 lastBuild 即当前构建号，
                // 跨越条件天然不成立，更新后公告不弹。
                guard lastBuild != current else { return false }
                if let target = ann.targetBuild {
                    return lastBuild < target && current >= target
                }
                return true
            }
            // 特殊活动：服务端已按时间窗过滤，客户端再按本地时钟复核一次。
            if let start = ann.startsAt, nowMs < start { return false }
            if let end = ann.endsAt, nowMs > end { return false }
            return true
        }
        // 无待弹公告：只有列表里已有一条本构建号的更新后公告时才结算；
        // 公告还没发布（装包后、发布前启动过一次）时不结算，留着等公告
        // 发布后再弹——否则本次构建号会被提前记为已结算，该包公告永不弹
        // （130 包实证：公告晚于装包发布，首启即烧掉了本次跨越）。
        guard let ann = candidate else {
            let hasCurrentTarget = list.contains { $0.isAfterUpdate && ($0.targetBuild ?? Int.max) <= current }
            if hasCurrentTarget {
                UserDefaults.standard.set(current, forKey: lastBuildKey)
            }
            return
        }
        // 先记已展示、再弹：弹过即结算，关掉后不再重弹。
        var nextShown = shown
        nextShown.insert(ann.id)
        UserDefaults.standard.set(Array(nextShown), forKey: shownIdsKey)
        UserDefaults.standard.set(current, forKey: lastBuildKey)
        BearyAnnouncementSheet.show(from: presenter, announcement: ann)
    }
}
