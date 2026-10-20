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
    }

    /// 扫描所有已安装的应用，返回 Bundle ID -> ScannedApp
    /// 使用 LSApplicationWorkspace 私有 API，旁加载可用。
    func scanAll() async -> [ScannedApp] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = Self.scanSync()
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

    private static func scanSync() -> [ScannedApp] {
        // 模拟器上跳过：私有 API 在模拟器上行为不可靠，且模拟器里不会有 Seal 装过的 App
        #if targetEnvironment(simulator)
        return []
        #endif
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return []
        }
        guard let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() else {
            return []
        }
        guard let appList = workspace.perform(NSSelectorFromString("allInstalledApplications"))?.takeUnretainedValue() as? [NSObject] else {
            return []
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
            // Team ID 需要从签名信息拿，这里先留空，调用方按需过滤
            result.append(ScannedApp(
                bundleIdentifier: bundleID,
                name: name,
                version: build.isEmpty ? version : build,
                buildNumber: version,
                teamID: nil
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
                .perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue(),
              let appList = workspace
                .perform(NSSelectorFromString("allInstalledApplications"))?.takeUnretainedValue() as? [NSObject] else {
            return [:]
        }

        var result: [String: Data] = [:]
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
        return result
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
