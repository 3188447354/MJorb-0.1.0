import CryptoKit
import Foundation
import Testing
@testable import Seal

/// 保险库编解码与迁移规划（0.1.52 第 7 项）：AES-GCM 往返、口令导出 / 导入、
/// 载荷 upsert / detach / merge 语义、旧 UUID 键迁移的幂等性。
/// 全部离线（固定钥匙 + 临时目录），不碰真实钥匙串。
struct CredentialVaultCodecTests {
    private func secret(
        email: String = "user@example.com",
        authToken: String = "token-1"
    ) -> AccountSecret {
        AccountSecret(
            email: email,
            accountIdentifier: "acct-1",
            dsid: "dsid-1",
            authToken: authToken,
            password: "pw-1"
        )
    }

    // MARK: 指纹

    @Test
    func fingerprintIgnoresCertificateMapLiteralOrder() {
        // 两份 secret 字段全等、仅字典字面量书写顺序不同：指纹内部按 serial 排序
        // 后再喂哈希，必须相等（字典迭代顺序在 Swift 里不稳定，不能进指纹）。
        let first = AccountSecret(
            email: "user@example.com", accountIdentifier: "acct-1", dsid: "dsid-1",
            authToken: "token-1", password: "pw-1",
            certificateP12: Data([1]), certificateSerialNumber: "AA01",
            certificateMachineIdentifier: "m1",
            certificateP12BySerial: ["AA01": Data([1]), "BB02": Data([2])],
            certificateMachineIdentifierBySerial: ["AA01": "m1", "BB02": "m2"]
        )
        let second = AccountSecret(
            email: "user@example.com", accountIdentifier: "acct-1", dsid: "dsid-1",
            authToken: "token-1", password: "pw-1",
            certificateP12: Data([1]), certificateSerialNumber: "AA01",
            certificateMachineIdentifier: "m1",
            certificateP12BySerial: ["BB02": Data([2]), "AA01": Data([1])],
            certificateMachineIdentifierBySerial: ["BB02": "m2", "AA01": "m1"]
        )
        #expect(first.credentialFingerprint == second.credentialFingerprint)
        #expect(first.hasSameCriticalFields(as: second))
    }

    @Test
    func fingerprintChangesWithCredentials() {
        #expect(secret().credentialFingerprint != secret(authToken: "token-2").credentialFingerprint)
        #expect(secret().hasSameCriticalFields(as: secret(authToken: "token-2")) == false)
    }

    // MARK: 设备钥匙文件编解码

    @Test
    func fileCryptoRoundTripsAndRejectsWrongKey() throws {
        let key = SymmetricKey(size: .bits256)
        let payload = CredentialVaultPayload(entries: [
            CredentialVaultEntry(key: "user@example.com", accountIDs: ["A"], secret: secret())
        ])
        let plain = try CredentialVaultCrypto.encodePayload(payload)
        let fileData = try CredentialVaultCrypto.encryptFile(payloadData: plain, key: key)
        // 文件里不得出现明文凭据片段。
        #expect(String(decoding: fileData, as: UTF8.self).contains("token-1") == false)
        let opened = try CredentialVaultCrypto.decryptFile(fileData, key: key)
        #expect(try CredentialVaultCrypto.decodePayload(opened) == payload)
        #expect(throws: (any Error).self) {
            try CredentialVaultCrypto.decryptFile(fileData, key: SymmetricKey(size: .bits256))
        }
    }

    // MARK: 口令导出 / 导入编解码

    @Test
    func exportRoundTripsWithPassphraseOnly() throws {
        let plain = try CredentialVaultCrypto.encodePayload(
            CredentialVaultPayload(entries: [
                CredentialVaultEntry(key: "user@example.com", accountIDs: [], secret: secret())
            ])
        )
        let salt = Data(repeating: 7, count: 32)
        let exported = try CredentialVaultCrypto.makeExportFile(
            payloadData: plain, passphrase: "correct horse", salt: salt
        )
        #expect(try CredentialVaultCrypto.openExportFile(exported, passphrase: "correct horse") == plain)
        // 口令错一个字：AES-GCM 校验失败，不返回任何明文。
        #expect(throws: (any Error).self) {
            try CredentialVaultCrypto.openExportFile(exported, passphrase: "wrong horse")
        }
        // 设备文件格式不是导出文件：必须拒绝，不能静默当空保险库导入。
        let deviceFile = try CredentialVaultCrypto.encryptFile(
            payloadData: plain, key: SymmetricKey(size: .bits256)
        )
        #expect(throws: (any Error).self) {
            try CredentialVaultCrypto.openExportFile(deviceFile, passphrase: "correct horse")
        }
    }

    // MARK: 载荷语义（双写 / detach 不删 / 合并）

    @Test
    func payloadUpsertDetachAndMergeKeepSecret() {
        let accountID = UUID()
        var payload = CredentialVaultPayload.empty
        payload.upsert(secret(), accountID: accountID)
        #expect(payload.entries.count == 1)
        #expect(payload.entry(forAccountID: accountID)?.secret == secret())
        #expect(payload.entry(forKey: "user@example.com")?.secret == secret())

        // 同键再存（新 token）：覆盖 secret、关联不变。
        payload.upsert(secret(authToken: "token-2"), accountID: accountID)
        #expect(payload.entries.count == 1)
        #expect(payload.entry(forKey: "user@example.com")?.secret.authToken == "token-2")

        // detach 只解关联：secret 本体还在（重加同号靠它接回）。
        payload.detach(accountID: accountID)
        #expect(payload.entry(forAccountID: accountID) == nil)
        #expect(payload.entry(forKey: "user@example.com")?.secret.authToken == "token-2")

        // 导入合并：同键以导入为准、关联取并集。
        var imported = CredentialVaultPayload.empty
        imported.upsert(secret(authToken: "token-3"), accountID: UUID())
        payload.merge(imported)
        #expect(payload.entries.count == 1)
        #expect(payload.entry(forKey: "user@example.com")?.secret.authToken == "token-3")
        #expect(payload.entry(forKey: "user@example.com")?.accountIDs.count == 1)
    }

    // MARK: 文件存储（临时目录 + 固定钥匙）

    @Test
    func fileStorePersistsHealsAndExports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CredentialVaultTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "CredentialVault.json")
        let key = SymmetricKey(size: .bits256)
        let store = CredentialVaultFileStore(fileURL: fileURL) { key }
        let accountID = UUID()

        _ = try await store.upsert(secret(), accountID: accountID)
        #expect(try await store.secret(forKey: "user@example.com") == secret())
        #expect(try await store.secret(forAccountID: accountID) == secret())

        // 新实例读同一文件：落盘成立（写后回读的存储层证据）。
        let reopened = CredentialVaultFileStore(fileURL: fileURL) { key }
        #expect(try await reopened.secret(forKey: "user@example.com") == secret())

        // 导出 → 换一台「设备」（新文件 + 新钥匙）导入 → 凭据回来。
        let exported = try await store.exportData(passphrase: "backup-pw")
        let otherURL = root.appending(path: "Other.json")
        // keyProvider 契约是「每次返回同一把钥匙」（生产实现从钥匙串读存量钥匙）；
        // 写成 `{ SymmetricKey(size: .bits256) }` 会每次调用都生成新随机钥匙，
        // 导入落盘与随后回读用的不是同一把 ⇒ GCM 校验必然 authenticationFailure
        // （CI run 39876823760 实证）。固定一把「另一台设备」的钥匙才符合契约。
        let otherKey = SymmetricKey(size: .bits256)
        let other = CredentialVaultFileStore(fileURL: otherURL) { otherKey }
        #expect(try await other.importData(exported, passphrase: "backup-pw") == 1)
        #expect(try await other.secret(forKey: "user@example.com") == secret())
        await #expect(throws: (any Error).self) {
            try await other.importData(exported, passphrase: "nope")
        }
    }

    // MARK: 迁移规划（幂等、只补不删）

    @Test
    func migrationPlannerMovesLegacyKeysOnce() {
        let legacyID = UUID()
        let legacy: [(key: String, secret: AccountSecret)] = [
            (key: legacyID.uuidString, secret: secret())
        ]
        let actions = CredentialMigrationPlanner.plan(keyedSecrets: legacy)
        #expect(actions.count == 1)
        #expect(actions.first?.normalizedKey == "user@example.com")

        // 补存后重跑：新键已有同指纹 secret ⇒ 空动作（幂等）。
        let afterMigration = legacy + [(key: "user@example.com", secret: secret())]
        #expect(CredentialMigrationPlanner.plan(keyedSecrets: afterMigration).isEmpty)

        // 同一登录 ID 两条旧记录：只产一个动作，不互相覆盖。
        let duplicated = legacy + [(key: UUID().uuidString, secret: secret(authToken: "token-2"))]
        #expect(CredentialMigrationPlanner.plan(keyedSecrets: duplicated).count == 1)

        // 新键内容已变（指纹不同）：仍需补存，以旧 UUID 条目为准对齐。
        let stale = legacy + [(key: "user@example.com", secret: secret(authToken: "token-9"))]
        #expect(CredentialMigrationPlanner.plan(keyedSecrets: stale).count == 1)
    }
}
