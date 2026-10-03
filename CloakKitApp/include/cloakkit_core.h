// CloakKit Core C 头文件 — 供 Swift/Objective-C 桥接
#ifndef CLOAKKIT_CORE_H
#define CLOAKKIT_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// 版本号（静态字符串，勿释放）
const char* ck_version(void);

// 最近一次错误信息（静态字符串，勿释放）
const char* ck_last_error(void);

// 释放由本库 ck_get_app_token 分配的字符串
void ck_free_string(char* ptr);

// 登录状态码
#define CK_LOGIN_OK              0
#define CK_LOGIN_NEEDS_2FA       1
#define CK_LOGIN_NEEDS_DEVICE_2FA 2
#define CK_LOGIN_NEEDS_SMS_2FA   3
#define CK_LOGIN_NEEDS_SMS_2FA_VERIFY 4
#define CK_LOGIN_NEEDS_EXTRA_STEP 5
#define CK_LOGIN_NEEDS_LOGIN     6

// 开始 Apple ID 登录。anisette_url 可传 NULL 使用默认远程服务器。
// 返回：>=0 为登录状态码，<0 为错误（见 ck_last_error）
int ck_login(const char* email, const char* password, const char* anisette_url);

// 校验 2FA / 短信验证码
int ck_verify_2fa(const char* code);

// 申请应用令牌。out 指向分配的字符串（调用方用 ck_free_string 释放）。
// 输出 JSON: {"auth_token":"...","app_tokens_plist":"..."}
int ck_get_app_token(const char* app_name, char** out);

// 向指定设备发送短信 2FA
int ck_send_sms(unsigned int phone_id);

// 注销会话
int ck_logout(void);

// ===== v2：IPA / Mach-O / CodeSignature 校验 =====
// 探测 IPA 元信息 + 主二进制架构。out 为 malloc 字符串(JSON)，调用方用 ck_free_string 释放。
int ck_probe_ipa(const char* ipa_path, char** out);
// 校验主二进制 Mach-O + CodeDirectory（输出 code_directory_sha256）。
int ck_verify_binary(const char* ipa_path, char** out);

// ===== v2.0：SideStore 式远程安装（RemotePairing / CoreDeviceProxy software tunnel）=====
// 导入 .mobiledevicepairing 配对记录并设置目标设备局域网 IP。0 成功。
int ck_pairing_import(const char* path, const char* ip);
// 是否已导入配对（1/0）。
int ck_pairing_present(void);
// 配对元信息 JSON（{udid,hostId,systemBuid,wifiMac,ip}），NULL 表示未导入。
char* ck_pairing_info(void);
// 更新目标设备 IP（手动输入/发现后）。0 成功。
int ck_device_set_ip(const char* ip);
// 经无线 Lockdown 读取设备信息 JSON（{name,udid,productType,osVersion,model}），NULL 失败。
char* ck_device_fetch_info(void);

// 打开 CoreDeviceProxy software tunnel（无需 Network Extension entitlement）。0 成功。
int ck_tunnel_open(void);
// 隧道状态 JSON（{open,clientIp,serverIp,rsdPort}）。
char* ck_tunnel_status(void);
// 关闭隧道。
int ck_tunnel_close(void);

// 经隧道列出目标设备已装应用，JSON 数组（[{bundleId,name,displayName,version,path}]）。
char* ck_apps_list(void);
// 经隧道卸载指定 bundle id。0 成功。
int ck_app_uninstall(const char* bundle_id);

// 上传并安装本地 IPA。返回任务 id（>0，用 ck_install_progress 轮询）；<=0 启动失败。
long long ck_install_ipa(const char* ipa_path);
// 查询安装进度 JSON（{id,phase,percent,message,done,error}）。
char* ck_install_progress(long long task_id);

#ifdef __cplusplus
}
#endif

#endif /* CLOAKKIT_CORE_H */
