import Foundation
import Testing
import AltSign
@testable import Seal

/// 批量门户读缓存（2026-10-03）：`fetchTeams` / `ensureDevice` / `fetchAppIDs`
/// 一轮批量里只拉一次。`isPortalReadCacheFresh` 是三处调用点的同源判据。
struct PortalReadCacheTests {
    private let ttl: TimeInterval = 300

    @Test
    func freshWithinTTL() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl - 1),
                ttl: ttl
            )
        )
    }

    @Test
    func staleAtTTLBoundary() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        // 恰好 TTL ⇒ 不新鲜（`< ttl`，不是 `<=`）。
        #expect(
            !ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl),
                ttl: ttl
            )
        )
    }

    @Test
    func staleBeyondTTL() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            !ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl + 60),
                ttl: ttl
            )
        )
    }

    @Test
    func defaultTTLIsFiveMinutes() {
        // 守卫意图：一轮批量通常 1–2 分钟，5 分钟覆盖它绰绰有余；
        // 改 TTL 时必须同步评估「跨轮复用旧列表」的风险。
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(5 * 60 - 1)
            )
        )
        #expect(
            !ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(5 * 60 + 1)
            )
        )
    }

    /// 跨服务共享缓存（2026-10-22）：存进去的团队列表在 TTL 内按账号取回，
    /// 过期 / 别的账号都取不到 —— 签名、证书、库存三个服务靠这一份省 `listTeams`。
    @Test
    func sharedTeamCacheServesStoredTeamsUntilTTL() async {
        let cache = PortalTeamCache()
        let account = ALTAccount()
        account.identifier = "account-1"
        let team = ALTTeam(
            name: "Team",
            identifier: "TEAM123456",
            type: .free,
            account: account
        )
        let storedAt = Date(timeIntervalSince1970: 2_000_000_000)
        await cache.store([team], accountIdentifier: "account-1", fetchedAt: storedAt)

        let fresh = await cache.cachedTeams(
            accountIdentifier: "account-1",
            now: storedAt.addingTimeInterval(60)
        )
        #expect(fresh?.value.first?.identifier == "TEAM123456")

        let stale = await cache.cachedTeams(
            accountIdentifier: "account-1",
            now: storedAt.addingTimeInterval(ttl + 1)
        )
        #expect(stale == nil)

        let otherAccount = await cache.cachedTeams(
            accountIdentifier: "account-2",
            now: storedAt.addingTimeInterval(60)
        )
        #expect(otherAccount == nil)

        await cache.invalidate(accountIdentifier: "account-1")
        let invalidated = await cache.cachedTeams(
            accountIdentifier: "account-1",
            now: storedAt.addingTimeInterval(60)
        )
        #expect(invalidated == nil)
    }

    @Test
    func sessionValidationBypassesFreshTeamsCache() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            !ApplePortalSigningService.shouldUseCachedTeams(
                bypassCache: true,
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(1)
            )
        )
        #expect(
            ApplePortalSigningService.shouldUseCachedTeams(
                bypassCache: false,
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(1)
            )
        )
    }
}
