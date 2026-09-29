// CloakKit Core FFI
// 供 iOS(SwiftUI) 通过 C ABI 调用。内核来自 apple-private-apis 的
//   - omnisette  (Anisette 生成)
//   - icloud_auth (Apple ID SRP/GrandSlam 登录、2FA、应用令牌)
// 本 crate 编译为静态库 libcloakkit_core.a (aarch64-apple-ios)。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Mutex;

use icloud_auth::{anisette::AnisetteData, AppleAccount, LoginState};
use omnisette::AnisetteConfiguration;

pub mod ipautil;
pub mod macho;

// 全局单会话（iOS 安装工具同一时间只登录一个 Apple ID，足够）
struct CkSession {
    runtime: tokio::runtime::Runtime,
    account: AppleAccount,
}

static SESSION: Mutex<Option<CkSession>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);


static EMPTY_C: &[u8] = b"\0";

// ---------- 工具 ----------
fn set_last_error(msg: String) {
    *LAST_ERROR.lock().unwrap() = Some(CString::new(msg).unwrap_or_default());
}

fn clear_last_error() {
    *LAST_ERROR.lock().unwrap() = None;
}

/// 把 icloud_auth 的 LoginState 映射为稳定的 int 状态码
fn login_state_code(state: &LoginState) -> i32 {
    match state {
        LoginState::LoggedIn => 0,
        LoginState::Needs2FAVerification => 1,
        LoginState::NeedsDevice2FA => 2,
        LoginState::NeedsSMS2FA => 3,
        LoginState::NeedsSMS2FAVerification(_) => 4,
        LoginState::NeedsExtraStep(_) => 5,
        LoginState::NeedsLogin => 6,
    }
}

/// 构造 Anisette 配置：优先使用调用方传入的 anisette_url，为空则用默认远程服务器。
/// iLoader 预设服务器均为裸主机名，需补 https://；v3 协议为侧载的标准协议。
fn build_config(anisette_url: Option<&str>) -> AnisetteConfiguration {
    let mut c = AnisetteConfiguration::new();
    if let Some(url) = anisette_url {
        if !url.is_empty() {
            let url = url.trim();
            let full = if url.starts_with("http://") || url.starts_with("https://") {
                url.to_string()
            } else {
                format!("https://{}", url)
            };
            // v3 与 v1 均指向所选服务器（v3 为侧载主协议）
            c = c.set_anisette_url_v3(full.clone()).set_anisette_url(full);
        }
    }
    // v3 需写入 state.plist，给一个沙箱可写目录
    let cfg_dir = std::env::temp_dir().join("cloakkit_anisette");
    let _ = std::fs::create_dir_all(&cfg_dir);
    c = c.set_configuration_path(cfg_dir);
    c
}

fn get_handle() -> Option<std::sync::MutexGuard<'static, Option<CkSession>>> {
    SESSION.lock().ok()
}

// ---------- FFI ----------

/// 版本号（静态字符串指针）
#[no_mangle]
pub extern "C" fn ck_version() -> *const c_char {
    static V: &[u8] = b"1.3.0\0";
    V.as_ptr() as *const c_char
}

/// 最近一次错误信息（静态指针，仅查询）
#[no_mangle]
pub extern "C" fn ck_last_error() -> *const c_char {
    let guard = LAST_ERROR.lock().unwrap();
    match guard.as_ref() {
        Some(s) => s.as_ptr(),
        None => EMPTY_C.as_ptr() as *const c_char,
    }
}

/// 释放由本库分配的字符串
#[no_mangle]
pub extern "C" fn ck_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// 开始 Apple ID 登录（邮箱 + 密码）。
/// 返回：0=已登录，1=需要2FA验证，2=需要设备2FA，3=需要短信2FA，4=需要短信2FA验证，5=额外步骤，6=需要登录，<0=错误
#[no_mangle]
pub extern "C" fn ck_login(
    email: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
) -> i32 {
    clear_last_error();

    let email = unsafe { CStr::from_ptr(email) }.to_string_lossy().into_owned();
    let password = unsafe { CStr::from_ptr(password) }.to_string_lossy().into_owned();
    let url = if anisette_url.is_null() {
        None
    } else {
        Some(unsafe { CStr::from_ptr(anisette_url) }.to_string_lossy().into_owned())
    };

    let config = build_config(url.as_deref());

    let runtime = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            set_last_error(format!("runtime init failed: {e}"));
            return -1;
        }
    };

    let mut account = match runtime.block_on(AppleAccount::new(config)) {
        Ok(a) => a,
        Err(e) => {
            set_last_error(format!("AppleAccount::new failed: {e:?}"));
            return -2;
        }
    };

    let state = match runtime.block_on(account.login_email_pass(&email, &password)) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(format!("login failed: {e:?}"));
            return -3;
        }
    };

    let code = login_state_code(&state);
    *SESSION.lock().unwrap() = Some(CkSession {
        runtime,
        account,
    });
    code
}

/// 校验 2FA / 短信验证码
#[no_mangle]
pub extern "C" fn ck_verify_2fa(code_str: *const c_char) -> i32 {
    clear_last_error();
    let code = unsafe { CStr::from_ptr(code_str) }.to_string_lossy().into_owned();

    let guard = SESSION.lock().unwrap();
    let sess = match guard.as_ref() {
        Some(s) => s,
        None => {
            set_last_error("no active session".into());
            return -4;
        }
    };

    match sess.runtime.block_on(sess.account.verify_2fa(code)) {
        Ok(state) => login_state_code(&state),
        Err(e) => {
            set_last_error(format!("verify_2fa failed: {e:?}"));
            -5
        }
    }
}

/// 申请应用令牌（Xcode / 侧载所需）。输出为一个 malloc 的 C 字符串，需 ck_free_string 释放。
/// 输出 JSON: {"auth_token": "...", "app_tokens_plist": "..."}
#[no_mangle]
pub extern "C" fn ck_get_app_token(
    app_name: *const c_char,
    out: *mut *mut c_char,
) -> i32 {
    clear_last_error();
    let app = unsafe { CStr::from_ptr(app_name) }.to_string_lossy().into_owned();

    let guard = SESSION.lock().unwrap();
    let sess = match guard.as_ref() {
        Some(s) => s,
        None => {
            set_last_error("no active session".into());
            return -4;
        }
    };

    match sess.runtime.block_on(sess.account.get_app_token(&app)) {
        Ok(token) => {
            // 序列化 app_tokens 字典为 plist XML
            let mut buf = Vec::new();
            let plist_ok = plist::to_writer_xml(&mut buf, &token.app_tokens);
            let tokens_str = match plist_ok {
                Ok(_) => String::from_utf8_lossy(&buf).into_owned(),
                Err(_) => String::new(),
            };
            let json = format!(
                r#"{{"auth_token":"{}","app_tokens_plist":"{}"}}"#,
                token.auth_token.replace('\\', "\\\\").replace('"', "\\\""),
                tokens_str.replace('\\', "\\\\").replace('"', "\\\"")
            );
            match CString::new(json) {
                Ok(cs) => {
                    unsafe {
                        *out = cs.into_raw();
                    }
                    0
                }
                Err(e) => {
                    set_last_error(format!("alloc failed: {e}"));
                    -6
                }
            }
        }
        Err(e) => {
            set_last_error(format!("get_app_token failed: {e:?}"));
            -7
        }
    }
}

/// 发送短信 2FA 到指定设备
#[no_mangle]
pub extern "C" fn ck_send_sms(phone_id: u32) -> i32 {
    clear_last_error();
    let guard = SESSION.lock().unwrap();
    let sess = match guard.as_ref() {
        Some(s) => s,
        None => {
            set_last_error("no active session".into());
            return -4;
        }
    };
    match sess.runtime.block_on(sess.account.send_sms_2fa_to_devices(phone_id)) {
        Ok(state) => login_state_code(&state),
        Err(e) => {
            set_last_error(format!("send_sms failed: {e:?}"));
            -8
        }
    }
}

/// 注销/清空会话
#[no_mangle]
pub extern "C" fn ck_logout() -> i32 {
    *SESSION.lock().unwrap() = None;
    clear_last_error();
    0
}

// ---------- v2：IPA / Mach-O / CodeSignature 校验 FFI ----------

/// 探测 IPA 元信息 + 主二进制架构。输出 malloc 字符串（JSON），需 ck_free_string 释放。
/// 返回 0 成功，<0 失败（ck_last_error）。
#[no_mangle]
pub extern "C" fn ck_probe_ipa(ipa_path: *const c_char, out: *mut *mut c_char) -> i32 {
    clear_last_error();
    let path = unsafe { CStr::from_ptr(ipa_path) }.to_string_lossy().into_owned();
    let data = match std::fs::read(&path) {
        Ok(d) => d,
        Err(e) => {
            set_last_error(format!("read {}: {e}", path));
            return -9;
        }
    };
    match ipautil::parse_ipa(&data) {
        Ok(meta) => {
            let json = serde_json::to_string(&serde_json::json!({
                "bundle_id": meta.bundle_id,
                "name": meta.name,
                "version": meta.version,
                "min_os": meta.min_os,
                "platforms": meta.supported_platforms,
                "archs": meta.archs,
            }))
            .unwrap_or_else(|_| "{}".into());
            match CString::new(json) {
                Ok(cs) => {
                    unsafe { *out = cs.into_raw(); }
                    0
                }
                Err(e) => {
                    set_last_error(format!("alloc failed: {e}"));
                    -6
                }
            }
        }
        Err(e) => {
            set_last_error(format!("parse ipa: {e}"));
            -10
        }
    }
}

/// 校验主二进制 Mach-O + CodeSignature（CodeDirectory 定位与 cdHash）。
/// 输出 malloc 字符串（JSON），需 ck_free_string 释放。
#[no_mangle]
pub extern "C" fn ck_verify_binary(ipa_path: *const c_char, out: *mut *mut c_char) -> i32 {
    clear_last_error();
    let path = unsafe { CStr::from_ptr(ipa_path) }.to_string_lossy().into_owned();
    let data = match std::fs::read(&path) {
        Ok(d) => d,
        Err(e) => {
            set_last_error(format!("read {}: {e}", path));
            return -9;
        }
    };
    match ipautil::verify_ipa(&data) {
        Ok((meta, cd_hash)) => {
            let hash_hex = cd_hash
                .map(|h| hex::encode(h))
                .unwrap_or_else(|| "none".into());
            let json = serde_json::to_string(&serde_json::json!({
                "bundle_id": meta.bundle_id,
                "archs": meta.archs,
                "code_directory_sha256": hash_hex,
                "verified": cd_hash.is_some(),
            }))
            .unwrap_or_else(|_| "{}".into());
            match CString::new(json) {
                Ok(cs) => {
                    unsafe { *out = cs.into_raw(); }
                    0
                }
                Err(e) => {
                    set_last_error(format!("alloc failed: {e}"));
                    -6
                }
            }
        }
        Err(e) => {
            set_last_error(format!("verify ipa: {e}"));
            -11
        }
    }
}

// 供 Xcode 中静态库被 Swift 引用时保持符号可见（避免被裁剪）
#[allow(dead_code)]
fn _keep_anisette_data_type(_: AnisetteData) {}
