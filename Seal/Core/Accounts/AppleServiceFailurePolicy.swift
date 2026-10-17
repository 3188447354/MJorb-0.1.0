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
        // ⚠️ **SEAL-AUTH-102c 不得标记失效**（2026-09-18 真机，构建 133）。
        //
        // 它自己的文案就写着「两种常见成因：登录真的失效，**或者短时间内请求过密被 Apple 限流**」
        // 且 recovery 是「**先等几分钟重试**」—— 而把它判成 `.credentialsRejected`
        // 会**立刻把账号标成「失效」**，与这段文案**直接矛盾** ✗。
        //
        // 真机证据：`318***5***@qq.com` 签抖音时
        //   15:00:49  疑似被限流，退避 1 秒后重试 读取证书列表（第 1 次）
        //   15:00:53  第 2 次（退避 4 秒）    15:00:58  第 3 次（退避 8 秒）
        //   15:01:09  [SEAL-AUTH-102c] Apple 拒绝了证书请求：认证状态无效
        // ⇒ 紧接 **3 次限流退避**之后报的 102c，极可能就是限流；账号却被标成「失效」
        //   ⇒ 用户看到「失效 + 已签名 0/10」，于是去重新验证 → 又撞限流 → **死循环**。
        //
        // 语义上也更该保守：`107`（明确的会话过期）已经不标 ✓，而 `102c` 是**二义**的，
        // 更不该标 ✓。注意 **`102d` 保持标记** —— 那是 Apple **明确**拒绝凭据
        //（可能密码已改 / 账号被锁定），语义不含糊。
        if code == "SEAL-AUTH-102c" { return nil }
        if code.hasPrefix("SEAL-AUTH-102") { return .credentialsRejected }
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
