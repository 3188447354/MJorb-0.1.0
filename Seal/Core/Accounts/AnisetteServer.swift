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
        // SideInstaller 1.5.1 的 RemoteV3 默认服务。REA 静态字符串证据：
        // `DEFAULT_ANISETTE_V3_URL = "https://ani.stikstore.app"`（该字符串
        // 紧邻 `vendor/isideload/src/anisette/remote_v3/mod.rs:175` 的 panic 位置）。
        // ⚠️ 它的 `/v3/client_info` 返回的是 Xcode 身份
        // `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>`，
        // 而 Apple 登录边缘会直接拒掉声明自己是 Xcode 的客户端（实测同 ADI 同请求下
        // Xcode 身份 → 503、akd 身份 → 200）。该身份由 `AnisetteV3Client.acceptedClientInfo`
        // 在身份层替换成可用的 macOS/akd 身份，因此这个服务器可以保留为默认。
        // ⚠️ 身份**不能**依赖服务器：三台公共服务器实测返回三种不同身份
        //（stikstore → Xcode、sidestore.io → macOS/akd、jkcoxson → Windows/iTunes），
        // 所以收口必须在客户端（`AnisetteV3Client.acceptedClientInfo`）。
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
