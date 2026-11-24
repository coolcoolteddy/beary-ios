import UIKit
import UserNotifications

/// 远程推送（2026-11-25，私信第一期）：APNs 远程推送只用于私信到达提醒。
/// 与 BearyLocalNotifications 分工：本地通知（21:00 写日记提醒、限时到期等）
/// 仍走本地排程；本文件只管远程——注册、device token 上报、远端私信推送的识别与路由。
/// 权限口径：本文件从不主动弹系统授权框。UNUserNotificationCenter 的授权本地与
/// 远程共用一份，授权仍由现有本地通知流程问（注册后引导页、写完第一篇日记后的
/// 说明卡）；授权已给时这里只做 registerForRemoteNotifications（不二次弹框），
/// 未授权时什么都不做，等用户在现有流程里授权后再由回前台／登录回调补注册。
/// 推送内容口径：服务端只发通用文案（“你有一条新私信”），不带私信正文；
/// 点按进会话后内容才由 App 内拉取，与本地通知行同路。
final class BearyPushNotifications {

    static let shared = BearyPushNotifications()

    /// 远端私信推送在 userInfo 里带这些键（与服务端 sendApnsDmPush 同口径）。
    /// 本地通知带 kind＋accountId、不带 aps，两类靠 aps 区分。
    struct RemoteDM {
        let senderId: Int
        let senderName: String?
        let accountId: Int
    }

    private static let deviceTokenKey = "beary_push_device_token"
    private static func lastSentTokenKey(userId: Int) -> String { "beary_push_last_sent_token_\(userId)" }

    private init() {}

    // MARK: - 注册

    /// 已授权才注册：授权状态由现有本地通知流程决定，这里只读不问。
    /// 调用点：SceneDelegate willConnectTo（冷启动）与 sceneDidBecomeActive
    ///（回前台——用户在引导页／首篇提示里刚授权时，下次回前台即补注册）。
    func registerIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// AppDelegate 转发：系统下发 device token（每次启动都可能变，token 刷新也走这里）。
    /// 只存不发，上报由 syncTokenIfNeeded 统一做（登录态变化时才有意义）。
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        UserDefaults.standard.set(hex, forKey: Self.deviceTokenKey)
        syncTokenIfNeeded()
    }

    /// AppDelegate 转发：注册失败只记日志，不 toast、不重试（下次启动／回前台重走 registerIfAuthorized）。
    func didFailToRegister(error: Error) {
        NSLog("[BearyPush] registerForRemoteNotifications failed: %@", error.localizedDescription)
    }

    // MARK: - Token 上报

    /// 有 token 且已登录、且本账号上次上报的 token 不同时，才 POST 上报。
    /// 调用点：didRegister 后、SceneDelegate onUserChanged（登录／切号）与回前台；
    /// 未登录时只存 token，等登录回调再发。失败静默（下次回前台／登录再试），
    /// 不 toast、不阻塞任何流程。
    func syncTokenIfNeeded() {
        guard let token = UserDefaults.standard.string(forKey: Self.deviceTokenKey), !token.isEmpty else { return }
        guard let userId = SessionManager.shared.currentUser?.id else { return }
        guard UserDefaults.standard.string(forKey: Self.lastSentTokenKey(userId: userId)) != token else { return }
        BearyAPI.shared.requestVoid("/beary/api/account/device-token", method: "POST", jsonBody: ["device_token": token]) { result in
            if case .success = result {
                UserDefaults.standard.set(token, forKey: Self.lastSentTokenKey(userId: userId))
            }
        }
    }

    // MARK: - 远端私信推送识别

    /// 远端推送的判定：带 aps 字典且 type == "dm"。本地通知不带 aps，不会误判。
    static func remoteDM(from notification: UNNotification) -> RemoteDM? {
        let info = notification.request.content.userInfo
        guard info["aps"] is [AnyHashable: Any],
              let type = info["type"] as? String, type == "dm",
              let senderId = info["sender_id"] as? Int,
              let accountId = info["account_id"] as? Int else { return nil }
        let senderName = info["sender_name"] as? String
        return RemoteDM(senderId: senderId, senderName: senderName, accountId: accountId)
    }

    /// 点按远端私信推送的路由：账号校验与本地通知同口径（排程账号与当前账号
    /// 不一致时不路由，切号后点旧通知不得进新账号内容）；peer 按通知页私信行
    /// 同款拼最小 FriendUser（只有 id＋名字，头像与 handle 进会话后由会话页自取）。
    static func peer(for remoteDM: RemoteDM) -> BearyAPI.FriendUser? {
        guard SessionManager.shared.currentUser?.id == remoteDM.accountId else {
            NSLog("[BearyPush] remote DM tap ignored: account mismatch")
            return nil
        }
        return BearyAPI.FriendUser(id: remoteDM.senderId, displayName: remoteDM.senderName, handle: nil, avatarUrl: nil, createdAt: nil)
    }
}
