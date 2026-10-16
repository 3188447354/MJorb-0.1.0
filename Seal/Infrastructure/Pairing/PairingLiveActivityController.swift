import ActivityKit
import Foundation

/// 把配对码推到灵动岛 / 锁屏。
///
/// ## 生命周期（2026-10-16 按真机反馈重做）
///
/// 前一版是「配对一开始就建活动，配对成功后一直挂着」，真机表现是：
/// 配对完了灵动岛不消失、且活动远远早于配对码出现就存在了。现在改成**跟着配对码走**：
///
/// ```
/// .showingCode   → 创建 + 展开，显示配对码        ← 与 App 内配对码同一时刻
/// .completed     → 改成「配对成功，点此返回 Seal」，**保留**
/// 用户点回 Seal   → finish() 收掉
/// 超时兜底        → finish() 收掉
/// ```
///
/// ⚠️ **为什么 `begin` 放在 `.showingCode` 而不是配对开始**：
/// `Activity.request` 只有 App 在前台才成功，而 `.showingCode` 恰恰是用户正盯着
/// 配对页、准备去「设置」输码的那一刻 —— 既满足前台要求，又让灵动岛与 App 内的码
/// **同时出现**，不会先挂一个空的「正在准备」。
///
/// ⚠️ **为什么配对成功后不立刻 `end`**：那时用户还在「设置」里，需要看到结果并有一个
/// 明确的返回入口。Apple 也不允许「点了就跳转」—— 灵动岛点击只能启动 App，
/// 所以文案要说清「点此返回」。用户真的回来了（`RootTabView` 收到 `seal://pairing`）
/// 才 `end`。
///
/// ⚠️ **`AlertConfiguration` 是展开灵动岛的开关**：当前项目使用的 ActivityKit SDK
/// 只支持把它传给 `update`，不能传给 `ActivityContent` 的初始化器。创建时先显示
/// 配对码，配对成功时通过 `update` 展开并提示返回 Seal。
@MainActor
final class PairingLiveActivityController {

    private var activity: Activity<PairingActivityAttributes>?

    /// 配对流程结束后，如果用户始终没点回来，多久自动收掉。
    ///
    /// 必须有这个兜底：Live Activity 默认会在锁屏/灵动岛留 8 小时，
    /// 而一个「配对成功」的卡片挂 8 小时毫无意义，还会一直占着灵动岛。
    private static let autoDismissAfterSeconds: TimeInterval = 180
    private var autoDismissTask: Task<Void, Never>?

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// 配对码即将显示时调用。**必须在前台**（用户正看着配对页）。
    func begin(deviceName: String, code: String) {
        guard isEnabled else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil

        // 同一时刻只留一枚活动，避免灵动岛里叠两个码。
        if let stale = Activity<PairingActivityAttributes>.activities.first {
            activity = stale
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil

        let attributes = PairingActivityAttributes(deviceName: deviceName)

        let content = ActivityContent(state: Self.codeState(code), staleDate: nil)
        activity = Activity.request(
            attributes: attributes,
            content: content,
            pushType: nil
        )
        scheduleAutoDismiss()
    }

    /// 配对成功。**不结束活动** —— 用户还在「设置」里，需要一个返回入口。
    func markPaired() {
        guard let activity else { return }
        let state = PairingActivityAttributes.ContentState(
            stage: .paired,
            code: "",
            title: "配对成功",
            detail: "点此返回 Seal"
        )
        Task {
            await activity.update(
                .init(state: state, staleDate: nil),
                alertConfiguration: AlertConfiguration(
                    title: LocalizedStringResource(stringLiteral: "配对成功"),
                    body: LocalizedStringResource(stringLiteral: "点此返回 Seal"),
                    sound: .default
                )
            )
        }
    }

    /// 收掉活动。三处会调用：用户点回 Seal、配对失败、超时兜底。
    func finish() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// 配对流程中途失败/取消时也要收掉，否则灵动岛上会留一个过期的码。
    func abandon() {
        finish()
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissAfterSeconds * 1_000_000_000))
            guard Task.isCancelled == false else { return }
            await MainActor.run { self?.finish() }
        }
    }

    private static func codeState(_ code: String) -> PairingActivityAttributes.ContentState {
        PairingActivityAttributes.ContentState(
            stage: .code,
            code: code,
            title: "配对码",
            detail: "在「设置」中核对并确认"
        )
    }

}
