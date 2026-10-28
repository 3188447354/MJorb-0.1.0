import Foundation
import Testing
@testable import Seal

struct AnisetteV3ClientTests {
    @Test
    func compatibilityRetryFailsClosedWithoutChangingSharedEnvironment() async throws {
        let store = TestAnisetteProvisioningStore()
        let identity = try AnisetteV3Identity(bytes: Data((0..<16).map(UInt8.init)))
        let state = try #require(AnisetteProvisioningState(identifier: identity.encodedIdentifier, adiPB: "existing", clientInfo: "existing-identity"))
        try await store.saveIdentifier(identity.encodedIdentifier)
        try await store.save(state)
        let writesBefore = await store.mutationCount()
        let client = AnisetteV3Client(servers: [], store: store, identityStore: store)

        do {
            _ = try await client.fetchForCompatibilityRetry(expectedDeviceID: "different-device")
            Issue.record("不同设备身份必须安全失败")
        } catch {
            #expect(error as? AnisetteV3Error == .staleProvisioning)
        }
        do {
            _ = try await client.fetchForCompatibilityRetry(expectedDeviceID: identity.deviceIdentifier)
            Issue.record("没有匹配服务时必须安全失败")
        } catch {
            #expect(error as? AnisetteV3Error == .unavailable)
        }
        let writesAfter = await store.mutationCount()
        let identifierAfter = try await store.loadIdentifier()
        let stateAfter = try await store.load()
        #expect(writesAfter == writesBefore)
        #expect(identifierAfter == identity.encodedIdentifier)
        #expect(stateAfter == state)
    }

    @Test
    func compatibilityRetryNeverCreatesMissingSharedIdentity() async throws {
        let store = TestAnisetteProvisioningStore()
        let client = AnisetteV3Client(servers: [], store: store, identityStore: store)
        do {
            _ = try await client.fetchForCompatibilityRetry(expectedDeviceID: "missing")
            Issue.record("缺失身份时必须安全失败")
        } catch {
            #expect(error as? AnisetteV3Error == .staleProvisioning)
        }
        let writes = await store.mutationCount()
        let identifier = try await store.loadIdentifier()
        #expect(writes == 0)
        #expect(identifier == nil)
    }

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

    /// **Mac（akd）身份的服务器排在第一位，Windows 身份服务器已退出目录**
    /// （2026-10-22，跟随 iLoader 2.4.0）。
    ///
    /// 这条断言此前守的是「`ani.jkcoxson.com`（Windows 身份）排第一」——那是
    /// 2026-10-16 跟随当时 isideload 的 Windows 归一化得出的结论。2026-10-22
    /// 真机实测推翻了它：多个既有账号 SRP 登录全程成功后，换 Xcode token 的
    /// apptokens 步被回 `-80046 / hsc=400`（Seal-log_45），同一批账号在
    /// iLoader（默认 `mac-ani.jkcoxson.com`）下登录、签名均正常；iLoader 2.4.0
    /// 已把默认服务器设为 Jkcoxson (Mac) 并移除 legacy Windows 服务器，
    /// isideload 也删除了 `client_info_to_use` 的 Windows 归一化。
    @Test
    func macIdentityServersComeFirstAndWindowsServersAreGone() throws {
        let servers = AnisetteServerCatalog.official
        let first = try #require(servers.first)

        #expect(first.url.absoluteString == "https://mac-ani.jkcoxson.com")
        #expect(Set(servers.map(\.id)).count == servers.count)
        #expect(servers.filter { $0.url.absoluteString == "https://mac-ani.jkcoxson.com" }.count == 1)
        // Windows 身份的两台已退出目录，不许悄悄加回来。
        #expect(servers.contains { $0.url.absoluteString == "https://ani.jkcoxson.com" } == false)
        #expect(servers.contains { $0.url.absoluteString == "https://win.ani.sidestore.io" } == false)
        // 其余 Mac 身份服务器保留作兜底回退。
        let fallbackIndex = try #require(servers.firstIndex { $0.url.absoluteString == "https://ani.sidestore.io" })
        #expect(fallbackIndex > 0)
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

    /// 对齐 isideload 当前的 `get_client_info`：服务器声明的身份与 User-Agent
    /// **原样采用**，不再做任何归一化（上游已删除 `client_info_to_use` 的
    /// Windows 归一化，2026-10-22）。唯一的加工是：服务器没给 User-Agent 时
    /// 用兜底值，避免请求头为空。
    @Test
    func clientInfoParsingUsesServerIdentityVerbatim() throws {
        func parsed(_ clientInfo: String, userAgent: String = "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0") throws -> AnisetteV3ClientInfo {
            let data = try JSONSerialization.data(withJSONObject: [
                "client_info": clientInfo,
                "user_agent": userAgent
            ])
            return try AnisetteV3Client.parseClientInfo(data: data)
        }

        // 曾被改写成 Windows 身份的几类声明，现在都必须原样通过——
        // 包括默认服务器 mac-ani 的 MacBookPro13,3 身份（此前正中改写名单）。
        let verbatimInputs = [
            "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>",
            "<MacBookPro15,1> <Mac OS X;10.15.2;19C57> <com.apple.AuthKit/1 (com.apple.dt.Xcode/1.0)>",
            "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
        ]
        for value in verbatimInputs {
            #expect(try parsed(value).clientInfo == value)
            #expect(try parsed(value).userAgent == "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0")
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
    private var writes = 0

    func mutationCount() -> Int { writes }

    func loadIdentifier() async throws -> String? { identifier }

    func saveIdentifier(_ identifier: String) async throws {
        writes += 1
        self.identifier = identifier
    }

    func removeIdentifier() async throws {
        writes += 1
        identifier = nil
    }

    func load() async throws -> AnisetteProvisioningState? { state }

    func save(_ state: AnisetteProvisioningState) async throws {
        writes += 1
        self.state = state
    }

    func remove() async throws {
        writes += 1
        state = nil
    }
}
