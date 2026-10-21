import Foundation
import Testing
@testable import Seal

@MainActor
struct ApplicationOperationCoordinatorTests {
    @Test
    func cancelledWaiterNeverAcquiresAnAvailableLease() async {
        let coordinator = OperationCoordinator()
        let waiter = Task { @MainActor in
            await coordinator.beginWaiting(.signing)
        }
        // This test stays on MainActor until cancellation, before the waiter can run.
        waiter.cancel()
        let lease = await waiter.value
        #expect(lease == nil)
        #expect(coordinator.activeLease == nil)
    }

    @Test
    func timedOutWaiterDoesNotReleaseAnotherOperationsLease() async throws {
        let coordinator = OperationCoordinator()
        let first = try #require(coordinator.begin(.signing))
        let second = await coordinator.beginWaiting(.renewing, timeout: 0)
        #expect(second == nil)
        #expect(coordinator.activeLease == first)
        coordinator.end(first)
    }

    @Test
    func foregroundTransactionWaitsUntilConflictingOperationEnds() async throws {
        let coordinator = OperationCoordinator()
        let first = try #require(coordinator.begin(.installing))
        let waiter = Task { @MainActor in
            await coordinator.beginWaiting(.renewing)
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.hasConflict(for: .renewing))
        coordinator.end(first)

        let acquiredLease = await waiter.value
        let second = try #require(acquiredLease)
        #expect(second.kind == .renewing)
        coordinator.end(second)
    }

    @Test
    func conflictingWriteOperationsAreRejectedUntilLeaseEnds() throws {
        let coordinator = OperationCoordinator()
        let first = try #require(coordinator.begin(.signing, appID: UUID()))
        #expect(coordinator.begin(.maintainingStorage) == nil)
        #expect(coordinator.conflictFailure(requested: .maintainingStorage).code == "SEAL-OP-001")

        coordinator.end(first)
        let second = try #require(coordinator.begin(.maintainingStorage))
        #expect(second.kind == .maintainingStorage)
        coordinator.end(second)
    }

    @Test
    func independentResourcesCanRunAtTheSameTime() throws {
        let coordinator = OperationCoordinator()
        let certificate = try #require(coordinator.begin(.managingCertificate))
        let importing = try #require(coordinator.begin(.importing))

        #expect(coordinator.activeLeases.count == 2)
        #expect(coordinator.hasConflict(for: .importing))
        #expect(coordinator.hasConflict(for: .signing))

        coordinator.end(certificate)
        #expect(coordinator.hasConflict(for: .signing) == false)
        #expect(coordinator.activeLease == importing)
    }

    @Test
    func deviceOperationsRemainSerialized() throws {
        let coordinator = OperationCoordinator()
        let install = try #require(coordinator.begin(.installing, appID: UUID()))

        #expect(coordinator.begin(.renewing) == nil)
        #expect(coordinator.begin(.resettingPairing) == nil)
        #expect(coordinator.hasDeviceSessionConflict)

        coordinator.end(install)
        #expect(coordinator.begin(.renewing) != nil)
    }

    @Test
    func deviceInventoryDoesNotBlockForegroundDeviceTransactions() throws {
        let coordinator = OperationCoordinator()
        let scan = try #require(coordinator.begin(.scanningDeviceInventory))

        #expect(coordinator.hasDeviceSessionConflict == false)
        let signing = try #require(coordinator.begin(.signing, accountID: UUID()))
        let importing = try #require(coordinator.begin(.importing))
        let account = try #require(coordinator.begin(.managingAccount, accountID: UUID()))
        let certificate = try #require(coordinator.begin(.managingCertificate, accountID: UUID()))
        #expect(coordinator.begin(.resettingPairing) == nil)
        #expect(coordinator.begin(.scanningDeviceInventory) == nil)

        coordinator.end(scan)
        coordinator.end(signing)
        coordinator.end(importing)
        coordinator.end(account)
        coordinator.end(certificate)
        let renewal = try #require(coordinator.begin(.renewing))
        coordinator.end(renewal)
    }

    @Test
    func deviceInventoryCanRunAlongsideIndependentOperations() throws {
        let coordinator = OperationCoordinator()
        let importing = try #require(coordinator.begin(.importing))
        let account = try #require(coordinator.begin(.managingAccount, accountID: UUID()))
        let certificate = try #require(coordinator.begin(.managingCertificate, accountID: UUID()))

        let scan = try #require(coordinator.begin(.scanningDeviceInventory))
        #expect(coordinator.begin(.scanningDeviceInventory) == nil)
        let signing = try #require(coordinator.begin(.signing))

        coordinator.end(scan)
        coordinator.end(signing)
        coordinator.end(importing)
        coordinator.end(account)
        coordinator.end(certificate)
    }

    @Test
    func nativeDeviceLeaseWaitsForPairingResetToFinish() async throws {
        let coordinator = OperationCoordinator()
        let reset = try #require(coordinator.begin(.resettingPairing))
        let waiter = Task { @MainActor in
            await coordinator.acquireNativeDeviceSessionLease(waitTimeout: 1)
        }

        try await Task.sleep(for: .milliseconds(20))
        coordinator.end(reset)
        guard let nativeLease = await waiter.value else {
            Issue.record("The device request should wait for pairing reset instead of failing immediately")
            return
        }
        #expect(nativeLease.kind == .scanningDeviceInventory)
        coordinator.releaseDeviceSessionLeaseAfterNativeCall(nativeLease)
    }

    @Test
    func profileMaintenanceDoesNotBlockForegroundDeviceOrAccountWork() throws {
        let coordinator = OperationCoordinator()
        let maintenance = try #require(coordinator.begin(.managingDeviceProfiles))

        #expect(coordinator.hasDeviceSessionConflict == false)
        let scan = try #require(coordinator.begin(.scanningDeviceInventory))
        let signing = try #require(coordinator.begin(.signing))
        let certificate = try #require(coordinator.begin(.managingCertificate, accountID: UUID()))
        #expect(coordinator.begin(.resettingPairing) == nil)
        #expect(coordinator.begin(.importing) != nil)
        #expect(coordinator.begin(.managingAccount, accountID: UUID()) != nil)

        coordinator.end(scan)
        coordinator.end(signing)
        coordinator.end(certificate)
        coordinator.end(maintenance)
    }

    @Test
    func pairingAndProfileMaintenanceDoNotHideLocalInstalledApps() throws {
        let coordinator = OperationCoordinator()
        let pairing = try #require(coordinator.begin(.resettingPairing))
        #expect(coordinator.hasDeviceSessionConflict == false)
        coordinator.end(pairing)

        let profileWork = try #require(coordinator.begin(.managingDeviceProfiles))
        #expect(coordinator.hasDeviceSessionConflict == false)
        coordinator.end(profileWork)

        let install = try #require(coordinator.begin(.installing))
        #expect(coordinator.hasDeviceSessionConflict)
        coordinator.end(install)
    }

    @Test
    func appMetadataEditsOnlyConflictWithTheSameAppOperation() throws {
        let coordinator = OperationCoordinator()
        let firstAppID = UUID()
        let secondAppID = UUID()
        let first = try #require(coordinator.begin(.updatingApp, appID: firstAppID))

        #expect(coordinator.begin(.updatingApp, appID: secondAppID) != nil)
        #expect(coordinator.begin(.signing, appID: firstAppID) == nil)

        coordinator.end(first)
    }

    @Test
    func accountScopedCertificateWorkDoesNotFreezeOtherAccountsOrDeviceRefresh() throws {
        let coordinator = OperationCoordinator()
        let firstAccountID = UUID()
        let secondAccountID = UUID()
        let certificate = try #require(
            coordinator.begin(.managingCertificate, accountID: firstAccountID)
        )

        #expect(coordinator.hasDeviceSessionConflict == false)
        let secondCertificate = try #require(
            coordinator.begin(.managingCertificate, accountID: secondAccountID)
        )
        coordinator.end(secondCertificate)
        let secondAccountSigning = try #require(
            coordinator.begin(.signing, accountID: secondAccountID)
        )
        #expect(coordinator.begin(.signing, accountID: firstAccountID) == nil)

        coordinator.end(certificate)
        coordinator.end(secondAccountSigning)
    }
}
