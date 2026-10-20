import Foundation

enum LogViewerPolicy {
    static let maximumVisibleEntries = 20

    static func visibleEntries(_ entries: [SealLogEntry]) -> [SealLogEntry] {
        Array(
            entries
                .filter { operationResult(for: $0) != nil }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(maximumVisibleEntries)
        )
    }

    static func operationResult(for entry: SealLogEntry) -> SealLogEntry.OperationResult? {
        switch entry.category {
        case .signing, .renewal, .installation:
            break
        case .account, .pairing, .system:
            return nil
        }
        if let operationResult = entry.operationResult {
            return operationResult == .notFinal ? nil : operationResult
        }

        // 兼容升级前已经写入的操作结果日志。
        if entry.message.contains("◷ ") || entry.message.contains("○ ") { return nil }
        if entry.level == .error { return .failure }
        if entry.message.contains("✗ ") { return .failure }

        switch entry.category {
        case .signing:
            return entry.message.contains("✓ ") || entry.message.contains("完成安装") ? .success : nil
        case .renewal:
            return entry.message.contains("✓ ") || entry.message.contains("项成功 ——") ? .success : nil
        case .installation:
            return entry.message.contains("设备核验通过") || entry.message.contains("自替换结算确认")
                ? .success : nil
        case .account, .pairing, .system:
            return nil
        }
    }
}
