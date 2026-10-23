import CryptoKit
import Foundation
import Security

// MARK: - 保险库数据模型

/// 保险库里的一条凭据：以**归一化登录 ID** 为键（见 `LoginIDNormalizer`），
/// `accountIDs` 只是「哪些账号记录用过这条 secret」的关联表 —— 它让旧调用方按
/// UUID 查 `load(accountID:)` 时也能在保险库里命中并自愈回填钥匙串。
/// 关联可增可删（`detach`），secret 本体永不随关联删除。
struct CredentialVaultEntry: Codable, Equatable, Sendable {
    var key: String
    var accountIDs: [String]
    var secret: AccountSecret
}

/// 保险库明文载荷（加密前 / 解密后的形态）。整体加密、整体落盘：
/// 账号量级只有个位数，没必要做逐条加密的文件格式。
struct CredentialVaultPayload: Codable, Equatable, Sendable {
    var entries: [CredentialVaultEntry]

    static let empty = CredentialVaultPayload(entries: [])

    func entry(forKey key: String) -> CredentialVaultEntry? {
        entries.first { $0.key == key }
    }

    func entry(forAccountID accountID: UUID) -> CredentialVaultEntry? {
        entries.first { $0.accountIDs.contains(accountID.uuidString) }
    }

    /// 写入 / 接回：同键覆盖 secret 并合并关联（幂等，重复跑结果不变）。
    mutating func upsert(_ secret: AccountSecret, accountID: UUID?) {
        let key = LoginIDNormalizer.vaultKey(forLoginID: secret.email)
        guard key.isEmpty == false else { return }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].secret = secret
            if let accountID,
               entries[index].accountIDs.contains(accountID.uuidString) == false {
                entries[index].accountIDs.append(accountID.uuidString)
            }
        } else {
            entries.append(CredentialVaultEntry(
                key: key,
                accountIDs: accountID.map { [$0.uuidString] } ?? [],
                secret: secret
            ))
        }
    }

    /// 只解关联、不删 secret（「记录删除 ≠ 凭据删除」的落点）。
    mutating func detach(accountID: UUID) {
        for index in entries.indices {
            entries[index].accountIDs.removeAll { $0 == accountID.uuidString }
        }
    }

}

// MARK: - 纯编解码（CryptoKit AES-GCM；不自造加密）

/// 保险库文件的加解密与载荷编解码。全部是纯函数：
/// 给定 (数据, 钥匙) 进、(数据) 出，不碰钥匙串、不碰文件系统 —— 单测直接钉。
enum CredentialVaultCrypto {
    static let fileFormatVersion = 1

    struct FileEnvelope: Codable, Equatable, Sendable {
        var version: Int
        /// AES-GCM `SealedBox.combined`（nonce + ciphertext + tag）的 base64。
        var sealedBox: String
    }

    enum CryptoError: Error, Equatable, Sendable {
        case malformedEnvelope
        case unsupportedVersion
    }

    // MARK: 设备钥匙（保险库文件本体）

    static func encryptFile(payloadData: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(payloadData, using: key)
        guard let combined = sealed.combined else { throw CryptoError.malformedEnvelope }
        let envelope = FileEnvelope(
            version: fileFormatVersion,
            sealedBox: combined.base64EncodedString()
        )
        return try JSONEncoder().encode(envelope)
    }

    static func decryptFile(_ fileData: Data, key: SymmetricKey) throws -> Data {
        let envelope = try JSONDecoder().decode(FileEnvelope.self, from: fileData)
        guard envelope.version == fileFormatVersion else { throw CryptoError.unsupportedVersion }
        guard let combined = Data(base64Encoded: envelope.sealedBox) else {
            throw CryptoError.malformedEnvelope
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }

    // MARK: 载荷编解码

    static func encodePayload(_ payload: CredentialVaultPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    static func decodePayload(_ data: Data) throws -> CredentialVaultPayload {
        try JSONDecoder().decode(CredentialVaultPayload.self, from: data)
    }
}

// MARK: - 迁移规划（纯函数）

/// 旧 UUID 键 → 新归一化键的迁移决策。输入是钥匙串里全部 (键, secret)，
/// 输出「需要按新键补存」的动作列表；**只补不删**（旧项保留），且幂等：
/// 新键已存在同指纹 secret 时不产动作，重复跑产空列表。
enum CredentialMigrationPlanner {
    struct Action: Equatable, Sendable {
        let secret: AccountSecret
        let normalizedKey: String
    }

    static func plan(keyedSecrets: [(key: String, secret: AccountSecret)]) -> [Action] {
        var existingByKey: [String: String] = [:] // normalizedKey -> fingerprint
        for item in keyedSecrets where LoginIDNormalizer.isLegacyUUIDKey(item.key) == false {
            existingByKey[item.key] = item.secret.credentialFingerprint
        }
        var plannedKeys: Set<String> = []
        var actions: [Action] = []
        for item in keyedSecrets where LoginIDNormalizer.isLegacyUUIDKey(item.key) {
            let normalizedKey = LoginIDNormalizer.vaultKey(forLoginID: item.secret.email)
            guard normalizedKey.isEmpty == false else { continue }
            if existingByKey[normalizedKey] == item.secret.credentialFingerprint { continue }
            guard plannedKeys.contains(normalizedKey) == false else { continue }
            plannedKeys.insert(normalizedKey)
            actions.append(Action(secret: item.secret, normalizedKey: normalizedKey))
        }
        return actions
    }
}

struct CredentialMigrationSummary: Equatable, Sendable {
    var migratedCount: Int
    var alreadyMigratedCount: Int
    static let none = CredentialMigrationSummary(migratedCount: 0, alreadyMigratedCount: 0)
}

// MARK: - 保险库加密钥匙（Keychain 专用条目）

/// 保险库文件的加密钥匙，单独存一个钥匙串条目（独立 service，与账号库隔离：
/// 账号库的 `loadAllSecrets` 枚举不会碰到它，它也不会被当成 AccountSecret 解码）。
enum CredentialVaultKeyStore {
    static let service = "com.mjorb.seal.credential-vault"
    static let account = "encryption-key-v1"

    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String: SealKeychainAccessibility.value,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = try loadKey() { return raced }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }

    private static func loadKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw KeychainError(status: status)
        }
        return SymmetricKey(data: data)
    }
}

// MARK: - 保险库文件存储（Application Support）

/// AES-GCM 加密的保险库文件：全账号 secret 合集的第二副本（双写自愈的「备」）。
/// 文件里只有密文；钥匙在钥匙串（`CredentialVaultKeyStore`）。
/// 每次操作整体读—改—写（原子写保证不写一半）。
///
/// ⚠️ 整载豁免依据（AGENTS.md 大包内存纪律针对的是 500MB+ IPA，只许流式）：
/// 本文件只装账号凭据——每条 secret 是邮箱 / token / 口令 + 若干张证书 P12
/// （单张约 3-4 KB），免费账号 3-app 场景下账号数个位数、每账号证书数个位数，
/// 全文件量级在几十 KB、极端不超过 1 MB，与 IPA 大包不是同一问题域；
/// 整体读—改—写换来的是「永不写一半」的原子性，这正是保险库的目的。
actor CredentialVaultFileStore {
    let fileURL: URL
    private let keyProvider: @Sendable () throws -> SymmetricKey

    /// 生产入口：钥匙来自钥匙串专用条目。单测注入固定钥匙即可离线跑通全链。
    init(fileURL: URL, keyProvider: @escaping @Sendable () throws -> SymmetricKey) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    static func production(fileURL: URL) -> CredentialVaultFileStore {
        CredentialVaultFileStore(fileURL: fileURL) {
            try CredentialVaultKeyStore.loadOrCreateKey()
        }
    }

    static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appending(path: AppConfiguration.Paths.applicationSupportSubdirectory, directoryHint: .isDirectory)
            .appending(path: "CredentialVault.json")
    }

    func loadPayload() throws -> CredentialVaultPayload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let fileData = try Data(contentsOf: fileURL)
        let plain = try CredentialVaultCrypto.decryptFile(fileData, key: try keyProvider())
        return try CredentialVaultCrypto.decodePayload(plain)
    }

    func savePayload(_ payload: CredentialVaultPayload) throws {
        let plain = try CredentialVaultCrypto.encodePayload(payload)
        let fileData = try CredentialVaultCrypto.encryptFile(payloadData: plain, key: try keyProvider())
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileData.write(to: fileURL, options: .atomic)
        try? CompleteFileProtector().protect(fileURL)
    }

    @discardableResult
    func upsert(_ secret: AccountSecret, accountID: UUID?) throws -> CredentialVaultEntry? {
        var payload = try loadPayload()
        payload.upsert(secret, accountID: accountID)
        try savePayload(payload)
        return payload.entry(forKey: LoginIDNormalizer.vaultKey(forLoginID: secret.email))
    }

    func secret(forKey key: String) throws -> AccountSecret? {
        try loadPayload().entry(forKey: key)?.secret
    }

    func secret(forAccountID accountID: UUID) throws -> AccountSecret? {
        try loadPayload().entry(forAccountID: accountID)?.secret
    }

    func detach(accountID: UUID) throws {
        var payload = try loadPayload()
        payload.detach(accountID: accountID)
        try savePayload(payload)
    }

}
