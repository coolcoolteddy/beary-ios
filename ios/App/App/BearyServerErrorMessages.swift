import Foundation

/// 服务端业务码→用户文案共享码表：发布与编辑共用的三个分支。
/// BearyPublishCenter.message(forPublishError:) 与
/// BearyComposerViewController.message(forUpdateError:) 先查这里，
/// 未命中再走各自专属分支与默认文案；文案一字不改。
enum BearyServerErrorMessages {
    /// 共用分支命中时返回文案，未命中返回 nil。
    static func sharedMessage(forServerCode code: String) -> String? {
        switch code {
        case "content too long":
            return NSLocalizedString("server_error.content_too_long", comment: "")
        case "title too long":
            return NSLocalizedString("server_error.title_too_long", comment: "")
        case "image unavailable":
            return NSLocalizedString("server_error.image_unavailable", comment: "")
        default:
            return nil
        }
    }
}
