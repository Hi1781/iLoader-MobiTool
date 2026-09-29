import Foundation

/// 封装 cloakkit_core 静态库的 C FFI，供 SwiftUI 调用。
/// 头文件：include/cloakkit_core.h
final class FFIBridge {

    enum LoginCode: Int {
        case ok = 0
        case needs2FA = 1
        case needsDevice2FA = 2
        case needsSMS2FA = 3
        case needsSMS2FAVerify = 4
        case needsExtraStep = 5
        case needsLogin = 6
    }

    struct AppTokenResult {
        let authToken: String
        let appTokensPlist: String
    }

    static let shared = FFIBridge()

    /// 版本号
    var version: String {
        guard let p = ck_version() else { return "?" }
        return String(cString: p)
    }

    /// 最近一次错误
    var lastError: String {
        guard let p = ck_last_error(), String(cString: p) != "" else {
            return "无错误"
        }
        return String(cString: p)
    }

    /// 开始登录
    @discardableResult
    func login(email: String, password: String, anisetteURL: String?) -> LoginCode {
        let code = email.withCString { e in
            password.withCString { pw in
                if let url = anisetteURL, !url.isEmpty {
                    return url.withCString { ck_login(e, pw, $0) }
                } else {
                    return ck_login(e, pw, nil)
                }
            }
        }
        return LoginCode(rawValue: Int(code)) ?? .needsLogin
    }

    /// 校验 2FA 验证码
    @discardableResult
    func verify2FA(code: String) -> LoginCode {
        let raw = code.withCString { ck_verify_2fa($0) }
        return LoginCode(rawValue: Int(raw)) ?? .needsLogin
    }

    /// 申请应用令牌
    func getAppToken(appName: String) throws -> AppTokenResult {
        var outPtr: UnsafeMutablePointer<CChar>? = nil
        let rc = appName.withCString { ck_get_app_token($0, &outPtr) }
        guard rc == 0, let ptr = outPtr else {
            throw NSError(domain: "CloakKit", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        defer { ck_free_string(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw NSError(domain: "CloakKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "令牌解析失败"])
        }
        return AppTokenResult(
            authToken: obj["auth_token"] ?? "",
            appTokensPlist: obj["app_tokens_plist"] ?? ""
        )
    }

    /// 发送短信 2FA
    @discardableResult
    func sendSMS(phoneID: UInt32) -> LoginCode {
        LoginCode(rawValue: Int(ck_send_sms(phoneID))) ?? .needsLogin
    }

    /// 注销
    func logout() {
        ck_logout()
    }
}
