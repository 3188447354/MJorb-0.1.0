import Foundation
import CoreGraphics
import ObjectiveC.runtime
import UIKit

/// 扫描设备上已安装的 App（私有 API）。
/// 用于重装 Seal 后找回之前签过的应用。
/// 可从 LaunchServices 读取基本信息与图标；设备扫描不会导出 IPA 文件。
final class InstalledAppScanner: Sendable {

    struct ScannedApp: Sendable {
        let bundleIdentifier: String
        let name: String
        let version: String
        let buildNumber: String
        let teamID: String?
        let sealManagedMarkerVersion: Int?
    }

    /// 扫描所有已安装的应用，返回 Bundle ID -> ScannedApp
    /// 使用 LSApplicationWorkspace 私有 API，旁加载可用。
    func scanAll() async -> [ScannedApp] {
        await scanAllSnapshot() ?? []
    }

    /// `nil` 表示系统清单不可读取；空数组表示成功读到空清单。
    /// 同步设备列表时必须区分两者，不能把读取失败当成“全部卸载”。
    func scanAllSnapshot() async -> [ScannedApp]? {
        await scanAllSnapshot(allowPartialForRecovery: false)
    }

    /// 恢复记录只会新增本机明确存在的 App，不会据此删除记录；因此只要任一系统枚举源有结果就可用。
    func scanAllSnapshot(allowPartialForRecovery: Bool) async -> [ScannedApp]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = Self.scanSync(allowPartialForRecovery: allowPartialForRecovery)
                continuation.resume(returning: apps)
            }
        }
    }

    /// 只读取指定候选应用的系统图标，避免为整台设备上的应用解码图像。
    func scanIconData(for normalizedBundleIdentifiers: Set<String>) async -> [String: Data] {
        guard normalizedBundleIdentifiers.isEmpty == false else { return [:] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Self.scanIconDataSync(for: normalizedBundleIdentifiers)
                )
            }
        }
    }

    private static func scanSync(allowPartialForRecovery: Bool) -> [ScannedApp]? {
        // 模拟器上跳过：私有 API 在模拟器上行为不可靠，且模拟器里不会有 Seal 装过的 App
        #if targetEnvironment(simulator)
        return nil
        #endif
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return nil
        }
        guard let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        guard let appLists = installedApplicationProxyLists(from: workspace) else {
            return nil
        }

        var appList: [NSObject] = []
        var seenBundleIdentifiers = Set<String>()
        // The two LaunchServices selectors can return different snapshots. Merge both
        // before treating the result as the device inventory so an app present in only
        // the compatibility selector is not silently omitted.
        for applications in appLists {
            for application in applications {
                guard let bundleIdentifier = application.value(forKey: "bundleIdentifier") as? String else {
                    continue
                }
                let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard normalized.isEmpty == false,
                      seenBundleIdentifiers.insert(normalized).inserted else {
                    continue
                }
                appList.append(application)
            }
        }
        if allowPartialForRecovery == false,
           appLists.count == 1,
           InstalledAppRefreshProbePolicy.hasPositiveControl(
                controlBundleIdentifier: Bundle.main.bundleIdentifier,
                installedBundleIdentifiers: appList.compactMap {
                    $0.value(forKey: "bundleIdentifier") as? String
                }
           ) == false {
            // One selector alone may be a partial compatibility view. Without Seal as a
            // positive control, do not let it remove records that only the missing view has.
            return nil
        }

        var result: [ScannedApp] = []
        for app in appList {
            guard let bundleID = app.value(forKey: "bundleIdentifier") as? String,
                  !bundleID.isEmpty else { continue }
            // 跳过系统应用和 Seal 自己（按需过滤）
            if bundleID.hasPrefix("com.apple.") { continue }

            let name = (app.value(forKey: "localizedName") as? String)
                ?? (app.value(forKey: "bundleIdentifier") as? String)
                ?? bundleID
            let version = (app.value(forKey: "bundleVersion") as? String) ?? ""
            let build = (app.value(forKey: "bundleShortVersionString") as? String) ?? ""
            let teamID = stringValue("teamID", on: app)
            result.append(ScannedApp(
                bundleIdentifier: bundleID,
                name: name,
                version: build.isEmpty ? version : build,
                buildNumber: version,
                teamID: teamID,
                sealManagedMarkerVersion: SealInstalledAppMarker.isDeclared(for: bundleID)
                    ? SealInstalledAppMarker.version
                    : nil
            ))
        }
        return result
    }

    private static func scanIconDataSync(for bundleIdentifiers: Set<String>) -> [String: Data] {
        #if targetEnvironment(simulator)
        return [:]
        #endif
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass
                .perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return [:]
        }

        var result: [String: Data] = [:]
        // The two LaunchServices selectors are not guaranteed to return the same snapshot.
        // For a targeted icon lookup, inspect both so a partial first list cannot hide an
        // installed app that only appears in the compatibility selector.
        for appList in installedApplicationProxyLists(from: workspace) ?? [] {
            for app in appList {
                guard let bundleID = app.value(forKey: "bundleIdentifier") as? String else { continue }
                let normalizedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard bundleIdentifiers.contains(normalizedBundleID),
                      result[normalizedBundleID] == nil,
                      let iconData = iconPNGData(from: app) else {
                    continue
                }
                result[normalizedBundleID] = iconData
            }
        }
        return result
    }

    private static func installedApplicationProxyLists(from workspace: NSObject) -> [[NSObject]]? {
        var lists: [[NSObject]] = []
        for name in ["allInstalledApplications", "allApplications"] {
            let selector = NSSelectorFromString(name)
            guard workspace.responds(to: selector),
                  let applications = workspace.perform(selector)?.takeUnretainedValue() as? [NSObject] else {
                continue
            }
            lists.append(applications)
        }
        return lists.isEmpty ? nil : lists
    }

    private static func stringValue(_ property: String, on object: NSObject) -> String? {
        let selector = NSSelectorFromString(property)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private static func iconPNGData(from application: NSObject) -> Data? {
        let selector = NSSelectorFromString("iconDataForVariant:")
        guard application.responds(to: selector),
              let method = class_getInstanceMethod(type(of: application), selector) else {
            return nil
        }

        typealias IconDataFunction = @convention(c) (
            AnyObject,
            Selector,
            Int32
        ) -> Unmanaged<AnyObject>?
        let function = unsafeBitCast(method_getImplementation(method), to: IconDataFunction.self)
        guard let object = function(application, selector, 2)?.takeUnretainedValue(),
              let data = object as? Data else {
            return nil
        }
        return decodeLaunchServicesIconData(data)
    }

    static func decodeLaunchServicesIconData(_ data: Data) -> Data? {
        if let image = UIImage(data: data), let pngData = image.pngData() {
            return pngData
        }

        // Older LaunchServices versions return a 32-byte header followed by BGRA pixels.
        // Infer the square icon size from the buffer length; reject unknown layouts safely.
        let headerLength = 32
        guard data.count > headerLength, data.count <= 2 * 1_024 * 1_024 else { return nil }
        let pixelDataLength = data.count - headerLength
        guard pixelDataLength.isMultiple(of: MemoryLayout<UInt32>.size) else { return nil }
        let pixelCount = pixelDataLength / MemoryLayout<UInt32>.size

        let squareWidth = Int(Double(pixelCount).squareRoot())
        let width: Int
        let bytesPerRow: Int
        if squareWidth * squareWidth == pixelCount {
            width = squareWidth
            bytesPerRow = width * MemoryLayout<UInt32>.size
        } else {
            let paddedWidth = Int((sqrt(Double(1 + 4 * pixelCount)) - 1) / 2)
            guard paddedWidth * (paddedWidth + 1) == pixelCount else { return nil }
            width = paddedWidth
            bytesPerRow = (width + 1) * MemoryLayout<UInt32>.size
        }
        guard (16...512).contains(width),
              let provider = CGDataProvider(data: data.subdata(in: headerLength..<data.count) as CFData) else {
            return nil
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        guard let cgImage = CGImage(
            width: width,
            height: width,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage).pngData()
    }
}
