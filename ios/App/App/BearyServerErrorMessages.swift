/// 服务端业务码→用户文案共享码表：发布与编辑共用的三个分支。
/// BearyPublishCenter.message(forPublishError:) 与
/// BearyComposerViewController.message(forUpdateError:) 先查这里，
/// 未命中再走各自专属分支与默认文案；文案一字不改。
enum BearyServerErrorMessages {
    /// 共用分支命中时返回文案，未命中返回 nil。
    static func sharedMessage(forServerCode code: String) -> String? {
        switch code {
        case "content too long":
            return "正文最多 2000 字"
        case "title too long":
            return "标题最多 30 字"
        case "image unavailable":
            return "图片已失效，请重新添加"
        default:
            return nil
        }
    }
}
