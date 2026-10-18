import Foundation
import Testing
@testable import Seal

struct PendingSignedSnapshotMigrationTests {
    @Test
    func olderPendingSnapshotWithoutInstallAttemptFieldsStillDecodes() throws {
        let data = Data(#"{"signingTargets":[],"extensionSnapshots":[]}"#.utf8)

        let snapshot = try JSONDecoder().decode(PendingSignedSnapshot.self, from: data)

        #expect(snapshot.installAttemptID == nil)
        #expect(snapshot.wasInstalledBeforeAttempt == false)
        #expect(snapshot.signingTargets.isEmpty)
        #expect(snapshot.extensionSnapshots.isEmpty)
    }
}
