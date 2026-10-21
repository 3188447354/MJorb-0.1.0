import Foundation
import UniformTypeIdentifiers

enum SealInstalledAppMarker {
    static let version = 2
    static let legacyTypeIdentifier = "com.mjorb.seal.installed-app"
    private static let typePrefix = "com.mjorb.seal.installed."

    static func typeIdentifier(for bundleIdentifier: String) -> String {
        typePrefix + bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func markerVersion(in infoDictionary: [String: Any], for bundleIdentifier: String) -> Int? {
        let identifier = typeIdentifier(for: bundleIdentifier)
        let declarations = infoDictionary["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        return declarations.contains { ($0["UTTypeIdentifier"] as? String) == identifier }
            ? version
            : nil
    }

    static func isDeclared(for bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              let type = UTType(typeIdentifier(for: normalized)) else {
            return false
        }
        return type.isDeclared
    }
}
