import ActivityKit
import Foundation

/// 控制手机配对的 Live Activity 生命周期。
///
/// 活动只在用户主动开始配对时预创建，保证随后切去系统设置前已经取得系统允许的
/// 前台创建窗口；预创建态没有假配对码，配对中点击返回会保留真实配对码。
/// 真正六码到达后才显示号码；只有凭证已成功导入本地后才显示完成。
@MainActor
final class PairingLiveActivityController {

    private let logStore: SealLogStore?
    private var activity: Activity<PairingActivityAttributes>?
    private var activityOperation: Task<Void, Never>?
    private var orphanCleanupTask: Task<Void, Never>?
    private var stage: PairingActivityAttributes.Stage?
    private var expiresAt: Date?
    private var dismissTask: Task<Void, Never>?

    static let preparationLifetime: TimeInterval = PhonePairingHost.timeoutSeconds + 30
    // 配对码阶段没有本地寿命：活动活到配对出结果为止（见 showCode），不设 codeLifetime。
    private static let completionLifetime: TimeInterval = 30
    private static let failureLifetime: TimeInterval = 12

    init(logStore: SealLogStore? = nil) {
        self.logStore = logStore
    }

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

    /// 启动时清理与用户开始配对前的清理共用同一个任务，避免旧清理晚于新活动创建，
    /// 把刚创建的配对活动误判为上次遗留活动结束。
    func scheduleOrphanCleanup() {
        guard orphanCleanupTask == nil else { return }
        orphanCleanupTask = Task { await endOrphanedActivities() }
    }

    /// 在用户按下「开始配对」的前台时调用。返回 false 时由调用方走通知回退。
    @discardableResult
    func prepare(deviceName: String) async -> Bool {
        finish()
        await activityOperation?.value
        if let orphanCleanupTask {
            await orphanCleanupTask.value
            self.orphanCleanupTask = nil
        } else {
            await endOrphanedActivities()
        }
        let extensionURL = Bundle.main.bundleURL.appending(
            path: "PlugIns/SealLiveActivity.appex",
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            await logUnavailable("当前 Seal 安装包缺少配对实时活动扩展，配对码将改用系统通知显示。")
            return false
        }
        guard isEnabled else {
            await logUnavailable("系统未允许实时活动，配对码将改用系统通知显示。")
            return false
        }

        let expiry = Date().addingTimeInterval(Self.preparationLifetime)
        do {
            activity = try Activity.request(
                attributes: PairingActivityAttributes(deviceName: deviceName),
                content: .init(state: Self.preparingState, staleDate: expiry),
                pushType: nil
            )
            stage = .preparing
            scheduleDismiss(at: expiry)
            return true
        } catch {
            activity = nil
            stage = nil
            await logUnavailable("创建配对实时活动失败，配对码将改用系统通知显示：\(error.localizedDescription)")
            return false
        }
    }

    /// 只在收到系统给出的真实六码后调用。若活动已不可用，调用方应切换到通知回退。
    @discardableResult
    func showCode(_ code: String) async -> Bool {
        guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else {
            await logUnavailable("配对服务返回的配对码格式无效，无法更新实时活动。")
            return false
        }
        guard let activity else {
            await logUnavailable("配对码到达时实时活动已不存在，配对码将改用系统通知显示。")
            return false
        }
        guard stage == .preparing || stage == .code else {
            await logUnavailable("配对码到达时实时活动处于非配对状态，配对码将改用系统通知显示。")
            return false
        }
        guard activity.activityState == .active || activity.activityState == .stale else {
            await logUnavailable("配对实时活动已被系统结束，配对码将改用系统通知显示。")
            finish()
            return false
        }
        let activityID = activity.id
        stage = .code
        // 输入窗口内不设 stale、不用本地计时器收活动：配对码阶段活到配对出结果
        // （成功 markPaired / 失败 markFailed / 会话超时走失败路径）为止。
        // preparing 阶段排的到期收尾在此摘掉，否则它会在输码途中把活动关掉；
        // 配对会话本身有超时（PhonePairingHost.timeoutSeconds），不会无限残留。
        dismissTask?.cancel()
        dismissTask = nil
        expiresAt = nil
        // ActivityKit's current SDK marks update as concurrent; this handle is only passed
        // to that API here and remains otherwise isolated to this controller.
        nonisolated(unsafe) let activityForUpdate = activity
        let previousOperation = activityOperation
        let updateOperation = Task {
            await previousOperation?.value
            // 带 AlertConfiguration 的 update：用户此刻在系统设置里，系统会把
            // 展开态弹出来直接看到配对码，不用先手动点开灵动岛。静默 update
            // 只换紧凑态内容，用户感知不到码已经到了。
            await activityForUpdate.update(
                .init(state: Self.codeState(code), staleDate: nil),
                alertConfiguration: Self.codeAlertConfiguration(code)
            )
        }
        activityOperation = updateOperation
        await updateOperation.value
        guard self.activity?.id == activityID, stage == .code else {
            await logUnavailable("更新配对码期间实时活动已被取消或替换，配对码将改用系统通知显示。")
            return false
        }
        guard activity.activityState == .active || activity.activityState == .stale else {
            await logUnavailable("配对实时活动更新后已不可用，配对码将改用系统通知显示。")
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
            lifetime: Self.completionLifetime,
            logMessage: "已向灵动岛提交「配对成功」状态",
            alertConfiguration: Self.pairedAlertConfiguration
        )
    }

    /// 失败态不保留旧配对码；短暂显示失败提示后结束活动。
    func markFailed() {
        endWithResult(
            stage: .failed,
            state: .init(stage: .failed, code: "", title: "Seal", detail: "返回 Seal 查看原因"),
            lifetime: Self.failureLifetime,
            logMessage: "已向灵动岛提交「配对失败」状态"
        )
    }

    /// 等待已排队的 ActivityKit 操作（配对码更新 / 终态提交）真正完成。
    /// 调用方用它确认终态已经交给系统，再结束为此申请的后台执行时间。
    func awaitPendingOperation() async {
        await activityOperation?.value
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
        // ActivityKit's current SDK marks end as concurrent; serialize the call with
        // the prior operation and pass the handle only to that API.
        nonisolated(unsafe) let activityForEnd = activity
        activityOperation = Task {
            await previousOperation?.value
            await activityForEnd.end(nil, dismissalPolicy: .immediate)
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

    /// 把终态提交给 ActivityKit 并排定本地收尾。终态只用 `update` 送达、不在这里
    /// `end`：苹果 HIG 写明活动一旦结束，系统立刻把它从灵动岛移除，最终内容只
    /// 留在锁屏（`dismissalPolicy: .after` 管的只是锁屏保留期）——147 真机上
    /// 「配对一完成岛就消失」正是这条。展示窗口内保持活动 active，到点由
    /// scheduleDismiss → discardExpiredActivityIfNeeded → finish 收尾；
    /// 点岛回 Seal 时 dismissIfTerminal 也会立即收。
    private func endWithResult(
        stage: PairingActivityAttributes.Stage,
        state: PairingActivityAttributes.ContentState,
        lifetime: TimeInterval,
        logMessage: String,
        alertConfiguration: AlertConfiguration? = nil
    ) {
        guard let activity else { return }
        self.stage = stage
        dismissTask?.cancel()
        expiresAt = nil
        let previousOperation = activityOperation
        let activityID = activity.id
        let logStore = self.logStore
        nonisolated(unsafe) let activityForEnd = activity
        activityOperation = Task { [weak self] in
            await previousOperation?.value
            let dismissalDate = Date().addingTimeInterval(lifetime)
            let content = ActivityContent(state: state, staleDate: dismissalDate)
            // 只 update、不 end（理由见函数头注释）：end 会让系统立刻把活动
            // 从灵动岛移除，配对成功态永远上不了岛。窗口内保持 active，
            // staleDate 到点先变陈旧态，本地计时器随后 finish 收尾。
            // 成功态带 AlertConfiguration 送达：与配对码同一机制，让系统在用户
            // 还在设置页时把展开态弹出来；失败态不传（nil），呈现行为保持原样。
            // （activityForEnd 是历史变量名，现只用于 update 与到点后的 finish。）
            await activityForEnd.update(content, alertConfiguration: alertConfiguration)
            try? await logStore?.append(category: .pairing, level: .info, message: logMessage)
            guard let self,
                  self.activity?.id == activityID,
                  self.stage == stage else { return }
            self.scheduleDismiss(at: dismissalDate)
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
        detail: PairingActivityAttributes.developerModePairingInstruction
    )

    private static func codeState(_ code: String) -> PairingActivityAttributes.ContentState {
        .init(stage: .code, code: code, title: "Seal", detail: "在系统配对窗口输入此码")
    }

    private static func codeAlertConfiguration(_ code: String) -> AlertConfiguration {
        AlertConfiguration(
            title: "Seal 配对码",
            body: "配对码 \(code)，在系统配对窗口输入此码",
            sound: .default
        )
    }

    private static let pairedAlertConfiguration = AlertConfiguration(
        title: "Seal",
        body: "配对成功，点击返回 Seal",
        sound: .default
    )

    private func logUnavailable(_ message: String) async {
        try? await logStore?.append(category: .pairing, level: .warning, message: message)
    }
}
