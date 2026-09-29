import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            AccountView().tabItem { Label("账号", systemImage: "person.circle") }
            InstallView().tabItem { Label("安装", systemImage: "arrow.down.circle") }
            AppListView().tabItem { Label("应用", systemImage: "square.grid.2x2") }
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

// MARK: - 账号
struct AccountView: View {
    @EnvironmentObject var auth: AuthModel

    var body: some View {
        NavigationView {
            Form {
                Section("登录") {
                    TextField("Apple ID 邮箱", text: $auth.email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $auth.password)
                    TextField("Anisette 服务器（可选）", text: $auth.anisetteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("登录") { auth.startLogin() }
                        .disabled(auth.phase == .loggingIn)
                }
                Section("状态") {
                    switch auth.phase {
                    case .idle: Label("未登录", systemImage: "circle").foregroundColor(.gray)
                    case .loggingIn: Label("登录中…", systemImage: "hourglass")
                    case .needs2FA:
                        VStack(alignment: .leading) {
                            Text("请输入验证码")
                            TextField("6 位验证码", text: $auth.smsCode).keyboardType(.numberPad)
                            Button("验证") { auth.submitCode(auth.smsCode) }
                        }
                    case .needsSMS: Label("需要短信验证", systemImage: "message")
                    case .loggedIn: Label("已登录", systemImage: "checkmark.circle").foregroundColor(.green)
                    case .failed(let msg):
                        VStack(alignment: .leading) {
                            Label("失败", systemImage: "xmark.circle").foregroundColor(.red)
                            Text(msg).font(.footnote).foregroundColor(.red)
                        }
                    }
                }
                if auth.phase == .loggedIn {
                    Button("注销") { auth.logout() }.foregroundColor(.red)
                }
            }
            .navigationTitle("CloakKit · 账号")
        }
    }
}

// MARK: - 安装
struct InstallView: View {
    @State private var importing = false
    @State private var meta: IPAMetadata?
    @State private var installing = false
    @State private var resultText = ""

    var body: some View {
        NavigationView {
            Form {
                Section("导入 IPA") {
                    Button { importing = true } label: { Label("从文件导入 IPA", systemImage: "folder") }
                    if let meta {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meta.name).font(.headline)
                            Text("\(meta.bundleID) · v\(meta.version)").font(.footnote).foregroundColor(.secondary)
                            Text("架构: \(meta.architectures.joined(separator: ", "))").font(.footnote)
                        }
                    }
                }
                if meta != nil {
                    Section {
                        Button { doInstall() } label: { Label("签名并安装", systemImage: "arrow.down.circle.fill") }
                            .disabled(installing)
                        if installing { ProgressView().frame(maxWidth: .infinity) }
                    }
                }
                if !resultText.isEmpty {
                    Section("结果") { Text(resultText).font(.footnote) }
                }
            }
            .navigationTitle("CloakKit · 安装")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ipa], allowsMultipleSelection: false) { res in
                if case .success(let urls) = res, let url = urls.first {
                    if let m = try? IPAParser.parse(at: url) {
                        meta = m
                        resultText = "IPA 解析成功"
                    } else {
                        resultText = "IPA 解析失败：文件可能损坏"
                    }
                }
            }
        }
    }

    private func doInstall() {
        guard let meta else { return }
        installing = true
        resultText = "开始安装…"
        let service = DefaultInstallService()
        service.install(ipa: meta.sourceURL) { res in
            DispatchQueue.main.async {
                installing = false
                switch res {
                case .success: resultText = "安装完成（校验通过；真实 installd 安装需链接 libimobiledevice，见 README 第 6 步）"
                case .failure(let e): resultText = "安装失败：\(e.localizedDescription)"
                }
            }
        }
    }
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
}

// MARK: - 应用列表
struct AppListView: View {
    @EnvironmentObject var store: AppListModel

    var body: some View {
        NavigationView {
            List(store.installed) { app in
                VStack(alignment: .leading) {
                    Text(app.name).font(.headline)
                    Text("\(app.id) · v\(app.version)").font(.footnote).foregroundColor(.secondary)
                    Text("签名：\(signText(app.signStatus))").font(.caption)
                }
            }
            .overlay {
                if store.installed.isEmpty {
                    VStack { Image(systemName: "square.grid.2x2"); Text("暂无侧载应用") }
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("CloakKit · 应用")
            .onAppear { store.refresh() }
        }
    }
    private func signText(_ s: InstalledApp.SignStatus) -> String {
        switch s { case .valid: return "有效"; case .expiringSoon: return "即将到期"; case .expired: return "已过期"; case .unknown: return "未知" }
    }
}

// MARK: - 设置
struct SettingsView: View {
    @State private var showEnv = false
    @State private var envWarnings: [String] = []

    var body: some View {
        NavigationView {
            Form {
                Section("CloakKit") {
                    LabeledContent("内核版本", value: FFIBridge.shared.version)
                    Button("环境自检") {
                        envWarnings = SideStoreBridge.environmentCheck()
                        showEnv = true
                    }
                }
                if !envWarnings.isEmpty {
                    Section("检查结果") {
                        ForEach(envWarnings, id: \.self) { Text("⚠️ \($0)") }
                    }
                }
                Section("说明") {
                    Text("本工具复用 SideStore 的无线调试 + JIT 授权通道，实现 iPhone/iPad 端本地 IPA 签名与安装。请确认已安装 SideStore 并完成首次配对。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("CloakKit · 设置")
        }
    }
}
