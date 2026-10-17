import Testing
@testable import Seal

@Suite("配对码通知点击路由")
struct PairingCodeNotificationRouteTests {
    @Test
    func onlyPairingCodeNotificationRequestsPairingRoute() {
        #expect(
            PairingCodeNotificationRoute.shouldOpenPairing(
                requestIdentifier: PairingCodeNotification.identifier
            )
        )
        #expect(
            PairingCodeNotificationRoute.shouldOpenPairing(
                requestIdentifier: BackgroundRenewalNotificationRoute.identifier
            ) == false
        )
    }
}
