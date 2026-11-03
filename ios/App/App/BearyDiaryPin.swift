import UIKit

/// 日记置顶共享口径（2026-11-03 Li 定，单槽位；显示与入口 2026-11-03 Li 再纠正）：
/// - 置顶排序只在个人页生效：置顶篇排个人页最前、带图钉＋橙色“置顶”标识，别人看该主页也在最前；广场／时间线顺序不动。
/// - 置顶／取消置顶入口只留个人页卡片 ⋯ 菜单：未置顶显“置顶”，已置顶显“取消置顶”，只对本人日记出现，点按即时生效（乐观更新）。
/// - 置顶标识仅限个人页：时间线／详情／广场均不画图钉与“置顶”文字。
/// - 最多 1 个：置顶新篇时旧篇自动取消；App 端替换先弹确认（见 confirmReplacement），取消时绝不调 pin 接口。
/// - 仅本人可置顶自己的日记（菜单行门禁＋服务端作者校验）。
/// - 图标走官方 icon_pin（BearyFeedIconCache／BearyIconImages 同款缓存口径），不得自绘。
/// - 本文件只放 App target（依赖 SessionManager／BearyToast 等 App 内类型，与 BearyFriends.swift 同例，不进测试 target）。
enum BearyDiaryPin {

    /// 本账号最近一次在作者 scope（个人页日记 tab）见到的置顶篇 id。
    /// 供个人页“当前列表未必含置顶篇”时判断替换确认用：
    /// 有记忆且与目标不同 → 弹确认；无记忆 → 直接置顶（后端单槽位仍会替换，见 PR 已知缺口）。
    /// 只在“见到置顶篇”时写入，缺失不清除（列表未必含置顶篇，缺失 ≠ 未置顶）。
    static var currentPinnedEntryId: String?

    /// 从作者 scope 列表同步记忆：只认 isPinned 的篇；他人页列表不得调（调用方以 isOwnProfile 守门）。
    static func noteEntries(_ entries: [Entry]) {
        if let pinned = entries.first(where: { $0.isPinned }), let id = pinned.id {
            currentPinnedEntryId = id
        }
    }

    /// 置顶／取消置顶成功后同步记忆。
    static func notePinResult(entryId: String, pinned: Bool) {
        if pinned {
            currentPinnedEntryId = entryId
        } else if currentPinnedEntryId == entryId {
            currentPinnedEntryId = nil
        }
    }

    /// 本人判定（个人页 viewerIsAuthor 同款：isMine 或 authorId == 当前登录用户）。
    static func isOwn(_ entry: Entry) -> Bool {
        entry.isMine == true || (entry.authorId != nil && entry.authorId == SessionManager.shared.currentUser?.id)
    }

    /// 除目标篇外已知的另一置顶篇 id：先查本页列表，再查共享记忆；都没有则 nil。
    static func existingPinnedId(excluding entryId: String, in entries: [Entry]) -> String? {
        if let local = entries.first(where: { $0.id != entryId && $0.isPinned })?.id {
            return local
        }
        if let known = currentPinnedEntryId, known != entryId {
            return known
        }
        return nil
    }

    /// 替换旧置顶篇的确认：系统 UIAlertController .alert（取关确认
    /// BearyFriends.confirmUnfollow 同款式，不自造新弹窗样式；动效走 BearyMotion）。
    /// 取消只调 completion(false)，调用方此时绝不发请求、不改本地态。
    static func confirmReplacement(from vc: UIViewController, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "置顶这篇日记？", message: "已有置顶日记，置顶这篇会取消上一篇的置顶。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "置顶", style: .default) { _ in completion(true) })
        vc.present(alert, animated: BearyMotion.animated(true))
    }

    /// 置顶失败 toast 文案：401／404／403／503 按接口口径分流，其余走通用失败文案；
    /// 限流沿用项目现有 rate_limited／429 文案。error 体带码的 403（.server）无法从码反推，
    /// 走通用文案，不编造服务端码。
    static func errorMessage(for error: APIError, pinning: Bool) -> String {
        switch error {
        case .unauthorized:
            return "请先登录"
        case .notFound:
            return "日记不存在"
        case .http(let status, _) where status == 403:
            return "仅作者可以置顶"
        case .http(let status, _) where status == 503:
            return "置顶功能暂不可用，请稍后再试"
        case .server(let code) where code == "rate_limited":
            return "操作太频繁，请稍后再试"
        case .http(let status, _) where status == 429:
            return "操作太频繁，请稍后再试"
        default:
            return pinning ? "置顶失败，请重试" : "取消置顶失败，请重试"
        }
    }
}
