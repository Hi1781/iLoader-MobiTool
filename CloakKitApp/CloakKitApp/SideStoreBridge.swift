import Foundation

/// 读取本机 SideStore 生成的配对文件（pairing.plist）与无线调试信息。
/// SideStore 依赖无线调试 + JIT 链路，本工具复用其已建立的授权通道。
struct SideStoreBridge {

    struct PairingInfo {
        let hostID: String
        let systemBUID: String
        let wifiMac: String?
    }

    /// SideStore 常见存储路径（App 沙盒内）
    private static let searchPaths: [String] = [
        "pairing.plist",
        "Library/Application Support/SideStore/pairing.plist",
        "Documents/pairing.plist",
        "Library/SideStore/pairing.plist"
    ]

    /// 在本机 App 沙盒与 SideStore 共享目录中查找 pairing.plist
    static func findPairing() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        // 优先尝试 SideStore 通过 app group / 共享容器写入的位置
        for p in searchPaths {
            let u = docs.appendingPathComponent(p)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 读取并解析 pairing.plist
    static func loadPairing() throws -> PairingInfo {
        guard let url = findPairing() else {
            throw NSError(domain: "CloakKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 SideStore 配对文件，请先在 SideStore 完成首次配对"])
        }
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "CloakKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "配对文件解析失败"])
        }
        return PairingInfo(
            hostID: plist["HostID"] as? String ?? "",
            systemBUID: plist["SystemBUID"] as? String ?? "",
            wifiMac: plist["WiFiMACAddress"] as? String
        )
    }

    /// 检查开发者模式 / 无线调试是否就绪（iOS 17+ 需手动开启）
    static func environmentCheck() -> [String] {
        var warnings: [String] = []
        // 开发者模式：iOS 16+ 可通过 Settings 开启；无公开 API 探测，给出引导提示
        if #available(iOS 16.0, *) {
            warnings.append("请确认已开启「设置 → 开发者模式」")
        }
        warnings.append("请确认已开启「设置 → 无线调试」并信任本机")
        return warnings
    }
}
