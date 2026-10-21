import Foundation

extension Notification.Name {
    static let sealDeviceSessionWriterReleased = Notification.Name("SealDeviceSessionWriterReleased")
}

@MainActor
final class OperationCoordinator {
    enum Kind: String, Equatable, Hashable, Sendable {
        case importing
        case updatingApp
        case signing
        case installing
        case renewing
        case managingCertificate
        case managingAccount
        case maintainingStorage
        case resettingPairing
        case scanningDeviceInventory
        case managingDeviceProfiles

        var title: String {
            switch self {
            case .importing: return "正在导入"
            case .updatingApp: return "正在更新应用资料"
            case .signing: return "正在签名"
            case .installing: return "正在安装"
            case .renewing: return "正在续签"
            case .managingCertificate: return "正在管理证书"
            case .managingAccount: return "正在管理 Apple ID"
            case .maintainingStorage: return "正在维护存储"
            case .resettingPairing: return "正在更新配对"
            case .scanningDeviceInventory: return "正在读取设备清单"
            case .managingDeviceProfiles: return "正在维护设备描述文件"
            }
        }
    }

    struct Lease: Equatable, Sendable {
        fileprivate let id: UUID
        let kind: Kind
        let appID: UUID?
        let accountID: UUID?

        static func uncoordinated(_ kind: Kind, appID: UUID?, accountID: UUID?) -> Lease {
            Lease(id: UUID(), kind: kind, appID: appID, accountID: accountID)
        }
    }

    private(set) var activeLeases: [Lease] = []
    private var nativeDeviceCallCounts: [UUID: Int] = [:]
    private var leasesEndingAfterNativeCalls = Set<UUID>()
    private var nativeDeviceLeasesCreatedByNativeCall = Set<UUID>()
    var onLeaseReleased: (() -> Void)?

    /// Compatibility view for existing status copy. Coordination decisions must use
    /// `hasConflict(for:appID:)` so an unrelated operation cannot appear globally busy.
    var activeLease: Lease? { activeLeases.first }

    var hasActiveLease: Bool { activeLeases.isEmpty == false }

    func begin(_ kind: Kind, appID: UUID? = nil, accountID: UUID? = nil) -> Lease? {
        guard hasConflict(for: kind, appID: appID, accountID: accountID) == false else { return nil }
        let lease = Lease(id: UUID(), kind: kind, appID: appID, accountID: accountID)
        activeLeases.append(lease)
        return lease
    }

    func end(_ lease: Lease) {
        if nativeDeviceCallCounts[lease.id, default: 0] > 0 {
            leasesEndingAfterNativeCalls.insert(lease.id)
            return
        }
        removeLease(id: lease.id)
    }

    /// Keep the parent device transaction alive, or create a narrow read lease when this native
    /// call has no parent transaction. The lease covers the full non-cancellable FFI lifetime.
    func acquireNativeDeviceSessionLease(waitTimeout: TimeInterval = 0) async -> Lease? {
        guard let lease = activeLeases.last(where: {
            [
                .signing, .installing, .renewing, .managingDeviceProfiles,
                .scanningDeviceInventory
            ].contains($0.kind)
        }) else {
            let lease: Lease?
            if let immediateLease = begin(.scanningDeviceInventory) {
                lease = immediateLease
            } else if waitTimeout > 0 {
                lease = await beginWaiting(.scanningDeviceInventory, timeout: waitTimeout)
            } else {
                lease = nil
            }
            guard let lease else { return nil }
            nativeDeviceCallCounts[lease.id] = 1
            nativeDeviceLeasesCreatedByNativeCall.insert(lease.id)
            return lease
        }
        nativeDeviceCallCounts[lease.id, default: 0] += 1
        return lease
    }

    func releaseDeviceSessionLeaseAfterNativeCall(_ lease: Lease) {
        let remaining = max(0, nativeDeviceCallCounts[lease.id, default: 0] - 1)
        if remaining == 0 {
            nativeDeviceCallCounts.removeValue(forKey: lease.id)
            let createdHere = nativeDeviceLeasesCreatedByNativeCall.remove(lease.id) != nil
            let ending = leasesEndingAfterNativeCalls.remove(lease.id) != nil
            if createdHere || ending {
                removeLease(id: lease.id)
            }
        } else {
            nativeDeviceCallCounts[lease.id] = remaining
        }
    }

    func hasConflict(for kind: Kind, appID: UUID? = nil, accountID: UUID? = nil) -> Bool {
        activeLeases.contains { active in
            Self.conflicts(active, with: kind, appID: appID, accountID: accountID)
        }
    }

    func blockingLease(for kind: Kind, appID: UUID? = nil, accountID: UUID? = nil) -> Lease? {
        activeLeases.first {
            Self.conflicts($0, with: kind, appID: appID, accountID: accountID)
        }
    }

    /// Only operations that can replace or remove an installed app defer presence reconciliation.
    /// Pairing and profile maintenance do not change the app list; local inventory stays usable.
    var hasDeviceSessionConflict: Bool {
        activeLeases.contains { lease in
            switch lease.kind {
            case .signing, .installing, .renewing:
                return true
            case .resettingPairing, .scanningDeviceInventory, .managingDeviceProfiles,
                 .importing, .updatingApp, .managingAccount, .managingCertificate, .maintainingStorage:
                return false
            }
        }
    }

    /// 异步等冲突操作结束；前台请求默认不设截止时间，可由所属任务取消。
    func beginWaiting(
        _ kind: Kind,
        appID: UUID? = nil,
        accountID: UUID? = nil,
        timeout: TimeInterval? = nil
    ) async -> Lease? {
        let deadline = timeout.flatMap { $0.isFinite ? Date().addingTimeInterval($0) : nil }
        while true {
            guard Task.isCancelled == false else { return nil }
            if let deadline, Date() >= deadline { return nil }
            if let lease = begin(kind, appID: appID, accountID: accountID) {
                return lease
            }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return nil
            }
        }
        return nil
    }

    func conflictFailure(requested: Kind) -> ImportFailure {
        let activeTitle = blockingLease(for: requested)?.kind.title ?? "其他操作"
        return ImportFailure(
            title: "暂时无法执行",
            reason: "\(activeTitle)，为避免签名、证书或文件状态互相覆盖，当前操作已阻止。",
            recovery: "等待当前操作完成后重试",
            code: "SEAL-OP-001"
        )
    }

    private func removeLease(id: UUID) {
        let previousCount = activeLeases.count
        let releasedKind = activeLeases.first(where: { $0.id == id })?.kind
        activeLeases.removeAll { $0.id == id }
        if activeLeases.count != previousCount {
            onLeaseReleased?()
            if let releasedKind {
                switch releasedKind {
                case .signing, .installing, .renewing, .resettingPairing, .managingDeviceProfiles:
                    NotificationCenter.default.post(name: .sealDeviceSessionWriterReleased, object: nil)
                case .importing, .updatingApp, .managingCertificate, .managingAccount,
                     .maintainingStorage, .scanningDeviceInventory:
                    break
                }
            }
        }
    }

    private static func conflicts(
        _ active: Lease,
        with requestedKind: Kind,
        appID requestedAppID: UUID?,
        accountID requestedAccountID: UUID?
    ) -> Bool {
        let activeKind = active.kind
        let deviceWork: Set<Kind> = [.signing, .installing, .renewing]
        let profileWork: Set<Kind> = [.managingDeviceProfiles]
        let inventoryWork: Set<Kind> = [.scanningDeviceInventory]

        // The read-only inventory lease covers one native call, not a user transaction.
        // Shared profile calls have their own native-call gate, so background inventory must
        // never reject a signing, install, or renewal action at its entry point.
        if inventoryWork.contains(activeKind), inventoryWork.contains(requestedKind) {
            return true
        }
        let accountWork: Set<Kind> = [.managingAccount, .managingCertificate]

        if deviceWork.contains(activeKind), deviceWork.contains(requestedKind) {
            return true
        }
        if profileWork.contains(activeKind), profileWork.contains(requestedKind) {
            return true
        }

        if activeKind == .resettingPairing || requestedKind == .resettingPairing {
            if activeKind == .resettingPairing, requestedKind == .resettingPairing { return true }
            let otherKind = activeKind == .resettingPairing ? requestedKind : activeKind
            return deviceWork.contains(otherKind)
                || profileWork.contains(otherKind)
                || inventoryWork.contains(otherKind)
                || accountWork.contains(otherKind)
        }

        if accountWork.contains(activeKind), accountWork.contains(requestedKind) {
            return scopesConflict(active.accountID, requestedAccountID)
        }

        if accountWork.contains(activeKind), deviceWork.contains(requestedKind) {
            return scopesConflict(active.accountID, requestedAccountID)
        }
        if deviceWork.contains(activeKind), accountWork.contains(requestedKind) {
            return scopesConflict(active.accountID, requestedAccountID)
        }

        if activeKind == .maintainingStorage || requestedKind == .maintainingStorage {
            let storageSensitive: Set<Kind> = [
                .importing, .updatingApp, .signing, .installing, .renewing, .maintainingStorage
            ]
            return storageSensitive.contains(activeKind) && storageSensitive.contains(requestedKind)
        }

        if activeKind == .importing, requestedKind == .importing { return true }

        if activeKind == .updatingApp || requestedKind == .updatingApp {
            let appIDMatches = active.appID == nil || requestedAppID == nil || active.appID == requestedAppID
            let appScopedWork: Set<Kind> = [.updatingApp, .signing, .installing, .renewing]
            return appIDMatches
                && appScopedWork.contains(activeKind)
                && appScopedWork.contains(requestedKind)
        }

        return false
    }

    private static func scopesConflict(_ lhs: UUID?, _ rhs: UUID?) -> Bool {
        lhs == nil || rhs == nil || lhs == rhs
    }
}
