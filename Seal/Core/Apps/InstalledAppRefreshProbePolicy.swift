import Foundation

/// 已安装页是尽力读取，不得借用签名/安装后的长验证预算。
enum InstalledAppRefreshProbePolicy {
    /// 查询超时只影响本次核验；用户操作与只读清单各自调度，不共享全局忙碌状态。
    static let timeoutSeconds: Double = 2

    static func normalizedBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// 只在系统清单能找到正在运行的 Seal 时，才把它当作可信的完整设备快照。
    static func hasPositiveControl(
        controlBundleIdentifier: String?,
        installedBundleIdentifiers: [String]
    ) -> Bool {
        guard let control = normalizedBundleIdentifier(controlBundleIdentifier) else { return false }
        return installedBundleIdentifiers.contains {
            normalizedBundleIdentifier($0) == control
        }
    }

    /// LaunchServices may return a complete user-app snapshot without listing the caller itself.
    /// A non-empty successful snapshot is still useful; an empty one remains untrusted so a
    /// transiently empty result cannot mark every saved app as uninstalled.
    static func canUseLocalSnapshot(
        controlBundleIdentifier: String?,
        installedBundleIdentifiers: [String]
    ) -> Bool {
        hasPositiveControl(
            controlBundleIdentifier: controlBundleIdentifier,
            installedBundleIdentifiers: installedBundleIdentifiers
        ) || installedBundleIdentifiers.contains {
            normalizedBundleIdentifier($0) != nil
        }
    }

    static func contains(
        _ bundleIdentifier: String?,
        in installedBundleIdentifiers: Set<String>
    ) -> Bool {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else { return false }
        return installedBundleIdentifiers.contains(bundleIdentifier)
            || installedBundleIdentifiers.contains {
                normalizedBundleIdentifier($0) == bundleIdentifier
            }
    }
}

/// Each native service has its own gate. A timeout cannot cancel Swift's synchronous FFI, so
/// that service stays occupied until its late completion callback releases it; unrelated
/// services remain available.
actor InstalledAppRefreshProbeGate {
    enum Availability: Equatable {
        case ready(UUID)
        case inFlight
        case cancelled
    }

    /// InstallationProxy reads share a gate with each other.
    static let inventory = InstalledAppRefreshProbeGate()
    /// Misagent profile reads and writes share a separate gate.
    static let profiles = InstalledAppRefreshProbeGate()

    private var activeProbeID: UUID?
    private var waitingForegroundOperationCount = 0

    func begin() -> Availability {
        guard waitingForegroundOperationCount == 0, activeProbeID == nil else { return .inFlight }
        let probeID = UUID()
        activeProbeID = probeID
        return .ready(probeID)
    }

    /// Interactive misagent work waits behind the active native call. New profile reads yield
    /// while it waits, so they cannot repeatedly jump ahead.
    func beginForeground() async -> Availability {
        waitingForegroundOperationCount += 1
        defer { waitingForegroundOperationCount -= 1 }

        while true {
            guard Task.isCancelled == false else { return .cancelled }
            if activeProbeID == nil {
                let probeID = UUID()
                activeProbeID = probeID
                return .ready(probeID)
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return .cancelled
            }
        }
    }

    func finish(probeID: UUID) {
        guard activeProbeID == probeID else { return }
        activeProbeID = nil
    }
}
