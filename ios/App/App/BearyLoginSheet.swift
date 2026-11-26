import UIKit

// ===== 登录改版（2026-11-26，Luma 式，预览 v3）：欢迎页＋底部登录卡 =====
// 形态：全屏 modal（modalPresentationStyle = .fullScreen），欢迎页在上、
// 登录区在卡片下方（拖动卡片上滑露出）；邮箱登录是单独一页
//（BearyEmailLoginViewController），登录完新注册用户进资料页
//（BearyProfileSetupViewController，由 SceneDelegate 接）。
// 容器：BearyLoginSheet.make() 只建欢迎页、不 present；调用点按原样接回调后再 present
//（与旧全页登录顺序一致，含 dismiss 调用方与会话守卫；关闭只关登录页自身）。
// 名字保留 BearyLoginSheet.make()：全部调用点（设置页、个人页、盲盒、私信、回收站、
// 许愿墙、SceneDelegate、引导页）一字不动即走新欢迎页，不留两套登录入口。
// 旧 BearyLoginViewController（全页登录）已随改版删除：邮箱验证码／密码登录
// 逻辑搬进 BearyEmailLoginViewController，Apple 登录搬进 BearyWelcomeViewController。

enum BearyLoginSheet {
    /// 建一个欢迎页（BearyWelcomeViewController，全屏 modal），不 present；
    /// 调用点接完回调后自行 present。
    static func make() -> BearyWelcomeViewController {
        let vc = BearyWelcomeViewController()
        vc.modalPresentationStyle = .fullScreen
        return vc
    }
}
