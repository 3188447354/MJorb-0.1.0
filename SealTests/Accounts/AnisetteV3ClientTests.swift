import Foundation
import Testing
@testable import Seal

struct AnisetteV3ClientTests {
    @Test
    func officialServersPutSelectedServerFirstWithoutDuplicates() throws {
        let selected = try #require(AnisetteServerCatalog.official.first)
        let servers = AnisetteServerCatalog.prioritized(selectedID: selected.id)

        #expect(servers.first?.id == selected.id)
        #expect(Set(servers.map(\.id)).count == servers.count)
        #expect(Set(servers.map(\.id)) == Set(AnisetteServerCatalog.official.map(\.id)))
        #expect(servers.allSatisfy { $0.url.scheme == "https" })
    }

    @Test
    func unknownSelectedServerUsesOfficialDefaultOrder() {
        let servers = AnisetteServerCatalog.prioritized(selectedID: "not-a-server")

        #expect(servers == AnisetteServerCatalog.official)
    }

    /// **Windows（iTunes）身份的服务器必须排在第一位**（2026-10-16 更正）。
    ///
    /// 这条断言原来守的是「`ani.sidestore.io` 排第一」——那是基于 SideInstaller 1.5.1
    /// 仍在用 Mac 身份时的观察。自 2026-10-12 起 Apple 开始返回 `-80045`，
    /// 原因是 **anisette 数据与声明的客户端身份不同源**；10-14 起连声明安卓/ Xcode
    /// 身份都会被边缘直接 503。当前唯一可用的是 **Windows ADI（iTunes）**。
    ///
    /// 实测（直接向 `GsService2` 发同一个 init 请求，只改身份）：
    ///   `<PC> <Windows;6.2(0,0);9200> …(com.apple.iTunes/12.12.4.1)>` → 200 正常处理
    ///   `<MacBookPro13,2> <macOS;13.1;22C65> …(com.apple.akd/1.0)>`   → 200 但登录回 -80045
    ///   `<Pixel 7> <Android;14;…>` / `dt.Xcode`                       → **503 HTML 硬拒**
    ///
    /// 而 13 台公共服务器里**只有 `ani.jkcoxson.com` 返回 Windows 身份**。
    /// 它曾经排在末尾，于是前面那台"能成功返回 Mac 身份"的服务器先命中、
    /// Windows 这台**永远不会被 fallback 到** —— 这正是登录一直修不好的直接原因。
    @Test
    func windowsIdentityServersComeFirst() throws {
        let servers = AnisetteServerCatalog.official
        let first = try #require(servers.first)

        #expect(first.url.absoluteString == "https://ani.jkcoxson.com")
        #expect(Set(servers.map(\.id)).count == servers.count)
        // 只出现一次：既不能被删掉（那样就没有 Windows 身份可用了），也不能重复。
        #expect(servers.filter { $0.url.absoluteString == "https://ani.jkcoxson.com" }.count == 1)
        // Mac 身份的服务器保留作兜底，但**必须排在 Windows 之后**。
        let macIndex = try #require(servers.firstIndex { $0.url.absoluteString == "https://ani.sidestore.io" })
        #expect(macIndex > 0)
    }

    @Test
    func provisioningStateRoundTripsAndRejectsEmptyValues() throws {
        let state = AnisetteProvisioningState(
            identifier: "identifier",
            adiPB: "adi-pb",
            clientInfo: "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        )
        let data = try JSONEncoder().encode(state)

        #expect(try JSONDecoder().decode(AnisetteProvisioningState.self, from: data) == state)
        #expect(AnisetteProvisioningState(identifier: "", adiPB: "adi-pb") == nil)
        #expect(AnisetteProvisioningState(identifier: "identifier", adiPB: "") == nil)

        // 旧版本写入的条目没有身份戳，必须仍能解码（解码为 nil），否则升级后读旧 ADI 会直接抛错。
        let legacy = Data(#"{"identifier":"identifier","adiPB":"adi-pb"}"#.utf8)
        #expect(try JSONDecoder().decode(AnisetteProvisioningState.self, from: legacy).clientInfo == nil)
    }

    /// ADI 只对「建它时声明的那个身份」有效：Apple 对「ADI 与声明系统不一致」的初始登录
    /// 回 `-80045`。身份现在随服务器变化（原样取 `/v3/client_info`），所以身份戳不匹配
    /// （含旧版本写入的无戳条目）必须判为无效，进而作废重签。
    @Test
    func provisioningStateMatchesOnlyTheIdentityItWasBuiltWith() throws {
        let macIdentity = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        let windowsIdentity = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"

        let stamped = try #require(
            AnisetteProvisioningState(
                identifier: "identifier",
                adiPB: "adi-pb",
                clientInfo: macIdentity
            )
        )
        #expect(stamped.matches(clientInfo: macIdentity))
        #expect(stamped.matches(clientInfo: windowsIdentity) == false)

        let legacy = try #require(AnisetteProvisioningState(identifier: "identifier", adiPB: "adi-pb"))
        #expect(legacy.clientInfo == nil)
        #expect(legacy.matches(clientInfo: macIdentity) == false)

        let staleXcode = try #require(
            AnisetteProvisioningState(
                identifier: "identifier",
                adiPB: "adi-pb",
                clientInfo: "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
            )
        )
        #expect(staleXcode.matches(clientInfo: macIdentity) == false)
    }

    @Test
    func identityDerivationIsStableForSixteenBytes() throws {
        let bytes = Data((0..<16).map(UInt8.init))
        let identity = try AnisetteV3Identity(bytes: bytes)

        #expect(identity.encodedIdentifier == "AAECAwQFBgcICQoLDA0ODw==")
        #expect(identity.localUserID == "BE45CB2605BF36BEBDE684841A28F0FD43C69850A3DCE5FEDBA69928EE3A8991")
        #expect(identity.deviceIdentifier == "00010203-0405-0607-0809-0A0B0C0D0E0F")
    }

    @Test
    func identityDerivationRejectsWrongByteCount() {
        #expect(throws: AnisetteV3Error.invalidIdentifier) {
            _ = try AnisetteV3Identity(bytes: Data([0]))
        }
    }

    @Test
    func clientInfoParsingPreservesCustomServerIdentity() throws {
        let serverValue = "<Mac14,2> <macOS;14.6;23G80> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        let data = try JSONSerialization.data(withJSONObject: [
            "client_info": serverValue,
            "user_agent": "akd/1.0 CFNetwork/808.1.4"
        ])

        // SideInstaller 只替换已知公共服务器的旧 Mac/Xcode 或 Android 声明；
        // 自建服务器的真实身份必须保留，不能被无差别覆盖。
        #expect(
            try AnisetteV3Client.parseClientInfo(data: data) ==
                AnisetteV3ClientInfo(
                    clientInfo: serverValue,
                    userAgent: "akd/1.0 CFNetwork/808.1.4"
                )
        )
    }

    /// 对齐 SideInstaller 当前的 `client_info_to_use`：旧 Mac/Xcode 与 Android
    /// 宣称身份统一使用 Windows iTunes 身份；自建服务器的真实身份保留。
    @Test
    func clientInfoParsingUsesSideInstallerAuthenticationIdentityPolicy() throws {
        func parsed(_ clientInfo: String, userAgent: String = "akd/1.0 CFNetwork/808.1.4") throws -> AnisetteV3ClientInfo {
            let data = try JSONSerialization.data(withJSONObject: [
                "client_info": clientInfo,
                "user_agent": userAgent
            ])
            return try AnisetteV3Client.parseClientInfo(data: data)
        }

        let windows = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
        let fallbackInputs = [
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>",
            "<MacBookPro15,1> <Mac OS X;10.15.2;19C57> <com.apple.AuthKit/1 (com.apple.dt.Xcode/1.0)>",
            "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        ]
        for value in fallbackInputs {
            #expect(try parsed(value).clientInfo == windows)
            #expect(try parsed(value).userAgent == "akd/1.0 CFNetwork/808.1.4")
        }

        let custom = "<Mac14,2> <macOS;14.6;23G80> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        #expect(try parsed(custom, userAgent: "").clientInfo == custom)
        #expect(try parsed(custom, userAgent: "").userAgent == "akd/1.0 CFNetwork/808.1.4")
    }

    @Test
    func clientInfoParsingRejectsResponseWithoutClientIdentity() throws {
        let data = try JSONSerialization.data(withJSONObject: ["user_agent": "akd/1.0"])

        #expect(throws: AnisetteV3Error.invalidServerResponse) {
            _ = try AnisetteV3Client.parseClientInfo(data: data)
        }
    }

    @Test
    func clientInfoParsingNormalizesMalformedJSON() {
        let data = Data("not-json".utf8)

        #expect(throws: AnisetteV3Error.invalidServerResponse) {
            _ = try AnisetteV3Client.parseClientInfo(data: data)
        }
    }

    @Test
    func resetSigningEnvironmentRemovesProvisioningButPreservesIdentifier() async throws {
        let store = TestAnisetteProvisioningStore()
        try await store.saveIdentifier("identifier")
        try await store.save(AnisetteProvisioningState(identifier: "identifier", adiPB: "adi-pb")!)
        let client = AnisetteV3Client(store: store, identityStore: store)

        await client.resetProvisioning()

        let identifier = try await store.loadIdentifier()
        let state = try await store.load()
        // identifier 与 authToken 绑定，清除会令所有已登录 Apple ID 会话过期（1100）而强制重登+2FA，
        // 因此 reset 只清远程 provisioning state，必须保留本地 identifier
        #expect(identifier == "identifier")
        #expect(state == nil)
    }
}

private actor TestAnisetteProvisioningStore: AnisetteProvisioningStore {
    private var identifier: String?
    private var state: AnisetteProvisioningState?

    func loadIdentifier() async throws -> String? { identifier }

    func saveIdentifier(_ identifier: String) async throws {
        self.identifier = identifier
    }

    func removeIdentifier() async throws {
        identifier = nil
    }

    func load() async throws -> AnisetteProvisioningState? { state }

    func save(_ state: AnisetteProvisioningState) async throws {
        self.state = state
    }

    func remove() async throws {
        state = nil
    }
}
