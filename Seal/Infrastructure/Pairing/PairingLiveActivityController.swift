import ActivityKit
import Foundation

/// 控制手机配对的 Live Activity 生命周期。
///
/// 活动只在用户主动开始配对时预创建，保证随后切去系统设置前已经取得系统允许的
/// 前台创建窗口；预创建态没有假配对码，也会在短超时、失败、取消或用户回到 Seal 时清理。
/// 真正六码到达后才显示号码；只有凭证已成功导入本地后才显示完成。
@MainActor
final class PairingLiveActivityController {

    private var activity: Activity<PairingActivityAttributes>?
    private var expiresAt: Date?
    private var dismissTask: Task<Void, Never>?

    private static let preparationLifetime: TimeInterval = 60
    private static let codeLifetime: TimeInterval = 180
    private static let completionLifetime: TimeInterval = 6
    private static let failureLifetime: TimeInterval = 12

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// 在用户按下「开始配对」的前台时调用。返回 false 时由调用方走通知回退。
    @discardableResult
    func prepare(deviceName: String) -> Bool {
        guard isEnabled else { return false }
        finish()

        let expiry = Date().addingTimeInterval(Self.preparationLifetime)
        let attributes = PairingActivityAttributes(deviceName: deviceName)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: Self.preparingState, staleDate: expiry),
                pushType: nil
            )
            scheduleDismiss(at: expiry)
            return true
        } catch {
            activity = nil
            return false
        }
    }

    /// 只在收到系统给出的真实六码后调用。若活动已不可用，调用方应切换到通知回退。
    @discardableResult
    func showCode(_ code: String) -> Bool {
        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil,
              let activity else {
            return false
        }
        let expiry = Date().addingTimeInterval(Self.codeLifetime)
        scheduleDismiss(at: expiry)
        Task {
            await activity.update(.init(state: Self.codeState(code), staleDate: expiry))
        }
        return true
    }

    /// 只有凭证已经成功保存后调用。结束请求交给系统在短暂完成态后执行，
    /// 不依赖 Seal 继续在前台或后台运行。
    func markPaired() {
        endWithResult(
            state: .init(stage: .paired, code: "", title: "配对完成", detail: "已连接到 Seal"),
            lifetime: Self.completionLifetime
        )
    }

    /// 失败态不保留旧配对码；同样由系统在短暂提示后结束活动。
    func markFailed() {
        endWithResult(
            state: .init(stage: .failed, code: "", title: "配对未完成", detail: "返回 Seal 查看原因"),
            lifetime: Self.failureLifetime
        )
    }

    /// 用户点回 Seal、取消流程，或到了兜底时间时关闭活动。
    func finish() {
        dismissTask?.cancel()
        dismissTask = nil
        expiresAt = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    func abandon() { finish() }

    /// App 回到前台时只回收已过期活动，不中断仍在进行的配对。
    func discardExpiredActivityIfNeeded() {
        if let expiresAt, expiresAt <= Date() {
            finish()
        }
    }

    /// 把结束时刻提交给 ActivityKit。过去只用本地 `Task.sleep`，Seal 被挂起或杀掉时
    /// 任务不会执行，导致完成卡片长期残留。
    private func endWithResult(
        state: PairingActivityAttributes.ContentState,
        lifetime: TimeInterval
    ) {
        dismissTask?.cancel()
        dismissTask = nil
        expiresAt = nil
        guard let activity else { return }
        self.activity = nil
        let dismissalDate = Date().addingTimeInterval(lifetime)
        let content = ActivityContent(state: state, staleDate: dismissalDate)
        Task {
            await activity.end(content, dismissalPolicy: .after(dismissalDate))
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
        detail: "正在准备配对"
    )

    private static func codeState(_ code: String) -> PairingActivityAttributes.ContentState {
        .init(stage: .code, code: code, title: "Seal 配对码", detail: "在系统设置中核对并确认")
    }
}
