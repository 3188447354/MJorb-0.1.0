import AltSign
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

    @Test
    func usesAppleReturnedNameAndAppIDWhenNoLocalSigningRecordExists() {
        let accountID = UUID()
        let snapshot = makeSnapshot()
        #expect(AppleAccountAppNamePolicy.displayName(
            for: snapshot.bundleIdentifier,
            accountID: accountID,
            relatedApps: [],
            fallbackAppleName: snapshot.name
        ) == "Apple 中的名称")
        #expect(AppleAccountAppNamePolicy.applicationIdentifier(
            for: snapshot.bundleIdentifier,
            accountID: accountID,
            relatedApps: [],
            fallbackAppleAppID: snapshot.identifier
        ) == "APPLE-APP-ID")
    }

    @Test
    func keepsAppIDWithoutAppleExpirationAndUsesReturnedDateWhenAvailable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ApplePortalAppIDPolicy.includes(expirationDate: nil, fetchedAt: now))
        #expect(ApplePortalAppIDPolicy.includes(
            expirationDate: now.addingTimeInterval(60),
            fetchedAt: now
        ))
        #expect(ApplePortalAppIDPolicy.includes(
            expirationDate: now,
            fetchedAt: now
        ) == false)

        let snapshot = makeSnapshot(appIDExpirationDate: now.addingTimeInterval(86_400))
        #expect(AppleAccountAppNamePolicy.expirationDate(
            for: snapshot.bundleIdentifier,
            snapshot: snapshot,
            accountID: UUID(),
            relatedApps: []
        ) == now.addingTimeInterval(86_400))
    }

    @Test
    func expirationOrderingPutsSoonestFirstAndUndatedLast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppleAccountAppNamePolicy.expirationComesBefore(
            now.addingTimeInterval(3_600), now.addingTimeInterval(86_400)
        ))
        #expect(AppleAccountAppNamePolicy.expirationComesBefore(now, nil))
        #expect(AppleAccountAppNamePolicy.expirationComesBefore(nil, now) == false)
    }

    @Test
    func highlightsExpirationsWithinOneDayAndAlreadyExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppleAccountAppNamePolicy.shouldHighlightExpiration(
            now.addingTimeInterval(86_400), now: now
        ))
        #expect(AppleAccountAppNamePolicy.shouldHighlightExpiration(
            now.addingTimeInterval(86_401), now: now
        ) == false)
        #expect(AppleAccountAppNamePolicy.shouldHighlightExpiration(now.addingTimeInterval(-1), now: now))
        #expect(AppleAccountAppNamePolicy.shouldHighlightExpiration(nil, now: now) == false)
    }

    @Test
    func parsesAppleJSONExpirationDateFromISO8601String() throws {
        for rawDate in ["2026-10-25T10:35:09Z", "2026-10-25T10:35:09.125Z"] {
            let appID = try #require(ALTAppID(responseDictionary: [
                "name": "Music Player",
                "appIdId": "APPLE-APP-ID",
                "identifier": "com.example.music",
                "expirationDate": rawDate
            ]))

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions.insert(.withFractionalSeconds)
            let expectedDate = fractionalFormatter.date(from: rawDate)
                ?? ISO8601DateFormatter().date(from: rawDate)
            #expect(appID.expirationDate == expectedDate)
        }
    }

    private func makeSnapshot(appIDExpirationDate: Date? = nil) -> ApplePortalAppIDSnapshot {
        ApplePortalAppIDSnapshot(
            identifier: "APPLE-APP-ID",
            name: "Apple 中的名称",
            bundleIdentifier: "com.example.appleapp",
            appIDExpirationDate: appIDExpirationDate,
            provisioningProfileName: nil,
            provisioningProfileExpirationDate: nil,
            provisioningProfileState: .unavailable
        )
    }
}
