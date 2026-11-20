import Foundation
import GoogleSignIn
import UIKit

// Google 登录（2026-11-20 Li 定：加，排队尾做）。
// 路子与 Apple 登录一样：App 拿 ID token → 后端 POST /api/account/google-login
// 验签建会话（发与验码同一套 30 天 session）。只申请 openid/email/profile
// 三个 scope（SDK 默认即这三个，不另加）。
// 按钮用官方 GIDSignInButton（Google 品牌规范要求，不自由改样式）。
// 占位：OAuth 客户端 ID 还没建（Li 在 Google Cloud 建项目后补）；未配置前
// 入口不触发 SDK，只提示尚未开通。真实值填进 Info.plist 的 GIDClientID /
// GIDServerClientID 与反向 client ID 的 URL scheme，见 PR 正文。
enum BearyGoogleSignIn {

    /// Info.plist 里 GIDClientID / GIDServerClientID 的占位值（不是真实 client ID）。
    static let placeholderClientID = "GOOGLE_IOS_CLIENT_ID_PLACEHOLDER"
    static let placeholderServerClientID = "GOOGLE_SERVER_CLIENT_ID_PLACEHOLDER"

    /// 是否已配好真实 client ID（占位时 false）。
    static var isConfigured: Bool {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty,
              clientID != placeholderClientID else { return false }
        return true
    }

    /// 官方 Google 登录按钮（品牌规范：直接用 SDK 自带按钮，不改样式）。
    /// style .wide 撑满行宽；colorScheme 跟随当前深浅。
    static func makeSignInButton() -> GIDSignInButton {
        let button = GIDSignInButton()
        button.style = .wide
        button.colorScheme = currentColorScheme()
        return button
    }

    static func currentColorScheme() -> GIDSignInButtonColorScheme {
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }

    enum SignInError: Error {
        /// 用户在 Google 页点了取消（调用方不弹错）。
        case cancelled
        /// 未配置真实 client ID。
        case notConfigured
        /// 其他失败（网络、SDK 报错、取不到 ID token）。
        case failed
    }

    /// 调起 Google 登录，成功回 ID token + 姓名（姓名只用于新账号首次写 display_name）。
    static func signIn(from presenting: UIViewController, completion: @escaping (Result<(idToken: String, fullName: String?), SignInError>) -> Void) {
        guard isConfigured else {
            completion(.failure(.notConfigured))
            return
        }
        GIDSignIn.sharedInstance.signIn(withPresenting: presenting) { result, error in
            if let error {
                completion(.failure(isCancelled(error) ? .cancelled : .failed))
                return
            }
            guard let user = result?.user else {
                completion(.failure(.failed))
                return
            }
            // 官方文档口径：发后端前先 refreshTokensIfNeeded，保证 ID token 新鲜。
            user.refreshTokensIfNeeded { user, error in
                guard error == nil,
                      let user,
                      let idToken = user.idToken?.tokenString,
                      !idToken.isEmpty else {
                    completion(.failure(.failed))
                    return
                }
                completion(.success((idToken: idToken, fullName: user.profile?.name)))
            }
        }
    }

    /// Google 登录取消的错误码：kGIDSignInErrorCodeCanceled = -5（SDK 头文件实证）。
    private static func isCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.google.GIDSignIn" && nsError.code == -5
    }
}
