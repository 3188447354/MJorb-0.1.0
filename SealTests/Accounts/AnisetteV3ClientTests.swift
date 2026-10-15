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

    /// SideInstaller 1.5.1 二进制里的 DEFAULT_ANISETTE_V3_URL 是
    /// `https://ani.stikstore.app`，Seal 沿用同一个默认服务器。该服务器返回的
    /// client_info 是 Xcode 身份，会被 Apple 登录边缘拒绝——这一点由
    /// `serverIdentitiesRejectedByAppleAreReplaced` 在身份层兜住，默认服务器本身
    /// 不再承担“指纹自洽”的职责。`ani.jkcoxson.com` 作为兜底保留在列表末尾。
    @Test
    func defaultServerKeepsSideInstallerDefaultServer() throws {
        let servers = AnisetteServerCatalog.official
        let first = try #require(servers.first)

        #expect(first.url.absoluteString == "https://ani.stikstore.app")
        #expect(servers.filter { $0.url.absoluteString == "https://ani.jkcoxson.com" }.count == 1)
        #expect(servers.last?.url.absoluteString == "https://ani.jkcoxson.com")
    }

    @Test
    func provisioningStateRoundTripsAndRejectsEmptyValues() throws {
        let state = AnisetteProvisioningState(
            identifier: "identifier",
            adiPB: "adi-pb",
            clientInfo: AnisetteV3Client.declaredClientInfo
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
    /// 回 `-80045`。所以身份戳不匹配（含旧版本写入的无戳条目）必须判为无效，进而作废重签。
    @Test
    func provisioningStateMatchesOnlyTheIdentityItWasBuiltWith() throws {
        let stamped = try #require(
            AnisetteProvisioningState(
                identifier: "identifier",
                adiPB: "adi-pb",
                clientInfo: AnisetteV3Client.declaredClientInfo
            )
        )
        #expect(stamped.matches(clientInfo: AnisetteV3Client.declaredClientInfo))
        #expect(stamped.matches(clientInfo: "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>") == false)

        let legacy = try #require(AnisetteProvisioningState(identifier: "identifier", adiPB: "adi-pb"))
        #expect(legacy.clientInfo == nil)
        #expect(legacy.matches(clientInfo: AnisetteV3Client.declaredClientInfo) == false)

        let staleXcode = try #require(
            AnisetteProvisioningState(
                identifier: "identifier",
                adiPB: "adi-pb",
                clientInfo: "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
            )
        )
        #expect(staleXcode.matches(clientInfo: AnisetteV3Client.declaredClientInfo) == false)
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
    func clientInfoParsingUsesDeclaredIdentityAndServerUserAgent() throws {
        let serverValue = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        let data = try JSONSerialization.data(withJSONObject: [
            "client_info": serverValue,
            "user_agent": "akd/1.0 CFNetwork/808.1.4"
        ])

        #expect(
            try AnisetteV3Client.parseClientInfo(data: data) ==
                AnisetteV3ClientInfo(
                    clientInfo: AnisetteV3Client.declaredClientInfo,
                    userAgent: "akd/1.0 CFNetwork/808.1.4"
                )
        )
    }

    /// REA（SideInstaller 1.5.1 主二进制）：它内置的 anisette 目录里 15 台服务器中，实测有
    /// 8 台的 `/v3/client_info` 返回会被 Apple 登录边缘直接拒掉的 Xcode 身份，而它照样能
    /// 登录 ⇒ 身份不取服务器返回值。Seal 同样只声明自己那一个身份，所以无论服务器返回
    /// Xcode / Android / macOS / Windows，声明出来的都必须是同一个。
    @Test
    func declaredIdentityIsIndependentOfTheServerReturnedIdentity() throws {
        func parsedClientInfo(_ clientInfo: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [
                "client_info": clientInfo,
                "user_agent": "akd/1.0 CFNetwork/808.1.4"
            ])
            return try AnisetteV3Client.parseClientInfo(data: data).clientInfo
        }

        let declared = AnisetteV3Client.declaredClientInfo
        let serverValues = [
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>",
            "<MacBookPro18,3> <macOS;26.5.2;25F84> <com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>",
            "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
        ]

        for value in serverValues {
            #expect(try parsedClientInfo(value) == declared)
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
