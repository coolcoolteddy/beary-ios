import UIKit

// MARK: - 好友第一期（App 侧共享关注状态机与缓存清理，关注/回关模型版）
//
// 契约（见 ~/workspace/friends-plan-20261101.md，2026-11-01 关注/回关模型版，
// 旧“直接加好友、申请/接受/拒绝”口径全部作废）：关注单向、不用对方同意；
// 对方回关后双方变互关，互关才算好友。仅好友可见与私信只认互关。
// 后端接口并行施工中：接口未上线前非 200 一律走调用方失败态（toast、不改本地态）。
//
// 状态机（状态一律调 GET /friends/state 实时取，不靠本地缓存；任一方向拉黑 /
// 游客 / 本人 → 隐藏，由调用方先判）：
//   none（无关系）→ “关注”；following（我关他、未互关）→ “已关注”（点按进取关确认）；
//   followedBy（他关我、我未关）→ “回关”（点按即关注，成互关）；
//   mutual（互关）→ “互关”（点按进取关确认；取关后退为对方单向关注我）。
// 注意：App 只能查到“我拉黑的人”（BearyBlockedStore）；对方拉黑我时无 per-user
// 接口可查——此时关注按钮按“未拉黑”画出，点关注会被服务端 403，调用方只 toast，
// 不得把“查不到”说成“可关注”之外的任何保证。

extension Notification.Name {
    /// 关注关系变化广播（回关成互关 / 取关成功后发，无 object）：
    /// 广场好友段、关注流、他人主页、搜索行据此清缓存/重拉，防止取关后旧缓存里的
    /// 仅好友篇仍显示。单向关注不发（不产生可见内容变化）；拉黑另有广播。
    static let bearyFriendsChanged = Notification.Name("bearyFriendsChanged")
}

enum BearyFollowState {
    case none
    case following
    case followedBy
    case mutual

    /// state 回包派生：mutual 优先（后端同时给 mutual 时以它为准；只给两方向时
    /// 两真即互关）；缺字段一律按 false 计（fail-closed，不把“未给”画成关系）。
    init(response: BearyAPI.FollowStateResponse) {
        let following = response.following ?? false
        let followedBy = response.followedBy ?? false
        if response.mutual ?? false || (following && followedBy) {
            self = .mutual
        } else if following {
            self = .following
        } else if followedBy {
            self = .followedBy
        } else {
            self = .none
        }
    }
}

enum BearyFriends {

    /// 取关二次确认（alert，系统官方样式；确认后才发请求，失败只 toast、不改态；
    /// 取关不给震动）。mutual 与单向关注的文案分开：互关取关会断双向可见性，
    /// 单向取关只断自己的关注流。
    static func confirmUnfollow(from vc: UIViewController, displayName: String, userId: Int, mutual: Bool, onRemoved: @escaping () -> Void) {
        let message = mutual
            ? "取关后，你们不再是互关好友，对方将看不到你的仅好友日记，你也看不到对方的仅好友日记。"
            : "取关后，你将不再看到对方的日记动态。"
        let alert = UIAlertController(title: "取关", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取关", style: .destructive) { _ in
            BearyAPI.shared.unfollowFriend(userId: userId) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        clearDiaryCachesAndNotify()
                        onRemoved()
                    case .failure:
                        BearyToast.show(in: vc.view, message: "取关失败，请重试")
                    }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        vc.present(alert, animated: BearyMotion.animated(true))
    }

    /// 回关/取关成功后的本地清理：广场磁盘快照（只含公开，本就无仅好友篇，
    /// 但清掉可防旧 viewer 字段残留）按当前身份桶清；引用单篇内存缓存同清
    ///（取关后旧缓存里的仅好友引用全文不得再出）；各列表页收到广播后重拉。
    static func clearDiaryCachesAndNotify() {
        let bucket = BearyFeedCache.bucket(userId: SessionManager.shared.currentUser?.id)
        BearyFeedCache.purge(bucket: bucket)
        BearyDiaryCardCell.quoteCache.removeAll()
        NotificationCenter.default.post(name: .bearyFriendsChanged, object: nil)
    }
}
