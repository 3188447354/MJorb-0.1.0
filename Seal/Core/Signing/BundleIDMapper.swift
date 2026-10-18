import CryptoKit
import Foundation

struct BundleIDMapper: Sendable {
    let prefix: String

    init(prefix: String = "com.mjorb.seal.apps") {
        self.prefix = prefix
    }

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

        // 🔴 **幂等保护**（2026-10-16 真机实测）：
        // 扩展的 Bundle ID 可能**已经是映射后的形态**，此时绝不能再套一次。
        //
        // 实测证据：主 App 得到 `com.mjorb.seal.3432ZHJUF9`（正确），
        // 扩展却被注册成 `com.mjorb.seal.3432ZHJUF9.3432ZHJUF9.LiveActivity`
        // —— 团队后缀出现了两次。那一个多余的 App ID 既浪费免费账号每周 10 个的名额，
        // 又让签名产物与运行中的 Seal 结构对不上 ⇒ 自更新被 `SEAL-SELF-106` 拦下。
        //
        // 判据：原始 ID 以「映射后的主 ID」开头 ⇒ 它已经是映射过的形态，原样返回。
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
        return "\(mappedMainBundleID).e\(digest(original, length: 10))"
    }

    func extensionBundleID(
        original: String,
        mappedMainBundleID: String
    ) -> String {
        "\(mappedMainBundleID).e\(digest(original, length: 10))"
    }

    func appGroupID(original: String, teamID: String) -> String {
        // App Group 是独立于 Bundle ID 的命名空间，沿用现有格式以保证团队隔离。
        //
        // 幂等：续签时输入的是已签名二进制 entitlements 里的 group ID（已映射过），
        // 若再追加一次 .seal.<teamID> 会得到 group.x.seal.TEAM.seal.TEAM，
        // fetchAppGroups 查不到 → 误调 addAppGroup → Apple 回 -1（曾被误报为 SEAL-APPID-303）。
        // 对齐 mainBundleID 的同类保护：已带当前 team 后缀（大小写不敏感）则原样返回。
        let suffix = ".seal.\(teamID)"
        if original.lowercased().hasSuffix(suffix.lowercased()) {
            return original
        }
        let base = original.hasPrefix("group.") ? String(original.dropFirst(6)) : original
        return "group.\(base).seal.\(teamID)"
    }

    private func digest(_ value: String, length: Int) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.map { String(format: "%02x", $0) }
            .joined()
            .prefix(length)
            .description
    }
}
