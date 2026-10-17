import Foundation
import Testing
@testable import Seal

@Suite("证书库存可见性")
struct ApplePortalInventoryVisibilityTests {
    @Test
    func filtersDismissedCertificateBeforePublishingInventory() {
        let dismissedSerial = "DISMISSED-\(UUID().uuidString)"
        let visibleSerial = "VISIBLE-\(UUID().uuidString)"
        CertificateDismissalStore.dismiss(serialNumber: dismissedSerial)

        let inventory = ApplePortalInventory(
            accountID: UUID(),
            teamID: "TEAM",
            teamName: "Team",
            appIDs: [],
            certificates: [
                certificate(serial: dismissedSerial),
                certificate(serial: visibleSerial)
            ],
            fetchedAt: Date()
        )

        let visible = inventory.filteringDismissedCertificates()

        #expect(visible.certificates.map(\.serialNumber) == [visibleSerial])
    }

    @Test
    func preservesAppleReturnedAppIDQuotaWhenFilteringCertificates() {
        let quota = ApplePortalAppIDQuotaSnapshot(
            returnedCount: 8,
            maxQuantity: 10,
            availableQuantity: 0
        )
        let inventory = ApplePortalInventory(
            accountID: UUID(),
            teamID: "TEAM",
            teamName: "Team",
            appIDs: [],
            certificates: [],
            fetchedAt: Date(),
            appIDQuota: quota
        )

        #expect(inventory.filteringDismissedCertificates().appIDQuota == quota)
    }

    @Test
    func decodesInventoryCacheWithoutAppleQuota() throws {
        let legacySnapshot = #"{"accountID":"00000000-0000-0000-0000-000000000001","teamID":"TEAM","teamName":"Team","appIDs":[],"certificates":[],"fetchedAt":0}"#

        let inventory = try JSONDecoder().decode(
            ApplePortalInventory.self,
            from: Data(legacySnapshot.utf8)
        )

        #expect(inventory.appIDQuota == nil)
    }

    @Test
    func decodesInventoryCacheCreatedBeforeCertificateNameWasAdded() throws {
        let legacySnapshot = #"{"serialNumber":"SERIAL","machineName":"Apple Development","machineIdentifier":null,"hasLocalPrivateKey":false,"expirationDate":null}"#

        let certificate = try JSONDecoder().decode(
            ApplePortalCertificateSnapshot.self,
            from: Data(legacySnapshot.utf8)
        )

        #expect(certificate.certificateName == nil)
        #expect(certificate.serialNumber == "SERIAL")
    }

    private func certificate(serial: String) -> ApplePortalCertificateSnapshot {
        ApplePortalCertificateSnapshot(
            serialNumber: serial,
            machineName: "Apple Development",
            machineIdentifier: nil,
            hasLocalPrivateKey: false,
            expirationDate: nil
        )
    }
}
