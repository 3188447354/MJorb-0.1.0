import CryptoKit
import Foundation
import os
import AnisetteKit
@preconcurrency import AltSign

struct AnisetteV3Client: AnisetteEnvironmentManaging {
    private static let logger = Logger(subsystem: "com.mjorb.seal", category: "anisette")

    /// Apple 登录边缘只接受「桌面系统、且不是 Xcode」的客户端身份。
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
    /// `X-Xcode-Version` / `X-Apple-App-Info` 的有无不改变结果（同一身份下 200 与 503
    /// 只由客户端身份决定）。同一组对照还确认 provisioning 用的
    /// `GsService2/lookup` 对所有身份都回 200 ⇒ 真机日志里的 `SEAL-NET-503` 只可能
    /// 来自 SRP 阶段，而不是 provisioning。因此 `ani.stikstore.app` 的
    /// `/v3/client_info` 返回的 Xcode 身份不能原样透传，不可用的身份统一替换为
    /// SideInstaller 参考实现固定使用的 macOS/akd 身份。
    static let acceptedFallbackClientInfo = "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    static func acceptedClientInfo(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let isDesktop = lowered.contains("macos") || lowered.contains("windows")
        let isXcode = lowered.contains("com.apple.dt.xcode")
        return (isDesktop && isXcode == false) ? raw : acceptedFallbackClientInfo
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
    private let anisetteProvider: AnisetteDataProvider

    /// 本地 ADI 模拟（Unicorn TCI）冷启动可能超过 45 秒，超时后遗弃但**不取消**任务：
    /// 杀在 provisioning 中途会弄脏 adi.pb，导致之后每次生成都失败。
    /// 遗弃的任务继续在后台完成，后续调用经 inFlight 合并等待其结果。
    private static let localGenerationTimeoutSeconds: TimeInterval = 90
    /// 远程降级的总时长预算：避免服务器逐个重试把添加账号拖到数分钟
    private static let remoteFallbackBudgetSeconds: TimeInterval = 120

    /// 进行中的本地生成任务（引用类型保证 struct 拷贝间共享同一状态）。
    /// ADI/Unicorn 生成有状态（adi.pb、provisioning 会话），**不可并发运行**。
    private final class InFlightGeneration: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<ALTAnisetteData, Error>?

        /// 返回进行中的生成；没有则启动新的（原子性避免并发双开 ADI 实例）。
        func currentOrStart(_ make: () -> Task<ALTAnisetteData, Error>) -> Task<ALTAnisetteData, Error> {
            lock.lock(); defer { lock.unlock() }
            if let task { return task }
            let newTask = make()
            task = newTask
            return newTask
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            task = nil
        }
    }

    private let inFlight = InFlightGeneration()

    init(
        servers: [AnisetteServer] = AnisetteServerCatalog.official,
        session: URLSession = .shared,
        store: (any AnisetteProvisioningStore)? = nil,
        identityStore: (any AnisetteProvisioningStore)? = nil,
        serverStore: any AnisetteServerStore = UserDefaultsAnisetteServerStore(),
        anisetteProvider: AnisetteDataProvider = .shared
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
        self.anisetteProvider = anisetteProvider
    }

    func preferRemoteOnNextFetch() async {
        // 兼容协议调用：远程 v3 已是唯一请求路径，无需切换状态。
    }

    /// 把 App Bundle 中内置的 .so 复制到 AnisetteDataProvider 的可写 libsDir。
    /// Unicorn 引擎 mmap 加载 .so 需要 PROT_WRITE，App Bundle 只读不能直接用。
    private func ensureBundledLibrariesCopied() throws {
        let fm = FileManager.default
        let libDir = anisetteProvider.libsDir
        if LocalAnisetteProvider.validateLibrariesExist(at: libDir) { return }
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        let bundledDir = Bundle.main.bundleURL.appendingPathComponent("Anisette", isDirectory: true)
        for name in LocalAnisetteProvider.requiredLibraryNames {
            let src = bundledDir.appendingPathComponent(name)
            let dst = libDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
    }

    /// 把 AnisetteV3Identity.encodedIdentifier（base64 16字节）解码为 UUID
    private func uuid(from identity: AnisetteV3Identity) throws -> UUID {
        guard let data = Data(base64Encoded: identity.encodedIdentifier), data.count == 16 else {
            throw AnisetteV3Error.invalidIdentifier
        }
        return data.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// 合并进行中的本地生成：超时被遗弃的任务仍在后台运行，重试必须合并等待
    /// 同一任务，而不是并行再起一个 ADI 实例互相污染（表现为 Apple 拒绝 anisette）。
    private func fetchLocalCoalesced(identity: AnisetteV3Identity) async throws -> ALTAnisetteData {
        let inFlight = self.inFlight
        let generation = inFlight.currentOrStart {
            Task { () -> ALTAnisetteData in
                // 完成后（成功或失败）清空合并位；等待者被取消时不影响任务本身
                defer { Task { inFlight.clear() } }
                return try await self.fetchLocal(identity: identity)
            }
        }
        return try await generation.value
    }

    /// 官方 AnisetteData -> AltSign ALTAnisetteData
    private func convert(_ data: AnisetteData) -> ALTAnisetteData? {
        let formatter = Self.iso8601UTCFormatter
        let json: [String: String] = [
            "machineID": data.machineID,
            "oneTimePassword": data.oneTimePassword,
            "localUserID": data.localUserID,
            "deviceUniqueIdentifier": data.deviceUniqueIdentifier,
            "deviceSerialNumber": data.deviceSerialNumber,
            "deviceDescription": data.deviceDescription,
            "routingInfo": String(data.routingInfo),
            "date": formatter.string(from: data.date),
            "locale": data.locale.identifier,
            "timeZone": data.timeZone.abbreviation() ?? "UTC"
        ]
        return ALTAnisetteData(json: json)
    }

    /// 用官方 AnisetteDataProvider localODA 模式生成本地 anisette
    private func fetchLocal(identity: AnisetteV3Identity) async throws -> ALTAnisetteData {
        try ensureBundledLibrariesCopied()
        let uuid = try self.uuid(from: identity)
        // localODA produces Android ADI data. Apple rejects GrandSlam sign-in
        // when that data is presented as a macOS machine, returning -80045.
        // This is the Android AuthKit (akd) profile used end-to-end by the
        // working SideInstaller reference. It must match the CoreADI data,
        // the GrandSlam User-Agent, and the later 2FA requests. Mixing it
        // with the Apple Music/Xcode identities makes Apple reject the SRP
        // exchange before the verification-code UI can appear.
        let clientInfo = "<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

        // 第一次尝试：用 keychain 中已有的 adi.pb
        let existingState = try? await identityStore.load()
        var existingBlob = existingState.flatMap { Data(base64Encoded: $0.adiPB) }

        do {
            let (data, newBlob) = try await anisetteProvider.fetchAnisetteData(
                mode: .localODA(libsDir: anisetteProvider.libsDir),
                identifier: uuid,
                existingAdiBlob: existingBlob,
                clientInfo: clientInfo,
                customLocalUserID: identity.localUserID,
                customDeviceID: identity.deviceIdentifier
            )
            // 保存新的 adi.pb 到 keychain
            if let newBlob, !newBlob.isEmpty,
               let state = AnisetteProvisioningState(identifier: identity.encodedIdentifier, adiPB: newBlob.base64EncodedString()) {
                try? await identityStore.save(state)
            }
            guard let alt = convert(data) else {
                throw AnisetteV3Error.localGenerationFailed("Failed to convert AnisetteData to ALTAnisetteData")
            }
            return alt
        } catch {
            // 如果错误是 "Device not provisioned" (-45061)，说明 keychain 中的 adi.pb 无效或过期
            // 清除旧数据，强制重新 provisioning（需要访问 gsa.apple.com）
            let msg = error.localizedDescription
            if msg.contains("Device not provisioned") || msg.contains("-45061") {
                Self.logger.warning("检测到 Device not provisioned，清除旧 adi.pb 重新 provisioning")
                try? await identityStore.remove()
                existingBlob = nil
                let (data, newBlob) = try await anisetteProvider.fetchAnisetteData(
                    mode: .localODA(libsDir: anisetteProvider.libsDir),
                    identifier: uuid,
                    existingAdiBlob: nil,
                    clientInfo: clientInfo,
                    customLocalUserID: identity.localUserID,
                    customDeviceID: identity.deviceIdentifier
                )
                if let newBlob, !newBlob.isEmpty,
                   let state = AnisetteProvisioningState(identifier: identity.encodedIdentifier, adiPB: newBlob.base64EncodedString()) {
                    try? await identityStore.save(state)
                }
                guard let alt = convert(data) else {
                    throw AnisetteV3Error.localGenerationFailed("Failed to convert AnisetteData to ALTAnisetteData")
                }
                return alt
            }
            throw AnisetteV3Error.localGenerationFailed(error.localizedDescription)
        }
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
        return AnisetteV3ClientInfo(
            clientInfo: Self.acceptedClientInfo(clientInfo),
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
                        adiPB: adiPB
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
            payload["device_id"] = identity.deviceIdentifier
            payload["md_lu"] = identity.localUserID
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
            "localUserID": identity.localUserID,
            "deviceUniqueIdentifier": identity.deviceIdentifier,
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
        request.setValue(clientInfo.clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(clientInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // 对齐 AltSign 与 iloader(2.3.3)：gsa.apple.com 对复用上次失败留下的 idle
        // 连接敏感（代理/TUN 切换后残留连接再复用会被 Apple 回 503），关键 provisioning
        // 请求每次走新连接。
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue(identity.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(identity.deviceIdentifier, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(Self.currentDateString(), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(
            TimeZone.current.abbreviation() ?? "PST",
            forHTTPHeaderField: "X-Apple-I-TimeZone"
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

/// 一次性"跳过本地 Anisette"标志：本地指纹被 Apple 拒绝后，下一次 fetch 直接走远程。
/// 用引用类型 + 锁，保证 struct 跨并发上下文共享同一状态且线程安全。
final class AnisetteBypassFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    /// 读取并复位（只生效一次）
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value = false
        return current
    }
}

typealias AnisetteClient = AnisetteV3Client
