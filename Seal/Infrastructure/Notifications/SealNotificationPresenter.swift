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
        if PairingCodeNotificationRoute.shouldOpenPairing(
            requestIdentifier: response.notification.request.identifier
        ) {
            await MainActor.run {
                PairingCodeNotificationRoute.requestOpen()
            }
            return
        }

        guard BackgroundRenewalNotificationRoute.shouldRequestResultPresentation(
            requestIdentifier: response.notification.request.identifier
        ) else {
            return
        }

        await MainActor.run {
            NotificationCenter.default.post(name: BackgroundRenewalNotificationRoute.opened, object: nil)
        }
    }
}
