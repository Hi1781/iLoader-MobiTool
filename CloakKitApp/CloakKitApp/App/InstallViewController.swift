import UIKit
import UniformTypeIdentifiers

// 安装：导入 IPA → 解析 → Mach-O/CodeDirectory 校验 → 安装
final class InstallViewController: UIViewController, UIDocumentPickerDelegate {
    private let bridge = FFIBridge.shared
    private let metaLabel = UILabel()
    private let resultLabel = UILabel()
    private let verifyButton = UIButton(type: .system)
    private let installButton = UIButton(type: .system)
    private var currentURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
    }

    private func buildUI() {
        let title = makeLabel("导入并安装 IPA", font: .boldSystemFont(ofSize: 20))
        let importButton = UIButton(type: .system)
        importButton.setTitle("从文件导入 IPA", for: .normal)
        importButton.addTarget(self, action: #selector(pickIPA), for: .touchUpInside)

        metaLabel.numberOfLines = 0
        metaLabel.font = .systemFont(ofSize: 14)
        metaLabel.textColor = .secondaryLabel
        metaLabel.text = "未导入"

        resultLabel.numberOfLines = 0
        resultLabel.font = .systemFont(ofSize: 13)
        resultLabel.textColor = .secondaryLabel

        verifyButton.setTitle("校验二进制（Mach-O / CodeDirectory）", for: .normal)
        verifyButton.addTarget(self, action: #selector(runVerify), for: .touchUpInside)
        verifyButton.isEnabled = false
        installButton.setTitle("签名并安装", for: .normal)
        installButton.addTarget(self, action: #selector(runInstall), for: .touchUpInside)
        installButton.isEnabled = false

        let stack = UIStackView(arrangedSubviews: [title, importButton, metaLabel, verifyButton, installButton, resultLabel])
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
        let l = UILabel(); l.text = s; l.font = font; return l
    }

    @objc private func pickIPA() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "ipa") ?? .data])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        currentURL = url
        do {
            let m = try IPAParser.parse(at: url)
            metaLabel.text = "\(m.name) · \(m.bundleID) · v\(m.version)\n架构: \(m.architectures.joined(separator: ", "))"
            verifyButton.isEnabled = true
            installButton.isEnabled = true
        } catch {
            metaLabel.text = "解析失败：\(error.localizedDescription)"
        }
    }

    @objc private func runVerify() {
        guard let url = currentURL else { return }
        resultLabel.text = "校验中…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let v = try self.bridge.verifyBinary(inIPA: url)
                DispatchQueue.main.async {
                    self.resultLabel.text = "架构: \(v.archs.joined(separator: ", "))\n"
                        + "CodeDirectory SHA-256: \(v.codeDirectorySHA256)\n"
                        + (v.verified ? "签名结构校验通过 ✅" : "未签名（SideStore 签名时生成 CodeDirectory）")
                }
            } catch {
                DispatchQueue.main.async { self.resultLabel.text = "校验失败：\(error.localizedDescription)" }
            }
        }
    }

    @objc private func runInstall() {
        guard let url = currentURL else { return }
        resultLabel.text = "开始安装…"
        DefaultInstallService().install(ipa: url) { res in
            DispatchQueue.main.async {
                switch res {
                case .success: self.resultLabel.text = "安装完成（校验通过）"
                case .failure(let e): self.resultLabel.text = "安装失败：\(e.localizedDescription)"
                }
            }
        }
    }
}
