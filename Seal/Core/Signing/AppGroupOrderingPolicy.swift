import Foundation

/// Produces the one stable App Group order used at every Seal-controlled boundary.
///
/// Apple treats an App Group entitlement as a set, but a few third-party apps use
/// the first item as their shared-container choice. The portal assignment, copied
/// bundle metadata, and signed entitlement must therefore receive the same order.
enum AppGroupOrderingPolicy {
    static func canonicalize(_ identifiers: [String]) -> [String] {
        Array(Set(identifiers)).sorted()
    }
}
