import UIKit

/// Anisette 服务器：iLoader 默认列表（8 个预设）+ 自定义输入。
/// 服务器均为 v3 协议（裸主机名，登录时内核自动补 https://）。
struct AnisetteServer {
    /// iLoader 原始默认列表（[主机, 标签]）
    static let presets: [(host: String, label: String)] = [
        ("ani.sidestore.io", "SideStore (.io)"),
        ("ani.stikstore.app", "StikStore"),
        ("ani.sidestore.app", "SideStore (.app)"),
        ("ani.sidestore.zip", "SideStore (.zip)"),
        ("ani.846969.xyz", "SideStore (.xyz)"),
        ("ani.neoarz.xyz", "neoarz"),
        ("ani.xu30.top", "SteX"),
        ("anisette.wedotstud.io", "WE. Studio"),
    ]

    static let defaultHost = "ani.sidestore.io"
    private static let key = "cloakkit_anisette_server"

    static var selected: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultHost }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(v.isEmpty ? defaultHost : v, forKey: key)
        }
    }

    static func label(for host: String) -> String {
        presets.first(where: { $0.host == host })?.label ?? host
    }
}
