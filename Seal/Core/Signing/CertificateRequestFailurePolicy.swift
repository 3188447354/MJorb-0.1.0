import AltSign
import Foundation

/// Only AltSign's typed certificate quota error authorizes quota recovery.
/// Invalid CSR errors and unrelated numeric/text matches must not trigger revocation.
enum CertificateRequestFailurePolicy {
    /// 这些失败都已经过远端证书清单复核；用户可以打开「撤销并继续签名」链路，
    /// 但只有明确选择并二次确认后才会真的撤销。
    static let recoveryEligibleCodes: Set<String> = [
        "SEAL-CERT-204b",
        "SEAL-CERT-204e",
        "SEAL-CERT-204f",
        "SEAL-CERT-204g"
    ]

    /// Apple 明确拒绝创建新开发证书时，才能进入“选一张旧证书撤销”的确认链路。
    /// 204f/204g 表示之前的撤销结果或列表已经变化，只能先重新读取候选列表。
    static let sacrificeSelectionEligibleCodes: Set<String> = [
        "SEAL-CERT-204b",
        "SEAL-CERT-204e"
    ]

    static func isCertificateLimitError(_ error: Error) -> Bool {
        matches(error, expected: ALTAppleAPIError(.tooManyCertificates))
    }

    static func requestFailure(
        error: Error,
        limitCode: String = "SEAL-CERT-204b"
    ) -> ImportFailure? {
        if isCertificateLimitError(error) {
            return ImportFailure(
                title: "签名证书数量已达上限",
                reason: "Apple 已明确拒绝新增签名证书：该账号证书数量已达上限。",
                recovery: "请先在原签名工具确认现有证书用途，完成签名身份迁移后再续签。",
                code: limitCode
            )
        }
        if matches(error, expected: ALTAppleAPIError(.invalidCertificateRequest)) {
            return ImportFailure(
                title: "签名证书请求无效",
                reason: "无法生成有效证书请求，或 Apple 拒绝了本次请求；此错误不代表证书名额已满。",
                recovery: "请导出日志排查证书请求；不要为此撤销现有证书。",
                code: "SEAL-CERT-220"
            )
        }
        return nil
    }

    /// Preserve actionable machine diagnostics without copying descriptions, responses,
    /// underlying errors, or arbitrary domain strings that can contain credentials.
    static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        let appleDomain = (ALTAppleAPIError(.tooManyCertificates) as NSError).domain
        let domain: String
        switch nsError.domain {
        case appleDomain: domain = "ALTAppleAPIErrorDomain"
        case NSURLErrorDomain: domain = "NSURLErrorDomain"
        default: domain = "OtherError"
        }
        return "domain=\(domain) code=\(nsError.code)"
    }

    static func isNonRetryableFailure(_ failure: ImportFailure) -> Bool {
        switch failure.code {
        case "SEAL-CERT-204", "SEAL-CERT-204a", "SEAL-CERT-204b",
             "SEAL-CERT-204c", "SEAL-CERT-204d", "SEAL-CERT-220", "SEAL-CERT-221":
            return true
        default:
            return false
        }
    }

    private static func matches(_ error: Error, expected: Error) -> Bool {
        let actual = error as NSError
        let expected = expected as NSError
        return actual.domain == expected.domain && actual.code == expected.code
    }
}
