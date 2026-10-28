import Testing
@testable import Seal

struct AppGroupOrderingPolicyTests {
    @Test
    func emptyAppGroupDeclarationDoesNotEraseRealOrMalformedGroups() {
        #expect(AppGroupOrderingPolicy.isEmptyGroupDeclaration([String]()))
        #expect(!AppGroupOrderingPolicy.isEmptyGroupDeclaration(["group.example.shared"]))
        #expect(!AppGroupOrderingPolicy.isEmptyGroupDeclaration("invalid"))
        #expect(!AppGroupOrderingPolicy.isEmptyGroupDeclaration([42]))
    }

    @Test
    func normalizationRemovesOnlyAnEmptyAppGroupDeclaration() {
        let empty: [String: any Sendable] = ["groups": [String](), "other": true]
        let result = AppGroupOrderingPolicy.removingEmptyGroupDeclaration(from: empty, groupKey: "groups")
        #expect(result["groups"] == nil)
        #expect(result["other"] as? Bool == true)

        let valid: [String: any Sendable] = ["groups": ["group.example.shared"]]
        let malformed: [String: any Sendable] = ["groups": "invalid"]
        #expect(AppGroupOrderingPolicy.removingEmptyGroupDeclaration(from: valid, groupKey: "groups")["groups"] as? [String] == ["group.example.shared"])
        #expect(AppGroupOrderingPolicy.removingEmptyGroupDeclaration(from: malformed, groupKey: "groups")["groups"] as? String == "invalid")
    }

    @Test
    func canonicalizesEquivalentAppGroupSetsForEveryPortalBoundary() {
        let mainBundleOrder = [
            "group.com.SideStore.SideStore.seal.CT8QZ7352B",
            "group.com.rileytestut.AltStore.seal.CT8QZ7352B"
        ]
        let companionBundleOrder = mainBundleOrder.reversed()

        #expect(AppGroupOrderingPolicy.canonicalize(mainBundleOrder) == [
            "group.com.SideStore.SideStore.seal.CT8QZ7352B",
            "group.com.rileytestut.AltStore.seal.CT8QZ7352B"
        ])
        #expect(
            AppGroupOrderingPolicy.canonicalize(Array(companionBundleOrder))
                == AppGroupOrderingPolicy.canonicalize(mainBundleOrder)
        )
    }

    @Test
    func canonicalizationRemovesDuplicatePortalAssignmentInputs() {
        #expect(AppGroupOrderingPolicy.canonicalize([
            "group.com.example.shared.seal.TEAM",
            "group.com.example.shared.seal.TEAM",
            "group.com.example.other.seal.TEAM"
        ]) == [
            "group.com.example.other.seal.TEAM",
            "group.com.example.shared.seal.TEAM"
        ])
    }

    @Test
    func reusesAnExistingAppGroupAndMapsForeignGroupsToTheCurrentTeam() {
        #expect(AppGroupIdentifierPolicy.mappedIdentifiers(
            [
                "group.com.SideStore.SideStore",
                "group.com.example.owned"
            ],
            teamIdentifier: "TEAM123456",
            existingIdentifiers: [
                "group.com.example.owned",
                "group.com.SideStore.SideStore.TEAM123456"
            ]
        ) == [
            "group.com.SideStore.SideStore.TEAM123456",
            "group.com.example.owned"
        ])
    }

    @Test
    func leavesAlreadyTeamScopedAppGroupsUnchanged() {
        #expect(AppGroupIdentifierPolicy.mappedIdentifiers(
            ["group.com.example.shared.TEAM123456"],
            teamIdentifier: "TEAM123456",
            existingIdentifiers: []
        ) == ["group.com.example.shared.TEAM123456"])
    }
}
