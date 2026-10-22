import Foundation

struct SealLogEntry: Codable, Equatable, Identifiable, Sendable {
    enum Category: String, Codable, Sendable {
        case account
        case pairing
        case signing
        case installation
        case renewal
        case system
    }

    enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    enum OperationResult: String, Codable, Sendable {
        case success
        case failure
        case notFinal

        var displayName: String {
            switch self {
            case .success: "成功"
            case .failure: "失败"
            case .notFinal: "处理中"
            }
        }
    }

    let id: UUID
    let timestamp: Date
    let category: Category
    let level: Level
    let message: String
    let code: String?
    let operationResult: OperationResult?
    let operationSummary: RenewalRoundSummary?
    /// 同一日志在去重窗口内重复出现的次数（含首次）。见 `LogDedupPolicy`。
    /// 旧版日志 JSON 没有这个字段，解码时按 1 处理。
    let repeatCount: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: Category,
        level: Level = .info,
        message: String,
        code: String? = nil,
        operationResult: OperationResult? = nil,
        operationSummary: RenewalRoundSummary? = nil,
        repeatCount: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.code = code
        self.operationResult = operationResult
        self.operationSummary = operationSummary
        self.repeatCount = max(1, repeatCount)
    }

    /// 复制一条日志并把重复计数加一（去重合并时用；时间戳保持首次出现时刻）。
    func incrementedRepeatCount() -> SealLogEntry {
        SealLogEntry(
            id: id,
            timestamp: timestamp,
            category: category,
            level: level,
            message: message,
            code: code,
            operationResult: operationResult,
            operationSummary: operationSummary,
            repeatCount: repeatCount + 1
        )
    }
}

extension SealLogEntry {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, category, level, message, code
        case operationResult, operationSummary, repeatCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        category = try container.decode(Category.self, forKey: .category)
        level = try container.decode(Level.self, forKey: .level)
        message = try container.decode(String.self, forKey: .message)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        operationResult = try container.decodeIfPresent(
            OperationResult.self, forKey: .operationResult
        )
        operationSummary = try container.decodeIfPresent(
            RenewalRoundSummary.self, forKey: .operationSummary
        )
        // 升级前遗留的日志 JSON 没有 repeatCount，缺省为 1（只出现过一次）。
        repeatCount = max(1, try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1)
    }
}

/// 日志去重判据（纯函数）：短窗口内与已有条目同键的重复日志只合并计数，不新增条目。
///
/// 合并键是 `(category, level, code, message)`，**比对前必须已脱敏** —— 调用方
/// （`SealLogStore.append`）先过 `LogPrivacyRedactor` 再构造条目，所以走到这里的
/// message/code 已经是脱敏后的文本；两个只差邮箱/序列号的原始事件脱敏后同键，
/// 正是应该合并的那一类（见 log-46/47：AltSign 证书解析三件套、anisette 成功行）。
///
/// 窗口**锚定首次出现时刻**（条目时间戳不变、不续窗）：120 秒内的重复计入同一条，
/// 超过窗口的重复另起一条。这样既不会把一整天的周期性日志链式并成一条，
/// 也不会改动缓冲的时序。带 `operationResult` / `operationSummary` 的条目是
/// 用户可见的操作结果（结算、轮次总结），语义上不可合并，一律排除。
enum LogDedupPolicy {
    /// 去重窗口（秒）。取值依据见 part-8 报告对 log-46/47 的模拟：60 秒已能合并
    /// 绝大部分同轮重复，120 秒覆盖一轮库存同步内间隔较远的同键重复。
    static let window: TimeInterval = 120

    struct Key: Hashable, Sendable {
        let category: SealLogEntry.Category
        let level: SealLogEntry.Level
        let code: String?
        let message: String
    }

    static func key(for entry: SealLogEntry) -> Key {
        Key(category: entry.category, level: entry.level, code: entry.code, message: entry.message)
    }

    static func isMergeable(_ entry: SealLogEntry) -> Bool {
        entry.operationResult == nil && entry.operationSummary == nil
    }

    /// 若 `entry` 应并入 `buffer` 中最近的同键条目，返回合并后的新缓冲；否则返回 nil。
    static func merging(
        _ entry: SealLogEntry,
        into buffer: [SealLogEntry],
        window: TimeInterval = LogDedupPolicy.window
    ) -> [SealLogEntry]? {
        guard isMergeable(entry) else { return nil }
        let entryKey = key(for: entry)
        for index in buffer.indices.reversed() {
            let existing = buffer[index]
            guard key(for: existing) == entryKey else { continue }
            guard isMergeable(existing) else { continue }
            let elapsed = entry.timestamp.timeIntervalSince(existing.timestamp)
            // 最近的同键条目已超出窗口时，更早的同键条目只会更旧，不再继续找。
            guard elapsed >= 0, elapsed <= window else { return nil }
            var merged = buffer
            merged[index] = existing.incrementedRepeatCount()
            return merged
        }
        return nil
    }
}

/// 日志留存判据（纯函数）：环形容量内谁先被丢弃。
///
/// 两条规则：
/// 1. 用户可见的操作结果（`LogViewerPolicy.isUserVisibleOperationResult`）优先保留，
///    沿用既有行为 —— 这是导出头里「签名、续签和安装结果优先保留」的实现出处。
/// 2. 其余诊断日志按类别设份额上限：单个 category 最多占诊断容量的
///    `maximumCategoryShare`，防止账号类噪声（log-46/47 里占 90% 以上）把
///    配对/安装等低频但关键的诊断挤光；第一轮没用满的容量第二轮按新旧回填，
///    不浪费名额。
enum LogRetentionPolicy {
    /// 默认环形上限。1000 条在真机一天产生 8000+ 条时只剩约 6 小时；
    /// 提高到 3000 条：按 log-46/47 实测导出文本约 171–206 B/条、JSON 约 260 B/条
    /// 估算，落盘 JSON 约 0.8 MB、Documents 镜像约 0.6 MB，内存可忽略。
    /// 与去重叠加后（log-46 模拟 1000 条原始日志合并为约 290 条），3000 条可覆盖
    /// 一天以上的完整签名/续签现场。属拍板项，取值集中在此常量，改一处即可。
    static let defaultMaximumEntries = 3000
    static let maximumCategoryShare = 0.6

    static func retainedEntries(_ entries: [SealLogEntry], capacity: Int) -> [SealLogEntry] {
        guard capacity >= 0, entries.count > capacity else { return entries }
        let retainedResults = Array(
            entries.filter(LogViewerPolicy.isUserVisibleOperationResult).suffix(capacity)
        )
        let diagnosticCapacity = max(0, capacity - retainedResults.count)
        let diagnostics = entries.filter {
            LogViewerPolicy.isUserVisibleOperationResult($0) == false
        }
        var keptDiagnosticIDs = Set<UUID>()
        if diagnostics.count <= diagnosticCapacity {
            keptDiagnosticIDs = Set(diagnostics.map(\.id))
        } else {
            let perCategoryCap = max(
                1, Int(ceil(Double(diagnosticCapacity) * maximumCategoryShare))
            )
            var perCategoryCount: [SealLogEntry.Category: Int] = [:]
            for entry in diagnostics.reversed() {
                guard keptDiagnosticIDs.count < diagnosticCapacity else { break }
                guard perCategoryCount[entry.category, default: 0] < perCategoryCap else { continue }
                perCategoryCount[entry.category, default: 0] += 1
                keptDiagnosticIDs.insert(entry.id)
            }
            if keptDiagnosticIDs.count < diagnosticCapacity {
                for entry in diagnostics.reversed() {
                    guard keptDiagnosticIDs.count < diagnosticCapacity else { break }
                    keptDiagnosticIDs.insert(entry.id)
                }
            }
        }
        let retainedIDs = Set(retainedResults.map(\.id)).union(keptDiagnosticIDs)
        return entries.filter { retainedIDs.contains($0.id) }
    }
}

extension SealLogEntry.Category {
    /// 导出文本用的中文名（两字宽，列对齐）
    var displayName: String {
        switch self {
        case .account: return "账号"
        case .pairing: return "配对"
        case .signing: return "签名"
        case .installation: return "安装"
        case .renewal: return "续签"
        case .system: return "系统"
        }
    }
}

extension SealLogEntry.Level {
    /// 导出文本用的中文名（两字宽，列对齐）
    var displayName: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

/// 日志导出统一排版：北京时间 + 中文固定宽度栏目，便于阅读。
enum SealLogTextFormatter {
    /// 日志文案里的业务时间统一使用北京时间，保留 ISO 8601 偏移以避免与 UTC 混淆。
    /// 2026-10-04: DateFormatter 提为 static，避免每次调用新建（毫秒级开销）。
    private static let diagnosticFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }()

    static func diagnosticTimestamp(_ date: Date) -> String {
        diagnosticFormatter.string(from: date)
    }

    /// 当前构建标识，形如 `1.1.16 (91)`。
    ///
    /// **为什么构建号必须进日志表头**：`CURRENT_PROJECT_VERSION` 由
    /// `Scripts/build-unsigned-ipa.sh` 取 `GITHUB_RUN_NUMBER`，所以它**唯一对应一次 CI 构建**、
    /// 进而唯一对应一个提交。没有它就无法判断「这份日志来自哪个构建」——
    /// 2026-09-17 实际踩到：拿着一份**旧构建**的日志去分析早就改过的代码，
    /// 从日志文案反推出「修复没生效」的结论，其实那个修复根本还没进到那份构建里。
    /// 有了这一行，`grep 构建` 就能一眼定版，不用再去比对日志文案的措辞。
    static var currentBuildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return "(\(build))"
        default: return "未知"
        }
    }

    static func exportText(
        _ entries: [SealLogEntry],
        capacity: Int = 1000,
        notice: String? = nil,
        buildLabel: String = SealLogTextFormatter.currentBuildLabel
    ) -> String {
        var lines = [
            "Seal 日志 · 北京时间 · 保留最近 \(capacity) 条",
            "构建 \(buildLabel) · 构建号取自 CI run number，可用于定位对应提交"
        ]
        if let notice {
            lines.append(notice)
        }
        lines.append("")
        lines.append(contentsOf: entries.map { entry in
            let code = entry.code.map { "  [\($0)]" } ?? ""
            let time = SealSettingsDateFormatter.string(from: entry.timestamp)
            // 去重合并过的条目在导出时呈现重复次数（时间戳为首次出现时刻）。
            let repeats = entry.repeatCount > 1 ? "  ×\(entry.repeatCount)" : ""
            return "\(time)  \(entry.level.displayName)  \(entry.category.displayName)\(code)  \(entry.message)\(repeats)"
        })
        return lines.joined(separator: "\n")
    }
}
