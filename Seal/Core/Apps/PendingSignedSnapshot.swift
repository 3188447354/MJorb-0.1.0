import Foundation

/// 两阶段提交的草稿：签名/续签阶段先写这里，确认成功后整体转正到 AppRecord 顶层。
/// nil = 无进行中的签名/续签。UI 只读顶层 committed 值，不读这里。
struct PendingSignedSnapshot: Codable, Equatable, Sendable {
    var expiryDate: Date?
    var provisioningProfileUUID: String?
    var provisioningProfileName: String?
    var provisioningProfileCreationDate: Date?
    var provisioningProfileExpirationDate: Date?
    var certificateSerialNumber: String?
    var signingTargets: [SigningTargetRecord]
    var extensionSnapshots: [PendingExtensionSnapshot]
    /// 普通安装的本次设备命令标识。仅当 native 安装超时/取消后仍在设备端执行时保留，
    /// 用于拒绝旧尝试迟到结果覆盖新尝试，并在结果到达后结算。
    var installAttemptID: UUID? = nil
    var wasInstalledBeforeAttempt: Bool = false

    struct PendingExtensionSnapshot: Codable, Equatable, Sendable {
        var bundleIdentifier: String
        var provisioningProfileUUID: String?
        var provisioningProfileName: String?
        var provisioningProfileExpirationDate: Date?
        var certificateSerialNumber: String?
    }
}

extension PendingSignedSnapshot {
    private enum CodingKeys: String, CodingKey {
        case expiryDate
        case provisioningProfileUUID
        case provisioningProfileName
        case provisioningProfileCreationDate
        case provisioningProfileExpirationDate
        case certificateSerialNumber
        case signingTargets
        case extensionSnapshots
        case installAttemptID
        case wasInstalledBeforeAttempt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expiryDate = try container.decodeIfPresent(Date.self, forKey: .expiryDate)
        provisioningProfileUUID = try container.decodeIfPresent(String.self, forKey: .provisioningProfileUUID)
        provisioningProfileName = try container.decodeIfPresent(String.self, forKey: .provisioningProfileName)
        provisioningProfileCreationDate = try container.decodeIfPresent(Date.self, forKey: .provisioningProfileCreationDate)
        provisioningProfileExpirationDate = try container.decodeIfPresent(Date.self, forKey: .provisioningProfileExpirationDate)
        certificateSerialNumber = try container.decodeIfPresent(String.self, forKey: .certificateSerialNumber)
        signingTargets = try container.decode([SigningTargetRecord].self, forKey: .signingTargets)
        extensionSnapshots = try container.decode([PendingExtensionSnapshot].self, forKey: .extensionSnapshots)
        installAttemptID = try container.decodeIfPresent(UUID.self, forKey: .installAttemptID)
        wasInstalledBeforeAttempt = try container.decodeIfPresent(Bool.self, forKey: .wasInstalledBeforeAttempt) ?? false
    }
}

extension AppRecord {
    /// pending → committed 转正：安装/注入确认后，把草稿整体写到顶层并清空。
    /// 无 pending 时直接返回。UI 只读顶层。
    mutating func commitPendingSnapshot() {
        guard let pending = pendingSignedSnapshot else { return }
        provisioningProfileUUID = pending.provisioningProfileUUID
        provisioningProfileName = pending.provisioningProfileName
        provisioningProfileCreationDate = pending.provisioningProfileCreationDate
        provisioningProfileExpirationDate = pending.provisioningProfileExpirationDate
        expiryDate = pending.expiryDate
        certificateSerialNumber = pending.certificateSerialNumber
        signingTargets = pending.signingTargets
        for snapshot in pending.extensionSnapshots {
            if let index = extensions.firstIndex(where: { $0.mappedBundleIdentifier == snapshot.bundleIdentifier }) {
                extensions[index].provisioningProfileUUID = snapshot.provisioningProfileUUID
                extensions[index].provisioningProfileName = snapshot.provisioningProfileName
                extensions[index].provisioningProfileExpirationDate = snapshot.provisioningProfileExpirationDate
                extensions[index].certificateSerialNumber = snapshot.certificateSerialNumber
            }
        }
        pendingSignedSnapshot = nil
    }

    /// 丢弃 pending（失败/回滚时），顶层保持旧的已确认值。
    mutating func discardPendingSnapshot() {
        pendingSignedSnapshot = nil
    }
}
