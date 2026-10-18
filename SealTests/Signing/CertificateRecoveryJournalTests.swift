import Foundation
import Testing
@testable import Seal

struct CertificateRecoveryJournalTests {
    @Test
    func revokedSerialsSurviveReloadAndAreScopedByAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "CertificateRecoveryJournal.json")
        let accountID = UUID()
        let otherAccountID = UUID()

        let store = CertificateRecoveryJournalStore(fileURL: fileURL)
        try await store.record(accountID: accountID, revokedSerialNumbers: ["00aBc", "ABC"])
        try await store.record(accountID: accountID, revokedSerialNumbers: ["def"])

        let reloaded = CertificateRecoveryJournalStore(fileURL: fileURL)
        #expect(try await reloaded.revokedSerialNumbers(for: accountID) == ["ABC", "DEF"])
        #expect(try await reloaded.revokedSerialNumbers(for: otherAccountID).isEmpty)

        try await reloaded.clear(accountID: accountID)
        #expect(try await CertificateRecoveryJournalStore(fileURL: fileURL)
            .revokedSerialNumbers(for: accountID).isEmpty)
    }
}
