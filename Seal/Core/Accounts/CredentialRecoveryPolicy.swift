import Foundation

/// 「凭据待恢复」的判定与出口 —— 0.1.52 第 7 项对 `SEAL-INVENTORY-100b` 刷屏的根治。
///
/// ## 现状与根因
/// 库存同步（证书 / App ID）在钥匙串 miss 时以**错误级**抛 `SEAL-INVENTORY-100b/100/100a`
/// 并写错误日志；账号页每次进入都会同步 ⇒ 真机一天成对刷约 20 次。
/// secret 真缺失时同步注定失败，重复抛错既不给用户新信息、又把日志环形缓冲冲掉。
///
/// ## 最小改法（沿用现有账号状态呈现，不新增状态枚举）
/// 待恢复 == 现有 `status == .needsVerification` + `verificationFailureReason == .localCredentialsMissing`：
/// - `AccountAvailabilityPolicy.isSelectable` 已排除 `.needsVerification`
///   ⇒ `refreshApplePortalInventories` 的批量入口天然跳过待恢复账号；
/// - 证书页对不可选账号显示「失效」，详情页引导重新验证 —— 呈现层零改动；
/// - 与签名链路既有口径一致（`SigningCoordinator` 在 secret miss 时正是这样标记，
///   码 `SEAL-AUTH-105a`）。
/// 本类型只负责**判定**（纯函数）与**唯一的待恢复失败出口**，不碰存储。
enum CredentialRecoveryPolicy {
    /// 账号是否处于「凭据待恢复」：记录在、但本机与保险库都没有它的 secret。
    static func isAwaitingRecovery(_ account: AppleAccountRecord) -> Bool {
        account.status == .needsVerification
            && account.verificationFailureReason == .localCredentialsMissing
    }

    /// 库存同步是否应跳过该账号（跳过时不打日志、不改失败状态之外的任何东西）。
    static func shouldSkipInventorySync(_ account: AppleAccountRecord) -> Bool {
        isAwaitingRecovery(account)
    }

    /// 一次性提示的节流判定：同一账号在一个进程内只提示一次。
    /// 节流集合由调用方（`SettingsViewModel`）持有，本函数只做纯判定方便单测。
    static func shouldEmitRecoveryNotice(
        accountID: UUID,
        alreadyNotifiedAccountIDs: Set<UUID>
    ) -> Bool {
        alreadyNotifiedAccountIDs.contains(accountID) == false
    }

    /// secret 是否存在（判定输入的归一化）：`load` 返回非 nil 即存在；
    /// 两处（钥匙串主存 + 保险库）都 miss 才算缺失，见 `KeychainVault.load`。
    static func isCredentialMissing(secret: AccountSecret?) -> Bool {
        secret == nil
    }

    /// 待恢复状态在证书 / 库存页的唯一展示出口（页面级提示，不是错误日志）。
    /// 码 `SEAL-KEYCHAIN-005` 同时用作一次性信息日志的码，保证「提示」与「日志」同源。
    static func recoveryFailure(for account: AppleAccountRecord) -> ImportFailure {
        ImportFailure(
            title: "Apple ID 凭据待恢复",
            reason: "本机没有此 Apple ID 的登录凭据，库存同步已暂停。",
            recovery: "重新验证 Apple ID",
            code: "SEAL-KEYCHAIN-005",
            condition: .accountVerificationRequired,
            action: .reauthenticateAccount,
            route: .account,
            retryDisposition: .manual,
            operation: .validateAccount,
            origin: .authentication
        )
    }
}
