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

/// Serializes profile injection for the entire process. `misagent` uses a
/// process-wide device transport, so two app renewals must never install a
/// profile concurrently.
actor ProfileOnlyProvisioningProfileInstaller {
    static let shared = ProfileOnlyProvisioningProfileInstaller()

    private var isBusy = false
    private var taint = ProfileOnlyTaintGate()
    private var operationLease = ProfileOnlyOperationLease()
    /// 门户请求期间预热的 profile 服务任务。写入会加入同一任务，避免 `dumpProfiles`
    /// 与真实注入并发使用 misagent。
    private var inFlightPreparation: Task<Void, Error>?
    /// misagent 保活心跳任务（2026-10-04 通道优化）。
    ///
    /// `misagent` 空闲一段时间后会变冷，下次注入要重新建服务连接（~数秒）。
    /// App 在前台存活时定期轻量 `prepareProfileService`，保持热状态。
    /// 失败不标记污染（`prewarmProfileService` 已保证），不干扰注入（`isBusy` 保护）。
    private var keepaliveTask: Task<Void, Never>?
    /// 保活间隔：5 分钟。misagent 空闲超时是分钟级，这个频率足够保持热状态，
    /// 又不会频繁唤醒设备。
    private static let keepaliveIntervalNanoseconds: UInt64 = 300_000_000_000

    /// 启动 misagent 保活心跳。App 回到前台时调用。
    ///
    /// 幂等：已在跑则直接返回。
    func startKeepalive(using channel: any InstallChannel) {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(nanoseconds: Self.keepaliveIntervalNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                guard Task.isCancelled == false else { return }
                // 保活只是轻量预热：失败不抛、不标记污染、不干扰注入。
                try? await self.prewarmProfileService(using: channel, waitForAvailability: false)
            }
        }
    }

    /// 停止 misagent 保活心跳。App 进后台时调用。
    func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// 与 Apple Portal 请求并行预热实际执行 profile 注入的设备服务。
    /// 正在写入时不另起探测，避免和 `misagent` 的进程级传输竞争。
    ///
    /// ⚠️ 预热失败**不标记污染**（2026-10-04）：预热只是后台优化，跑在坏通道上
    /// 失败是预期的；若它标记污染，会与 `renewProfilesOnly` 的污染消费竞态 ——
    /// 消费后、注入前预热才标记 ⇒ `installAndVerify` 误报 `SEAL-PROFILE-350`
    /// （调用方明明已重置通道）。真正的注入失败仍由 `installAndVerify` 自己标记。
    func prewarmProfileService(
        using channel: any InstallChannel,
        waitForAvailability: Bool = true
    ) async throws {
        guard isBusy == false else { return }
        isBusy = true
        defer {
            if operationLease.holdBusyUntilCompletion == false { isBusy = false }
        }
        try await ensureProfileService(
            using: channel,
            markTaintOnFailure: false,
            waitForAvailability: waitForAvailability
        )
    }

    func installAndVerify(
        _ materials: [ProfileOnlyProfileMaterial],
        certificateSerialNumber: String,
        channel: any InstallChannel,
        operationCoordinator: OperationCoordinator? = nil,
        // 污染自愈时留痕（`SEAL-PROFILE-355`），由调用方传入日志闭包。
        onTaintHealed: @Sendable () async -> Void = {}
    ) async throws {
        // Actor 在 await 处可重入，因此仅把「等待前驱」放入 task tail 不够：
        // 前驱一入场，后继的门闩也会完成。这里持有 isBusy 直到所有设备操作与读回结束。
        while isBusy {
            try Task.checkCancellation()
            // 原生同步 FFI 超时后不会停止。保持租约直到它真正返回是设备安全边界；
            // 但后继不能无限等待并继续占用前台事务租约，否则一项卡住会拖住整批续签。
            guard operationLease.holdBusyUntilCompletion == false else {
                throw failure(
                    reason: "上一项设备描述文件操作超时，底层调用仍未返回；本项未开始。",
                    code: "SEAL-PROFILE-357",
                    recovery: "等待设备通道恢复后重试；本次未开始的 App 可单独续签。"
                )
            }
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
            await channel.reset()
            _ = try await channel.start()
            await onTaintHealed()
        }

        // 这道门验证的是真正执行注入的 misagent 服务，不是 profile-only 的资格。
        // 其短时租约让签名入口预热的结果可复用；过期或失效则在写入前重建一次。
        try await ensureProfileService(using: channel)

        for material in materials {
            try Task.checkCancellation()
            try await inject(
                material,
                using: channel,
                operationCoordinator: operationCoordinator
            )
        }

        // ── 批量读回核验（性能优化）：全部注入完后一次 dump + 全量解析，
        // 逐份核验，避免每份各做一次秒级 dump（2026-10-04）。
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

    private func ensureProfileService(
        using channel: any InstallChannel,
        markTaintOnFailure: Bool = true,
        waitForAvailability: Bool = true
    ) async throws {
        do {
            if let inFlightPreparation {
                try await inFlightPreparation.value
                return
            }

            operationLease.beginNativeOperation()
            let task = Task<Void, Error> { [weak self] in
                do {
                    try await channel.prepareProfileService(
                        waitForAvailability: waitForAvailability,
                        onLateCompletion: { [weak self] in
                            await self?.nativeProfileOperationDidComplete()
                        }
                    )
                    await self?.nativeProfileOperationDidComplete()
                } catch {
                    await self?.nativeProfileOperationDidFail(error)
                    throw error
                }
            }
            inFlightPreparation = task
            defer { inFlightPreparation = nil }
            try await task.value
        } catch {
            // `dumpProfiles` 的有界等待超时后，Rust FFI 仍可能占着 misagent。
            // 复用既有污染闸门：下一轮先 reset + start，不能在旧传输上立即重试。
            // ⚠️ 预热调用传 `markTaintOnFailure: false`（见 `prewarmProfileService`）。
            if markTaintOnFailure,
               let failure = error as? ImportFailure,
               DeviceChannelTransientPolicy.profileOperationTimeoutCodes.contains(failure.code) {
                taint.markTainted()
            }
            throw error
        }
    }

    /// 注入所用的 misagent 服务可能在健康探测与真正写入之间瞬时掉线。
    /// 同一 UUID 的 profile 注入是幂等的，因此只对明确的通道瞬时失败立即重建一次，
    /// 避免把可恢复的冷 RSD 会话交给外层 8 秒退避；超时仍按污染路径处理。
    private func inject(
        _ material: ProfileOnlyProfileMaterial,
        using channel: any InstallChannel,
        operationCoordinator: OperationCoordinator?
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
                await channel.invalidateProfileServiceConnection()
                try await ensureProfileService(using: channel)
            }
        }
    }

    private func nativeProfileOperationDidComplete() {
        if operationLease.nativeOperationCompleted() {
            isBusy = false
        }
    }

    private func nativeProfileOperationDidFail(_ error: Error) {
        if let failure = error as? ImportFailure,
           DeviceChannelTransientPolicy.profileOperationTimeoutCodes.contains(failure.code) {
            _ = operationLease.timedOut()
        } else if operationLease.nativeOperationCompleted() {
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
