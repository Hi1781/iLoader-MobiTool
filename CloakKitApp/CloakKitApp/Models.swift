import Foundation

// MARK: - IPA 元信息
struct IPAMetadata {
    let bundleID: String
    let name: String
    let version: String
    let minOSVersion: String?
    let architectures: [String]
    let sourceURL: URL
}

// MARK: - 已安装侧载应用
struct InstalledApp: Identifiable {
    let id: String // bundleID
    let name: String
    let version: String
    let signStatus: SignStatus
    let expiresAt: Date?

    enum SignStatus {
        case valid, expiringSoon, expired, unknown
    }
}

// MARK: - 登录会话状态
enum AuthPhase: Equatable {
    case idle
    case loggingIn
    case needs2FA
    case needsSMS
    case loggedIn
    case failed(String)
}
