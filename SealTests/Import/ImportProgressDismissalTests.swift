import Foundation
import Testing
@testable import Seal

@MainActor
struct ImportProgressDismissalTests {
    @Test
    func dismissingCommitProgressKeepsTheTransactionActive() throws {
        let model = try #require(
            AppsViewModel.uiTestModel(arguments: ["--ui-testing-import-committing"])
        )
        #expect(model.phase == .committing)
        #expect(model.isImportSheetPresented)
        #expect(model.sheetDraft != nil)

        model.dismissImportProgress()

        #expect(model.phase == .committing)
        #expect(model.sheetDraft != nil)
        #expect(model.isImportSheetPresented == false)
    }
}
