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

    // MARK: - v2 校验接口

    struct IPAVerifyResult {
        let bundleID: String
        let archs: [String]
        let codeDirectorySHA256: String
        let verified: Bool
    }

    /// 探测 IPA 元信息 + 架构
    func probeIPA(at url: URL) throws -> [String: String] {
        var out: UnsafeMutablePointer<CChar>? = nil
        let rc = url.path.withCString { ck_probe_ipa($0, &out) }
        guard rc == 0, let ptr = out else {
            throw NSError(domain: "CloakKit", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        defer { ck_free_string(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CloakKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "探测结果解析失败"])
        }
        var flat: [String: String] = [:]
        for (k, v) in obj { flat[k] = "\(v)" }
        return flat
    }

    /// 校验主二进制 Mach-O + CodeDirectory
    func verifyBinary(inIPA url: URL) throws -> IPAVerifyResult {
        var out: UnsafeMutablePointer<CChar>? = nil
        let rc = url.path.withCString { ck_verify_binary($0, &out) }
        guard rc == 0, let ptr = out else {
            throw NSError(domain: "CloakKit", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        defer { ck_free_string(ptr) }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CloakKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "校验结果解析失败"])
        }
        return IPAVerifyResult(
            bundleID: obj["bundle_id"] as? String ?? "",
            archs: (obj["archs"] as? [String]) ?? [],
            codeDirectorySHA256: obj["code_directory_sha256"] as? String ?? "none",
            verified: obj["verified"] as? Bool ?? false
        )
    }

    // MARK: - v2.0 远程设备 / SideStore 式安装

    /// 已配对目标设备的简要信息
    struct RemoteDevice {
        let udid: String
        let hostId: String
        let systemBuid: String
        let wifiMac: String
        var ip: String
    }

    /// 安装进度
    struct InstallProgress {
        let phase: String
        let percent: Int
        let message: String
        let done: Bool
        let error: String?
    }

    @discardableResult
    func importPairing(at url: URL, ip: String) -> Bool {
        url.path.withCString { pPath in
            ip.withCString { pIp in ck_pairing_import(pPath, pIp) == 0 }
        }
    }

    var pairingPresent: Bool { ck_pairing_present() == 1 }

    func pairingInfo() -> RemoteDevice? {
        guard let p = ck_pairing_info() else { return nil }
        defer { ck_free_string(p) }
        guard let dict = jsonObject(String(cString: p)) as? [String: Any] else { return nil }
        return RemoteDevice(
            udid: dict["udid"] as? String ?? "",
            hostId: dict["hostId"] as? String ?? "",
            systemBuid: dict["systemBuid"] as? String ?? "",
            wifiMac: dict["wifiMac"] as? String ?? "",
            ip: dict["ip"] as? String ?? ""
        )
    }

    @discardableResult
    func setDeviceIP(_ ip: String) -> Bool {
        ip.withCString { ck_device_set_ip($0) == 0 }
    }

    func fetchDeviceInfo() throws -> [String: Any] {
        guard let p = ck_device_fetch_info() else {
            throw err()
        }
        defer { ck_free_string(p) }
        return jsonObject(String(cString: p)) as? [String: Any] ?? [:]
    }

    @discardableResult
    func openTunnel() -> Bool { ck_tunnel_open() == 0 }

    func tunnelStatus() -> [String: Any] {
        guard let p = ck_tunnel_status() else { return ["open": false] }
        defer { ck_free_string(p) }
        return jsonObject(String(cString: p)) as? [String: Any] ?? ["open": false]
    }

    func closeTunnel() { ck_tunnel_close() }

    struct RemoteApp {
        let bundleId: String
        let name: String
        let displayName: String
        let version: String
    }

    func listRemoteApps() throws -> [RemoteApp] {
        guard let p = ck_apps_list() else { throw err() }
        defer { ck_free_string(p) }
        let arr = jsonObject(String(cString: p)) as? [[String: Any]] ?? []
        return arr.map {
            RemoteApp(
                bundleId: $0["bundleId"] as? String ?? "",
                name: $0["name"] as? String ?? "",
                displayName: $0["displayName"] as? String ?? "",
                version: $0["version"] as? String ?? ""
            )
        }
    }

    @discardableResult
    func uninstallRemoteApp(_ bundleId: String) -> Bool {
        bundleId.withCString { ck_app_uninstall($0) == 0 }
    }

    /// 开始安装，返回任务 id（>0）
    func startInstall(ipa url: URL) -> Int64 {
        url.path.withCString { ck_install_ipa($0) }
    }

    func installProgress(_ taskId: Int64) -> InstallProgress? {
        guard let p = ck_install_progress(taskId) else { return nil }
        defer { ck_free_string(p) }
        guard let d = jsonObject(String(cString: p)) as? [String: Any] else { return nil }
        return InstallProgress(
            phase: d["phase"] as? String ?? "",
            percent: d["percent"] as? Int ?? 0,
            message: d["message"] as? String ?? "",
            done: d["done"] as? Bool ?? false,
            error: d["error"] as? String
        )
    }

    private func jsonObject(_ s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func err() -> NSError {
        NSError(domain: "CloakKit", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError])
    }
}
