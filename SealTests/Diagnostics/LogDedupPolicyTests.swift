import Foundation
import Testing
@testable import Seal

/// 0.1.52 第 8 项：日志去重（`LogDedupPolicy`）与留存（`LogRetentionPolicy`）判据。
///
/// 背景（log-46/47 真机实证）：1000 条环形里 AltSign 证书解析三件套占一半以上、
/// anisette 成功行成对出现，一天丢弃 7066 条，真正的签名现场被挤光。
/// 去重只合并「脱敏后同键 + 短窗口」的诊断日志，操作结果/轮次总结永不合并。
struct LogDedupPolicyTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        _ message: String,
        at offset: TimeInterval,
        category: SealLogEntry.Category = .account,
        level: SealLogEntry.Level = .info,
        code: String? = nil,
        operationResult: SealLogEntry.OperationResult? = nil
    ) -> SealLogEntry {
        SealLogEntry(
            timestamp: base.addingTimeInterval(offset),
            category: category,
            level: level,
            message: message,
            code: code,
            operationResult: operationResult
        )
    }

    @Test
    func interleavedRepeatsMergeWithinWindow() {
        // AltSign 三件套的真实形态：A B C A B C 交错重复，不是相邻重复。
        var buffer: [SealLogEntry] = []
        for round in 0..<3 {
            for (index, message) in ["extract started", "parse started", "parse succeeded"].enumerated() {
                let candidate = entry(message, at: TimeInterval(round * 3 + index))
                if let merged = LogDedupPolicy.merging(candidate, into: buffer) {
                    buffer = merged
                } else {
                    buffer.append(candidate)
                }
            }
        }
        #expect(buffer.count == 3)
        #expect(buffer.map(\.repeatCount) == [3, 3, 3])
        // 时间戳锚定首次出现，不被后续重复改写，缓冲时序不变。
        #expect(buffer.map(\.timestamp) == [base, base.addingTimeInterval(1), base.addingTimeInterval(2)])
    }

    @Test
    func windowIsAnchoredAtFirstOccurrenceAndDoesNotChain() {
        let first = entry("same", at: 0)
        let second = entry("same", at: 100)
        let third = entry("same", at: 200)
        let merged = LogDedupPolicy.merging(second, into: [first])
        #expect(merged?.first?.repeatCount == 2)
        // 200 秒距首次已超 120 秒窗口：即使距上次重复只有 100 秒，也不得续窗合并。
        #expect(LogDedupPolicy.merging(third, into: merged ?? [first]) == nil)
    }

    @Test
    func differentKeyFieldsDoNotMerge() {
        let buffer = [entry("same", at: 0)]
        #expect(LogDedupPolicy.merging(entry("other", at: 1), into: buffer) == nil)
        #expect(LogDedupPolicy.merging(entry("same", at: 1, category: .system), into: buffer) == nil)
        #expect(LogDedupPolicy.merging(entry("same", at: 1, level: .warning), into: buffer) == nil)
        #expect(LogDedupPolicy.merging(entry("same", at: 1, code: "SEAL-X-1"), into: buffer) == nil)
    }

    @Test
    func operationResultsNeverMerge() {
        let buffer = [entry("done", at: 0, category: .installation, operationResult: .success)]
        let candidate = entry("done", at: 1, category: .installation, operationResult: .success)
        #expect(LogDedupPolicy.merging(candidate, into: buffer) == nil)
        #expect(LogDedupPolicy.isMergeable(candidate) == false)
    }

    @Test
    func exportTextShowsRepeatCount() {
        let repeated = SealLogEntry(
            timestamp: base, category: .account, message: "merged", repeatCount: 4
        )
        let text = SealLogTextFormatter.exportText([repeated], capacity: 3000, buildLabel: "test")
        #expect(text.contains("merged  ×4"))
        let single = SealLogEntry(timestamp: base, category: .account, message: "once")
        let singleText = SealLogTextFormatter.exportText([single], capacity: 3000, buildLabel: "test")
        #expect(singleText.contains("×") == false)
    }

    @Test
    func legacyJSONWithoutRepeatCountDecodesAsOne() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","timestamp":"2023-11-14T22:13:20Z",\
        "category":"system","level":"info","message":"legacy","code":null,\
        "operationResult":null,"operationSummary":null}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 与 SealLogStore 相同的日期策略下，旧文件必须能读（数值时间戳走同一解码器配置）。
        let entries = try decoder.decode([SealLogEntry].self, from: Data(json.utf8))
        #expect(entries.first?.repeatCount == 1)
    }

    // MARK: - 留存

    @Test
    func retentionCapsSingleCategoryShareOfDiagnostics() {
        var entries: [SealLogEntry] = (0..<9).map {
            entry("noise \($0)", at: TimeInterval($0), category: .account)
        }
        entries.append(entry("pairing diag", at: 100, category: .pairing))
        let retained = LogRetentionPolicy.retainedEntries(entries, capacity: 5)
        // 诊断容量 5，单类上限 ceil(5 × 0.6) = 3：账号噪声最多占 3，配对诊断必须留住。
        #expect(retained.count == 5)
        #expect(retained.contains { $0.category == .pairing })
        #expect(retained.filter { $0.category == .account }.count == 4)
    }

    @Test
    func retentionKeepsOperationResultsAheadOfDiagnostics() {
        var entries: [SealLogEntry] = (0..<8).map {
            entry("noise \($0)", at: TimeInterval($0), category: .account)
        }
        entries.append(SealLogEntry(
            timestamp: base.addingTimeInterval(50),
            category: .installation,
            message: "设备核验通过：Seal",
            operationResult: .success
        ))
        let retained = LogRetentionPolicy.retainedEntries(entries, capacity: 3)
        #expect(retained.contains { $0.operationResult == .success })
        #expect(retained.count == 3)
    }

    @Test
    func retentionUnderCapacityIsIdentity() {
        let entries = [entry("a", at: 0), entry("b", at: 1)]
        #expect(LogRetentionPolicy.retainedEntries(entries, capacity: 3000) == entries)
    }

    // MARK: - Store 集成

    @Test
    func storeMergesRedactedDuplicatesAndPersistsCount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SealTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "Logs.json")
        let store = SealLogStore(
            fileURL: fileURL,
            fileProtector: MarkerFileProtector()
        )
        // 两条原始 message 只差 UUID 后段：脱敏后同为「12345678…[uuid]」同键，
        // 必须合并（证明脱敏在去重比对之前）。
        try await store.append(category: .account, message: "请求 12345678-1111-1111-1111-111111111111 已发出")
        try await store.append(category: .account, message: "请求 12345678-2222-2222-2222-222222222222 已发出")
        try await store.append(category: .account, message: "unrelated")

        let entries = try await store.entries()
        #expect(entries.count == 2)
        #expect(entries.last?.repeatCount == 2)

        let export = try await store.exportText()
        #expect(export.contains("×2"))
        // 合并不是丢弃：导出头不得出现容量丢弃提示。
        #expect(export.contains("因容量限制被丢弃") == false)

        await store.flush()
        let reopened = SealLogStore(fileURL: fileURL, fileProtector: MarkerFileProtector())
        #expect(try await reopened.entries().last?.repeatCount == 2)
    }
}
