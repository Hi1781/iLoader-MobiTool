import UIKit

// 设置：Anisette 服务器（iLoader 默认列表 + 自定义）、内核版本、环境自检
final class SettingsViewController: UITableViewController {
    private var warnings: [String] = []
    private var customEditing = false
    private var customField: UITextField?

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        // iPad 可读宽度：表视图在宽屏下不铺满全宽
        view.backgroundColor = .systemBackground
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 3                  // 当前服务器 / 预设 / 自定义
        case 1: return 2                  // 内核版本 / 环境自检
        default: return max(warnings.count, 1)
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Anisette 服务器"
        case 1: return "CloakKit"
        default: return "检查结果"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "登录时自动补 https://。留空或用默认服务器，多个服务器可逐个尝试。" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        c.textLabel?.numberOfLines = 0
        c.textLabel?.textColor = .label
        c.accessoryType = .none
        c.selectionStyle = .default
        c.textLabel?.font = .preferredFont(forTextStyle: .body)
        c.textLabel?.adjustsFontForContentSizeCategory = true
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                let host = AnisetteServer.selected
                c.textLabel?.text = "当前：" + AnisetteServer.label(for: host) + "\n" + host
                c.textLabel?.textColor = .secondaryLabel
                c.selectionStyle = .none
            } else if indexPath.row == 1 {
                c.textLabel?.text = "选择预设服务器"
                c.accessoryType = .disclosureIndicator
            } else {
                if customEditing {
                    let field = UITextField(frame: CGRect(x: 20, y: 6, width: c.bounds.width - 40, height: 32))
                    field.placeholder = "ani.yourserver.com"
                    field.text = AnisetteServer.selected
                    field.autocapitalizationType = .none
                    field.keyboardType = .URL
                    field.returnKeyType = .done
                    field.font = .preferredFont(forTextStyle: .body)
                    field.clearButtonMode = .whileEditing
                    field.addTarget(self, action: #selector(customChanged(_:)), for: .editingChanged)
                    field.addTarget(self, action: #selector(customDone(_:)), for: .editingDidEndOnExit)
                    c.contentView.addSubview(field)
                    customField = field
                    c.textLabel?.text = ""
                } else {
                    c.textLabel?.text = "自定义服务器"
                }
            }
        } else if indexPath.section == 1 {
            if indexPath.row == 0 {
                c.textLabel?.text = "内核版本"
                c.detailTextLabel?.text = FFIBridge.shared.version
            } else {
                c.textLabel?.text = "环境自检"
                c.textLabel?.textColor = .systemBlue
                c.accessoryType = .disclosureIndicator
            }
        } else {
            if warnings.isEmpty {
                c.textLabel?.text = "点击上方「环境自检」查看结果"
                c.textLabel?.textColor = .secondaryLabel
            } else {
                c.textLabel?.text = "⚠️ " + warnings[indexPath.row]
                c.textLabel?.textColor = .secondaryLabel
            }
        }
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            if indexPath.row == 1 { presentPresetPicker() }
            else if indexPath.row == 2 { toggleCustom() }
        } else if indexPath.section == 1 && indexPath.row == 1 {
            warnings = SideStoreBridge.environmentCheck()
            tableView.reloadSections([2], with: .automatic)
        }
    }

    /// 预设服务器选择（action sheet，iLoader 8 个预设 + 自定义）
    private func presentPresetPicker() {
        let alert = UIAlertController(title: "Anisette 服务器", message: "选择预设或自定义", preferredStyle: .actionSheet)
        for p in AnisetteServer.presets {
            alert.addAction(UIAlertAction(title: "\(p.label) · \(p.host)", style: .default) { _ in
                AnisetteServer.selected = p.host
                self.customEditing = false
                self.tableView.reloadSections([0], with: .automatic)
            })
        }
        alert.addAction(UIAlertAction(title: "自定义…", style: .default) { _ in
            self.customEditing = true
            self.tableView.reloadSections([0], with: .automatic)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        // iPad action sheet 需要 popover 锚点
        if let pop = alert.popoverPresentationController {
            pop.sourceView = tableView
            pop.sourceRect = tableView.rectForRow(at: IndexPath(row: 1, section: 0))
        }
        present(alert, animated: true, completion: nil)
    }

    private func toggleCustom() {
        if customEditing {
            customField?.resignFirstResponder()
            customEditing = false
        } else {
            customEditing = true
        }
        tableView.reloadSections([0], with: .automatic)
    }

    @objc private func customChanged(_ field: UITextField) {
        if let t = field.text, !t.isEmpty { AnisetteServer.selected = t }
    }

    @objc private func customDone(_ field: UITextField) {
        if let t = field.text, !t.isEmpty { AnisetteServer.selected = t }
        field.resignFirstResponder()
        customEditing = false
        tableView.reloadSections([0], with: .automatic)
    }
}
