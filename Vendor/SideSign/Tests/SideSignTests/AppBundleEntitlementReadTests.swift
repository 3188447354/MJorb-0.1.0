import Foundation
import Testing
@testable import SideSign

struct AppBundleEntitlementReadTests {
    @Test
    func emptyEntitlementStringRepresentsAnAppWithNoEntitlements() throws {
        #expect(try AppBundle.readEntitlements(from: "").isEmpty)
    }

    @Test
    func malformedEntitlementPlistThrowsInsteadOfBecomingAnEmptySet() {
        #expect(throws: (any Error).self) {
            try AppBundle.readEntitlements(from: "not a property list")
        }
    }

    @Test
    func propertyListEntitlementsArePreserved() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.application-groups": ["group.example.app"]],
            format: .xml,
            options: 0
        )
        let plist = try #require(String(data: data, encoding: .utf8))

        let entitlements = try AppBundle.readEntitlements(from: plist)

        #expect(entitlements["com.apple.security.application-groups"] as? [String] == ["group.example.app"])
    }
}
