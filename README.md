# CloakKit (v2.0.0)

iOS（iPhone/iPad）本地 IPA 侧载安装器，复用 **SideStore** 的无线调试 + JIT 授权通道，
在手机端直接完成 Apple ID 登录、Anisette、IPA 解析、签名与安装，替代电脑端 iLoader。

## v2 新增（本版本）
- 适配 **iPhone + iPad**（`TARGETED_DEVICE_FAMILY=1,2`，自适应 TabView 布局）。
- 新增 **IPA/Mach-O/CodeSignature 校验内核**（Rust `macho.rs` + `ipautil.rs`，已通过本机对真实 IPA 的端到端测试）：
  - 提取 Info.plist、主二进制架构；
  - Mach-O 头一致性 + 加载命令越界守卫；
  - `LC_CODE_SIGNATURE` 定位、CodeDirectory 结构校验 + 计算其 SHA-256（cdHash）。
- 新增 FFI：`ck_probe_ipa` / `ck_verify_binary`，Swift 侧 `InstallView` 导入后自动校验并在界面显示 CodeDirectory 状态。

## 架构

```
┌────────────────────────────────────────────────────────────┐
│  CloakKitApp (SwiftUI)                                       │
│   账号 / 安装 / 应用 / 设置  ← 界面                          │
│   FFIBridge ──▶ libcloakkit_core.a (C FFI)                  │
└────────────────────────────────────────────────────────────┘
                │  C ABI
┌────────────────────────────────────────────────────────────┐
│  cloakkit-core (Rust 静态库)  —— 来自 SideStore 官方底层库    │
│   omnisette    : Anisette 生成                               │
│   icloud_auth  : Apple ID SRP/GrandSlam 登录、2FA、应用令牌    │
└────────────────────────────────────────────────────────────┘
                │  无线调试 socket (复用 SideStore 配对)
┌────────────────────────────────────────────────────────────┐
│  libimobiledevice (installd)  → 系统安装 IPA                  │
│  SideStore 配对文件 / 开发者模式 / JIT 通道                   │
└────────────────────────────────────────────────────────────┘
```

- 内核（Anisette + 登录/2FA）：来源 `SideStore/apple-private-apis`，已剥离为独立 Rust crate。
- 界面：SwiftUI，本仓库内完整源码。
- 真实安装：走 SideStore 无线调试通道 + libimobiledevice（见下「已知边界」）。

## 目录

```
CloakKit/
├── cloakkit-core/          Rust FFI 内核（→ libcloakkit_core.a）
│   └── src/lib.rs          C ABI：ck_login / ck_verify_2fa / ck_get_app_token ...
├── apple-private-apis/     SideStore 官方底层库（已 vendored，含 omnisette/icloud-auth）
├── iloader/                iLoader 源码（参考其业务逻辑）
├── sidestore/              SideStore 源码（参考无线调试/配对/JIT）
├── CloakKitApp/            iOS SwiftUI 工程
│   ├── CloakKitApp/        Swift 源码（FFIBridge/MiniZip/IPAParser/Views...）
│   ├── include/cloakkit_core.h
│   └── Info.plist
├── project.yml             XcodeGen 工程描述
├── build.sh                macOS 一键构建脚本
└── README.md
```

## macOS 构建（产出 IPA）

> 本仓库的 Linux 侧已把**内核 Rust 源码、FFI、SwiftUI、构建脚本全部就绪并通过主机编译验证**。
> 但 iOS 静态库（ring/rustls 加密栈）与最终 IPA 强依赖 Apple 工具链，**必须在 macOS 上执行**：

```bash
# 1. 前置（macOS）
brew install xcodegen
rustup target add aarch64-apple-ios

# 2. 一键构建
./build.sh
# 产出：build/CloakKit-unsigned.ipa

# 3. 用 SideStore 导入该 IPA，以你的 Apple ID 签名安装
```

## 已知边界（诚实说明）

1. **本环境（Linux）无法产出 .ipa**：ring（rustls 加密栈）交叉编译需 Apple clang/SDK，
   最终链接需 Xcode。Linux 侧只验证了 FFI 源码正确性（主机目标编译通过）。
2. **证书申请层**（apple-dev-apis 的 `XcodeSession::with`）在官方仓库里是 `todo!()` 桩，
   需要你在 macOS 上补齐（参考 iLoader 的 provision 逻辑）。
3. **真实 installd 安装**：`IPAInstallService.swift` 提供了通道协议与校验逻辑，
   实际调用需链接 libimobiledevice 并走 SideStore 无线调试 socket（见文件内 TODO）。
4. 免费 Apple ID：单 ID 最多 3 个侧载应用、7 天过期需续签。

## 许可证与合规

- `apple-private-apis` 为 MPL-2.0；iLoader 为 MIT。复用自用/研究，**勿打包分发**。
- Anisette / GrandSlam 属 Apple 私有协议，苹果可能随时封堵；仅限自己设备、自己开发的 IPA。
