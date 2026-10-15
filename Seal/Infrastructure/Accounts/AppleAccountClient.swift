import Foundation
@preconcurrency import AltSign

enum AppleAuthenticationStage: Sendable {
    case signIn
    case teamLookup
}

enum AppleAuthenticationFailure {
    static func make(stage: AppleAuthenticationStage, error: Error) -> ImportFailure {
        // 双重认证要排在**最前**：它是最具体的诊断（Apple 已经接受了密码，只是要求第二步），
        // 而 3018 既不是限流也不是网络错误 ⇒ 放在后面只会被泛化文案吃掉，
        // 真机上就是这样把用户引去「核对 Apple ID 与密码」的。
        if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {
            return AppleAuthenticationDiagnosis.twoFactorFailure(for: error)
        }
        if AppleServiceFailurePolicy.isTemporaryAuthenticationRejection(error) {
            return AppleServiceFailurePolicy.temporaryAuthenticationRejectionFailure(
                underlying: error,
                operation: .authenticateAccount
            )
        }
        if AppleServiceFailurePolicy.isRateLimited(error) {
            return AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)
        }
        if AppleServiceFailurePolicy.isNetworkError(error) {
            return AppleServiceFailurePolicy.networkFailure(
                underlying: error,
                operation: .authenticateAccount
            )
        }
        switch stage {
        case .signIn:
            return ImportFailure(
                title: "无法添加账号",
                reason: "Apple ID 验证失败。\n\(AppleAuthenticationDiagnosis.detail(for: error))",
                recovery: "重试",
                code: "SEAL-AUTH-107a"
            )
        case .teamLookup:
            return ImportFailure(
                title: "无法添加账号",
                reason: "验证码已接受，但 Apple 没有返回可用的开发团队。",
                recovery: "重试",
                code: "SEAL-AUTH-105f",
                condition: .developerTeamLookupFailed,
                action: .retry,
                retryDisposition: .manual,
                operation: .authenticateAccount,
                origin: .applePortal
            )
        }
    }
}

@MainActor
final class AppleAccountClient {
    private let anisetteProvider: any AnisetteProvider
    /// 全量操作日志：登录每个阶段（取 anisette、SRP、SIM resync、team 查询）都留痕。
    private let logStore: SealLogStore?

    /// Apple Developer Portal 请求所使用的 X-Xcode-Version。
    nonisolated static let xcodeVersion = "26.0"

    nonisolated init(
        anisetteProvider: any AnisetteProvider = AnisetteV3Client(),
        logStore: SealLogStore? = nil
    ) {
        self.anisetteProvider = anisetteProvider
        self.logStore = logStore
    }

    /// 写一条登录操作日志（脱敏由 SealLogStore 保证）。
    private nonisolated func trace(
        _ message: String,
        level: SealLogEntry.Level = .info
    ) async {
        try? await logStore?.append(category: .account, level: level, message: "[auth] \(message)")
    }

    func authenticate(
        email: String,
        password: String,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> AuthenticatedAppleAccount {
        // SideInstaller 使用远程 v3 Anisette 完成认证；Seal 必须让验证码、登录后验证
        // 和后续门户请求持续使用同一份远程会话，不能认证后切回本机 ADI。
        // 旧本机 ADI 与 identifier 均保留，远程 provisioning 状态独立保存。
        try await withTimeout(seconds: 240) {
            try await self.authenticateOnce(
                email: email,
                password: password,
                verificationCode: verificationCode
            )
        }
    }

    /// 只识别 Apple 明确声明为无效 Anisette 的错误。
    ///
    /// GrandSlam 的 HTML 503 只是 Apple 登录边缘返回的服务错误，不能借此
    /// 推断本机 Anisette 损坏，更不能引导用户清理签名环境。
    private nonisolated static func shouldRetryWithRemoteAnisette(_ error: Error) -> Bool {
        if case ALTAppleAPIError.invalidAnisetteData = error { return true }
        return false
    }

    /// 把错误压缩成一行，便于日志归因（脱敏由 SealLogStore 兜底）。
    private nonisolated static func describeError(_ error: Error) -> String {
        if let importFailure = error as? ImportFailure {
            return "ImportFailure(\(importFailure.code))"
        }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    /// Apple 认证/团队请求直接发出。服务端暂不可用由统一失败策略如实呈现，
    /// 不把它猜测成网络出口或账号状态问题。
    private static func directAppleRequest<T>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        try await operation()
    }

    /// 给异步操作加超时，超时后抛出超时错误。
    /// 认证可能卡在无法协作取消的调用里（本地 ADI 模拟、AltSign 内部回调），
    /// 因此必须用可遗弃竞速：超时先到就抛错，未完成的认证在后台自行结束后被丢弃。
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await HardTimeout.run(seconds: seconds, operation)
        } catch let error as HardTimeout.TimeoutError {
            // 必须以 ImportFailure 抛出，否则上层 addAccount 的兜底 catch
            // 会把超时改写成误导性的“Apple ID 验证失败”。
            throw ImportFailure(
                title: "添加账号超时",
                reason: "Apple 认证在 \(Int(error.seconds)) 秒内没有完成。",
                recovery: "等待片刻后重新添加账号",
                code: "SEAL-AUTH-107t",
                condition: .authenticationTimedOut,
                action: .waitThenRetry,
                retryDisposition: .manual,
                operation: .authenticateAccount,
                origin: .authentication
            )
        }
    }

    /// 自动重新登录（authToken 失效 1100 时使用）
    /// verificationCode 闭包在需要双重验证码时被调用，返回用户输入的验证码；返回 nil 表示取消
    func reauthenticate(
        email: String,
        password: String,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> AccountSecret {
        let anisetteData = try await anisetteProvider.fetchForAuthentication()
        let auth = try await authenticate(
            email: email,
            password: password,
            anisetteData: anisetteData,
            verificationCode: verificationCode
        ).value
        return AccountSecret(
            email: email,
            accountIdentifier: auth.account.identifier,
            dsid: auth.session.dsid,
            authToken: auth.session.authToken,
            password: password
        )
    }

    private func authenticateOnce(
        email: String,
        password: String,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> AuthenticatedAppleAccount {
        var stage: AppleAuthenticationStage = .signIn
        do {
            try Task.checkCancellation()
            await trace("阶段 signIn：取 anisette 环境数据")
            let anisetteData = try await anisetteProvider.fetchForAuthentication()
            await trace("anisette 就绪，声明身份=\(anisetteData.deviceDescription)")
            let auth: AuthObjects
            do {
                await trace("发起 GrandSlam SRP 登录")
                auth = try await self.authenticate(email: email, password: password, anisetteData: anisetteData, verificationCode: verificationCode).value
                await trace("SRP 登录成功，进入 team 查询")
            } catch {
                let detail = Self.describeError(error)

                if let sim = Self.resyncSIM(from: error) {
                    // Apple 要求 anisette 重新同步（Status.hsc == 434，附 SIM）。
                    await trace("SRP 登录要求 SIM 同步（sim 长度=\(sim.count)），resync 后重试一次", level: .warning)
                    let resyncedAnisetteData = try await anisetteProvider.resync(sim: sim)
                    await trace("resync 完成，重发 SRP")
                    auth = try await self.authenticate(email: email, password: password, anisetteData: resyncedAnisetteData, verificationCode: verificationCode).value
                    await trace("resync 后 SRP 登录成功")
                } else if AppleServiceFailurePolicy.isTemporaryAuthenticationRejection(error) {
                    // ── -80045：自动作废 ADI、重新 provisioning，再重试一次 ──────────
                    //
                    // -80045 是「Apple 暂时拒绝了登录请求」，而请求形态已逐条对齐
                    // isideload：cpd 六字段一致（bootstrap / icscrec / loc / pbe /
                    // prkgen / svct，加三个 anisette 头）、请求头一致（Content-Type /
                    // Accept / X-Mme-Client-Info / User-Agent / X-Xcode-Version /
                    // X-Apple-App-Info / Connection: close）、声明身份一致（实测 10 台
                    // 公共 anisette 服务器都返回 <MacBookPro13,2> <macOS;13.1;22C65>
                    // … com.apple.akd，Seal 原样使用）。
                    //
                    // 剩下的变量只有本地那份缓存的 ADI：日志一直显示
                    // 「ADI 命中：已有 ADI 的身份戳与本次声明身份一致，复用」，
                    // 也就是从不重新 provisioning；而 isideload 在 -45061 时会重签。
                    // 若那份 ADI 坏了、或它对应的标识曾被 Apple 标记过，-80045 就能解释
                    // 得通，也能解释为什么与账号无关（爱思用同一账号能过，因为它完全不
                    // 用这份 ADI）。
                    //
                    // **只清 remoteStore（ADI），绝不动 identityStore（identifier）**：
                    // identifier 与 authToken 绑定，清它会让所有已登录 ID 掉线并触发
                    // 2FA —— 源码注释明确记载过该路径"曾造成严重回归"。
                    // resetProvisioning 恰好只删 remoteStore，所以直接复用。
                    //
                    // 只重试一次：这既不是限流（不该连打），也不保证可恢复；
                    // 重试仍失败就把错误抛出，交由上层按 SEAL-AUTH-80045 呈现。
                    await trace("SRP 登录失败（无 SIM 同步指令）：\(detail)", level: .error)
                    await trace("检测到 -80045：作废远程 ADI 并重新 provisioning，随后重试一次", level: .warning)
                    await anisetteProvider.resetProvisioning()
                    let reprovisioned = try await anisetteProvider.fetchForAuthentication()
                    await trace("ADI 已重签，声明身份=\(reprovisioned.deviceDescription)，重发 SRP")
                    auth = try await self.authenticate(
                        email: email,
                        password: password,
                        anisetteData: reprovisioned,
                        verificationCode: verificationCode
                    ).value
                    await trace("ADI 重签后 SRP 登录成功")
                } else {
                    await trace("SRP 登录失败（无 SIM 同步指令）：\(detail)", level: .error)
                    throw error
                }
            }
            try Task.checkCancellation()
            stage = .teamLookup
            let teams = try await Self.directAppleRequest {
                try await self.fetchTeams(
                    account: auth.account,
                    session: auth.session
                )
            }
            try Task.checkCancellation()
            let availableTeams = teams
                .filter { $0.type != .unknown }
                .map {
                    AppleTeamRecord(
                        id: $0.identifier,
                        name: $0.name,
                        isFreeTeam: $0.type == .free
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isFreeTeam != rhs.isFreeTeam { return lhs.isFreeTeam == false }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard availableTeams.isEmpty == false else {
                throw ImportFailure(
                    title: "未找到开发者团队",
                    reason: "这个 Apple ID 没有可用的开发者团队（免费账号也会自动创建免费团队）。",
                    recovery: "确认该 Apple ID 已在 Apple 开发者网站同意协议，或更换其他 Apple ID",
                    code: "SEAL-AUTH-103"
                )
            }

            let secret = AccountSecret(
                email: email,
                accountIdentifier: auth.account.identifier,
                dsid: auth.session.dsid,
                authToken: auth.session.authToken,
                password: password
            )
            return AuthenticatedAppleAccount(
                maskedEmail: Self.mask(email),
                accountIdentifier: auth.account.identifier,
                teams: availableTeams,
                secret: secret,
                verifiedAt: Date()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ALTAppleAPIError.incorrectVerificationCode {
            throw ImportFailure(
                title: "无法添加账号",
                reason: "Apple 拒绝了当前验证码（验证码无效或已过期）。",
                recovery: "获取最新验证码后重新输入",
                code: "SEAL-AUTH-101",
                condition: .verificationCodeRejected,
                action: .enterNewVerificationCode,
                route: .account,
                retryDisposition: .manual,
                operation: .authenticateAccount,
                origin: .authentication
            )
        } catch ALTAppleAPIError.incorrectCredentials {
            throw ImportFailure(
                title: "无法添加账号",
                reason: "Apple 拒绝了账号 \(Self.mask(email)) 的登录凭据（Apple ID 不存在或密码错误）。",
                recovery: "核对 Apple ID 与密码后重试；忘记密码请先到 Apple 官网重置",
                code: "SEAL-AUTH-102a",
                condition: .credentialsRejected,
                action: .reauthenticateAccount,
                route: .account,
                retryDisposition: .manual,
                operation: .authenticateAccount,
                origin: .authentication
            )
        } catch ALTAppleAPIError.invalidAnisetteData {
            throw ALTAppleAPIError(.invalidAnisetteData)
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            if AppleServiceFailurePolicy.isRateLimited(error) {
                throw AppleServiceFailurePolicy.rateLimitedFailure(
                    underlying: error
                )
            }
            // Apple 明确判 Anisette 无效时：
            // 不做任何自动重置（machineID 变化会让已登录账号全部掉线），
            // 以明确的错误呈现，由用户决定是否手动重置签名环境。
            if Self.shouldRetryWithRemoteAnisette(error) {
                let underlying = (error as NSError).localizedDescription
                throw ImportFailure(
                    title: "无法添加账号",
                    reason: "Apple 拒绝了本次认证使用的设备环境数据（Anisette）。\n底层错误：\(underlying)",
                    recovery: "重试；如持续失败，到「我的」页面手动重置签名环境（会导致已登录 ID 需重新验证）",
                    code: "SEAL-ANI-115"
                )
            }
            // Apple 拒绝认证握手，通常与 Anisette 设备环境数据无效有关，
            // 而不是用户网络问题，必须与“验证失败/网络”区分开。
            if let apiError = error as? ALTAppleAPIError,
               case .authenticationHandshakeFailed = apiError {
                let underlying = (apiError as NSError).localizedDescription
                throw ImportFailure(
                    title: "无法添加账号",
                    reason: "Apple 拒绝了本次认证握手。\n底层错误：\(underlying)",
                    recovery: "稍后重新添加账号",
                    code: "SEAL-AUTH-107h",
                    condition: .authenticationHandshakeRejected,
                    action: .waitThenRetry,
                    retryDisposition: .manual,
                    operation: .authenticateAccount,
                    origin: .authentication
                )
            }
            if error is AnisetteV3Error {
                throw Self.failure(from: error)
            }
            throw AppleAuthenticationFailure.make(stage: stage, error: error)
        }
    }

    func validate(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws {
        do {
            try Task.checkCancellation()
            let anisetteData = try await anisetteProvider.fetch()
            let session = ALTAppleAPISession(
                dsid: secret.dsid,
                authToken: secret.authToken,
                anisetteData: anisetteData,
                xcodeVersion: Self.xcodeVersion
            )
            let altAccount = ALTAccount()
            altAccount.appleID = secret.email
            altAccount.identifier = secret.accountIdentifier
            let teams = try await fetchTeams(account: altAccount, session: session)
            try Task.checkCancellation()
            guard teams.contains(where: { $0.identifier == account.teamID }) else {
                throw ImportFailure(
                    title: "Team 不可用",
                    reason: "当前 Apple ID 已无法访问之前保存的 Team（Apple 返回的团队列表中已找不到该 Team）。",
                    recovery: "选择 Team",
                    code: "SEAL-AUTH-112a"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch ALTAppleAPIError.incorrectCredentials {
            throw ImportFailure(
                title: "Apple ID 需要重新验证",
                reason: "Apple 已明确拒绝当前登录凭据。",
                recovery: "重新验证 Apple ID",
                code: "SEAL-AUTH-102b",
                condition: .credentialsRejected,
                action: .reauthenticateAccount,
                route: .account,
                retryDisposition: .manual,
                operation: .validateAccount,
                origin: .authentication
            )
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            // 第三个映射入口。本函数走的是**已存 session**（不重新用密码登录），
            // 正常情况下 Apple 不会在这里要求双重认证 —— 但 session 失效时确实可能。
            // 三个入口用同一个工厂、同一个优先级顺序：这条规则一旦在某条链路上漏掉，
            // 不崩、不编译失败，只在真机上把用户引向「反复重试」。
            if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {
                throw AppleAuthenticationDiagnosis.twoFactorFailure(for: error)
            }
            if AppleServiceFailurePolicy.isTemporaryAuthenticationRejection(error) {
                throw AppleServiceFailurePolicy.temporaryAuthenticationRejectionFailure(
                    underlying: error,
                    operation: .validateAccount
                )
            }
            if AppleServiceFailurePolicy.isRateLimited(error) {
                throw AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)
            }
            if AppleServiceFailurePolicy.isNetworkError(error) {
                throw AppleServiceFailurePolicy.networkFailure(
                    underlying: error,
                    operation: .validateAccount
                )
            }
            let nsError = error as NSError
            throw ImportFailure(
                title: "无法验证 Apple ID",
                reason: "Apple 验证返回了无法分类的错误，账号状态未改变。",
                recovery: "稍后重试；如持续失败再重新验证 Apple ID",
                code: "SEAL-VERIFY-500a",
                condition: .unexpected,
                action: .waitThenRetry,
                retryDisposition: .manual,
                operation: .validateAccount,
                origin: .authentication
            )
        }
    }

    nonisolated static func mask(_ appleID: String) -> String {
        let trimmedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAppleID.isEmpty == false else { return "***" }

        if trimmedAppleID.contains("@") {
            return maskEmail(trimmedAppleID)
        }

        if isPhoneNumber(trimmedAppleID) {
            return maskPhone(trimmedAppleID)
        }

        return maskPlainIdentifier(trimmedAppleID)
    }

    private nonisolated static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return maskPlainIdentifier(email) }

        let localPart = parts[0]
        let domain = parts[1]
        guard localPart.isEmpty == false, domain.isEmpty == false else {
            return maskPlainIdentifier(email)
        }
        return "\(maskPlainIdentifier(localPart))@\(domain)"
    }

    private nonisolated static func maskPhone(_ value: String) -> String {
        let hasCountryPrefix = value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")
        let digits = String(value.filter { $0.isNumber })
        guard digits.count >= 6 else { return maskPlainIdentifier(value) }

        if hasCountryPrefix,
           let countryCodeLength = countryCodeLength(in: digits),
           digits.count > countryCodeLength {
            let countryCode = String(digits.prefix(countryCodeLength))
            let nationalNumber = String(digits.dropFirst(countryCodeLength))
            return "+\(countryCode) \(maskPhoneNationalNumber(nationalNumber))"
        }

        return maskPhoneNationalNumber(digits)
    }

    private nonisolated static func maskPhoneNationalNumber(_ digits: String) -> String {
        let characters = Array(digits)
        switch characters.count {
        case 0:
            return "***"
        case 1...5:
            return maskPlainIdentifier(digits)
        case 6...7:
            let prefix = String(characters.prefix(2))
            let suffix = String(characters.suffix(2))
            return "\(prefix)****\(suffix)"
        case 8:
            let prefix = String(characters.prefix(3))
            let suffix = String(characters.suffix(3))
            return "\(prefix)****\(suffix)"
        default:
            let prefix = String(characters.prefix(3))
            let suffix = String(characters.suffix(4))
            return "\(prefix)****\(suffix)"
        }
    }

    private nonisolated static func maskPlainIdentifier(_ identifier: String) -> String {
        let characters = Array(identifier)
        switch characters.count {
        case 0:
            return "***"
        case 1...3:
            return "\(characters[0])***"
        case 4...5:
            let prefix = String(characters.prefix(2))
            let suffix = String(characters.suffix(1))
            return "\(prefix)***\(suffix)"
        default:
            let prefix = String(characters.prefix(3))
            let suffix = String(characters.suffix(2))
            return "\(prefix)***\(suffix)"
        }
    }

    private nonisolated static func isPhoneNumber(_ value: String) -> Bool {
        let digits = value.filter { $0.isNumber }
        guard digits.count >= 6 else { return false }

        let allowedCharacters = CharacterSet(charactersIn: "+0123456789 -()")
        return value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private nonisolated static func countryCodeLength(in digits: String) -> Int? {
        let knownCountryCodes: Set<String> = [
            "1", "7",
            "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
            "52", "55", "60", "61", "62", "63", "64", "65", "66", "81", "82", "84", "86", "90", "91", "92", "93", "94", "95", "98",
            "212", "213", "216", "218", "234", "351", "352", "353", "354", "355", "356", "357", "358", "359",
            "370", "371", "372", "373", "374", "375", "376", "377", "380", "381", "382", "383", "385", "386", "387", "389",
            "420", "421", "852", "853", "855", "856", "886", "960", "961", "962", "963", "964", "965", "966", "967", "968",
            "971", "972", "973", "974", "975", "976", "977", "992", "993", "994", "995", "996", "998"
        ]

        for length in stride(from: min(3, digits.count - 1), through: 1, by: -1) {
            let candidate = String(digits.prefix(length))
            if knownCountryCodes.contains(candidate) {
                return length
            }
        }

        guard digits.count > 10 else { return nil }
        return min(3, max(1, digits.count - 10))
    }

    private func authenticate(
        email: String,
        password: String,
        anisetteData: ALTAnisetteData,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> LegacyBox<AuthObjects> {
        try await Self.authenticateWithAPI(
            email: email,
            password: password,
            anisetteData: anisetteData,
            verificationCode: verificationCode
        )
    }

    private nonisolated static func authenticateWithAPI(
        email: String,
        password: String,
        anisetteData: ALTAnisetteData,
        verificationCode: @escaping @MainActor @Sendable () async -> String?
    ) async throws -> LegacyBox<AuthObjects> {
        try await withCheckedThrowingContinuation { continuation in
            let callback = LegacyCallbackBox(continuation)
            ALTAppleAPI.shared.authenticate(
                appleID: email,
                password: password,
                anisetteData: anisetteData,
                xcodeVersion: Self.xcodeVersion,
                verificationHandler: { response in
                    let reply = VerificationReply(response)
                    Task { @MainActor in
                        reply.send(await verificationCode())
                    }
                }
            ) { account, session, error in
                if let account, let session {
                    callback.resume(
                        returning: LegacyBox(
                            AuthObjects(account: account, session: session)
                        )
                    )
                } else {
                    callback.resume(
                        throwing: error ?? URLError(.userAuthenticationRequired)
                    )
                }
            }
        }
    }

    private func fetchTeams(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        try await Self.fetchTeamsWithAPI(account: account, session: session)
    }

    private nonisolated static func fetchTeamsWithAPI(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        let box: LegacyBox<[ALTTeam]> = try await withCheckedThrowingContinuation {
            continuation in
            let callback = LegacyCallbackBox(continuation)
            ALTAppleAPI.shared.fetchTeams(for: account, session: session) { teams, error in
                if let teams {
                    callback.resume(returning: LegacyBox(teams))
                } else {
                    callback.resume(
                        throwing: error ?? URLError(.badServerResponse)
                    )
                }
            }
        }
        return box.value
    }

    /// 纯函数：只做错误分类，不加锁不碰 UI 状态；
    /// 需要 nonisolated 以便从 withTimeout 的 @Sendable 闭包调用
    nonisolated static func failure(from error: Error) -> ImportFailure {
        if let anisetteError = error as? AnisetteV3Error {
            switch anisetteError {
            case .invalidIdentifier, .invalidServerResponse:
                return ImportFailure(
                    title: "无法获取设备环境",
                    reason: "Apple 拒绝了当前的设备标识（Anisette 无效或服务器响应异常）。",
                    recovery: "重试",
                    code: "SEAL-ANI-110",
                    condition: .authenticationEnvironmentRejected,
                    action: .retry,
                    retryDisposition: .manual,
                    operation: .authenticateAccount,
                    origin: .authentication
                )
            case .provisioningFailed:
                return ImportFailure(
                    title: "无法获取设备环境",
                    reason: "Anisette 设备信息（provisioning）生成失败。",
                    recovery: "重试",
                    code: "SEAL-ANI-111",
                    condition: .authenticationEnvironmentUnavailable,
                    action: .retry,
                    retryDisposition: .manual,
                    operation: .authenticateAccount,
                    origin: .authentication
                )
            case .staleProvisioning:
                return ImportFailure(
                    title: "无法获取设备环境",
                    reason: "Anisette 设备信息（provisioning）已过期，请重新生成。",
                    recovery: "重试",
                    code: "SEAL-ANI-112",
                    condition: .authenticationEnvironmentUnavailable,
                    action: .retry,
                    retryDisposition: .manual,
                    operation: .authenticateAccount,
                    origin: .authentication
                )
            case .unavailable:
                return ImportFailure(
                    title: "无法获取设备环境",
                    reason: "Anisette 服务当前不可用。",
                    recovery: "稍后重试",
                    code: "SEAL-ANI-113",
                    condition: .authenticationEnvironmentServiceUnavailable,
                    action: .waitThenRetry,
                    retryDisposition: .manual,
                    operation: .authenticateAccount,
                    origin: .authentication
                )
            case .rejectedIdentity:
                return ImportFailure(
                    title: "无法获取设备环境",
                    reason: "Anisette 服务器返回的客户端身份不可用，已跳过该服务器重试。",
                    recovery: "重试",
                    code: "SEAL-ANI-110",
                    condition: .authenticationEnvironmentRejected,
                    action: .retry,
                    retryDisposition: .manual,
                    operation: .authenticateAccount,
                    origin: .authentication
                )
            }
        }
        // 双重认证必须排在**限流/网络之前**，与 `AppleAuthenticationFailure.make` 的
        // 顺序保持一致（两处顺序不同 = 同一个错误在两条路径上给出不同提示，
        // 而这类漂移不崩、不编译失败）。`isRateLimited` 只看 503 文案，理论上不会吞掉
        // 3018，但「靠另一个判据恰好不命中」不是设计，顺序本身就是设计。
        if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {
            return AppleAuthenticationDiagnosis.twoFactorFailure(for: error)
        }
        if AppleServiceFailurePolicy.isTemporaryAuthenticationRejection(error) {
            return AppleServiceFailurePolicy.temporaryAuthenticationRejectionFailure(
                underlying: error,
                operation: .authenticateAccount
            )
        }
        if AppleServiceFailurePolicy.isRateLimited(error) {
            return AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)
        }
        if AppleServiceFailurePolicy.isNetworkError(error) {
            return AppleServiceFailurePolicy.networkFailure(
                underlying: error,
                operation: .authenticateAccount
            )
        }
        let nsError = error as NSError
        let isVerificationFailure = nsError.localizedDescription
            .localizedCaseInsensitiveContains("verification")
        let detail = AppleAuthenticationDiagnosis.detail(for: error)
        let baseReason = isVerificationFailure ? "Apple 拒绝了当前验证码（验证码无效或已过期）" : "Apple ID 验证失败"
        return ImportFailure(
            title: "无法添加账号",
            reason: "\(baseReason)\n\(detail)",
            recovery: isVerificationFailure ? "获取最新验证码后重试" : "重试；如持续失败请核对 Apple ID 与密码",
            code: isVerificationFailure ? "SEAL-AUTH-101" : "SEAL-AUTH-107a"
        )
    }

    private nonisolated static func resyncSIM(from error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == ALTUnderlyingAppleAPIErrorDomain else { return nil }
        // The SIM itself is Apple's resync instruction. Some current replies
        // omit `hsc`, so requiring the legacy 434 marker drops a valid resync.
        if let sim = ns.userInfo["ALTAppleAPIResyncSIM"] as? String { return sim }
        if let sim = ns.userInfo["ALTAppleAPIResyncSIM"] as? Data { return sim.base64EncodedString() }
        return nil
    }
}

private struct AuthObjects {
    let account: ALTAccount
    let session: ALTAppleAPISession
}

struct LegacyBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class VerificationReply: @unchecked Sendable {
    private let response: (String?) -> Void

    init(_ response: @escaping (String?) -> Void) {
        self.response = response
    }

    func send(_ code: String?) {
        response(code)
    }
}

private final class LegacyCallbackBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
