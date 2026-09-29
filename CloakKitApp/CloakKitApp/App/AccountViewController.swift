import UIKit

// 账号：Apple ID 登录（调用 Rust 内核 FFI）+ 2FA 校验
final class AccountViewController: UIViewController {
    private let bridge = FFIBridge.shared
    private let emailField = UITextField()
    private let passField = UITextField()
    private let anisetteField = UITextField()
    private let codeField = UITextField()
    private let statusLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var awaiting2FA = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
    }

    private func buildUI() {
        let title = makeLabel("Apple ID 登录", font: .boldSystemFont(ofSize: 20))
        emailField.placeholder = "邮箱"
        emailField.autocapitalizationType = .none
        emailField.keyboardType = .emailAddress
        passField.placeholder = "密码"
        passField.isSecureTextEntry = true
        anisetteField.placeholder = "Anisette 服务器（可选，留空用默认）"
        anisetteField.autocapitalizationType = .none
        codeField.placeholder = "6 位验证码"
        codeField.keyboardType = .numberPad
        codeField.isHidden = true

        actionButton.setTitle("登录", for: .normal)
        actionButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.text = "未登录"

        let stack = UIStackView(arrangedSubviews: [title, emailField, passField, anisetteField, codeField, actionButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func makeLabel(_ s: String, font: UIFont) -> UILabel {
        let l = UILabel()
        l.text = s
        l.font = font
        return l
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
            let url = anisetteField.text ?? ""
            statusLabel.text = "登录中…"
            DispatchQueue.global(qos: .userInitiated).async {
                let r = self.bridge.login(email: email, password: pass, anisetteURL: url.isEmpty ? nil : url)
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
