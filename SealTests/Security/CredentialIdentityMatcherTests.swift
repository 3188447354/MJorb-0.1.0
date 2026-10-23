import Foundation
import Testing
@testable import Seal

/// 凭据全兜底匹配（2026-10-23 立规，规格第 14 条）：已登录 ID 不许人为失效。
/// `load(accountID:)` 的记录键 miss 时，按 Apple 账号标识在全部存量 secret
/// 里找本人那条 —— 这组纯函数判据决定「找得回」还是「误判待恢复」。
/// 夹具一律合成占位符。
struct CredentialIdentityMatcherTests {
    private func secret(
        accountIdentifier: String,
        authToken: String = "token-1",
        certificateP12: Data? = nil,
        certificateP12BySerial: [String: Data] = [:]
    ) -> AccountSecret {
        AccountSecret(
            email: "user@example.com",
            accountIdentifier: accountIdentifier,
            dsid: "dsid-1",
            authToken: authToken,
            password: "pw-1",
            certificateP12: certificateP12,
            certificateSerialNumber: certificateP12 != nil ? "AA01" : nil,
            certificateP12BySerial: certificateP12BySerial
        )
    }

    @Test
    func emptyIdentifierMatchesNothing() {
        // fail closed：标识缺失时宁可不匹配，也不许认错人。
        let candidates = [secret(accountIdentifier: "acct-1")]
        #expect(CredentialIdentityMatcher.match(accountIdentifier: "", in: candidates) == nil)
    }

    @Test
    func noMatchReturnsNil() {
        let candidates = [
            secret(accountIdentifier: "acct-2"),
            secret(accountIdentifier: "acct-3")
        ]
        #expect(CredentialIdentityMatcher.match(accountIdentifier: "acct-1", in: candidates) == nil)
        #expect(CredentialIdentityMatcher.match(accountIdentifier: "acct-1", in: []) == nil)
    }

    @Test
    func findsOwnSecretAmongOthers() {
        // 场景：记录重建换了 UUID，secret 只剩旧键下的一份（候选来自全盘扫描）。
        let mine = secret(accountIdentifier: "acct-1", authToken: "token-mine")
        let candidates = [
            secret(accountIdentifier: "acct-2", authToken: "token-other"),
            mine,
            secret(accountIdentifier: "acct-3", authToken: "token-other-2")
        ]
        #expect(CredentialIdentityMatcher.match(accountIdentifier: "acct-1", in: candidates) == mine)
    }

    @Test
    func prefersMostCompleteSigningMaterial() {
        // 同账号两份存量（钥匙串旧副本 + 保险库新副本）：取带证书材料的那份，
        // 否则接回的是没私钥的空壳、续签照样失败。
        let stale = secret(accountIdentifier: "acct-1", authToken: "token-old")
        let complete = secret(
            accountIdentifier: "acct-1",
            authToken: "token-new",
            certificateP12: Data([1]),
            certificateP12BySerial: ["AA01": Data([1])]
        )
        #expect(CredentialIdentityMatcher.match(
            accountIdentifier: "acct-1", in: [stale, complete]
        ) == complete)
        #expect(CredentialIdentityMatcher.match(
            accountIdentifier: "acct-1", in: [complete, stale]
        ) == complete)
    }

    @Test
    func equalMaterialKeepsFirstCandidate() {
        // 同分时结果稳定：保持候选原序取第一条，日志与行为可复现。
        let first = secret(accountIdentifier: "acct-1", authToken: "token-a")
        let second = secret(accountIdentifier: "acct-1", authToken: "token-b")
        #expect(CredentialIdentityMatcher.match(
            accountIdentifier: "acct-1", in: [first, second]
        ) == first)
    }
}
