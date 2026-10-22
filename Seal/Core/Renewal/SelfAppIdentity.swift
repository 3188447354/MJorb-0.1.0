import Foundation

enum SelfAppBundleIdentity {
    static func originalBundleIdentifier(
        currentBundleIdentifier: String,
        declaredOriginalBundleIdentifier: String?,
        existingOriginalBundleIdentifier: String?
    ) -> String {
        existingOriginalBundleIdentifier
            ?? declaredOriginalBundleIdentifier
            ?? currentBundleIdentifier
    }
}

enum SelfAppAccountBinding {
    static func matchedAccountID(
        teamIdentifier: String?,
        accounts: [AppleAccountRecord]
    ) -> UUID? {
        guard let teamIdentifier = normalizedTeamIdentifier(teamIdentifier) else {
            return nil
        }
        return accounts.first { account in
            account.teamID.caseInsensitiveCompare(teamIdentifier) == .orderedSame
        }?.id
    }

    static func resolvedAccountID(
        teamIdentifier: String?,
        accounts: [AppleAccountRecord],
        fallbackAccountID: UUID?
    ) -> UUID? {
        guard normalizedTeamIdentifier(teamIdentifier) != nil else {
            return fallbackAccountID
        }
        return matchedAccountID(
            teamIdentifier: teamIdentifier,
            accounts: accounts
        )
    }

    private static func normalizedTeamIdentifier(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              normalized.isEmpty == false else {
            return nil
        }
        return normalized
    }
}

enum SelfAppRecordSelection {
    static func preferredExistingSealRecord(
        in records: [AppRecord],
        currentBundleIdentifier: String
    ) -> AppRecord? {
        records
            .filter { record in
                record.isSeal && matchesSealBundleIdentifier(
                    currentBundleIdentifier,
                    record: record
                )
            }
            .sorted { lhs, rhs in
                if lhs.belongsInInstalledList != rhs.belongsInInstalledList {
                    return lhs.belongsInInstalledList
                }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.importedAt > rhs.importedAt
            }
            .first
    }

    static func preferredExistingSealRecordForImportedIPA(
        in records: [AppRecord],
        importedBundleIdentifier: String
    ) -> AppRecord? {
        let normalizedImportedBundleIdentifier = normalize(importedBundleIdentifier)
        let matchingRecords = records.filter { record in
            guard record.isSeal else { return false }
            // Seal 记录需同时匹配原始 Bundle ID 和实际签名后的 Bundle ID
            let identifiers = [
                record.originalBundleIdentifier,
                record.mappedBundleIdentifier,
                record.preferredBundleIdentifier
            ].compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { $0.isEmpty == false }
            return identifiers.contains(normalizedImportedBundleIdentifier)
        }
        return matchingRecords.sorted { lhs, rhs in
            if lhs.belongsInInstalledList != rhs.belongsInInstalledList {
                return lhs.belongsInInstalledList
            }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.importedAt > rhs.importedAt
        }.first
    }

    /// 自替换事务已确认新进程实际运行时，优先接管导入时创建的替换记录，
    /// 而不是更新将被替换的旧记录。这样待签名列表的可见性标记会与旧记录
    /// 在同一事务中完成交接，不会留下永远待签名的 Seal 更新包。
    static func importedReplacement(
        for existing: AppRecord,
        in records: [AppRecord]
    ) -> AppRecord? {
        records
            .filter { record in
                record.isSeal && record.replacesInstalledAppID == existing.id
            }
            .sorted { lhs, rhs in
                if lhs.importedAt != rhs.importedAt {
                    return lhs.importedAt > rhs.importedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }

    private static func matchesSealBundleIdentifier(
        _ bundleIdentifier: String,
        record: AppRecord
    ) -> Bool {
        let installedIdentifiers = [
            record.mappedBundleIdentifier,
            record.preferredBundleIdentifier
        ].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.isEmpty == false }

        if installedIdentifiers.isEmpty == false {
            return installedIdentifiers.contains { identifier in
                bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
            }
        }

        return bundleIdentifier.caseInsensitiveCompare(record.originalBundleIdentifier) == .orderedSame
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 现行两记录模型（2026-10-09 重设计后）里「待更新 Seal 记录」的唯一判据，
/// 供 `SelfAppRegistrar` 的待更新保护分支与重复记录清理豁免**同源**使用 ——
/// 不许再各写一份，否则两处迟早打架（一处豁免、一处照删）。
///
/// 2026-10-09 后待更新源是一条独立新记录：`replacesInstalledAppID` 指向已安装
/// 记录，通常还带 `pendingUpdateSourceFingerprint`。判据只认替换链接，不把指纹
/// 设为必要条件：导入侧对「与已装包同指纹 / 同构建号」的包会刻意把指纹置 nil
/// （见 `ImportWorkflow.commit`），但替换链接照样在、记录照样等着签名安装；
/// 若要求指纹非空，这类记录会被重新当成重复记录删掉。反过来，指纹会在旧单
/// 记录模型的结算途中短暂挂在已安装记录上，单独拿它作判据会误伤。
/// 结算完成的形态也是确定的：所有交接路径（签名安装、迟到安装、自替换对账）
/// 都在 `commitInstalledReplacement` 前把替换链接与待更新指纹一并清掉，
/// 因此链接还在 = 更新尚未结算，必须保留；链接已清 = 可以按普通重复记录清理。
enum SelfAppPendingUpdateProtection {
    static func isPendingUpdateSource(_ record: AppRecord) -> Bool {
        record.isSeal && record.replacesInstalledAppID != nil
    }

    static func pendingUpdateSource(in records: [AppRecord]) -> AppRecord? {
        records
            .filter { isPendingUpdateSource($0) }
            .sorted { lhs, rhs in
                if lhs.importedAt != rhs.importedAt {
                    return lhs.importedAt > rhs.importedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }

    /// 重复记录清理的删除候选：Seal 记录、不是保留的那条、且不是待更新源。
    /// 待更新源连同它的文件一律不删 —— 删它等于删掉用户尚未签名的更新包，
    /// 签名抽屉随后就会拿着已删记录的 ID 撞出 SEAL-SIGN-404。
    static func duplicateCleanupCandidates(
        in records: [AppRecord],
        keepID: UUID
    ) -> [AppRecord] {
        records.filter { record in
            record.isSeal
                && record.id != keepID
                && isPendingUpdateSource(record) == false
        }
    }
}
