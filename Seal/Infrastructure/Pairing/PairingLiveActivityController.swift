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
/// ⚠️ **`AlertConfiguration` 是展开灵动岛的开关**：只在 `update` 时带它，创建时不带，
/// 灵动岛就不会主动展开。这里创建（`.showingCode`）与「配对成功」两次都带。
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

        // ⚠️ **`AlertConfiguration` 挂在 `ActivityContent` 上，不挂在 `request` 的参数上**
        // （2026-10-16 编译报错后改）：
        // Xcode 26 的 `Activity.request(attributes:content:pushType:style:alertConfiguration:start:)`
        // 里 `style` / `start` 是**必填**且没有带默认值的旧重载 —— 只传前三个参数会报
        //   error: missing arguments for parameters 'style', 'start' in call
        // 而那个不带 style/start 的重载**不抛任何错误**（编译器会连带报
        // `'catch' block is unreachable`）。AlertConfiguration 的正式归宿是
        // `ActivityContent(state:staleDate:alertConfiguration:)`，走它就不必猜
        // `style` / `start` 的类型。
        let content = ActivityContent(
            state: Self.codeState(code),
            staleDate: nil,
            alertConfiguration: Self.codeAlert(code)
        )
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

    private static func codeAlert(_ code: String) -> AlertConfiguration {
        AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: "配对码 \(code)"),
            body: LocalizedStringResource(stringLiteral: "在「设置」中核对并确认"),
            sound: .default
        )
    }
}
