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
    private static let resultLifetime: TimeInterval = 180
    private static let failureLifetime: TimeInterval = 30

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
        guard code.range(of: #"^\\d{6}$"#, options: .regularExpression) != nil,
              let activity else {
            return false
        }
        let expiry = Date().addingTimeInterval(Self.resultLifetime)
        scheduleDismiss(at: expiry)
        Task {
            await activity.update(.init(state: Self.codeState(code), staleDate: expiry))
        }
        return true
    }

    /// 只能在配对凭证已经成功保存后调用。完成态保留返回 Seal 的入口，用户点回 App 后关闭。
    func markPaired() {
        updateResult(
            state: .init(stage: .paired, code: "", title: "配对完成", detail: "点按返回 Seal"),
            lifetime: Self.resultLifetime,
            alertTitle: "配对完成",
            alertBody: "点按返回 Seal"
        )
    }

    /// 失败态不保留旧配对码，短暂显示返回入口后自动清理。
    func markFailed() {
        updateResult(
            state: .init(stage: .failed, code: "", title: "配对未完成", detail: "返回 Seal 查看原因"),
            lifetime: Self.failureLifetime,
            alertTitle: "配对未完成",
            alertBody: "返回 Seal 查看原因"
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

    private func updateResult(
        state: PairingActivityAttributes.ContentState,
        lifetime: TimeInterval,
        alertTitle: String,
        alertBody: String
    ) {
        guard let activity else { return }
        let expiry = Date().addingTimeInterval(lifetime)
        scheduleDismiss(at: expiry)
        Task {
            await activity.update(
                .init(state: state, staleDate: expiry),
                alertConfiguration: AlertConfiguration(
                    title: LocalizedStringResource(stringLiteral: alertTitle),
                    body: LocalizedStringResource(stringLiteral: alertBody),
                    sound: .default
                )
            )
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
