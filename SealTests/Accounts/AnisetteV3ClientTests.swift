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

    /// SideInstaller 1.5.1 内置 anisette 目录第一条是 `https://ani.sidestore.io`，
    /// 且它实测返回的是唯一可用身份（`MacBookPro13,2` / macOS 13.1 / akd），
    /// 因此 Seal 把它排在默认第一位：身份原样取服务器值时，直接命中 SideInstaller
    /// 的成功落点，不必先撞那 8 台 Xcode 身份服务器再靠 failover 绕开。
    @Test
    func defaultServerKeepsSideInstallerDefaultServer() throws {
        let servers = AnisetteServerCatalog.official
        let first = try #require(servers.first)

        #expect(first.url.absoluteString == "https://ani.sidestore.io")
        #expect(Set(servers.map(\.id)).count == servers.count)
        #expect(servers.filter { $0.url.absoluteString == "https://ani.jkcoxson.com" }.count == 1)
        #expect(servers.last?.url.absoluteString == "https://ani.jkcoxson.com")
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
    func clientInfoParsingUsesServerIdentityVerbatim() throws {
        let serverValue = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        let data = try JSONSerialization.data(withJSONObject: [
            "client_info": serverValue,
            "user_agent": "akd/1.0 CFNetwork/808.1.4"
        ])

        // isideload 同款：身份原样取服务器返回值（`remote_v3/mod.rs:194`），
        // 只用服务器的 user_agent 拼请求头。
        #expect(
            try AnisetteV3Client.parseClientInfo(data: data) ==
                AnisetteV3ClientInfo(
                    clientInfo: serverValue,
                    userAgent: "akd/1.0 CFNetwork/808.1.4"
                )
        )
    }

    /// REA（SideInstaller 1.5.1 的 isideload 源码）：身份取服务器返回值；而它内置目录
    /// 15 台里有 8 台返回会被 Apple 边缘直接拒掉的 Xcode 身份——它靠**换服务器**绕开，
    /// 不是改写身份。所以 Seal 对必拒身份（Xcode / Android）抛 `rejectedIdentity`
    /// 让上层换下一台；可用身份（macOS / Windows）原样放行。
    @Test
    func identitiesRejectedByAppleFailOverInsteadOfBeingSent() throws {
        func parsed(_ clientInfo: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "client_info": clientInfo,
                "user_agent": "akd/1.0 CFNetwork/808.1.4"
            ])
            return try AnisetteV3Client.parseClientInfo(data: data).clientInfo
        }

        let rejected = [
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>",
            "<MacBookPro18,3> <macOS;26.5.2;25F84> <com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>",
            "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        ]
        for value in rejected {
            #expect(throws: AnisetteV3Error.rejectedIdentity) {
                _ = try parsed(value)
            }
        }

        let accepted = [
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
        ]
        for value in accepted {
            #expect(try parsed(value) == value)
        }
    }

    @Test
    func clientInfoParsingRejectsIncompleteResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: ["client_info": "only-one"])

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
