import Foundation
import Security

actor KeychainVault {
    private let service = SealKeychainServices.accountVault
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func save(_ secret: AccountSecret, for accountID: UUID) throws {
        let data = try encoder.encode(secret)
        let base = query(for: accountID)
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

    func load(accountID: UUID) throws -> AccountSecret? {
        var request = query(for: accountID)
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

    /// App 容器删除后，账号 UUID 索引会丢失，但同一签名访问组下的钥匙串条目可能仍在。
    /// Seal 接管判据按实际证书序列号验证这些材料，不能只遍历当前 Accounts.json 的 UUID。
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

    func delete(accountID: UUID) throws {
        let status = SecItemDelete(query(for: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    func clearSigningMaterial(accountID: UUID) throws {
        guard var secret = try load(accountID: accountID) else { return }
        secret.clearAllCertificateMaterials()
        try save(secret, for: accountID)
    }

    func signingMaterialSummary(accountID: UUID) throws -> SigningMaterialSummary? {
        guard let secret = try load(accountID: accountID) else { return nil }
        return SigningMaterialSummary(
            accountIdentifier: secret.accountIdentifier,
            hasCertificateP12: secret.certificateP12 != nil,
            certificateSerialNumber: secret.certificateSerialNumber,
            certificateMachineIdentifier: secret.certificateMachineIdentifier
        )
    }

    private func query(for accountID: UUID) -> [String: Any] {
        var request = baseQuery()
        request[kSecAttrAccount as String] = accountID.uuidString
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
