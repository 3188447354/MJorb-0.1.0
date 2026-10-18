import Foundation

/// 设备端一份描述文件的**只读摘要** —— 扫回的唯一输入。
///
/// 由 `DeviceInstalledAppScanner` 从 `Provision.dumpProfiles` 的产物解析出来，
/// **不落盘**、只在本轮内存里活着。刻意只留「重建一条记录必须的那几项」：
/// 多解析一个字段就多一份在真机上崩的机会，而扫回是个「有就用、没有就算了」的功能。
///
/// ⚠️ `bundleIdentifier` 是**非可选**的：扫描器只会把解析出非空 Bundle ID 的
/// 描述文件放进来，所以「没有 Bundle ID」这一态在类型上就不存在 —— 别在消费端
/// 再写一次 `?? ""` 或可选链，那只会掩盖真正的漏筛。
struct DeviceProvisioningProfileSummary: Equatable, Sendable {
    let bundleIdentifier: String
    let teamIdentifier: String?
    let uuid: String?
    let name: String?
    let creationDate: Date?
    let expirationDate: Date?
}

/// 设备端扫回的结果摘要。
///
/// `stage` 的取值就是「为什么一条都没补」的答案 —— 不留这个字段，
/// 「扫回 0」和「根本没扫」在日志上分不开，而这两件事该看的下一处完全不同。
struct InstalledRecordRecoverySummary: Equatable, Sendable {
    /// 本地描述文件筛出来的候选份数。
    var candidates = 0
    /// 真正补回已安装列表的记录数。
    var recovered = 0
    /// 候选里「设备上其实没装」而跳过的份数。
    var notInstalled = 0
    /// `done` / `skipped-*` / `failed-*`。
    var stage = "done"
    var firstError: String?
    var samples: [String] = []

    /// 是否值得写日志：**没有候选就不写**。每次启动都留一条「扫了 0 个」
    /// 只会把真实信号挤出环形缓冲（本仓已有的教训，见 R12 轮询降噪）。
    var shouldLog: Bool {
        candidates > 0 || recovered > 0 || stage.hasPrefix("failed")
    }

    var logMessage: String {
        var text = "设备端扫回已安装应用：候选 \(candidates)，补回 \(recovered)，"
            + "设备上未安装 \(notInstalled)，阶段 \(stage)"
        if let firstError {
            text += "，首个错误 \(firstError)"
        }
        if samples.isEmpty == false {
            text += "，示例 \(samples.joined(separator: "、"))"
        }
        return text
    }
}

/// 「用户主动从已安装列表移除过」的 Bundle ID 墓碑。
///
/// ## 为什么必须有它
///
/// 扫回会把「设备上装着、记录里没有」的 Seal 签名应用补回列表；而删除记录
/// **明确不卸载设备上的应用**（删除确认文案：「删除后将从 Seal 的已安装列表中移除，
/// 不会卸载手机上的应用」）。少了墓碑，用户删一次、下次启动又回来一次，永远删不掉。
///
/// ## 为什么是文件而不是 `UserDefaults`
///
/// Seal 自签覆盖安装会丢 `UserDefaults`（本仓已有实证，见
/// `persistPendingBatchResultForSealUpdate` 的双保险注释）；墓碑一丢，
/// 被删掉的记录下次启动就自己回来了。所以落成与其它状态文件同目录的 JSON。
///
/// ## 目录只有一处出处
///
/// `defaultFileURL()` 复刻 `AppContainer` 解析 `sealDirectory` 的方式
/// （`applicationSupport + AppConfiguration.Paths.applicationSupportSubdirectory`）。
/// 这是**唯一**一处推导，两个调用点（`AppRecordRecovery` 读、`AppsViewModel.delete` 写）
/// 都走它，所以不存在「读的是一份、写的是另一份」这种漂移。
///
/// 读写都**最佳努力**，且读失败按空集：宁可按「没删过」处理（只是多一条记录），
/// 也不能按「全删过」处理 —— 那会让扫回静默失效，用户永远等不到他的应用回来。
enum DismissedInstalledRecordTombstones {
    static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(
                path: AppConfiguration.Paths.applicationSupportSubdirectory,
                directoryHint: .isDirectory
            )
            .appending(path: AppConfiguration.Paths.dismissedInstalledRecordsFile)
    }

    static func all(fileURL: URL? = nil) -> Set<String> {
        guard let url = fileURL ?? defaultFileURL(),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values.map(InstalledRecordRecoveryPolicy.normalizedBundleIdentifier))
    }

    @discardableResult
    static func insert(_ bundleIdentifiers: [String], fileURL: URL? = nil) -> Set<String> {
        var current = all(fileURL: fileURL)
        let added = bundleIdentifiers
            .map(InstalledRecordRecoveryPolicy.normalizedBundleIdentifier)
            .filter { $0.isEmpty == false }
        guard added.isEmpty == false else { return current }
        current.formUnion(added)
        guard let url = fileURL ?? defaultFileURL(),
              let data = try? JSONEncoder().encode(current.sorted()) else {
            return current
        }
        try? data.write(to: url, options: .atomic)
        return current
    }
}

/// 扫回的纯逻辑：把「设备端描述文件摘要 ＋ 现有记录 ＋ 账号」折成待重建的记录草稿。
///
/// ## 背景（2026-09-25 用户反馈）
///
/// 「只卸载了 Seal，其他应用没卸载，重装 Seal 后它们进不了已安装列表」——
/// 记录（`Seal.sqlite`）随 Seal 一起没了，设备上的应用却还在。扫描设备上的描述文件，
/// 根据真实 Bundle ID、可信 Team 和设备安装状态恢复记录，不依赖签名工具的 ID 格式。
///
/// ## 五条纪律
///
/// 1. **不按命名格式筛选**：Seal、AltStore、SideStore 或用户自定义的有效 Bundle ID，
///    都按设备描述文件里的实际值识别；Team 只用于确认账号归属，不参与拼 ID。
/// 2. **身份必须诚实**：重建的记录**没有本地 IPA**（文件从未存在过），所以
///    `signedIPARelativePath` / `signedIPASHA256` 留空、`signedArtifactStatus` 留 nil。
///    于是 `hasSignedArtifact == false` ⇒ 天然进不了 profile-only 续签、也进不了
///    「安装已签名产物」路径 —— 与事实一致。填假值会让下游拿不存在的文件去签名。
///    **证书序列号同样留空**，理由见 `makeRecord` 里那段。
/// 3. **本策略只做本地筛选**，产出的只是候选。「到底装没装」必须由会抛错的
///    `Minimuxer.isAppInstalled` 回答（见 `DeviceInstalledAppScanner`）——
///    少一次设备核验，就会给「已从设备删掉、profile 还留着」的 App 造出僵尸记录。
/// 4. **Team 必须可信**：设备上 dump 出来的是**全部**描述文件，含别的工具、旧账号
///    留下的（真机实测过 39 个 Bundle ID 变体 / 33 份孤儿）。Team 是唯一能证明
///    「这份 profile 属于当前这批账号/记录」的证据。
/// 5. **必须排在设备端旧描述文件清理之前**（`AppMaintenanceJob` 第 1 步 vs 第 4 步）。
///    新补回的记录是那份 profile 唯一的本地引用；反过来的顺序会让第 4 步把它的
///    profile 当旧账删掉 —— 而设备上的 App 正靠那份 profile 运行，当场打不开。
///
/// 抽成纯函数是因为它的错法**不崩、不编译失败，只在真机上多造或少造记录** ——
/// 只能靠单测 + 守卫断言钉住。
enum InstalledRecordRecoveryPolicy {
    struct InstalledAppDraft: Equatable, Sendable {
        let bundleIdentifier: String
        let teamIdentifier: String?
        let profileUUID: String?
        let profileName: String?
        let profileCreationDate: Date?
        let profileExpirationDate: Date?
        let displayName: String
        let version: String
        let buildNumber: String
    }

    /// 一条待重建记录的草稿。
    struct Draft: Equatable, Sendable {
        let bundleIdentifier: String
        let originalBundleIdentifier: String
        let teamIdentifier: String
        let profileUUID: String?
        let profileName: String?
        let profileCreationDate: Date?
        let profileExpirationDate: Date?
        let displayName: String
    }

    /// 本轮扫回的判据参数。
    ///
    /// ⚠️ **归一化放在 `init` 里，不靠调用方记得**：`drafts()` 是拿「设备端描述文件里的
    /// Bundle ID」去查这两张表的 —— 那个值来自 Apple，Team 段是**大写**（`ABCDE12345`），
    /// 而查询侧一律按小写比较。调用方漏归一化一次，`known` / `dismissed` 两条闸门就
    /// **一条都筛不掉**（静默多建记录），而这两条闸门恰恰是「不重复建」「不把用户删掉的
    /// 捞回来」的唯一保障。
    ///
    /// 2026-09-25 实测踩到：单测里手搓 `Context` 时传了原始值，`skipsBundleIdentifier
    /// AlreadyCoveredByARecord` / `respectsDismissedTombstones` 两条用例直接红 ——
    /// 文档写着「已归一化」，但没有任何东西**强制**它。现在由类型自己保证。
    struct Context: Equatable, Sendable {
        /// 已有记录里出现过的生效 Bundle ID（含扩展）。已覆盖的一律不再重建。
        let knownBundleIdentifiers: Set<String>
        /// 可信 Team：已添加账号的 TeamID ＋ 已有记录的 `signingTeamID`。
        let knownTeamIdentifiers: Set<String>
        /// 用户主动从已安装列表移除过的 Bundle ID。
        let dismissedBundleIdentifiers: Set<String>
        /// Seal 自己的规范 Bundle ID（`com.mjorb.seal`）。
        let sealCanonicalBundleIdentifier: String

        init(
            knownBundleIdentifiers: Set<String>,
            knownTeamIdentifiers: Set<String>,
            dismissedBundleIdentifiers: Set<String>,
            sealCanonicalBundleIdentifier: String
        ) {
            self.knownBundleIdentifiers = Set(
                knownBundleIdentifiers.map { InstalledRecordRecoveryPolicy.normalizedBundleIdentifier($0) }
            )
            self.knownTeamIdentifiers = Set(
                knownTeamIdentifiers.compactMap {
                    InstalledRecordRecoveryPolicy.normalizedTeamIdentifier($0)
                }
            )
            self.dismissedBundleIdentifiers = Set(
                dismissedBundleIdentifiers.map {
                    InstalledRecordRecoveryPolicy.normalizedBundleIdentifier($0)
                }
            )
            self.sealCanonicalBundleIdentifier = sealCanonicalBundleIdentifier
        }
    }

    /// 扫回记录的统一标识，写进 `importWarnings` —— 签名页会把 `importWarnings`
    /// 列出来，所以这是用户能看见的那一句；守卫也按它断言。
    static let recoveryWarning =
        "此记录由设备端扫回重建，本机没有该应用的原始 IPA；需要重新签名时，请先导入该应用的 IPA。"

    static func normalizedBundleIdentifier(_ value: String) -> String {
        // 「Bundle ID 怎么归一化」只有一处实现（`ProfileReclaimPolicy`），不在这里再抄一遍。
        ProfileReclaimPolicy.normalized(value)
    }

    /// Seal 自己的 ID：规范 ID，或历史上按 Team ID / `.seal.<TeamID>` 生成的自身 ID。
    ///
    /// 扫回必须排除 Seal：它的记录由 `SelfAppRegistrar` 专门管理，
    /// 扫回再造一条只会得到「两条都叫 Seal」的重复记录。
    static func isSealBundleIdentifier(
        _ bundleID: String,
        canonicalBundleIdentifier: String,
        teamIdentifier: String?
    ) -> Bool {
        let value = normalizedBundleIdentifier(bundleID)
        let canonical = normalizedBundleIdentifier(canonicalBundleIdentifier)
        guard canonical.isEmpty == false, value.isEmpty == false else { return false }
        guard value != canonical else { return true }
        guard let team = normalizedTeamIdentifier(teamIdentifier) else { return false }
        let historicalIDs = [canonical + "." + team, canonical + ".seal." + team]
        return historicalIDs.contains { value == normalizedBundleIdentifier($0) }
    }

    static func context(
        records: [AppRecord],
        accountTeamIdentifiers: Set<String>,
        dismissedBundleIdentifiers: Set<String>,
        sealCanonicalBundleIdentifier: String
    ) -> Context {
        var known: Set<String> = []
        var teams: Set<String> = []
        for record in records {
            if let bundleID = ProfileReclaimPolicy.effectiveBundleID(
                mapped: record.mappedBundleIdentifier,
                preferred: record.preferredBundleIdentifier
            ) {
                known.insert(normalizedBundleIdentifier(bundleID))
            }
            if let team = normalizedTeamIdentifier(record.signingTeamID) {
                teams.insert(team)
            }
            // 扩展也算「已覆盖」：扩展不是独立安装的 App，单独建记录只会得到
            // 一条点开就报错的僵尸记录（`isAppInstalled` 对扩展恒为 false）。
            for extensionRecord in record.extensions {
                if let extensionID = ProfileReclaimPolicy.effectiveBundleID(
                    mapped: extensionRecord.mappedBundleIdentifier,
                    preferred: nil
                ) {
                    known.insert(normalizedBundleIdentifier(extensionID))
                }
            }
        }
        for team in accountTeamIdentifiers {
            if let normalized = normalizedTeamIdentifier(team) {
                teams.insert(normalized)
            }
        }
        return Context(
            knownBundleIdentifiers: known,
            knownTeamIdentifiers: teams,
            dismissedBundleIdentifiers: Set(
                dismissedBundleIdentifiers.map(normalizedBundleIdentifier)
            ),
            sealCanonicalBundleIdentifier: sealCanonicalBundleIdentifier
        )
    }

    /// 本地描述文件筛选 —— **不碰设备**。
    static func drafts(
        profiles: [DeviceProvisioningProfileSummary],
        context: Context
    ) -> [Draft] {
        // 不以 `.seal`、团队后缀或其它工具的命名规则筛选。只读取非空 Bundle ID，
        // 并用描述文件 Team 确认归属。LockDown 路径同一份 profile 会落 raw + plist 两份，先去重。
        var candidates: [(profile: DeviceProvisioningProfileSummary, bundleID: String)] = []
        var seen: Set<String> = []
        for profile in profiles {
            let raw = profile.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.isEmpty == false else { continue }
            let normalized = normalizedBundleIdentifier(raw)
            guard let team = normalizedTeamIdentifier(profile.teamIdentifier),
                  context.knownTeamIdentifiers.contains(team) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            candidates.append((profile, raw))
        }
        var drafts: [Draft] = []
        for (profile, bundleID) in candidates {
            let normalized = normalizedBundleIdentifier(bundleID)
            // ① 已经是记录里某个 App / 扩展的生效 Bundle ID ⇒ 不算「缺失」。
            guard context.knownBundleIdentifiers.contains(normalized) == false else { continue }
            // ② 用户主动从列表移除过的 ⇒ 尊重那次删除（见 `DismissedInstalledRecordTombstones`）。
            guard context.dismissedBundleIdentifiers.contains(normalized) == false else { continue }
            // ③ Seal 自己由 `SelfAppRegistrar` 专门管理，不参与扫回。
            guard isSealBundleIdentifier(
                bundleID,
                canonicalBundleIdentifier: context.sealCanonicalBundleIdentifier,
                teamIdentifier: profile.teamIdentifier
            ) == false else { continue }
            // ④ Team 已在本地描述文件筛选阶段与已添加账号 / 记录核对。
            guard let team = normalizedTeamIdentifier(profile.teamIdentifier) else { continue }
            // ⑤ 不从 Bundle ID 前缀猜测扩展关系；后续由设备安装查询确认哪些是独立 App。
            // ⑥ Team 后缀和历史 Seal 后缀可还原原始 ID；其它格式保留设备实际 Bundle ID。
            guard let original = originalBundleIdentifier(
                fromMapped: bundleID,
                teamIdentifier: team
            ) else { continue }

            drafts.append(Draft(
                bundleIdentifier: bundleID,
                originalBundleIdentifier: original,
                teamIdentifier: team,
                profileUUID: profile.uuid,
                profileName: profile.name,
                profileCreationDate: profile.creationDate,
                profileExpirationDate: profile.expirationDate,
                displayName: displayName(forOriginalBundleIdentifier: original)
            ))
        }
        // 稳定顺序：同一轮里「先问设备」的顺序固定，日志才可复现。
        return drafts.sorted {
            $0.bundleIdentifier.lowercased() < $1.bundleIdentifier.lowercased()
        }
    }

    /// Rebuilds records from the actual user-app inventory. InstallationProxy's
    /// ProfileValidated flag is the sideload signal; profile data is attached only
    /// when one unambiguous device profile covers the app.
    static func drafts(
        installedApplications: [DeviceInstalledApplicationSummary],
        profiles: [DeviceProvisioningProfileSummary],
        context: Context
    ) -> [InstalledAppDraft] {
        var seen = Set<String>()
        return installedApplications.compactMap { application in
            let bundleID = application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizedBundleIdentifier(bundleID)
            guard application.profileValidated == true,
                  normalized.isEmpty == false,
                  seen.insert(normalized).inserted,
                  context.knownBundleIdentifiers.contains(normalized) == false,
                  context.dismissedBundleIdentifiers.contains(normalized) == false else {
                return nil
            }

            let matchingProfiles = profiles.filter {
                profile($0, covers: bundleID)
            }
            let matchedProfile = matchingProfiles.count == 1 ? matchingProfiles.first : nil
            let isSeal = isSealBundleIdentifier(
                bundleID,
                canonicalBundleIdentifier: context.sealCanonicalBundleIdentifier,
                teamIdentifier: nil
            ) || matchingProfiles.contains {
                isSealBundleIdentifier(
                    bundleID,
                    canonicalBundleIdentifier: context.sealCanonicalBundleIdentifier,
                    teamIdentifier: $0.teamIdentifier
                )
            }
            guard isSeal == false else { return nil }

            let profileTeam = matchedProfile.flatMap { normalizedTeamIdentifier($0.teamIdentifier) }
            return InstalledAppDraft(
                bundleIdentifier: bundleID,
                teamIdentifier: profileTeam,
                profileUUID: matchedProfile?.uuid,
                profileName: matchedProfile?.name,
                profileCreationDate: matchedProfile?.creationDate,
                profileExpirationDate: matchedProfile?.expirationDate,
                displayName: application.displayName.isEmpty ? bundleID : application.displayName,
                version: application.shortVersion,
                buildNumber: application.buildNumber
            )
        }.sorted { $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending }
    }

    private static func profile(_ profile: DeviceProvisioningProfileSummary, covers bundleIdentifier: String) -> Bool {
        let pattern = normalizedBundleIdentifier(profile.bundleIdentifier)
        let target = normalizedBundleIdentifier(bundleIdentifier)
        guard pattern.isEmpty == false else { return false }
        if pattern == target { return true }
        guard pattern.hasSuffix(".*") else { return false }
        let prefix = String(pattern.dropLast())
        return target.hasPrefix(prefix) && target.count > prefix.count
    }

    static func makeRecord(
        from draft: InstalledAppDraft,
        accountID: UUID?,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> AppRecord {
        AppRecord(
            id: id,
            originalBundleIdentifier: draft.bundleIdentifier,
            mappedBundleIdentifier: draft.bundleIdentifier,
            name: draft.displayName,
            version: draft.version,
            buildNumber: draft.buildNumber,
            size: 0,
            iconRelativePath: nil,
            state: .installed,
            expiryDate: draft.profileExpirationDate,
            accountID: accountID,
            signingTeamID: draft.teamIdentifier,
            certificateSerialNumber: nil,
            signedDeviceIdentifier: nil,
            provisioningProfileUUID: draft.profileUUID,
            provisioningProfileName: draft.profileName,
            provisioningProfileCreationDate: draft.profileCreationDate,
            provisioningProfileExpirationDate: draft.profileExpirationDate,
            lastInstalledAt: nil,
            signingTargets: [],
            ipaRelativePath: "Apps/\(id.uuidString)/Original.ipa",
            signedIPARelativePath: nil,
            signedIPASHA256: nil,
            signedArtifactStatus: nil,
            preferredBundleIdentifier: draft.bundleIdentifier,
            needsIPAImport: true,
            preferredDisplayName: nil,
            isSeal: false,
            isPinned: false,
            importedAt: now,
            extensions: [],
            importWarnings: [recoveryWarning]
        )
    }

    /// Team 后缀 `<原始>.<team>` 和旧 Seal 格式 `<原始>.seal.<team>` 还原为原始 ID；
    /// 其它格式原样保留。
    ///
    /// 只有描述文件中可信 Team 与 ID 的末尾完全匹配时才剥离一次；其它 ID 保留设备实际值。
    static func originalBundleIdentifier(
        fromMapped mapped: String,
        teamIdentifier: String?
    ) -> String? {
        let value = mapped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return nil }
        if let team = normalizedTeamIdentifier(teamIdentifier) {
            let suffixes = [ProfileReclaimPolicy.sealGeneratedMarker + team, "." + team]
            for suffix in suffixes where value.lowercased().hasSuffix(suffix.lowercased()) {
                let stripped = String(value.dropLast(suffix.count))
                return stripped.isEmpty ? value : stripped
            }
        }
        return value
    }

    /// 展示名。
    ///
    /// **拿不到真实应用名**：`Minimuxer.lookupApp` 只回 Bundle ID
    /// （`bridge_idevice.rs` 的 `lookup_app_rppairing` 就是
    /// `apps.contains_key(&bundle_id).then_some(bundle_id)`），而描述文件的 `Name`
    /// 是 Apple 按 `<映射后的 Bundle ID>` 生成的，同样不是应用名。
    ///
    /// ⇒ 用设备实际 Bundle ID：不会把工具自己的映射标记误当成应用名。
    static func displayName(forOriginalBundleIdentifier original: String) -> String {
        original
    }

    /// 把草稿折成最终记录。`installedOnDevice == false` 时返回 `nil`（**不建记录**）。
    static func makeRecord(
        from draft: Draft,
        installedOnDevice: Bool,
        accountID: UUID?,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> AppRecord? {
        guard installedOnDevice else { return nil }
        return AppRecord(
            id: id,
            originalBundleIdentifier: draft.originalBundleIdentifier,
            // 设备上**实际**的 Bundle ID。必须填：`BundleIDPolicy.targetBundleIdentifier`
            // 对 `.installed` / `requiresLockedSigningIdentity` 会锁到 mapped，
            // 缺了它点续签会直接抛 `SEAL-BUNDLE-002`（「续签记录不完整」）。
            mappedBundleIdentifier: draft.bundleIdentifier,
            name: draft.displayName,
            // 版本 / 构建号 / 体积都拿不到（同上：lookup 只回 Bundle ID）。
            // 空串而不是编造值 —— 详情页会显示成 `v · 0 B`，不好看，
            // 但不会让人以为那个版本号是真的。
            version: "",
            buildNumber: "",
            size: 0,
            iconRelativePath: nil,
            state: .installed,
            expiryDate: draft.profileExpirationDate,
            accountID: accountID,
            signingTeamID: draft.teamIdentifier,
            // ⚠️ **证书序列号留空，即使描述文件里恰好只授权一张证书。**
            //
            // 理由不是「懒得填」，是**填了会骗人**：这个字段在本仓的含义是
            // 「**实际签名者**的序列号」，而描述文件里的 `DeveloperCertificates`
            // 是**授权列表** —— 本仓已明文区分这两件事（见
            // `ProfileReclaimPolicy` / `DeviceProfileInspector` 的相关注释）。
            //
            // 而它一旦有值，会立刻被两处破坏性链路选中：
            // ① `SigningCoordinator.appsAffectedByCertificateRotation` ⇒ 证书轮换时
            //    把这条记录排进「自动重签」，而它没有本地 IPA ⇒ 必然抛
            //    `SEAL-RECOVER-002`，事务里多一条「恢复失败」的错误日志；
            // ② `revokeKeylessCertificateAfterConfirmation` 的 `affectedInstalledApps`
            //    ⇒ 确认弹窗会告诉用户「这 N 个应用会被自动重新签名安装」，而这 N 个里
            //    有一个**永远不会成功**。那就是「弹窗承诺了做不到的事」，
            //    与本仓「破坏性操作的失败必须让用户看见」是同一条纪律的反面。
            //
            // 留空的代价很小：这条记录本来就不能续签（没有本地 IPA）。
            certificateSerialNumber: nil,
            // 设备标识符不填：描述文件里的 `ProvisionedDevices` 是「允许安装的设备集合」，
            // 不是「这台设备的 UDID」，拿它当 `signedDeviceIdentifier` 是错的。
            signedDeviceIdentifier: nil,
            provisioningProfileUUID: draft.profileUUID,
            provisioningProfileName: draft.profileName,
            provisioningProfileCreationDate: draft.profileCreationDate,
            provisioningProfileExpirationDate: draft.profileExpirationDate,
            // `lastInstalledAt` 不填：我们只知道它现在装着，不知道什么时候装的。
            lastInstalledAt: nil,
            signingTargets: [],
            // 占位路径：Swift 的 `let` 属性必须初始化，而这条记录**从来没有过**本地 IPA。
            // `AppFileStore.fileURL` 只校验「路径在 documents 内」、不校验存在性，
            // 所以这里留一个形状正确但必然不存在的路径；下游真去读时会得到明确失败
            // （`SigningCoordinator` 的 `SEAL-RECOVER-002` 就是为它准备的）。
            // ⚠️ 绝不能指向任何**真实**文件：那会让重签拿错包。
            ipaRelativePath: "Apps/\(id.uuidString)/Original.ipa",
            signedIPARelativePath: nil,
            signedIPASHA256: nil,
            signedArtifactStatus: nil,
            preferredBundleIdentifier: draft.bundleIdentifier,
            preferredDisplayName: nil,
            isSeal: false,
            isPinned: false,
            importedAt: now,
            extensions: [],
            importWarnings: [recoveryWarning]
        )
    }

    /// Team 归一化：去空白、空串视为「没有」、统一大写。
    ///
    /// ⚠️ **不是 `private`**：`Context.init` 要用它（`Context` 是嵌套类型），而单测也要
    /// 直接钉住这条规则。Team 的大小写在这条链路上是**载荷性**的 —— 设备端描述文件里是
    /// `ABCDE12345`、账号记录里可能是小写，不归一化就永远对不上（闸门静默失效）。
    /// 规则只有这一处出处，`context(...)` 与 `Context.init` 都走它。
    static func normalizedTeamIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else { return nil }
        return trimmed.uppercased()
    }
}
