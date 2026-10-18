import Testing
@testable import Seal

@Suite("描述文件原生调用：超时后继续持有设备租约")
struct ProfileOnlyOperationLeaseTests {
    @Test("超时中的原生调用完成前必须保留忙碌租约")
    func lateNativeCompletionReleasesLease() {
        var lease = ProfileOnlyOperationLease()
        lease.beginNativeOperation()

        let shouldHold = lease.timedOut()
        #expect(shouldHold)
        #expect(lease.holdBusyUntilCompletion)

        let shouldRelease = lease.nativeOperationCompleted()
        #expect(shouldRelease)
        #expect(lease.nativeOperationInFlight == false)
        #expect(lease.holdBusyUntilCompletion == false)
    }

    @Test("原生调用已返回后才处理超时，不得留下永久租约")
    func completionBeforeTimeoutDoesNotHoldLease() {
        var lease = ProfileOnlyOperationLease()
        lease.beginNativeOperation()

        let lateRelease = lease.nativeOperationCompleted()
        let shouldHold = lease.timedOut()

        #expect(lateRelease == false)
        #expect(shouldHold == false)
        #expect(lease.holdBusyUntilCompletion == false)
    }
}
