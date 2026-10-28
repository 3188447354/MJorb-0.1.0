import Foundation
import UserNotifications

final class SealNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func install() {
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if PairingCodeNotification.shouldOpenPairing(
            requestIdentifier: response.notification.request.identifier
        ) {
            PairingCodeNotification.recordPairingScreenTap()
            return
        }

        guard BackgroundRenewalNotificationRoute.shouldRequestResultPresentation(
            requestIdentifier: response.notification.request.identifier
        ) else {
            return
        }

        // The callback can run inside UIKit's scene-restoration transaction. Even a
        // main-queue hop can then abort in _performBlockAfterCATransactionCommitSynchronizes.
        // Persist the intent first; the app scene consumes it only after becoming active.
        let roundID = response.notification.request.content.userInfo[
            BackgroundRenewalNotificationRoute.roundIDUserInfoKey
        ] as? String
        BackgroundRenewalNotificationRoute.recordTap(roundID: roundID)
    }
}
