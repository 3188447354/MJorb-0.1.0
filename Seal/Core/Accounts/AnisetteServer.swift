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
        // 它返回 macOS/Xcode 身份
        // `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>`，
        // 与 GrandSlam 固定发送的 `X-Apple-App-Info: com.apple.gs.xcode.auth`
        // 属于同一个 Xcode 应用，指纹自洽。ani.jkcoxson.com 返回的是
        // iTunes/Windows 身份，与同一指纹冲突，因此降级到列表末尾兜底。
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
        // isideload 上游源码的默认值，但返回 Windows/iTunes 身份
        // `<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>`，
        // 与 Xcode 认证指纹不匹配，只作最后的兜底。
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
