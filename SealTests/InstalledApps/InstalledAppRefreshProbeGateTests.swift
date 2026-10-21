import Testing
@testable import Seal

@Suite("设备原生调用排队")
struct InstalledAppRefreshProbeGateTests {
    @Test
    func inventoryReadsDoNotBlockMisagentProfileWrites() async {
        guard case .ready(let inventoryID) = await InstalledAppRefreshProbeGate.inventory.begin() else {
            Issue.record("The inventory service should be available")
            return
        }
        guard case .ready(let profileID) = await InstalledAppRefreshProbeGate.profiles.begin() else {
            Issue.record("A profile write should not queue behind an inventory read")
            await InstalledAppRefreshProbeGate.inventory.finish(probeID: inventoryID)
            return
        }
        await InstalledAppRefreshProbeGate.profiles.finish(probeID: profileID)
        await InstalledAppRefreshProbeGate.inventory.finish(probeID: inventoryID)
    }

    @Test
    func timedOutWaiterKeepsGateUntilNativeCallActuallyReturns() async {
        let gate = InstalledAppRefreshProbeGate()
        guard case .ready(let probeID) = await gate.begin() else {
            Issue.record("The first device call should acquire the gate")
            return
        }

        #expect(await gate.begin() == .inFlight)
        await gate.finish(probeID: probeID)
        guard case .ready = await gate.begin() else {
            Issue.record("The next operation should start as soon as the native call returns")
            return
        }
    }

    @Test
    func staleCompletionCannotReleaseANewerProbe() async {
        let gate = InstalledAppRefreshProbeGate()
        guard case .ready(let firstProbeID) = await gate.begin() else {
            Issue.record("The first device call should acquire the gate")
            return
        }
        await gate.finish(probeID: firstProbeID)

        guard case .ready(let secondProbeID) = await gate.begin() else {
            Issue.record("The second device call should acquire the released gate")
            return
        }
        await gate.finish(probeID: firstProbeID)

        #expect(await gate.begin() == .inFlight)
        await gate.finish(probeID: secondProbeID)
        guard case .ready = await gate.begin() else {
            Issue.record("The gate should be available after the active call completes")
            return
        }
    }

    @Test
    func foregroundDeviceOperationWaitsForAnActiveNativeCall() async throws {
        let gate = InstalledAppRefreshProbeGate()
        guard case .ready(let scanID) = await gate.begin() else {
            Issue.record("The inventory scan should acquire the gate")
            return
        }

        let writer = Task { await gate.beginForeground() }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await gate.begin() == .inFlight)

        await gate.finish(probeID: scanID)
        guard case .ready(let writerID) = await writer.value else {
            Issue.record("The foreground device operation should start after the scan")
            return
        }
        await gate.finish(probeID: writerID)
    }

    @Test
    func cancellingAQueuedOperationReleasesItsPriority() async throws {
        let gate = InstalledAppRefreshProbeGate()
        guard case .ready(let scanID) = await gate.begin() else {
            Issue.record("The inventory scan should acquire the gate")
            return
        }

        let writer = Task { await gate.beginForeground() }
        try await Task.sleep(nanoseconds: 20_000_000)
        writer.cancel()
        #expect(await writer.value == .cancelled)

        await gate.finish(probeID: scanID)
        guard case .ready = await gate.begin() else {
            Issue.record("A cancelled waiter must not block later device work")
            return
        }
    }
}
