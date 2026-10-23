import Foundation
import Testing
@testable import Seal

/// 0.1.52 第 2 项根因回归：2026-10-09 两记录模型下，待更新 Seal 记录是独立新
/// 记录（`replacesInstalledAppID` 指向已安装记录），而 `SelfAppRegistrar` 的
/// 待更新保护只看已安装记录上恒 false 的旧标志、重复清理又没有豁免，于是
/// 待更新记录被连文件删掉，签名抽屉拿着已删 ID 连撞 SEAL-SIGN-404。
/// 这里钉住同源判据 `SelfAppPendingUpdateProtection` 与清理的实际行为。
struct SelfAppRegistrarPendingUpdateProtectionTests {
    // MARK: - 纯函数判据（任务指定的三个场景，各一）

    /// 场景一：已安装 + 待更新并存。待更新记录不是清理候选；同场的普通重复
    /// 记录仍然是候选（豁免不能变成「整轮不清理」）。
    @Test
    func cleanupExemptsPendingUpdateSourceWhenInstalledAndPendingCoexist() {
        let installed = makeRecord(version: "1.0", buildNumber: "1")
        var pending = makeRecord(version: "1.1", buildNumber: "2")
        pending.state = .imported
        pending.replacesInstalledAppID = installed.id
        pending.pendingUpdateSourceFingerprint = "pending-fingerprint"
        let staleDuplicate = makeRecord(version: "0.9", buildNumber: "0")

        let records = [installed, pending, staleDuplicate]

        #expect(SelfAppPendingUpdateProtection.isPendingUpdateSource(pending))
        #expect(SelfAppPendingUpdateProtection.isPendingUpdateSource(installed) == false)
        #expect(
            SelfAppPendingUpdateProtection.pendingUpdateSource(in: records)?.id == pending.id
        )
        #expect(
            SelfAppPendingUpdateProtection.duplicateCleanupCandidates(
                in: records,
                keepID: installed.id
            ).map(\.id) == [staleDuplicate.id]
        )
    }

    /// 场景二：只有待更新记录在（已安装记录已被清掉）。哪怕保留 ID 是别的
    /// 记录，待更新源也不得成为清理候选 —— 删它就等于删掉唯一的更新包。
    @Test
    func cleanupExemptsTheOnlyPendingUpdateSource() {
        var pending = makeRecord(version: "1.1", buildNumber: "2")
        pending.state = .imported
        pending.replacesInstalledAppID = UUID()
        pending.pendingUpdateSourceFingerprint = "pending-fingerprint"

        #expect(SelfAppPendingUpdateProtection.isPendingUpdateSource(pending))
        #expect(
            SelfAppPendingUpdateProtection.duplicateCleanupCandidates(
                in: [pending],
                keepID: UUID()
            ).isEmpty
        )
    }

    /// 场景三：更新已结算。交接路径会把替换链接与待更新指纹一并清掉、指纹
    /// 转记为已装指纹 —— 此后这条记录不再受豁免，可按普通重复记录清理。
    @Test
    func cleanupAllowsSettledRecordAfterReplacementIsCommitted() {
        let installed = makeRecord(version: "1.1", buildNumber: "2")
        var settled = makeRecord(version: "1.1", buildNumber: "2")
        settled.state = .installed
        settled.replacesInstalledAppID = nil
        settled.pendingUpdateSourceFingerprint = nil
        settled.installedFingerprint = "pending-fingerprint"

        #expect(SelfAppPendingUpdateProtection.isPendingUpdateSource(settled) == false)
        #expect(
            SelfAppPendingUpdateProtection.duplicateCleanupCandidates(
                in: [installed, settled],
                keepID: installed.id
            ).map(\.id) == [settled.id]
        )
    }

    // MARK: - 集成：回前台/启动自注册不得删待更新记录及其文件

    @Test
    func registrationPreservesPendingUpdateSourceAndFileWhileCleaningOtherDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealPendingUpdateProtection-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let appStore = try CoreDataAppStore(inMemory: true)
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)

        func writeIPA(for recordID: UUID, contents: String) throws -> URL {
            let url = documents.appending(path: "Apps/\(recordID.uuidString)/Original.ipa")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
            return url
        }

        var installed = makeRecord(version: "1.0", buildNumber: "1")
        installed.state = .installed
        installed.isPinned = true
        _ = try writeIPA(for: installed.id, contents: "installed")

        var pending = makeRecord(version: "1.1", buildNumber: "2")
        pending.state = .imported
        pending.isPinned = true
        pending.replacesInstalledAppID = installed.id
        pending.pendingUpdateSourceFingerprint = "pending-fingerprint"
        let pendingURL = try writeIPA(for: pending.id, contents: "pending-update")

        var staleDuplicate = makeRecord(version: "0.9", buildNumber: "0")
        staleDuplicate.state = .imported
        let staleURL = try writeIPA(for: staleDuplicate.id, contents: "stale-duplicate")

        try await appStore.save(installed)
        try await appStore.save(pending)
        try await appStore.save(staleDuplicate)

        let currentBundle = root.appending(path: "CurrentSeal.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: currentBundle, withIntermediateDirectories: true)
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: currentBundle,
                bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: nil,
                signingTeamIdentifier: nil,
                signingApplicationIdentifier: nil
            ),
            appStore: appStore,
            accountRepository: PendingUpdateEmptyAccountRepository(),
            fileStore: fileStore
        )

        try await registrar.ensureRegistered()

        let records = try await appStore.fetchAll()
        #expect(Set(records.map(\.id)) == [installed.id, pending.id])
        let preservedPending = try #require(records.first { $0.id == pending.id })
        #expect(preservedPending.replacesInstalledAppID == installed.id)
        #expect(preservedPending.pendingUpdateSourceFingerprint == "pending-fingerprint")
        #expect(try Data(contentsOf: pendingURL) == Data("pending-update".utf8))
        #expect(FileManager.default.fileExists(atPath: staleURL.path) == false)
    }

    /// 残留链接结算（2026-10-23 收口未决②）：只剩待更新记录、且它与运行包
    /// 同版本同构建（更新已装上、前任记录已删）时，自注册应直接把它结算为
    /// 已安装 —— 清替换链接、待更新指纹转正，否则它永远挂在待安装列表。
    @Test
    func registrationSettlesResidualPendingRecordMatchingRunningVersion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealPendingResidual-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let appStore = try CoreDataAppStore(inMemory: true)
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)

        var residual = makeRecord(version: "1.0", buildNumber: "1")
        residual.state = .imported
        residual.replacesInstalledAppID = UUID()
        residual.pendingUpdateSourceFingerprint = "pending-fingerprint"
        let ipaURL = documents.appending(path: "Apps/\(residual.id.uuidString)/Original.ipa")
        try FileManager.default.createDirectory(
            at: ipaURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("residual".utf8).write(to: ipaURL)
        try await appStore.save(residual)

        let currentBundle = root.appending(path: "CurrentSeal.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: currentBundle, withIntermediateDirectories: true)
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: currentBundle,
                bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: nil,
                signingTeamIdentifier: nil,
                signingApplicationIdentifier: nil
            ),
            appStore: appStore,
            accountRepository: PendingUpdateEmptyAccountRepository(),
            fileStore: fileStore
        )

        try await registrar.ensureRegistered()

        let records = try await appStore.fetchAll()
        let settled = try #require(records.first { $0.id == residual.id })
        #expect(settled.state == .installed)
        #expect(settled.replacesInstalledAppID == nil)
        #expect(settled.installedFingerprint == "pending-fingerprint")
        #expect(settled.pendingUpdateSourceFingerprint == nil)
    }

    // MARK: - 夹具

    private func makeRecord(version: String, buildNumber: String) -> AppRecord {
        let id = UUID()
        return AppRecord(
            id: id,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal",
            name: "Seal",
            version: version,
            buildNumber: buildNumber,
            size: 100,
            state: .installed,
            ipaRelativePath: "Apps/\(id.uuidString)/Original.ipa",
            preferredBundleIdentifier: "com.mjorb.seal",
            isSeal: true,
            importedAt: .distantPast
        )
    }
}

private actor PendingUpdateEmptyAccountRepository: AccountRepository {
    func fetchAll() throws -> [AppleAccountRecord] { [] }
    func save(_ account: AppleAccountRecord) throws {}
    func delete(id: UUID) throws {}
}
