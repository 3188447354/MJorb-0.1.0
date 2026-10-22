import Foundation
import Testing
@testable import Seal

/// `SEAL-SIGN-404`「未找到要签名的应用记录」的入口就绪门判据自证。
///
/// **为什么值得单测**：2026-10-22 真机（Seal-log-46，build 143）更新抽屉连点
/// 3 次、每次 0 秒以 404 失败 —— `signAndInstall` 入口只查一次记录，查不到即
/// 终态抛错，而外层两条重试（单签的通道重试、批量的 `isRetryable`）都不认 404。
/// 就绪门的判据若漂移（比如预算被改成长等待），错法只会在真机上表现为
/// 「续签莫名变慢」或「404 又变回 0 秒连败」，单测是唯一便宜的防线。
///
/// **为什么只测纯判据**：真正的等待/复查落在 `SigningCoordinator`（actor +
/// `AppStore`）里，测试 target 构造不出那条链路；与本仓既有做法一致
///（`DeviceChannelTransientPolicy` 等），把「查几次、等多久、何时停」抽成
/// 纯函数测透，actor 侧只剩机械执行。
@Suite("SEAL-SIGN-404 记录就绪门：复查判据与预算")
struct Sign404RecordReadinessPolicyTests {

    @Test("第一次就查到时不复查：常态路径零新增等待")
    func firstHitNeverRechecks() {
        // shouldRecheck 只回答「查不到之后还要不要再来」；第一次命中根本不进复查分支。
        // 这里钉住的是预算形状：第一次未命中后仍有复查机会（attempt 1 < maxAttempts）。
        #expect(SignRecordReadinessPolicy.shouldRecheck(afterAttempt: 1))
    }

    @Test("复查在预算内进行、到上限即停")
    func recheckStopsAtBudget() {
        let maxAttempts = SignRecordReadinessPolicy.maxAttempts
        for attempt in 1..<maxAttempts {
            #expect(SignRecordReadinessPolicy.shouldRecheck(afterAttempt: attempt))
        }
        #expect(SignRecordReadinessPolicy.shouldRecheck(afterAttempt: maxAttempts) == false)
        #expect(SignRecordReadinessPolicy.shouldRecheck(afterAttempt: maxAttempts + 1) == false)
    }

    @Test("非法 attempt（0 / 负数）不触发复查")
    func invalidAttemptNeverRechecks() {
        #expect(SignRecordReadinessPolicy.shouldRecheck(afterAttempt: 0) == false)
        #expect(SignRecordReadinessPolicy.shouldRecheck(afterAttempt: -1) == false)
    }

    @Test("退避递增且封顶：250ms / 500ms / 1000ms，超表按最后一档")
    func delaysIncreaseAndClamp() {
        #expect(SignRecordReadinessPolicy.delayNanoseconds(afterAttempt: 1) == 250_000_000)
        #expect(SignRecordReadinessPolicy.delayNanoseconds(afterAttempt: 2) == 500_000_000)
        #expect(SignRecordReadinessPolicy.delayNanoseconds(afterAttempt: 3) == 1_000_000_000)
        #expect(SignRecordReadinessPolicy.delayNanoseconds(afterAttempt: 99) == 1_000_000_000)
        #expect(SignRecordReadinessPolicy.delayNanoseconds(afterAttempt: 0) == 250_000_000)
    }

    @Test("最坏总等待 1.75 秒：内层预算必须短于外层重试退避（8 秒起）")
    func worstCaseBudgetStaysShort() {
        // AGENTS.md 预算纪律：有外层重试时内层预算必须短。
        // 单签外层通道退避基数是 8 秒；就绪门最坏总等待必须明显小于它，
        // 且只能落在「本来就会失败」的查不到路径上。
        #expect(SignRecordReadinessPolicy.worstCaseTotalDelayNanoseconds == 1_750_000_000)
        #expect(
            SignRecordReadinessPolicy.worstCaseTotalDelayNanoseconds
                < DeviceChannelTransientPolicy.channelRetryDelayNanoseconds
        )
    }

    @Test("尝试上限保持小量级：入口复查不是轮询")
    func attemptBudgetStaysSmall() {
        // 4 次 = 首次 + 3 次复查。若有人把这里改成几十次，
        // 404 路径会从「快速失败」变成「长时间假死」，先在这里红。
        #expect(SignRecordReadinessPolicy.maxAttempts == 4)
        #expect(
            SignRecordReadinessPolicy.recheckDelaysNanoseconds.count
                == SignRecordReadinessPolicy.maxAttempts - 1
        )
    }
}
