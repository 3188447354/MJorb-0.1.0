import Foundation

/// 按 Apple 账号标识在候选 secret 里找本人的那一条（纯函数）。
///
/// 用途：`KeychainVault.load(accountID:accountIdentifier:)` 的全兜底一步 ——
/// 记录 UUID 键与保险库 accountID 关联都 miss 时，存量 secret 可能还挂在
/// 旧 UUID 键 / 归一化登录 ID 键下，或保险库里只剩旧关联。判据只认
/// `accountIdentifier`（Apple 侧稳定标识，账号记录与 secret 同源同值），
/// 命中即由调用方自愈回填到当前记录键下。
///
/// 纪律：
/// - 标识为空 ⇒ 不匹配任何条目（fail closed：宁可报「待恢复」，不许认错人）。
/// - 多条命中时取签名材料最全的一条（旧副本可能缺新证书材料）；
///   材料同分时保持候选原序取第一条，结果稳定可复现。
enum CredentialIdentityMatcher {
    static func match(
        accountIdentifier: String,
        in candidates: [AccountSecret]
    ) -> AccountSecret? {
        guard accountIdentifier.isEmpty == false else { return nil }
        var best: AccountSecret?
        var bestScore = -1
        for candidate in candidates where candidate.accountIdentifier == accountIdentifier {
            let score = materialScore(candidate)
            if score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best
    }

    /// 签名材料完整度：有当前证书私钥最重，其次历史证书材料条数。
    private static func materialScore(_ secret: AccountSecret) -> Int {
        (secret.certificateP12 != nil ? 100 : 0) + secret.certificateP12BySerial.count
    }
}
