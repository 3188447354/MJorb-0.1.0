import Foundation
import Testing
@testable import Seal

/// 抽屉呈现仲裁的状态机序列。
///
/// 这条判据的错法同样是「不崩、不编译失败，只在真机上抢层/闪一帧/死锁」：
/// 旧实现靠硬等 250ms + `onChange` 强清 + 绑定门禁拼凑交接，边缘时序
/// （已安装操作抽屉点续签、批量结果撞正开着的操作抽屉、结果呈现期间再来
/// 新操作）全靠运气。所以交接规则收成纯状态机后，逐条序列钉死在这里。
///
/// ⚠️ 写法纪律：`#expect` 的表达式会被 Testing 宏改写进闭包，mutating 调用
/// 不能直接写在里面（守卫的改写闭包规则会拦）—— 所有 mutating 调用先把
/// 结果赋给局部量，再对值断言。时序断言只靠状态推进，不用 sleep 赌帧。
@Suite("抽屉呈现仲裁：同一时刻只许一张在场，交接串行关完再开")
struct SheetArbitrationTests {

    /// 已安装操作抽屉 → 续签（操作）抽屉：必须等操作抽屉关闭完成，
    /// 续签抽屉才被允许呈现 —— 中间任何时刻都不许两张同时可呈现，
    /// 也不需要任何延时等待。
    @Test
    func installedActionToRenewalHandoffIsSerial() {
        var arbiter = SheetArbiter()
        let claimAction = arbiter.request(.installedAction)
        #expect(claimAction == .present(.installedAction))
        #expect(arbiter.allowsPresentation(of: .installedAction))

        let handoffAction = arbiter.request(.operation)
        #expect(handoffAction == .dismissCurrentThenPresentPending)
        // 关闭完成事件到达之前：台上仍是旧抽屉，新抽屉绝不许呈现。
        let operationAllowedBeforeDismissal = arbiter.allowsPresentation(of: .operation)
        #expect(arbiter.allowsPresentation(of: .installedAction))
        #expect(operationAllowedBeforeDismissal == false)
        #expect(arbiter.pending == .operation)

        let promotionAction = arbiter.sheetDidDismiss(.installedAction)
        #expect(promotionAction == .present(.operation))
        #expect(arbiter.allowsPresentation(of: .operation))
        let installedActionAllowedAfterPromotion = arbiter.allowsPresentation(of: .installedAction)
        #expect(installedActionAllowedAfterPromotion == false)
        #expect(arbiter.pending == nil)
    }

    /// 批量结果撞上正开着的操作抽屉：结果登记为待呈现，操作抽屉关完才上台。
    @Test
    func batchResultWaitsForOpenOperationSheetToDismiss() {
        var arbiter = SheetArbiter()
        let claimAction = arbiter.request(.operation)
        #expect(claimAction == .present(.operation))

        let collisionAction = arbiter.request(.batchResult)
        #expect(collisionAction == .dismissCurrentThenPresentPending)
        let batchAllowedBeforeDismissal = arbiter.allowsPresentation(of: .batchResult)
        #expect(batchAllowedBeforeDismissal == false)
        #expect(arbiter.current == .operation)

        let promotionAction = arbiter.sheetDidDismiss(.operation)
        #expect(promotionAction == .present(.batchResult))
        #expect(arbiter.allowsPresentation(of: .batchResult))
        #expect(arbiter.isIdle == false)
    }

    /// 结果呈现期间再触发新操作：新操作只能排队，结果抽屉关完才上台 ——
    /// 新操作无权在结果还挂着时抢层，更无权替用户把结果关掉。
    @Test
    func newOperationQueuesBehindPresentedBatchResult() {
        var arbiter = SheetArbiter()
        let claimAction = arbiter.request(.batchResult)
        #expect(claimAction == .present(.batchResult))

        let queueAction = arbiter.request(.operation)
        #expect(queueAction == .dismissCurrentThenPresentPending)
        #expect(arbiter.allowsPresentation(of: .batchResult))
        let operationAllowedWhileBatchPresented = arbiter.allowsPresentation(of: .operation)
        #expect(operationAllowedWhileBatchPresented == false)

        let promotionAction = arbiter.sheetDidDismiss(.batchResult)
        #expect(promotionAction == .present(.operation))
        #expect(arbiter.allowsPresentation(of: .operation))
    }

    /// 重复请求同一张抽屉是无操作：不产生第二次呈现、不改变台上状态。
    @Test
    func duplicateRequestIsIdempotent() {
        var arbiter = SheetArbiter()
        let firstAction = arbiter.request(.operation)
        #expect(firstAction == .present(.operation))
        let duplicateAction = arbiter.request(.operation)
        #expect(duplicateAction == .none)
        #expect(arbiter.current == .operation)
        #expect(arbiter.pending == nil)
    }

    /// 过时抽屉的迟到关闭事件必须被忽略：它不能清掉后来上台的抽屉。
    @Test
    func staleDismissalDoesNotClearCurrentSheet() {
        var arbiter = SheetArbiter()
        let claimAction = arbiter.request(.batchResult)
        #expect(claimAction == .present(.batchResult))
        let staleAction = arbiter.sheetDidDismiss(.detail)
        #expect(staleAction == .none)
        #expect(arbiter.current == .batchResult)
        #expect(arbiter.allowsPresentation(of: .batchResult))
    }

    /// 排队期间又来新请求：以最新呈现意图为准。
    @Test
    func latestPendingRequestWins() {
        var arbiter = SheetArbiter()
        let claimAction = arbiter.request(.operation)
        #expect(claimAction == .present(.operation))
        let firstQueueAction = arbiter.request(.batchResult)
        #expect(firstQueueAction == .dismissCurrentThenPresentPending)
        let replacementAction = arbiter.request(.detail)
        #expect(replacementAction == .dismissCurrentThenPresentPending)
        #expect(arbiter.pending == .detail)
        let promotionAction = arbiter.sheetDidDismiss(.operation)
        #expect(promotionAction == .present(.detail))
    }

    /// 撤销待呈现请求后，当前抽屉关闭完不得再把已撤销的抽屉抬上台。
    /// `cancelPending` 本身也是 mutating：同样先执行、再断言其后果状态。
    @Test
    func cancelledPendingSheetNeverPresents() {
        var arbiter = SheetArbiter()
        let claimAction = arbiter.request(.installedAction)
        #expect(claimAction == .present(.installedAction))
        let queueAction = arbiter.request(.operation)
        #expect(queueAction == .dismissCurrentThenPresentPending)
        arbiter.cancelPending(.operation)
        let pendingAfterCancel = arbiter.pending
        #expect(pendingAfterCancel == nil)
        let dismissalAction = arbiter.sheetDidDismiss(.installedAction)
        #expect(dismissalAction == .none)
        #expect(arbiter.isIdle)
    }

    /// 正常关闭（无待呈现）后仲裁回到空台，下一张可以直接呈现。
    @Test
    func plainDismissalReturnsToIdle() {
        var arbiter = SheetArbiter()
        let claimAction = arbiter.request(.detail)
        #expect(claimAction == .present(.detail))
        let dismissalAction = arbiter.sheetDidDismiss(.detail)
        #expect(dismissalAction == .none)
        #expect(arbiter.isIdle)
        let nextClaimAction = arbiter.request(.operation)
        #expect(nextClaimAction == .present(.operation))
    }
}
