import Foundation
import Testing
@testable import Seal

/// 「凭据待恢复」判定（0.1.52 第 7 项）：待恢复 == needsVerification + localCredentialsMissing。
/// 钉住它是为了让库存同步的「跳过且不刷日志」有唯一判据，不再各处自创条件。
struct CredentialVaultRecoveryPolicyTests {
    private func account(
        status: AccountStatus,
        reason: AccountVerificationFailureReason?
    ) -> AppleAccountRecord {
        AppleAccountRecord(
            maskedEmail: "u***@example.com",
            accountIdentifier: "acct-1",
            teamID: "TEAM123456",
            teamName: "Personal Team",
            status: status,
            verificationFailureReason: reason,
            lastVerifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test
    func awaitingRecoveryRequiresMissingCredentialReason() {
        #expect(CredentialRecoveryPolicy.isAwaitingRecovery(
            account(status: .needsVerification, reason: .localCredentialsMissing)
        ))
        #expect(CredentialRecoveryPolicy.isAwaitingRecovery(
            account(status: .needsVerification, reason: .sessionExpired)
        ) == false)
        #expect(CredentialRecoveryPolicy.isAwaitingRecovery(
            account(status: .needsVerification, reason: nil)
        ) == false)
        #expect(CredentialRecoveryPolicy.isAwaitingRecovery(
            account(status: .verified, reason: nil)
        ) == false)
        #expect(CredentialRecoveryPolicy.isAwaitingRecovery(
            account(status: .availableOffline, reason: nil)
        ) == false)
    }

    @Test
    func inventorySyncSkipsOnlyAwaitingRecovery() {
        #expect(CredentialRecoveryPolicy.shouldSkipInventorySync(
            account(status: .needsVerification, reason: .localCredentialsMissing)
        ))
        #expect(CredentialRecoveryPolicy.shouldSkipInventorySync(
            account(status: .verified, reason: nil)
        ) == false)
    }

    @Test
    func recoveryNoticeIsEmittedOncePerAccount() {
        let accountID = UUID()
        #expect(CredentialRecoveryPolicy.shouldEmitRecoveryNotice(
            accountID: accountID, alreadyNotifiedAccountIDs: []
        ))
        #expect(CredentialRecoveryPolicy.shouldEmitRecoveryNotice(
            accountID: accountID, alreadyNotifiedAccountIDs: [accountID]
        ) == false)
        #expect(CredentialRecoveryPolicy.shouldEmitRecoveryNotice(
            accountID: accountID, alreadyNotifiedAccountIDs: [UUID()]
        ))
    }

    @Test
    func missingMeansBothStoresMissed() {
        // `load` 的契约：主存 + 保险库任一命中都返回非 nil；nil 才是缺失。
        #expect(CredentialRecoveryPolicy.isCredentialMissing(secret: nil))
        let secret = AccountSecret(
            email: "user@example.com",
            accountIdentifier: "acct-1",
            dsid: "dsid-1",
            authToken: "token-1",
            password: nil
        )
        #expect(CredentialRecoveryPolicy.isCredentialMissing(secret: secret) == false)
    }

    @Test
    func recoveryFailurePointsAtReverification() {
        let failure = CredentialRecoveryPolicy.recoveryFailure(
            for: account(status: .needsVerification, reason: .localCredentialsMissing)
        )
        #expect(failure.code == "SEAL-KEYCHAIN-005")
        #expect(failure.action == .reauthenticateAccount)
        #expect(failure.route == .account)
    }
}
