import Testing
@testable import Seal

@Suite("后台续签通知点击路由")
struct BackgroundRenewalNotificationRouteTests {
    @Test
    func onlyBackgroundRenewalNotificationRequestsResultPresentation() {
        #expect(
            BackgroundRenewalNotificationRoute.shouldRequestResultPresentation(
                requestIdentifier: BackgroundRenewalNotificationRoute.identifier
            )
        )
        #expect(
            BackgroundRenewalNotificationRoute.shouldRequestResultPresentation(
                requestIdentifier: "com.mjorb.seal.expiry"
            ) == false
        )
    }
}
