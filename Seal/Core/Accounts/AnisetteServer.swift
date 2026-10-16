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
        // ── 首选：**提供 Windows（iTunes）身份**的服务器 ──────────────────────
        //
        // 2026-10-16 定论（来源：altstoreio/AltStore#1834 的实测记录 + 本机独立探测）：
        // 从 10-12 起，`-80045 / hsc=500` 的原因是 **anisette 数据与声明的客户端身份
        // 不是同一套**；而 10-14 ~20:50 UTC 起 Apple 更进一步，**对任何声明安卓身份的
        // 请求直接返回 503 HTML**。真正还能用的是 **Windows 的 ADI（iTunes）**。
        //
        // 本机探测（直接向 GsService2 发同一个 init 请求，只改身份）：
        //   `<PC> <Windows;6.2(0,0);9200> …(com.apple.iTunes/12.12.4.1)>` → 200 正常处理
        //   `<MacBookPro13,2> <macOS;13.1;22C65> …(com.apple.akd/1.0)>`   → 200 正常处理
        //   `<Pixel 7> <Android;14;…>`                                    → **503 HTML 硬拒**
        //
        // 而 13 台公共服务器里**只有 `ani.jkcoxson.com` 返回 Windows 身份**；
        // `ani.sidestore.io` 等返回的是 Mac 身份，其 ADI 被 Apple 判为不符而回 -80045。
        // 所以必须把它排在第一位：它排在末尾时，前面那台"能成功返回 Mac 身份"的服务器
        // 会先命中，Windows 这台**永远不会被 fallback 到** —— 这正是修不好登录的原因。
        AnisetteServer(
            id: "jkcoxson",
            url: makeURL("https://ani.jkcoxson.com"),
            displayName: "jkcoxson (Windows)"
        ),
        AnisetteServer(
            id: "stikstore2",
            url: makeURL("https://ani2.stikstore.app"),
            displayName: "stikstore (Windows)"
        ),
        // ── 以下为 Mac 身份的公共服务器 ──────────────────────────────────────
        // 保留在列表里作为兜底（Apple 对 Mac 身份在边缘是放行的），但**不再优先**。
        // 它们返回 `<MacBookPro13,2> <macOS;13.1;22C65>`；返回 Xcode 身份的那几台
        // 会按 SideInstaller 策略归一化为 Windows 身份后继续使用。
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
