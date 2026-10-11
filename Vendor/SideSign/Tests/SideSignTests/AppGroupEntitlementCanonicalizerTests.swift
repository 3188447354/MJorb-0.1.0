import Foundation
import Testing
@testable import SideSign

struct AppGroupEntitlementCanonicalizerTests {
    private let appGroupsKey = "com.apple.security.application-groups"

    @Test
    func sortsAndDeduplicatesStringGroups() {
        let result = AppGroupEntitlementCanonicalizer.apply(to: [
            appGroupsKey: [
                "group.com.rileytestut.AltStore",
                "group.com.SideStore.SideStore",
                "group.com.rileytestut.AltStore"
            ]
        ])

        #expect(result[appGroupsKey] as? [String] == [
            "group.com.SideStore.SideStore",
            "group.com.rileytestut.AltStore"
        ])
    }

    @Test
    func preservesUnsupportedSendableValueWithoutGuessing() {
        let original = 42
        let result = AppGroupEntitlementCanonicalizer.apply(to: [
            appGroupsKey: original
        ])

        #expect(result[appGroupsKey] as? Int == original)
    }

    @Test
    func neverReordersKeychainAccessGroups() {
        let original = ["TEAM.first", "TEAM.second"]
        let result = AppGroupEntitlementCanonicalizer.apply(to: [
            "keychain-access-groups": original
        ])

        #expect(result["keychain-access-groups"] as? [String] == original)
    }
}
