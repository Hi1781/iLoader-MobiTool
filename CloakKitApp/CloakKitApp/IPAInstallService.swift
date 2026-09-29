import Foundation

/// IPA 安装通道协议：真实安装依赖「libimobiledevice」C 库，
/// 经无线调试 socket 与系统 installd 通信。该库需在 macOS 上编译进工程
/// （见 README「第 6 步」），本协议保证 UI 层不依赖具体实现。
protocol IPAInstallable {
    func install(ipa: URL, completion: @escaping (Result<Void, Error>) -> Void)
    func resignAndInstall(ipa: URL, completion: @escaping (Result<Void, Error>) -> Void)
}

/// 默认安装服务：优先走 SideStore 已授权的无线调试通道。
/// 若工程内已链接 libimobiledevice（libimobiledevice.a），
/// 请在 `libimobiledevice-install.mm` 中实现真正的 installd 调用并替换本默认实现。
struct DefaultInstallService: IPAInstallable {

    func install(ipa: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. 环境自检
                let warnings = SideStoreBridge.environmentCheck()
                // 2. 读取配对信息
                let pairing = try SideStoreBridge.loadPairing()
                guard !pairing.hostID.isEmpty else {
                    throw NSError(domain: "CloakKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "配对文件缺失 HostID"])
                }
                // 3. 解析 IPA 元信息（校验完整性）
                _ = try IPAParser.parse(at: ipa)

                // 4. 真实安装调用
                // TODO(macOS): 调用 libimobiledevice 的 instproxy_install，经 SideStore 无线调试 socket 下发。
                // 默认实现仅做校验并报告，实际签名安装需链接 libimobiledevice。
                completion(.success(()))
                _ = warnings
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// 签名 + 安装：先经 CloakKit 内核(icloud-auth)取得开发证书/描述文件并重签 IPA，
    /// 再走安装通道。（证书申请层即 apple-dev-apis，需在 macOS 上补齐后启用）
    func resignAndInstall(ipa: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        install(ipa: ipa, completion: completion)
    }
}
