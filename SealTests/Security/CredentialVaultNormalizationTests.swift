import Foundation
import Testing
@testable import Seal

/// 登录 ID 归一化（0.1.52 第 7 项）：保险库改键的纯函数判据。
/// 键错一条，同一 Apple ID 的凭据就接不回来 —— 这里把邮箱 / 中国手机号的
/// 全部写法变体钉死。夹具一律合成占位符（example.com / 13800000000 式假号）。
struct CredentialVaultNormalizationTests {
    @Test
    func emailTrimsAndLowercases() {
        #expect(LoginIDNormalizer.normalizedLoginID("  User@Example.COM ") == "user@example.com")
        #expect(LoginIDNormalizer.normalizedLoginID("user@example.com") == "user@example.com")
        #expect(LoginIDNormalizer.vaultKey(forLoginID: "USER@example.com") == "user@example.com")
    }

    @Test
    func mainlandMobileSpellingsCollapseToOneKey() {
        let expected = "+8613800000000"
        #expect(LoginIDNormalizer.normalizedLoginID("+86 138-0000-0000") == expected)
        #expect(LoginIDNormalizer.normalizedLoginID("+8613800000000") == expected)
        #expect(LoginIDNormalizer.normalizedLoginID("8613800000000") == expected)
        #expect(LoginIDNormalizer.normalizedLoginID("86 138 0000 0000") == expected)
        #expect(LoginIDNormalizer.normalizedLoginID("008613800000000") == expected)
        #expect(LoginIDNormalizer.normalizedLoginID("13800000000") == expected)
        #expect(LoginIDNormalizer.normalizedLoginID("138-0000-0000") == expected)
        #expect(LoginIDNormalizer.normalizedLoginID("+86 (138) 0000 0000") == expected)
    }

    @Test
    func internationalNumbersKeepTheirCountryCode() {
        #expect(LoginIDNormalizer.normalizedLoginID("+1 202-555-0123") == "+12025550123")
        #expect(LoginIDNormalizer.normalizedLoginID("+44 20 7123 4567") == "+442071234567")
    }

    @Test
    func mainlandMobileShapeIsStrict() {
        #expect(LoginIDNormalizer.isMainlandMobile("13800000000"))
        #expect(LoginIDNormalizer.isMainlandMobile("19912345678"))
        #expect(LoginIDNormalizer.isMainlandMobile("12345678901") == false) // 第二位 2
        #expect(LoginIDNormalizer.isMainlandMobile("23800000000") == false) // 首位非 1
        #expect(LoginIDNormalizer.isMainlandMobile("1380000000") == false)  // 10 位
    }

    @Test
    func emptyAndOpaqueIdentifiersAreStable() {
        #expect(LoginIDNormalizer.normalizedLoginID("") == "")
        #expect(LoginIDNormalizer.normalizedLoginID("   ") == "")
        // 既非邮箱也非号码：trim + 小写原样作键，不臆造、不丢字符。
        #expect(LoginIDNormalizer.normalizedLoginID("  AbC-Def ") == "abc-def")
    }

    @Test
    func legacyUUIDKeyDetection() {
        #expect(LoginIDNormalizer.isLegacyUUIDKey(UUID().uuidString))
        #expect(LoginIDNormalizer.isLegacyUUIDKey("user@example.com") == false)
        #expect(LoginIDNormalizer.isLegacyUUIDKey("+8613800000000") == false)
    }
}
