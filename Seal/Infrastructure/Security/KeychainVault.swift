import Foundation
import Security

/// 账号凭据库（0.1.52 第 7 项重构：「保存了就不许丢」）。
///
/// ## 存储形态（双写）
/// 1. **钥匙串主存**：service = `accountVault`。每条 secret 存两份键：
///    - **归一化登录 ID 键**（`LoginIDNormalizer`，主查找键）；
///    - **账号记录 UUID 键**（兼容键：仓内全部既有调用方都按 `accountID` 查，
///      且升级前的存量只有这一份键，迁移期靠它读出存量）。
/// 2. **保险库文件**：Application Support 下 AES-GCM 加密文件
///    （`CredentialVaultFileStore`，钥匙在钥匙串专用条目），全账号 secret 合集。
///
/// ## 读取（自愈）
/// `load` 任一处命中即返回，并把缺失的另一处当场回填 —— 单副本损坏 / 丢失
/// 不再等于凭据丢失。两处都 miss 才返回 `nil`（凭据待恢复，见 `CredentialRecoveryPolicy`）。
///
/// ## 删除（永不删 secret）
/// 本类**没有**真正删除 secret 的入口：`delete` / `detach` 只解除 UUID 关联
/// （钥匙串 UUID 别名 + 保险库关联表），归一化键条目与保险库本体一律保留，
/// 重新添加同一 Apple ID 时按登录 ID 自动接回。
actor KeychainVault {
    private let service = SealKeychainServices.accountVault
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let vaultStore: CredentialVaultFileStore?
    private var didAttemptMigration = false

    init(vaultFileURL: URL? = CredentialVaultFileStore.defaultFileURL()) {
        if let vaultFileURL {
            vaultStore = CredentialVaultFileStore.production(fileURL: vaultFileURL)
        } else {
            vaultStore = nil
        }
    }

    /// 单测 / 特殊场景注入（注入带固定钥匙的文件存储，避免碰真实钥匙串钥匙条目）。
    init(vaultStore: CredentialVaultFileStore?) {
        self.vaultStore = vaultStore
    }

    // MARK: - 保存（双写 + 写后验证）

    func save(_ secret: AccountSecret, for accountID: UUID) async throws {
        await ensureMigrated()
        let normalizedKey = LoginIDNormalizer.vaultKey(forLoginID: secret.email)
        try rawSave(secret, key: accountID.uuidString)
        if normalizedKey.isEmpty == false {
            try rawSave(secret, key: normalizedKey)
        }
        if let vaultStore {
            _ = try await vaultStore.upsert(secret, accountID: accountID)
        }
        try await verifySaved(secret, normalizedKey: normalizedKey, accountID: accountID)
    }

    /// 写后验证：回读主存与保险库、比对关键字段指纹。不一致当场以
    /// `SEAL-KEYCHAIN-004` 报告，绝不让「以为存上了其实没存上」静默过关。
    /// 归一化键为空（登录 ID 缺失的异常 secret）时主存腿回退按 UUID 键回读、
    /// 保险库腿跳过 —— 保险库以登录 ID 为键，无键可存时不能假报失败。
    private func verifySaved(_ secret: AccountSecret, normalizedKey: String, accountID: UUID) async throws {
        let readBackKey = normalizedKey.isEmpty ? accountID.uuidString : normalizedKey
        let keychainCopy = try rawLoad(key: readBackKey)
        guard let keychainCopy, keychainCopy.hasSameCriticalFields(as: secret) else {
            throw Self.writeVerificationFailure(secret: secret, stage: "钥匙串主存回读不一致")
        }
        if let vaultStore, normalizedKey.isEmpty == false {
            let vaultCopy = try await vaultStore.secret(forKey: normalizedKey)
            guard let vaultCopy, vaultCopy.hasSameCriticalFields(as: secret) else {
                throw Self.writeVerificationFailure(secret: secret, stage: "保险库回读不一致")
            }
        }
    }

    private static func writeVerificationFailure(secret: AccountSecret, stage: String) -> ImportFailure {
        ImportFailure(
            title: "账号凭据保存未完成",
            reason: "凭据写入后回读校验失败（\(stage)），本次保存不能确认已落盘。",
            recovery: "重新验证 Apple ID；如持续失败请导出日志",
            code: "SEAL-KEYCHAIN-004",
            condition: .localStorageWriteFailed,
            action: .copyDiagnostics,
            retryDisposition: .manual,
            operation: .authenticateAccount,
            origin: .fileStore
        )
    }

    // MARK: - 读取（主存 → 保险库 → 存量扫描，命中即自愈）

    func load(accountID: UUID) async throws -> AccountSecret? {
        await ensureMigrated()
        if let secret = try rawLoad(key: accountID.uuidString) {
            // 主存命中顺手补齐保险库（旧版本只有钥匙串一份时，保险库靠读路径长出来）。
            if let vaultStore {
                _ = try? await vaultStore.upsert(secret, accountID: accountID)
            }
            return secret
        }
        if let vaultStore, let healed = try await vaultStore.secret(forAccountID: accountID) {
            try healKeychain(with: healed, accountID: accountID)
            return healed
        }
        return nil
    }

    /// 按登录 ID 查（重加同号接回旧 secret 的入口）：归一化键 → 保险库 → 存量全扫。
    func load(loginID rawLoginID: String) async throws -> AccountSecret? {
        await ensureMigrated()
        let normalizedKey = LoginIDNormalizer.vaultKey(forLoginID: rawLoginID)
        guard normalizedKey.isEmpty == false else { return nil }
        if let secret = try rawLoad(key: normalizedKey) {
            if let vaultStore {
                _ = try? await vaultStore.upsert(secret, accountID: nil)
            }
            return secret
        }
        if let vaultStore, let healed = try await vaultStore.secret(forKey: normalizedKey) {
            try healKeychain(with: healed, accountID: nil)
            return healed
        }
        // 存量兜底：迁移未覆盖到的旧 UUID 条目按 secret 内容里的登录 ID 匹配。
        for item in try allKeyedSecrets()
        where LoginIDNormalizer.vaultKey(forLoginID: item.secret.email) == normalizedKey {
            try healKeychain(with: item.secret, accountID: nil)
            if let vaultStore {
                _ = try? await vaultStore.upsert(item.secret, accountID: nil)
            }
            return item.secret
        }
        return nil
    }

    /// App 容器删除后，账号 UUID 索引会丢失，但同一签名访问组下的钥匙串条目可能仍在。
    /// Seal 接管判据按实际证书序列号验证这些材料，不能只遍历当前 Accounts.json 的 UUID。
    ///
    /// ⚠️ 签名保持同步 `throws` 不是遗漏：守卫 R125 以原文钉住本签名与
    /// `kSecMatchLimitAll` 枚举（重装接管判据的契约）。保险库合并版见
    /// `loadAllSecretsIncludingVault()` —— 两个 R125 消费方（续签接管 / 证书页自管理）
    /// 切过去需要同步改 R125 断言，已列 part-7 报告「待拍板」，不在本批擅自迁移。
    func loadAllSecrets() throws -> [AccountSecret] {
        var request = baseQuery()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }

        let dataItems = (result as? [Any])?.compactMap { $0 as? Data }
            ?? (result as? Data).map { [$0] }
            ?? []
        return dataItems.compactMap { try? decoder.decode(AccountSecret.self, from: $0) }
    }

    /// `loadAllSecrets()` 的保险库合并版：钥匙串枚举 + 保险库条目（按指纹去重）。
    /// 钥匙串被选择性清空、容器还在的场景下，接管 / 查找判据仍能从保险库拿到材料。
    func loadAllSecretsIncludingVault() async throws -> [AccountSecret] {
        await ensureMigrated()
        var secrets = try loadAllSecrets()
        var seen = Set(secrets.map(\.credentialFingerprint))
        if let vaultStore {
            for entry in (try? await vaultStore.loadPayload())?.entries ?? [] {
                guard seen.contains(entry.secret.credentialFingerprint) == false else { continue }
                seen.insert(entry.secret.credentialFingerprint)
                secrets.append(entry.secret)
            }
        }
        return secrets
    }

    // MARK: - 解除关联（永不删 secret）

    /// 解除账号记录与 secret 的关联：删 UUID 别名、清保险库关联表；
    /// 归一化键条目与保险库 secret 本体保留，重加同号自动接回。
    func detach(accountID: UUID) async throws {
        try rawDelete(key: accountID.uuidString)
        if let vaultStore {
            try await vaultStore.detach(accountID: accountID)
        }
    }

    /// 历史 API 名，语义已变：**不再删除 secret**，等价于 `detach`。
    /// 保留它是为了让既有调用点（删号、保存回滚）无需大改就获得「不许丢」语义；
    /// 新代码请直接用 `detach` 把意图写清楚。
    func delete(accountID: UUID) async throws {
        try await detach(accountID: accountID)
    }

    // MARK: - 证书材料（只清证书，不动登录凭据）

    func clearSigningMaterial(accountID: UUID) async throws {
        guard var secret = try await load(accountID: accountID) else { return }
        secret.clearAllCertificateMaterials()
        try await save(secret, for: accountID)
    }

    func signingMaterialSummary(accountID: UUID) async throws -> SigningMaterialSummary? {
        guard let secret = try await load(accountID: accountID) else { return nil }
        return SigningMaterialSummary(
            accountIdentifier: secret.accountIdentifier,
            hasCertificateP12: secret.certificateP12 != nil,
            certificateSerialNumber: secret.certificateSerialNumber,
            certificateMachineIdentifier: secret.certificateMachineIdentifier
        )
    }

    // MARK: - 迁移（惰性 + 可显式调用；幂等、只补不删）

    private func ensureMigrated() async {
        guard didAttemptMigration == false else { return }
        didAttemptMigration = true
        _ = await runMigration()
    }

    /// 扫描旧 UUID 键存量：读出 secret 内容里的登录 ID，归一化后按新键补存到
    /// 主存 + 保险库；旧 UUID 条目保留不删。返回摘要供日志（只记条数）。
    @discardableResult
    func migrateLegacySecretsIfNeeded() async -> CredentialMigrationSummary {
        didAttemptMigration = true
        return await runMigration()
    }

    private func runMigration() async -> CredentialMigrationSummary {
        guard let keyed = try? allKeyedSecrets() else { return .none }
        let actions = CredentialMigrationPlanner.plan(keyedSecrets: keyed)
        var applied = 0
        for action in actions {
            let sourceID = keyed.first {
                LoginIDNormalizer.isLegacyUUIDKey($0.key)
                    && $0.secret.credentialFingerprint == action.secret.credentialFingerprint
            }.flatMap { UUID(uuidString: $0.key) }
            guard (try? rawSave(action.secret, key: action.normalizedKey)) != nil else { continue }
            if let vaultStore {
                _ = try? await vaultStore.upsert(action.secret, accountID: sourceID)
            }
            applied += 1
        }
        let legacyCount = keyed.filter { LoginIDNormalizer.isLegacyUUIDKey($0.key) }.count
        return CredentialMigrationSummary(
            migratedCount: applied,
            alreadyMigratedCount: max(0, legacyCount - actions.count)
        )
    }

    // MARK: - 口令导出 / 导入（后端；UI 入口形态未决，见 part-7 报告）

    func exportVaultData(passphrase: String) async throws -> Data {
        guard let vaultStore else { throw Self.vaultUnavailableFailure() }
        do {
            return try await vaultStore.exportData(passphrase: passphrase)
        } catch {
            throw Self.exportImportFailure()
        }
    }

    /// 导入恢复：解开后逐条并入保险库并回填钥匙串（归一化键），返回导入条数。
    @discardableResult
    func importVaultData(_ data: Data, passphrase: String) async throws -> Int {
        guard let vaultStore else { throw Self.vaultUnavailableFailure() }
        let count: Int
        do {
            count = try await vaultStore.importData(data, passphrase: passphrase)
        } catch {
            throw Self.exportImportFailure()
        }
        for entry in (try? await vaultStore.loadPayload())?.entries ?? [] {
            try? rawSave(entry.secret, key: entry.key)
        }
        return count
    }

    private static func vaultUnavailableFailure() -> ImportFailure {
        ImportFailure(
            title: "凭据保险库不可用",
            reason: "本机保险库文件位置不可用，无法导出或导入凭据备份。",
            recovery: "重新打开 Seal 后重试；如持续失败请导出日志",
            code: "SEAL-KEYCHAIN-006",
            condition: .localStorageWriteFailed,
            action: .copyDiagnostics,
            retryDisposition: .manual,
            operation: .authenticateAccount,
            origin: .fileStore
        )
    }

    private static func exportImportFailure() -> ImportFailure {
        ImportFailure(
            title: "凭据备份处理失败",
            reason: "备份文件无法解开（口令不正确或文件已损坏），本机凭据未做任何更改。",
            recovery: "确认口令与备份文件后重试",
            code: "SEAL-KEYCHAIN-006",
            condition: .localStorageWriteFailed,
            action: .copyDiagnostics,
            retryDisposition: .manual,
            operation: .authenticateAccount,
            origin: .fileStore
        )
    }

    // MARK: - 自愈与原始钥匙串操作（不触发迁移 / 保险库逻辑，防递归）

    private func healKeychain(with secret: AccountSecret, accountID: UUID?) throws {
        let normalizedKey = LoginIDNormalizer.vaultKey(forLoginID: secret.email)
        if normalizedKey.isEmpty == false {
            try rawSave(secret, key: normalizedKey)
        }
        if let accountID {
            try rawSave(secret, key: accountID.uuidString)
        }
    }

    private func rawSave(_ secret: AccountSecret, key: String) throws {
        let data = try encoder.encode(secret)
        let base = query(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // 必须是「首次解锁后可读」：锁屏下后台续签要现读这份密钥，
            // 用 `WhenUnlocked` 会直接失败（见 `SealKeychainAccessibility`）。
            kSecAttrAccessible as String: SealKeychainAccessibility.value
        ]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            attributes.forEach { insert[$0.key] = $0.value }
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainError(status: insertStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func rawLoad(key: String) throws -> AccountSecret? {
        var request = query(forKey: key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try decoder.decode(AccountSecret.self, from: data)
    }

    private func rawDelete(key: String) throws {
        let status = SecItemDelete(query(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// 枚举本 service 下全部 (键, secret)：迁移与存量扫描的原料。
    /// 解码失败的条目（如异形数据）跳过，不让一条坏数据挡住全量迁移。
    private func allKeyedSecrets() throws -> [(key: String, secret: AccountSecret)] {
        var request = baseQuery()
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = (result as? [Any]) ?? (result.map { [$0] } ?? [])
        return items.compactMap { item in
            guard let dict = item as? [String: Any],
                  let key = dict[kSecAttrAccount as String] as? String,
                  let data = dict[kSecValueData as String] as? Data,
                  let secret = try? decoder.decode(AccountSecret.self, from: data)
            else { return nil }
            return (key: key, secret: secret)
        }
    }

    private func query(forKey key: String) -> [String: Any] {
        var request = baseQuery()
        request[kSecAttrAccount as String] = key
        return request
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

struct KeychainError: Error, Equatable, Sendable {
    let status: OSStatus
}

extension KeychainError: CustomNSError {
    /// 🔴 为什么要显式给 domain / code / 文案：`KeychainError` 是 struct，
    /// 桥成 `NSError` 时 domain 恒为 `Seal.KeychainError`、**code 恒为 1**、
    /// `localizedDescription` 是系统默认文案 ⇒ 真机日志里只剩一句 `Seal.KeychainError 1`，
    /// 分不清「设备锁定」和「条目不存在」（2026-09-28 锁屏后台续签正是这么被看的）。
    /// 把真实 OSStatus 放到 `errorCode` 上，日志从此能直接读出 -25308 这类关键码。
    static var errorDomain: String { "Seal.KeychainError" }

    var errorCode: Int { Int(status) }

    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: describe]
    }

    /// 把 OSStatus 翻成一句能直接判断下一步的话。
    var describe: String {
        switch status {
        case errSecSuccess:
            return "钥匙串操作成功（不应作为错误抛出）"
        case errSecItemNotFound:
            return "钥匙串里没有这一项"
        case errSecInteractionNotAllowed:
            return "设备已锁定，当前无法读取该钥匙串条目"
        case errSecAuthFailed:
            return "钥匙串鉴权失败"
        case errSecDuplicateItem:
            return "钥匙串里已存在同一条目"
        default:
            return "钥匙串操作失败（OSStatus \(status)）"
        }
    }
}


struct SigningMaterialSummary: Equatable, Sendable {
    let accountIdentifier: String
    let hasCertificateP12: Bool
    let certificateSerialNumber: String?
    let certificateMachineIdentifier: String?
}
