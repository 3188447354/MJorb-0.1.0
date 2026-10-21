import Foundation

/// 已安装页是尽力读取，不得借用签名/安装后的长验证预算。
enum InstalledAppRefreshProbePolicy {
    /// 正常设备查询为亚秒级；超时后保留本地列表即可，无需让下拉手势转圈 15 秒。
    ///
    /// ⚠️ **保持 2 秒，不要动**（2026-09-26，构建 46 真机复盘）。日志里三次
    /// `SEAL-INSTALL-707`（01:25:01 / 01:26:40 / 01:29:11）确实全部落在续签与自替换
    /// 进行中、2 秒预算必然超时 —— 但根因是**并发**（核验去抢签名链路正在用的设备会话），
    /// **不是预算太短**。把它调大只会让每次失败的等待更长，并让这条「尽力读取」的核验
    /// 悄悄借走安装链路的验证预算。
    /// ⇒ 正确的修法在调用方：`AppsViewModel.reconcileInstalledAppsWithDevice` 在有前台操作时
    /// **整体跳过**（不探测、不报错、不弹窗）。
    static let timeoutSeconds: Double = 2

    /// `BlockingCall` 超时不会停止底层 FFI。原生调用结束后仍留短暂冷却，避免连续操作
    /// 立即叠加到刚发生超时的设备会话上。
    static let timeoutCooldownSeconds: TimeInterval = 20

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

/// Device inventory and misagent profile operations share one device-session gate.
/// A timeout cannot cancel the synchronous FFI, so the gate stays occupied until its native
/// call completes; this prevents a timed-out read, injection, or cleanup from overlapping the next call.
actor InstalledAppRefreshProbeGate {
    enum Availability: Equatable {
        case ready(UUID)
        case inFlight
        case coolingDown
    }

    static let shared = InstalledAppRefreshProbeGate()

    private var activeProbeID: UUID?
    private var cooldownUntil = Date.distantPast

    func begin() -> Availability {
        guard Date() >= cooldownUntil else { return .coolingDown }
        guard activeProbeID == nil else { return .inFlight }
        let probeID = UUID()
        activeProbeID = probeID
        return .ready(probeID)
    }

    func finish(probeID: UUID, timedOut: Bool) {
        guard activeProbeID == probeID else { return }
        activeProbeID = nil
        if timedOut {
            cooldownUntil = Date().addingTimeInterval(InstalledAppRefreshProbePolicy.timeoutCooldownSeconds)
        }
    }
}
