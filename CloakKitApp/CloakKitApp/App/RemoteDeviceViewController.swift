import UIKit

/// 设备：为「其他设备」做 SideStore 式无线远程安装。
/// 流程：导入 .mobiledevicepairing → 填目标设备局域网 IP → 建立 software tunnel
///       → 浏览/卸载已装应用 / 选择 IPA 远程安装（进度回调）。
final class RemoteDeviceViewController: UIViewController {

    private let bridge = FFIBridge.shared

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    private let ipField = UITextField()
    private let statusLabel = UILabel()
    private let tunnelLabel = UILabel()

    private var apps: [FFIBridge.RemoteApp] = []
    private var tableView: UITableView!
    private var tableHeight: NSLayoutConstraint!

    private var progressTimer: Timer?
    private var currentTask: Int64 = 0
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        refreshPairingUI()
        refreshTunnel()
    }

    // MARK: UI

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 680)
        ])
        let fill = stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        fill.priority = .defaultHigh
        fill.isActive = true

        addHeader("① 导入配对文件")
        let importBtn = makeButton("选择 .mobiledevicepairing", action: #selector(pickPairing), filled: true)
        stack.addArrangedSubview(importBtn)
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(statusLabel)

        addHeader("② 目标设备局域网 IP")
        ipField.borderStyle = .roundedRect
        ipField.placeholder = "例如 192.168.1.23"
        ipField.keyboardType = .numbersAndPunctuation
        ipField.autocapitalizationType = .none
        ipField.font = .preferredFont(forTextStyle: .body)
        stack.addArrangedSubview(ipField)
        let fetchBtn = makeButton("读取设备信息", action: #selector(fetchInfo), filled: false)
        stack.addArrangedSubview(fetchBtn)

        addHeader("③ 远程调试隧道")
        let tunnelRow = UIStackView()
        tunnelRow.axis = .horizontal
        tunnelRow.spacing = 10
        tunnelRow.distribution = .fillEqually
        tunnelRow.addArrangedSubview(makeButton("建立隧道", action: #selector(openTunnel), filled: true))
        tunnelRow.addArrangedSubview(makeButton("关闭", action: #selector(closeTunnel), filled: false))
        stack.addArrangedSubview(tunnelRow)
        tunnelLabel.numberOfLines = 0
        tunnelLabel.font = .preferredFont(forTextStyle: .footnote)
        tunnelLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(tunnelLabel)

        addHeader("④ 远程安装 / 应用")
        stack.addArrangedSubview(makeButton("选择 IPA 安装到此设备", action: #selector(pickIPA), filled: true))
        progressBar.isHidden = true
        stack.addArrangedSubview(progressBar)
        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.textColor = .secondaryLabel
        progressLabel.numberOfLines = 0
        stack.addArrangedSubview(progressLabel)

        stack.addArrangedSubview(makeButton("刷新已装应用", action: #selector(loadApps), filled: false))

        tableView = UITableView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "app")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.isScrollEnabled = false
        tableHeight = tableView.heightAnchor.constraint(equalToConstant: 0)
        tableHeight.isActive = true
        stack.addArrangedSubview(tableView)

        let hint = UILabel()
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.text = "前置条件：两台设备同一 Wi‑Fi；目标设备已开启「开发者模式」与「无线调试」，并已有由电脑/SideStore 生成的配对记录。iOS17+ 首次可能需要挂载开发者镜像。"
        stack.addArrangedSubview(hint)
    }

    private func addHeader(_ t: String) {
        let l = UILabel()
        l.text = t
        l.font = .preferredFont(forTextStyle: .headline)
        l.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(l)
    }

    private func makeButton(_ title: String, action: Selector, filled: Bool) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .preferredFont(forTextStyle: .body)
        b.titleLabel?.adjustsFontForContentSizeCategory = true
        if filled {
            b.backgroundColor = .systemBlue
            b.setTitleColor(.white, for: .normal)
            b.layer.cornerRadius = 10
        } else {
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.systemBlue.cgColor
            b.layer.cornerRadius = 10
        }
        b.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    // MARK: Actions

    @objc private func pickPairing() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func fetchInfo() {
        saveIP()
        do {
            let info = try bridge.fetchDeviceInfo()
            let name = info["name"] as? String ?? "?"
            let udid = info["udid"] as? String ?? "?"
            let os = info["osVersion"] as? String ?? "?"
            let model = info["productType"] as? String ?? "?"
            statusLabel.text = "已连接：\(name)\n\(model) · iOS \(os)\n\(udid)"
        } catch {
            statusLabel.text = "读取失败：\(error.localizedDescription)"
        }
    }

    @objc private func openTunnel() {
        saveIP()
        let ok = bridge.openTunnel()
        if !ok {
            tunnelLabel.text = "失败：\(bridge.lastError)"
        }
        refreshTunnel()
        if ok { loadApps() }
    }

    @objc private func closeTunnel() {
        bridge.closeTunnel()
        refreshTunnel()
    }

    @objc private func loadApps() {
        do {
            apps = try bridge.listRemoteApps()
            tableView.reloadData()
            DispatchQueue.main.async {
                self.tableHeight.constant = CGFloat(self.apps.count) * 48
                self.view.layoutIfNeeded()
            }
        } catch {
            tunnelLabel.text = "应用列表：\(error.localizedDescription)"
        }
    }

    @objc private func pickIPA() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    private func saveIP() {
        let ip = ipField.text ?? ""
        if !ip.isEmpty {
            bridge.setDeviceIP(ip)
        }
    }

    private func refreshPairingUI() {
        if let p = bridge.pairingInfo() {
            statusLabel.text = "已导入配对：\(p.udid)\nHostID \(p.hostId)"
            if ipField.text?.isEmpty != false { ipField.text = p.ip }
        } else {
            statusLabel.text = "尚未导入配对文件。"
        }
    }

    private func refreshTunnel() {
        let s = bridge.tunnelStatus()
        if (s["open"] as? Bool) == true {
            let cip = s["clientIp"] as? String ?? "?"
            let sip = s["serverIp"] as? String ?? "?"
            tunnelLabel.text = "隧道已建立\n本地虚拟IP \(cip) → 设备 \(sip)"
            tunnelLabel.textColor = .systemGreen
        } else {
            tunnelLabel.text = "隧道未建立"
            tunnelLabel.textColor = .secondaryLabel
        }
    }

    // MARK: install polling

    private func startInstall(url: URL) {
        let id = bridge.startInstall(ipa: url)
        guard id > 0 else {
            progressLabel.text = "启动失败：\(bridge.lastError)"
            return
        }
        currentTask = id
        progressBar.isHidden = false
        progressBar.setProgress(0, animated: false)
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollProgress(id)
        }
    }

    private func pollProgress(_ id: Int64) {
        guard let p = bridge.installProgress(id) else { return }
        progressBar.setProgress(Float(p.percent) / 100.0, animated: true)
        progressLabel.text = "\(p.message)（\(p.percent)%）"
        if p.done {
            progressTimer?.invalidate()
            progressTimer = nil
            if let e = p.error {
                progressLabel.text = "失败：\(e)"
            } else {
                progressLabel.text = "安装完成 ✅"
                loadApps()
            }
        }
    }
}

extension RemoteDeviceViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" {
            startInstall(url: url)
        } else {
            // 视为配对文件
            let ip = ipField.text ?? ""
            if bridge.importPairing(at: url, ip: ip) {
                refreshPairingUI()
            } else {
                statusLabel.text = "导入失败：\(bridge.lastError)"
            }
        }
    }
}

extension RemoteDeviceViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { apps.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = tableView.dequeueReusableCell(withIdentifier: "app", for: indexPath)
        let a = apps[indexPath.row]
        c.textLabel?.text = a.displayName.isEmpty ? a.name : a.displayName
        c.detailTextLabel?.text = "\(a.bundleId) · v\(a.version)"
        c.textLabel?.font = .preferredFont(forTextStyle: .body)
        c.detailTextLabel?.font = .preferredFont(forTextStyle: .caption2)
        return c
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let a = apps[indexPath.row]
        let ac = UIAlertController(title: "卸载 \(a.name)", message: a.bundleId, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "卸载", style: .destructive) { [weak self] _ in
            if self?.bridge.uninstallRemoteApp(a.bundleId) == true {
                self?.loadApps()
            }
        })
        present(ac, animated: true)
    }
}
