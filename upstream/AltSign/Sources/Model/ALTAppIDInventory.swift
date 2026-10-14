//
//  ALTAppIDInventory.swift
//  AltSign
//

import Foundation

/// The App IDs visible to a team together with the registration quota Apple
/// returned for that same list request.
///
/// `availableQuantity` is intentionally optional because older portal replies
/// do not include it. A negative value is preserved: Apple uses it to mean
/// that clients must defer to the subsequent registration request.
public struct ALTAppIDInventory {
    public let appIDs: [ALTAppID]
    public let maxQuantity: Int?
    public let availableQuantity: Int?

    public init(appIDs: [ALTAppID], maxQuantity: Int?, availableQuantity: Int?) {
        self.appIDs = appIDs
        self.maxQuantity = maxQuantity
        self.availableQuantity = availableQuantity
    }
}
