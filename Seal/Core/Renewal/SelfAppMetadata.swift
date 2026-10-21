import Foundation
import UIKit

struct SelfAppMetadata: Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
    let originalBundleIdentifier: String?
    let name: String
    let version: String
    let buildNumber: String
    let iconData: Data?
    let expirationDate: Date?
    let signingTeamIdentifier: String?
    let signingApplicationIdentifier: String?
    /// 运行中包内 `embedded.mobileprovision` 的身份。同版本续签会换掉 profile 但**版本号不变**，
    /// 因此 profile 身份是判断「续签是否真的生效」的唯一可观测证据（见 R07）。
    var provisioningProfileUUID: String? = nil
    var provisioningProfileName: String? = nil
    var provisioningProfileCreationDate: Date? = nil
    /// 运行包描述文件里授权的证书序列号列表。Seal 注册时必须从这里取真实的证书序列号，
    /// 而不是继承旧记录——爱思/其他工具签的 Seal，证书不是 Seal 创建的，
    /// 如果记录里存的是旧值或 nil，前置清理会误撤 Seal 在用的证书导致变砖。
    var certificateSerialNumbers: [String] = []
    /// 主程序和全部扩展的真实 CMS 签名身份。读取失败时本字段为 nil，
    /// 撤销/接管等高风险操作因此关闭，但 Seal 自身记录仍应正常注册。
    var installedIdentity: InstalledIdentity? = nil
    /// 当前运行包实际包含的扩展；nil 表示无法读取，空数组表示确认没有扩展。
    var extensionRecords: [AppExtensionRecord]? = nil

    /// 轮次级短 TTL 缓存（性能优化 2026-10-04）：每轮续签调 2 次 `current()`，
    /// 每次 = mobileprovision 磁盘读 + CMS 解析 + Mach-O 全解析 + 图标 PNG 解码。
    /// 10 秒 TTL 覆盖一轮；自替换换包时调 `invalidateCache()` 失效。
    @MainActor
    private static var cachedMetadata: (value: SelfAppMetadata, at: Date)?
    @MainActor
    private static let cacheTTL: TimeInterval = 10

    private struct ParsedRunningBundleMetadata: Sendable {
        let expirationDate: Date?
        let teamIdentifier: String?
        let applicationIdentifier: String?
        let profileUUID: String?
        let profileName: String?
        let profileCreationDate: Date?
        let certificateSerialNumbers: [String]
        let installedIdentity: InstalledIdentity?
        let extensionRecords: [AppExtensionRecord]?
    }

    @MainActor
    static func invalidateCache() {
        cachedMetadata = nil
    }

    @MainActor
    static func current(
        bundle: Bundle = .main,
        identityReader: AppBundleSigningIdentityReader = .init(),
        includeIcon: Bool = true
    ) -> SelfAppMetadata? {
        if let cached = cachedMetadata,
           Date().timeIntervalSince(cached.at) < cacheTTL {
            // 缓存命中时若调用方不要图标，直接返回（图标懒加载，见下）。
            if !includeIcon || cached.value.iconData != nil {
                return cached.value
            }
        }
        guard let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Seal"
        let version = (bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String) ?? "1.0"
        let buildNumber = (bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String) ?? "1"
        // 直接读取 .app 路径，不能依赖 Bundle 的资源查询缓存。自替换安装可能在当前
        // 进程尚未退出时原地更新 Seal.app；此时只有磁盘上的 embedded.mobileprovision
        // 能证明新包是否真的落盘。
        let profileURL = bundle.bundleURL.appending(path: "embedded.mobileprovision")
        // 用 details 而不是 summary：summary 不含 UUID/Name/CreationDate，
        // 而「同版本续签是否生效」只能靠 profile 身份判断。
        let profileDetails = (try? Data(contentsOf: profileURL, options: .mappedIfSafe))
            .flatMap { try? ProvisioningProfileReader().details(from: $0) }

        // 读取真实 CMS 签名身份；失败时仍创建 SelfAppMetadata，但 installedIdentity 为 nil，
        // 所有撤销和接管操作因此关闭。
        let identity = try? identityReader.read(bundleURL: bundle.bundleURL)
        let extensionRecords = readExtensionRecords(
            bundleURL: bundle.bundleURL,
            installedIdentity: identity
        )

        let result = SelfAppMetadata(
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundleIdentifier,
            originalBundleIdentifier: bundle.object(
                forInfoDictionaryKey: "SealOriginalBundleIdentifier"
            ) as? String,
            name: name,
            version: version,
            buildNumber: buildNumber,
            iconData: includeIcon ? iconData(bundle: bundle) : nil,
            expirationDate: profileDetails?.expirationDate,
            signingTeamIdentifier: profileDetails?.teamIdentifier,
            signingApplicationIdentifier: profileDetails?.applicationIdentifier,
            provisioningProfileUUID: profileDetails?.uuid,
            provisioningProfileName: profileDetails?.name,
            provisioningProfileCreationDate: profileDetails?.creationDate,
            certificateSerialNumbers: profileDetails?.certificateSerialNumbers ?? [],
            installedIdentity: identity,
            extensionRecords: extensionRecords
        )
        cachedMetadata = (result, Date())
        return result
    }

    /// Loads Seal's registration metadata without parsing CMS signatures or provisioning
    /// profiles on the main actor during application startup.
    @MainActor
    static func loadCurrentAsync() async -> SelfAppMetadata? {
        if let cached = cachedMetadata,
           Date().timeIntervalSince(cached.at) < cacheTTL,
           cached.value.iconData != nil {
            return cached.value
        }

        let bundle = Bundle.main
        guard let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        let bundleURL = bundle.bundleURL
        let originalBundleIdentifier = bundle.object(
            forInfoDictionaryKey: "SealOriginalBundleIdentifier"
        ) as? String
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Seal"
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let buildNumber = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"

        let parsed = await Task.detached(priority: .utility) {
            let profileURL = bundleURL.appending(path: "embedded.mobileprovision")
            let profileDetails = (try? Data(contentsOf: profileURL, options: .mappedIfSafe))
                .flatMap { try? ProvisioningProfileReader().details(from: $0) }
            let identity = try? AppBundleSigningIdentityReader().read(bundleURL: bundleURL)
            return ParsedRunningBundleMetadata(
                expirationDate: profileDetails?.expirationDate,
                teamIdentifier: profileDetails?.teamIdentifier,
                applicationIdentifier: profileDetails?.applicationIdentifier,
                profileUUID: profileDetails?.uuid,
                profileName: profileDetails?.name,
                profileCreationDate: profileDetails?.creationDate,
                certificateSerialNumbers: profileDetails?.certificateSerialNumbers ?? [],
                installedIdentity: identity,
                extensionRecords: readExtensionRecords(bundleURL: bundleURL, installedIdentity: identity)
            )
        }.value

        let result = SelfAppMetadata(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            originalBundleIdentifier: originalBundleIdentifier,
            name: name,
            version: version,
            buildNumber: buildNumber,
            iconData: iconData(bundle: bundle),
            expirationDate: parsed.expirationDate,
            signingTeamIdentifier: parsed.teamIdentifier,
            signingApplicationIdentifier: parsed.applicationIdentifier,
            provisioningProfileUUID: parsed.profileUUID,
            provisioningProfileName: parsed.profileName,
            provisioningProfileCreationDate: parsed.profileCreationDate,
            certificateSerialNumbers: parsed.certificateSerialNumbers,
            installedIdentity: parsed.installedIdentity,
            extensionRecords: parsed.extensionRecords
        )
        cachedMetadata = (result, Date())
        return result
    }

    /// Reads only the running app's signed identity off the UI actor.
    /// Signing and certificate safety checks need the Mach-O CMS signer, not the icon or
    /// other presentation metadata that `current()` also gathers.
    static func installedIdentitySnapshot() async -> InstalledIdentity? {
        let bundleURL = Bundle.main.bundleURL
        return await Task.detached(priority: .utility) {
            try? AppBundleSigningIdentityReader().read(bundleURL: bundleURL)
        }.value
    }

    static func readExtensionRecords(
        bundleURL: URL,
        installedIdentity: InstalledIdentity?
    ) -> [AppExtensionRecord]? {
        let pluginsURL = bundleURL.appending(path: "PlugIns", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: pluginsURL.path) else { return [] }
        guard let appexURLs = try? FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil
        )
        .filter({ $0.pathExtension == "appex" })
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return nil
        }

        var records: [AppExtensionRecord] = []
        for appexURL in appexURLs {
            let infoURL = appexURL.appending(path: "Info.plist")
            guard let data = try? Data(contentsOf: infoURL, options: .mappedIfSafe),
                  let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let info = propertyList as? [String: Any],
                  let bundleIdentifier = info["CFBundleIdentifier"] as? String,
                  bundleIdentifier.isEmpty == false else {
                return nil
            }

            let target = installedIdentity?.targets.first {
                $0.kind == .appExtension
                    && $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
                    && $0.isComplete
            }
            let extensionPoint = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? appexURL.deletingPathExtension().lastPathComponent

            records.append(
                AppExtensionRecord(
                    name: name,
                    originalBundleIdentifier: (info["SealOriginalBundleIdentifier"] as? String)
                        ?? bundleIdentifier,
                    mappedBundleIdentifier: bundleIdentifier,
                    kind: extensionKind(for: extensionPoint),
                    provisioningProfileUUID: target?.profileUUID,
                    provisioningProfileExpirationDate: target?.profileExpirationDate,
                    certificateSerialNumber: target?.signerSerialNumber
                )
            )
        }
        return records
    }

    private static func extensionKind(for pointIdentifier: String?) -> AppExtensionKind {
        switch pointIdentifier {
        case "com.apple.share-services": .share
        case "com.apple.usernotifications.service": .notificationService
        case "com.apple.widgetkit-extension", "com.apple.widget-extension": .widget
        default: .unknown
        }
    }

    @MainActor
    private static func iconData(bundle: Bundle) -> Data? {
        let names = iconFileNames(bundle: bundle)
        for name in names.reversed() {
            if let data = resourceIconData(name: name, bundle: bundle) { return data }
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil),
               let data = image.pngData() {
                return data
            }
        }

        for candidate in ["AppIcon", "SealIcon", "Icon", "iTunesArtwork", "iTunesArtwork@2x"] {
            if let data = resourceIconData(name: candidate, bundle: bundle) { return data }
            if let image = UIImage(named: candidate, in: bundle, compatibleWith: nil),
               let data = image.pngData() {
                return data
            }
        }
        return nil
    }

    private static func iconFileNames(bundle: Bundle) -> [String] {
        let info = bundle.infoDictionary ?? [:]
        var names: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primaryIcon["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        if let files = info["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    private static func resourceIconData(name: String, bundle: Bundle) -> Data? {
        let url = URL(fileURLWithPath: name)
        let resourceName = url.deletingPathExtension().lastPathComponent
        let resourceExtension = url.pathExtension
        let extensions = resourceExtension.isEmpty ? ["png", ""] : [resourceExtension]
        for ext in extensions {
            let found = ext.isEmpty
                ? bundle.url(forResource: resourceName, withExtension: nil)
                : bundle.url(forResource: resourceName, withExtension: ext)
            if let found, let data = try? Data(contentsOf: found, options: .mappedIfSafe) {
                return data
            }
        }
        return nil
    }
}
