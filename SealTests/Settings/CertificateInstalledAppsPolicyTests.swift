import Foundation
import Testing
@testable import Seal

/// 签名证书页「本机已安装 App」区域的纯判定（0.1.52 第 5 项第二轮）。
///
/// 根因（parts-0152/part-5.md）：①区域与硬门只认 `certificateSerialNumber`，
/// 与健康口径 `selected ?? certificate ?? secret` 不一致，切换证书后拿旧/空
/// 序列号比对（空串归一为 `"0"` 恒不命中）；②本地扫描分支只要扫描非 nil
/// 就丢弃记录口径列表，同团队判据再不成立时恒显「暂无」。
/// 全部用例为纯函数同步断言，不含任何计时/竞速断言。
struct CertificateInstalledAppsPolicyTests {
    // MARK: - 序列号统一取源

    @Test
    func effectiveSerialPrefersSelectedOverCertificateAndSecret() {
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(
                selectedCertificateSerialNumber: "SEL111",
                certificateSerialNumber: "CER222",
                secretCertificateSerialNumber: "SEC333"
            ) == "SEL111"
        )
    }

    @Test
    func effectiveSerialFallsBackToCertificateWhenSelectedIsNilOrBlank() {
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(
                selectedCertificateSerialNumber: nil,
                certificateSerialNumber: "CER222",
                secretCertificateSerialNumber: "SEC333"
            ) == "CER222"
        )
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(
                selectedCertificateSerialNumber: "  ",
                certificateSerialNumber: "CER222",
                secretCertificateSerialNumber: "SEC333"
            ) == "CER222"
        )
    }

    @Test
    func effectiveSerialFallsBackToSecretWhenRecordSerialsAreMissing() {
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(
                selectedCertificateSerialNumber: nil,
                certificateSerialNumber: "",
                secretCertificateSerialNumber: "SEC333"
            ) == "SEC333"
        )
    }

    @Test
    func effectiveSerialIsEmptyWhenEverySourceIsMissing() {
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(
                selectedCertificateSerialNumber: nil,
                certificateSerialNumber: nil,
                secretCertificateSerialNumber: nil
            ) == ""
        )
    }

    @Test
    func effectiveSerialTrimsWhitespaceFromTheWinningSource() {
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(
                selectedCertificateSerialNumber: "  SEL111\n",
                certificateSerialNumber: "CER222"
            ) == "SEL111"
        )
    }

    @Test
    func effectiveSerialForAccountUsesSelectedThenCertificate() {
        let selectedOnly = AppleAccountRecord(
            maskedEmail: "a@example.com",
            accountIdentifier: "1",
            teamID: "TEAM123456",
            teamName: "Example",
            certificateSerialNumber: "CER222",
            selectedCertificateSerialNumber: "SEL111",
            lastVerifiedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(for: selectedOnly) == "SEL111"
        )

        let certificateOnly = AppleAccountRecord(
            maskedEmail: "a@example.com",
            accountIdentifier: "1",
            teamID: "TEAM123456",
            teamName: "Example",
            certificateSerialNumber: "CER222",
            selectedCertificateSerialNumber: nil,
            lastVerifiedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(
            CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(for: certificateOnly) == "CER222"
        )
    }

    // MARK: - 展示列表组合判定

    @Test
    func displayPrefersLocalAppsWhenLocalScanHasVisibleApps() {
        let record = makeApp(name: "Alpha")
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: true,
                locallyVisibleIsEmpty: false,
                hasInstalledBundleIdentifiers: true,
                installedApps: [record],
                certificateApps: [record]
            ) == .localApps
        )
    }

    /// 根因 A 的回归锁：本地扫描为空时不得整体吞成「暂无」，
    /// 先回落设备清单核验过的 installedApps。
    @Test
    func displayFallsBackToInstalledAppsWhenLocalScanIsEmpty() {
        let alpha = makeApp(name: "Alpha")
        let beta = makeApp(name: "Beta")
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: true,
                locallyVisibleIsEmpty: true,
                hasInstalledBundleIdentifiers: true,
                installedApps: [alpha],
                certificateApps: [alpha, beta]
            ) == .recordApps([alpha])
        )
    }

    /// installedApps 也为空时，再回落全量记录口径 certificateApps。
    @Test
    func displayFallsBackToCertificateAppsWhenInstalledAppsAreAlsoEmpty() {
        let beta = makeApp(name: "Beta")
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: true,
                locallyVisibleIsEmpty: true,
                hasInstalledBundleIdentifiers: true,
                installedApps: [],
                certificateApps: [beta]
            ) == .recordApps([beta])
        )
    }

    @Test
    func displayIsEmptyWhenLocalScanAndEveryRecordListAreEmpty() {
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: true,
                locallyVisibleIsEmpty: true,
                hasInstalledBundleIdentifiers: true,
                installedApps: [],
                certificateApps: []
            ) == .empty
        )
    }

    @Test
    func displayWithoutLocalScanUsesInstalledAppsWhenIdentifiersExist() {
        let alpha = makeApp(name: "Alpha")
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: false,
                locallyVisibleIsEmpty: true,
                hasInstalledBundleIdentifiers: true,
                installedApps: [alpha],
                certificateApps: [alpha]
            ) == .recordApps([alpha])
        )
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: false,
                locallyVisibleIsEmpty: true,
                hasInstalledBundleIdentifiers: true,
                installedApps: [],
                certificateApps: [alpha]
            ) == .empty
        )
    }

    @Test
    func displayWithoutAnyDeviceListUsesCertificateAppsOrNoRecords() {
        let alpha = makeApp(name: "Alpha")
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: false,
                locallyVisibleIsEmpty: true,
                hasInstalledBundleIdentifiers: false,
                installedApps: [],
                certificateApps: [alpha]
            ) == .recordApps([alpha])
        )
        #expect(
            CertificateInstalledAppsPolicy.display(
                hasLocalScan: false,
                locallyVisibleIsEmpty: true,
                hasInstalledBundleIdentifiers: false,
                installedApps: [],
                certificateApps: []
            ) == .noAssociatedRecords
        )
    }

    private func makeApp(name: String) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.\(name)",
            name: name,
            version: "1.0",
            buildNumber: "1",
            size: 1024,
            state: .installed,
            ipaRelativePath: "\(name).ipa",
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

/// `AppleAccountDetailView` 四处裸 `accountID` 判据的悬空分流（同轮第 5 项）。
///
/// 与 `SigningCertificateSelectionPolicy.validateAccountAndTeam` 同口径：
/// 绑定仍在 ⇒ 不放行；悬空/未绑定 ⇒ 按签名 Team 判据（signingTeamID 或
/// 任一 signingTarget 的 teamIdentifier）。全部纯函数同步断言。
struct CertificateInstalledAppsDanglingBindingTests {
    private let teamID = "TEAM123456"

    @Test
    func exactBindingStillMatchesWithoutTeamContext() {
        let accountID = UUID()
        let app = makeApp(accountID: accountID, signingTeamID: "OTHERTEAM1")
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                app,
                accountID: accountID,
                accountTeamID: nil,
                knownAccountIDs: nil
            )
        )
    }

    /// 绑定账号仍在账号库 ⇒ 真的用了别的账号，同 Team 也不放行。
    @Test
    func liveBindingToAnotherAccountDoesNotMatchEvenWithSameTeam() {
        let boundAccountID = UUID()
        let app = makeApp(accountID: boundAccountID, signingTeamID: teamID)
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                app,
                accountID: UUID(),
                accountTeamID: teamID,
                knownAccountIDs: [boundAccountID, UUID()]
            ) == false
        )
    }

    /// 未提供账号库快照时按「绑定仍在」处理，保持旧的保守行为。
    @Test
    func unknownAccountLibraryKeepsConservativeRejection() {
        let app = makeApp(accountID: UUID(), signingTeamID: teamID)
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                app,
                accountID: UUID(),
                accountTeamID: teamID,
                knownAccountIDs: nil
            ) == false
        )
    }

    @Test
    func danglingBindingMatchesBySigningTeamIDCaseInsensitively() {
        let boundAccountID = UUID()
        let currentAccountID = UUID()
        let app = makeApp(accountID: boundAccountID, signingTeamID: "team123456")
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                app,
                accountID: currentAccountID,
                accountTeamID: teamID,
                knownAccountIDs: [currentAccountID]
            )
        )
    }

    @Test
    func danglingBindingMatchesBySigningTargetTeamWhenTopLevelTeamDiffers() {
        let boundAccountID = UUID()
        let currentAccountID = UUID()
        let target = SigningTargetRecord(
            bundleIdentifier: "com.example.Alpha",
            profileUUID: "PROFILE-1",
            profileName: "Profile",
            profileCreationDate: nil,
            profileExpirationDate: Date(timeIntervalSince1970: 2_000_000_000),
            teamIdentifier: teamID,
            certificateSerialNumbers: ["AA11"],
            deviceIdentifiers: []
        )
        let app = makeApp(accountID: boundAccountID, signingTeamID: nil, signingTargets: [target])
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                app,
                accountID: currentAccountID,
                accountTeamID: teamID,
                knownAccountIDs: [currentAccountID]
            )
        )
    }

    @Test
    func danglingBindingWithDifferentTeamDoesNotMatch() {
        let boundAccountID = UUID()
        let currentAccountID = UUID()
        let app = makeApp(accountID: boundAccountID, signingTeamID: "OTHERTEAM1")
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                app,
                accountID: currentAccountID,
                accountTeamID: teamID,
                knownAccountIDs: [currentAccountID]
            ) == false
        )
    }

    @Test
    func missingBindingMatchesByTeamAndFailsWithoutTeamEvidence() {
        let currentAccountID = UUID()
        let withTeam = makeApp(accountID: nil, signingTeamID: teamID)
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                withTeam,
                accountID: currentAccountID,
                accountTeamID: teamID,
                knownAccountIDs: [currentAccountID]
            )
        )
        let withoutTeam = makeApp(accountID: nil, signingTeamID: nil)
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                withoutTeam,
                accountID: currentAccountID,
                accountTeamID: teamID,
                knownAccountIDs: [currentAccountID]
            ) == false
        )
        let emptyAccountTeam = makeApp(accountID: nil, signingTeamID: teamID)
        #expect(
            AppleAccountAppNamePolicy.isAccountMatch(
                emptyAccountTeam,
                accountID: currentAccountID,
                accountTeamID: "  ",
                knownAccountIDs: [currentAccountID]
            ) == false
        )
    }

    /// 端到端富化：悬空后名称 / App ID / 到期时间都应恢复本地记录口径，
    /// 而不是退化为门户原名 +「未记录」。
    @Test
    func danglingBindingRestoresNameAppIDAndExpirationEnrichment() {
        let boundAccountID = UUID()
        let currentAccountID = UUID()
        let expiration = Date(timeIntervalSince1970: 2_000_000_000)
        let target = SigningTargetRecord(
            bundleIdentifier: "com.example.Alpha",
            profileUUID: "PROFILE-1",
            profileName: "Profile",
            profileCreationDate: nil,
            profileExpirationDate: expiration,
            teamIdentifier: teamID,
            certificateSerialNumbers: ["AA11"],
            deviceIdentifiers: [],
            applicationIdentifier: "TEAM123456.com.example.Alpha"
        )
        let app = makeApp(
            accountID: boundAccountID,
            signingTeamID: teamID,
            signingTargets: [target]
        )
        let known: Set<UUID> = [currentAccountID]
        let snapshot = ApplePortalAppIDSnapshot(
            identifier: "APPLE-APP-ID",
            name: "Apple 中的名称",
            bundleIdentifier: "com.example.Alpha",
            appIDExpirationDate: nil,
            provisioningProfileName: nil,
            provisioningProfileExpirationDate: nil,
            provisioningProfileState: .unavailable
        )

        #expect(
            AppleAccountAppNamePolicy.displayName(
                for: "com.example.Alpha",
                accountID: currentAccountID,
                relatedApps: [app],
                fallbackAppleName: snapshot.name,
                accountTeamID: teamID,
                knownAccountIDs: known
            ) == "Alpha"
        )
        #expect(
            AppleAccountAppNamePolicy.applicationIdentifier(
                for: "com.example.Alpha",
                accountID: currentAccountID,
                relatedApps: [app],
                fallbackAppleAppID: snapshot.identifier,
                accountTeamID: teamID,
                knownAccountIDs: known
            ) == "TEAM123456.com.example.Alpha"
        )
        #expect(
            AppleAccountAppNamePolicy.expirationDate(
                for: "com.example.Alpha",
                snapshot: snapshot,
                accountID: currentAccountID,
                relatedApps: [app],
                accountTeamID: teamID,
                knownAccountIDs: known
            ) == expiration
        )
    }

    /// 悬空但异 Team：三项富化全部不放行，退回门户回退值。
    @Test
    func danglingBindingWithDifferentTeamKeepsPortalFallbacks() {
        let boundAccountID = UUID()
        let currentAccountID = UUID()
        let app = makeApp(accountID: boundAccountID, signingTeamID: "OTHERTEAM1")
        let known: Set<UUID> = [currentAccountID]
        let snapshot = ApplePortalAppIDSnapshot(
            identifier: "APPLE-APP-ID",
            name: "Apple 中的名称",
            bundleIdentifier: "com.example.Alpha",
            appIDExpirationDate: nil,
            provisioningProfileName: nil,
            provisioningProfileExpirationDate: nil,
            provisioningProfileState: .unavailable
        )

        #expect(
            AppleAccountAppNamePolicy.displayName(
                for: "com.example.Alpha",
                accountID: currentAccountID,
                relatedApps: [app],
                fallbackAppleName: snapshot.name,
                accountTeamID: teamID,
                knownAccountIDs: known
            ) == "Apple 中的名称"
        )
        #expect(
            AppleAccountAppNamePolicy.applicationIdentifier(
                for: "com.example.Alpha",
                accountID: currentAccountID,
                relatedApps: [app],
                fallbackAppleAppID: snapshot.identifier,
                accountTeamID: teamID,
                knownAccountIDs: known
            ) == "APPLE-APP-ID"
        )
        #expect(
            AppleAccountAppNamePolicy.expirationDate(
                for: "com.example.Alpha",
                snapshot: snapshot,
                accountID: currentAccountID,
                relatedApps: [app],
                accountTeamID: teamID,
                knownAccountIDs: known
            ) == nil
        )
    }

    private func makeApp(
        accountID: UUID?,
        signingTeamID: String?,
        signingTargets: [SigningTargetRecord] = []
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.Alpha",
            name: "Alpha",
            version: "1.0",
            buildNumber: "1",
            size: 1024,
            state: .installed,
            accountID: accountID,
            signingTeamID: signingTeamID,
            signingTargets: signingTargets,
            ipaRelativePath: "Alpha.ipa",
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
