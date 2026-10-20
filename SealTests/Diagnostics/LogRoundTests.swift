import Foundation
import Testing
@testable import Seal

struct LogViewerPolicyTests {
    @Test
    func displaysOnlyLatestTwentyOperationResults() throws {
        let entries = (0..<60).map { index in
            SealLogEntry(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                category: index.isMultiple(of: 2) ? .installation : .renewal,
                level: .info,
                message: "操作结果 \(index)",
                operationResult: index.isMultiple(of: 2)
                    ? (index.isMultiple(of: 4) ? .success : .failure)
                    : nil
            )
        }
        let unrelated = SealLogEntry(
            category: .account,
            message: "账号登录",
            operationResult: .failure
        )
        let pending = SealLogEntry(
            category: .renewal,
            message: "等待新进程核验",
            operationResult: .notFinal
        )

        let visible = LogViewerPolicy.visibleEntries(entries + [unrelated, pending])

        #expect(visible.count == 20)
        #expect(visible.first?.message == "操作结果 58")
        #expect(visible.last?.message == "操作结果 20")
        #expect(visible.contains(where: { $0.operationResult == .success }))
        #expect(visible.contains(where: { $0.operationResult == .failure }))
        #expect(visible.allSatisfy { $0.category == .installation || $0.category == .renewal })
    }
}
