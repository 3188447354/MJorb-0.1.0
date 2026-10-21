import Testing
@testable import Seal

@Suite("已安装页设备查询互斥")
struct InstalledAppRefreshProbeGateTests {
    @Test
    func lateProbeCompletionKeepsGateBusyUntilNativeCallEnds() async {
        let gate = InstalledAppRefreshProbeGate()

        guard case .ready(let probeID) = await gate.begin() else {
            Issue.record("The first device probe should acquire the gate")
            return
        }
        #expect(await gate.begin() == .inFlight)
        await gate.finish(probeID: probeID, timedOut: true)

        #expect(await gate.begin() == .coolingDown)
    }

    @Test
    func staleCompletionCannotReleaseANewerProbe() async {
        let gate = InstalledAppRefreshProbeGate()
        guard case .ready(let firstProbeID) = await gate.begin() else {
            Issue.record("The first device probe should acquire the gate")
            return
        }
        await gate.finish(probeID: firstProbeID, timedOut: false)

        guard case .ready(let secondProbeID) = await gate.begin() else {
            Issue.record("The second device probe should acquire the gate")
            return
        }
        await gate.finish(probeID: firstProbeID, timedOut: true)

        #expect(await gate.begin() == .inFlight)
        await gate.finish(probeID: secondProbeID, timedOut: false)
        guard case .ready = await gate.begin() else {
            Issue.record("The gate should be available after the active probe completes")
            return
        }
    }

    @Test
    func cancelledProbeThatNeverStartedDoesNotEnterCooldown() async {
        let gate = InstalledAppRefreshProbeGate()
        guard case .ready(let probeID) = await gate.begin() else {
            Issue.record("The probe should acquire the gate")
            return
        }

        await gate.finish(probeID: probeID, timedOut: false)

        guard case .ready = await gate.begin() else {
            Issue.record("A probe that never reached native code should not cool down the gate")
            return
        }
    }

    @Test
    func foregroundDeviceOperationWaitsForProbeAndRecoveryCooldown() async throws {
        let gate = InstalledAppRefreshProbeGate(timeoutCooldownSeconds: 0.02)
        guard case .ready(let scanID) = await gate.begin() else {
            Issue.record("The inventory scan should acquire the gate")
            return
        }

        let writer = Task { await gate.beginForeground(timeoutSeconds: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await gate.begin() == .coolingDown)

        await gate.finish(probeID: scanID, timedOut: true)
        guard case .ready(let writerID) = await writer.value else {
            Issue.record("The foreground operation should acquire the released device gate")
            return
        }
        await gate.finish(probeID: writerID, timedOut: false)
    }

    @Test
    func foregroundWaitTimeoutDoesNotLeaveAReservationBehind() async {
        let gate = InstalledAppRefreshProbeGate()
        guard case .ready(let scanID) = await gate.begin() else {
            Issue.record("The inventory scan should acquire the gate")
            return
        }

        #expect(await gate.beginForeground(timeoutSeconds: 0.01) == .coolingDown)
        await gate.finish(probeID: scanID, timedOut: false)
        guard case .ready = await gate.begin() else {
            Issue.record("A timed-out writer must release its priority reservation")
            return
        }
    }
}
