import Foundation

struct AnisetteServer: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let displayName: String
}

enum AnisetteServerCatalog {
    private static func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("编译期固定 URL 无效: \(string)")
        }
        return url
    }

    static let official: [AnisetteServer] = [
        // SideInstaller 1.5.1 内置 anisette 目录里的一台。REA 静态字符串证据：
        // Rust 常量区可见 `https://ani.stikstore.app`（紧邻 `panic while revoking
        // certificate`）；而它 Swift 侧带名字的服务器目录第一条是
        // `https://ani.sidestore.io`。这里沿用 SideInstaller 的默认选择。
        // ⚠️ 实测它的 `/v3/client_info` 返回 Xcode 身份
        // `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>`，
        // 会被 Apple 登录边缘直接拒（同 ADI 同请求：Xcode 身份 → 503、akd 身份 → 200）。
        // ⚠️ 但身份**不能**跟着服务器走：逐台实测 SideInstaller 目录里 15 台服务器，
        // 有 8 台返回的都是这个会被拒的 Xcode 身份，而它照样能登录 ⇒ 身份必须由 Seal
        // 自己声明（`AnisetteV3Client.declaredClientInfo`），服务器只提供 `user_agent`。
        // 所以这台可以安全保留为默认：身份不受它影响，provisioning 也照常成功。
        AnisetteServer(
            id: "sideinstaller-default",
            url: makeURL("https://ani.stikstore.app"),
            displayName: "SideInstaller"
        ),
        // SideStore 官方维护的公共 Anisette 服务器列表
        // 来源: https://servers.sidestore.io/servers.json
        // Seal 会按顺序自动尝试，一个挂了自动切下一个，避免单点故障
        AnisetteServer(
            id: "sidestore-io",
            url: makeURL("https://ani.sidestore.io"),
            displayName: "SideStore"
        ),
        AnisetteServer(
            id: "sidestore-app",
            url: makeURL("https://ani.sidestore.app"),
            displayName: "SideStore (.app)"
        ),
        AnisetteServer(
            id: "sidestore-zip",
            url: makeURL("https://ani.sidestore.zip"),
            displayName: "SideStore (.zip)"
        ),
        AnisetteServer(
            id: "sidestore-xyz",
            url: makeURL("https://ani.846969.xyz"),
            displayName: "SideStore (.xyz)"
        ),
        AnisetteServer(
            id: "nythepegasus",
            url: makeURL("https://ani.npeg.us"),
            displayName: "nythepegasus"
        ),
        AnisetteServer(
            id: "we-studio",
            url: makeURL("https://anisette.wedotstud.io"),
            displayName: "WE. Studio"
        ),
        AnisetteServer(
            id: "stex",
            url: makeURL("https://ani.xu30.top"),
            displayName: "SteX"
        ),
        AnisetteServer(
            id: "owoellen",
            url: makeURL("https://ani.owoellen.rocks"),
            displayName: "owoellen"
        ),
        AnisetteServer(
            id: "idh-server",
            url: makeURL("https://ani.idevicehacked.com"),
            displayName: "iDH Server"
        ),
        AnisetteServer(
            id: "neoarz",
            url: makeURL("https://ani.neoarz.com"),
            displayName: "neoarz"
        ),
        AnisetteServer(
            id: "pythonplayer123",
            url: makeURL("https://ani3server.fly.dev"),
            displayName: "pythonplayer123"
        ),
        AnisetteServer(
            id: "jayden",
            url: makeURL("https://ani.jaydenha.uk"),
            displayName: "Jayden's Server"
        ),
        AnisetteServer(
            id: "crystall1nedev",
            url: makeURL("https://anisette.crystall1ne.dev"),
            displayName: "crystall1nedev"
        ),
        // isideload 上游源码的默认值，返回 Windows/iTunes 身份
        // `<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>`。
        // 实测该身份同样被 Apple 登录边缘放行（→ 200），所以它作为兜底是可用的；
        // 放在列表末尾只是为了保留 SideInstaller / SideStore 的优先顺序。
        AnisetteServer(
            id: "jkcoxson",
            url: makeURL("https://ani.jkcoxson.com"),
            displayName: "jkcoxson"
        )
    ]

    static func prioritized(selectedID: String?) -> [AnisetteServer] {
        guard let selectedID,
              let selected = official.first(where: { $0.id == selectedID }) else {
            return official
        }

        return [selected] + official.filter { $0.id != selected.id }
    }
}
