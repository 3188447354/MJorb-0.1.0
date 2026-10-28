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
/// 不再等于凭据丢失。两处均完整读取且都 miss 才返回 `nil`（凭据待恢复，见
/// `CredentialRecoveryPolicy`）；任一存储无法完整读取时抛错，不能误标账号状态。
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
    private var credentialVaultWarning: String?

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
        var vaultSynchronized = false
        if normalizedKey.isEmpty == false {
            vaultSynchronized = await synchronizeVault(secret, accountID: accountID)
        }
        try await verifySaved(
            secret,
            normalizedKey: normalizedKey,
            accountID: accountID,
            verifyVault: vaultSynchronized
        )
    }

    /// 下次账号操作时由调用方写入脱敏日志；不包含 Apple ID、口令或凭据内容。
    func consumeCredentialVaultWarning() -> String? {
        defer { credentialVaultWarning = nil }
        return credentialVaultWarning
    }

    /// 写后验证：回读主存与保险库、比对关键字段指纹。不一致当场以
    /// `SEAL-KEYCHAIN-004` 报告，绝不让「以为存上了其实没存上」静默过关。
    /// 归一化键为空（登录 ID 缺失的异常 secret）时主存腿回退按 UUID 键回读、
    /// 保险库腿跳过 —— 保险库以登录 ID 为键，无键可存时不能假报失败。
    private func verifySaved(
        _ secret: AccountSecret,
        normalizedKey: String,
        accountID: UUID,
        verifyVault: Bool
    ) async throws {
        let readBackKey = normalizedKey.isEmpty ? accountID.uuidString : normalizedKey
        let keychainCopy = try rawLoad(key: readBackKey)
        guard let keychainCopy, keychainCopy.hasSameCriticalFields(as: secret) else {
            throw Self.writeVerificationFailure(secret: secret, stage: "钥匙串主存回读不一致")
        }
        if let vaultStore, normalizedKey.isEmpty == false, verifyVault {
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

    /// 按账号记录读 secret。`accountIdentifier` 传了才启用最后的全兜底一步
    /// （见下）。返回 nil 只代表所有可用存储都成功读完并确认不存在；任何存储
    /// 读取失败都必须抛出，不能被上层当成「账号凭据丢失」。
    ///
    /// ⚠️ 为什么必须有全兜底（2026-10-23 立规，规格第 14 条）：已登录 ID 只许
    /// 苹果官方失效或用户自己删除，人为操作不许弄失效。但前两步的键都绑在
    /// 「当前记录」上——记录重建换 UUID、迁移把存量补到归一化键/保险库旧关联，
    /// 都会让 secret 还在、本函数却返回 nil ⇒ 上层误判「凭据待恢复」要用户
    /// 重新验证（log-48 09:44:26 两账号实证）。故传了账号标识时，前两步 miss
    /// 后再全盘（钥匙串全部条目＋保险库全部条目）按 `accountIdentifier` 匹配，
    /// 命中即自愈回填当前 UUID 键与保险库关联，之后走回快路径。
    func load(accountID: UUID, accountIdentifier: String? = nil) async throws -> AccountSecret? {
        await ensureMigrated()
        if let secret = try rawLoad(key: accountID.uuidString) {
            // 主存命中顺手补齐保险库（旧版本只有钥匙串一份时，保险库靠读路径长出来）。
            _ = await synchronizeVault(secret, accountID: accountID)
            return secret
        }
        var accountScopedVaultFailure: Error?
        if let vaultStore {
            do {
                if let healed = try await vaultStore.secret(forAccountID: accountID) {
                    try healKeychain(with: healed, accountID: accountID)
                    return healed
                }
            } catch {
                noteCredentialVaultProblem()
                accountScopedVaultFailure = error
            }
        }

        guard let accountIdentifier, accountIdentifier.isEmpty == false else {
            // 没有稳定账号标识就无法安全做全盘匹配。若保险库读取也失败，不能把
            // 「读不到」伪装成「没有凭据」。
            if let accountScopedVaultFailure { throw accountScopedVaultFailure }
            return nil
        }

        var candidates: [AccountSecret] = []
        var keychainScanFailure: Error?
        do {
            candidates.append(contentsOf: try allKeyedSecretsStrict().map(\.secret))
        } catch {
            keychainScanFailure = error
        }
        var vaultScanFailure: Error?
        if let vaultStore {
            do {
                candidates.append(contentsOf: try await vaultStore.loadPayload().entries.map(\.secret))
            } catch {
                noteCredentialVaultProblem()
                vaultScanFailure = error
            }
        }

        if let found = CredentialIdentityMatcher.match(
            accountIdentifier: accountIdentifier,
            in: candidates
        ) {
            // 自愈写回失败也不能抹掉已经找到的凭据；后续保存时会再次补齐。
            try? healKeychain(with: found, accountID: accountID)
            _ = await synchronizeVault(found, accountID: accountID)
            return found
        }

        // 至少一份完整扫描失败时，结果是「未知」，不是「不存在」。只在钥匙串与
        // 保险库都成功扫描且均无匹配时返回 nil，防止上层把暂时读错写成 ID 失效。
        if let keychainScanFailure { throw keychainScanFailure }
        if let vaultScanFailure { throw vaultScanFailure }
        // 账号关联索引读取失败但完整保险库扫描成功时，完整扫描已经给出权威结果。
        return nil
    }

    /// 按登录 ID 查（重加同号接回旧 secret 的入口）：归一化键 → 保险库 → 存量全扫。
    func load(loginID rawLoginID: String) async throws -> AccountSecret? {
        await ensureMigrated()
        let normalizedKey = LoginIDNormalizer.vaultKey(forLoginID: rawLoginID)
        guard normalizedKey.isEmpty == false else { return nil }
        if let secret = try rawLoad(key: normalizedKey) {
            _ = await synchronizeVault(secret, accountID: nil)
            return secret
        }
        var vaultLookupFailure: Error?
        if let vaultStore {
            do {
                if let healed = try await vaultStore.secret(forKey: normalizedKey) {
                    try healKeychain(with: healed, accountID: nil)
                    return healed
                }
            } catch {
                noteCredentialVaultProblem()
                vaultLookupFailure = error
            }
        }
        // 存量兜底：迁移未覆盖到的旧 UUID 条目按 secret 内容里的登录 ID 匹配。
        let keyedSecrets = try allKeyedSecretsStrict()
        for item in keyedSecrets where LoginIDNormalizer.vaultKey(forLoginID: item.secret.email) == normalizedKey {
            try healKeychain(with: item.secret, accountID: nil)
            _ = await synchronizeVault(item.secret, accountID: nil)
            return item.secret
        }
        // 只有保险库 lookup 与钥匙串全量扫描均成功，才能确认该登录 ID 没有凭据。
        if let vaultLookupFailure { throw vaultLookupFailure }
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
            do {
                for entry in try await vaultStore.loadPayload().entries {
                    guard seen.contains(entry.secret.credentialFingerprint) == false else { continue }
                    seen.insert(entry.secret.credentialFingerprint)
                    secrets.append(entry.secret)
                }
            } catch {
                noteCredentialVaultProblem()
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
            do {
                try await vaultStore.detach(accountID: accountID)
            } catch {
                // normalized ID 主存仍保留，坏掉的加密副本不能阻断账号记录操作。
                noteCredentialVaultProblem()
            }
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
            _ = await synchronizeVault(action.secret, accountID: sourceID)
            applied += 1
        }
        let legacyCount = keyed.filter { LoginIDNormalizer.isLegacyUUIDKey($0.key) }.count
        return CredentialMigrationSummary(
            migratedCount: applied,
            alreadyMigratedCount: max(0, legacyCount - actions.count)
        )
    }

    // MARK: - 自愈与原始钥匙串操作（不触发迁移 / 保险库逻辑，防递归）

    /// 钥匙串是账号凭据主存；加密文件只是可恢复副本。副本内容校验失败时，
    /// 先完整保留旧密文，再从钥匙串可读条目重建，任何副本错误都不冒充 Apple 登录失败。
    @discardableResult
    private func synchronizeVault(_ secret: AccountSecret, accountID: UUID?) async -> Bool {
        guard let vaultStore else { return false }
        do {
            _ = try await vaultStore.upsert(secret, accountID: accountID)
            return true
        } catch CredentialVaultFileStoreError.unreadableContent {
            do {
                let keyedSecrets = try allKeyedSecrets().sorted {
                    LoginIDNormalizer.isLegacyUUIDKey($0.key)
                        && LoginIDNormalizer.isLegacyUUIDKey($1.key) == false
                }
                var recoveredPayload = CredentialVaultPayload.empty
                for item in keyedSecrets {
                    let loginKey = LoginIDNormalizer.vaultKey(forLoginID: item.secret.email)
                    let existingSecret = recoveredPayload.entry(forKey: loginKey)?.secret
                    let mergedSecret = item.secret.preservingSigningMaterial(from: existingSecret)
                    recoveredPayload.upsert(
                        mergedSecret,
                        accountID: UUID(uuidString: item.key)
                    )
                }
                let loginKey = LoginIDNormalizer.vaultKey(forLoginID: secret.email)
                let existingSecret = recoveredPayload.entry(forKey: loginKey)?.secret
                recoveredPayload.upsert(
                    secret.preservingSigningMaterial(from: existingSecret),
                    accountID: accountID
                )
                try await vaultStore.quarantineUnreadableFileAndSave(recoveredPayload)
                noteCredentialVaultProblem(
                    "本机加密凭据副本无法解读，旧文件已保留，并已从钥匙串重建副本。"
                )
                return true
            } catch {
                noteCredentialVaultProblem(
                    "本机加密凭据副本暂不可读，原文件已保留；账号钥匙串主存仍可使用。"
                )
                return false
            }
        } catch {
            noteCredentialVaultProblem(
                "本机加密凭据副本同步失败；账号钥匙串主存仍可使用。"
            )
            return false
        }
    }

    private func noteCredentialVaultProblem(_ message: String = "本机加密凭据副本读取失败；账号钥匙串主存仍可使用。") {
        if credentialVaultWarning == nil {
            credentialVaultWarning = message
        }
    }

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

    /// 枚举本 service 下全部 (键, secret)：供幂等迁移与副本重建使用。
    /// 解码失败的条目（如异形数据）跳过，不让一条坏数据挡住迁移；账号“是否缺失”
    /// 判定必须使用下方严格版本，不能将被跳过的条目当成不存在。
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

    /// 账号恢复必须区分「扫描完毕且不存在」与「扫描到无法解码的条目」。
    /// 普通迁移仍使用上面的容错扫描；这里遇到任何结构异常或解码失败都抛错，
    /// 防止把未读完的钥匙串误判为凭据不存在，继而将 Apple ID 标成待验证。
    private func allKeyedSecretsStrict() throws -> [(key: String, secret: AccountSecret)] {
        var request = baseQuery()
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let result else { throw KeychainScanFailure.unexpectedResult }
        let items = (result as? [Any]) ?? [result]
        var secrets: [(key: String, secret: AccountSecret)] = []
        secrets.reserveCapacity(items.count)
        for item in items {
            guard let dict = item as? [String: Any],
                  let key = dict[kSecAttrAccount as String] as? String,
                  let data = dict[kSecValueData as String] as? Data
            else {
                throw KeychainScanFailure.malformedEntry
            }
            do {
                secrets.append((key: key, secret: try decoder.decode(AccountSecret.self, from: data)))
            } catch {
                throw KeychainScanFailure.unreadableEntry
            }
        }
        return secrets
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

private enum KeychainScanFailure: LocalizedError {
    case unexpectedResult
    case malformedEntry
    case unreadableEntry

    var errorDescription: String? {
        switch self {
        case .unexpectedResult:
            return "钥匙串扫描未返回结果，无法确认账号凭据是否存在。"
        case .malformedEntry:
            return "钥匙串包含无法识别的账号凭据条目，无法确认账号凭据是否存在。"
        case .unreadableEntry:
            return "钥匙串账号凭据条目无法解码，无法确认账号凭据是否存在。"
        }
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
