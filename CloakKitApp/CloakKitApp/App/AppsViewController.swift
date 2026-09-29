import UIKit

// 应用：已安装侧载应用列表（数据由 SideStore 记录填充，当前为空态）
final class AppsViewController: UITableViewController {
    private var items: [InstalledApp] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let app = items[indexPath.row]
        c.textLabel?.text = app.name
        c.detailTextLabel?.text = "\(app.id) · v\(app.version)"
        return c
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if items.isEmpty {
            // 真实实现：读取 SideStore 的 installed apps 记录
        }
    }
}
