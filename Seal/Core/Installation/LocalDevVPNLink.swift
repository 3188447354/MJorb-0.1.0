import Foundation
import UIKit

enum LocalDevVPNLink {
    static let enableAndReturn = URL(
        string: "localdevvpn://enable?scheme=seal"
    )!
    static let disableAndReturn = URL(
        string: "localdevvpn://disable?scheme=seal"
    )!
    static let appStore = URL(
        string: "itms-apps://itunes.apple.com/app/id6755608044"
    )!

    @MainActor
    static func openApplication() {
        UIApplication.shared.open(enableAndReturn) { opened in
            if opened == false {
                UIApplication.shared.open(appStore)
            }
        }
    }

    static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "seal"
    }
}
