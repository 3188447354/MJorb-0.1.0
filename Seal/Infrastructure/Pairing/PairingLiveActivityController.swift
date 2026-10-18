import ActivityKit
import Foundation

/// 控制手机配对的 Live Activity 生命周期。
///
/// 活动只在用户主动开始配对时预创建，保证随后切去系统设置前已经取得系统允许的
/// 前台创建窗口；预创建态没有假配对码，配对中点击返回会保留真实配对码。
/// 真正六码到达后才显示号码；只有凭证已成功导入本地后才显示完成。
@MainActor
final class PairingLiveActivityController {

    private var activity: Activity<PairingActivityAttributes>?
    private var activityOperation: Task<Void, Never>?
    private var stage: PairingActivityAttributes.Stage?
    private var expiresAt: Date?
    private var dismissTask: Task<Void, Never>?

    private static let preparationLifetime: TimeInterval = 60
    private static let codeLifetime: TimeInterval = 180
    private static let completionLifetime: TimeInterval = 6
    private static let failureLifetime: TimeInterval = 12

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// 新进程无法恢复已结束的原生配对监听，因此旧活动不能继续显示为可配对。
    /// 启动时收回本应用遗留的活动，避免重复岛和过期配对码。
    nonisolated func endOrphanedActivities() async {
        let orphaned = Activity<PairingActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
        for activity in orphaned {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 在用户按下「开始配对」的前台时调用。返回 false 时由调用方走通知回退。
    @discardableResult
    func prepare(deviceName: String) -> Bool {
        finish()
        guard isEnabled else { return false }

        let expiry = Date().addingTimeInterval(Self.preparationLifetime)
        let attributes = PairingActivityAttributes(deviceName: deviceName)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: Self.preparingState, staleDate: expiry),
                pushType: nil
            )
            stage = .preparing
            scheduleDismiss(at: expiry)
            return true
        } catch {
            activity = nil
            stage = nil
            return false
        }
    }

    /// 只在收到系统给出的真实六码后调用。若活动已不可用，调用方应切换到通知回退。
    @discardableResult
    func showCode(_ code: String) async -> Bool {
        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil,
              let activity,
              stage == .preparing || stage == .code else {
            return false
        }
        guard activity.activityState == .active || activity.activityState == .stale else {
            finish()
            return false
        }
        let activityID = activity.id
        stage = .code
        let expiry = Date().addingTimeInterval(Self.codeLifetime)
        scheduleDismiss(at: expiry)
        // ActivityKit's current SDK marks update as concurrent; this handle is only passed
        // to that API here and remains otherwise isolated to this controller.
        nonisolated(unsafe) let activityForUpdate = activity
        let previousOperation = activityOperation
        let updateOperation = Task {
            await previousOperation?.value
            await activityForUpdate.update(.init(state: Self.codeState(code), staleDate: expiry))
        }
        activityOperation = updateOperation
        await updateOperation.value
        guard self.activity?.id == activityID, stage == .code else { return false }
        guard activity.activityState == .active || activity.activityState == .stale else {
            finish()
            return false
        }
        return true
    }

    /// 只有凭证已经成功保存后调用。先更新完成态，短暂展示后再结束活动。
    func markPaired() {
        endWithResult(
            stage: .paired,
            state: .init(stage: .paired, code: "", title: "Seal", detail: "点击返回 Seal"),
            lifetime: Self.completionLifetime
        )
    }

    /// 失败态不保留旧配对码；短暂显示失败提示后结束活动。
    func markFailed() {
        endWithResult(
            stage: .failed,
            state: .init(stage: .failed, code: "", title: "Seal", detail: "返回 Seal 查看原因"),
            lifetime: Self.failureLifetime
        )
    }

    /// 新一轮配对开始或活动到期时立即关闭旧活动。
    func finish() {
        dismissTask?.cancel()
        dismissTask = nil
        expiresAt = nil
        stage = nil
        guard let activity else { return }
        self.activity = nil
        let previousOperation = activityOperation
        activityOperation = Task {
            await previousOperation?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func abandon() { finish() }

    /// 点活动返回 Seal 时保留仍在进行的配对码；成功或失败态才立即收起。
    func dismissIfTerminal() {
        guard stage?.isTerminal == true else { return }
        finish()
    }

    /// App 回到前台时只回收已过期活动，不中断仍在进行的配对。
    func discardExpiredActivityIfNeeded() {
        if let expiresAt, expiresAt <= Date() {
            finish()
        }
    }

    /// 把结束时刻提交给 ActivityKit。过去只用本地 `Task.sleep`，Seal 被挂起或杀掉时
    /// 任务不会执行，导致完成卡片长期残留。
    private func endWithResult(
        stage: PairingActivityAttributes.Stage,
        state: PairingActivityAttributes.ContentState,
        lifetime: TimeInterval
    ) {
        guard let activity else { return }
        self.stage = stage
        let dismissalDate = Date().addingTimeInterval(lifetime)
        dismissTask?.cancel()
        expiresAt = dismissalDate
        let content = ActivityContent(state: state, staleDate: dismissalDate)
        let previousOperation = activityOperation
        let activityID = activity.id
        nonisolated(unsafe) let activityForUpdate = activity
        activityOperation = Task {
            await previousOperation?.value
            await activityForUpdate.update(content)
        }
        dismissTask = Task { [weak self] in
            let delay = max(0, dismissalDate.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                guard self?.activity?.id == activityID,
                      self?.stage == stage else { return }
                self?.finish()
            }
        }
    }

    private func scheduleDismiss(at expiry: Date) {
        dismissTask?.cancel()
        expiresAt = expiry
        dismissTask = Task { [weak self] in
            let delay = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard Task.isCancelled == false else { return }
            await MainActor.run { self?.discardExpiredActivityIfNeeded() }
        }
    }

    private static let preparingState = PairingActivityAttributes.ContentState(
        stage: .preparing,
        code: "",
        title: "Seal",
        detail: "隐私与安全-开发者模式-与 Seal 配对"
    )

    private static func codeState(_ code: String) -> PairingActivityAttributes.ContentState {
        .init(stage: .code, code: code, title: "Seal", detail: "在系统配对窗口输入此码")
    }
}
