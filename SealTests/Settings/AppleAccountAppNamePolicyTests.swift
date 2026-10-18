import Foundation
import Testing
@testable import Seal

struct AppleAccountAppNamePolicyTests {
    @Test
    func usesTheImportedSoftwareNameForTheMatchingAccountAndSignedBundleID() {
        let accountID = UUID()
        let app = AppRecord(
            originalBundleIdentifier: "com.example.song",
            mappedBundleIdentifier: "com.example.song.TEAMID",
            name: "歌一刀",
            version: "2.5.0",
            buildNumber: "25",
            size: 1,
            state: .installed,
            accountID: accountID,
            ipaRelativePath: "Apps/song/Original.ipa",
            preferredBundleIdentifier: "com.example.song.TEAMID",
            preferredDisplayName: "自定义昵称",
            importedAt: Date()
        )

        let name = AppleAccountAppNamePolicy.name(
            for: "COM.EXAMPLE.SONG.TEAMID",
            accountID: accountID,
            relatedApps: [app]
        )

        #expect(name == "歌一刀")
    }

    @Test
    func doesNotUseAnAppNameFromAnotherAccount() {
        let app = AppRecord(
            originalBundleIdentifier: "com.example.song",
            name: "歌一刀",
            version: "2.5.0",
            buildNumber: "25",
            size: 1,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: "Apps/song/Original.ipa",
            importedAt: Date()
        )

        let name = AppleAccountAppNamePolicy.name(
            for: "com.example.song",
            accountID: UUID(),
            relatedApps: [app]
        )

        #expect(name == "App 名称未记录")
    }

    @Test
    func showsTheApplicationIdentifierReadFromTheSignedTarget() {
        let accountID = UUID()
        let expirationDate = Date(timeIntervalSince1970: 1_900_000_000)
        let signingTarget = SigningTargetRecord(
            bundleIdentifier: "com.example.song.TEAMID",
            profileUUID: "profile-id",
            profileName: "Development",
            profileCreationDate: nil,
            profileExpirationDate: expirationDate,
            teamIdentifier: "TEAMID",
            certificateSerialNumbers: [],
            deviceIdentifiers: [],
            entitlements: ["application-identifier": .string("PREFIX.*")],
            applicationIdentifier: "ACTUALPREFIX.com.example.song.TEAMID"
        )
        let app = AppRecord(
            originalBundleIdentifier: "com.example.song",
            mappedBundleIdentifier: "com.example.song.TEAMID",
            name: "歌一刀",
            version: "2.5.0",
            buildNumber: "25",
            size: 1,
            state: .installed,
            accountID: accountID,
            signingTargets: [signingTarget],
            ipaRelativePath: "Apps/song/Original.ipa",
            importedAt: Date()
        )

        #expect(AppleAccountAppNamePolicy.applicationIdentifier(
            for: "com.example.song.TEAMID",
            accountID: accountID,
            relatedApps: [app]
        ) == "ACTUALPREFIX.com.example.song.TEAMID")
    }
}
