import Foundation

enum AppleServiceFailurePolicy {
    /// Apple APIError -80045: "This action cannot be completed at this time."
    ///
    /// The code alone only establishes that Apple temporarily rejected this
    /// request. It does not establish an incorrect password, a locked account,
    /// or a device-specific restriction.
    static let temporaryAuthenticationRejectionCode = -80045

    /// GrandSlam codes SideSign identifies as authentication/2FA throttling.
    /// These must not enter the automatic 503 retry loop.
    private static let authenticationRateLimitCodes: Set<Int> = [-22411, -21668, -20102]

    static func isNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return networkCodes.contains(urlError.code)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            if networkCodes.contains(code) {
                return true
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isNetworkError(underlying) {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return networkFragments.contains(where: message.contains)
    }

    /// 传输失败的归因结果：先分清失败发生在 anisette 候选链还是 Apple 门户链，
    /// 再决定错误码与文案，避免把本机网络问题说成 Apple 开发者服务的问题。
    enum TransportFailureAttribution: Equatable, Sendable {
        /// anisette 候选服务器全部以网络错误终局（带来源标记）。
        case anisetteServersUnreachable
        /// 与 Apple 开发者服务之间的请求传输失败。
        case appleDeveloperServiceUnreachable
        /// 不是已知的传输失败。
        case notTransportFailure
    }

    /// 纯函数归因：输入错误特征，输出归因枚举（可单测，不碰网络/UI）。
    ///
    /// 顺序即设计：来源标记（`AnisetteAllServersNetworkFailure`）比泛化的
    /// `isNetworkError` 更具体，必须先判；裸网络错误仍按 Apple 门户传输失败处理，
    /// 保持 `SEAL-NET-102` 的既有口径不变。
    static func transportAttribution(for error: Error) -> TransportFailureAttribution {
        if isAnisetteAllServersNetworkFailure(error) {
            return .anisetteServersUnreachable
        }
        if isNetworkError(error) {
            return .appleDeveloperServiceUnreachable
        }
        return .notTransportFailure
    }

    static func isAnisetteAllServersNetworkFailure(_ error: Error) -> Bool {
        if error is AnisetteAllServersNetworkFailure {
            return true
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isAnisetteAllServersNetworkFailure(underlying)
        }
        return false
    }

    /// anisette 候选全灭（本机网络不可达）的专属失败：文案只讲用户能核对的事实
    /// （服务全部连不上、通常是当前网络暂时不可用），不提 Apple 开发者服务。
    static func anisetteServersUnreachableFailure(
        underlying _: Error? = nil,
        operation: FailureOperation = .unknown,
        origin: FailureOrigin = .authentication
    ) -> ImportFailure {
        ImportFailure(
            title: "暂时连不上网络",
            reason: "获取登录环境数据的服务全部无法连接，通常是当前网络暂时不可用。",
            recovery: "检查网络连接后稍后重试",
            code: "SEAL-ANI-116",
            condition: .authenticationEnvironmentServiceUnavailable,
            action: .retry,
            retryDisposition: .manual,
            operation: operation,
            origin: origin
        )
    }

    static func networkFailure(
        underlying _: Error? = nil,
        title: String = "Apple 请求未完成",
        reason: String = "与 Apple 开发者服务的请求未完成。已保存的 Apple ID 状态未改变。",
        recovery: String = "稍后重试",
        code: String = "SEAL-NET-101",
        operation: FailureOperation = .unknown
    ) -> ImportFailure {
        ImportFailure(
            title: title,
            reason: reason,
            recovery: recovery,
            code: code,
            condition: .appleRequestTransportUnavailable,
            action: .retry,
            retryDisposition: .manual,
            operation: operation,
            origin: .applePortal
        )
    }

    /// Apple 服务端返回 503 或明确的暂不可用提示。
    ///
    /// 这只能证明服务暂时无法处理请求，不能推断用户的网络线路、地区或节点原因。
    static func isRateLimited(_ error: Error) -> Bool {
        let ns = error as NSError
        if messageIndicates503(ns.localizedDescription) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error,
           isRateLimited(underlying) { return true }
        return false
    }

    /// 503 专属失败：让用户稍后重试，不把未知的网络成因伪装成确定结论。
    static func rateLimitedFailure(underlying _: Error? = nil) -> ImportFailure {
        ImportFailure(
            title: "Apple 服务暂时不可用",
            reason: "Apple 开发者服务暂时无法处理请求。",
            recovery: "稍后重试",
            code: "SEAL-NET-503",
            condition: .appleServiceUnavailable,
            action: .waitThenRetry,
            retryDisposition: .manual,
            origin: .applePortal
        )
    }

    static func isTemporaryAuthenticationRejection(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "Apple.APIError",
           nsError.code == temporaryAuthenticationRejectionCode {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTemporaryAuthenticationRejection(underlying)
        }
        return false
    }

    static func isAuthenticationRateLimited(_ error: Error) -> Bool {
        authenticationRateLimitCode(in: error) != nil
    }

    private static func authenticationRateLimitCode(in error: Error) -> Int? {
        let nsError = error as NSError
        if nsError.domain == "Apple.APIError",
           authenticationRateLimitCodes.contains(nsError.code) {
            return nsError.code
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return authenticationRateLimitCode(in: underlying)
        }
        return nil
    }

    static func authenticationRateLimitFailure(
        underlying error: Error,
        operation: FailureOperation = .authenticateAccount
    ) -> ImportFailure {
        let code = authenticationRateLimitCode(in: error) ?? (error as NSError).code
        return ImportFailure(
            title: "登录验证暂时受限",
            reason: "Apple 暂时拒绝了这次登录验证（错误码 \(code)），不代表密码错误或账号异常。你可以立即重试；如果仍失败，请稍后再试或换用其他 Apple ID。",
            recovery: "立即重试",
            code: "SEAL-AUTH-RATE-LIMITED",
            condition: .appleRateLimited,
            action: .retry,
            retryDisposition: .manual,
            operation: operation,
            origin: .authentication
        )
    }

    static func temporaryAuthenticationRejectionFailure(
        underlying _: Error? = nil,
        operation: FailureOperation = .authenticateAccount,
        origin: FailureOrigin = .authentication
    ) -> ImportFailure {
        ImportFailure(
            title: "Apple 认证暂时不可用",
            reason: "Apple 暂时拒绝了登录请求（-80045）。这不能说明 Apple ID 被标记、密码错误或账号被锁定。",
            recovery: "等待一段时间后再重试；不要连续重复登录或修改密码。",
            code: "SEAL-AUTH-80045",
            condition: .appleServiceUnavailable,
            action: .waitThenRetry,
            retryDisposition: .manual,
            operation: operation,
            origin: origin
        )
    }

    private static func messageIndicates503(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("503") || m.contains("service temporarily unavailable")
    }

    static func verificationFailureReason(
        for failure: ImportFailure
    ) -> AccountVerificationFailureReason? {
        // 新合同先于旧错误码规则：同一编号在历史日志中可能承载过不同语义，
        // 已迁移的生产出口不能再靠前缀反推出账号状态。
        if failure.hasStructuredSemantics {
            return failure.condition == .credentialsRejected ? .credentialsRejected : nil
        }
        let code = failure.code
        // SEAL-AUTH-105f 是 Team 查询失败，不代表本地凭据缺失，不得标记 needsVerification。
        if code == "SEAL-AUTH-105f" { return nil }
        // 只有 Apple 明确拒绝登录凭据时才标记账号需要验证。
        // `102c` 是证书请求的二义认证错误，可能是会话状态或 Apple 限流；`102e` 是设备环境
        // 握手失败。两者都不能据此认定密码错误，否则会把仍保存在 Keychain 的账号锁进失效状态。
        // `102d` 来自 Apple 明确的 incorrectCredentials；不扩大到整个 102 前缀。
        let explicitCredentialRejectionCodes: Set<String> = [
            "SEAL-AUTH-102",
            "SEAL-AUTH-102a",
            "SEAL-AUTH-102b",
            "SEAL-AUTH-102d"
        ]
        if explicitCredentialRejectionCodes.contains(code) { return .credentialsRejected }
        if code.hasPrefix("SEAL-AUTH-105") { return .localCredentialsMissing }
        if code.hasPrefix("SEAL-AUTH-106") { return .localCredentialsMismatch }
        // SEAL-AUTH-107（会话过期）不标记 ID 失效：签名/续签在 LocalDevVPN 环境无法可靠自动重登，
        // 统一引导到「我的」页重新验证；网络/限流也不写账号状态。
        return nil
    }

    static func shouldRequireReverification(_ failure: ImportFailure) -> Bool {
        verificationFailureReason(for: failure) != nil
    }

    static func isTransient(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-NET-")
            || failure.code.hasPrefix("SEAL-ANI-")
            || failure.code == "SEAL-CERT-205"
    }

    private static let networkCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive,
        .resourceUnavailable
    ]

    private static let networkFragments = [
        "network",
        "timed out",
        "timeout",
        "not connected",
        "offline",
        "cannot connect",
        "could not connect",
        "cannot find host",
        "dns"
    ]
}
