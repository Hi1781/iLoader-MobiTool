//! 远程设备模块（SideStore 式无线安装）
//!
//! v2.0 第一阶段：
//!  - 导入/解析 `.mobiledevicepairing`（idevice::pairing_file::PairingFile）
//!  - 经 TcpProvider 直连设备（同局域网 IP）+ LockdownClient 读取设备信息
//!
//! 后续阶段：CoreDeviceProxy software tunnel（jktcp 用户态栈）→ AFC 上传
//! → installation_proxy 安装/列表/卸载。
//!
//! 所有 FFI 走 JSON 输入/输出，错误经 `crate::set_last_error` 暴露。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Mutex;

use idevice::pairing_file::PairingFile;
use idevice::provider::TcpProvider;
use idevice::services::core_device_proxy::CoreDeviceProxy;
use idevice::services::installation_proxy::InstallationProxyClient;
use idevice::services::lockdown::LockdownClient;
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::IdeviceService;

/// 已导入的配对记录（全局单份，与「一次操作一台目标设备」模型匹配）
struct PairedDevice {
    pairing: PairingFile,
    ip: std::net::IpAddr,
    label: String,
}

/// 已建立的 software tunnel（jktcp 用户态 TCP 栈，无需 Network Extension entitlement）。
/// Adapter 转成 thread-safe AdapterHandle 保存，可多次复用连 RSD 服务。
struct Tunnel {
    handle: AdapterHandle,
    rsd_port: u16,
    client_ip: String,
    server_ip: String,
}

static PAIRED: Mutex<Option<PairedDevice>> = Mutex::new(None);
static TUNNEL: Mutex<Option<Tunnel>> = Mutex::new(None);

unsafe fn cstr_to_string(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok().map(|s| s.to_string())
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// 导入 .mobiledevicepairing 并预填设备 IP（IP 可随后用 ck_device_set_ip 覆盖）。
/// 成功返回 0；失败返回非 0，错误信息写入 last_error。
#[no_mangle]
pub extern "C" fn ck_pairing_import(path: *const c_char, ip: *const c_char) -> i32 {
    let path = match unsafe { cstr_to_string(path) } {
        Some(p) => p,
        None => {
            crate::set_last_error("配对文件路径为空".into());
            return -1;
        }
    };
    let pairing = match PairingFile::read_from_file(&path) {
        Ok(p) => p,
        Err(e) => {
            crate::set_last_error(format!("配对文件解析失败：{e}"));
            return -2;
        }
    };

    // IP：优先用入参；否则尝试用配对记录中的 wifi mac 无法得到 IP，默认占位 0.0.0.0
    // （iOS 上需由用户在 UI 填写/扫描得到真实局域网 IP）。
    let ip_str = unsafe { cstr_to_string(ip) }.unwrap_or_default();
    let ip: std::net::IpAddr = match ip_str.parse() {
        Ok(v) => v,
        Err(_) => {
            crate::set_last_error("设备 IP 无效，请输入目标设备的局域网地址".into());
            return -3;
        }
    };

    let label = pairing
        .udid
        .clone()
        .unwrap_or_else(|| "cloakkit".to_string());
    *PAIRED.lock().unwrap() = Some(PairedDevice {
        pairing,
        ip,
        label,
    });
    0
}

/// 是否已导入配对记录。
#[no_mangle]
pub extern "C" fn ck_pairing_present() -> i32 {
    if PAIRED.lock().unwrap().is_some() {
        1
    } else {
        0
    }
}

/// 返回已导入配对记录的元信息 JSON：{udid,hostId,systemBuid,wifiMac,ip}
#[no_mangle]
pub extern "C" fn ck_pairing_info() -> *mut c_char {
    let guard = PAIRED.lock().unwrap();
    let p = match guard.as_ref() {
        Some(p) => p,
        None => return std::ptr::null_mut(),
    };
    let json = serde_json::json!({
        "udid": p.pairing.udid,
        "hostId": p.pairing.host_id,
        "systemBuid": p.pairing.system_buid,
        "wifiMac": p.pairing.wifi_mac_address,
        "ip": p.ip.to_string(),
    })
    .to_string();
    drop(guard);
    into_c(json)
}

/// 更新目标设备 IP（Bonjour 发现或手动输入后调用）。
#[no_mangle]
pub extern "C" fn ck_device_set_ip(ip: *const c_char) -> i32 {
    let ip = match unsafe { cstr_to_string(ip) }.and_then(|s| s.parse().ok()) {
        Some(ip) => ip,
        None => {
            crate::set_last_error("IP 无效".into());
            return -1;
        }
    };
    let mut guard = PAIRED.lock().unwrap();
    match guard.as_mut() {
        Some(p) => {
            p.ip = ip;
            0
        }
        None => {
            crate::set_last_error("尚未导入配对文件".into());
            -2
        }
    }
}

/// 经无线 TCP 连接 Lockdown，读取目标设备基础信息。
/// 需在独立线程调用（内部构建临时 tokio runtime）。
/// 返回 JSON {name,udid,productType,osVersion,model}；失败返回 null（查 last_error）。
#[no_mangle]
pub extern "C" fn ck_device_fetch_info() -> *mut c_char {
    let (pairing, ip, label) = {
        let guard = PAIRED.lock().unwrap();
        match guard.as_ref() {
            Some(p) => (p.pairing.clone(), p.ip, p.label.clone()),
            None => {
                crate::set_last_error("尚未导入配对文件".into());
                return std::ptr::null_mut();
            }
        }
    };

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            crate::set_last_error(format!("运行时初始化失败：{e}"));
            return std::ptr::null_mut();
        }
    };

    let result = rt.block_on(async move {
        let provider = TcpProvider {
            addr: ip,
            scope_id: None,
            pairing_file: pairing,
            label,
        };
        let mut lockdown = LockdownClient::connect(&provider).await?;

        async fn gv(
            l: &mut LockdownClient,
            key: &str,
        ) -> Result<Option<String>, idevice::IdeviceError> {
            match l.get_value(Some(key), None).await {
                Ok(v) => Ok(v.as_string().map(|s| s.to_string())),
                Err(_) => Ok(None),
            }
        }
        let name = gv(&mut lockdown, "DeviceName").await?.unwrap_or_default();
        let udid = gv(&mut lockdown, "UniqueDeviceID")
            .await?
            .unwrap_or_default();
        let product_type = gv(&mut lockdown, "ProductType")
            .await?
            .unwrap_or_default();
        let os_version = gv(&mut lockdown, "ProductVersion")
            .await?
            .unwrap_or_default();
        let model = gv(&mut lockdown, "ModelNumber").await?.unwrap_or_default();

        Ok::<_, idevice::IdeviceError>(
            serde_json::json!({
                "name": name,
                "udid": udid,
                "productType": product_type,
                "osVersion": os_version,
                "model": model,
            })
            .to_string(),
        )
    });

    match result {
        Ok(json) => into_c(json),
        Err(e) => {
            crate::set_last_error(format!("连接设备失败：{e}（请确认同 Wi-Fi、已信任、开发者模式与无线调试已开启）"));
            std::ptr::null_mut()
        }
    }
}

// ================= v2.0 第二阶段：software tunnel + installation_proxy =================

fn with_rt<F>(f: F) -> *mut c_char
where
    F: FnOnce(tokio::runtime::Runtime) -> Result<String, String>,
{
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            crate::set_last_error(format!("运行时初始化失败：{e}"));
            return std::ptr::null_mut();
        }
    };
    match f(rt) {
        Ok(json) => into_c(json),
        Err(e) => {
            crate::set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// 打开 CoreDeviceProxy software tunnel（iOS17+ 无线调试通道）。
/// 成功返回 0；TUNNEL 全局保活。
#[no_mangle]
pub extern "C" fn ck_tunnel_open() -> i32 {
    let (pairing, ip, label) = {
        let guard = PAIRED.lock().unwrap();
        match guard.as_ref() {
            Some(p) => (p.pairing.clone(), p.ip, p.label.clone()),
            None => {
                crate::set_last_error("尚未导入配对文件".into());
                return -1;
            }
        }
    };

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            crate::set_last_error(format!("运行时初始化失败：{e}"));
            return -2;
        }
    };

    let res = rt.block_on(async move {
        let provider = TcpProvider {
            addr: ip,
            scope_id: None,
            pairing_file: pairing,
            label,
        };
        // CoreDeviceProxy::connect 经 trusted lockdown 启动服务并做 CDTunnel 握手
        let proxy = CoreDeviceProxy::connect(&provider).await?;
        let info = proxy.tunnel_info().clone();
        let rsd_port = info.server_rsd_port;
        let client_ip = info.client_address.clone();
        let server_ip = info.server_address.clone();
        let adapter = proxy.create_software_tunnel()?;
        // Adapter 消费为 thread-safe handle 以便多次复用
        Ok::<_, idevice::IdeviceError>(Tunnel {
            handle: adapter.to_async_handle(),
            rsd_port,
            client_ip,
            server_ip,
        })
    });

    match res {
        Ok(t) => {
            *TUNNEL.lock().unwrap() = Some(t);
            0
        }
        Err(e) => {
            crate::set_last_error(format!(
                "建立远程隧道失败：{e}（iOS17+ 需开启开发者模式与无线调试，并确认设备可达）"
            ));
            -3
        }
    }
}

/// 隧道状态 JSON {open,clientIp,serverIp,rsdPort}
#[no_mangle]
pub extern "C" fn ck_tunnel_status() -> *mut c_char {
    let g = TUNNEL.lock().unwrap();
    let json = match g.as_ref() {
        Some(t) => serde_json::json!({
            "open": true,
            "clientIp": t.client_ip,
            "serverIp": t.server_ip,
            "rsdPort": t.rsd_port,
        }),
        None => serde_json::json!({ "open": false }),
    }
    .to_string();
    into_c(json)
}

#[no_mangle]
pub extern "C" fn ck_tunnel_close() -> i32 {
    *TUNNEL.lock().unwrap() = None;
    0
}

/// 经隧道 RSD 连 installation_proxy，列出已安装应用。
/// 返回 JSON 数组 [{bundleId,name,path,version}]
#[no_mangle]
pub extern "C" fn ck_apps_list() -> *mut c_char {
    with_rt(|rt| {
        rt.block_on(async {
            // AdapterHandle 内部为 mpsc，Clone 即用；取出后立即放锁，避免跨 await 持锁。
            let (rsd_port, mut handle) = {
                let g = TUNNEL.lock().unwrap();
                let t = g.as_ref().ok_or_else(|| "隧道未建立".to_string())?;
                (t.rsd_port, t.handle.clone())
            };

            let stream = handle
                .connect(rsd_port)
                .await
                .map_err(|e| format!("连接 RSD 失败：{e}"))?;
            let mut handshake = RsdHandshake::new(Box::new(stream))
                .await
                .map_err(|e| format!("RSD 握手失败：{e}"))?;

            let mut proxy: InstallationProxyClient = handshake
                .connect(&mut handle)
                .await
                .map_err(|e| format!("无法连接 installation_proxy：{e}"))?;

            let apps = proxy
                .get_apps(Some("User"), None)
                .await
                .map_err(|e| format!("读取应用列表失败：{e}"))?;

            let mut list = Vec::new();
            for (bundle_id, val) in apps {
                let d = match val.as_dictionary() {
                    Some(d) => d,
                    None => continue,
                };
                let get = |k: &str| {
                    d.get(k)
                        .and_then(|v| v.as_string())
                        .map(|s| s.to_string())
                        .unwrap_or_default()
                };
                list.push(serde_json::json!({
                    "bundleId": bundle_id,
                    "name": get("CFBundleName"),
                    "displayName": get("CFBundleDisplayName"),
                    "version": get("CFBundleShortVersionString"),
                    "path": get("Path"),
                }));
            }
            Ok(serde_json::Value::Array(list).to_string())
        })
    })
}

/// 经隧道卸载指定 bundle id。
#[no_mangle]
pub extern "C" fn ck_app_uninstall(bundle_id: *const c_char) -> i32 {
    let bid = match unsafe { cstr_to_string(bundle_id) } {
        Some(s) if !s.is_empty() => s,
        _ => {
            crate::set_last_error("bundle id 为空".into());
            return -1;
        }
    };

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            crate::set_last_error(format!("运行时初始化失败：{e}"));
            return -2;
        }
    };

    let res = rt.block_on(async move {
        let (rsd_port, mut handle) = {
            let g = TUNNEL.lock().unwrap();
            let t = g.as_ref().ok_or_else(|| "隧道未建立".to_string())?;
            (t.rsd_port, t.handle.clone())
        };
        let stream = handle
            .connect(rsd_port)
            .await
            .map_err(|e| format!("连接 RSD 失败：{e}"))?;
        let mut handshake = RsdHandshake::new(Box::new(stream))
            .await
            .map_err(|e| format!("RSD 握手失败：{e}"))?;
        let mut proxy: InstallationProxyClient = handshake
            .connect(&mut handle)
            .await
            .map_err(|e| format!("无法连接 installation_proxy：{e}"))?;
        proxy
            .uninstall(&bid, None)
            .await
            .map_err(|e| format!("卸载失败：{e}"))?;
        Ok::<(), String>(())
    });

    match res {
        Ok(()) => 0,
        Err(e) => {
            crate::set_last_error(e);
            -3
        }
    }
}

// ================= v2.0 第三阶段：上传 IPA + installation_proxy 安装 =================

use std::sync::atomic::{AtomicI64, Ordering};
use idevice::services::house_arrest::HouseArrestClient;

/// 安装任务进度（全局按任务 id 存，FFI 轮询）。
static INSTALL_PROGRESS: Mutex<Option<InstallProgress>> = Mutex::new(None);
static INSTALL_TASK_ID: AtomicI64 = AtomicI64::new(0);

struct InstallProgress {
    id: i64,
    phase: String,
    percent: u64,
    message: String,
    done: bool,
    error: Option<String>,
}

/// 安装本地 IPA 到目标设备（经 software tunnel）。
/// 流程：RSD → house_arrest(vend installation_proxy 容器) 得到 AFC →
///       上传 IPA 到容器 → installation_proxy.install(PackagePath=文件名)。
/// 返回任务 id（>0）；进度用 ck_install_progress(id) 轮询。返回 <=0 表示启动失败。
#[no_mangle]
pub extern "C" fn ck_install_ipa(ipa_path: *const c_char) -> i64 {
    let path = match unsafe { cstr_to_string(ipa_path) } {
        Some(p) => p,
        None => {
            crate::set_last_error("IPA 路径为空".into());
            return -1;
        }
    };
    if !std::path::Path::new(&path).exists() {
        crate::set_last_error("IPA 文件不存在".into());
        return -2;
    }

    let id = INSTALL_TASK_ID.fetch_add(1, Ordering::SeqCst) + 1;
    *INSTALL_PROGRESS.lock().unwrap() = Some(InstallProgress {
        id,
        phase: "queued".into(),
        percent: 0,
        message: "排队中".into(),
        done: false,
        error: None,
    });

    // 隧道句柄在后台线程使用
    let (rsd_port, handle) = {
        let g = TUNNEL.lock().unwrap();
        match g.as_ref() {
            Some(t) => (t.rsd_port, t.handle.clone()),
            None => {
                crate::set_last_error("隧道未建立".into());
                return -3;
            }
        }
    };

    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                mark_install_error(id, format!("运行时初始化失败：{e}"));
                return;
            }
        };
        rt.block_on(async move {
            if let Err(e) =
                install_via_tunnel(id, handle, rsd_port, path).await
            {
                mark_install_error(id, e);
            } else {
                let mut g = INSTALL_PROGRESS.lock().unwrap();
                if let Some(p) = g.as_mut() {
                    p.phase = "complete".to_string();
                    p.percent = 100;
                    p.message = "安装完成".into();
                    p.done = true;
                }
            }
        });
    });

    id
}

fn mark_install_error(id: i64, e: String) {
    crate::set_last_error(e.clone());
    let mut g = INSTALL_PROGRESS.lock().unwrap();
    if let Some(p) = g.as_mut() {
        if p.id == id {
            p.phase = "error".to_string();
            p.message = e.clone();
            p.done = true;
            p.error = Some(e);
        }
    }
}

fn set_progress(id: i64, phase: &str, percent: u64, message: &str) {
    let mut g = INSTALL_PROGRESS.lock().unwrap();
    if let Some(p) = g.as_mut() {
        if p.id == id {
            p.phase = phase.to_string();
            p.percent = percent;
            p.message = message.to_string();
        }
    }
}

async fn install_via_tunnel(
    id: i64,
    mut handle: AdapterHandle,
    rsd_port: u16,
    ipa_path: String,
) -> Result<(), String> {
    use idevice::services::afc::opcode::AfcFopenMode;
    use tokio::io::AsyncReadExt;

    set_progress(id, "connect", 2, "连接远程服务…");
    let rsd_stream = handle
        .connect(rsd_port)
        .await
        .map_err(|e| format!("连接 RSD 失败：{e}"))?;
    let mut handshake = RsdHandshake::new(Box::new(rsd_stream))
        .await
        .map_err(|e| format!("RSD 握手失败：{e}"))?;

    // 1) house_arrest 拿 installation_proxy 的可写容器（AFC）
    set_progress(id, "house_arrest", 5, "获取安装容器…");
    let mut house: HouseArrestClient = handshake
        .connect(&mut handle)
        .await
        .map_err(|e| format!("连接 house_arrest 失败：{e}"))?;
    let container_name = std::path::Path::new(&ipa_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("package.ipa")
        .to_string();
    let mut afc = house
        .vend_container("com.apple.mobile.installation_proxy")
        .await
        .map_err(|e| format!("获取安装容器失败（设备可能不允许远程安装）：{e}"))?;

    // 2) 上传 IPA（分块写，0..80%）
    set_progress(id, "upload", 8, "上传安装包…");
    let total = std::fs::metadata(&ipa_path).map(|m| m.len()).unwrap_or(1);
    let mut file = tokio::fs::File::open(&ipa_path)
        .await
        .map_err(|e| format!("打开本地 IPA 失败：{e}"))?;

    let remote_path = container_name.clone();
    let mut fd = afc
        .open(&remote_path, AfcFopenMode::Wr)
        .await
        .map_err(|e| format!("创建设备端文件失败：{e}"))?;

    let mut buf = vec![0u8; 1024 * 256]; // 256KB
    let mut sent: u64 = 0;
    loop {
        let n = file
            .read(&mut buf)
            .await
            .map_err(|e| format!("读取 IPA 失败：{e}"))?;
        if n == 0 {
            break;
        }
        fd.write_entire(&buf[..n])
            .await
            .map_err(|e| format!("上传写入失败：{e}"))?;
        sent += n as u64;
        let pct = 8 + ((sent as f64 / total as f64) * 72.0) as u64;
        set_progress(id, "upload", pct.min(80), "上传安装包…");
    }
    fd.close().await.map_err(|_| "关闭远端文件失败".to_string())?;

    // 3) 连 installation_proxy 触发安装（80..100%）
    set_progress(id, "install", 82, "正在安装…");
    // house_arrest 连接占用后，另起一次 RSD 握手拿 installation_proxy
    let rsd_stream2 = handle
        .connect(rsd_port)
        .await
        .map_err(|e| format!("二次连接 RSD 失败：{e}"))?;
    let mut hs2 = RsdHandshake::new(Box::new(rsd_stream2))
        .await
        .map_err(|e| format!("RSD 二次握手失败：{e}"))?;
    let mut proxy: InstallationProxyClient = hs2
        .connect(&mut handle)
        .await
        .map_err(|e| format!("无法连接 installation_proxy：{e}"))?;

    proxy
        .install(&remote_path, None)
        .await
        .map_err(|e| format!("安装失败：{e}"))?;
    Ok(())
}

/// 查询安装进度 JSON {id,phase,percent,message,done,error}
#[no_mangle]
pub extern "C" fn ck_install_progress(task_id: i64) -> *mut c_char {
    let g = INSTALL_PROGRESS.lock().unwrap();
    let json = match g.as_ref() {
        Some(p) if p.id == task_id => serde_json::json!({
            "id": p.id,
            "phase": p.phase,
            "percent": p.percent,
            "message": p.message,
            "done": p.done,
            "error": p.error,
        }),
        _ => serde_json::json!({ "id": task_id, "found": false }),
    }
    .to_string();
    drop(g);
    into_c(json)
}
