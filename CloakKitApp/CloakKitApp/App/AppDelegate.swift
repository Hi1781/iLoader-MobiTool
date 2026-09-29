import UIKit

// 入口：与参考工程(ClipboardHistory)一致，@main UIApplicationDelegate，
// 用代码搭建窗口与根控制器（无 storyboard，便于 Swift 5.8 Linux 交叉编译）。
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MainTabBarController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
