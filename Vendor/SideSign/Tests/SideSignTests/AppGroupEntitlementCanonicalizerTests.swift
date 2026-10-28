import Foundation
import Testing
@testable import SideSign

struct AppGroupEntitlementCanonicalizerTests {
    private let appGroupsKey = "com.apple.security.application-groups"

    @Test
    func emptyRequestedGroupsDoNotInheritGroupsFromProfile() {
        let profile: [String: any Sendable] = [appGroupsKey: ["group.example.old"], "other": true]
        let result = AppGroupEntitlementCanonicalizer.omittingEmptyRequestedGroups(
            from: profile, requested: [appGroupsKey: [String]()]
        )
        #expect(result[appGroupsKey] == nil)
        #expect(result["other"] as? Bool == true)
    }

    @Test
    func nonemptyOrMalformedRequestedGroupsAreNotSilentlyRemoved() {
        let profile: [String: any Sendable] = [appGroupsKey: ["group.example.shared"]]
        let cases: [[String: any Sendable]] = [
            [appGroupsKey: ["group.example.shared"]],
            [appGroupsKey: "invalid"],
        ]
        for requested in cases {
            let result = AppGroupEntitlementCanonicalizer.omittingEmptyRequestedGroups(from: profile, requested: requested)
            #expect(result[appGroupsKey] as? [String] == ["group.example.shared"])
        }
    }

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
