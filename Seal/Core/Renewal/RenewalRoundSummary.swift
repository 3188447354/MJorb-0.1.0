import Foundation

/// 续签触发来源（日志轮次头用）。
enum RenewalTriggerSource: String, Codable, Sendable {
    /// 用户在 App 内手动点「续签全部」/ 单项续签
    case manual
    /// 快捷指令触发（后台或前台）
    case shortcut
    /// 后台预测式续签
    case background

    var displayName: String {
        switch self {
        case .manual: "手动"
        case .shortcut: "快捷指令"
        case .background: "后台"
        }
    }
}

/// 日志轮次的操作类型。单项操作也使用与批量续签相同的卡片语法，
/// 这样日志页和导出文件只需维护一套解析与呈现逻辑。
enum RenewalRoundOperation: String, Codable, Equatable, Sendable {
    case batchRenewal
    case singleRenewal
    case singleSigning
    case singleUpdate
    case singleInstallation

    var headerLabel: String? {
        switch self {
        case .batchRenewal: nil
        case .singleRenewal: "单独续签"
        case .singleSigning: "单独签名"
        case .singleUpdate: "更新"
        case .singleInstallation: "安装"
        }
    }

    func displayTitle(triggerSource: RenewalTriggerSource) -> String {
        switch self {
        case .batchRenewal:
            switch triggerSource {
            case .manual: return "手动续签"
            case .shortcut: return "快捷指令续签"
            case .background: return "后台续签"
            }
        case .singleRenewal:
            switch triggerSource {
            case .manual: return "手动续签"
            case .shortcut: return "快捷指令续签"
            case .background: return "后台续签"
            }
        case .singleSigning:
            switch triggerSource {
            case .manual: return "签名"
            case .shortcut: return "快捷指令签名"
            case .background: return "后台签名"
            }
        case .singleUpdate: return "更新"
        case .singleInstallation: return "安装"
        }
    }

    var showsAppCount: Bool {
        self != .singleSigning && self != .singleUpdate
    }
}

/// 轮次里单个 App 的结果（供轮次总结用）。
struct RenewalRoundItem: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case succeeded
        case failed
        case needsAction
        case awaitingConfirmation
    }

    let appName: String
    let outcome: Outcome
    /// 真实耗时（秒），由单调时钟测量，避免系统时间变化影响结果。
    let duration: TimeInterval
    /// 成功时新描述文件的到期时间（用户要看"有效期至"）
    let profileExpirationDate: Date?
    /// 失败时的诊断码（技术层用）
    let failureCode: String?
    /// 失败时的人话原因（用户层用，已是去术语文案）
    let failureReason: String?
    /// 失败时的恢复建议；为"知道了"时表示用户无法自行解决
    let failureRecovery: String?
}

/// 一轮续签的总结（人话层 + 技术层同源）。
///
/// 写入 `SealLogStore` 一条 `SEAL-RENEW-ROUND` 日志，App 内展示与导出文本
/// 都从这条解析/渲染，共用一份底层数据。
struct RenewalRoundSummary: Codable, Equatable, Sendable {
    let roundNumber: Int
    let triggerSource: RenewalTriggerSource
    let operation: RenewalRoundOperation
    let startedAt: Date
    let endedAt: Date
    let items: [RenewalRoundItem]
    /// 持久化的真实耗时。ISO-8601 日期编码会丢弃 Date 的亚秒部分，不能用解码后的起止时间重算。
    let measuredDuration: TimeInterval?

    init(
        roundNumber: Int,
        triggerSource: RenewalTriggerSource,
        operation: RenewalRoundOperation,
        startedAt: Date,
        endedAt: Date,
        items: [RenewalRoundItem],
        measuredDuration: TimeInterval? = nil
    ) {
        self.roundNumber = roundNumber
        self.triggerSource = triggerSource
        self.operation = operation
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.items = items
        self.measuredDuration = max(0, measuredDuration ?? endedAt.timeIntervalSince(startedAt))
    }

    var totalDuration: TimeInterval {
        max(0, measuredDuration ?? endedAt.timeIntervalSince(startedAt))
    }
    var succeededCount: Int { items.filter { $0.outcome == .succeeded }.count }
    var failedCount: Int { items.filter { $0.outcome == .failed }.count }
    var needsActionCount: Int { items.filter { $0.outcome == .needsAction }.count }
    var awaitingCount: Int { items.filter { $0.outcome == .awaitingConfirmation }.count }

    static func sealUpdate(
        startedAt: Date,
        endedAt: Date,
        expirationDate: Date,
        measuredDuration: TimeInterval? = nil
    ) -> Self {
        let duration = max(0, measuredDuration ?? endedAt.timeIntervalSince(startedAt))
        return Self(
            roundNumber: 0,
            triggerSource: .manual,
            operation: .singleUpdate,
            startedAt: startedAt,
            endedAt: endedAt,
            items: [
                RenewalRoundItem(
                    appName: "Seal",
                    outcome: .succeeded,
                    duration: duration,
                    profileExpirationDate: expirationDate,
                    failureCode: nil,
                    failureReason: nil,
                    failureRecovery: nil
                )
            ],
            measuredDuration: duration
        )
    }

    /// 人话层消息（用户直接看的）。
    ///
    /// 只说"成了没、用了多久、失败了为什么、找谁"，
    /// 不出现诊断码/Bundle ID 等术语；日志里不放重试按钮。
    func humanReadableMessage() -> String {
        let time = Self.timeFormatter.string(from: startedAt)
        let header = if let label = operation.headerLabel {
            "▶ \(label) · \(time) · \(triggerSource.displayName) · \(items.count)个App"
        } else {
            "▶ 第\(roundNumber)轮 · \(time) · \(triggerSource.displayName) · \(items.count)个App"
        }
        var lines = [
            "━━━━━━━━━━━━━━━━━━━━━━━━",
            header,
            "────────────────────────────────",
        ]
        for item in items {
            switch item.outcome {
            case .succeeded:
                if let expiry = item.profileExpirationDate {
                    let dateStr = Self.expiryFormatter.string(from: expiry)
                    lines.append("✓ \(item.appName) 成功，有效期至 \(dateStr)")
                } else {
                    lines.append("✓ \(item.appName) 成功，用了\(Self.formatDuration(item.duration))")
                }
            case .failed:
                lines.append("✗ \(item.appName) 失败，用了\(Self.formatDuration(item.duration))")
                if let reason = item.failureReason, !reason.isEmpty {
                    // 原因可能含换行，逐行缩进
                    for rline in reason.split(separator: "\n") {
                        lines.append("  原因：\(rline)")
                    }
                }
                // 用户无法自行解决时（recovery 只是"知道了"），指引找作者
                let recovery = item.failureRecovery ?? ""
                let reason = item.failureReason ?? ""
                if recovery == "知道了" && !reason.contains("MJorb") {
                    lines.append("  → 将日志发给作者 MJorb")
                }
            case .needsAction:
                lines.append("○ \(item.appName) 本轮未执行")
                if let reason = item.failureReason, !reason.isEmpty {
                    for rline in reason.split(separator: "\n") {
                        lines.append("  原因：\(rline)")
                    }
                }
            case .awaitingConfirmation:
                lines.append("◷ \(item.appName) 等待新进程核验")
            }
        }
        lines.append("────────────────────────────────")
        var footer = "■ 完成 · 共用\(Self.formatDuration(totalDuration))"
        if failedCount == 0 && needsActionCount == 0 && awaitingCount == 0 {
            footer += " · \(succeededCount)/\(items.count) 成功"
        } else {
            var parts: [String] = []
            if succeededCount > 0 { parts.append("\(succeededCount)成功") }
            if failedCount > 0 { parts.append("\(failedCount)失败") }
            if needsActionCount > 0 { parts.append("\(needsActionCount)未执行") }
            if awaitingCount > 0 { parts.append("\(awaitingCount)待核验") }
            footer += " · " + parts.joined(separator: " · ")
        }
        lines.append(footer)
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━")
        return lines.joined(separator: "\n")
    }

    /// 技术层摘要（诊断码行，供导出/排查用）。
    /// 人话层不展示这些；导出文本里跟在人话层后面。
    func technicalSummary() -> String {
        var lines: [String] = []
        for item in items {
            if let code = item.failureCode {
                lines.append("[\(code)] \(item.appName)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 格式工具

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 续签结果与日志页里的有效期时间统一显示到秒。
    private static let expiryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 时长按真实起止时间四舍五入到 0.1 秒：4.2秒 / 1分23.4秒
    static func formatDuration(_ interval: TimeInterval) -> String {
        let roundedTenths = Int((max(0, interval) * 10).rounded())
        let minutes = roundedTenths / 600
        let remainingTenths = roundedTenths % 600
        let wholeSeconds = remainingTenths / 10
        let fractionalDigit = remainingTenths % 10
        let secondsText = fractionalDigit == 0
            ? "\(wholeSeconds)"
            : "\(wholeSeconds).\(fractionalDigit)"
        return minutes == 0
            ? "\(secondsText)秒"
            : "\(minutes)分\(secondsText)秒"
    }

    static func formatExpirationDate(_ date: Date) -> String {
        expiryFormatter.string(from: date)
    }
}
