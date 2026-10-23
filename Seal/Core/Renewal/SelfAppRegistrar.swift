import Foundation
import ZIPFoundation

actor SelfAppRegistrar {
    private let metadata: SelfAppMetadata
    private let appStore: any AppStore
    private let accountRepository: any AccountRepository
    private let fileStore: AppFileStore
    private let selfReplacement: (any SelfReplacing)?
    private let profileCleaner: (any SelfReplacementProfileCleaning)?
    private let keychain: KeychainVault?
    private let logStore: SealLogStore?
    private let pendingBatchResultStore: PendingBatchResultStore?
    private let refreshQueueStore: RefreshQueueStore?

    // 固定 ID，确保 Seal 记录和文件夹路径始终一致，不会出现多个文件夹
    private let fixedSealID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // 启动 .task 与 scenePhase 回前台可能同时触发注册。并发调用必须等待同一轮完成，
    // 否则较早返回的调用会让维护层误发“已同步”通知，界面仍读取旧版本记录。
    private var registrationTask: Task<Void, Error>?

    init(
        metadata: SelfAppMetadata,
        appStore: any AppStore,
        accountRepository: any AccountRepository,
        fileStore: AppFileStore,
        selfReplacement: (any SelfReplacing)? = nil,
        profileCleaner: (any SelfReplacementProfileCleaning)? = nil,
        keychain: KeychainVault? = nil,
        logStore: SealLogStore? = nil,
        pendingBatchResultStore: PendingBatchResultStore? = nil,
        refreshQueueStore: RefreshQueueStore? = nil
    ) {
        self.metadata = metadata
        self.appStore = appStore
        self.accountRepository = accountRepository
        self.fileStore = fileStore
        self.selfReplacement = selfReplacement
        self.profileCleaner = profileCleaner
        self.keychain = keychain
        self.logStore = logStore
        self.pendingBatchResultStore = pendingBatchResultStore
        self.refreshQueueStore = refreshQueueStore
    }

    func ensureRegistered() async throws {
        if let registrationTask {
            try await registrationTask.value
            return
        }

        let task = Task { try await self.registerIfNeeded() }
        registrationTask = task
        do {
            try await task.value
            registrationTask = nil
        } catch {
            registrationTask = nil
            throw error
        }
    }

    private func registerIfNeeded() async throws {
        var records = try await appStore.fetchAll()
        let accounts = try await accountRepository.fetchAll()
        var existing = SelfAppRecordSelection.preferredExistingSealRecord(
            in: records,
            currentBundleIdentifier: metadata.bundleIdentifier
        )

        // 启动只对账上一进程留下的自替换事务，绝不在这里发起安装。
        // 结算会推进记录，之后必须重新读取，避免旧快照覆盖刚确认的真实身份。
        if try await reconcileSelfReplacement(
            existing: existing,
            accounts: accounts,
            // 传全部记录（不只是 Seal 那条）：结算清理的保留集合只有 Seal 自己一个条目，
            // 宽松受保护集合必须由**全部**记录算出来，否则其它 App 的扩展会被当孤儿删掉。
            allRecords: records
        ) {
            records = try await appStore.fetchAll()
            existing = SelfAppRecordSelection.preferredExistingSealRecord(
                in: records,
                currentBundleIdentifier: metadata.bundleIdentifier
            )
        }

        // 已导入、待下次安装生效的自更新源（hasPendingSelfUpdateSource）：
        // 其版本通常比当前运行中的 Bundle 新。此窗口内 App 若重启，仍运行旧版，
        // 绝不能用当前旧 metadata 覆盖这条待安装记录与文件，否则更新源丢失。
        // 仅当待安装源文件仍在、且记录版本不低于运行版本时保留（记录版本更低说明
        // 待安装源已被外部更新取代，属残留标记，落到原子更新对齐当前运行版本，
        // 否则已安装列表会一直显示旧版本号）。
        if let existing,
           existing.hasPendingSelfUpdateSource,
           existing.ipaRelativePath.isEmpty == false,
           try await fileStore.exists(relativePath: existing.ipaRelativePath),
           Version.compare(existing.version, metadata.version) != .orderedAscending {
            // 保留待安装源及 signingTargets，但已安装快照必须来自当前运行包。
            // 安装失败后仍运行旧包时，不能让安装前乐观写入的新有效期继续显示。
            try await reconcileSealRecordFromRunningBundleIfNeeded(
                existing: existing,
                metadata: metadata,
                accounts: accounts
            )
            // The new process itself is proof that this update reached the device. A
            // previously deleted predecessor can leave `replacesInstalledAppID` behind;
            // that stale link keeps Seal in the pending-install list forever.
            if Version.compare(existing.version, metadata.version) == .orderedSame,
               existing.buildNumber == metadata.buildNumber,
               let replacedID = existing.replacesInstalledAppID {
                var installed = try await appStore.fetchAll().first { $0.id == existing.id } ?? existing
                installed.state = .installed
                installed.signedArtifactStatus = .installed
                installed.replacesInstalledAppID = nil
                if let pending = installed.pendingUpdateSourceFingerprint {
                    installed.installedFingerprint = pending
                }
                installed.pendingUpdateSourceFingerprint = nil
                try await appStore.commitInstalledReplacement(installed, replacing: replacedID)
            }
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            return
        }

        // 现行两记录模型的待更新保护：待更新源是独立新记录，靠
        // `replacesInstalledAppID` 指向已安装记录（通常还带
        // `pendingUpdateSourceFingerprint`），已安装记录上的
        // `hasPendingSelfUpdateSource` 在这套模型里恒为 false，上面的旧标志分支
        // 看不见它 ⇒ 保护曾静默失效，待更新记录随后被版本一致分支当「重复 Seal」
        // 连文件删掉（签名抽屉再点就是 SEAL-SIGN-404）。判据与重复清理的豁免
        // 同源（`SelfAppPendingUpdateProtection`）。本轮只回补已安装快照并清理
        // （清理会豁免待更新源），绝不用运行包覆盖待更新源，也绝不替它结算 ——
        // 交接只能由签名安装 / 新进程自替换对账完成。
        // 仅当待更新源文件仍在、且其版本不低于运行版本时才提前收口；不满足时
        // 落到下面的常规分支，清理豁免照样保住待更新源（见 cleanup 实现）。
        if let existing,
           let pendingSource = SelfAppPendingUpdateProtection.pendingUpdateSource(in: records),
           pendingSource.ipaRelativePath.isEmpty == false,
           try await fileStore.exists(relativePath: pendingSource.ipaRelativePath),
           Version.compare(pendingSource.version, metadata.version) != .orderedAscending {
            if pendingSource.id != existing.id {
                // 两记录并存：回补的是已安装记录的快照，不是待更新源。
                try await reconcileSealRecordFromRunningBundleIfNeeded(
                    existing: existing,
                    metadata: metadata,
                    accounts: accounts
                )
            } else if pendingSource.version == metadata.version,
                      pendingSource.buildNumber == metadata.buildNumber {
                // 只剩待更新记录、且它与运行包同版本同构建 = 更新已经装上、
                // 只剩残留链接没清的形态。本进程正运行这个版本，就是更新
                // 已落地的硬证据（与旧标志分支的结算同理）：回补后直接结算 ——
                // 转已安装、清替换链接、待更新指纹转正为已安装指纹；否则这条
                // 记录会永远挂在待安装列表里（2026-10-23 收口根因轮未决②）。
                try await reconcileSealRecordFromRunningBundleIfNeeded(
                    existing: existing,
                    metadata: metadata,
                    accounts: accounts
                )
                if let replacedID = existing.replacesInstalledAppID {
                    var installed = try await appStore.fetchAll().first { $0.id == existing.id } ?? existing
                    installed.state = .installed
                    installed.signedArtifactStatus = .installed
                    installed.replacesInstalledAppID = nil
                    if let pending = installed.pendingUpdateSourceFingerprint {
                        installed.installedFingerprint = pending
                    }
                    installed.pendingUpdateSourceFingerprint = nil
                    try await appStore.commitInstalledReplacement(installed, replacing: replacedID)
                }
            }
            // 保护命中留痕（根因轮未决④）：下次再现待更新异常时，日志里能
            // 直接看到本轮是保护分支收口，而不是又删了记录。
            try? await logStore?.append(
                category: .system,
                level: .info,
                message: "Seal 启动检测到待更新源记录（版本 \(pendingSource.version)），已按待更新保护跳过覆盖，等待签名安装或结算",
                code: "SEAL-SELF-120"
            )
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            return
        }

        // 版本一致且文件存在 → 直接跳过，只清理重复记录
        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           existing.ipaRelativePath.isEmpty == false,
           try await fileStore.exists(relativePath: existing.ipaRelativePath) {
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            // 版本一致也回补：Team/账号（首次未记录时从自身描述文件补全，避免续签时退化成
            // "选第一个账号"导致 Bundle ID 被占用），**以及 profile 身份与有效期**。
            // 后者是 R07：同版本续签会换掉 profile 但版本号不变，只比版本就会漏掉结算。
            try await reconcileSealRecordFromRunningBundleIfNeeded(
                existing: existing,
                metadata: metadata,
                accounts: accounts
            )
            return
        }

        // 版本变更或文件缺失 → 原子更新
        // 兜底：只要 pending 指纹还在就清掉（无论 build 号是否一致）。
        // 自替换场景下，导入时记录的 build 号已更新到新版，运行时 build 号一致，
        // 旧条件（必须不一致）永远不满足，导致「有新版本待安装」常驻。
        if let existing, existing.pendingUpdateSourceFingerprint != nil {
            var updated = existing
            // 2026-10-08：只清待安装标记，不把 pending 记为已装指纹。
            // 这段兜底跑在启动时，没有"新包真的落盘"的证据；若自替换实际失败，
            // 把 pending 写成 installedFingerprint，会让下次导入同包时被误判
            // "已安装过"而不提示更新。标记清掉后红标消失，指纹保持原样。
            updated.pendingUpdateSourceFingerprint = nil
            try await appStore.save(updated)
            try? await logStore?.append(
                category: .system,
                level: .info,
                message: "Seal 启动检测到 build 号变化（记录 \(existing.buildNumber ?? "-") → 运行 \(metadata.buildNumber ?? "-")），已清掉待安装标记",
                code: "SEAL-SELF-120"
            )
        }
        let id = existing?.id ?? fixedSealID
        try await atomicallyUpdateSealRecord(id: id, existing: existing, accounts: accounts)

        // 清理历史残留的重复记录
        try await cleanupDuplicateSealRecords(records: records, keepID: id)
    }

    // MARK: - 原子更新：先暂存，再提交覆盖，失败回滚

    private func atomicallyUpdateSealRecord(
        id: UUID,
        existing: AppRecord?,
        accounts: [AppleAccountRecord]
    ) async throws {
        // 1. 打包新 IPA 到临时工作区（不碰旧文件）
        let workspace = try await fileStore.signingWorkspace(appID: UUID())
        defer { try? FileManager.default.removeItem(at: workspace) }

        let payload = workspace.appending(path: "Payload", directoryHint: .isDirectory)
        let appURL = payload.appending(
            path: "\(metadata.name).app",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: metadata.bundleURL, to: appURL)
        let ipaURL = workspace.appending(path: "Seal.ipa")
        // ⚠️ **必须复用 `SigningWorkspace.writeIPA`**（2026-09-26）——
        // 这里原先是自己写一份 `FileManager.zipItem(compressionMethod: .deflate)`，
        // 于是「按类型选压缩方法」那条规则就有了**两份实现**：改了一处、另一处照旧 ✗。
        // ⇒ 统一走同一个打包函数，Seal 自替换的包也享受同样的压缩策略 ✓。
        try SigningWorkspace.writeIPA(from: payload, to: ipaURL)

        // 2. 暂存新文件
        let staged = try await fileStore.stage(sourceURL: ipaURL)

        do {
            // 3. 图标：优先用新提取的，失败则复用旧图标
            var iconData = metadata.iconData
            if iconData == nil, let oldIconPath = existing?.iconRelativePath {
                iconData = try? await fileStore.read(relativePath: oldIconPath)
            }

            // 4. 提交新文件（用同一个 ID，覆盖旧文件，不是先删后建）
            let files = try await fileStore.commit(
                staged: staged,
                appID: id,
                iconData: iconData
            )

            // 5. 取消暂存
            do {
                try await fileStore.cancel(staged)
            } catch {
                throw ImportFailure(
                    title: "Seal 临时文件清理失败",
                    reason: "Seal 自身注册已写入文件，但暂存文件未能清理。",
                    recovery: "稍后在设置→存储维护中重试清理",
                    code: "SEAL-STORAGE-SELF-001"
                )
            }

            // 6. 计算文件大小
            let attributes = try FileManager.default.attributesOfItem(atPath: ipaURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            // 7. 解析账户绑定（和以前逻辑一致，匹配不到返回 nil，不强制用第一个账户）
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )
            // 启动对账已经确认过当前运行包的身份时，它是重建本地 IPA 后唯一可信的
            // profile 真相。不能因重新封装本地缓存而把刚结算的 UUID / 到期时间擦空，
            // 否则列表虽已转正，后续续签又会误判为缺失签名身份。
            let installedMain = metadata.installedIdentity?.mainTarget
            let installedProfileUUID = installedMain?.profileUUID
                ?? metadata.provisioningProfileUUID
                ?? existing?.provisioningProfileUUID
            let installedProfileExpiry = installedMain?.profileExpirationDate
                ?? metadata.expirationDate
                ?? existing?.provisioningProfileExpirationDate
            let installedExtensions = metadata.extensionRecords.map {
                SelfAppRegistrar.reconcileExtensionRecords(
                    $0,
                    preservingIDsFrom: existing?.extensions ?? []
                )
            } ?? existing?.extensions ?? []

            // 8. 更新记录（复用 ID，不删除重建）
            let record = AppRecord(
                id: id,
                originalBundleIdentifier: SelfAppBundleIdentity.originalBundleIdentifier(
                    currentBundleIdentifier: metadata.bundleIdentifier,
                    declaredOriginalBundleIdentifier: metadata.originalBundleIdentifier,
                    existingOriginalBundleIdentifier: existing?.originalBundleIdentifier
                ),
                mappedBundleIdentifier: metadata.bundleIdentifier,
                name: metadata.name,
                version: metadata.version,
                buildNumber: metadata.buildNumber,
                size: size,
                iconRelativePath: files.iconRelativePath ?? existing?.iconRelativePath,
                state: .installed,
                expiryDate: installedProfileExpiry,
                accountID: resolvedAccountID,
                signingTeamID: installedMain?.teamIdentifier
                    ?? metadata.signingTeamIdentifier
                    ?? existing?.signingTeamID,
                // 关键：Seal 的证书序列号只能取运行包主程序的真实 CMS 签名者，
                // 绝不把描述文件授权证书列表当成实际签名者；身份读取失败时保留既有记录。
                // 爱思/其他工具签的 Seal，证书不是 Seal 创建的，旧记录里可能是 nil 或过期值，
                // 导致前置清理误撤 Seal 在用的证书 → 变砖（2026-09-15 真机确认）。
                certificateSerialNumber: metadata.installedIdentity?.mainTarget?.signerSerialNumber
                    ?? existing?.certificateSerialNumber,
                provisioningProfileUUID: installedProfileUUID,
                provisioningProfileName: metadata.provisioningProfileName ?? existing?.provisioningProfileName,
                provisioningProfileCreationDate: metadata.provisioningProfileCreationDate
                    ?? existing?.provisioningProfileCreationDate,
                provisioningProfileExpirationDate: installedProfileExpiry,
                signingTargets: existing?.signingTargets ?? [],
                ipaRelativePath: files.ipaRelativePath,
                signedIPARelativePath: nil,
                preferredBundleIdentifier: metadata.bundleIdentifier,
                preferredIconRelativePath: existing?.preferredIconRelativePath,
                isSeal: true,
                isPinned: true,
                importedAt: existing?.importedAt ?? Date(),
                extensions: installedExtensions
            )
            try await appStore.save(record)

        } catch {
            // 9. 失败回滚：取消暂存，旧文件不受影响
            try? await fileStore.cancel(staged)
            throw error
        }
    }

    // MARK: - 自替换启动对账：只确认/关闭事务，绝不发起安装

    /// 消费上一次启动留下的自替换事务。返回值表示是否发生了结算（记录被推进），
    /// 调用方在结算后必须重新读取记录，避免用旧快照覆盖刚确认的真实身份。
    @discardableResult
    private func reconcileSelfReplacement(
        existing: AppRecord?,
        accounts: [AppleAccountRecord],
        allRecords: [AppRecord]
    ) async throws -> Bool {
        guard let selfReplacement else { return false }
        switch try await selfReplacement.reconcileAtLaunch() {
        case .none, .awaitNextLaunch:
            return false
        case .closeAsNotInstalled:
            try await selfReplacement.closeAsNotInstalled()
            await settlePendingBatchSealResult(to: .failed)
            // ⚠️ **必须把记录拉回设备现实**（2026-09-25，构建 38 真机）。
            //
            // 自更新路径在**签名阶段**把 profile 相关写进 `pendingSignedSnapshot` 草稿。
            // 而这里刚刚确认「候选没落盘」⇒ 设备上 Seal 用的还是**旧 profile**。
            //
            // ⚠️ 判据必须由调用方**显式**给出（`candidateConfirmedNotInstalled: true`），
            //    不能指望结算函数自己从版本号推出来：**同版本**续签的自更新失败时，
            //    记录版本与运行包版本**完全相同**，那条「有待安装源且版本不一致」的回滚判据
            //    恒为 false ⇒ 草稿会被当成有效真相转正，记录停在一个设备上不存在的有效期。
            //    而这个分支**已经明确知道**候选没装成，所以要直接告诉结算，别让它猜。
            //
            // 不拉回来，维护作业第 4 步的 `AppMaintenanceJob.profileKeepMap` 就会拿这份
            // 错位记录当「必须保留的那一份」，把设备上**正在用的旧 profile** 判成旧账删掉
            // ⇒ Seal 当场打不开、「VPN 与设备管理」里的描述文件消失。
            // 真机正是这个现象（01:46:30 判失败，01:46:50 维护作业删除 1 份）。
            if let existing {
                do {
                    try await reconcileSealRecordFromRunningBundleIfNeeded(
                        existing: existing,
                        metadata: metadata,
                        accounts: accounts,
                        candidateConfirmedNotInstalled: true
                    )
                } catch {
                    // 回补失败不阻断启动：`AppMaintenanceJob.profileKeepMap` 对 Seal 那条
                    // 只信运行时值（读不到就不进保留集合），是这条链路的最后一道防线。
                    // 但必须留痕 —— 记录错位期间任何「按记录清理」的判断都不可信。
                    try? await logStore?.append(
                        category: .installation,
                        level: .error,
                        message: "自替换结算：无法按运行中的 Bundle 回补记录（\(error)），记录可能与设备现实不一致。",
                        code: "SEAL-SELF-115"
                    )
                }
            }
            try? await logStore?.append(
                category: .installation,
                level: .warning,
                message: "自替换结算：仍在安装前身份，候选未落盘；事务已关闭，本轮不记为成功。已按运行中的 Bundle 回补记录（描述文件 / 证书序列号 / 安装状态），避免用签名阶段的乐观值参与后续清理。",
                code: "SEAL-SELF-111"
            )
            // ⚠️ 必须返回 `true`：上面**确实推进了记录**（回补），而调用方只有拿到 `true`
            //    才会重读记录 —— 否则它手上那份**旧快照**（还带着刚被丢弃的
            //    `pendingSignedSnapshot`）会继续往下走，被后面几轮对账原样写回库
            //    ⇒ 刚丢弃的候选身份又复活（同版本续签时尤其致命：版本判据分辨不出来）。
            //    返回值的契约见 `reconcileSelfReplacement` 的说明：它是
            //    「是否发生了结算（记录被推进）」，**不是**「本轮是否算成功」——
            //    后者已经由上面的 `settlePendingBatchSealResult(to: .failed)` 表达。
            return true
        case .requireRecovery(let reason):
            try await selfReplacement.requireRecovery(reason: reason)
            try? await logStore?.append(
                category: .installation,
                level: .error,
                message: "自替换结算：需要恢复（\(reason)）；已保留事务，不会把本轮记为成功。",
                code: "SEAL-SELF-112"
            )
            return false
        case .settle:
            let settled = try await selfReplacement.settle()
            if let existing {
                let recordToPromote = SelfAppRecordSelection.importedReplacement(
                    for: existing,
                    in: allRecords
                ) ?? existing
                try await atomicallyApplyInstalledIdentity(
                    settled.installedIdentity,
                    to: recordToPromote,
                    accounts: accounts
                )
            } else {
                // The device confirms the new Seal identity, but device reconciliation may
                // already have removed every local predecessor. Rebuild the installed row
                // from the running bundle before declaring the update or batch renewal done.
                try await atomicallyUpdateSealRecord(
                    id: fixedSealID,
                    existing: nil,
                    accounts: accounts
                )
            }
            // A confirmed runtime identity is not a completed user operation until its
            // durable AppStore row has also been committed.
            await settlePendingBatchSealResult(to: .completed)
            if let main = settled.installedIdentity.mainTarget {
                let expiry = SealLogTextFormatter.diagnosticTimestamp(main.profileExpirationDate)
                let measuredDuration: TimeInterval?
                if let startedAt = settled.transactionStartedAtSystemUptime,
                   let endedAt = settled.installedIdentityReadAtSystemUptime,
                   endedAt >= startedAt {
                    measuredDuration = endedAt - startedAt
                } else {
                    measuredDuration = nil
                }
                let summary = RenewalRoundSummary.sealUpdate(
                    startedAt: settled.transactionStartedAt,
                    endedAt: settled.installedIdentityReadAt,
                    expirationDate: main.profileExpirationDate,
                    measuredDuration: measuredDuration
                )
                try? await logStore?.append(
                    category: .installation,
                    message: "自替换结算确认：运行包身份与候选一致；Bundle=\(main.bundleIdentifier)，描述文件 \(main.profileUUID)，到期 \(expiry)，证书末尾 …\(main.signerSerialNumber.suffix(8))",
                    code: "SEAL-SELF-113",
                    operationResult: .success,
                    operationSummary: summary
                )
            }
            // 先推进记录，再精准清理：清理发生时记录必须已指向候选身份，
            // 清理失败只进事务审计，不回滚已确认的安装身份。
            //
            // `protectedBundleIDs` 是这条路径**唯一**能保护其它 App 扩展的东西 ——
            // 它的保留集合只有 Seal 自己一个条目，别的 ID 全是候选，而扩展的设备端核验
            // 恒为「没装」⇒ 不保护就会被删。见 `ProfileCleanupRequest` 的说明。
            let request = ProfileCleanupRequest(
                transactionID: settled.transactionID,
                bundleIdentifier: settled.mainBundleIdentifier,
                keepingProfileUUID: settled.mainProfileUUID,
                installedIdentityReadAt: settled.installedIdentityReadAt,
                protectedBundleIDs: ProfileReclaimPolicy.protectedBundleIDs(records: allRecords)
            )
            let cleanup = await profileCleaner?.removeStaleProfiles(request)
                ?? ProfileCleanupSummary(stage: "skipped-no-cleaner")
            // 自替换结算清理是**唯一**会回收 Seal 自己那份堆积的路径 —— Seal 的自更新
            // 不走 `installSignedIPA`，所以「安装后旧描述文件清理」那条根本轮不到它。
            // 而它原先只把摘要写进事务审计、**不写日志**：真机上 Seal 堆了 16 份旧 profile，
            // 日志里却完全查不出这条清理到底跑没跑、是不是被判成了身份已变化。
            // 事务审计只在 App 内部可读，排障时拿到的只有日志 —— 所以必须同时落日志。
            try? await logStore?.append(
                category: .installation,
                message: "自替换结算清理：\(cleanup.logMessage)",
                code: "SEAL-PROFILE-322"
            )
            try await selfReplacement.finishCleanup(cleanup)
            return true
        }
    }

    private func settlePendingBatchSealResult(to state: BatchRefreshSession.Item.State) async {
        guard let pendingBatchResultStore else { return }
        do {
            let settled = try await pendingBatchResultStore.settleSeal(to: state)
            guard settled.isEmpty == false else { return }
            _ = try await refreshQueueStore?.recoverInterrupted(settled: settled)
            let conclusion = state == .completed ? "成功" : "失败"
            try? await logStore?.append(
                category: .renewal,
                message: "批量续签：Seal 已由新进程身份核验结算为\(conclusion)",
                code: "SEAL-RENEW-028",
                operationResult: state == .completed ? .success : .failure
            )
        } catch {
            try? await logStore?.append(
                category: .renewal,
                level: .warning,
                message: "批量续签：Seal 自替换结算未能写回结果，稍后将按未知项提示核验",
                code: "SEAL-RENEW-029"
            )
        }
    }

    /// 把结算确认的真实运行身份写入 Seal 记录：真实 signer 序列号、主 profile UUID、
    /// Team 与到期时间全部来自 `InstalledIdentity.mainTarget`，不读描述文件授权列表第一项。
    private func atomicallyApplyInstalledIdentity(
        _ identity: InstalledIdentity,
        to existing: AppRecord,
        accounts: [AppleAccountRecord]
    ) async throws {
        guard let main = identity.mainTarget else { return }
        var updated = existing
        // 两阶段确认：先转正 pending（拿 signingTargets，Mach-O 读不到它），
        // 再用 Mach-O 真值覆盖标量字段（运行中的身份是最终可信源）。
        // 不一致时（自更新失败回滚）：pending 是旧包的草稿，照样转正拿 targets，
        // 标量会被下面 Mach-O 真值覆盖，结果正确。
        updated.commitPendingSnapshot()
        // 运行中的 Mach-O 身份是最终可信源，直接写顶层。
        updated.certificateSerialNumber = main.signerSerialNumber
        updated.provisioningProfileUUID = main.profileUUID
        updated.provisioningProfileExpirationDate = main.profileExpirationDate
        updated.expiryDate = main.profileExpirationDate
        updated.signingTeamID = main.teamIdentifier
        updated.state = .installed
        updated.signedArtifactStatus = .installed
        updated.installedAppMarkerVersion = Bundle.main.bundleIdentifier.flatMap { bundleIdentifier in
            SealInstalledAppMarker.isDeclared(for: bundleIdentifier) ? SealInstalledAppMarker.version : nil
        }
        updated.accountID = SelfAppAccountBinding.resolvedAccountID(
            teamIdentifier: main.teamIdentifier,
            accounts: accounts,
            fallbackAccountID: existing.accountID
        )
        // 自替换安装已确认生效 ⇒ 待安装的更新源指纹清掉：它是自愈的，
        // 下一次续签准入不再把它当成「有待安装更新」（否则同版本更新会每次续签都重装）。
        // 注意 `hasPendingSelfUpdateSource` 在这里刻意不清 —— 自替换走不到
        // SigningCoordinator 的普通安装路径，那个标志的语义是「导入过自更新源」，
        // 由 `SelfAppRegistrar` 的待安装分支按版本/文件存在性解读。
        // 安装的是待安装的包 ⇒ 把它的指纹记为已装指纹，下次导入同一包时不重复提示。
        if let pending = updated.pendingUpdateSourceFingerprint {
            updated.installedFingerprint = pending
        }
        updated.pendingUpdateSourceFingerprint = nil
        if let replacedID = updated.replacesInstalledAppID {
            updated.replacesInstalledAppID = nil
            try await appStore.commitInstalledReplacement(updated, replacing: replacedID)
        } else {
            try await appStore.save(updated)
        }
    }

    // MARK: - 清理重复的 Seal 记录

    private func cleanupDuplicateSealRecords(
        records: [AppRecord],
        keepID: UUID
    ) async throws {
        // 删除决定必须按**执行时刻的现行记录**做，不能用入参这份快照：三个调用点
        // （待更新保护 / 版本一致 / 原子更新后）传的都是 `registerIfNeeded` 开头
        // 抓的 `records`，中间隔着自替换对账、回补与打包等步骤 —— 快照里已不存在
        // 的记录会被重复尝试删除，快照之后才出现的记录（尤其是刚导入的待更新
        // 记录）则完全不在视野里。重取失败时整轮不删（fail closed：跳过清理只
        // 留下残留，误删会连文件一起删掉用户尚未签名的更新包）。
        // 豁免判据与待更新保护分支同源：`replacesInstalledAppID != nil` 的记录
        // 在其指向的更新结算完成前一律不删（结算会把该链接清掉，见
        // `SelfAppPendingUpdateProtection`）。
        guard let currentRecords = try? await appStore.fetchAll() else { return }
        for record in SelfAppPendingUpdateProtection.duplicateCleanupCandidates(
            in: currentRecords,
            keepID: keepID
        ) {
            // 先删除文件，再删除数据库记录，避免产生孤儿文件
            try? await fileStore.removeApp(appID: record.id)
            try? await appStore.delete(id: record.id)
        }
    }

    /// 版本一致时的轻量回补：从**当前运行包**回补 Team/账号绑定与 profile 身份，不重打包 IPA。
    ///
    /// 为什么不能只看版本（R07）：同版本续签会换掉 profile（新 UUID、新有效期）但**版本号不变**。
    /// 旧实现在这个分支只回补 Team/账号就 `return`，于是数据库里的有效期始终停留在
    /// 「安装前乐观写入」的那一份 —— 一旦那次自更新实际失败（或进程在安装中被系统杀掉），
    /// UI 会显示一个设备上并不存在的有效期，用户直到应用被吊销都收不到提醒。
    ///
    /// **运行中的 Bundle 才是唯一可信证据**：它要么是新包（续签生效，读到新 profile），
    /// 要么是旧包（续签失败，读到旧 profile）。因此这里按 profile 身份结算，而不是按版本号。
    /// - Parameter candidateConfirmedNotInstalled: 调用方**已经确认**「这次自更新的候选包
    ///   没有落到设备上」（目前只有 `.closeAsNotInstalled` 一种）。默认 `false`：
    ///   其余调用点只是「顺手对一次账」，并不知道候选的去向。
    private func reconcileSealRecordFromRunningBundleIfNeeded(
        existing: AppRecord,
        metadata: SelfAppMetadata,
        accounts: [AppleAccountRecord],
        candidateConfirmedNotInstalled: Bool = false
    ) async throws {
        let resolvedTeamID = metadata.signingTeamIdentifier ?? existing.signingTeamID
        let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
            teamIdentifier: resolvedTeamID,
            accounts: accounts,
            fallbackAccountID: existing.accountID
        )

        var updated = existing
        var changed = false
        let candidateIsOffDevice = candidateConfirmedNotInstalled
            || (existing.hasPendingSelfUpdateSource && existing.version != metadata.version)
        // 本函数的 metadata 来自正在运行的 Bundle.main；pending 自更新源只表示
        // 有新源包等待安装，不改变 Seal 当前确实已安装并运行这一事实。
        if updated.state != .installed {
            updated.state = .installed
            changed = true
        }

        if existing.signingTeamID != resolvedTeamID {
            updated.signingTeamID = resolvedTeamID
            changed = true
        }
        if existing.accountID != resolvedAccountID {
            updated.accountID = resolvedAccountID
            changed = true
        }

        if let extensionRecords = metadata.extensionRecords {
            let reconciledExtensions = SelfAppRegistrar.reconcileExtensionRecords(
                extensionRecords,
                preservingIDsFrom: existing.extensions,
                adoptingRuntimeProfileIdentity: candidateIsOffDevice
            )
            if updated.extensions != reconciledExtensions {
                updated.extensions = reconciledExtensions
                changed = true
            }
        }

        // ── 两阶段确认：pending 的去留由「候选到底在不在设备上」决定 ──
        //
        // ① 调用方**显式声明**候选已确认没落盘（`.closeAsNotInstalled`：启动自替换对账
        //    刚把这次自更新判死）。这是**唯一**能覆盖「同版本」的判据 ——
        //    同版本续签的自更新失败时 `version` 与运行包完全相同，下面那个版本比较恒为 false，
        //    光看版本号分辨不出来 ⇒ 签名阶段写下的候选身份会被 `commitPendingSnapshot()`
        //    转正，记录从此显示一个设备上并不存在的有效期（用户直到被吊销都收不到提醒）。
        // ② 有待安装源且记录版本 ≠ 运行版本（自更新失败，仍在跑旧包）。
        //
        // 两者任一成立 ⇒ 候选不在设备上：丢弃 pending、以运行包的真实身份为准。
        // 否则 pending 是有效的新真相，转正。
        // 这替代了旧的 `versionMismatch` 守卫：profile-only 续签后设备有新 profile
        // 但运行包内嵌旧 profile，非回滚时不再用旧值回盖新记录。
        // 把运行包里读到的 profile 身份收进记录（就地），返回是否真的改动过。
        func adoptRunningBundleProfileIdentity() -> Bool {
            var adopted = false
            if let uuid = metadata.provisioningProfileUUID,
               uuid != updated.provisioningProfileUUID {
                updated.provisioningProfileUUID = uuid
                adopted = true
            }
            if let name = metadata.provisioningProfileName,
               name != updated.provisioningProfileName {
                updated.provisioningProfileName = name
                adopted = true
            }
            if let creationDate = metadata.provisioningProfileCreationDate,
               creationDate != updated.provisioningProfileCreationDate {
                updated.provisioningProfileCreationDate = creationDate
                adopted = true
            }
            if let expiry = metadata.expirationDate,
               expiry != updated.expiryDate || expiry != updated.provisioningProfileExpirationDate {
                updated.expiryDate = expiry
                updated.provisioningProfileExpirationDate = expiry
                adopted = true
            }
            return adopted
        }

        // 运行包报出的 profile 身份是否**权威到可以回盖记录里那份**。
        //
        // ① 运行包的有效期更晚 ⇒ 设备上这份比记录知道的更晚签（续签只会把有效期往后推）。
        //    R07 的典型：用户在别处重新签了 Seal 再装回来，版本号没变 ⇒ 只比版本号看不出来。
        // ② 反向（记录更晚、运行包更早）**默认不动** —— profile-only 续签只注入新描述文件、
        //    不重装 App，`Bundle.main` 里仍是旧的 embedded profile，回盖会把刚续的 profile 打回原地。
        //    唯一的例外是「记录里那份还没被确认落到设备上」：**存在待安装的自更新源**
        //    （导入过自更新源但没装成）时，那份新身份只存在于签名产物里，设备上并没有。
        //    旧模型「签名阶段乐观推进顶层」留下的错位记录（自更新失败、版本号没变的那种）
        //    也只能靠这条自愈 —— 否则它会一直显示一个设备上不存在的有效期。
        func runningBundleProfileIdentityIsAuthoritative() -> Bool {
            guard let runningUUID = metadata.provisioningProfileUUID,
                  runningUUID != existing.provisioningProfileUUID else { return false }
            guard let runningExpiry = metadata.expirationDate else { return false }
            guard let recordedExpiry = existing.provisioningProfileExpirationDate ?? existing.expiryDate else {
                // 记录里没有有效期可比 ⇒ 采纳运行包不会让 UI 退化成「无到期日」。
                return true
            }
            if runningExpiry > recordedExpiry { return true }
            return existing.hasPendingSelfUpdateSource
        }

        if existing.pendingSignedSnapshot != nil {
            if candidateIsOffDevice {
                updated.discardPendingSnapshot()
                changed = true
            } else {
                updated.commitPendingSnapshot()
                changed = true
            }
        }
        // 运行包（= 设备现实）最后覆盖标量身份：无论上面是「丢弃草稿」还是「转正草稿」，
        // 落库的 `provisioningProfile*` / `expiryDate` 都必须描述设备上真正在跑的那一份。
        // `signingTargets` 不在这里覆盖 —— 它来自草稿（Mach-O 读不到），是产物的账本。
        if candidateIsOffDevice || runningBundleProfileIdentityIsAuthoritative(),
           adoptRunningBundleProfileIdentity() {
            changed = true
        }

        // ── 证书序列号：同版本续签可能换证书，只能以运行包真实 CMS 签名者为准回补 ──
        // 描述文件授权证书列表不是实际签名者；身份读取失败时保留既有记录，
        // 避免前置清理误撤 Seal 在用的证书（2026-09-15 真机确认）。
        let resolvedCertSerial = metadata.installedIdentity?.mainTarget?.signerSerialNumber
            ?? existing.certificateSerialNumber
        if existing.certificateSerialNumber != resolvedCertSerial {
            updated.certificateSerialNumber = resolvedCertSerial
            changed = true
        }

        // 成品目标独立保留；旧包重启只能纠正安装快照，不能把待安装成品标成已安装。
        if existing.signedIPARelativePath != nil,
           let runningProfileUUID = metadata.provisioningProfileUUID,
           let target = existing.signingTargets.first(where: {
               $0.bundleIdentifier == metadata.bundleIdentifier
           }), let targetProfileUUID = target.profileUUID {
            let status: SignedArtifactStatus = targetProfileUUID.caseInsensitiveCompare(runningProfileUUID) == .orderedSame
                ? .installed : .awaitingVerification
            if existing.signedArtifactStatus != status {
                updated.signedArtifactStatus = status
                changed = true
            }
        }

        // version / buildNumber **不在这里对齐**：它们是 AppRecord 的 `let` 常量。
        // 版本变化时走的是 `atomicallyUpdateSealRecord`（用运行包重打包并整体重建记录），
        // 本函数只在「版本一致」分支被调用，因此不存在「DB 版本 ≠ 运行版本」的窗口。

        guard changed else { return }
        try await appStore.save(updated)
    }

    private static func reconcileExtensionRecords(
        _ runtimeExtensions: [AppExtensionRecord],
        preservingIDsFrom existingExtensions: [AppExtensionRecord],
        adoptingRuntimeProfileIdentity: Bool = false
    ) -> [AppExtensionRecord] {
        runtimeExtensions.map { runtime in
            let runtimeBundleID = (runtime.mappedBundleIdentifier ?? runtime.originalBundleIdentifier).lowercased()
            let existing = existingExtensions.first {
                ($0.mappedBundleIdentifier ?? $0.originalBundleIdentifier).lowercased() == runtimeBundleID
            }
            guard let existing else { return runtime }
            return AppExtensionRecord(
                id: existing.id,
                name: runtime.name,
                originalBundleIdentifier: existing.originalBundleIdentifier,
                mappedBundleIdentifier: runtime.mappedBundleIdentifier,
                kind: runtime.kind,
                provisioningProfileUUID: adoptingRuntimeProfileIdentity
                    ? runtime.provisioningProfileUUID : existing.provisioningProfileUUID ?? runtime.provisioningProfileUUID,
                provisioningProfileName: adoptingRuntimeProfileIdentity
                    ? runtime.provisioningProfileName : existing.provisioningProfileName ?? runtime.provisioningProfileName,
                provisioningProfileExpirationDate: adoptingRuntimeProfileIdentity
                    ? runtime.provisioningProfileExpirationDate : existing.provisioningProfileExpirationDate ?? runtime.provisioningProfileExpirationDate,
                certificateSerialNumber: adoptingRuntimeProfileIdentity
                    ? runtime.certificateSerialNumber : existing.certificateSerialNumber ?? runtime.certificateSerialNumber
            )
        }
    }
}
