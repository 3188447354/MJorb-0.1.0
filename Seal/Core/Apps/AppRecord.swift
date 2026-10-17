import Foundation

struct AppRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let originalBundleIdentifier: String
    var mappedBundleIdentifier: String?
    let name: String
    let version: String
    let buildNumber: String
    let size: Int64
    var iconRelativePath: String?
    var state: AppState
    var expiryDate: Date?
    var accountID: UUID?
    var signingTeamID: String?
    var certificateSerialNumber: String?
    var signedDeviceIdentifier: String?
    var provisioningProfileUUID: String?
    var provisioningProfileName: String?
    var provisioningProfileCreationDate: Date?
    var provisioningProfileExpirationDate: Date?
    var entitlementValidationStatus: String?
    var capabilityValidationStatus: String?
    var lastSignedAt: Date?
    var lastInstalledAt: Date?
    var removedExtensionBundleIdentifiers: [String]
    var signingTargets: [SigningTargetRecord]
    let ipaRelativePath: String
    var signedIPARelativePath: String?
    var signedIPASHA256: String?
    /// 已签包落盘时的文件大小 + 修改时间（性能优化 2026-10-04）：
    /// 缓存复用前先比对这两项，命中则跳过 1.5GB 全量 SHA256。
    var signedIPAFileSize: Int64?
    var signedIPAModificationDate: Date?
    var signedArtifactStatus: SignedArtifactStatus?
    var preferredBundleIdentifier: String?
    var preferredDisplayName: String?
    var preferredIconRelativePath: String?
    var lastInstallFailureCode: String?
    var lastInstallFailureReason: String?
    var pendingFileTransactionID: UUID?
    var hasPendingSelfUpdateSource: Bool
    /// 重装后扫回来的"空壳"记录：有名字版本但没有 IPA 文件，需要用户重新导入 IPA。
    /// 为 true 时列表显示"待导入 IPA"徽标，且不能签名/续签。
    var needsIPAImport: Bool
    /// 待安装的自更新源包指纹（源 IPA 的 SHA256，导入 Seal 自身 IPA 时写入）。
    /// 续签准入用它判断「有没有待安装的更新源」：版本号相同时只能靠内容指纹区分。
    /// 自替换安装成功、结算完成后清掉（`SelfAppRegistrar.atomicallyApplyInstalledIdentity`），
    /// 因此它是自愈的 —— 不像 `hasPendingSelfUpdateSource` 那样装完还一直为真。
    var pendingUpdateSourceFingerprint: String?
    /// 已安装包的指纹（安装成功时写入）。导入时若新包指纹与它一致，说明是同一个包，
    /// 不标为待更新（避免重复导入同一包一直提示）。
    var installedFingerprint: String?
    let isSeal: Bool
    var isPinned: Bool
    let importedAt: Date
    var extensions: [AppExtensionRecord]
    var importWarnings: [String]
    var extensionProfileStrategy: AppExtensionProfileStrategy?
    /// 两阶段提交的草稿：签名/续签阶段先写这里，确认成功后整体转正到顶层。
    /// nil = 无进行中的签名/续签。UI 只读顶层 committed 值，不读这里。
    var pendingSignedSnapshot: PendingSignedSnapshot?
    /// 覆盖更新时，指向被替换的已安装记录 ID。签名安装成功后，删除旧记录，本记录转正为已安装。
    /// nil = 普通导入，不是覆盖更新。
    var replacesInstalledAppID: UUID?

    init(
        id: UUID = UUID(),
        originalBundleIdentifier: String,
        mappedBundleIdentifier: String? = nil,
        name: String,
        version: String,
        buildNumber: String,
        size: Int64,
        iconRelativePath: String? = nil,
        state: AppState,
        expiryDate: Date? = nil,
        accountID: UUID? = nil,
        signingTeamID: String? = nil,
        certificateSerialNumber: String? = nil,
        signedDeviceIdentifier: String? = nil,
        provisioningProfileUUID: String? = nil,
        provisioningProfileName: String? = nil,
        provisioningProfileCreationDate: Date? = nil,
        provisioningProfileExpirationDate: Date? = nil,
        entitlementValidationStatus: String? = nil,
        capabilityValidationStatus: String? = nil,
        lastSignedAt: Date? = nil,
        lastInstalledAt: Date? = nil,
        removedExtensionBundleIdentifiers: [String] = [],
        signingTargets: [SigningTargetRecord] = [],
        ipaRelativePath: String,
        signedIPARelativePath: String? = nil,
        signedIPASHA256: String? = nil,
        signedIPAFileSize: Int64? = nil,
        signedIPAModificationDate: Date? = nil,
        signedArtifactStatus: SignedArtifactStatus? = nil,
        preferredBundleIdentifier: String? = nil,
        preferredDisplayName: String? = nil,
        preferredIconRelativePath: String? = nil,
        lastInstallFailureCode: String? = nil,
        lastInstallFailureReason: String? = nil,
        pendingFileTransactionID: UUID? = nil,
        hasPendingSelfUpdateSource: Bool = false,
        pendingUpdateSourceFingerprint: String? = nil,
        installedFingerprint: String? = nil,
        needsIPAImport: Bool = false,
        isSeal: Bool = false,
        isPinned: Bool = false,
        importedAt: Date,
        extensions: [AppExtensionRecord] = [],
        importWarnings: [String] = [],
        extensionProfileStrategy: AppExtensionProfileStrategy? = nil,
        pendingSignedSnapshot: PendingSignedSnapshot? = nil,
        replacesInstalledAppID: UUID? = nil
    ) {
        self.id = id
        self.originalBundleIdentifier = originalBundleIdentifier
        self.mappedBundleIdentifier = mappedBundleIdentifier
        self.name = name
        self.version = version
        self.buildNumber = buildNumber
        self.size = size
        self.iconRelativePath = iconRelativePath
        self.state = state
        self.expiryDate = expiryDate
        self.accountID = accountID
        self.signingTeamID = signingTeamID
        self.certificateSerialNumber = certificateSerialNumber
        self.signedDeviceIdentifier = signedDeviceIdentifier
        self.provisioningProfileUUID = provisioningProfileUUID
        self.provisioningProfileName = provisioningProfileName
        self.provisioningProfileCreationDate = provisioningProfileCreationDate
        self.provisioningProfileExpirationDate = provisioningProfileExpirationDate
        self.entitlementValidationStatus = entitlementValidationStatus
        self.capabilityValidationStatus = capabilityValidationStatus
        self.lastSignedAt = lastSignedAt
        self.lastInstalledAt = lastInstalledAt
        self.removedExtensionBundleIdentifiers = removedExtensionBundleIdentifiers
        self.signingTargets = signingTargets
        self.ipaRelativePath = ipaRelativePath
        self.signedIPARelativePath = signedIPARelativePath
        self.signedIPASHA256 = signedIPASHA256
        self.signedIPAFileSize = signedIPAFileSize
        self.signedIPAModificationDate = signedIPAModificationDate
        self.signedArtifactStatus = signedArtifactStatus
        self.preferredBundleIdentifier = preferredBundleIdentifier
        self.preferredDisplayName = preferredDisplayName
        self.preferredIconRelativePath = preferredIconRelativePath
        self.lastInstallFailureCode = lastInstallFailureCode
        self.lastInstallFailureReason = lastInstallFailureReason
        self.pendingFileTransactionID = pendingFileTransactionID
        self.hasPendingSelfUpdateSource = hasPendingSelfUpdateSource
        self.needsIPAImport = needsIPAImport
        self.pendingUpdateSourceFingerprint = pendingUpdateSourceFingerprint
        self.installedFingerprint = installedFingerprint
        self.isSeal = isSeal
        self.isPinned = isPinned
        self.importedAt = importedAt
        self.extensions = extensions
        self.importWarnings = importWarnings
        self.extensionProfileStrategy = extensionProfileStrategy
        self.pendingSignedSnapshot = pendingSignedSnapshot
        self.replacesInstalledAppID = replacesInstalledAppID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case originalBundleIdentifier
        case mappedBundleIdentifier
        case name
        case version
        case buildNumber
        case size
        case iconRelativePath
        case state
        case expiryDate
        case accountID
        case signingTeamID
        case certificateSerialNumber
        case signedDeviceIdentifier
        case provisioningProfileUUID
        case provisioningProfileName
        case provisioningProfileCreationDate
        case provisioningProfileExpirationDate
        case entitlementValidationStatus
        case capabilityValidationStatus
        case lastSignedAt
        case lastInstalledAt
        case removedExtensionBundleIdentifiers
        case signingTargets
        case ipaRelativePath
        case signedIPARelativePath
        case signedIPASHA256
        case signedIPAFileSize
        case signedIPAModificationDate
        case signedArtifactStatus
        case preferredBundleIdentifier
        case preferredDisplayName
        case preferredIconRelativePath
        case lastInstallFailureCode
        case lastInstallFailureReason
        case pendingFileTransactionID
        case hasPendingSelfUpdateSource
        case pendingUpdateSourceFingerprint
        case installedFingerprint
        case needsIPAImport
        case isSeal
        case isPinned
        case importedAt
        case extensions
        case importWarnings
        case extensionProfileStrategy
        case pendingSignedSnapshot
        case replacesInstalledAppID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalBundleIdentifier = try container.decode(String.self, forKey: .originalBundleIdentifier)
        mappedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .mappedBundleIdentifier)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        size = try container.decode(Int64.self, forKey: .size)
        iconRelativePath = try container.decodeIfPresent(String.self, forKey: .iconRelativePath)
        state = try container.decode(AppState.self, forKey: .state)
        expiryDate = try container.decodeIfPresent(Date.self, forKey: .expiryDate)
        accountID = try container.decodeIfPresent(UUID.self, forKey: .accountID)
        signingTeamID = try container.decodeIfPresent(String.self, forKey: .signingTeamID)
        certificateSerialNumber = try container.decodeIfPresent(String.self, forKey: .certificateSerialNumber)
        signedDeviceIdentifier = try container.decodeIfPresent(String.self, forKey: .signedDeviceIdentifier)
        provisioningProfileUUID = try container.decodeIfPresent(String.self, forKey: .provisioningProfileUUID)
        provisioningProfileName = try container.decodeIfPresent(String.self, forKey: .provisioningProfileName)
        provisioningProfileCreationDate = try container.decodeIfPresent(Date.self, forKey: .provisioningProfileCreationDate)
        provisioningProfileExpirationDate = try container.decodeIfPresent(Date.self, forKey: .provisioningProfileExpirationDate)
        entitlementValidationStatus = try container.decodeIfPresent(String.self, forKey: .entitlementValidationStatus)
        capabilityValidationStatus = try container.decodeIfPresent(String.self, forKey: .capabilityValidationStatus)
        lastSignedAt = try container.decodeIfPresent(Date.self, forKey: .lastSignedAt)
        lastInstalledAt = try container.decodeIfPresent(Date.self, forKey: .lastInstalledAt)
        removedExtensionBundleIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .removedExtensionBundleIdentifiers
        ) ?? []
        signingTargets = try container.decodeIfPresent(
            [SigningTargetRecord].self,
            forKey: .signingTargets
        ) ?? []
        ipaRelativePath = try container.decode(String.self, forKey: .ipaRelativePath)
        signedIPARelativePath = try container.decodeIfPresent(String.self, forKey: .signedIPARelativePath)
        signedIPASHA256 = try container.decodeIfPresent(String.self, forKey: .signedIPASHA256)
        signedIPAFileSize = try container.decodeIfPresent(Int64.self, forKey: .signedIPAFileSize)
        signedIPAModificationDate = try container.decodeIfPresent(Date.self, forKey: .signedIPAModificationDate)
        signedArtifactStatus = try container.decodeIfPresent(SignedArtifactStatus.self, forKey: .signedArtifactStatus)
        preferredBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .preferredBundleIdentifier)
        preferredDisplayName = try container.decodeIfPresent(String.self, forKey: .preferredDisplayName)
        preferredIconRelativePath = try container.decodeIfPresent(String.self, forKey: .preferredIconRelativePath)
        lastInstallFailureCode = try container.decodeIfPresent(String.self, forKey: .lastInstallFailureCode)
        lastInstallFailureReason = try container.decodeIfPresent(String.self, forKey: .lastInstallFailureReason)
        pendingFileTransactionID = try container.decodeIfPresent(UUID.self, forKey: .pendingFileTransactionID)
        hasPendingSelfUpdateSource = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasPendingSelfUpdateSource
        ) ?? false
        pendingUpdateSourceFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .pendingUpdateSourceFingerprint
        )
        installedFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .installedFingerprint
        )
        isSeal = try container.decodeIfPresent(Bool.self, forKey: .isSeal) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        extensions = try container.decodeIfPresent(
            [AppExtensionRecord].self,
            forKey: .extensions
        ) ?? []
        importWarnings = try container.decodeIfPresent(
            [String].self,
            forKey: .importWarnings
        ) ?? []
        extensionProfileStrategy = try container.decodeIfPresent(
            AppExtensionProfileStrategy.self,
            forKey: .extensionProfileStrategy
        )
        pendingSignedSnapshot = try container.decodeIfPresent(
            PendingSignedSnapshot.self,
            forKey: .pendingSignedSnapshot
        )
        replacesInstalledAppID = try container.decodeIfPresent(UUID.self, forKey: .replacesInstalledAppID)
        needsIPAImport = try container.decodeIfPresent(Bool.self, forKey: .needsIPAImport) ?? false
    }

    var hasPersistedSigningIdentity: Bool {
        mappedBundleIdentifier?.isEmpty == false
            && accountID != nil
            && signingTeamID?.isEmpty == false
            && certificateSerialNumber?.isEmpty == false
            && signedDeviceIdentifier?.isEmpty == false
            && provisioningProfileExpirationDate != nil
    }

    /// 已记录或用户明确选择的策略优先。普通 IPA 默认共享；Seal 与 LiveContainer 默认独立。
    /// 普通 IPA 的扩展若有不兼容能力，只为该扩展单独申请 profile。
    var effectiveExtensionProfileStrategy: AppExtensionProfileStrategy {
        if let extensionProfileStrategy {
            return extensionProfileStrategy
        }
        return AppExtensionProfileStrategy.defaultFor(
            isSeal: isSeal,
            isLiveContainer: isLiveContainer
        )
    }

    private var isLiveContainer: Bool {
        let identifier = originalBundleIdentifier.lowercased()
        return identifier == "com.kdt.livecontainer"
            || identifier.hasPrefix("com.kdt.livecontainer.")
    }

    /// 逐目标签名时，独立扩展可由已提交 signingTargets 中的 profile UUID 还原，
    /// 不需要另存一份容易与签名记录失配的 Bundle ID 清单。
    var independentlyProvisionedExtensionBundleIdentifiers: Set<String> {
        let extensionBundleIDs = Set(extensions.compactMap(\.mappedBundleIdentifier))
        switch extensionProfileStrategy {
        case .some(.sharedMainProfile):
            return []
        case .none:
            return extensionBundleIDs
        case .some(.independentProfiles):
            return extensionBundleIDs
        case .some(.selectiveProfiles):
            guard let mainProfileUUID = provisioningProfileUUID else { return [] }
            return Set(signingTargets.compactMap { target in
                guard extensionBundleIDs.contains(target.bundleIdentifier),
                      let profileUUID = target.profileUUID,
                      profileUUID.caseInsensitiveCompare(mainProfileUUID) != .orderedSame else { return nil }
                return target.bundleIdentifier
            })
    }
    }

    var requiresLockedSigningIdentity: Bool {
        hasPersistedSigningIdentity
    }

    var displayName: String {
        if let trimmed = preferredDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           trimmed.isEmpty == false {
            return trimmed
        }
        return name
    }

    var displayIconRelativePath: String? {
        preferredIconRelativePath ?? iconRelativePath
    }

    var hasSignedArtifact: Bool {
        signedIPARelativePath?.isEmpty == false && signedIPASHA256?.isEmpty == false
    }

    /// 设备端已确认不再安装该 App 时，保留本地 IPA 与签名产物，
    /// 仅撤销“已安装”的派生状态。设备探测不是用户删除资料的授权。
    mutating func markMissingOnDevice() {
        state = .signed
        lastInstalledAt = nil
        signedArtifactStatus = hasSignedArtifact ? .available : .missing
    }

    /// 删除可再生的已签名 IPA 缓存元数据，不触碰设备上已安装应用的续签身份。
    /// 描述文件续签只依赖已安装身份、证书私钥与签名目标；缓存不存在时仅不能离线重装。
    mutating func clearSignedIPACacheMetadata() {
        signedIPARelativePath = nil
        signedIPASHA256 = nil
        signedIPAFileSize = nil
        signedIPAModificationDate = nil
    }

    /// 供「应用不在设备上」等旧调用路径使用：缓存和已安装产物同时失效。
    mutating func clearSignedArtifact() {
        clearSignedIPACacheMetadata()
        signedArtifactStatus = .missing
    }

    var belongsInInstalledList: Bool {
        // 待签名的 Seal 更新包在设备核验成功前始终不进已安装列表。签名阶段会把
        // state 从 .imported 改成 .preflightPassed / .signing 等；若只排除 .imported，
        // 新旧 Seal 会在这段事务窗口并列显示。replacesInstalledAppID 仅在原子接管
        // commitInstalledReplacement 后清空，因此它是这里唯一可靠的可见性边界。
        if isSeal, replacesInstalledAppID != nil {
            return false
        }
        return isSeal || state == .installed || lastInstalledAt != nil || signedArtifactStatus == .installed
    }

    var belongsInSignedList: Bool {
        guard belongsInInstalledList == false,
              hasSignedArtifact else {
            return false
        }

        // 只有可再次下发到设备的签名包才进入「待安装」。损坏、缺失或过期的
        // 产物重复安装没有意义，仍留在「待签名」让用户重新生成一份有效包。
        switch signedArtifactStatus {
        case .available, .awaitingVerification, .installFailed, .deviceUnavailable, nil:
            return true
        case .installed, .expired, .damaged, .missing:
            return false
        }
    }

    var belongsInUnsignedList: Bool {
        // 待签名的 Seal 更新包在整个签名/安装事务内都留在待签名列表；成功接管后
        // replacesInstalledAppID 才会清空并进入已安装列表。
        if isSeal, replacesInstalledAppID != nil {
            return true
        }
        return belongsInInstalledList == false && belongsInSignedList == false
    }

    var userIdentityKeys: Set<String> {
        // 只比较实际签名后的 Bundle ID（mapped/preferred）
        // 不包含 originalBundleIdentifier：同一原始 IPA 可用不同 Bundle ID 签出多个副本同时安装
        [
            mappedBundleIdentifier,
            preferredBundleIdentifier
        ]
        .compactMap { value -> String? in
            guard let normalized = value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  normalized.isEmpty == false else { return nil }
            return normalized
        }
        .reduce(into: Set<String>()) { result, value in
            result.insert(value)
        }
    }

}
