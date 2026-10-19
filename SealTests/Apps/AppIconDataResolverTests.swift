import Foundation
import Testing
@testable import Seal

struct AppIconDataResolverTests {
    @Test
    func replacementIconFillsMissingInstalledAppIcon() {
        let installed = makeRecord(state: .installed)
        let replacement = makeRecord(
            state: .imported,
            iconPath: "Apps/replacement/Icon.png",
            replacesInstalledAppID: installed.id
        )
        let replacementIcon = Data([1, 2, 3])

        let resolved = AppIconDataResolver.fillingMissingInstalledIcons(
            in: [installed, replacement],
            iconDataByAppID: [replacement.id: replacementIcon]
        )

        #expect(resolved[installed.id] == replacementIcon)
    }

    @Test
    func existingInstalledIconIsPreserved() {
        let installed = makeRecord(state: .installed)
        let replacement = makeRecord(
            state: .imported,
            iconPath: "Apps/replacement/Icon.png",
            replacesInstalledAppID: installed.id
        )
        let installedIcon = Data([4, 5, 6])
        let replacementIcon = Data([1, 2, 3])

        let resolved = AppIconDataResolver.fillingMissingInstalledIcons(
            in: [installed, replacement],
            iconDataByAppID: [installed.id: installedIcon, replacement.id: replacementIcon]
        )

        #expect(resolved[installed.id] == installedIcon)
    }

    @Test
    func missingPreferredIconFallsBackToImportedIPAIconPath() {
        let app = makeRecord(
            state: .imported,
            iconPath: "Apps/replacement/IPAIcon.png",
            preferredIconPath: "Apps/replacement/CustomIcon.png"
        )

        #expect(AppIconDataResolver.iconRelativePaths(for: app) == [
            "Apps/replacement/CustomIcon.png",
            "Apps/replacement/IPAIcon.png"
        ])
    }

    private func makeRecord(
        state: AppState,
        iconPath: String? = nil,
        preferredIconPath: String? = nil,
        replacesInstalledAppID: UUID? = nil
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            iconRelativePath: iconPath,
            state: state,
            lastInstalledAt: state == .installed ? Date(timeIntervalSince1970: 1_800_000_000) : nil,
            ipaRelativePath: "Apps/demo/Original.ipa",
            preferredIconRelativePath: preferredIconPath,
            importedAt: Date(timeIntervalSince1970: 1_800_000_000),
            replacesInstalledAppID: replacesInstalledAppID
        )
    }
}
