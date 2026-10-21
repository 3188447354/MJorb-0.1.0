import Testing
@testable import Seal

@Suite("已安装页设备查询预算")
struct InstalledAppRefreshProbePolicyTests {
    @Test
    func refreshProbeFailsFastWithoutBorrowingInstallationBudget() {
        #expect(InstalledAppRefreshProbePolicy.timeoutSeconds == 2)
    }

    @Test
    func localSnapshotNeedsSealAsPositiveControl() {
        #expect(
            InstalledAppRefreshProbePolicy.hasPositiveControl(
                controlBundleIdentifier: "com.mjorb.seal.device",
                installedBundleIdentifiers: ["com.example.music"]
            ) == false
        )
        #expect(
            InstalledAppRefreshProbePolicy.hasPositiveControl(
                controlBundleIdentifier: "com.mjorb.seal.device",
                installedBundleIdentifiers: ["COM.MJORB.SEAL.DEVICE"]
            )
        )
    }

    @Test
    func acceptsNonemptyLaunchServicesSnapshotWhenItOmitsTheRunningApp() {
        #expect(
            InstalledAppRefreshProbePolicy.canUseLocalSnapshot(
                controlBundleIdentifier: "com.mjorb.seal.device",
                installedBundleIdentifiers: ["com.example.music"]
            )
        )
        #expect(
            InstalledAppRefreshProbePolicy.canUseLocalSnapshot(
                controlBundleIdentifier: "com.mjorb.seal.device",
                installedBundleIdentifiers: []
            ) == false
        )
    }

    @Test
    func localSnapshotMatchesBundleIDsCaseInsensitively() {
        #expect(
            InstalledAppRefreshProbePolicy.contains(
                "com.example.music",
                in: ["COM.EXAMPLE.MUSIC"]
            )
        )
        #expect(
            InstalledAppRefreshProbePolicy.contains(
                "com.example.video",
                in: ["com.example.music"]
            ) == false
        )
    }
}
