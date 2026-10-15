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

    /// Apple 登录边缘只放行「桌面系统、且不是 Xcode」的客户端身份。
    ///
    /// 实测证据（`GsService2` 的 `o=init` SRP 请求，合成 anisette 占位、只改
    /// `X-Mme-Client-Info`、每次重复 2 遍，只看边缘 HTTP 状态）：
    /// - `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>` → 503 / 503
    /// - `<MacBookPro18,3> <macOS;26.5.2;25F84> <com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>`     → 503 / 503
    /// - `<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`          → 503 / 503
    /// - `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`             → 200 / 200
    /// - `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`                → 200 / 200
    /// - `<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>`          → 200 / 200
    ///
    /// `X-Xcode-Version` / `X-Apple-App-Info` 的有无不改变结果；`GsService2/lookup` 对所有
    /// 身份都回 200 ⇒ `SEAL-NET-503` 只可能来自 SRP 阶段，不是 provisioning。
    ///
    /// REA（SideInstaller 1.5.1 的 isideload 源码）确定真实形态是
    /// **「用服务器返回的身份 + 多服务器兜底」**，不是固定声明某个身份：
    /// `remote_v3/mod.rs:121` 注释写明「本可以硬编码，但 Apple 变化太快，不如直接从
    /// 服务器取」，`:194` 把 `/v3/client_info` 返回值原样当 `device_description`，
    /// `grandslam.rs:220` 的 SRP 头就用它；那条 `<Mac15,7> …` 硬编码只出现在
    /// URL bag 一个请求（`grandslam.rs:59`，注释 "we lie for this request"）。
    /// 实测它内置目录 15 台服务器中 8 台返回 Xcode 身份（边缘必 503）——它靠换服务器
    /// 绕开这些，落到 `ani.sidestore.io` 的
    /// `<MacBookPro13,2> <macOS;13.1;22C65> … com.apple.akd` 上就成功。
    ///
    /// Seal 采用同一形态：身份**原样取服务器返回值**；返回的是必被拒的身份
    ///（Xcode / Android）时判定该服务器不可用、换下一台（复刻 SideInstaller 的
    /// failover），绝不把「必失败的身份」硬发给 Apple。因身份随服务器变化，
    /// ADI 由身份戳保证「建它的身份」与「声明的身份」一致。
    static func identityRejectedByApple(_ clientInfo: String) -> Bool {
        let lowered = clientInfo.lowercased()
        return lowered.contains("com.apple.dt.xcode") || lowered.contains("android")
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

    /// 远程降级的总时长预算：避免服务器逐个重试把添加账号拖到数分钟
    private static let remoteFallbackBudgetSeconds: TimeInterval = 120

    init(
        servers: [AnisetteServer] = AnisetteServerCatalog.official,
        session: URLSession = .shared,
        store: (any AnisetteProvisioningStore)? = nil,
        identityStore: (any AnisetteProvisioningStore)? = nil,
        serverStore: any AnisetteServerStore = UserDefaultsAnisetteServerStore()
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
    }

    /// SideInstaller 的默认策略：认证、验证码、认证后验证和门户请求始终用同一个
    /// 远程 v3 Anisette 会话。不能先用远程取得 authToken、随后切回本机 ADI。
    func fetch() async throws -> ALTAnisetteData {
        let identity = try await loadIdentity()
        return try await fetchRemote(identity: identity)
    }

    func fetchForAuthentication() async throws -> ALTAnisetteData {
        try await fetch()
    }

    func resetProvisioning() async {
        // 只重置远程 v3 provisioning 状态；稳定 identifier 和旧本机 ADI 都不删除。
        try? await remoteStore.remove()
    }

    func resync(sim: String) async throws -> ALTAnisetteData {
        let identity = try await loadIdentity()
        guard let state = try await remoteStore.load() else { throw AnisetteV3Error.staleProvisioning }
        var lastError: Error?
        for server in await prioritizedServers() where server.url.scheme == "https" {
            do {
                let clientInfo = try await fetchClientInfo(from: server.url)
                // 同一条不变量：ADI 只对建它时声明的身份有效。身份戳不匹配就当作
                // provisioning 已失效，交给调用方走完整的 fetch()（会作废重签）。
                guard state.matches(clientInfo: clientInfo.clientInfo) else {
                    throw AnisetteV3Error.staleProvisioning
                }
                return try await fetchHeaders(from: server.url, state: state, clientInfo: clientInfo, identity: identity, sim: sim)
            } catch { lastError = error }
        }
        throw lastError ?? AnisetteV3Error.unavailable
    }

    private func fetchRemote(identity: AnisetteV3Identity) async throws -> ALTAnisetteData {
        let fallbackDeadline = Date().addingTimeInterval(Self.remoteFallbackBudgetSeconds)
        var lastError: Error?
        for server in await prioritizedServers() where server.url.scheme == "https" {
            if Date() > fallbackDeadline {
                break
            }
            do {
                try Task.checkCancellation()
                return try await fetch(from: server.url, identity: identity)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.error("远程 Anisette 服务器 \(server.displayName, privacy: .public) 失败：\(String(describing: error), privacy: .public)")
                lastError = error
            }
        }
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
        let clientInfo = try await fetchClientInfo(from: server)

        if let state = try await remoteStore.load() {
            if state.matches(clientInfo: clientInfo.clientInfo) {
                do {
                    return try await fetchHeaders(
                        from: server,
                        state: state,
                        clientInfo: clientInfo,
                        identity: identity
                    )
                } catch AnisetteV3Error.staleProvisioning,
                        AnisetteV3Error.invalidServerResponse,
                        AnisetteV3Error.provisioningFailed {
                    // 本地 provisioning 失效或服务器响应异常，重置后重新 provision
                    try await remoteStore.remove()
                }
            } else {
                // ADI 只对「建它时声明的那个身份」有效：Apple 对「ADI 与声明系统不一致」
                // 的初始登录直接回 -80045。所以声明身份一变就必须作废重签，而不是继续
                // 复用旧 ADI。旧版本写入的条目没有身份戳（nil），会走这条路径自动迁移。
                try await remoteStore.remove()
            }
        }

        // provision 失败时只报错，不重置 identity
        // identity 是设备标识（deviceUniqueIdentifier/localUserID），与 authToken 绑定
        // 重置会导致所有已登录 Apple ID 全部失效（1100 会话过期）
        let state = try await provision(
            on: server,
            clientInfo: clientInfo,
            identity: identity
        )
        try await remoteStore.save(state)
        return try await fetchHeaders(
            from: server,
            state: state,
            clientInfo: clientInfo,
            identity: identity
        )
    }

    private func loadIdentity() async throws -> AnisetteV3Identity {
        if let encoded = try await identityStore.loadIdentifier(),
           let bytes = Data(base64Encoded: encoded) {
            return try AnisetteV3Identity(bytes: bytes)
        }

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
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnisetteV3Error.invalidServerResponse
        }
        return try Self.parseClientInfo(data: data)
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
        guard
              let clientInfo = json["client_info"] as? String,
              let userAgent = json["user_agent"] as? String,
              clientInfo.isEmpty == false,
              userAgent.isEmpty == false else {
            throw AnisetteV3Error.invalidServerResponse
        }
        // 身份原样取服务器返回值（isideload 同样如此）；但返回的是必被 Apple 拒的
        // 身份（Xcode / Android）时判为「该服务器不可用」，抛错让上层换下一台，
        // 而不是把必失败的身份硬发给 Apple（SideInstaller 靠同款 failover 绕开
        // 15 台目录里那 8 台 Xcode 身份服务器）。
        guard Self.identityRejectedByApple(clientInfo) == false else {
            throw AnisetteV3Error.rejectedIdentity
        }
        return AnisetteV3ClientInfo(
            clientInfo: clientInfo,
            userAgent: userAgent
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
                throw AnisetteV3Error.provisioningFailed
            }

            switch result {
            case "GiveIdentifier":
                try await send(["identifier": identity.encodedIdentifier], through: socket)

            case "GiveStartProvisioningData":
                let spim = try await startProvisioning(
                    at: urls.start,
                    clientInfo: clientInfo,
                    identity: identity
                )
                try await send(["spim": spim], through: socket)

            case "GiveEndProvisioningData":
                guard let cpim = json["cpim"] as? String, cpim.isEmpty == false else {
                    throw AnisetteV3Error.provisioningFailed
                }
                let endData = try await finishProvisioning(
                    at: urls.end,
                    cpim: cpim,
                    clientInfo: clientInfo,
                    identity: identity
                )
                try await send(endData, through: socket)

            case "ProvisioningSuccess":
                guard let adiPB = json["adi_pb"] as? String,
                      let state = AnisetteProvisioningState(
                        identifier: identity.encodedIdentifier,
                        adiPB: adiPB,
                        clientInfo: clientInfo.clientInfo
                      ) else {
                    throw AnisetteV3Error.provisioningFailed
                }
                return state

            default:
                if result.contains("Error") || result.contains("Invalid") ||
                    result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                    throw AnisetteV3Error.provisioningFailed
                }
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
            throw AnisetteV3Error.provisioningFailed
        }
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
            throw AnisetteV3Error.invalidServerResponse
        }
        let json: [String: String]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw AnisetteV3Error.invalidServerResponse
            }
            json = value
        } catch let error as AnisetteV3Error {
            throw error
        } catch {
            throw AnisetteV3Error.invalidServerResponse
        }
        if json["result"] == "GetHeadersError" {
            if json["message"]?.contains("-45061") == true {
                throw AnisetteV3Error.staleProvisioning
            }
            throw AnisetteV3Error.provisioningFailed
        }

        var formatted: [String: String] = [
            "deviceSerialNumber": "0",
            "deviceDescription": clientInfo.clientInfo,
            // 与 header 值保持同一小写形态，Apple 看到的设备标识在两处一致。
            "localUserID": identity.localUserID.lowercased(),
            "deviceUniqueIdentifier": identity.deviceIdentifier.lowercased(),
            "date": Self.currentDateString(),
            "locale": Locale.current.identifier,
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
        request.setValue(clientInfo.clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
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
