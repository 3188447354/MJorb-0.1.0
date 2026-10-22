import Foundation
import Testing
@testable import Seal

/// 冷启动呈现解耦的判据矩阵（log-47 回归）。
///
/// 2026-10-22 真机：快捷指令后台续签完成后，持久化（SEAL-RENEW-023）与
/// 「从持久化载荷恢复」（SEAL-RENEW-024）在**后台进程内同一秒**发生 ——
/// 结果被没有呈现层的进程消费；用户点通知冷启动进前台后抽屉不弹
/// （无 025），已安装列表又被「待呈现结果优先」的逻辑吞掉点按，点不动。
///
/// 钉死的新规则：非呈现调用（后台进程的 load、启动恢复、轮询复查）只能
/// 登记待呈现；只有呈现层在宿主就绪且 App active 时授权的那一次，
/// 才允许恢复并呈现；已呈现会话的载荷更新是原地更新、不是新呈现。
@Suite("批量结果恢复路线：后台只登记、前台授权才呈现")
struct BatchResultPresentationDecouplingTests {

    private func route(
        hasPayload: Bool = true,
        presentationAuthorized: Bool = false,
        hasPresentedSession: Bool = false,
        payloadFingerprintChanged: Bool = false,
        hasActiveBatchTask: Bool = false,
        hasLiveUnrestoredSession: Bool = false
    ) -> BatchResultRestoreRoute {
        BatchResultRestorePolicy.route(
            hasPayload: hasPayload,
            presentationAuthorized: presentationAuthorized,
            hasPresentedSession: hasPresentedSession,
            payloadFingerprintChanged: payloadFingerprintChanged,
            hasActiveBatchTask: hasActiveBatchTask,
            hasLiveUnrestoredSession: hasLiveUnrestoredSession
        )
    }

    /// log-47 本体：后台进程里的普通恢复调用（无呈现授权）只能登记，
    /// 绝不能恢复进会话并置呈现标志 —— 否则结果在后台被消费、前台再无抽屉。
    @Test
    func backgroundRestoreOnlyRegistersAwaitingPresentation() {
        #expect(route() == .registerAwaitingPresentation)
    }

    /// 呈现层（宿主就绪 + App active）显式授权时才允许真正恢复呈现。
    @Test
    func authorizedForegroundRestorePresents() {
        #expect(route(presentationAuthorized: true) == .restoreForPresentation)
    }

    /// 没有载荷时任何路线都不成立。
    @Test
    func noPayloadIsIgnored() {
        #expect(route(hasPayload: false) == .ignore)
        #expect(route(hasPayload: false, presentationAuthorized: true) == .ignore)
    }

    /// 有批量任务在跑时不恢复：半成品结果不能被当成终态呈现，
    /// 呈现授权也不能越过这条（对应旧 SEAL-RENEW-021 的跳过情形）。
    @Test
    func activeBatchTaskBlocksEveryRoute() {
        #expect(route(hasActiveBatchTask: true) == .ignore)
        #expect(route(presentationAuthorized: true, hasActiveBatchTask: true) == .ignore)
    }

    /// 已有现场（未从载荷恢复的）会话时不抢它的台，也不登记一份幽灵待呈现。
    @Test
    func liveUnrestoredSessionBlocksRestoreAndRegistration() {
        #expect(route(hasLiveUnrestoredSession: true) == .ignore)
        #expect(route(presentationAuthorized: true, hasLiveUnrestoredSession: true) == .ignore)
    }

    /// 已在本进程呈现过的会话，载荷被 Seal 结算改写后只原地更新内容 ——
    /// 这不是一次新呈现，不需要呈现授权，也不能重新登记成待呈现。
    @Test
    func presentedSessionUpdatesInPlaceWhenPayloadChanges() {
        #expect(
            route(hasPresentedSession: true, payloadFingerprintChanged: true)
                == .updatePresentedSession
        )
        #expect(
            route(
                presentationAuthorized: true,
                hasPresentedSession: true,
                payloadFingerprintChanged: true
            ) == .updatePresentedSession
        )
    }

    /// 已呈现会话且载荷没变：轮询恢复是无操作，不能重复呈现或重复登记。
    @Test
    func presentedSessionWithUnchangedPayloadIsIgnored() {
        #expect(route(hasPresentedSession: true) == .ignore)
        #expect(route(presentationAuthorized: true, hasPresentedSession: true) == .ignore)
    }
}
