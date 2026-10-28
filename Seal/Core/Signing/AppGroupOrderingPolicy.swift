import Foundation

/// Produces the one stable App Group order used at every Seal-controlled boundary.
///
/// Apple treats an App Group entitlement as a set, but a few third-party apps use
/// the first item as their shared-container choice. The portal assignment, copied
/// bundle metadata, and signed entitlement must therefore receive the same order.
enum AppGroupOrderingPolicy {
    /// An empty App Groups array requests no group and need not be provisioned.
    /// Other types are retained for normal validation rather than silently discarded.
    static func isEmptyGroupDeclaration(_ value: Any) -> Bool {
        (value as? [String])?.isEmpty == true
    }

    static func removingEmptyGroupDeclaration<Key: Hashable>(
        from entitlements: [Key: any Sendable], groupKey: Key
    ) -> [Key: any Sendable] {
        guard let value = entitlements[groupKey], isEmptyGroupDeclaration(value) else {
            return entitlements
        }
        var result = entitlements
        result.removeValue(forKey: groupKey)
        return result
    }

    static func canonicalize(_ identifiers: [String]) -> [String] {
        Array(Set(identifiers)).sorted()
    }
}

enum AppGroupIdentifierPolicy {
    static func mappedIdentifiers(
        _ identifiers: [String],
        teamIdentifier: String,
        existingIdentifiers: [String]
    ) -> [String] {
        let existing = Set(existingIdentifiers)
        let teamSuffix = ".\(teamIdentifier)"
        return AppGroupOrderingPolicy.canonicalize(identifiers.map { identifier in
            if existing.contains(identifier) || identifier.hasSuffix(teamSuffix) {
                return identifier
            }
            return identifier + teamSuffix
        })
    }
}
