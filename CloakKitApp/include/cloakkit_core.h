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

#ifdef __cplusplus
}
#endif

#endif /* CLOAKKIT_CORE_H */
