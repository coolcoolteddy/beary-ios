import UIKit

// ===== App 公告栏（2026-11-08）：App 端公告单独一批，不与网页横幅共用 =====
// 后端 GET /beary/api/app-announcements（公开，不用登录）：只返回 site='app'
// 且当前有效的公告（event 在时间窗内；after-update 带 target_build）。
// 触发只做两种：更新后（构建号变了且跨过目标构建号）、特殊活动（时间窗内）。
// “有更新了”（发现新版本）不做：无版本比较、无更新提示。
// 每条公告只弹一次（已展示 id 记 UserDefaults）；拉取失败静默，不拦启动。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await。

extension Notification.Name {
    /// 公告列表拉到（首拉或重拉）：轮播公告页据此重建。
    static let bearyAnnouncementListDidChange = Notification.Name("bearyAnnouncementListDidChange")
}

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
    // 强制更新 / 柔性提醒 / 远程开关（2026-11-19）：后端同响应带 config 对象，
    // 缺失时为 nil，中心不动旧存值；全空（0/空数组）时完全无行为。
    let config: BearyAppConfig?
}

final class BearyAnnouncementCenter {
    static let shared = BearyAnnouncementCenter()

    private let lastBuildKey = "beary_announcement_last_build"
    private let lastRunBuildKey = "beary_announcement_last_run_build"
    private let shownIdsKey = "beary_announcement_shown_ids"

    private var fetchInFlight = false
    private var fetchWaiters: [([BearyAnnouncement]?) -> Void] = []
    private var cachedList: [BearyAnnouncement]?

    private init() {}

    /// 轮播公告页用：缓存里的最新一条有效公告（服务端已按时间窗过滤、按 created_at 倒序）。
    /// 未拉取过时返回 nil（调用方不建公告页，由 fetchList 补拉后重建）。
    func latestAnnouncement() -> BearyAnnouncement? {
        return cachedList?.first
    }

    /// 拉取公告列表（只填缓存，不弹 sheet）：轮播重建时用；失败静默。
    /// 拉到后发 .bearyAnnouncementListDidChange；回调一律主线程。
    /// 在途去重：多次调用只发一条请求，回包分发给所有等在途者。
    func fetchList(completion: (([BearyAnnouncement]?) -> Void)? = nil) {
        if let list = cachedList {
            if let completion = completion {
                DispatchQueue.main.async { completion(list) }
            }
            return
        }
        if fetchInFlight {
            if let completion = completion {
                fetchWaiters.append(completion)
            }
            return
        }
        fetchInFlight = true
        if let completion = completion {
            fetchWaiters.append(completion)
        }
        BearyAPI.shared.request("/beary/api/app-announcements", suppressUnauthorized: true) { [weak self] (result: Result<BearyAnnouncementListResponse, APIError>) in
            guard let self = self else { return }
            // BearyAPI 回调不在主线程：缓存读写统一走主线程，免得与主线程
            // 的调用抢 cachedList/fetchInFlight。
            DispatchQueue.main.async {
                self.fetchInFlight = false
                let waiting = self.fetchWaiters
                self.fetchWaiters = []
                switch result {
                case .success(let response):
                    guard response.ok else {
                        waiting.forEach { $0(nil) }
                        return
                    }
                    if let config = response.config {
                        BearyForceUpdateCenter.shared.store(config: config)
                    }
                    self.cachedList = response.list
                    NotificationCenter.default.post(name: .bearyAnnouncementListDidChange, object: nil)
                    waiting.forEach { $0(response.list) }
                case .failure:
                    // 弱网/失败静默：不记状态，下次再拉。
                    waiting.forEach { $0(nil) }
                }
            }
        }
    }

    /// 启动时调用（chrome viewDidAppear veil 已去时、veil 揭开完成时各一处；
    /// 拉取每进程只发一次，重复调用直接用缓存再试呈现）。
    /// 拉取失败静默，不弹、不记状态，下次启动再拉。
    func checkOnLaunch(from presenter: UIViewController) {
        if let list = cachedList {
            tryPresent(list: list, from: presenter)
            return
        }
        fetchList { [weak self, weak presenter] list in
            guard let self = self, let presenter = presenter else { return }
            guard let list = list else {
                // 弱网/失败静默：公告不弹、不记状态，下次启动再拉；但强制/柔性
                // 更新按上次拉到的 config 离线判断（从没拉到过则放行）。
                BearyForceUpdateCenter.shared.tryPresentUpdate(from: presenter, announcements: self.cachedList ?? [])
                return
            }
            self.tryPresent(list: list, from: presenter)
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
        // R13-3/4：构建号结算拆成两本账——
        // · lastRunBuildKey：上次实际运行的构建号，每次走到这里都记当前构建号；
        // · lastBuildKey：更新跨越的结算基线，只在更新后公告展示、或无候选但列表
        //   已有本构建号目标时才推进到当前构建号。
        // 旧口径只用 lastBuildKey、缺失时回落 current：旧版启动时列表为空就从不
        // 记旧构建号，升级后基线回落成当前构建号，目标为新构建号的更新公告永不弹；
        // 且活动公告一弹就把 lastBuildKey 写成当前构建号，同版更新公告随即被烧掉。
        // 新口径：首次检测到升级（上次运行构建号 < 当前）时，把升级起点记进
        // lastBuildKey 并保留到结算为止——公告晚发布时下次启动仍按起点判断；
        // 全新安装（从无上次运行构建号）时基线仍是当前构建号，更新后公告不弹。
        let previousRunBuild = UserDefaults.standard.object(forKey: lastRunBuildKey) as? Int
        if UserDefaults.standard.object(forKey: lastBuildKey) == nil,
           let previous = previousRunBuild, previous < current {
            UserDefaults.standard.set(previous, forKey: lastBuildKey)
        }
        let lastBuild = UserDefaults.standard.object(forKey: lastBuildKey) as? Int ?? current
        UserDefaults.standard.set(current, forKey: lastRunBuildKey)
        // 强制更新 > 柔性提醒 > 公告：更新 UI 弹了就不再弹公告。
        if BearyForceUpdateCenter.shared.tryPresentUpdate(from: presenter, announcements: list) { return }
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
            let hasCurrentTarget = list.contains { $0.isAfterUpdate && ($0.targetBuild ?? Int.max) == current }
            if hasCurrentTarget {
                UserDefaults.standard.set(current, forKey: lastBuildKey)
            }
            return
        }
        // 先记已展示、再弹：弹过即结算，关掉后不再重弹。
        var nextShown = shown
        nextShown.insert(ann.id)
        UserDefaults.standard.set(Array(nextShown), forKey: shownIdsKey)
        // R13-4：只有更新后公告才结算构建号跨越；活动公告只记自己的展示 id，
        // 不动 lastBuildKey——否则同版更新公告会被先弹的活动公告烧掉。
        if ann.isAfterUpdate {
            UserDefaults.standard.set(current, forKey: lastBuildKey)
        }
        BearyAnnouncementSheet.show(from: presenter, announcement: ann)
    }
}
