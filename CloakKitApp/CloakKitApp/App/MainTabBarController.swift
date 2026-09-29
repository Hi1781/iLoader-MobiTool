import UIKit

// 主 Tab 容器：账号 / 安装 / 应用 / 设置，适配 iPhone 与 iPad。
final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let account = wrap(AccountViewController(), title: "账号", icon: "person.circle")
        let install = wrap(InstallViewController(), title: "安装", icon: "arrow.down.circle")
        let apps = wrap(AppsViewController(), title: "应用", icon: "square.grid.2x2")
        let settings = wrap(SettingsViewController(), title: "设置", icon: "gearshape")
        viewControllers = [account, install, apps, settings]
    }

    private func wrap(_ vc: UIViewController, title: String, icon: String) -> UINavigationController {
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.title = "CloakKit · \(title)"
        nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), selectedImage: nil)
        return nav
    }
}
