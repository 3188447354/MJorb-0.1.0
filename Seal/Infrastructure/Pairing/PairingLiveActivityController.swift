import ActivityKit
import Foundation

/// 把配对码推到灵动岛 / 锁屏。
///
/// 三条来自 Apple 的硬约束，写在这里免得以后被"优化"掉：
///
/// 1. **`Activity.request` 必须在前台调用**。系统不给后台启动 Live Activity 的机会，
///    所以本类型要在「配对服务刚起来、App 还在前台」的那一刻就 `begin`，
///    而不是等系统给出配对码时才首次请求。
/// 2. **`AlertConfiguration` 才是"打开灵动岛"的开关**。只 `request` 不带它，
///    活动会安静地待在锁屏，灵动岛不展开 —— 而"输码时能一直看见"正是这个功能的全部意义。
/// 3. **后台 `update` 依赖 App 仍活着**。Seal 的后台保活音频（`BackgroundKeepAliveService`）
///    让进程在切到「设置」后继续运行，更新才发得出去；保活一旦停，码就不会再变。
@MainActor
final class PairingLiveActivityController {

    /// 只有一枚活动；重复 `begin` 会先收掉旧的，避免灵动岛上叠两个码。
    private var activity: Activity<PairingActivityAttributes>?

    /// Live Activity 是否可用（用户可能把 App 的实时活动总开关关了）。
    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// 服务起来时调用。**必须在前台**，见类型注释第 1 条。
    func begin(deviceName: String) {
        guard isEnabled else { return }
        // 已经有一枚就先结束，保证同一时刻只有一个码。
        if let existing = activity {
            Task { await existing.end(nil, dismissalPolicy: .immediate) }
            activity = existing
        } else {
            activity = Activity<PairingActivityAttributes>.activities.first
        }
        guard activity == nil else { return }

        let attributes = PairingActivityAttributes(deviceName: deviceName)
        let state = PairingActivityAttributes.ContentState(
            stage: .waiting,
            code: "",
            title: "正在准备配对",
            detail: "请在 Seal 中保持此页面打开"
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // 失败不是致命问题：App 内仍然显示配对码，只是没有灵动岛镜像。
            activity = nil
        }
    }

    /// 系统给出配对码时调用。
    func presentCode(_ code: String) {
        update(
            stage: .code,
            code: code,
            title: "配对码",
            detail: "在系统设置中核对此配对码",
            alertTitle: "配对码 \(code)",
            alertBody: "在系统设置中核对后确认"
        )
    }

    /// 配对成功时调用。
    func markPaired() {
        update(
            stage: .paired,
            code: "",
            title: "已配对",
            detail: "可以返回 Seal 继续",
            alertTitle: "已配对",
            alertBody: "可以返回 Seal 继续"
        )
    }

    /// 配对流程结束（无论成败）时调用，把灵动岛收掉。
    func finish() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func update(
        stage: PairingActivityAttributes.Stage,
        code: String,
        title: String,
        detail: String,
        alertTitle: String,
        alertBody: String
    ) {
        guard let activity else { return }
        let state = PairingActivityAttributes.ContentState(
            stage: stage,
            code: code,
            title: title,
            detail: detail
        )
        // 用 `.sound` 之外的缺省选项：配对是用户正盯着的操作，不需要额外提示音。
        let alert = AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: alertTitle),
            body: LocalizedStringResource(stringLiteral: alertBody),
            sound: .default
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil), alertConfiguration: alert)
        }
    }
}
