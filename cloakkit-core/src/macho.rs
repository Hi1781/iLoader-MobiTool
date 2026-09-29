//! Mach-O 与 CodeSignature 校验。
//! 在 Linux 上可直接对 arm64 iOS 二进制做结构级校验：
//!   - 头部 magic / cputype / filetype 一致性
//!   - 加载命令区间合法（无越界）
//!   - LC_CODE_SIGNATURE 定位、CodeDirectory 结构校验 + 计算其 cdHash(sha256)
//! 完整的「CodeDirectory 与 Mach-O 代码一致」重签名校验由 macOS `codesign` 完成
//! （见 build.sh / README），此处提供可复现的结构级验证。

/// Mach-O 64 小端 magic
const MH_MAGIC_64: u32 = 0xfeed_facf;
/// FAT magic（大端）
const FAT_MAGIC: u32 = 0xcafe_babe;
/// LC_CODE_SIGNATURE
const LC_CODE_SIGNATURE: u32 = 0x1d;
/// 超级块 magic 'CSB'（大端）
const CS_SUPERBLOB_MAGIC: u32 = 0xfade_0cc0;
/// CodeDirectory magic
const CSMAGIC_CODEDIRECTORY: u32 = 0xfade_0c02;

pub struct MachOInfo {
    pub magic: u32,
    pub cputype: i32,
    pub filetype: u32,
    pub ncmds: u32,
    pub arch: String,
}

impl MachOInfo {
    fn arch_name(cputype: i32) -> String {
        match cputype {
            0x0100_000c => "arm64".into(),
            0x0100_000d => "arm64e".into(),
            0x0100_0007 => "x86_64".into(),
            0x0000_000c => "arm".into(),
            0x0000_0007 => "i386".into(),
            _ => format!("cpu(0x{:x})", cputype),
        }
    }
}

/// 解析 64 位 Mach-O 头部
pub fn parse_header(bin: &[u8]) -> Result<MachOInfo, String> {
    if bin.len() < 4 {
        return Err("binary too short".into());
    }
    let magic = u32::from_le_bytes(bin[0..4].try_into().unwrap());
    if magic == FAT_MAGIC || magic == FAT_MAGIC.swap_bytes() {
        // FAT：读 nfat 并取第一个 cpu（FAT 头 28 字节）
        if bin.len() < 8 + 20 {
            return Err("bad FAT header".into());
        }
        let nfat = u32::from_be_bytes(bin[4..8].try_into().unwrap());
        if nfat == 0 {
            return Err("FAT has no slices".into());
        }
        let ct = i32::from_be_bytes(bin[8..12].try_into().unwrap());
        return Ok(MachOInfo {
            magic,
            cputype: ct,
            filetype: 0,
            ncmds: 0,
            arch: MachOInfo::arch_name(ct),
        });
    }
    if bin.len() < 32 {
        return Err("binary too short".into());
    }
    if magic != MH_MAGIC_64 {
        // 也接受 32 位或其它字节序，仅作探测
        if u32::from_be_bytes(bin[0..4].try_into().unwrap()) == MH_MAGIC_64 {
            return Err("64-bit Mach-O in big-endian; unhandled".into());
        }
        return Err(format!("not Mach-O 64: magic=0x{:08x}", magic));
    }
    let cputype = i32::from_le_bytes(bin[4..8].try_into().unwrap());
    let filetype = u32::from_le_bytes(bin[12..16].try_into().unwrap());
    let ncmds = u32::from_le_bytes(bin[16..20].try_into().unwrap());
    let sizeofcmds = u32::from_le_bytes(bin[20..24].try_into().unwrap());
    // 越界守卫：加载命令区域必须落在文件内
    if (20 + sizeofcmds) as usize > bin.len() {
        return Err("load commands region out of bounds".into());
    }
    Ok(MachOInfo {
        magic,
        cputype,
        filetype,
        ncmds,
        arch: MachOInfo::arch_name(cputype),
    })
}

/// 定位并校验 CodeSignature：返回 CodeDirectory 的 cdHash(sha256)。
/// 失败说明签名结构缺失或越界。
pub fn verify_code_signature(bin: &[u8]) -> Result<[u8; 32], String> {
    let info = parse_header(bin)?;
    if info.magic != MH_MAGIC_64 {
        return Err("not a thin 64-bit Mach-O; cannot verify signature".into());
    }
    // 遍历 load commands（每条 8 字节头 + 数据）
    let mut off: usize = 32;
    let mut cs_off: Option<(u32, u32)> = None;
    for _ in 0..info.ncmds {
        if off + 8 > bin.len() {
            return Err("load command header out of bounds".into());
        }
        let cmd = u32::from_le_bytes(bin[off..off + 4].try_into().unwrap());
        let cmdsize = u32::from_le_bytes(bin[off + 4..off + 8].try_into().unwrap()) as usize;
        if cmdsize < 8 || off + cmdsize > bin.len() {
            return Err(format!("load command size invalid at 0x{:x}", off));
        }
        if cmd == LC_CODE_SIGNATURE {
            // 结构: cmd,cmdsize,dataoff,datasize
            let dataoff = u32::from_le_bytes(bin[off + 8..off + 12].try_into().unwrap());
            let datasize = u32::from_le_bytes(bin[off + 12..off + 16].try_into().unwrap());
            cs_off = Some((dataoff, datasize));
        }
        off += cmdsize;
    }
    let (dataoff, datasize) = cs_off.ok_or("LC_CODE_SIGNATURE not found (unsigned)")?;
    let start = dataoff as usize;
    let end = (dataoff + datasize) as usize;
    if end > bin.len() {
        return Err("code signature region out of bounds".into());
    }
    let sig = &bin[start..end];
    if sig.len() < 8 {
        return Err("superblob too short".into());
    }
    let sb_magic = u32::from_be_bytes(sig[0..4].try_into().unwrap());
    if sb_magic != CS_SUPERBLOB_MAGIC {
        return Err(format!("bad superblob magic 0x{:08x}", sb_magic));
    }
    let count = u32::from_be_bytes(sig[4..8].try_into().unwrap());
    for i in 0..count as usize {
        let b = 8 + i * 8;
        if b + 8 > sig.len() {
            return Err("superblob index out of bounds".into());
        }
        let _btype = u32::from_be_bytes(sig[b..b + 4].try_into().unwrap());
        let boffset = u32::from_be_bytes(sig[b + 4..b + 8].try_into().unwrap()) as usize;
        if boffset + 12 > sig.len() {
            return Err("blob offset out of bounds".into());
        }
        let cd_magic = u32::from_be_bytes(sig[boffset..boffset + 4].try_into().unwrap());
        if cd_magic == CSMAGIC_CODEDIRECTORY {
            // CodeDirectory：magic(4)+length(4)+version(4)+flags(4)+hashOffset(4)+identOffset(4)+...
            let length = u32::from_be_bytes(sig[boffset + 4..boffset + 8].try_into().unwrap()) as usize;
            let ident_offset =
                u32::from_be_bytes(sig[boffset + 20..boffset + 24].try_into().unwrap()) as usize;
            let hash_offset =
                u32::from_be_bytes(sig[boffset + 16..boffset + 20].try_into().unwrap()) as usize;
            let cd_end = boffset + length;
            if cd_end > sig.len() {
                return Err("CodeDirectory length out of bounds".into());
            }
            if ident_offset >= length || hash_offset >= length {
                return Err("CodeDirectory offsets invalid".into());
            }
            // 计算 CodeDirectory 的 cdHash = SHA256(cd blob)
            let cd_blob = &sig[boffset..cd_end];
            let mut hasher = Sha256::new();
            hasher.update(cd_blob);
            return Ok(hasher.finalize().into());
        }
    }
    Err("no CodeDirectory blob found".into())
}

// 使用纯 Rust sha2（已在依赖中）
use sha2::{Digest, Sha256};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_garbage_header() {
        let bin = vec![0u8; 64];
        assert!(parse_header(&bin).is_err());
    }

    #[test]
    fn rejects_truncated() {
        let bin = vec![0u8; 4];
        assert!(parse_header(&bin).is_err());
    }

    #[test]
    fn detects_fat_arm64() {
        // 手工构造 FAT 头（大端）：magic, nfat=1, cputype=arm64
        let mut bin = Vec::new();
        bin.extend_from_slice(&0xcafebabeu32.to_be_bytes());
        bin.extend_from_slice(&1u32.to_be_bytes());
        bin.extend_from_slice(&0x0100000cu32.to_be_bytes());
        bin.extend_from_slice(&0u32.to_be_bytes()); // cpusubtype
        bin.extend_from_slice(&0u32.to_be_bytes()); // offset
        bin.extend_from_slice(&100u32.to_be_bytes()); // size
        bin.extend_from_slice(&12u32.to_be_bytes()); // align
        let info = parse_header(&bin).unwrap();
        assert_eq!(info.arch, "arm64");
    }

    #[test]
    fn unsigned_binary_reports_missing_signature() {
        // 参考 IPA 是 raw-unsigned：主二进制无 LC_CODE_SIGNATURE
        let data = std::fs::read(
            concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/reference-unsigned.ipa"),
        )
        .unwrap();
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(&data)).unwrap();
        let names: Vec<String> = zip.file_names().map(|s| s.to_string()).collect();
        let _info = names.iter().find(|n| n.ends_with(".app/Info.plist")).unwrap().clone();
        let exec = "Payload/ClipboardHistory.app/ClipboardHistory";
        let mut f = zip.by_name(exec).unwrap();
        let mut buf = Vec::new();
        std::io::Read::read_to_end(&mut f, &mut buf).unwrap();
        assert_eq!(parse_header(&buf).unwrap().arch, "arm64");
        // 未签名 → verify_code_signature 应返回 Err（"not found" 或结构错误）
        assert!(verify_code_signature(&buf).is_err());
    }
}

