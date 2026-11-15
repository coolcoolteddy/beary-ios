import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 第三轮审计 ④：注册 BGAppRefreshTask 后台刷新（此前全仓 0 命中，
        // 系统从不会在后台唤醒 App）；标识须在 Info.plist 的
        // BGTaskSchedulerPermittedIdentifiers 里，否则注册返回 false。
        BearyBackgroundRefresh.registerAndSchedule()
        // 审计动效组：启动时后台预热全部 11 音，首次播放不走主线程文件 IO。
        // 第三轮审计 14：音效关闭时不预热（门控在 BearySoundPlayer.prewarmAll 内）。
        BearySoundPlayer.prewarmAll()
        // 审计四轮 16：启动时清掉过期导出临时文件（只认 teddyhn-data-
        // 前缀、只清超过 24 小时的，中途退出残留兜底；分享收起即删仍是主路径）。
        BearySettingsViewController.BearyExportTempFileCleanup.cleanStaleExportFiles()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
