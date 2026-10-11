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
    func canonicalizesNSArrayOfStrings() {
        let result = AppGroupEntitlementCanonicalizer.apply(to: [
            appGroupsKey: NSArray(array: [
                "group.com.rileytestut.AltStore",
                "group.com.SideStore.SideStore"
            ])
        ])

        #expect(result[appGroupsKey] as? [String] == [
            "group.com.SideStore.SideStore",
            "group.com.rileytestut.AltStore"
        ])
    }

    @Test
    func retainsMixedTypeGroupsWithoutGuessing() {
        let original: [Any] = ["group.example", 1]
        let result = AppGroupEntitlementCanonicalizer.apply(to: [appGroupsKey: original])

        #expect((result[appGroupsKey] as? [Any])?.count == original.count)
        #expect((result[appGroupsKey] as? [Any])?[1] as? Int == 1)
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
