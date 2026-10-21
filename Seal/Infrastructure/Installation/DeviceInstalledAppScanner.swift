import Foundation
@preconcurrency import Minimuxer

struct DeviceInstalledApplicationSummary: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let shortVersion: String
    let buildNumber: String
    let profileValidated: Bool?
    let teamIdentifier: String?
    let sealManagedMarkerVersion: Int?

    init(
        bundleIdentifier: String,
        displayName: String,
        shortVersion: String,
        buildNumber: String,
        profileValidated: Bool?,
        teamIdentifier: String? = nil,
        sealManagedMarkerVersion: Int? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.profileValidated = profileValidated
        self.teamIdentifier = teamIdentifier
        self.sealManagedMarkerVersion = sealManagedMarkerVersion
    }
}

/// 设备端扫回的**注入点**。
///
/// ## 为什么必须是注入，不能直接调静态方法
///
/// `AppRecordRecovery.restoreMissingRecords()` 被**单测直接调用**
/// （`AppRecordRecoveryTests` 的三个用例）。扫回若写死在它里面，那三个用例就会在 CI 的
/// 模拟器上真的去调 `Provision.dumpProfiles` —— 一次**无设备可连**的同步 FFI：
/// 最坏情况白等 15 秒，还可能直接崩掉整个测试进程。
///
/// 本仓对「会碰设备」的依赖一律**注入 ＋ 默认 nil**（同 `StaleProfileSweeping`），
/// 生产路径由 `AppContainer` 接上带 `OperationCoordinator` 的扫描器实例。
/// `nil` 的后果必须留 stage（`skipped-not-wired`）—— 否则「没人接这根线」会被
/// 读成「设备端确实没有可补的」，扫回静默失效。
protocol InstalledAppScanning: Sendable {
    /// 枚举设备端全部描述文件并解析成摘要。
    /// `nil` = **无法核验**（未连接设备 / 隧道不可用 / dump 或解析失败）。
    func scanProfileSummaries() async -> [DeviceProvisioningProfileSummary]?

    /// 设备端 installation proxy 的全部用户应用清单；侧载状态由安装代理标记和已知描述文件共同判定。
    func scanUserApplications() async -> [DeviceInstalledApplicationSummary]?

    /// 本机 LaunchServices 清单。记录恢复只新增，不用部分清单判断卸载，因此无需 LocalDevVPN。
    func scanLocalApplications() async -> [DeviceInstalledApplicationSummary]?

    /// 按归一化 Bundle ID 读取本机 LaunchServices 图标；失败或不可用时返回空字典。
    /// Reads icon bytes from local LaunchServices metadata; this call does not use the paired device channel.
    func scanIconData(for normalizedBundleIdentifiers: Set<String>) async -> [String: Data]

    /// 阳性对照 ＋ 逐条设备核验，**先问完再动手**。
    /// `nil` = 通道不可信（**一条记录都不许建**）。
    func scanConfirmedInstalledBundleIdentifiers(
        candidates: [String],
        positiveControl: String?
    ) async -> Set<String>?
}

extension InstalledAppScanning {
    func scanUserApplications() async -> [DeviceInstalledApplicationSummary]? { nil }
    func scanLocalApplications() async -> [DeviceInstalledApplicationSummary]? { nil }
    func scanIconData(for normalizedBundleIdentifiers: Set<String>) async -> [String: Data] { [:] }
}

/// Scoped lease for synchronous device-inventory FFI. A timeout cannot cancel native work,
/// so the lease remains active until the late-completion callback releases it.
enum InstalledAppInventoryOperationLease {
    static func begin(
        using coordinator: OperationCoordinator?,
        kind: OperationCoordinator.Kind = .scanningDeviceInventory
    ) async -> OperationCoordinator.Lease? {
        if let coordinator {
            return await coordinator.begin(kind)
        }
        return .uncoordinated(kind, appID: nil, accountID: nil)
    }

    static func end(
        _ lease: OperationCoordinator.Lease,
        using coordinator: OperationCoordinator?
    ) async {
        await coordinator?.end(lease)
    }
}

/// 设备端「已验证侧载应用」的只读扫描：读取描述文件和安装代理的用户应用清单。
///
/// 与 `DeviceProfileInspector` / `DeviceProfileCleaner` 共用同一条 misagent dump 通道，
/// 并通过 InstallationProxy 读取已安装应用；**绝不删除任何文件**、也**不落任何状态**。
///
/// ⚠️ 两个入口都是同步阻塞 FFI（`Provision.dumpProfiles` / `Minimuxer.installedApplications`），
/// 在一条已死的 RSD 缓存会话上**不报错、只阻塞到操作系统放弃** ⇒ 必须有界。
/// 查询类调用用 `BlockingCall.bounded`；设备会话租约在原生调用真正结束前不会释放。
struct DeviceInstalledAppScanner: InstalledAppScanning, Sendable {
    private let operationCoordinator: OperationCoordinator?

    init(operationCoordinator: OperationCoordinator? = nil) {
        self.operationCoordinator = operationCoordinator
    }

    func scanProfileSummaries() async -> [DeviceProvisioningProfileSummary]? {
        await profileSummaries()
    }

    func scanUserApplications() async -> [DeviceInstalledApplicationSummary]? {
        await userApplications()
    }

    func scanLocalApplications() async -> [DeviceInstalledApplicationSummary]? {
        guard let applications = await InstalledAppScanner().scanAllSnapshot(
            allowPartialForRecovery: true
        ) else { return nil }
        return applications.map { application in
            DeviceInstalledApplicationSummary(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.name,
                shortVersion: application.version,
                buildNumber: application.buildNumber,
                profileValidated: nil,
                teamIdentifier: application.teamID,
                sealManagedMarkerVersion: application.sealManagedMarkerVersion
            )
        }
    }

    func scanIconData(for normalizedBundleIdentifiers: Set<String>) async -> [String: Data] {
        await InstalledAppScanner().scanIconData(for: normalizedBundleIdentifiers)
    }

    func scanConfirmedInstalledBundleIdentifiers(
        candidates: [String],
        positiveControl: String?
    ) async -> Set<String>? {
        await Self.confirmedInstalledBundleIdentifiers(
            candidates: candidates,
            positiveControl: positiveControl,
            operationCoordinator: operationCoordinator
        )
    }

    /// 枚举设备端全部描述文件并解析成摘要。
    ///
    /// - Returns: `nil` = **无法核验**（未连接设备 / 隧道不可用 / dump 或解析失败）。
    ///   调用方必须按「不知道」处理（本轮不建任何记录）；返回空数组仅当设备端确实一份都没有。
    private func profileSummaries() async -> [DeviceProvisioningProfileSummary]? {
        guard let operationLease = await InstalledAppInventoryOperationLease.begin(
            using: operationCoordinator,
            kind: .managingDeviceProfiles
        ) else { return nil }
        let probeID: UUID
        switch await InstalledAppRefreshProbeGate.profiles.begin() {
        case .ready(let id):
            probeID = id
        case .inFlight, .cancelled:
            await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            return nil
        }
        let outcome = await BlockingCall.bounded(
            seconds: BlockingCall.queryTimeoutSeconds,
            cancelsWorkOnTimeout: false,
            onLateCompletion: { _ in
                await InstalledAppRefreshProbeGate.profiles.finish(probeID: probeID)
                await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            },
            onWorkNeverStarted: {
                await InstalledAppRefreshProbeGate.profiles.finish(probeID: probeID)
                await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            }
        ) {
            Self.readProfileSummaries()
        }
        guard let outcome else { return nil }
        await InstalledAppRefreshProbeGate.profiles.finish(probeID: probeID)
        await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
        guard case .success(let summaries) = outcome else { return nil }
        return summaries
    }

    private func userApplications() async -> [DeviceInstalledApplicationSummary]? {
        guard let operationLease = await InstalledAppInventoryOperationLease.begin(
            using: operationCoordinator
        ) else { return nil }
        let probeID: UUID
        switch await InstalledAppRefreshProbeGate.inventory.begin() {
        case .ready(let id):
            probeID = id
        case .inFlight, .cancelled:
            await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            return nil
        }
        let outcome = await BlockingCall.bounded(
            seconds: BlockingCall.queryTimeoutSeconds,
            cancelsWorkOnTimeout: false,
            onLateCompletion: { _ in
                await InstalledAppRefreshProbeGate.inventory.finish(probeID: probeID)
                await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            },
            onWorkNeverStarted: {
                await InstalledAppRefreshProbeGate.inventory.finish(probeID: probeID)
                await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            }
        ) {
            try Minimuxer.installedApplications()
        }
        guard let outcome else { return nil }
        await InstalledAppRefreshProbeGate.inventory.finish(probeID: probeID)
        await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
        guard case .success(let applications) = outcome else { return nil }
        return applications.map { application in
            DeviceInstalledApplicationSummary(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                shortVersion: application.shortVersion,
                buildNumber: application.buildNumber,
                profileValidated: application.profileValidated,
                sealManagedMarkerVersion: SealInstalledAppMarker.isDeclared(
                    for: application.bundleIdentifier
                ) ? SealInstalledAppMarker.version : nil
            )
        }
    }

    /// 阳性对照 ＋ 逐条设备核验，**先问完再动手**。
    ///
    /// - Parameters:
    ///   - candidates: 待核验的 Bundle ID（来自 `InstalledRecordRecoveryPolicy.drafts`）。
    ///   - positiveControl: 一个**确定装着**的 Bundle ID —— 传正在运行的 Seal 自己。
    /// - Returns: `nil` = 通道不可信（**一条记录都不许建**）；否则是「确认装在设备上」
    ///   的 Bundle ID 集合（已归一化）。
    ///
    /// ## 为什么必须有阳性对照
    ///
    /// `isAppInstalled` 抛错只能抓到「同步调用失败」。而 Rust 侧的
    /// `RustInstProxy.lookup(appId:)` 把 RPC 失败也返回成 `nil`（空指针 ⇒ Swift 侧 `nil`），
    /// 这种**静默的**失败在单条查询上看不出来。阳性对照就是先证明「这条通道此刻说真话」，
    /// 再去信它对候选的回答。判据与 `ProfileReclaimPolicy.decision` 同源。
    ///
    /// ## 为什么一条失败就整轮中止
    ///
    /// 与 `reconcileInstalledAppsWithDevice` 同一条纪律（2026-09-25 那次修复）：
    /// 通道一抖动，剩下的候选会被读成「没装」⇒ 该补的 App 永远补不回来；
    /// 更糟的是「问一半、建一半」会让列表看起来像是随机的。代价只是「本轮不补」，下次维护再来。
    ///
    /// ## 调用成本
    ///
    /// 每条候选一次 `InstalledAppDeviceVerifier.isInstalled`（上限 2 秒，且共享
    /// `InstalledAppRefreshProbeGate`）。调用方**必须**先在本地把候选筛到尽量小
    /// （`InstalledRecordRecoveryPolicy.drafts` 就是干这个的），否则这里会变成
    /// 一串 2 秒超时的串行等待。候选为空时**一次设备查询都不发**。
    static func confirmedInstalledBundleIdentifiers(
        candidates: [String],
        positiveControl: String?,
        operationCoordinator: OperationCoordinator? = nil
    ) async -> Set<String>? {
        guard candidates.isEmpty == false else { return [] }

        if let positiveControl,
           positiveControl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let control = try? await InstalledAppDeviceVerifier.isInstalled(
                bundleIdentifier: positiveControl,
                operationCoordinator: operationCoordinator
            )
            guard control == true else { return nil }
        }

        var confirmed: Set<String> = []
        for candidate in candidates {
            guard let installed = try? await InstalledAppDeviceVerifier.isInstalled(
                bundleIdentifier: candidate,
                operationCoordinator: operationCoordinator
            ) else { return nil }
            if installed {
                confirmed.insert(InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(candidate))
            }
        }
        return confirmed
    }

    /// 同步部分：dump ＋ 解析。跑在 `BlockingCall.bounded` 的闭包里。
    private static func readProfileSummaries() -> [DeviceProvisioningProfileSummary]? {
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-installed-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workingDir) }

        guard let dumpDir = try? Provision.dumpProfiles(docsPath: workingDir.path),
              let profileURLs = try? fileManager.contentsOfDirectory(
                  at: URL(fileURLWithPath: dumpDir),
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else { return nil }
        // 设备端确实没有描述文件：空数组是**有效结论**（没有任何 Seal 痕迹）。
        if profileURLs.isEmpty { return [] }

        let reader = ProvisioningProfileReader()
        var summaries: [DeviceProvisioningProfileSummary] = []
        var handledUUIDs = Set<String>()
        var parsed = 0
        for fileURL in profileURLs {
            // 与 `DeviceProfileCleaner` 同约定：不按扩展名过滤 —— misagent 返回的是
            // CMS 包裹的二进制，识别一律交给 `ProvisioningProfileReader` 解 CMS。
            guard let data = try? Data(contentsOf: fileURL),
                  let details = try? reader.details(from: data) else { continue }
            // LockDown 路径同一 profile 会落 raw + plist 两份，按 UUID 去重。
            if let uuid = details.uuid, handledUUIDs.insert(uuid).inserted == false { continue }
            parsed += 1
            guard let bundleIdentifier = details.bundleIdentifier,
                  bundleIdentifier.isEmpty == false else { continue }
            summaries.append(DeviceProvisioningProfileSummary(
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: details.teamIdentifier,
                uuid: details.uuid,
                name: details.name,
                creationDate: details.creationDate,
                expirationDate: details.expirationDate,
                binding: try? reader.binding(from: data)
            ))
        }
        // 目录里有文件却一份都解析不出来 = 核验失败，**不是**「没有」。
        return parsed > 0 ? summaries : nil
    }
}
