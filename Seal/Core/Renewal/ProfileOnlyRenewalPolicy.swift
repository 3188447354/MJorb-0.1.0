import Foundation

/// 运行产物的**实时签名身份** —— 记录之外的第二条续签准入依据。
///
/// 上游 SideStore 的 `refresh` 管线根本**不看数据库记录**：它的准入是
/// `VerifyCertificateOperation(willResign: false)`，输入是**已安装产物的签名证书** ——
/// 自身从运行中的 Mach-O 读（`CertificateManager.getSigningCertificate(at:)` ＋
/// `Bundle.Info.activeBundleURL`），第三方读安装时缓存的 `<app>/signing_certificate.der`
/// （`CacheSigningCertOperation`）。本仓对**自身**有完全等价的现成物：
/// `SelfAppMetadata.current()` 读运行包的 CMS 签名身份（`AppBundleSigningIdentityReader`）。
///
/// 由 `ProfileOnlyRenewalPolicy.liveIdentity(installedIdentity:runningVersion:app:)` 构造；
/// 只有「运行包能自证身份」时才存在（任何一项读不出来 ⇒ `nil`，**绝不猜**）。
struct LiveProfileOnlyIdentity: Equatable, Sendable {
    /// 运行包主目标的 Bundle ID（从 CMS 身份里读出来的那个）。
    let mainBundleIdentifier: String
    let profileUUID: String
    let certificateSerialNumber: String
    let teamIdentifier: String
    /// 该应用在设备上实际存在的全部签名目标（主 App ＋ 扩展）。
    let targetBundleIdentifiers: [String]
    /// **正在运行的那个包**的 `CFBundleShortVersionString`。
    ///
    /// 🔴 为什么必须有（2026-09-26 用户实测）：记录里的 `version` 描述的是**已导入的源包**，
    /// 不是「设备上正在跑的那个」。覆盖更新（`ImportWorkflow.makeInstalledUpdateRecord`）
    /// 会把它写成新导入包的版本，并把 `hasPendingSelfUpdateSource` 置真 —— 这条记录**刻意**
    /// 保留新版本号，等下一次安装生效（见 `SelfAppRegistrar` 那段注释）。
    /// 而 profile-only 只换描述文件、**从不安装** ⇒ 只看 Bundle ID 相等的准入会把
    /// 「已导入 1.3.20、实际跑着 1.3.19」判成合格 ⇒ 新版本**永远装不上**，
    /// 界面却一直显示 1.3.20（用户实测：「关于」里仍是 1.3.19）。
    let runningVersion: String
}

/// Decides whether an installed app has enough identity to attempt a profile-only
/// refresh. Missing profile snapshots and local private keys do not decide ordinary
/// profile-only renewals; the coordinator separately requires Seal's one-time local
/// signing bootstrap when its running signer has no matching private key.
///
/// 🔴 **Seal 自己不再被排除**（2026-09-25）：它与任何第三方已装应用走**同一条**判据 ——
/// 「只更新描述文件、不重新安装」对 Seal 同样适用，判定依据是可核验的身份信息，
/// 与「这是谁的应用」无关。理由见 `evaluate(app:)`。
///
/// 🔴 **记录不是唯一入口**（2026-09-26，构建 46 真机）：只认「持久化记录完整」仍然不够。
/// Seal 自身的记录由 `SelfAppRegistrar` 维护，它**从不写** `signedDeviceIdentifier` /
/// `signingTargets` / `signedIPARelativePath`（⇒ `hasSignedArtifact` 恒为 false）
/// ⇒ 上面那条「不按身份排除」在真机上**一次都没生效过**：构建 46 日志里
/// 01:24:30「开始续签：Seal」紧接着就是「续签路径已确认：需要完整重签并安装」，
/// 而且**没有** `SEAL-PROFILE-363` —— 说明它是在更早的准入处就返回了 false。
/// ⇒ 记录不完整但**运行产物身份可读且完整**时一样放行（见 `evaluate(app:liveIdentity:)`）。
enum ProfileOnlyRenewalPolicy {
    enum Decision: Equatable, Sendable {
        case eligible(targetBundleIdentifiers: [String])
        case requiresFullResign(FullResignReason)
    }

    enum FullResignReason: Equatable, Sendable {
        case missingInstalledArtifact
        case incompleteSigningIdentity
        case missingTargetRecord
        /// 记录证实上一份产物曾移除扩展。profile-only 只能换描述文件，无法把已
        /// 删除的二进制扩展装回去；必须完整重签并覆盖安装一次才能自愈。
        case incompleteExtensionSet
        /// 🔴 **记录里有一条「已导入但尚未生效」的更新源**（2026-09-26，用户实测）。
        ///
        /// 覆盖更新把记录写成**新导入包**的版本号（`hasPendingSelfUpdateSource = true`，
        /// 见 `ImportWorkflow.makeInstalledUpdateRecord`），而设备上跑的还是旧版。
        /// 此时 profile-only 只换描述文件、**从不安装** ⇒ 新版本永远装不上，
        /// 而界面（`AppPresentation` 的 `v\(app.version)`）一直显示新版本号。
        ///
        /// 真机复现：把 1.3.20 的 IPA 手动导入 1.3.19 的 Seal ⇒ 落在「已安装」并显示 1.3.20，
        /// 点「续签」直接走 profile-only ⇒ 「关于」里仍是 1.3.19。
        /// 这条版本比较只对 Seal 的运行包身份有效；普通应用仍由用户选择的更新/重签动作
        /// 决定是否要更换二进制，不能将它们的持久化版本号当作运行版本。
        case pendingSelfUpdateSource
    }

    /// `FullResignReason` 的**可读说明**（只用于日志）。
    ///
    /// 界面文案不使用这里；Seal 首次本机接管的例外由 `SigningCoordinator` 单独处理。
    static func describe(_ reason: FullResignReason) -> String {
        switch reason {
        case .missingInstalledArtifact: "记录里缺少已安装产物"
        case .incompleteSigningIdentity: "记录里的签名身份不完整"
        case .missingTargetRecord: "记录里缺少签名目标"
        case .incompleteExtensionSet: "上一份签名产物缺少扩展，需要完整重签修复"
        case .pendingSelfUpdateSource: "已导入的更新源尚未安装"
        }
    }

    /// 「本机是否持有该应用当前证书的私钥」——**界面**用（日志用 `describe(_:)`）。
    ///
    /// **三态而不是 `Bool`**：读不到账号密钥 与「确认没有私钥」的下一步动作完全不同 ——
    /// 前者（Keychain 暂时读不到 / 账号已删）**不能**凭空断言「缺私钥」，只能什么都不说；
    /// 后者只说明本机没有私钥；普通应用的描述文件续签仍由 Apple 门户里的证书状态决定。
    ///
    /// 普通应用没有该证书私钥时不强制完整重签；Apple 门户仍可能接受该证书并签发更新后的
    /// 描述文件。Seal 首次安装后的接管例外由 `SigningCoordinator` 处理。
    enum LocalCertificateAvailability: Equatable, Sendable {
        /// 没有记录序列号、或读不到该账号的密钥 ⇒ **不显示任何话**（不能凭空断言缺私钥）。
        case undetermined
        /// 本机保存了可解析的该证书私钥。
        case ready
        /// 本机没有保存可解析的该证书私钥；Apple 门户仍可能允许更新其描述文件。
        case missingPrivateKey
    }

    /// 单个应用的本机私钥状态，仅用于界面说明，不参与描述文件续签准入。
    static func localCertificateAvailability(
        secret: AccountSecret?,
        certificateSerialNumber: String?
    ) -> LocalCertificateAvailability {
        guard let secret, let serialNumber = nonBlank(certificateSerialNumber) else { return .undetermined }
        return SigningCertificateMaterialPolicy.availableCertificate(
            secret: secret,
            serialNumber: serialNumber
        ) == nil ? .missingPrivateKey : .ready
    }

    /// 把「账号密钥表」映射成「每个**已安装**应用的本机证书状态」。
    ///
    /// 抽成纯函数（不碰 Keychain、不碰网络）才能单测 —— 它的错法只在真机上表现为
    /// 「本该提示却没有提示 / 不该提示却提示」，不会崩、不会编译失败。
    ///
    /// ⚠️ 只算**已安装**的应用：未安装的应用还没走到续签，提示它只会让列表变吵。
    static func availabilityByAppID(
        apps: [AppRecord],
        secretsByAccount: [UUID: AccountSecret]
    ) -> [UUID: LocalCertificateAvailability] {
        var values: [UUID: LocalCertificateAvailability] = [:]
        for app in apps where app.belongsInInstalledList {
            values[app.id] = localCertificateAvailability(
                secret: app.accountID.flatMap { secretsByAccount[$0] },
                certificateSerialNumber: app.certificateSerialNumber
            )
        }
        return values
    }

    /// 判定当前已安装目标是否具备尝试仅更新描述文件的身份信息。
    ///
    /// 🔴 **Seal 自己不再被排除**（2026-09-25 真机，构建 44）。
    ///
    /// 旧实现的第一句是 `guard app.isSeal == false else { return .requiresFullResign(.sealSelfReplacement) }`
    /// ⇒ Seal **永远**走完整重签 + **自替换安装** ⇒ 进程被系统换掉：
    ///   · 批量续签跑到 Seal 那一项（第 3/3 项）时，队列项还停在 `running` 就随进程消失
    ///     ⇒ 新进程启动后降级成未知，报 `SEAL-RENEW-007`「1 个应用的结果未知，需要重新核验」；
    ///   · 同一轮里 `SEAL-SELF-109`（Seal 自更新安装遇到未预期错误）连报两次，
    ///     并引出多轮自替换结算 + `SEAL-INSTALL-707`；
    ///   · 用户看到的是「续签全部」反复中断、必须手动重试。
    ///
    /// 而「续签」在上游 SideStore 的稳定实现里**从不重签、从不重装** —— 它的
    /// `OperationStepDefinition.refresh` 是**五步**（2026-09-26 逐行复核
    /// `upstream/SideStore/SideStore/Core/Operations/OperationStepDefinition.swift:82-88`）：
    /// `updateAppCertificate` / `verifyCertificate` / `fetchProvisioningProfiles` /
    /// `cacheResignedMetadata` / `refreshApp`；底层就是 misagent 的
    /// `installProvisioningProfile`（本仓对应 `ProfileOnlyProvisioningProfileInstaller`
    /// → `Minimuxer.installProvisioningProfile`），**对它自己同样如此**；
    /// 自替换（`handleSelfReinstallation`）只出现在 install / update / resign 管线里。
    ///
    /// ⚠️ 这段注释原先写的是「三步」——那是 2026-09-08 之前的形态，
    /// `39a97cd039` 起插入 `cacheResignedMetadata`，`verifyCertificate` 更晚。
    /// **别再照抄旧注释**（本项目「过时注释比没有注释更贵」的老坑）。
    ///
    /// Apple 门户会重新核验团队、证书、设备、App ID 和能力；Seal 不要求旧 profile UUID、
    /// 旧 target 快照或本机证书私钥必须完整。缺少 entitlements 时由 Portal 层从 IPA 重建。
    /// 仍无法确认应用身份或扩展目标时，才不能安全地仅替换描述文件。
    static func evaluate(app: AppRecord) -> Decision {
        // `removedExtensionBundleIdentifiers` 是历史完整签名曾物理移除扩展的唯一记录。
        // 只续签无法修复二进制布局，若继续走快路径会把“已续签”写回一个仍缺
        // LiveProcess / Share Extension 的安装包，令用户永远无法通过续签恢复功能。
        guard app.removedExtensionBundleIdentifiers.isEmpty else {
            return .requiresFullResign(.incompleteExtensionSet)
        }
        // 普通应用不依赖可清理的 `Signed.ipa` 缓存或完整旧 target 快照：缺少的
        // entitlements 可从原始 IPA 重建，Apple 会对本轮 profile 的实际配置裁决。
        guard app.state == .installed,
              nonBlank(app.signingTeamID) != nil,
              effectiveCertificateSerialNumber(app: app, liveIdentity: nil) != nil,
              let mainBundleIdentifier = nonBlank(app.mappedBundleIdentifier) else {
            return .requiresFullResign(.incompleteSigningIdentity)
        }

        let targetBundleIdentifiers = [mainBundleIdentifier] + app.extensions.compactMap {
            nonBlank($0.mappedBundleIdentifier)
        }
        guard targetBundleIdentifiers.count == app.extensions.count + 1,
              Set(targetBundleIdentifiers.map { $0.lowercased() }).count == targetBundleIdentifiers.count else {
            return .requiresFullResign(.missingTargetRecord)
        }

        // Seal 的 SelfAppRegistrar 通常不写完整签名快照。它可以由上面的实时身份通道放行；
        // 若实时身份缺失或与记录不匹配，记录通道必须有自己的完整证据，不能拿部分记录兜底。
        if app.isSeal {
            let recordedTargetBundleIdentifiers = Set(app.signingTargets.map {
                $0.bundleIdentifier.lowercased()
            })
            guard nonBlank(app.signedDeviceIdentifier) != nil,
                  app.hasSignedArtifact,
                  Set(targetBundleIdentifiers.map { $0.lowercased() })
                    .isSubset(of: recordedTargetBundleIdentifiers) else {
                return .requiresFullResign(.incompleteSigningIdentity)
            }
        }

        return .eligible(targetBundleIdentifiers: targetBundleIdentifiers)
    }

    /// 从「运行包身份」构造 `LiveProfileOnlyIdentity`。任何一项读不出来都返回 nil —— **绝不猜**。
    ///
    /// - Parameter installedIdentity: `SelfAppMetadata.current()?.installedIdentity`。
    ///   要求每个当前安装目标的 Bundle ID 与 CMS 签名者可读；扩展 Team 缺失时仅继承主程序 Team，
    ///   且所有目标仍必须由同一证书签名。描述文件缺失或失效不阻止恢复。
    ///
    /// - Parameter runningVersion: `SelfAppMetadata.current()?.version` —— **正在运行的那个包**
    ///   的版本。它与记录里的 `version` 是两件事：记录描述「已导入的源包」，可能更新。
    ///   读不到（空串）时整体放弃，**不猜**（空串会被 `Version.compare` 当成 0，
    ///   与任何真实版本都不等 ⇒ 会误判成「有待安装更新」）。
    ///
    /// ⚠️ 调用方**必须**只在「这确实是该 app 自己的运行包」时调用 —— `SelfAppMetadata.current()`
    /// 读的是 `Bundle.main`，对第三方 App 用它会读成 **Seal 自己**的身份（假阳性）。
    /// 见 `SigningCoordinator.liveProfileOnlyIdentity(for:)`。
    static func liveIdentity(
        installedIdentity: InstalledIdentity?,
        runningVersion: String?,
        app: AppRecord
    ) -> LiveProfileOnlyIdentity? {
        guard let installedIdentity,
              installedIdentity.canSafelyIdentifySigners,
              let mainTarget = installedIdentity.mainTarget,
              let mappedMainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
              mainTarget.bundleIdentifier.caseInsensitiveCompare(mappedMainBundleIdentifier) == .orderedSame,
              let serialNumber = nonBlank(mainTarget.signerSerialNumber),
              let teamIdentifier = nonBlank(mainTarget.teamIdentifier) ?? nonBlank(app.signingTeamID),
              let resolvedRunningVersion = nonBlank(runningVersion) else {
            return nil
        }
        let normalizedMainSerial = normalizedSerialNumber(serialNumber)
        guard installedIdentity.targets.allSatisfy({
            let targetTeamIdentifier = nonBlank($0.teamIdentifier) ?? teamIdentifier
            return normalizedSerialNumber($0.signerSerialNumber) == normalizedMainSerial
                && targetTeamIdentifier.caseInsensitiveCompare(teamIdentifier) == .orderedSame
        }) else { return nil }
        let targets = installedIdentity.targets.map(\.bundleIdentifier)
        guard targets.first?.caseInsensitiveCompare(mappedMainBundleIdentifier) == .orderedSame,
              Set(targets.map { $0.lowercased() }).count == targets.count else { return nil }
        return LiveProfileOnlyIdentity(
            mainBundleIdentifier: mappedMainBundleIdentifier,
            profileUUID: nonBlank(mainTarget.profileUUID) ?? "",
            certificateSerialNumber: serialNumber,
            teamIdentifier: teamIdentifier,
            targetBundleIdentifiers: targets,
            runningVersion: resolvedRunningVersion
        )
    }

    /// 🔴 **唯一判据**：「记录里描述的那个源包」与「正在运行的那个包」是不是同一个版本，
    /// 加上「有没有新导入但尚未安装的源包」（内容指纹）。
    ///
    /// `true` = 记录里有一条**已导入但尚未生效**的更新源。
    ///
    /// 为什么必须单独立出来（2026-09-26 用户实测）：这条判断有**两个**消费方 ——
    /// ① 准入（`evaluate(app:liveIdentity:)`：有待安装更新就回落完整重签）；
    /// ② 界面（`AppSigningPresentationHelpers.pendingUpdateNote(for:runningVersion:)`：
    ///    在详情页 / 操作抽屉里说明「本次续签会完整重签并安装」）。
    /// 两处各写一份必然漂移成「准入说要做、界面不说」或反过来（本项目最反复的坑）。
    ///
    /// 版本比较之外为什么还要指纹（2026-10-02 用户需求）：导入 Seal 自身的 IPA
    /// 即使**版本号相同**也要能覆盖更新。只看版本会把「同版本重建的包」判成无更新 ⇒
    /// 走 profile-only（只换描述文件、从不安装）⇒ 新包永远装不上。
    /// 指纹是导入时算的源包 SHA256，自替换结算成功后清掉（`SelfAppRegistrar`），
    /// 因此同样是**自愈**的：没有新导入时指纹为空 ⇒ 回落为纯版本比较，
    /// 续签不导入新包就不会触发重装 —— 1.3.17「续签全都要重装」的坑不会回来。
    ///
    /// ⚠️ **不能用 `AppRecord.hasPendingSelfUpdateSource` 代替它**：那个标志对 Seal
    /// **永远清不掉** —— 自替换安装成功后进程被系统换掉，清标志的那行
    /// （`SigningCoordinator` 里 `updated.hasPendingSelfUpdateSource = false`）
    /// 走的是普通安装路径；而 `SelfAppRegistrar` 的待安装分支刻意一直保留它。
    /// 版本比较则是**自愈**的：装完新版本后记录版本与运行版本自然相等。
    ///
    /// ⚠️ 两边任一读不出来 ⇒ 返回 `false`（**不声称**有待安装更新）：
    ///   · 准入侧：`liveIdentity.runningVersion` 在 `liveIdentity(...)` 里已被 `nonBlank`
    ///     守卫过 ⇒ 只可能是 `app.version` 为空（记录损坏，现实里不会出现）；
    ///   · 界面侧：读不到运行版本时不能凭空告诉用户「有更新待安装」，
    ///     那会把一次正常的续签说成必须重装（与 R85 的 `.undetermined` 同一条纪律）。
    /// 待安装源的**企业级分类**：只看版本与指纹的客观事实，不掺 UI 文案。
    ///
    /// - `none`：无待安装（版本一致且指纹一致，或无源包）。
    /// - `newVersion`：源包版本 > 已装版本 —— 真正的"新版本"。
    /// - `sameVersion`：版本一致但指纹不同 —— 同版本号的不同包（重新打包/不同渠道）。
    /// - `downgrade`：源包版本 < 已装版本 —— 旧包，**不是**新版本。
    enum PendingUpdateKind {
        case none
        case newVersion
        case sameVersion
        case downgrade
    }

    /// 分类待安装源。调用方按分类决定 UI 文案与准入策略。
    static func pendingUpdateKind(
        recordedVersion: String?,
        runningVersion: String?,
        pendingUpdateSourceFingerprint: String? = nil,
        installedFingerprint: String? = nil
    ) -> PendingUpdateKind {
        guard let recorded = nonBlank(recordedVersion),
              let running = nonBlank(runningVersion) else { return .none }
        switch Version.compare(recorded, running) {
        case .orderedDescending:
            return .newVersion
        case .orderedAscending:
            return .downgrade
        case .orderedSame:
            break
        }
        // 版本一致时看指纹：用户显式导入了新源包（即使版本号相同）才算待安装；
        // 指纹为空（老记录 / 已结算）时不声称有更新；指纹与已装包一致 ⇒ 同一个包。
        guard let pending = nonBlank(pendingUpdateSourceFingerprint) else { return .none }
        if let installed = nonBlank(installedFingerprint), pending == installed {
            return .none
        }
        return .sameVersion
    }

    static func hasPendingUpdateSource(
        recordedVersion: String?,
        runningVersion: String?,
        pendingUpdateSourceFingerprint: String? = nil,
        installedFingerprint: String? = nil
    ) -> Bool {
        // 降级不算"待更新"：旧包导入不触发更新流程，避免误导。
        // 同版本不同包仍算待安装（与过去行为一致）。
        switch pendingUpdateKind(
            recordedVersion: recordedVersion,
            runningVersion: runningVersion,
            pendingUpdateSourceFingerprint: pendingUpdateSourceFingerprint,
            installedFingerprint: installedFingerprint
        ) {
        case .newVersion, .sameVersion:
            return true
        case .none, .downgrade:
            return false
        }
    }

    /// 记录之外的**第二条准入通道**：以「运行产物的实时身份」为准（对齐上游 `refresh`）。
    ///
    /// 适用场景：记录里缺字段（Seal 自身就是如此），但**运行包能自证身份**。
    /// 此时记录完整性不再必要 —— 运行包本身就是「已安装」这个事实的最强证据，
    /// 比任何 DB 字段都强（DB 字段可能是安装前乐观写入的、也可能是旧值）。
    ///
    /// 实时身份必须能识别主应用和所有已安装目标的签名者，并与记录里的主 Bundle ID 一致；
    /// profile UUID 可以缺失，因为续签会从 Apple 重新取得 profile。
    ///
    /// 🔴 **再加一条：记录里的源包版本必须等于正在运行的版本**（2026-09-26，用户实测）。
    /// 覆盖更新刻意把记录写成**新导入包**的版本号（`hasPendingSelfUpdateSource`），
    /// 而设备上跑的还是旧版 ⇒ 此时放行 profile-only 等于宣布「更新已生效」，
    /// 而它只换描述文件、从不安装 ⇒ **新版本永远装不上，界面却一直显示新版本号**。
    /// 版本不一致 ⇒ 回落完整重签（它会用 `app.ipaRelativePath` 里的**新包**重新签名并安装，
    /// 装完记录版本与运行版本重新相等 —— 这条判据**自愈**，不依赖任何「待安装」标志：
    /// Seal 走的是自替换安装，进程会被系统换掉，清标志那行根本轮不到它）。
    static func evaluate(
        app: AppRecord,
        liveIdentity: LiveProfileOnlyIdentity?
    ) -> Decision {
        if let liveIdentity,
           let mappedMainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
           liveIdentity.mainBundleIdentifier.caseInsensitiveCompare(mappedMainBundleIdentifier)
               == .orderedSame {
            guard app.state == .installed else {
                return .requiresFullResign(.missingInstalledArtifact)
            }
            guard app.removedExtensionBundleIdentifiers.isEmpty else {
                return .requiresFullResign(.incompleteExtensionSet)
            }
            let liveTargets = liveIdentity.targetBundleIdentifiers
            guard liveTargets.first?.caseInsensitiveCompare(mappedMainBundleIdentifier) == .orderedSame,
                  Set(liveTargets.map { $0.lowercased() }).count == liveTargets.count else {
                return .requiresFullResign(.missingTargetRecord)
            }
            // ⚠️ 比较的是**营销版本**（`CFBundleShortVersionString`）—— 那正是更新通道
            // 判「有没有新版本」用的单位（见 `AGENTS.md` §6）。版本一致时再看
            // `pendingUpdateSourceFingerprint`：只有用户**显式导入了新源包**
            // （即使版本号相同）才回落完整重签；续签时没导入新包指纹为空 ⇒
            // 仍走 profile-only —— 1.3.17「续签全都要重装」的坑不会回来。
            guard hasPendingUpdateSource(
                recordedVersion: app.version,
                runningVersion: liveIdentity.runningVersion,
                pendingUpdateSourceFingerprint: app.pendingUpdateSourceFingerprint,
                installedFingerprint: app.installedFingerprint
            ) == false else {
                return .requiresFullResign(.pendingSelfUpdateSource)
            }
            return .eligible(targetBundleIdentifiers: liveTargets)
        }
        return evaluate(app: app)
    }

    /// 准入通过后判定「设备绑定」是否成立。
    ///
    /// 当前连接设备必须可识别；旧 `signedDeviceIdentifier` 仅是历史快照，Apple 会按
    /// 当前设备注册状态生成 profile，本地旧值不参与准入。
    static func isBoundToCurrentDevice(
        app: AppRecord,
        deviceIdentifier: String,
        liveIdentity: LiveProfileOnlyIdentity?
    ) -> Bool {
        if let liveIdentity,
           let mappedBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
           liveIdentity.mainBundleIdentifier.caseInsensitiveCompare(mappedBundleIdentifier) != .orderedSame {
            return false
        }
        // 旧设备 ID 是记录快照，不是 Apple 对本轮 profile 的裁决。
        // 当前设备必须可识别；Apple 端注册状态与新 profile 内的设备列表才是准据。
        return nonBlank(deviceIdentifier) != nil
    }

    /// 准入通过后取「该应用实际被哪张证书签名」。
    /// 记录里的值是安装前写入的，可能是旧证书；实时身份是运行包 CMS 里的真值。
    static func effectiveCertificateSerialNumber(
        app: AppRecord,
        liveIdentity: LiveProfileOnlyIdentity?
    ) -> String? {
        if let liveSerial = nonBlank(liveIdentity?.certificateSerialNumber) {
            return liveSerial
        }
        if let recordedSerial = nonBlank(app.certificateSerialNumber) {
            return recordedSerial
        }
        guard let mainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
              let mainTarget = app.signingTargets.first(where: {
                  $0.bundleIdentifier.caseInsensitiveCompare(mainBundleIdentifier) == .orderedSame
              }) else { return nil }
        let profileSerials = Set(mainTarget.certificateSerialNumbers.compactMap {
            normalizedSerialNumber($0)
        })
        guard profileSerials.count == 1 else { return nil }
        return profileSerials.first
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedSerialNumber(_ serialNumber: String?) -> String? {
        guard let serialNumber = nonBlank(serialNumber) else { return nil }
        let normalized = serialNumber.uppercased().drop(while: { $0 == "0" })
        return normalized.isEmpty ? "0" : String(normalized)
    }

}
