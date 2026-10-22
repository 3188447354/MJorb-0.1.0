import Foundation
@preconcurrency import AltSign

/// 门户 Team 列表的**跨服务共享缓存**（2026-10-22，门户提速）。
///
/// 此前只有 `ApplePortalSigningService` 私有一份团队缓存，而且会话验证那次
/// `bypassCache` 的实时结果**不回填** —— 同一轮签名里 `listTeams` 至少发两次
/// （验证 1 次 + 主流程冷拉 1 次），证书 / 库存服务另起炉灶再各拉一次，
/// 慢网络下每次往返 10–21 秒，纯等待能堆到一分钟以上。
///
/// 现在三个门户服务共用同一份缓存：
/// - 键 = 账号 identifier；新鲜度判据与 TTL 只有一份
///   （`ApplePortalSigningService.isPortalReadCacheFresh`，5 分钟），不另抄。
/// - 只缓存**读**到的团队列表。团队成员在一轮操作内不变，与原有 5 分钟 TTL
///   假设同级；**会话是否有效仍由 `ensureCurrentSession` 的 bypass 实时请求
///   把关**，缓存只省「刚验证完又重拉同一份列表」，不会把假阳性带进写路径。
/// - 证书 / 库存服务复用它只是为了少发一次为拿 Team 标识而发的 `listTeams`；
///   撤销决策要读的**最新证书清单**不在这里缓存，仍逐次真拉。
actor PortalTeamCache {
    private var entries: [String: (teams: [ALTTeam], fetchedAt: Date)] = [:]

    func cachedTeams(accountIdentifier: String, now: Date = Date()) -> [ALTTeam]? {
        guard let entry = entries[accountIdentifier],
              ApplePortalSigningService.isPortalReadCacheFresh(
                  fetchedAt: entry.fetchedAt,
                  now: now
              ) else {
            return nil
        }
        return entry.teams
    }

    func store(
        _ teams: [ALTTeam],
        accountIdentifier: String,
        fetchedAt: Date = Date()
    ) {
        entries[accountIdentifier] = (teams, fetchedAt)
    }

    func invalidate(accountIdentifier: String) {
        entries.removeValue(forKey: accountIdentifier)
    }
}
