import Foundation

protocol InstallChannel: Actor {
    func start() async throws -> String
    func diagnose() async -> InstallChannelDiagnostics
    func isReady() async -> Bool
    func requireReadyForSigning() async throws
    func storedDeviceIdentifier() async -> String?
    func reset() async
    /// 清除「失败熔断」，让下一次 `start()` 真正重跑完整隧道诊断。
    ///
    /// 背景：`start()` 失败后若不加限制，批量续签里 N 个 App 会各自重跑一遍
    /// 完整诊断（reset + 18s RSD 握手 + 36×500ms 轮询，硬超时 75s），即 N×75s。
    /// 因此具体实现会在失败后写一段短熔断窗口。但**用户主动触发的刷新必须绕过它** ——
    /// 用户刚修好 VPN 或刚点「恢复连接」，期待的是真实重试，不是拿 20 秒前的旧错误搪塞。
    ///
    /// 注意：**必须声明为协议要求**。只在 extension 里给默认实现的话，
    /// `any InstallChannel` 会静态派发到默认实现，具体实现的覆写不会被调用
    ///（同类坑见下方 `install(onProgress:)` 的注释）。
    func clearFailureCooldown() async
    /// 进程启动时的通道点火（对齐 SideStore `AppBootManager`：启动即把 minimuxer
    /// 拉起来**常驻**，之后每个操作只做就绪检查，不再临场建连）。
    ///
    /// 语义是**尽力而为**：未配对 / 隧道未连时静默跳过；失败不许毒化
    /// `start()` 的失败熔断 —— 用户随后真正签名时必须能重新完整诊断，
    /// 不能被启动时那个陈旧错误挡回。
    ///
    /// ⚠️ 与 `clearFailureCooldown()` 同理**必须声明为协议要求**：只在 extension
    /// 里给默认实现的话，`any InstallChannel` 会静态派发到默认实现，
    /// 具体实现的覆写不会被调用。
    func prewarmAtLaunch() async
    /// 只废弃 Rust 的 RSD 会话缓存，保留当前配对文件与 provider 选择。
    /// 用于 profile 服务出现瞬时失败后的立即自愈，避免全量 reset 配对状态。
    func invalidateProfileServiceConnection() async
    func pushIpa(ipaData: Data, bundleID: String) async throws
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws
    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws
    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void,
        onLateCompletion: @escaping @Sendable (Result<Void, HardTimeout.LateCompletionError>) async -> Void
    ) async throws
    func verifyInstalled(bundleID: String) async throws
}

extension InstallChannel {
    func storedDeviceIdentifier() async -> String? { nil }
    func reset() async {}

    func requireReadyForSigning() async throws {
        guard await isReady() else {
            throw ImportFailure(
                title: "设备连接失败",
                reason: "设备通道尚未就绪，本次签名尚未开始，也未申请新的 Apple 签名资源。",
                recovery: "确认 iPhone 已解锁、已配对，并检查 LocalDevVPN 后重试",
                code: "SEAL-INSTALL-706b",
                condition: .tunnelUnavailable,
                action: .openLocalDevVPN,
                route: .localDevVPN,
                retryDisposition: .manual,
                operation: .install,
                origin: .deviceChannel
            )
        }
    }

    /// 默认空实现：供测试桩与不实现熔断的类型直接遵循。
    /// 真实实现见 `MinimuxerInstallChannel.clearFailureCooldown()`。
    func clearFailureCooldown() async {}

    /// 默认空实现：供测试桩与不做启动点火的类型直接遵循。
    /// 真实实现见 `MinimuxerInstallChannel.prewarmAtLaunch()`。
    func prewarmAtLaunch() async {}

    func invalidateProfileServiceConnection() async {}

    /// 带进度回调用法的默认实现：忽略进度，直接转发到无进度版本。
    /// `install(onProgress:)` 已声明为协议要求，`any InstallChannel` 会动态派发到
    /// 具体实现（MinimuxerInstallChannel 覆写版走真实 AFC 上传进度 + 自更新回主屏时机）；
    /// 此默认实现仅供未覆写该方法的遵循类型（如测试桩）向后兼容。
    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        try await install(
            ipaData: ipaData,
            bundleID: bundleID,
            isSelfReplacement: isSelfReplacement
        )
    }

    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void,
        onLateCompletion: @escaping @Sendable (Result<Void, HardTimeout.LateCompletionError>) async -> Void
    ) async throws {
        try await install(
            ipaData: ipaData,
            bundleID: bundleID,
            isSelfReplacement: isSelfReplacement,
            onProgress: onProgress
        )
    }
}
