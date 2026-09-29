import UIKit

// 账号：Apple ID 登录（调用 Rust 内核 FFI）+ 2FA 校验。
// Anisette 服务器：默认读取设置页所选（iLoader 8 预设 + 自定义）。
final class AccountViewController: UIViewController {
    private let bridge = FFIBridge.shared
    private let emailField = UITextField()
    private let passField = UITextField()
    private let anisetteField = UITextField()
    private let pickerButton = UIButton(type: .system)
    private let codeField = UITextField()
    private let statusLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var awaiting2FA = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        refreshServerDisplay()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshServerDisplay()
    }

    private func refreshServerDisplay() {
        let host = AnisetteServer.selected
        anisetteField.text = host == AnisetteServer.defaultHost ? "" : host
        pickerButton.setTitle("服务器：" + AnisetteServer.label(for: host) + "（点此更换）", for: .normal)
    }

    private func buildUI() {
        let title = makeLabel("Apple ID 登录", font: .preferredFont(forTextStyle: .title2))
        title.adjustsFontForContentSizeCategory = true

        emailField.placeholder = "邮箱"
        emailField.autocapitalizationType = .none
        emailField.keyboardType = .emailAddress
        emailField.font = .preferredFont(forTextStyle: .body)
        emailField.adjustsFontForContentSizeCategory = true
        emailField.borderStyle = .roundedRect

        passField.placeholder = "密码"
        passField.isSecureTextEntry = true
        passField.font = .preferredFont(forTextStyle: .body)
        passField.adjustsFontForContentSizeCategory = true
        passField.borderStyle = .roundedRect

        anisetteField.placeholder = "Anisette 服务器（留空用默认）"
        anisetteField.autocapitalizationType = .none
        anisetteField.keyboardType = .URL
        anisetteField.font = .preferredFont(forTextStyle: .body)
        anisetteField.adjustsFontForContentSizeCategory = true
        anisetteField.borderStyle = .roundedRect

        pickerButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        pickerButton.titleLabel?.adjustsFontForContentSizeCategory = true
        pickerButton.contentHorizontalAlignment = .left
        pickerButton.addTarget(self, action: #selector(pickServer), for: .touchUpInside)

        codeField.placeholder = "6 位验证码"
        codeField.keyboardType = .numberPad
        codeField.font = .preferredFont(forTextStyle: .body)
        codeField.borderStyle = .roundedRect
        codeField.isHidden = true

        actionButton.setTitle("登录", for: .normal)
        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        actionButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.text = "未登录"

        let stack = UIStackView(arrangedSubviews: [title, emailField, passField, anisetteField, pickerButton, codeField, actionButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // iPad 适配：可读宽度（≤520）居中；iPhone 保持满宽
        ReadableWidth.pin(stack, in: view)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func makeLabel(_ s: String, font: UIFont) -> UILabel {
        let l = UILabel()
        l.text = s
        l.font = font
        l.adjustsFontForContentSizeCategory = true
        return l
    }

    /// 预设服务器快速选择（iLoader 8 预设 + 自定义）
    @objc private func pickServer() {
        let alert = UIAlertController(title: "Anisette 服务器", message: "选择预设，或到「设置」页自定义", preferredStyle: .actionSheet)
        for p in AnisetteServer.presets {
            alert.addAction(UIAlertAction(title: "\(p.label) · \(p.host)", style: .default) { _ in
                AnisetteServer.selected = p.host
                self.refreshServerDisplay()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = pickerButton
            pop.sourceRect = pickerButton.bounds
        }
        present(alert, animated: true, completion: nil)
    }

    @objc private func primaryTapped() {
        if awaiting2FA {
            let code = codeField.text ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let r = self.bridge.verify2FA(code: code)
                DispatchQueue.main.async {
                    if r == .ok { self.statusLabel.text = "已登录 ✅"; self.awaiting2FA = false; self.codeField.isHidden = true }
                    else { self.statusLabel.text = "2FA 验证失败：\(self.bridge.lastError)" }
                }
            }
        } else {
            let email = emailField.text ?? ""
            let pass = passField.text ?? ""
            // 服务器：字段为空 → 用设置页所选（登录时内核自动补 https://）
            let fieldURL = (anisetteField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let server: String? = fieldURL.isEmpty ? AnisetteServer.selected : fieldURL
            statusLabel.text = "登录中…（服务器：\(server ?? AnisetteServer.defaultHost)）"
            DispatchQueue.global(qos: .userInitiated).async {
                let r = self.bridge.login(email: email, password: pass, anisetteURL: server)
                DispatchQueue.main.async {
                    switch r {
                    case .ok:
                        self.statusLabel.text = "已登录 ✅（内核 v\(self.bridge.version)）"
                    case .needs2FA, .needsDevice2FA, .needsSMS2FAVerify:
                        self.awaiting2FA = true
                        self.codeField.isHidden = false
                        self.statusLabel.text = "需要验证码：请输入 6 位验证码"
                    case .needsSMS2FA:
                        self.awaiting2FA = true
                        self.codeField.isHidden = false
                        self.statusLabel.text = "需要短信验证码"
                    default:
                        self.statusLabel.text = "登录失败（\(r.rawValue)）：\(self.bridge.lastError)"
                    }
                }
            }
        }
    }
}
