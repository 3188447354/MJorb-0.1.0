import Foundation

struct BundleIDMapper: Sendable {
    func mainBundleID(
        original: String,
        teamID _: String,
        requested: String? = nil
    ) -> String {
        // 不推断或改写 Bundle ID 格式：保留用户明确输入的值，否则保留 IPA 原值。
        // Apple ID / Team 的命名空间由 Apple 服务处理，不在 Bundle ID 上拼接 Seal 标记。
        if let requested { return requested.trimmingCharacters(in: .whitespacesAndNewlines) }
        return original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func extensionBundleID(
        original: String,
        originalMainBundleID: String,
        mappedMainBundleID: String
    ) -> String {
        let originalLower = original.lowercased()
        let mainLower = originalMainBundleID.lowercased()

        // 已属于目标主 Bundle ID 的扩展 ID 保持原样。
        if originalLower == mappedMainBundleID.lowercased()
            || originalLower.hasPrefix(mappedMainBundleID.lowercased() + ".") {
            return original
        }

        if originalLower.hasPrefix(mainLower + ".") {
            let suffixIndex = original.index(
                original.startIndex,
                offsetBy: originalMainBundleID.count
            )
            let suffix = String(original[suffixIndex...])
            return mappedMainBundleID + suffix
        }
        return original
    }
}
