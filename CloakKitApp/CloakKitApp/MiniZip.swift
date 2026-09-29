import Foundation

/// 极简 ZIP 中央目录解析器。
/// 仅用于从 IPA 中提取指定条目（如 Info.plist / 二进制架构探测），
/// 支持 Store 与 Deflate 两种压缩方式，自包含、无第三方依赖。
struct MiniZip {

    enum ZipError: Error {
        case badData, entryNotFound
    }

    /// 读取 zip 文件中名为 `name` 的条目原始数据
    static func extractEntry(name: String, from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return try extractEntry(name: name, from: data)
    }

    static func extractEntry(name: String, from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        // 从文件末尾向前扫描 EOCD（End of Central Directory）签名 0x06054b50
        guard let eocd = findEOCD(in: bytes) else { throw ZipError.badData }
        let cdOffset = readU32(bytes, eocd + 16)
        let cdCount = readU16(bytes, eocd + 10)

        var cursor = Int(cdOffset)
        for _ in 0..<cdCount {
            // 中央目录条目签名 0x02014b50
            guard cursor + 46 <= bytes.count, bytes[cursor] == 0x50,
                  bytes[cursor + 1] == 0x4b, bytes[cursor + 2] == 0x01,
                  bytes[cursor + 3] == 0x02 else { throw ZipError.badData }

            let method = readU16(bytes, cursor + 10)
            let compSize = readU32(bytes, cursor + 20)
            let uncompSize = readU32(bytes, cursor + 24)
            let nameLen = readU16(bytes, cursor + 28)
            let extraLen = readU16(bytes, cursor + 30)
            let commentLen = readU16(bytes, cursor + 32)
            let localHeaderOffset = readU32(bytes, cursor + 42)

            let nameStart = cursor + 46
            guard nameStart + nameLen <= bytes.count else { throw ZipError.badData }
            let entryName = String(bytes: bytes[nameStart..<(nameStart + Int(nameLen))], encoding: .utf8) ?? ""

            let localPos = Int(localHeaderOffset)
            // 本地文件头：签名 0x04034b50，文件名长度位于 +26，额外字段长度 +28
            let dataStart = localPos + 30 + Int(readU16(bytes, localPos + 26)) + Int(readU16(bytes, localPos + 28))
            let dataEnd = dataStart + Int(compSize)
            guard dataEnd <= bytes.count else { throw ZipError.badData }

            if entryName == name {
                let raw = Data(bytes[dataStart..<dataEnd])
                if method == 0 { // Store
                    return raw
                } else if method == 8 { // Deflate
                    return try inflate(raw, expectedSize: Int(uncompSize))
                } else {
                    throw ZipError.badData
                }
            }
            cursor = nameStart + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }
        throw ZipError.entryNotFound
    }

    /// 探测解压后的 Mach-O 支持架构（arm64 / arm64e / armv7 / x86_64）
    static func probeArchitectures(ofExecutable data: Data) -> [String] {
        var archs: [String] = []
        guard data.count >= 8 else { return archs }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let big: UInt32 = 0xcafebabe   // FAT (大端)
        let fat: UInt32 = 0xcafebabe   // FAT
        let mach64: UInt32 = 0xfeedfacf
        let mach32: UInt32 = 0xfeedface
        let littleMagic = magic.byteSwapped

        if magic == fat || littleMagic == fat || magic == big {
            // FAT 通用二进制
            let nfat = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.byteSwapped
            for i in 0..<min(Int(nfat), 64) {
                let off = 8 + i * 20
                guard data.count >= off + 4 else { break }
                let cputype = data.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self) }.byteSwapped
                archs.append(cpuName(Int32(bitPattern: cputype)))
            }
        } else if magic == mach64 || littleMagic == mach64 {
            archs.append("arm64")
        } else if magic == mach32 || littleMagic == mach32 {
            archs.append("arm")
        }
        return Array(Set(archs))
    }

    private static func cpuName(_ type: Int32) -> String {
        switch type {
        case 0x0100000c: return "arm64"
        case 0x0100000d: return "arm64e"
        case 0x01000007: return "x86_64"
        case 12: return "arm"
        case 7: return "i386"
        default: return "cpu(\(type))"
        }
    }

    // MARK: - Deflate (纯 Swift, raw deflate 无 zlib 头)
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        // 使用 Compressor 无法直接解 raw deflate；这里解析 raw deflate 位流
        var out = Data(capacity: expectedSize)
        var reader = BitReader(bytes: [UInt8](data))

        var codeLengths = Array(repeating: 0, count: 288)
        codeLengths[0...143] = Array(repeating: 8, count: 144)
        codeLengths[144...255] = Array(repeating: 9, count: 112)
        codeLengths[256...279] = Array(repeating: 7, count: 24)
        codeLengths[280...287] = Array(repeating: 8, count: 8)
        let litTable = HuffmanTable(codeLengths)

        var distLengths = Array(repeating: 5, count: 32)
        let distTable = HuffmanTable(distLengths)

        loop: while true {
            guard let bfinal = try? reader.readBits(1), bfinal != nil else { throw ZipError.badData }
            guard let btype = try reader.readBits(2) else { throw ZipError.badData }
            switch btype {
            case 0:
                // 未压缩块
                reader.alignToByte()
                guard let len = try reader.readBits(16), let nlen = try reader.readBits(16) else { throw ZipError.badData }
                guard len == (~nlen & 0xffff) else { throw ZipError.badData }
                if let bytes = try reader.readBytes(Int(len)) { out.append(contentsOf: bytes) }
            case 1:
                // 固定 Huffman
                var lt = litTable, dt = distTable
                inflateBlock(&reader, &out, &lt, &dt)
            case 2:
                // 动态 Huffman
                guard let hlitRaw = try reader.readBits(5), let hdistRaw = try reader.readBits(5),
                      let hclenRaw = try reader.readBits(4) else { throw ZipError.badData }
                let hlit = Int(hlitRaw) + 257
                let hdist = Int(hdistRaw) + 1
                let hclen = Int(hclenRaw) + 4
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var clenLens = Array(repeating: 0, count: 19)
                for i in 0..<hclen {
                    if let v = try reader.readBits(3) { clenLens[order[i]] = Int(v) }
                }
                let clenTable = HuffmanTable(clenLens)
                var lens = [Int]()
                while lens.count < hlit + hdist {
                    guard let sym = try reader.readHuff(&clenTable) else { throw ZipError.badData }
                    if sym < 16 { lens.append(sym) }
                    else if sym == 16 {
                        guard let prev = lens.last else { throw ZipError.badData }
                        guard let rep = try reader.readBits(2) else { throw ZipError.badData }
                        lens.append(contentsOf: Array(repeating: prev, count: Int(rep) + 3))
                    } else if sym == 17 {
                        guard let rep = try reader.readBits(3) else { throw ZipError.badData }
                        lens.append(contentsOf: Array(repeating: 0, count: Int(rep) + 3))
                    } else {
                        guard let rep = try reader.readBits(7) else { throw ZipError.badData }
                        lens.append(contentsOf: Array(repeating: 0, count: Int(rep) + 11))
                    }
                }
                var lt2 = HuffmanTable(Array(lens[0..<hlit]))
                var dt2 = HuffmanTable(Array(lens[hlit..<hlit + hdist]))
                inflateBlock(&reader, &out, &lt2, &dt2)
            default:
                throw ZipError.badData
            }
            if bfinal == 1 { break loop }
        }
        return out
    }

    private static func inflateBlock(_ reader: inout BitReader, _ out: inout Data,
                                     _ lt: inout HuffmanTable, _ dt: inout HuffmanTable) {
        while true {
            guard let sym = try? reader.readHuff(&lt) else { return }
            if sym < 256 { out.append(UInt8(sym)) }
            else if sym == 256 { return }
            else {
                // 长度符号
                let lenBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
                let lenExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
                let idx = sym - 257
                var len = lenBase[idx]
                if let e = try? reader.readBits(lenExtra[idx]) { len += Int(e) }
                guard let dSym = try? reader.readHuff(&dt) else { return }
                let distBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
                let distExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
                var dist = distBase[dSym]
                if let e = try? reader.readBits(distExtra[dSym]) { dist += Int(e) }
                let start = out.count - dist
                for _ in 0..<len {
                    if start < 0 || start >= out.count { return }
                    out.append(out[out.index(out.startIndex, offsetBy: start)])
                }
            }
        }
    }

    private static func findEOCD(in bytes: [UInt8]) -> Int? {
        let n = bytes.count
        let maxScan = min(n, 65557)
        var i = n - maxScan
        while i < n - 3 {
            if bytes[i] == 0x50, bytes[i+1] == 0x4b, bytes[i+2] == 0x05, bytes[i+3] == 0x06 {
                return i
            }
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

    // MARK: - Huffman 解码表
    struct HuffmanTable {
        private var codes: [UInt16: Int] = [:]
        private var lens: [Int: Int] = [:] // 长度 -> 码表起点
        init(_ lengths: [Int]) {
            // 构造 canonical 码
            var blCount = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 { blCount[l] += 1 }
            var nextCode = [Int](repeating: 0, count: 16)
            var code = 0
            for bits in 1..<16 {
                code = (code + blCount[bits - 1]) << 1
                nextCode[bits] = code
            }
            for (sym, l) in lengths.enumerated() where l > 0 {
                let c = nextCode[l]
                nextCode[l] += 1
                codes[UInt16(c)] = sym
                lens[l, default: 0] += 1
            }
        }
        mutating func symbol(_ reader: inout BitReader) -> Int? {
            var code: UInt16 = 0
            for bits in 1...15 {
                guard let b = try? reader.readBits(1) else { return nil }
                code = (code << 1) | UInt16(b!)
                if let sym = codes[code] { return sym }
            }
            return nil
        }
    }

    struct BitReader {
        let bytes: [UInt8]
        var bitPos = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func readBits(_ n: Int) throws -> UInt32? {
            var result: UInt32 = 0
            for i in 0..<n {
                let byte = bitPos >> 3
                guard byte < bytes.count else { return nil }
                let bit = bytes[byte] >> (bitPos & 7) & 1
                result |= UInt32(bit) << UInt32(i)
                bitPos += 1
            }
            return result
        }
        mutating func readHuff(_ table: inout HuffmanTable) throws -> Int? {
            table.symbol(&self)
        }
        mutating func readBytes(_ n: Int) throws -> [UInt8]? {
            alignToByte()
            let byte = bitPos >> 3
            guard byte + n <= bytes.count else { return nil }
            let slice = Array(bytes[byte..<(byte + n)])
            bitPos += n * 8
            return slice
        }
        mutating func alignToByte() {
            bitPos = (bitPos + 7) & ~7
        }
    }
}
