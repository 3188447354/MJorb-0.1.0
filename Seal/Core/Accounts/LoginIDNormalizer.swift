import Foundation

/// 登录 ID 归一化 —— 凭据保险库（`KeychainVault` / `CredentialVaultFileStore`）的唯一查找键来源。
///
/// ## 为什么要改键（0.1.52 第 7 项根因）
/// 旧版钥匙串以**账号记录 UUID** 为键（`kSecAttrAccount = accountID.uuidString`）。
/// UUID 是本地记录的身份、不是用户的身份：删号重加会新建 UUID ⇒ 旧 secret 还在钥匙串 /
/// 保险库里却按新 UUID 查不到 ⇒ `SEAL-INVENTORY-100b` 反复报「本机没有登录凭据」。
/// 改以**登录 ID 归一化**为键后，同一 Apple ID 无论记录重建多少次都命中同一条 secret，
/// 「重加同号自动接回旧 secret」成为键本身的性质，而不是某条调用路径的补丁。
///
/// ## 归一化规则（纯函数，单测钉死）
/// - 邮箱：`trim` 首尾空白 + 整体小写（Apple ID 邮箱大小写不敏感）。
/// - 手机号：先去掉空格 / 横线 / 括号等一切非数字字符（保留「是否带 +」这一位信息），
///   再统一国家码写法，以中国大陆手机号为主：
///   `+86 138-0000-0000`、`86 138 0000 0000`、`0086…`、裸号 `13800000000`
///   四种写法一律归一为 `+8613800000000`。
/// - 其它国际号码（带 `+`）：`+` + 纯数字，不猜国家。
/// - 既非邮箱也非号码形状的标识：trim + 小写后原样作键（不丢信息、不臆造）。
enum LoginIDNormalizer {
    /// 归一化后的登录 ID，同时就是钥匙串 / 保险库的查找键。
    static func normalizedLoginID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        if trimmed.contains("@") {
            return trimmed.lowercased()
        }
        let digits = trimmed.filter { $0.isNumber }
        guard digits.isEmpty == false else {
            return trimmed.lowercased()
        }
        return normalizedPhoneDigits(digits, hadPlusPrefix: trimmed.hasPrefix("+"))
    }

    /// 保险库查找键。当前与归一化登录 ID 相同；单独留一层是为了将来改键格式时
    /// 只动这里（调用方永远不自己拼键）。
    static func vaultKey(forLoginID raw: String) -> String {
        normalizedLoginID(raw)
    }

    /// 中国大陆手机号：11 位、首位 1、第二位 3-9。
    static func isMainlandMobile(_ digits: String) -> Bool {
        guard digits.count == 11, digits.hasPrefix("1") else { return false }
        let second = digits[digits.index(digits.startIndex, offsetBy: 1)]
        return second.wholeNumberValue.map { (3...9).contains($0) } ?? false
    }

    static func normalizedPhoneDigits(_ digits: String, hadPlusPrefix: Bool) -> String {
        // 0086 是 +86 的国际拨号写法，先剥掉开头的 00 还原成国家码形态。
        var rest = digits
        if rest.hasPrefix("0086") {
            rest = String(rest.dropFirst(2)) // -> 86xxxxxxxxxxx
        }
        // 86 + 大陆手机号（共 13 位）=> +86…
        if rest.hasPrefix("86"), rest.count == 13 {
            return "+" + rest
        }
        // 裸大陆手机号 => 补 +86。
        if isMainlandMobile(rest) {
            return "+86" + rest
        }
        // 86 开头但不是手机号形状（如座机）：仍统一成 + 开头的国际写法，不猜区号。
        if rest.hasPrefix("86"), hadPlusPrefix || rest.count > 11 {
            return "+" + rest
        }
        // 其它带 + 的国际号码：+ 与纯数字拼接。
        if hadPlusPrefix {
            return "+" + rest
        }
        // 无国家码又不是大陆手机号：无法可靠判定国家，保留纯数字作键（同一输入仍稳定命中）。
        return rest
    }

    /// 旧 UUID 键的判据（迁移规划用）：能被 `UUID(uuidString:)` 解析的键是旧键。
    static func isLegacyUUIDKey(_ key: String) -> Bool {
        UUID(uuidString: key) != nil
    }
}
