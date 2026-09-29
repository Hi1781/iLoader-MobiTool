import Foundation

/// 解析 IPA：提取 Info.plist 与架构信息（自包含，无第三方依赖）
struct IPAParser {

    static func parse(at url: URL) throws -> IPAMetadata {
        // 寻找 Payload/*.app/Info.plist
        let entryNames = try listEntries(in: url)
        guard let infoPath = entryNames.first(where: { $0.hasSuffix(".app/Info.plist") }) else {
            throw NSError(domain: "CloakKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 Info.plist，IPA 可能损坏"])
        }
        let infoData = try MiniZip.extractEntry(name: infoPath, from: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw NSError(domain: "CloakKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Info.plist 解析失败"])
        }

        let bundleID = plist["CFBundleIdentifier"] as? String ?? "unknown"
        let name = plist["CFBundleDisplayName"] as? String ?? (plist["CFBundleName"] as? String ?? "unknown")
        let version = plist["CFBundleShortVersionString"] as? String ?? "?"
        let minOS = plist["MinimumOSVersion"] as? String

        // 探测可执行文件架构
        var archs: [String] = []
        if let execName = plist["CFBundleExecutable"] as? String {
            let execPath = infoPath.replacingOccurrences(of: "/Info.plist", with: "/\(execName)")
            if let execData = try? MiniZip.extractEntry(name: execPath, from: url) {
                archs = MiniZip.probeArchitectures(ofExecutable: execData)
            }
        }

        return IPAMetadata(
            bundleID: bundleID,
            name: name,
            version: version,
            minOSVersion: minOS,
            architectures: archs,
            sourceURL: url
        )
    }

    /// 列出 zip 内全部条目名（供定位 .app/Info.plist 与 .app 目录）
    static func listEntries(in url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        guard let eocd = scanEOCD(in: bytes) else {
            throw NSError(domain: "CloakKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "非法 ZIP"])
        }
        let cdOffset = readU32(bytes, eocd + 16)
        let cdCount = readU16(bytes, eocd + 10)
        var cursor = Int(cdOffset)
        var names: [String] = []
        for _ in 0..<cdCount {
            guard cursor + 46 <= bytes.count else { break }
            let nameLen = readU16(bytes, cursor + 28)
            let extraLen = readU16(bytes, cursor + 30)
            let commentLen = readU16(bytes, cursor + 32)
            let nameStart = cursor + 46
            if let name = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8) {
                names.append(name)
            }
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return names
    }

    private static func scanEOCD(in bytes: [UInt8]) -> Int? {
        let n = bytes.count
        let maxScan = min(n, 65557)
        var i = n - maxScan
        while i < n - 3 {
            if bytes[i] == 0x50, bytes[i+1] == 0x4b, bytes[i+2] == 0x05, bytes[i+3] == 0x06 { return i }
            i += 1
        }
        return nil
    }
    private static func readU16(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 1 < b.count else { return 0 }
        return Int(b[o]) | (Int(b[o+1]) << 8)
    }
    private static func readU32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 3 < b.count else { return 0 }
        return Int(b[o]) | (Int(b[o+1]) << 8) | (Int(b[o+2]) << 16) | (Int(b[o+3]) << 24)
    }
}
