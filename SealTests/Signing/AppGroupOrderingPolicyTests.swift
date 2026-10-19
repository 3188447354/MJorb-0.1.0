import Testing
@testable import Seal

struct AppGroupOrderingPolicyTests {
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
