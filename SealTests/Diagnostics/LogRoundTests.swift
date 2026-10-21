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
        let componentDetail = SealLogEntry(
            timestamp: Date(timeIntervalSince1970: 999),
            category: .renewal,
            message: "单项续签成功",
            code: "SEAL-RENEW-020",
            operationResult: .success
        )

        let visible = LogViewerPolicy.visibleEntries(entries + [unrelated, pending, componentDetail])

        #expect(visible.count == 20)
        #expect(visible.first?.message == "操作结果 58")
        #expect(visible.last?.message == "操作结果 20")
        #expect(visible.contains(where: { $0.operationResult == .success }))
        #expect(visible.contains(where: { $0.operationResult == .failure }))
        #expect(visible.allSatisfy { $0.category == .installation || $0.category == .renewal })
    }

    @Test
    func parsesLegacyRenewalRoundIntoStructuredSummary() {
        let entry = SealLogEntry(
            timestamp: Date(timeIntervalSince1970: 1_792_500_822),
            category: .renewal,
            message: "▶ 第1轮 · 17:53:33 · 手动 · 1个App\n✓ Demo 成功，有效期至 2026-10-27 17:53:54\n■ 完成 · 共用9秒 · 1/1 成功",
            code: "SEAL-RENEW-ROUND",
            operationResult: .success
        )

        let summary = LogViewerPolicy.operationSummary(for: entry)

        #expect(summary?.operation == .batchRenewal)
        #expect(summary?.triggerSource == .manual)
        #expect(summary?.items.first?.appName == "Demo")
        #expect(summary?.items.first?.profileExpirationDate != nil)
    }

    @Test
    func applicationUpdateHasItsOwnSingleAppOperationType() {
        let summary = RenewalRoundSummary(
            roundNumber: 0,
            triggerSource: .manual,
            operation: .singleUpdate,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 102),
            items: [
                RenewalRoundItem(
                    appName: "Demo",
                    outcome: .succeeded,
                    duration: 2,
                    profileExpirationDate: nil,
                    failureCode: nil,
                    failureReason: nil,
                    failureRecovery: nil
                )
            ]
        )

        #expect(summary.operation.displayTitle(triggerSource: .manual) == "更新")
        #expect(summary.operation.showsAppCount == false)
        #expect(LogViewerPolicy.operationSummary(for: SealLogEntry(
            category: .installation,
            message: summary.humanReadableMessage(),
            operationResult: .success,
            operationSummary: summary
        ))?.operation == .singleUpdate)
    }

    @Test
    func sealSelfUpdateSummaryNamesTheAppAndUsesConfirmedTransactionDuration() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let endedAt = Date(timeIntervalSince1970: 113)
        let expiration = Date(timeIntervalSince1970: 2_100_000_000)
        let summary = RenewalRoundSummary.sealUpdate(
            startedAt: startedAt,
            endedAt: endedAt,
            expirationDate: expiration
        )
        let entry = SealLogEntry(
            category: .installation,
            message: summary.humanReadableMessage(),
            operationResult: .success,
            operationSummary: summary
        )

        #expect(summary.operation == .singleUpdate)
        #expect(summary.items.map(\.appName) == ["Seal"])
        #expect(summary.totalDuration == 13)
        #expect(LogViewerPolicy.visibleEntries([entry]) == [entry])
    }

    @Test
    func displaysFinishedRoundsThatIncludeAppsNotRun() {
        let summary = RenewalRoundSummary(
            roundNumber: 1,
            triggerSource: .manual,
            operation: .batchRenewal,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 110),
            items: [
                RenewalRoundItem(
                    appName: "Renewed",
                    outcome: .succeeded,
                    duration: 4,
                    profileExpirationDate: nil,
                    failureCode: nil,
                    failureReason: nil,
                    failureRecovery: nil
                ),
                RenewalRoundItem(
                    appName: "Needs action",
                    outcome: .needsAction,
                    duration: 0,
                    profileExpirationDate: nil,
                    failureCode: "SEAL-TEST-001",
                    failureReason: "需要重新登录",
                    failureRecovery: "打开我的页面"
                )
            ]
        )
        let entry = SealLogEntry(
            timestamp: Date(timeIntervalSince1970: 110),
            category: .renewal,
            message: summary.humanReadableMessage(),
            code: "SEAL-RENEW-ROUND",
            operationResult: .notFinal,
            operationSummary: summary
        )

        #expect(LogViewerPolicy.visibleEntries([entry]) == [entry])
        #expect(LogViewerPolicy.operationResult(for: entry) == .failure)
        #expect(LogViewerPolicy.operationSummary(for: entry)?.needsActionCount == 1)
    }
}
