import UIKit

// 设置：内核版本、环境自检
final class SettingsViewController: UITableViewController {
    private var warnings: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : max(warnings.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "CloakKit" : "检查结果"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                c.textLabel?.text = "内核版本"
                c.detailTextLabel?.text = FFIBridge.shared.version
            } else {
                c.textLabel?.text = "环境自检"
                c.textLabel?.textColor = .systemBlue
                c.accessoryType = .disclosureIndicator
            }
        } else {
            c.textLabel?.numberOfLines = 0
            if warnings.isEmpty {
                c.textLabel?.text = "点击上方「环境自检」查看结果"
                c.textLabel?.textColor = .secondaryLabel
            } else {
                c.textLabel?.text = "⚠️ " + warnings[indexPath.row]
            }
        }
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 && indexPath.row == 1 {
            warnings = SideStoreBridge.environmentCheck()
            tableView.reloadSections([1], with: .automatic)
        }
    }
}
