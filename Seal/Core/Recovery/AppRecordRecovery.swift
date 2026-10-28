import Foundation

actor AppRecordRecovery {
    private let appStore: any AppStore
    private let fileStore: AppFileStore
    private let parser: IPAParserService
    /// 已添加账号的读取口。只用来把扫回的记录挂回**同 Team 的账号**；
    /// 不传（测试 / 预览）时记录照建，只是 `accountID` 留空。
    private let accountsProvider: (@Sendable () async -> [AppleAccountRecord])?
    /// 本机/设备安装清单的注入点。**默认 nil = 完全不扫** —— 见 `InstalledAppScanning`：
    /// `AppRecordRecoveryTests` 会直接调 `restoreMissingRecords()`，写死就会在 CI 的
    /// 模拟器上真的去调私有设备 API。
    private let deviceScanner: (any InstalledAppScanning)?

    init(
        appStore: any AppStore,
        fileStore: AppFileStore,
        parser: IPAParserService = IPAParserService(),
        accountsProvider: (@Sendable () async -> [AppleAccountRecord])? = nil,
        deviceScanner: (any InstalledAppScanning)? = nil
    ) {
        self.appStore = appStore
        self.fileStore = fileStore
        self.parser = parser
        self.accountsProvider = accountsProvider
        self.deviceScanner = deviceScanner
    }

    @discardableResult
    func restoreMissingRecords(localInventoryOnly: Bool = false) async throws -> InstalledRecordRecoverySummary {
        try await recoverPendingFileTransactions()
        try await reconcileKnownRecords()

        let existing = try await appStore.fetchAll()
        let storedIPAs = try await fileStore.storedOriginalIPAs()
        for stored in storedIPAs {
            guard existing.contains(where: { $0.ipaRelativePath == stored.relativePath }) == false else {
                continue
            }
            guard let parsed = try? parser.parse(url: stored.url) else { continue }
            // Seal 由 SelfAppRegistrar 专门管理，通用恢复逻辑跳过，避免产生重复记录
            guard parsed.name != "Seal" else { continue }
            guard existing.contains(where: {
                $0.isSeal && Self.matchesSealBundleIdentifier(parsed.bundleIdentifier, record: $0)
            }) == false else {
                continue
            }
            // A leftover directory from an older replaced import must never be
            // resurrected as a second app record. Bundle identity, not the file
            // name, is the stable recovery key for third-party imports.
            guard existing.contains(where: {
                $0.isSeal == false
                    && $0.originalBundleIdentifier.caseInsensitiveCompare(
                        parsed.bundleIdentifier
                    ) == .orderedSame
            }) == false else {
                continue
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: stored.url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? parsed.fileSize
            let signedArtifact = try await recoveredSignedArtifact(appID: stored.appID)
            let record = AppRecord(
                id: stored.appID,
                originalBundleIdentifier: parsed.bundleIdentifier,
                mappedBundleIdentifier: signedArtifact?.mappedBundleIdentifier,
                name: parsed.name,
                version: parsed.version,
                buildNumber: parsed.buildNumber,
                size: size,
                iconRelativePath: nil,
                state: signedArtifact == nil ? .imported : .signed,
                expiryDate: nil,
                accountID: nil,
                ipaRelativePath: stored.relativePath,
                signedIPARelativePath: signedArtifact?.relativePath,
                signedIPASHA256: signedArtifact?.sha256,
                signedArtifactStatus: signedArtifact == nil ? nil : .awaitingVerification,
                preferredBundleIdentifier: signedArtifact?.mappedBundleIdentifier
                    ?? BundleIDPolicy.recommendedBundleIdentifier(for: parsed.bundleIdentifier),
                isPinned: false,
                importedAt: Date(),
                extensions: parsed.extensions
            )
            try await appStore.save(record)
        }

        // ── 从本机安装清单恢复（2026-09-25 新增）───────────────────────
        // 上面三步都只看得见**本地文件**；「只卸载了 Seal、其他 App 没卸载」的场景里
        // 本地文件全没了，系统 LaunchServices 仍能提供应用名、版本和图标。放在最后是
        // 为了先读完本地恢复结果，避免重建已有记录。
        return await recoverRecordsFromLocalInventory(localInventoryOnly: localInventoryOnly)
    }

    /// Recover installed apps without touching import or signed-file transactions.
    /// Device reads acquire their own service lease; local inventory stays independent.
    func restoreInstalledApps(localInventoryOnly: Bool = false) async -> InstalledRecordRecoverySummary {
        await recoverRecordsFromLocalInventory(localInventoryOnly: localInventoryOnly)
    }

    /// 从本机安装清单恢复设备上仍存在、带 Seal 逐应用标记且本地记录丢失的应用。
    /// 只新增系统当前列出的 App；卸载清理由另一条完整清单路径负责。
    private func recoverRecordsFromLocalInventory(
        localInventoryOnly: Bool
    ) async -> InstalledRecordRecoverySummary {
        var summary = InstalledRecordRecoverySummary()
        let storedRecords = (try? await appStore.fetchAll()) ?? []
        // 没接线就**完全不碰设备**（测试 / 预览走这里）。`skipped-not-wired` 必须与
        // `skipped-no-candidates` 分得开 —— 前者是「没人接这根线」（配置问题），
        // 后者是「接了线、设备端确实没有可补的」（正常结论）。
        guard let deviceScanner else {
            summary.stage = "skipped-not-wired"
            return summary
        }
        // Known records recover icons through LaunchServices alone; no device channel is needed.
        let iconRecovery = await recoverMissingIcons(for: storedRecords, scanner: deviceScanner)
        summary.iconsUpdated = iconRecovery.updatedCount
        // LaunchServices 是本机系统清单，不依赖 Wi-Fi / LocalDevVPN。恢复只会新增已确认
        // 安装的记录，不会据此清理，因此可安全接收部分系统枚举源的结果。
        let installedApplications: [DeviceInstalledApplicationSummary]?
        let profileSummaries: [DeviceProvisioningProfileSummary]?
        if localInventoryOnly {
            installedApplications = InstalledRecordRecoveryPolicy.mergeInstalledApplications(
                local: await deviceScanner.scanLocalApplications(),
                paired: nil
            )
            profileSummaries = nil
        } else {
            async let localScan = deviceScanner.scanLocalApplications()
            async let pairedScan = deviceScanner.scanUserApplications()
            async let profileScan = deviceScanner.scanProfileSummaries()
            let (localApplications, pairedApplications, profiles) = await (
                localScan,
                pairedScan,
                profileScan
            )
            installedApplications = InstalledRecordRecoveryPolicy.mergeInstalledApplications(
                local: localApplications,
                paired: pairedApplications
            )
            profileSummaries = profiles
        }
        if localInventoryOnly, installedApplications == nil {
            summary.stage = "skipped-local-inventory-unavailable"
            return summary
        }
        guard let installedApplications else {
            summary.stage = "skipped-app-list-unavailable"
            return summary
        }
        var records = (try? await appStore.fetchAll()) ?? iconRecovery.records
        var accounts: [AppleAccountRecord] = []
        if let accountsProvider {
            accounts = await accountsProvider()
        }
        let applicationsByBundleIdentifier = Dictionary(
            installedApplications.map {
                (InstalledRecordRecoveryPolicy.normalizedBundleIdentifier($0.bundleIdentifier), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for index in records.indices {
            let record = records[index]
            guard record.isSeal == false, record.state == .installed else { continue }
            let bundleIdentifier = record.mappedBundleIdentifier
                ?? record.preferredBundleIdentifier
                ?? record.originalBundleIdentifier
            let normalizedBundleIdentifier = InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(
                bundleIdentifier
            )
            guard let application = applicationsByBundleIdentifier[normalizedBundleIdentifier] else { continue }
            let hasOriginalIPA = (try? await fileStore.exists(relativePath: record.ipaRelativePath)) == true
            let isRecoveredRecord = record.importWarnings.contains(AppRecord.deviceRecoveryWarning)
            guard isRecoveredRecord || hasOriginalIPA == false else { continue }

            var enriched = record
            if hasOriginalIPA == false {
                enriched.needsIPAImport = true
                if isRecoveredRecord == false {
                    enriched.importWarnings.append(AppRecord.deviceRecoveryWarning)
                }
            }
            if enriched.signedDeviceIdentifier == nil,
               enriched.signedIPARelativePath == nil,
               enriched.signedIPASHA256 == nil {
                enriched.certificateSerialNumber = nil
            }
            let displayName = application.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordNameIsBundleIdentifier = [bundleIdentifier, record.originalBundleIdentifier]
                .contains(where: { record.name.caseInsensitiveCompare($0) == .orderedSame })
            if displayName.isEmpty == false,
               (record.name.isEmpty || recordNameIsBundleIdentifier) {
                enriched.name = displayName
            }
            if application.shortVersion.isEmpty == false {
                enriched.version = application.shortVersion
            }
            if application.buildNumber.isEmpty == false {
                enriched.buildNumber = application.buildNumber
            }
            if let teamIdentifier = application.teamIdentifier {
                enriched.signingTeamID = teamIdentifier
            }
            if let markerVersion = application.sealManagedMarkerVersion {
                enriched.installedAppMarkerVersion = markerVersion
            }
            if let teamIdentifier = enriched.signingTeamID,
               let account = accounts.first(where: {
                   $0.teamID.caseInsensitiveCompare(teamIdentifier) == .orderedSame
               }) {
                enriched.accountID = account.id
            }

            if enriched.signingTargets.isEmpty,
               let profileSummaries,
               let binding = InstalledRecordRecoveryPolicy.profileBinding(
                   from: profileSummaries,
                   bundleIdentifier: bundleIdentifier,
                   teamIdentifier: enriched.signingTeamID
               ) {
                enriched.signingTargets = [
                    SigningTargetRecord(binding: binding, signedBundleIdentifier: bundleIdentifier)
                ]
                enriched.provisioningProfileUUID = binding.profileUUID
                enriched.provisioningProfileName = binding.profileName
                enriched.provisioningProfileCreationDate = binding.creationDate
                enriched.provisioningProfileExpirationDate = binding.expirationDate
                enriched.expiryDate = binding.expirationDate
            }
            guard enriched != record else { continue }
            try? await appStore.save(enriched)
            records[index] = enriched
        }
        let context = InstalledRecordRecoveryPolicy.context(
            records: records,
            accountTeamIdentifiers: Set(accounts.map(\.teamID)),
            dismissedBundleIdentifiers: DismissedInstalledRecordTombstones.all(),
            sealCanonicalBundleIdentifier: BundleIDPolicy.canonicalSealBundleIdentifier()
        )
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            installedApplications: installedApplications,
            profiles: profileSummaries,
            context: context
        )
        summary.candidates = drafts.count
        summary.samples = drafts.prefix(3).map(\.bundleIdentifier)
        let installedBundleIdentifiers = Set(installedApplications.map {
            InstalledRecordRecoveryPolicy.normalizedBundleIdentifier($0.bundleIdentifier)
        })
        var recordsNeedingIcons: [AppRecord] = []
        for record in records where record.isSeal == false && record.belongsInInstalledList {
            let bundleIdentifier = record.mappedBundleIdentifier
                ?? record.preferredBundleIdentifier
                ?? record.originalBundleIdentifier
            let normalizedBundleIdentifier = InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(
                bundleIdentifier
            )
            guard installedBundleIdentifiers.contains(normalizedBundleIdentifier) else { continue }

            var hasReadableIcon = false
            for iconPath in AppIconDataResolver.iconRelativePaths(for: record) {
                if (try? await fileStore.read(relativePath: iconPath)) != nil {
                    hasReadableIcon = true
                    break
                }
            }
            if hasReadableIcon == false {
                recordsNeedingIcons.append(record)
            }
        }

        let candidateBundleIdentifiers = Set(drafts.map {
            InstalledRecordRecoveryPolicy.normalizedBundleIdentifier($0.bundleIdentifier)
        } + recordsNeedingIcons.map { record in
            InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(
                record.mappedBundleIdentifier
                    ?? record.preferredBundleIdentifier
                    ?? record.originalBundleIdentifier
            )
        })
        // 没有新记录，也没有缺失图标的已安装记录时，不再重复读取图标。
        guard candidateBundleIdentifiers.isEmpty == false else {
            summary.stage = "skipped-no-candidates"
            return summary
        }
        let iconDataByBundleIdentifier = await deviceScanner.scanIconData(
            for: candidateBundleIdentifiers
        )
        for var record in recordsNeedingIcons {
            let bundleIdentifier = record.mappedBundleIdentifier
                ?? record.preferredBundleIdentifier
                ?? record.originalBundleIdentifier
            let normalizedBundleIdentifier = InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(
                bundleIdentifier
            )
            guard let iconData = iconDataByBundleIdentifier[normalizedBundleIdentifier],
                  let iconPath = try? await fileStore.storeIcon(data: iconData, appID: record.id) else {
                continue
            }
            record.iconRelativePath = iconPath
            do {
                try await appStore.save(record)
                summary.iconsUpdated += 1
            } catch {
                continue
            }
        }
        for draft in drafts {
            let accountID = draft.teamIdentifier.flatMap { teamID in
                accounts.first { $0.teamID.caseInsensitiveCompare(teamID) == .orderedSame }?.id
            }
            let recordID = UUID()
            var record = InstalledRecordRecoveryPolicy.makeRecord(
                from: draft,
                accountID: accountID,
                id: recordID
            )
            let normalizedBundleID = InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(
                draft.bundleIdentifier
            )
            if let iconData = iconDataByBundleIdentifier[normalizedBundleID] {
                record.iconRelativePath = try? await fileStore.storeIcon(data: iconData, appID: recordID)
            }
            do {
                try await appStore.save(record)
                summary.recovered += 1
            } catch {
                let nsError = error as NSError
                summary.stage = "failed-save"
                summary.firstError = "\(nsError.domain) \(nsError.code)"
                break
            }
        }
        return summary
    }

    private func recoverMissingIcons(
        for sourceRecords: [AppRecord],
        scanner: any InstalledAppScanning
    ) async -> (records: [AppRecord], updatedCount: Int) {
        var records = sourceRecords
        var bundleIdentifierByRecordID: [UUID: String] = [:]
        for record in records where record.isSeal == false && record.belongsInInstalledList {
            var hasReadableIcon = false
            for path in AppIconDataResolver.iconRelativePaths(for: record) {
                if (try? await fileStore.read(relativePath: path)) != nil {
                    hasReadableIcon = true
                    break
                }
            }
            guard hasReadableIcon == false else { continue }
            let bundleIdentifier = InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(
                record.mappedBundleIdentifier
                    ?? record.preferredBundleIdentifier
                    ?? record.originalBundleIdentifier
            )
            bundleIdentifierByRecordID[record.id] = bundleIdentifier
        }
        guard bundleIdentifierByRecordID.isEmpty == false else { return (records, 0) }

        let icons = await scanner.scanIconData(
            for: Set(bundleIdentifierByRecordID.values)
        )
        var updatedCount = 0
        for index in records.indices {
            let recordID = records[index].id
            guard let bundleIdentifier = bundleIdentifierByRecordID[recordID],
                  let iconData = icons[bundleIdentifier],
                  let iconPath = try? await fileStore.storeIcon(data: iconData, appID: recordID) else {
                continue
            }
            var updated = records[index]
            updated.iconRelativePath = iconPath
            do {
                try await appStore.save(updated)
                records[index] = updated
                updatedCount += 1
            } catch {
                continue
            }
        }
        return (records, updatedCount)
    }

    private func recoverPendingFileTransactions() async throws {
        try await fileStore.recoverSignedIPAReplacementArtifacts()
        let transactions = try await fileStore.pendingImportTransactions()
        guard transactions.isEmpty == false else { return }

        var records = try await appStore.fetchAll()
        var failedTransactionCount = 0
        for transaction in transactions {
            let matchingRecord = records.first { $0.pendingFileTransactionID == transaction.id }

            if matchingRecord != nil || transaction.phase == .finalized {
                do {
                    let finalized = transaction.phase == .finalized
                        ? transaction
                        : try await fileStore.finalizeImportCommit(transaction)
                    if var record = matchingRecord {
                        record.pendingFileTransactionID = nil
                        try await appStore.save(record)
                        if let index = records.firstIndex(where: { $0.id == record.id }) {
                            records[index] = record
                        }
                    }
                    try await fileStore.completeImportCommit(finalized)
                } catch {
                    // Leave the journal intact so a later launch can retry.
                    failedTransactionCount += 1
                }
            } else {
                do {
                    try await fileStore.abortImportCommit(transaction)
                } catch {
                    failedTransactionCount += 1
                }
            }
        }

        if failedTransactionCount > 0 {
            throw ImportFailure(
                title: "本地事务恢复未完成",
                reason: "有 \(failedTransactionCount) 个 IPA 文件事务仍需恢复，恢复记录已保留。",
                recovery: "下次启动 Seal 会自动继续恢复",
                code: "SEAL-IPA-214"
            )
        }
    }

    private func reconcileKnownRecords() async throws {
        var records = try await appStore.fetchAll()
        for index in records.indices {
            var record = records[index]
            guard let signedPath = record.signedIPARelativePath else { continue }
            let exists = try await fileStore.exists(relativePath: signedPath)
            if exists == false {
                record.signedArtifactStatus = .missing
                if record.state != .installed && record.isSeal == false {
                    record.state = .signed
                }
                try await appStore.save(record)
                records[index] = record
                continue
            }

            do {
                let hash = try await fileStore.sha256(relativePath: signedPath)
                if let expected = record.signedIPASHA256,
                   expected.caseInsensitiveCompare(hash) != .orderedSame {
                    record.signedArtifactStatus = .damaged
                } else {
                    // Legacy signed packages gain integrity metadata during migration.
                    record.signedIPASHA256 = hash
                    if record.signedArtifactStatus == nil
                        || record.signedArtifactStatus == .missing
                        || record.signedArtifactStatus == .damaged {
                        record.signedArtifactStatus = record.state == .installed ? .installed : .available
                    }
                }
                try await appStore.save(record)
                records[index] = record
            } catch {
                record.signedArtifactStatus = .damaged
                if record.state != .installed && record.isSeal == false {
                    record.state = .signed
                }
                try await appStore.save(record)
                records[index] = record
            }
        }
    }

    private struct RecoveredSignedArtifact {
        let relativePath: String
        let sha256: String
        let mappedBundleIdentifier: String?
    }

    private func recoveredSignedArtifact(appID: UUID) async throws -> RecoveredSignedArtifact? {
        guard let signed = try await fileStore.storedSignedIPA(appID: appID) else { return nil }
        let hash = try await fileStore.sha256(relativePath: signed.relativePath)
        let mappedBundleIdentifier = (try? parser.parse(url: signed.url))?.bundleIdentifier
        return RecoveredSignedArtifact(
            relativePath: signed.relativePath,
            sha256: hash,
            mappedBundleIdentifier: mappedBundleIdentifier
        )
    }

    private static func matchesSealBundleIdentifier(
        _ bundleIdentifier: String,
        record: AppRecord
    ) -> Bool {
        bundleIdentifier == record.originalBundleIdentifier
            || bundleIdentifier == record.mappedBundleIdentifier
    }
}
