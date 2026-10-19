import Foundation
import Testing
@testable import Seal

struct BundleIDMapperTests {
    @Test
    func preservesSourceBundleIdentifierAcrossTeams() {
        let mapper = BundleIDMapper()
        let first = mapper.mainBundleID(original: "com.example.demo", teamID: "TEAM1")
        let sameTeam = mapper.mainBundleID(original: "com.example.demo", teamID: "TEAM1")
        let otherTeam = mapper.mainBundleID(original: "com.example.demo", teamID: "TEAM2")
        let appExtension = mapper.extensionBundleID(
            original: "com.example.demo.share",
            originalMainBundleID: "com.example.demo",
            mappedMainBundleID: first
        )
        // Team 不参与 Bundle ID 命名；Apple 的 App ID 在各自开发团队内管理。
        #expect(first == "com.example.demo")
        #expect(first == sameTeam)
        #expect(otherTeam == "com.example.demo")
        #expect(first == otherTeam)
        #expect(appExtension == "com.example.demo.share")
    }

    @Test
    func unrelatedExtensionBundleIdentifierIsPreserved() {
        let mapper = BundleIDMapper()
        #expect(
            mapper.extensionBundleID(
                original: "com.vendor.extension",
                originalMainBundleID: "com.vendor.app",
                mappedMainBundleID: "com.user.app"
            ) == "com.vendor.extension"
        )
    }

    @Test
    func requestedMainBundleIdentifierIsUsedExactlyAsShownInTheEditor() {
        let mapper = BundleIDMapper()
        // 默认值可以含 Team 后缀，用户编辑后的值也必须原样用于签名。
        #expect(
            mapper.mainBundleID(
                original: "com.example.demo",
                teamID: "TEAM1",
                requested: "com.example.demo.TEAM1"
            ) == "com.example.demo.TEAM1"
        )
        #expect(
            mapper.mainBundleID(
                original: "com.example.demo",
                teamID: "TEAM1",
                requested: "com.example.custom"
            ) == "com.example.custom"
        )
        #expect(
            mapper.mainBundleID(
                original: "com.example.demo",
                teamID: "TEAM1",
                requested: ""
            ).isEmpty
        )
    }

    @Test
    func policyKeepsTheVisibleDefaultOrUserEditedBundleIdentifier() throws {
        let imported = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .preflightPassed,
            ipaRelativePath: "Apps/demo.ipa",
            importedAt: Date()
        )

        #expect(
            try BundleIDPolicy.targetBundleIdentifier(
                for: imported,
                requestedBundleIdentifier: "com.example.demo.TEAM1"
            ) == "com.example.demo.TEAM1"
        )
        #expect(
            try BundleIDPolicy.targetBundleIdentifier(
                for: imported,
                requestedBundleIdentifier: "com.example.custom"
            ) == "com.example.custom"
        )
        #expect(throws: ImportFailure.self) {
            try BundleIDPolicy.targetBundleIdentifier(
                for: imported,
                requestedBundleIdentifier: ""
            )
        }
    }

    @Test
    func policyIgnoresRequestedBundleIdentifierForRenewal() throws {
        let installed = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/demo.ipa",
            importedAt: Date()
        )

        #expect(
            try BundleIDPolicy.targetBundleIdentifier(
                for: installed,
                requestedBundleIdentifier: "com.example.demo.other"
            ) == "com.example.demo.seal"
        )
    }

    @Test
    func policyUsesMappedBundleIdentifierForInstalledRenewal() throws {
        var installed = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/demo.ipa",
            importedAt: Date()
        )
        installed.preferredBundleIdentifier = "com.example.demo.old"

        #expect(try BundleIDPolicy.targetBundleIdentifier(for: installed) == "com.example.demo.seal")
    }

    @Test
    func policyRejectsInstalledRenewalWithoutSignedBundleIdentifier() throws {
        let installed = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: nil,
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/demo.ipa",
            importedAt: Date()
        )

        #expect(throws: ImportFailure.self) {
            try BundleIDPolicy.targetBundleIdentifier(for: installed)
        }
    }

    @Test
    func policyIgnoresRequestedBundleIdentifierForSealPackage() throws {
        let seal = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.current",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/seal.ipa",
            isSeal: true,
            importedAt: Date()
        )

        #expect(
            try BundleIDPolicy.targetBundleIdentifier(
                for: seal,
                requestedBundleIdentifier: "com.mjorb.seal.seal",
                currentSealBundleIdentifier: "com.mjorb.seal"
            ) == "com.mjorb.seal.current"
        )
    }

    @Test
    func recommendedBundleIdentifierAddsEditableTeamSuffix() {
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo", teamID: "T") == "com.example.demo.T")
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo.seal", teamID: "T") == "com.example.demo.seal.T")
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo.T", teamID: "T") == "com.example.demo.T.T")
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: " com.vendor.app.123 ", teamID: "T") == "com.vendor.app.123.T")
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo", teamID: "  ") == "com.example.demo")
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo") == "com.example.demo")
    }

    @Test
    func extensionMappingPreservesRelativeSuffix() {
        let mapper = BundleIDMapper()
        #expect(
            mapper.extensionBundleID(
                original: "com.example.app.widget",
                originalMainBundleID: "com.example.app",
                mappedMainBundleID: "com.example.app.TEAM1"
            ) == "com.example.app.TEAM1.widget"
        )
        #expect(
            mapper.extensionBundleID(
                original: "com.example.app.share",
                originalMainBundleID: "com.example.app",
                mappedMainBundleID: "com.example.custom"
            ) == "com.example.custom.share"
        )
    }

    @Test
    func bundleIdentifierValidationOnlyEnforcesAppleCharacterSet() {
        #expect(BundleIDPolicy.validationError(for: "") != nil)
        // 反向域名是 Apple 推荐格式；本地只校验 Apple 明确列出的字符范围。
        #expect(BundleIDPolicy.validationError(for: "single") == nil)
        #expect(BundleIDPolicy.validationError(for: ".com.example") == nil)
        #expect(BundleIDPolicy.validationError(for: "com..example") == nil)
        #expect(BundleIDPolicy.validationError(for: "com.-example") == nil)
        #expect(BundleIDPolicy.validationError(for: "com.example-") == nil)
        #expect(BundleIDPolicy.validationError(for: "com.example_app") != nil)
        #expect(BundleIDPolicy.validationError(for: "com.example-app") == nil)
    }

}
