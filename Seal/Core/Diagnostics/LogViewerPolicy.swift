import Foundation

enum LogViewerPolicy {
    static let maximumVisibleEntries = 20

    static func visibleEntries(_ entries: [SealLogEntry]) -> [SealLogEntry] {
        Array(
            entries
                .filter { operationResult(for: $0) != nil && isSummaryEntry($0) }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(maximumVisibleEntries)
        )
    }

    static func operationSummary(for entry: SealLogEntry) -> RenewalRoundSummary? {
        if let summary = entry.operationSummary {
            guard summary.measuredDuration == nil,
                  let duration = durationInMessage(entry.message) else {
                return summary
            }
            return RenewalRoundSummary(
                roundNumber: summary.roundNumber,
                triggerSource: summary.triggerSource,
                operation: summary.operation,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt,
                items: summary.items,
                measuredDuration: duration
            )
        }
        return legacyOperationSummary(for: entry)
    }

    static func operationResult(for entry: SealLogEntry) -> SealLogEntry.OperationResult? {
        switch entry.category {
        case .signing, .renewal, .installation:
            break
        case .account, .pairing, .system:
            return nil
        }
        if let operationResult = entry.operationResult {
            guard operationResult == .notFinal else { return operationResult }
            guard let summary = operationSummary(for: entry), summary.awaitingCount == 0 else { return nil }
            return summary.failedCount + summary.needsActionCount > 0 ? .failure : .success
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

    static func isUserVisibleOperationResult(_ entry: SealLogEntry) -> Bool {
        operationResult(for: entry) != nil && isSummaryEntry(entry)
    }

    private static func isSummaryEntry(_ entry: SealLogEntry) -> Bool {
        // Per-App renewal diagnostics and raw signing errors are already represented by the
        // operation summary, whose failure reason is shown only when the user taps the row.
        guard entry.code != "SEAL-RENEW-020", entry.code != "SEAL-RENEW-030" else { return false }
        if operationSummary(for: entry) != nil { return true }
        if entry.category == .installation {
            return entry.operationResult != nil
                || entry.message.contains("设备核验通过")
                || entry.message.contains("自替换结算确认")
        }
        guard entry.code == nil, entry.level != .error else { return false }
        return entry.message.contains("✓ ") || entry.message.contains("✗ ")
    }

    private static func legacyOperationSummary(for entry: SealLogEntry) -> RenewalRoundSummary? {
        let lines = entry.message.components(separatedBy: .newlines)
        guard let header = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("▶ ") }) else {
            return nil
        }

        let parts = header
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "▶ ", with: "")
            .components(separatedBy: " · ")
        guard let label = parts.first else { return nil }
        let triggerSource: RenewalTriggerSource = parts.contains("快捷指令")
            ? .shortcut : parts.contains("后台") ? .background : .manual
        let operation: RenewalRoundOperation
        if entry.category == .signing {
            operation = .singleSigning
        } else if label.contains("单独续签") {
            operation = .singleRenewal
        } else if label == "更新" {
            operation = .singleUpdate
        } else if label == "安装" {
            operation = .singleInstallation
        } else {
            operation = .batchRenewal
        }

        let roundNumber = Self.firstInteger(in: label, matching: "第([0-9]+)轮") ?? 0
        let startedAt = Self.legacyStartDate(in: parts, relativeTo: entry.timestamp)
        let items = lines.compactMap(Self.legacyItem(from:))
        guard items.isEmpty == false else { return nil }

        return RenewalRoundSummary(
            roundNumber: roundNumber,
            triggerSource: triggerSource,
            operation: operation,
            startedAt: startedAt,
            endedAt: entry.timestamp,
            items: items,
            measuredDuration: durationInMessage(entry.message)
        )
    }

    private static func durationInMessage(_ message: String) -> TimeInterval? {
        let pattern = #"(?:共用|共计)\s*(?:(\d+)\s*分)?(\d+(?:\.\d+)?)\s*秒"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: message,
                range: NSRange(message.startIndex..., in: message)
              ),
              let secondsRange = Range(match.range(at: 2), in: message),
              let seconds = TimeInterval(String(message[secondsRange])) else {
            return nil
        }
        let minutes: TimeInterval
        if match.range(at: 1).location == NSNotFound {
            minutes = 0
        } else if let minutesRange = Range(match.range(at: 1), in: message),
                  let parsedMinutes = TimeInterval(String(message[minutesRange])) {
            minutes = parsedMinutes
        } else {
            return nil
        }
        return max(0, minutes * 60 + seconds)
    }

    private static func legacyItem(from line: String) -> RenewalRoundItem? {
        let value = line.trimmingCharacters(in: .whitespaces)
        let outcome: RenewalRoundItem.Outcome
        let marker: String
        let delimiter: String
        switch value {
        case let line where line.hasPrefix("✓ "):
            outcome = .succeeded
            marker = "✓ "
            delimiter = " 成功"
        case let line where line.hasPrefix("✗ "):
            outcome = .failed
            marker = "✗ "
            delimiter = " 失败"
        case let line where line.hasPrefix("○ "):
            outcome = .needsAction
            marker = "○ "
            delimiter = " 本轮未执行"
        case let line where line.hasPrefix("◷ "):
            outcome = .awaitingConfirmation
            marker = "◷ "
            delimiter = " 等待新进程核验"
        default:
            return nil
        }

        let body = String(value.dropFirst(marker.count))
        guard let end = body.range(of: delimiter) else { return nil }
        let appName = String(body[..<end.lowerBound])
        let expirationDate: Date?
        if let range = body.range(of: "有效期至 ") {
            expirationDate = Self.legacyDate(String(body[range.upperBound...]))
        } else {
            expirationDate = nil
        }

        return RenewalRoundItem(
            appName: appName,
            outcome: outcome,
            duration: 0,
            profileExpirationDate: expirationDate,
            failureCode: nil,
            failureReason: nil,
            failureRecovery: nil
        )
    }

    private static func legacyStartDate(in parts: [String], relativeTo date: Date) -> Date {
        guard let time = parts.first(where: { $0.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil }),
              let match = time.range(of: #"^(\d{2}):(\d{2}):(\d{2})$"#, options: .regularExpression) else {
            return date
        }
        let components = time[match].split(separator: ":").compactMap { Int($0) }
        guard components.count == 3 else { return date }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dateComponents.hour = components[0]
        dateComponents.minute = components[1]
        dateComponents.second = components[2]
        guard var parsed = calendar.date(from: dateComponents) else { return date }
        if parsed > date {
            parsed = calendar.date(byAdding: .day, value: -1, to: parsed) ?? parsed
        }
        return parsed
    }

    private static func legacyDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(value.prefix(19)))
    }

    private static func firstInteger(in value: String, matching pattern: String) -> Int? {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
        let digits = value[range].filter(\.isNumber)
        return Int(digits)
    }
}
