import Foundation
import Testing
@testable import Seal

struct AppRecordRecoveryTests {
    @Test
    func restoresPendingRecordFromAPreservedOriginalIPA() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let appID = UUID()
        let staged = try await environment.fileStore.stage(sourceURL: source)
        _ = try await environment.fileStore.commit(
            staged: staged,
            appID: appID,
            iconData: nil
        )

        try await AppRecordRecovery(
            appStore: environment.appStore,
            fileStore: environment.fileStore
        ).restoreMissingRecords()

        let records = try await environment.appStore.fetchAll()
        let restored = try #require(records.first)
        #expect(restored.id == appID)
        #expect(restored.originalBundleIdentifier == "com.example.demo")
        #expect(restored.state == .imported)
        #expect(restored.accountID == nil)
    }

    @Test
    func orphanWithSignedIPAIsRecoveredAsSignedAwaitingVerification() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let appID = UUID()
        let staged = try await environment.fileStore.stage(sourceURL: source)
        _ = try await environment.fileStore.commit(staged: staged, appID: appID, iconData: nil)
        _ = try await environment.fileStore.storeSignedIPA(sourceURL: source, appID: appID)

        try await AppRecordRecovery(
            appStore: environment.appStore,
            fileStore: environment.fileStore
        ).restoreMissingRecords()

        let restored = try #require(try await environment.appStore.fetchAll().first)
        #expect(restored.state == .signed)
        #expect(restored.signedArtifactStatus == .awaitingVerification)
        #expect(restored.signedIPASHA256?.isEmpty == false)
        #expect(restored.accountID == nil)
    }

    @Test
    func doesNotCreateADuplicateForAnExistingSealRecord() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make(
            apps: [.init(bundleIdentifier: "com.mjorb.seal")]
        )
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let staleAppID = UUID()
        let currentAppID = UUID()
        let staged = try await environment.fileStore.stage(sourceURL: source)
        _ = try await environment.fileStore.commit(
            staged: staged,
            appID: staleAppID,
            iconData: nil
        )
        let currentStaged = try await environment.fileStore.stage(sourceURL: source)
        let files = try await environment.fileStore.commit(
            staged: currentStaged,
            appID: currentAppID,
            iconData: nil
        )
        try await environment.appStore.save(
            AppRecord(
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                size: 1,
                state: .installed,
                ipaRelativePath: files.ipaRelativePath,
                isSeal: true,
                importedAt: Date()
            )
        )

        try await AppRecordRecovery(
            appStore: environment.appStore,
            fileStore: environment.fileStore
        ).restoreMissingRecords()

        #expect(try await environment.appStore.fetchAll().count == 1)
    }

    @Test
    func persistsIconReadFromDeviceForRecoveredInstalledApp() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let bundleIdentifier = "com.example.demo.ABCDE12345"
        let iconData = try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")
        )
        let scanner = FakeInstalledAppScanner(
            bundleIdentifier: bundleIdentifier,
            iconData: iconData
        )

        try await AppRecordRecovery(
            appStore: environment.appStore,
            fileStore: environment.fileStore,
            deviceScanner: scanner
        ).restoreMissingRecords()

        let recovered = try #require(try await environment.appStore.fetchAll().first)
        let iconPath = try #require(recovered.iconRelativePath)
        #expect(try await environment.fileStore.read(relativePath: iconPath) == iconData)
    }

    @Test
    func fillsMissingIconForExistingDeviceScannedRecordWithoutIPA() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let bundleIdentifier = "com.example.demo.ABCDE12345"
        let appID = UUID()
        let iconData = try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")
        )
        try await environment.appStore.save(
            AppRecord(
                id: appID,
                originalBundleIdentifier: "com.example.demo",
                mappedBundleIdentifier: bundleIdentifier,
                name: "Demo",
                version: "1.0",
                buildNumber: "1",
                size: 0,
                state: .installed,
                signingTeamID: "ABCDE12345",
                ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
                needsIPAImport: true,
                importedAt: Date()
            )
        )
        let scanner = FakeInstalledAppScanner(
            bundleIdentifier: bundleIdentifier,
            iconData: iconData
        )

        try await AppRecordRecovery(
            appStore: environment.appStore,
            fileStore: environment.fileStore,
            deviceScanner: scanner
        ).restoreMissingRecords()

        let records = try await environment.appStore.fetchAll()
        #expect(records.count == 1)
        let iconPath = try #require(records.first?.iconRelativePath)
        #expect(try await environment.fileStore.read(relativePath: iconPath) == iconData)
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealRecoveryTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return Environment(
            root: root,
            fileStore: AppFileStore(documentsDirectory: documents, cacheDirectory: cache),
            appStore: try CoreDataAppStore(inMemory: true)
        )
    }
}

private extension AppRecordRecoveryTests {
    struct Environment {
        let root: URL
        let fileStore: AppFileStore
        let appStore: CoreDataAppStore
    }

    struct FakeInstalledAppScanner: InstalledAppScanning {
        let bundleIdentifier: String
        let iconData: Data

        func scanProfileSummaries() async -> [DeviceProvisioningProfileSummary]? {
            [DeviceProvisioningProfileSummary(
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: "ABCDE12345",
                uuid: "PROFILE-ICON-1",
                name: "Profile",
                creationDate: nil,
                expirationDate: Date(timeIntervalSince1970: 2_100_000_000)
            )]
        }

        func scanValidatedUserApplications() async -> [DeviceInstalledApplicationSummary]? {
            [DeviceInstalledApplicationSummary(
                bundleIdentifier: bundleIdentifier,
                displayName: "Demo",
                shortVersion: "1.0",
                buildNumber: "1",
                profileValidated: true
            )]
        }

        func scanIconData(for normalizedBundleIdentifiers: Set<String>) async -> [String: Data] {
            guard normalizedBundleIdentifiers.contains(bundleIdentifier.lowercased()) else { return [:] }
            return [bundleIdentifier.lowercased(): iconData]
        }

        func scanConfirmedInstalledBundleIdentifiers(
            candidates: [String],
            positiveControl: String?
        ) async -> Set<String>? {
            Set(candidates.map(InstalledRecordRecoveryPolicy.normalizedBundleIdentifier))
        }
    }
}
