import SwiftUI

@main
struct CloakKitApp: App {
    @StateObject private var auth = AuthModel()
    @StateObject private var appStore = AppListModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(appStore)
        }
    }
}

// MARK: - 认证状态模型（调用 FFI 内核）
final class AuthModel: ObservableObject {
    @Published var phase: AuthPhase = .idle
    @Published var email = ""
    @Published var password = ""
    @Published var smsCode = ""
    @Published var anisetteURL = ""   // 留空使用默认远程 anisette 服务器

    private let bridge = FFIBridge.shared

    func startLogin() {
        guard !email.isEmpty, !password.isEmpty else { return }
        phase = .loggingIn
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.bridge.login(email: self.email, password: self.password, anisetteURL: self.anisetteURL.isEmpty ? nil : self.anisetteURL)
            DispatchQueue.main.async {
                switch result {
                case .ok: self.phase = .loggedIn
                case .needs2FA, .needsDevice2FA, .needsSMS2FAVerify: self.phase = .needs2FA
                case .needsSMS2FA: self.phase = .needsSMS
                case .failed(let msg): self.phase = .failed(msg)
                default: self.phase = .failed("登录状态码 \(result.rawValue)")
                }
            }
        }
    }

    func submitCode(_ code: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.bridge.verify2FA(code: code)
            DispatchQueue.main.async {
                if result == .ok { self.phase = .loggedIn }
                else { self.phase = .needs2FA }
            }
        }
    }

    func logout() {
        bridge.logout()
        phase = .idle
    }
}

// MARK: - 已安装应用列表模型
final class AppListModel: ObservableObject {
    @Published var installed: [InstalledApp] = []

    func refresh() {
        // 从系统查询侧载应用（iOS 无公开枚举 API，此处由 SideStore 数据/安装记录填充）
        // 真实实现：读取 SideStore 的 installed apps 记录。
        installed = []
    }
}
