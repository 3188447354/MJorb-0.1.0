import CryptoKit
import Foundation
import os
@preconcurrency import AltSign

struct AnisetteV3Client: AnisetteEnvironmentManaging {
    private static let logger = Logger(subsystem: "com.mjorb.seal", category: "anisette")

    /// 与 isideload `grandslam.rs` 的 `base_headers` 逐字一致的两个指纹头，
    /// 也与 `upstream/AltSign` 的同名常量保持一致（那边作用于 SRP，这边作用于
    /// provisioning）。
    private static let grandSlamAuthenticationXcodeVersion = "27.0 (27A5218g)"
    private static let grandSlamAuthenticationAppInfo = "com.apple.gs.xcode.auth"

    /// 与 SideInstaller 当前 isideload 完全相同的登录身份归一化策略。
    ///
    /// 某些 v3 服务器用 Android ADI 生成数据，却仍宣称旧版 Mac/Xcode 或 Android 身份。
    /// Apple 已会直接拒绝这些声明。SideInstaller 会在这种情况下以 Windows iTunes
    /// 身份请求，并在 provisioning、SRP 和后续认证中始终使用同一有效身份。
    /// Seal 必须同样将**归一化后的身份**写入 ADI 身份戳，避免再把旧 ADI 与新声明混用。
    private static let windowsClientInfo =
        "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
    private static let akdUserAgent = "akd/1.0 CFNetwork/808.1.4"
    private static let stockServerClientPrefixes = [
        "<MacBookPro13,2> <macOS;13.1;22C65>",
        "<MacBookPro15,1> <Mac OS X;10.15.2;19C57>"
    ]

    static func authenticationClientInfo(
        advertisedClientInfo: String,
        advertisedUserAgent: String
    ) -> AnisetteV3ClientInfo {
        let clientInfo = advertisedClientInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let isStockServerIdentity = stockServerClientPrefixes.contains { clientInfo.hasPrefix($0) }
        if clientInfo.isEmpty || isStockServerIdentity || clientInfo.contains("<Android;") {
            return AnisetteV3ClientInfo(
                clientInfo: windowsClientInfo,
                userAgent: akdUserAgent
            )
        }

        let userAgent = advertisedUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return AnisetteV3ClientInfo(
            clientInfo: clientInfo,
            userAgent: userAgent.isEmpty ? akdUserAgent : userAgent
        )
    }

    /// Anisette 时间格式（ISO8601 UTC），两处复用，避免每次新建 DateFormatter。
    private static let iso8601UTCFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private let servers: [AnisetteServer]
    private let session: URLSession
    /// SideInstaller 风格远程 v3 会话状态。与旧本机 ADI 状态隔离，不能互相覆盖。
    private let remoteStore: any AnisetteProvisioningStore
    /// 只保存稳定的设备 identifier；保留旧值以维持设备身份连续性。
    private let identityStore: any AnisetteProvisioningStore
    private let serverStore: any AnisetteServerStore
    /// 全量操作日志：每个决策点（选服务器、取身份、ADI 命中/作废、provisioning
    /// 成败、get_headers 结果）都写一条，真机排障时能完整还原一次添加账号做了什么。
    private let logStore: SealLogStore?

    /// 远程降级的总时长预算：避免服务器逐个重试把添加账号拖到数分钟
    private static let remoteFallbackBudgetSeconds: TimeInterval = 120

    init(
        servers: [AnisetteServer] = AnisetteServerCatalog.official,
        session: URLSession = .shared,
        store: (any AnisetteProvisioningStore)? = nil,
        identityStore: (any AnisetteProvisioningStore)? = nil,
        serverStore: any AnisetteServerStore = UserDefaultsAnisetteServerStore(),
        logStore: SealLogStore? = nil
    ) {
        self.servers = servers
        self.session = session
        let remoteStore = store ?? KeychainAnisetteProvisioningStore(
            service: SealKeychainServices.remoteAnisetteProvisioning
        )
        let identityStore = identityStore ?? KeychainAnisetteProvisioningStore(
            service: SealKeychainServices.anisetteProvisioning
        )
        self.remoteStore = remoteStore
        self.identityStore = identityStore
        self.serverStore = serverStore
        self.logStore = logStore
    }

    /// 写一条 anisette 操作日志（脱敏由 SealLogStore 保证）。
    /// 日志永不中断主流程：`try?` 吞掉写入失败，绝不能让记日志把登录搞崩。
    private func trace(
        _ message: String,
        level: SealLogEntry.Level = .info
    ) async {
        try? await logStore?.append(category: .account, level: level, message: "[anisette] \(message)")
    }

    /// SideInstaller 的默认策略：认证、验证码、认证后验证和门户请求始终用同一个
    /// 远程 v3 Anisette 会话。不能先用远程取得 authToken、随后切回本机 ADI。

    /// 认证路径的固定 locale：与身份串保持同一套声明，不取设备 locale
    /// （中文机取 `Locale.current` 会得到 zh_CN，与身份串自相矛盾）。
    private static let authenticationLocaleIdentifier = "en_US"

    /// **实验开关**：把登录请求的 `X-Mme-Client-Info` 钉成 SideInstaller 二进制里
    /// 那条 Mac 身份，而不是 anisette 服务器返回的 `MacBookPro13,2 / macOS 13.1`。
    ///
    /// 为什么要试：`-80045` 出现在 `o=init` 这第一个请求上（日志里从未走到 `o=complete`），
    /// init 的载荷不含任何密码材料，而 Apple 返回的是 **`hsc = 500`（服务端内部错误）**。
    /// 走到这一步，客户端载荷已逐项核对无误（cpd 九字段、SRP 头七项、A2k 256 字节、
    /// PBKDF2/群组/哈希/username 入 x 全部与 isideload 等价），**唯一从未换过的变量就是
    /// 这条身份串** —— 它一直是那台 2023 年的 `MacBookPro13,2`。
    ///
    /// 判别力：成功即定位根因；失败则**干净地排除"身份差异"**，不再留悬案。
    ///
    /// 与"把配置整体换成 isideload"不同：isideload 走的就是服务器身份，所以那件事
    /// 解决不了本问题；这里做的是换成**另一个已知可用实现里真实存在的字面量**。
    ///
    /// 置回 `nil` 即恢复原行为（用服务器返回的身份），其余逻辑一概不动。
    ///
    /// ⚠️ 2026-10-16 **已实测证伪，保持为 nil**。
    /// 真机日志（build 48）显示身份确实换成了 `<Mac15,7> <macOS;27.0;26A5378j>`
    /// 且 ADI 重新 provisioning，Apple 仍返回 `-80045 / hsc=500`。
    /// 另外用独立探测（不经 App、直接向 `GsService2` 发同样的 init 请求）跑过身份矩阵：
    /// `Mac15,7` / `MacBookPro13,2` / `MacBookPro18,3` / Windows PC 四条 `akd` 身份
    /// **全部得到同一个 `-80009 MID is invalid`**，行为完全一致；只有 `dt.Xcode` 与
    /// Android 会被边缘以 503 拒绝。⇒ Apple 只区分 `akd` vs Xcode/Android，
    /// **不区分具体机型或系统版本**，所以「换身份」这条路是死的。
    private static let experimentalSignInClientInfo: String? = nil

    func fetch() async throws -> ALTAnisetteData {
        let identity = try await loadIdentity()
        await trace("fetch 开始，设备标识=\(identity.deviceIdentifier.lowercased())，声明身份将取自服务器")
        return try await fetchRemote(identity: identity)
    }

    func fetchForAuthentication() async throws -> ALTAnisetteData {
        await trace("fetchForAuthentication（认证专用，与后续门户请求同一会话）")
        return try await fetch()
    }

    func resetProvisioning() async {
        // 只重置远程 v3 provisioning 状态；稳定 identifier 和旧本机 ADI 都不删除。
        await trace("resetProvisioning：作废远程 ADI（identifier 保留）", level: .warning)
        try? await remoteStore.remove()
    }

    func resync(sim: String) async throws -> ALTAnisetteData {
        let identity = try await loadIdentity()
        await trace("resync 开始，sim 长度=\(sim.count)")
        guard let state = try await remoteStore.load() else {
            await trace("resync 失败：无远程 ADI，需先走 fetch() 重新 provisioning", level: .warning)
            throw AnisetteV3Error.staleProvisioning
        }
        var lastError: Error?
        for server in await prioritizedServers() where server.url.scheme == "https" {
            do {
                let clientInfo = try await fetchClientInfo(from: server.url)
                // 同一条不变量：ADI 只对建它时声明的身份有效。身份戳不匹配就当作
                // provisioning 已失效，交给调用方走完整的 fetch()（会作废重签）。
                guard state.matches(clientInfo: clientInfo.clientInfo) else {
                    await trace("resync：ADI 身份戳不匹配（建时=\(state.clientInfo ?? "无")/现=\(clientInfo.clientInfo)），判为失效", level: .warning)
                    throw AnisetteV3Error.staleProvisioning
                }
                let data = try await fetchHeaders(from: server.url, state: state, clientInfo: clientInfo, identity: identity, sim: sim)
                await trace("resync 成功，服务器=\(server.displayName)")
                return data
            } catch {
                await trace("resync 服务器=\(server.displayName) 失败：\(Self.describe(error))", level: .warning)
                lastError = error
            }
        }
        await trace("resync 所有服务器均失败，最后错误=\(lastError.map(Self.describe) ?? "无")", level: .error)
        throw lastError ?? AnisetteV3Error.unavailable
    }

    private func fetchRemote(identity: AnisetteV3Identity) async throws -> ALTAnisetteData {
        let fallbackDeadline = Date().addingTimeInterval(Self.remoteFallbackBudgetSeconds)
        var lastError: Error?
        let all = await prioritizedServers().filter { $0.url.scheme == "https" }
        await trace("fetchRemote 开始，候选服务器 \(all.count) 台，超时预算 \(Int(Self.remoteFallbackBudgetSeconds)) 秒")
        for server in all {
            if Date() > fallbackDeadline {
                await trace("fetchRemote 预算耗尽，放弃剩余服务器", level: .warning)
                break
            }
            do {
                try Task.checkCancellation()
                await trace("fetchRemote 尝试服务器=\(server.displayName)（\(server.url.absoluteString)）")
                let data = try await fetch(from: server.url, identity: identity)
                await trace("fetchRemote 成功，使用服务器=\(server.displayName)，声明身份=\(data.deviceDescription)")
                return data
            } catch is CancellationError {
                await trace("fetchRemote 被取消", level: .warning)
                throw CancellationError()
            } catch {
                Self.logger.error("远程 Anisette 服务器 \(server.displayName, privacy: .public) 失败：\(String(describing: error), privacy: .public)")
                await trace("fetchRemote 服务器=\(server.displayName) 失败：\(Self.describe(error))，换下一台", level: .warning)
                lastError = error
            }
        }
        await trace("fetchRemote 全部失败，最后错误=\(lastError.map(Self.describe) ?? "无")", level: .error)
        throw lastError ?? AnisetteV3Error.unavailable
    }

    func availableServers() async -> [AnisetteServer] {
        servers
    }

    func selectedServerID() async -> String? {
        await serverStore.selectedServerID()
    }

    func selectServer(id: String) async {
        guard servers.contains(where: { $0.id == id }) else { return }
        await serverStore.saveSelectedServerID(id)
    }

    private func fetch(from server: URL, identity: AnisetteV3Identity) async throws -> ALTAnisetteData {
        let serverName = server.host ?? server.absoluteString
        let clientInfo = try await fetchClientInfo(from: server)
        await trace("服务器=\(serverName) 返回身份=\(clientInfo.clientInfo)")

        if let state = try await remoteStore.load() {
            if state.matches(clientInfo: clientInfo.clientInfo) {
                await trace("ADI 命中：已有 ADI 的身份戳与本次声明身份一致，复用")
                do {
                    let data = try await fetchHeaders(
                        from: server,
                        state: state,
                        clientInfo: clientInfo,
                        identity: identity
                    )
                    await trace("复用 ADI 取 headers 成功，服务器=\(serverName)")
                    return data
                } catch let caughtError where Self.isProvisioningRecoverable(caughtError) {
                    // 本地 provisioning 失效或服务器响应异常，重置后重新 provision
                    await trace("复用 ADI 取 headers 失败（\(Self.describe(caughtError))），作废 ADI 后重新 provisioning", level: .warning)
                    try await remoteStore.remove()
                }
            } else {
                // ADI 只对「建它时声明的那个身份」有效：Apple 对「ADI 与声明系统不一致」
                // 的初始登录直接回 -80045。所以声明身份一变就必须作废重签，而不是继续
                // 复用旧 ADI。旧版本写入的条目没有身份戳（nil），会走这条路径自动迁移。
                await trace("ADI 身份戳不匹配（建时=\(state.clientInfo ?? "无戳-旧版本")/现=\(clientInfo.clientInfo)），作废旧 ADI 重新 provisioning", level: .warning)
                try await remoteStore.remove()
            }
        } else {
            await trace("无已存 ADI，走全新 provisioning")
        }

        // provision 失败时只报错，不重置 identity
        // identity 是设备标识（deviceUniqueIdentifier/localUserID），与 authToken 绑定
        // 重置会导致所有已登录 Apple ID 全部失效（1100 会话过期）
        await trace("开始 provisioning，服务器=\(serverName)，声明身份=\(clientInfo.clientInfo)")
        let state = try await provision(
            on: server,
            clientInfo: clientInfo,
            identity: identity
        )
        try await remoteStore.save(state)
        await trace("provisioning 成功，ADI 已保存（身份戳=\(clientInfo.clientInfo)）")
        let data = try await fetchHeaders(
            from: server,
            state: state,
            clientInfo: clientInfo,
            identity: identity
        )
        await trace("新 ADI 取 headers 成功，服务器=\(serverName)")
        return data
    }

    /// 复用 ADI 取 headers 时「作废重签即可恢复」的失败；其余错误原样上抛。
    private static func isProvisioningRecoverable(_ error: Error) -> Bool {
        guard let e = error as? AnisetteV3Error else { return false }
        switch e {
        case .staleProvisioning, .invalidServerResponse, .provisioningFailed:
            return true
        case .invalidIdentifier, .unavailable, .rejectedIdentity:
            return false
        }
    }

    /// 把错误压缩成一行，便于日志归因（不要 dump 全量 userInfo，脱敏由 SealLogStore 兜底）。
    private static func describe(_ error: Error) -> String {
        if let e = error as? AnisetteV3Error {
            switch e {
            case .invalidIdentifier: return "invalidIdentifier"
            case .invalidServerResponse: return "invalidServerResponse"
            case .provisioningFailed: return "provisioningFailed"
            case .staleProvisioning: return "staleProvisioning"
            case .unavailable: return "unavailable"
            case .rejectedIdentity: return "rejectedIdentity(服务器身份会被 Apple 拒)"
            }
        }
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue))"
        }
        return String(describing: error)
    }

    private func loadIdentity() async throws -> AnisetteV3Identity {
        if let encoded = try await identityStore.loadIdentifier(),
           let bytes = Data(base64Encoded: encoded) {
            await trace("设备 identifier 复用已有值（与 authToken 绑定，不重置）")
            return try AnisetteV3Identity(bytes: bytes)
        }
        await trace("首次生成设备 identifier（随机 16 字节）")

        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let encoded = bytes.base64EncodedString()
        try await identityStore.saveIdentifier(encoded)
        return try AnisetteV3Identity(bytes: bytes)
    }

    private func fetchClientInfo(from server: URL) async throws -> AnisetteV3ClientInfo {
        let url = server.appendingPathComponent("v3").appendingPathComponent("client_info")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                await trace("client_info 非 2xx：\(server.host ?? "?") status=\((response as? HTTPURLResponse)?.statusCode ?? -1)", level: .warning)
                throw AnisetteV3Error.invalidServerResponse
            }
            return try Self.parseClientInfo(data: data)
        } catch let e as AnisetteV3Error {
            if case .rejectedIdentity = e {
                await trace("client_info 身份被拒（必被 Apple 拒），跳过 \(server.host ?? "?")", level: .warning)
            }
            throw e
        }
    }

    static func parseClientInfo(data: Data) throws -> AnisetteV3ClientInfo {
        let json: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AnisetteV3Error.invalidServerResponse
            }
            json = value
        } catch let error as AnisetteV3Error {
            throw error
        } catch {
            throw AnisetteV3Error.invalidServerResponse
        }
        guard let clientInfo = json["client_info"] as? String else {
            throw AnisetteV3Error.invalidServerResponse
        }
        let userAgent = json["user_agent"] as? String ?? ""
        return Self.authenticationClientInfo(
            advertisedClientInfo: clientInfo,
            advertisedUserAgent: userAgent
        )
    }

    private func provision(
        on server: URL,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> AnisetteProvisioningState {
        let urls = try await provisioningURLs(clientInfo: clientInfo, identity: identity)
        var socketRequest = URLRequest(url: try websocketURL(for: server))
        socketRequest.timeoutInterval = 15
        let socket = session.webSocketTask(with: socketRequest)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        while true {
            let json = try await receiveJSON(from: socket)
            guard let result = json["result"] as? String else {
                await trace("provisioning WS 消息缺少 result 字段：\(Array(json.keys).sorted().joined(separator: ","))", level: .error)
                throw AnisetteV3Error.provisioningFailed
            }
            await trace("provisioning WS 消息：\(result)")

            switch result {
            case "GiveIdentifier":
                try await send(["identifier": identity.encodedIdentifier], through: socket)

            case "GiveStartProvisioningData":
                let spim = try await startProvisioning(
                    at: urls.start,
                    clientInfo: clientInfo,
                    identity: identity
                )
                await trace("startProvisioning 取到 spim（长度 \(spim.count)）")
                try await send(["spim": spim], through: socket)

            case "GiveEndProvisioningData":
                guard let cpim = json["cpim"] as? String, cpim.isEmpty == false else {
                    await trace("GiveEndProvisioningData 缺少 cpim", level: .error)
                    throw AnisetteV3Error.provisioningFailed
                }
                let endData = try await finishProvisioning(
                    at: urls.end,
                    cpim: cpim,
                    clientInfo: clientInfo,
                    identity: identity
                )
                await trace("finishProvisioning 成功，回送 \(endData.count) 字节")
                try await send(endData, through: socket)

            case "ProvisioningSuccess":
                guard let adiPB = json["adi_pb"] as? String,
                      let state = AnisetteProvisioningState(
                        identifier: identity.encodedIdentifier,
                        adiPB: adiPB,
                        clientInfo: clientInfo.clientInfo
                      ) else {
                    await trace("ProvisioningSuccess 缺少 adi_pb 或状态构造失败", level: .error)
                    throw AnisetteV3Error.provisioningFailed
                }
                await trace("provisioning 完成，adi_pb 长度 \(adiPB.count)")
                return state

            default:
                if result.contains("Error") || result.contains("Invalid") ||
                    result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                    await trace("provisioning WS 报错：\(result)，附带字段=\(json.filter { $0.key != "result" }.keys.sorted().joined(separator: ","))", level: .error)
                    throw AnisetteV3Error.provisioningFailed
                }
                await trace("provisioning WS 未知消息，忽略：\(result)", level: .warning)
            }
        }
    }

    private func provisioningURLs(
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> (start: URL, end: URL) {
        guard let url = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup") else {
            throw AnisetteV3Error.provisioningFailed
        }
        let request = appleRequest(
            url: url,
            clientInfo: clientInfo,
            identity: identity
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: [String: Any]],
              let startString = plist["urls"]?["midStartProvisioning"] as? String,
              let endString = plist["urls"]?["midFinishProvisioning"] as? String,
              let start = URL(string: startString),
              let end = URL(string: endString) else {
            await trace("lookup 失败：status=\((response as? HTTPURLResponse)?.statusCode ?? -1)，body 长度=\(data.count)", level: .error)
            throw AnisetteV3Error.provisioningFailed
        }
        await trace("lookup 成功：midStartProvisioning=\(start.host ?? "?")，midFinishProvisioning=\(end.host ?? "?")")
        return (start, end)
    }

    private func startProvisioning(
        at url: URL,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> String {
        let body: [String: [String: Any]] = [
            "Header": [:],
            "Request": [:]
        ]
        let data = try await postApplePlist(
            url: url,
            body: body,
            clientInfo: clientInfo,
            identity: identity
        )
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: [String: Any]],
        let spim = plist["Response"]?["spim"] as? String else {
            throw AnisetteV3Error.provisioningFailed
        }
        return spim
    }

    private func finishProvisioning(
        at url: URL,
        cpim: String,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> [String: String] {
        let body: [String: [String: Any]] = [
            "Header": [:],
            "Request": ["cpim": cpim]
        ]
        let data = try await postApplePlist(
            url: url,
            body: body,
            clientInfo: clientInfo,
            identity: identity
        )
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: [String: Any]],
        let ptm = plist["Response"]?["ptm"] as? String,
        let tk = plist["Response"]?["tk"] as? String else {
            throw AnisetteV3Error.provisioningFailed
        }
        return ["ptm": ptm, "tk": tk]
    }

    private func postApplePlist(
        url: URL,
        body: [String: [String: Any]],
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> Data {
        var request = appleRequest(
            url: url,
            clientInfo: clientInfo,
            identity: identity
        )
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(
            fromPropertyList: body,
            format: .xml,
            options: 0
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnisetteV3Error.provisioningFailed
        }
        return data
    }

    private func fetchHeaders(
        from server: URL,
        state: AnisetteProvisioningState,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity,
        sim: String? = nil
    ) async throws -> ALTAnisetteData {
        let url = server.appendingPathComponent("v3").appendingPathComponent("get_headers")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = [
            "identifier": state.identifier,
            "adi_pb": state.adiPB
        ]
        if let sim {
            payload["sim"] = sim
            // isideload 对应字段用 `Uuid::to_string` 与 `hex::encode`，均为小写。
            payload["device_id"] = identity.deviceIdentifier.lowercased()
            payload["md_lu"] = identity.localUserID.lowercased()
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            await trace("get_headers 非 2xx：\(server.host ?? "?") status=\((response as? HTTPURLResponse)?.statusCode ?? -1)，body 长度=\(data.count)", level: .warning)
            throw AnisetteV3Error.invalidServerResponse
        }
        let json: [String: String]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                await trace("get_headers 响应不是 JSON 字符串字典", level: .warning)
                throw AnisetteV3Error.invalidServerResponse
            }
            json = value
        } catch let error as AnisetteV3Error {
            throw error
        } catch {
            throw AnisetteV3Error.invalidServerResponse
        }
        if json["result"] == "GetHeadersError" {
            let message = json["message"] ?? "无 message"
            if message.contains("-45061") {
                await trace("get_headers 返回 -45061（ADI 未 provision），判为 staleProvisioning", level: .warning)
                throw AnisetteV3Error.staleProvisioning
            }
            await trace("get_headers 返回 GetHeadersError：\(message)", level: .error)
            throw AnisetteV3Error.provisioningFailed
        }
        await trace("get_headers 成功：拿到 X-Apple-I-MD-M/\(json["X-Apple-I-MD"] != nil ? "MD✓" : "MD✗")/\(json["X-Apple-I-MD-RINFO"] != nil ? "RINFO✓" : "RINFO✗")")

        // 实验中：登录请求声明哪条身份由 experimentalSignInClientInfo 决定；
        // 为 nil 时退回服务器返回的那条（原行为）。
        // 这里同时作用于 `ALTAnisetteData.deviceDescription` —— 它正是 SRP 请求头
        // `X-Mme-Client-Info` 的取值来源，所以两处天然一致。
        let declaredClientInfo = Self.experimentalSignInClientInfo ?? clientInfo.clientInfo

        var formatted: [String: String] = [
            "deviceSerialNumber": "0",
            "deviceDescription": declaredClientInfo,
            // 与 header 值保持同一小写形态，Apple 看到的设备标识在两处一致。
            "localUserID": identity.localUserID.lowercased(),
            "deviceUniqueIdentifier": identity.deviceIdentifier.lowercased(),
            "date": Self.currentDateString(),
            // 固定 en_US：与上面固定的 Windows PC 身份串同属一套声明。
            // 取 Locale.current 会在中文机上得到 zh_CN，与身份串自相矛盾
            // （isideload 的 get_client_provided_data() 同样写死 en_US）。
            "locale": Self.authenticationLocaleIdentifier,
            "timeZone": TimeZone.current.abbreviation() ?? "PST"
        ]
        guard let machineID = json["X-Apple-I-MD-M"],
              let oneTimePassword = json["X-Apple-I-MD"],
              let routingInfo = json["X-Apple-I-MD-RINFO"] else {
            throw AnisetteV3Error.invalidServerResponse
        }
        formatted["machineID"] = machineID
        formatted["oneTimePassword"] = oneTimePassword
        formatted["routingInfo"] = routingInfo
        guard let anisette = ALTAnisetteData(json: formatted) else {
            throw AnisetteV3Error.invalidServerResponse
        }
        return anisette
    }

    private func appleRequest(
        url: URL,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) -> URLRequest {
        var request = URLRequest(url: url)
        // 与 isideload `GrandSlam::base_headers` + `provisioning_headers` 逐项对齐：
        // provisioning 请求同样带 `X-Xcode-Version` / `X-Apple-App-Info`（此前漏发），
        // `Accept` 用 plist 而不是 `*/*`，并且**不发** `X-Apple-I-Client-Time` /
        // `X-Apple-Locale` / `X-Apple-I-TimeZone` —— isideload 把这三个显式注释掉了，
        // 说明刻意不发，Seal 不该多发。
        request.setValue(Self.experimentalSignInClientInfo ?? clientInfo.clientInfo,
                         forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(clientInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue(
            Self.grandSlamAuthenticationXcodeVersion,
            forHTTPHeaderField: "X-Xcode-Version"
        )
        request.setValue(
            Self.grandSlamAuthenticationAppInfo,
            forHTTPHeaderField: "X-Apple-App-Info"
        )
        // 对齐 AltSign 与 iloader(2.3.3)：gsa.apple.com 对复用上次失败留下的 idle
        // 连接敏感（代理/TUN 切换后残留连接再复用会被 Apple 回 503），关键 provisioning
        // 请求每次走新连接。
        request.setValue("close", forHTTPHeaderField: "Connection")
        // isideload 用 `hex::encode` 与 `Uuid::to_string`，两者都是小写；此前用大写
        // 导致与参考实现的 header 值逐字节不一致。
        request.setValue(
            identity.localUserID.lowercased(),
            forHTTPHeaderField: "X-Apple-I-MD-LU"
        )
        request.setValue(
            identity.deviceIdentifier.lowercased(),
            forHTTPHeaderField: "X-Mme-Device-Id"
        )
        return request
    }

    private func websocketURL(for server: URL) throws -> URL {
        guard var components = URLComponents(
            url: server,
            resolvingAgainstBaseURL: false
        ) else {
            throw AnisetteV3Error.invalidServerResponse
        }
        components.scheme = "wss"
        guard let baseURL = components.url else {
            throw AnisetteV3Error.invalidServerResponse
        }
        return baseURL
            .appendingPathComponent("v3")
            .appendingPathComponent("provisioning_session")
    }

    private func send(
        _ values: [String: String],
        through socket: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AnisetteV3Error.provisioningFailed
        }
        try await socket.send(.string(string))
    }

    /// 单次 WebSocket 接收超时并解析为 JSON。
    /// request.timeoutInterval 只约束建连，receive 本身可以无限期挂起；
    /// 挂起时按 provisioning 失败处理，换下一个服务器。
    private func receiveJSON(
        from socket: URLSessionWebSocketTask
    ) async throws -> [String: Any] {
        // URLSessionWebSocketTask 的 Sendable 标注随 SDK 版本不一，用 @unchecked 包装
        // 穿过竞速边界；URLSessionWebSocketTask 本身线程安全。
        final class SendableSocket: @unchecked Sendable {
            let task: URLSessionWebSocketTask
            init(_ task: URLSessionWebSocketTask) { self.task = task }
        }
        let boxed = SendableSocket(socket)
        let text: String
        do {
            text = try await HardTimeout.run(seconds: 20) {
                let message = try await boxed.task.receive()
                switch message {
                case .string(let string):
                    return string
                case .data(let data):
                    return String(decoding: data, as: UTF8.self)
                @unknown default:
                    return ""
                }
            }
        } catch is HardTimeout.TimeoutError {
            throw AnisetteV3Error.provisioningFailed
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw AnisetteV3Error.provisioningFailed
        }
        return json
    }

    private static func currentDateString() -> String {
        return iso8601UTCFormatter.string(from: Date())
    }

    private func prioritizedServers() async -> [AnisetteServer] {
        let selectedID = await serverStore.selectedServerID()
        guard let selectedID,
              let selected = servers.first(where: { $0.id == selectedID }) else {
            return servers
        }
        return [selected] + servers.filter { $0.id != selected.id }
    }
}

struct AnisetteV3ClientInfo: Equatable, Sendable {
    let clientInfo: String
    let userAgent: String
}

typealias AnisetteClient = AnisetteV3Client
