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
        // ── 首选：**提供 Mac（akd）身份**的服务器 ────────────────────────────
        //
        // 2026-10-22 定论（跟随 iLoader 2.4.0 / isideload 现行实现）：
        // 此前的 Windows（iTunes）身份路线（2026-10-16 定论）已经失效——真机日志
        // Seal-log_45 实测：多个既有账号在 SRP 登录全程成功后，换 Xcode token 的
        // apptokens 步被 Apple 回 `ec=-80046 / hsc=400`；同一批账号在 iLoader
        // （默认 `mac-ani.jkcoxson.com` 的 Mac 身份）下登录、签名均正常。
        // iLoader 2.4.0 同时把默认服务器设为 Jkcoxson (Mac) 并移除了 legacy
        // Windows 服务器；isideload 也已删除 `client_info_to_use` 的 Windows
        // 归一化，改为原样采用服务器 `/v3/client_info`（见 `AnisetteClient`
        // 的 `authenticationClientInfo`）。Seal 按同路线对齐。
        //
        // `mac-ani.jkcoxson.com` 与 `new.ani.sidestore.io` 返回同一身份：
        //   `<MacBookPro13,3> <Mac OS X;10.12.6;16G29> …(com.apple.akd/1.0)>`
        //   user_agent `akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0`
        AnisetteServer(
            id: "jkcoxson-mac",
            url: makeURL("https://mac-ani.jkcoxson.com"),
            displayName: "jkcoxson (Mac)"
        ),
        AnisetteServer(
            id: "sidestore-new",
            url: makeURL("https://new.ani.sidestore.io"),
            displayName: "SideStore (New)"
        ),
        AnisetteServer(
            id: "stikstore2",
            url: makeURL("https://ani2.stikstore.app"),
            displayName: "stikstore"
        ),
        // ── 以下为其余 Mac 身份的公共服务器，保留作兜底回退 ─────────────────
        AnisetteServer(
            id: "sidestore-io",
            url: makeURL("https://ani.sidestore.io"),
            displayName: "SideStore"
        ),
        // SideStore 官方维护的公共 Anisette 服务器列表
        // 来源: https://servers.sidestore.io/servers.json
        // Seal 会按顺序自动尝试，一个挂了自动切下一个，避免单点故障
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
        AnisetteServer(
            id: "ethxn",
            url: makeURL("https://omni.ethxn.xyz"),
            displayName: "ethxn"
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
