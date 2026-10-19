import Foundation

/// 数字版本比较；更新标签的 Apple 格式校验由 UpdateChecker 单独执行。
enum Version {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(of: lhs)
        let b = components(of: rhs)
        let count = max(a.count, b.count)
        for index in 0..<count {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    /// 严格比较数字版本号。无法解析时返回 nil，调用方不得猜测升降级方向。
    static func compareIfValid(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = validatedComponents(of: lhs),
              let b = validatedComponents(of: rhs) else { return nil }
        let count = max(a.count, b.count)
        for index in 0..<count {
            let av = index < a.count ? a[index] : "0"
            let bv = index < b.count ? b[index] : "0"
            let normalizedA = String(av.drop(while: { $0 == "0" }))
            let normalizedB = String(bv.drop(while: { $0 == "0" }))
            let numericA = normalizedA.isEmpty ? "0" : normalizedA
            let numericB = normalizedB.isEmpty ? "0" : normalizedB
            if numericA.count < numericB.count { return .orderedAscending }
            if numericA.count > numericB.count { return .orderedDescending }
            if numericA != numericB {
                return numericA.lexicographicallyPrecedes(numericB)
                    ? .orderedAscending
                    : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func validatedComponents(of version: String) -> [String]? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        let parts = text.components(separatedBy: ".")
        guard parts.isEmpty == false,
              parts.allSatisfy({ part in
                  part.isEmpty == false && part.utf8.allSatisfy { (48...57).contains($0) }
              }) else { return nil }
        return parts
    }

    private static func components(of version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        // 问题13修复：转不成 Int 的分段按 0 处理，而不是丢弃。
        // 否则 "1.0.0-beta" 会被当成 "1.0"（"0-beta" 被 compactMap 丢掉）。
        return text.components(separatedBy: ".").map { Int($0) ?? 0 }
    }
}
