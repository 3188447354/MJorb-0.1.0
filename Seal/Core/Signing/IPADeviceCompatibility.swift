import Darwin
import Foundation

struct IPADeviceCompatibilityMetadata: Equatable, Sendable {
    let supportedDevices: [String]?
    let minimumOSVersion: String?
}

enum IPADeviceCompatibility {
    static func currentModelIdentifier() -> String? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        let capacity = MemoryLayout.size(ofValue: systemInfo.machine)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                let value = String(cString: $0)
                return value.isEmpty ? nil : value
            }
        }
    }

    static func failure(
        metadata: IPADeviceCompatibilityMetadata,
        modelIdentifier: String,
        operatingSystemVersion: OperatingSystemVersion
    ) -> ImportFailure? {
        if let supportedDevices = metadata.supportedDevices,
           supportedDevices.isEmpty == false,
           supportedDevices.contains(where: {
               $0.caseInsensitiveCompare(modelIdentifier) == .orderedSame
           }) == false {
            return ImportFailure(
                title: "应用不支持当前设备",
                reason: "IPA 声明支持的设备不包含当前机型（\(modelIdentifier)），Apple 安装服务会拒绝安装。Seal 尚未申请本次签名资源。",
                recovery: "获取支持当前设备型号的 IPA 后重试",
                code: "SEAL-IPA-107"
            )
        }

        if let minimumOSVersion = metadata.minimumOSVersion,
           requiresNewerOperatingSystem(minimumOSVersion, than: operatingSystemVersion) {
            return ImportFailure(
                title: "当前系统版本过低",
                reason: "IPA 要求 iOS \(minimumOSVersion) 或更高版本；当前设备系统为 \(versionString(operatingSystemVersion))。Seal 尚未申请本次签名资源。",
                recovery: "更新设备系统，或获取支持当前 iOS 版本的 IPA",
                code: "SEAL-IPA-108"
            )
        }
        return nil
    }

    private static func requiresNewerOperatingSystem(
        _ minimumVersion: String,
        than currentVersion: OperatingSystemVersion
    ) -> Bool {
        let required = minimumVersion.split(separator: ".").compactMap { Int($0) }
        guard required.isEmpty == false,
              required.count == minimumVersion.split(separator: ".").count else { return false }
        let current = [
            currentVersion.majorVersion,
            currentVersion.minorVersion,
            currentVersion.patchVersion
        ]
        for index in 0..<max(3, required.count) {
            let requiredComponent = index < required.count ? required[index] : 0
            let currentComponent = index < current.count ? current[index] : 0
            if requiredComponent != currentComponent {
                return requiredComponent > currentComponent
            }
        }
        return false
    }

    private static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
