//! IPA 解析（Rust 实现，可在 Linux 上直接对真实 IPA 做端到端测试）。
//! 提取 Info.plist、主二进制架构、并在内存中完成 Mach-O 结构校验。

#[derive(Debug, Clone)]
pub struct IpaMeta {
    pub bundle_id: String,
    pub name: String,
    pub version: String,
    pub min_os: Option<String>,
    pub supported_platforms: Vec<String>,
    pub exec_path: String,
    pub archs: Vec<String>,
}

/// 从 zip 字节流读取指定条目
type IpaZip<'a> = zip::ZipArchive<std::io::Cursor<&'a [u8]>>;

fn read_entry(zip: &mut IpaZip, name: &str) -> Result<Vec<u8>, String> {
    let f = zip.by_name(name).map_err(|e| format!("missing {name}: {e}"))?;
    let mut buf = Vec::new();
    let mut f = f;
    std::io::Read::read_to_end(&mut f, &mut buf).map_err(|e| format!("read {name}: {e}"))?;
    Ok(buf)
}

pub fn parse_ipa(data: &[u8]) -> Result<IpaMeta, String> {
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(data))
        .map_err(|e| format!("open zip: {e}"))?;

    // 定位 Payload/*.app/Info.plist
    let names: Vec<String> = zip
        .file_names()
        .map(|s| s.to_string())
        .collect();
    let info_path = names
        .iter()
        .find(|n| n.ends_with(".app/Info.plist"))
        .ok_or("no Info.plist in IPA")?
        .clone();

    let info_bytes = read_entry(&mut zip, &info_path)?;
    let plist: plist::Value = plist::from_bytes(&info_bytes).map_err(|e| format!("plist: {e}"))?;
    let dict = plist
        .as_dictionary()
        .ok_or("Info.plist root not dictionary")?;

    let s = |k: &str| -> Option<String> {
        dict.get(k).and_then(|v| v.as_string().map(|x| x.to_string()))
    };
    let sa = |k: &str| -> Vec<String> {
        dict.get(k)
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_string().map(|y| y.to_string()))
                    .collect()
            })
            .unwrap_or_default()
    };

    let exec = s("CFBundleExecutable").unwrap_or_else(|| "App".to_string());
    let exec_path = info_path.replace("/Info.plist", &format!("/{exec}"));

    let mut archs = Vec::new();
    if let Ok(exec_bytes) = read_entry(&mut zip, &exec_path) {
        if let Ok(info) = crate::macho::parse_header(&exec_bytes) {
            archs.push(info.arch);
        }
    }

    Ok(IpaMeta {
        bundle_id: s("CFBundleIdentifier").unwrap_or_else(|| "unknown".into()),
        name: s("CFBundleDisplayName")
            .or_else(|| s("CFBundleName"))
            .unwrap_or_else(|| "unknown".into()),
        version: s("CFBundleShortVersionString").unwrap_or_else(|| "?".into()),
        min_os: s("MinimumOSVersion"),
        supported_platforms: sa("CFBundleSupportedPlatforms"),
        exec_path,
        archs,
    })
}

/// 校验 IPA：解析元信息 + 主二进制 Mach-O 结构级校验（含 CodeSignature 定位）
pub fn verify_ipa(data: &[u8]) -> Result<(IpaMeta, Option<[u8; 32]>), String> {
    let meta = parse_ipa(data)?;
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(data)).map_err(|e| e.to_string())?;
    let exec_bytes = read_entry(&mut zip, &meta.exec_path)?;
    let cd_hash = crate::macho::verify_code_signature(&exec_bytes).ok();
    Ok((meta, cd_hash))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_ipa() -> Vec<u8> {
        std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/testdata/reference-unsigned.ipa"
        ))
        .unwrap()
    }

    #[test]
    fn parses_reference_ipa_metadata() {
        let meta = parse_ipa(&test_ipa()).unwrap();
        assert_eq!(meta.bundle_id, "com.clipboard.history");
        assert!(meta.archs.contains(&"arm64".to_string()));
        assert_eq!(meta.min_os.as_deref(), Some("16.0"));
        assert!(meta.supported_platforms.contains(&"iPhoneOS".to_string()));
        assert_eq!(meta.exec_path, "Payload/ClipboardHistory.app/ClipboardHistory");
    }

    #[test]
    fn corrupt_ipa_fails() {
        let bad = b"not a zip file at all".to_vec();
        assert!(parse_ipa(&bad).is_err());
    }

    #[test]
    fn verify_unsiged_reports_no_cd() {
        let (meta, cd) = verify_ipa(&test_ipa()).unwrap();
        assert_eq!(meta.bundle_id, "com.clipboard.history");
        // raw-unsigned → 无 CodeDirectory
        assert!(cd.is_none());
    }
}

