import Foundation
@preconcurrency import Minimuxer

/// 「上一次描述文件设备操作是否留下了污染」的**纯状态机**（可单测）。
///
/// ## 为什么抽成值类型，而不是 actor 的私有 `Bool`
///
/// `installAndVerify` 要调 `Minimuxer`，而 `SealTests` target 看不到 Minimuxer
/// ⇒ 判定若留在 actor 的私有状态里就**永远测不到**。这条判定的两种错法都不报错、
/// 只改行为：`consume()` 若不是一次性的 ⇒ 每一项续签都白重置一次设备通道；
/// 污染若被漏掉 ⇒ 把「可能仍在跑」的上一次注入与本次注入放成并发。
struct ProfileOnlyTaintGate {
    private(set) var isTainted = false

    /// 记录「上一次设备操作超时 —— 底层同步 FFI 没有取消机制、可能仍在后台跑」。
    mutating func markTainted() {
        isTainted = true
    }

    /// 读取并**清除**污染标记；返回清除前是否处于污染态。
    ///
    /// 「读取 + 清除」必须是**一个**操作：写成
    /// `if isTainted { reset(); isTainted = false }` 会让两个并发调用都看到 `true`、
    /// 各自重置一次设备通道（而重置本身要拆掉正在用的连接）。
    mutating func consume() -> Bool {
        let wasTainted = isTainted
        isTainted = false
        return wasTainted
    }
}

/// Keeps the device-operation lease until a non-cancellable native profile call really returns.
struct ProfileOnlyOperationLease {
    private(set) var nativeOperationInFlight = false
    private(set) var holdBusyUntilCompletion = false

    mutating func beginNativeOperation() {
        nativeOperationInFlight = true
    }

    /// Returns true when the late completion must release the installer actor's busy lease.
    mutating func nativeOperationCompleted() -> Bool {
        nativeOperationInFlight = false
        let shouldReleaseBusy = holdBusyUntilCompletion
        holdBusyUntilCompletion = false
        return shouldReleaseBusy
    }

    /// Returns true when a timed-out caller must keep the busy lease until native completion.
    mutating func timedOut() -> Bool {
        guard nativeOperationInFlight else { return false }
        holdBusyUntilCompletion = true
        return true
    }
}

/// 设备注入子阶段的上报事件（只用于界面提示，不改变注入语义）。
/// 注入器本身不写界面文案：调用方（SigningCoordinator）把事件译成人话后
/// 经阶段回调送界面；这里只报事实。
enum ProfileOnlyInjectionProgress: Sendable {
    /// 串行 actor 正被另一项占用，本项在排队。
    case waitingForTurn
    /// 消费到污染标记，正在重置并重建设备通道。
    case healingTaint
    /// 正在注入第 index / total 份描述文件。
    case injecting(index: Int, total: Int)
    /// 注入完成，正在一次性 dump 逐份读回核验。
    case verifyingReadback
    /// 本次注入遇通道瞬时失败，正在重建连接后重试一次。
    case retryingConnection
}

/// Serializes profile injection for the entire process. `misagent` uses a
/// process-wide device transport, so two app renewals must never install a
/// profile concurrently.
actor ProfileOnlyProvisioningProfileInstaller {
    static let shared = ProfileOnlyProvisioningProfileInstaller()

    private var isBusy = false
    private var taint = ProfileOnlyTaintGate()
    private var operationLease = ProfileOnlyOperationLease()
    func installAndVerify(
        _ materials: [ProfileOnlyProfileMaterial],
        certificateSerialNumber: String,
        channel: any InstallChannel,
        operationCoordinator: OperationCoordinator? = nil,
        // 污染自愈时留痕（`SEAL-PROFILE-355`），由调用方传入日志闭包。
        onTaintHealed: @Sendable () async -> Void = {},
        // 设备注入子阶段上报：调用方译成界面提示。默认空实现，不影响旧调用点。
        onProgress: @Sendable (ProfileOnlyInjectionProgress) async -> Void = { _ in }
    ) async throws {
        // Actor 在 await 处可重入，因此仅把「等待前驱」放入 task tail 不够：
        // 前驱一入场，后继的门闩也会完成。这里持有 isBusy 直到所有设备操作与读回结束。
        if isBusy {
            await onProgress(.waitingForTurn)
        }
        while isBusy {
            try Task.checkCancellation()
            // 原生调用结束前让同设备写入排队；等候期间释放 actor 执行权，其他 App 操作仍可运行。
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        isBusy = true
        defer {
            if operationLease.holdBusyUntilCompletion == false { isBusy = false }
        }

        // ── 拿锁后自愈污染（2026-10-04）──
        // 「消费 + 重置 + 注入」在串行临界区里原子完成（R93② 钉住）：
        // 排队等待期间，另一项的注入可能失败并标记污染，或 363 提前标记了污染。
        // 在这里消费 + 重置通道，注入继续，不丢一轮。
        if taint.consume() {
            await onProgress(.healingTaint)
            await channel.reset()
            _ = try await channel.start()
            await onTaintHealed()
        }

        for (index, material) in materials.enumerated() {
            try Task.checkCancellation()
            await onProgress(.injecting(index: index + 1, total: materials.count))
            try await inject(
                material,
                using: channel,
                operationCoordinator: operationCoordinator,
                onProgress: onProgress
            )
        }

        // ── 批量读回核验（性能优化）：全部注入完后一次 dump + 全量解析，
        // 逐份核验，避免每份各做一次秒级 dump（2026-10-04）。
        await onProgress(.verifyingReadback)
        operationLease.beginNativeOperation()
        let readback = await DeviceProfileInspector.containsProfiles(
            matching: materials.map(\.binding),
            certificateSerialNumber: certificateSerialNumber,
            using: operationCoordinator,
            onNativeCompletion: { [weak self] in
                await self?.nativeProfileOperationDidComplete()
            }
        )
        let results: [Bool?]
        switch readback {
        case .completed(let result):
            releaseBusyAfterNativeCompletionIfNeeded()
            do {
                results = try result.get()
            } catch {
                throw failure(
                    reason: "设备端读取本轮注入的描述文件失败：\(error)",
                    code: "SEAL-PROFILE-354"
                )
            }
        case .unavailable:
            releaseBusyAfterNativeCompletionIfNeeded()
            throw failure(
                reason: "设备描述文件服务正被另一项设备查询占用；本轮没有并发读取。",
                code: "SEAL-OP-001",
                recovery: "等待当前设备操作结束后重试。"
            )
        case .nativeCallMayStillBeRunning:
            _ = operationLease.timedOut()
            taint.markTainted()
            throw failure(
                reason: "设备端读取本轮注入的描述文件超过 30 秒未完成。",
                code: "SEAL-PROFILE-353"
            )
        }
        for (material, installed) in zip(materials, results) {
            guard installed == true else {
                throw failure(
                    reason: "设备端未能读回本轮注入的 \(material.binding.bundleIdentifier) 描述文件；本地到期日未更新。",
                    code: "SEAL-PROFILE-354"
                )
            }
        }
    }

    /// 注入所用的 misagent 服务可能在健康探测与真正写入之间瞬时掉线。
    /// 同一 UUID 的 profile 注入是幂等的，因此只对明确的通道瞬时失败立即重建一次，
    /// 避免把可恢复的冷 RSD 会话交给外层 8 秒退避；超时仍按污染路径处理。
    private func inject(
        _ material: ProfileOnlyProfileMaterial,
        using channel: any InstallChannel,
        operationCoordinator: OperationCoordinator?,
        onProgress: @Sendable (ProfileOnlyInjectionProgress) async -> Void = { _ in }
    ) async throws {
        var recoveredConnection = false

        while true {
            operationLease.beginNativeOperation()
            let injection = await DeviceProfileNativeCall.perform(
                operationCoordinator: operationCoordinator,
                seconds: 30,
                waitForAvailability: true,
                onNativeCompletion: { [weak self] in
                    await self?.nativeProfileOperationDidComplete()
                }
            ) {
                try Minimuxer.installProvisioningProfile(profile: material.data)
            }
            let result: Result<Void, Error>
            switch injection {
            case .completed(let completed):
                releaseBusyAfterNativeCompletionIfNeeded()
                result = completed
            case .unavailable:
                releaseBusyAfterNativeCompletionIfNeeded()
                throw failure(
                    reason: "设备描述文件服务正被另一项设备查询占用；本轮没有并发写入。",
                    code: "SEAL-OP-001",
                    recovery: "等待当前设备操作结束后重试。"
                )
            case .nativeCallMayStillBeRunning:
                _ = operationLease.timedOut()
                taint.markTainted()
                throw failure(
                    reason: "注入 \(material.binding.bundleIdentifier) 的描述文件超过 30 秒未返回。",
                    code: "SEAL-PROFILE-352"
                )
            }

            do {
                try result.get()
                return
            } catch {
                guard recoveredConnection == false,
                      DeviceChannelTransientPolicy.isTransientChannelFailure(error) else {
                    throw error
                }
                recoveredConnection = true
                await onProgress(.retryingConnection)
                await channel.invalidateProfileServiceConnection()
                _ = try await channel.start()
            }
        }
    }

    private func nativeProfileOperationDidComplete() {
        if operationLease.nativeOperationCompleted() {
            isBusy = false
        }
    }

    private func releaseBusyAfterNativeCompletionIfNeeded() {
        if operationLease.nativeOperationCompleted() {
            isBusy = false
        }
    }

    private func failure(
        reason: String,
        code: String,
        recovery: String = "确认 LocalDevVPN 与设备连接后重试；不要在未确认前删除旧描述文件"
    ) -> ImportFailure {
        ImportFailure(
            title: "描述文件续签未确认",
            reason: reason,
            recovery: recovery,
            code: code
        )
    }
}
