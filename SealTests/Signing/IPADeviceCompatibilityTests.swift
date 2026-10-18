import Foundation
import Testing
@testable import Seal

struct IPADeviceCompatibilityTests {
    private let currentOS = OperatingSystemVersion(majorVersion: 18, minorVersion: 2, patchVersion: 0)

    @Test
    func explicitlyUnsupportedDeviceIsRejectedBeforeSigningResourcesAreRequested() {
        let failure = IPADeviceCompatibility.failure(
            metadata: IPADeviceCompatibilityMetadata(
                supportedDevices: ["iPad14,1", "iPad14,2"],
                minimumOSVersion: "17.0"
            ),
            modelIdentifier: "iPhone17,1",
            operatingSystemVersion: currentOS
        )

        #expect(failure?.code == "SEAL-IPA-107")
    }

    @Test
    func absentDeviceListDoesNotInventAnIncompatibility() {
        let failure = IPADeviceCompatibility.failure(
            metadata: IPADeviceCompatibilityMetadata(supportedDevices: nil, minimumOSVersion: nil),
            modelIdentifier: "iPhone17,1",
            operatingSystemVersion: currentOS
        )

        #expect(failure == nil)
    }

    @Test
    func minimumOperatingSystemIsComparedByNumericComponents() {
        let failure = IPADeviceCompatibility.failure(
            metadata: IPADeviceCompatibilityMetadata(supportedDevices: nil, minimumOSVersion: "18.10"),
            modelIdentifier: "iPhone17,1",
            operatingSystemVersion: currentOS
        )

        #expect(failure?.code == "SEAL-IPA-108")
    }

    @Test
    func supportedDeviceAndOperatingSystemPass() {
        let failure = IPADeviceCompatibility.failure(
            metadata: IPADeviceCompatibilityMetadata(
                supportedDevices: ["iPhone17,1"],
                minimumOSVersion: "18.2"
            ),
            modelIdentifier: "iPhone17,1",
            operatingSystemVersion: currentOS
        )

        #expect(failure == nil)
    }
}
