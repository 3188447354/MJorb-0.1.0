import Foundation
import ZIPFoundation
@testable import Seal

enum IPAArchiveFixture {
    private enum FixtureError: Error {
        case invalidZIP
    }

    struct AppSpec {
        let directoryName: String
        let bundleIdentifier: String
        let name: String
        let version: String
        let buildNumber: String
        let malformedInfo: Bool

        init(
            directoryName: String = "Demo.app",
            bundleIdentifier: String = "com.example.demo",
            name: String = "Demo",
            version: String = "1.2.3",
            buildNumber: String = "45",
            malformedInfo: Bool = false
        ) {
            self.directoryName = directoryName
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.version = version
            self.buildNumber = buildNumber
            self.malformedInfo = malformedInfo
        }
    }

    static func make(
        apps: [AppSpec] = [AppSpec()],
        includeInfo: Bool = true,
        includeIcon: Bool = true,
        includeShareExtension: Bool = false,
        includeEntitlements: Bool = false,
        includeMobileProvision: Bool = false,
        extraEntries: [(path: String, data: Data)] = [],
        extensionMobileProvision: Data? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "SealTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appending(path: "Fixture.ipa")
        let archive = try Archive(url: archiveURL, accessMode: .create)

        for app in apps {
            let appRoot = "Payload/\(app.directoryName)"
            if includeInfo {
                let infoData: Data
                if app.malformedInfo {
                    infoData = Data("not a property list".utf8)
                } else {
                    let info: [String: Any] = [
                        "CFBundleDisplayName": app.name,
                        "CFBundleIdentifier": app.bundleIdentifier,
                        "CFBundleShortVersionString": app.version,
                        "CFBundleVersion": app.buildNumber,
                        "CFBundleExecutable": app.name,
                        "CFBundleIcons": [
                            "CFBundlePrimaryIcon": [
                                "CFBundleIconFiles": ["AppIcon60x60"]
                            ]
                        ]
                    ]
                    infoData = try propertyListData(info)
                }
                try add(infoData, path: "\(appRoot)/Info.plist", to: archive)
            }

            if includeInfo && app.malformedInfo == false {
                try add(Data(repeating: 0, count: 32), path: "\(appRoot)/\(app.name)", to: archive)
            }

            if includeIcon {
                try add(Data("fixture-icon".utf8), path: "\(appRoot)/AppIcon60x60@3x.png", to: archive)
            }

            if includeEntitlements {
                let entitlements = try propertyListData([
                    "aps-environment": "development",
                    "com.apple.security.application-groups": ["group.example.demo"]
                ])
                try add(entitlements, path: "\(appRoot)/archived-expanded-entitlements.xcent", to: archive)
            }

            if includeShareExtension {
                let extensionInfo = try propertyListData([
                    "CFBundleDisplayName": "Share",
                    "CFBundleIdentifier": "\(app.bundleIdentifier).share",
                    "CFBundleExecutable": "Share",
                    "NSExtension": [
                        "NSExtensionPointIdentifier": "com.apple.share-services"
                    ]
                ])
                try add(
                    extensionInfo,
                    path: "\(appRoot)/PlugIns/Share.appex/Info.plist",
                    to: archive
                )
                if includeMobileProvision {
                    try add(
                        extensionMobileProvision ?? Self.makeMinimalMobileProvisionData(),
                        path: "\(appRoot)/PlugIns/Share.appex/embedded.mobileprovision",
                        to: archive
                    )
                    try add(
                        Data("share-extension-executable".utf8),
                        path: "\(appRoot)/PlugIns/Share.appex/Share",
                        to: archive
                    )
                }
            }

            if includeMobileProvision {
                try add(
                    Self.makeMinimalMobileProvisionData(),
                    path: "\(appRoot)/embedded.mobileprovision",
                    to: archive
                )
            }
        }

        for entry in extraEntries {
            try add(entry.data, path: entry.path, to: archive)
        }

        return archiveURL
    }

    static func clearUTF8FilenameFlag(in archiveURL: URL) throws {
        var data = try Data(contentsOf: archiveURL)
        let minimumEndRecordSize = 22
        let searchStart = max(0, data.count - minimumEndRecordSize - Int(UInt16.max))
        let endRecordOffset = (searchStart...(data.count - minimumEndRecordSize))
            .reversed()
            .first { offset in
                data[offset] == 0x50
                    && data[offset + 1] == 0x4B
                    && data[offset + 2] == 0x05
                    && data[offset + 3] == 0x06
                    && offset + minimumEndRecordSize + Int(readUInt16(data, at: offset + 20)) == data.count
            }
        guard let endRecordOffset else { throw FixtureError.invalidZIP }

        let entryCount = Int(readUInt16(data, at: endRecordOffset + 10))
        var centralOffset = Int(readUInt32(data, at: endRecordOffset + 16))
        for _ in 0..<entryCount {
            guard centralOffset + 46 <= data.count,
                  data[centralOffset] == 0x50,
                  data[centralOffset + 1] == 0x4B,
                  data[centralOffset + 2] == 0x01,
                  data[centralOffset + 3] == 0x02 else {
                throw FixtureError.invalidZIP
            }
            clearUTF8Flag(in: &data, at: centralOffset + 8)
            let localHeaderOffset = Int(readUInt32(data, at: centralOffset + 42))
            guard localHeaderOffset + 8 <= data.count else { throw FixtureError.invalidZIP }
            clearUTF8Flag(in: &data, at: localHeaderOffset + 6)

            centralOffset += 46
                + Int(readUInt16(data, at: centralOffset + 28))
                + Int(readUInt16(data, at: centralOffset + 30))
                + Int(readUInt16(data, at: centralOffset + 32))
        }
        try data.write(to: archiveURL)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func clearUTF8Flag(in data: inout Data, at offset: Int) {
        let flags = readUInt16(data, at: offset) & ~0x0800
        data[offset] = UInt8(truncatingIfNeeded: flags)
        data[offset + 1] = UInt8(truncatingIfNeeded: flags >> 8)
    }

    private static func propertyListData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

    private static func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    /// 供 SignedIPAIdentityReader / SignedArtifactProfileReader 测试使用的最小描述文件数据。
    /// DeveloperCertificates 使用真实 DER X.509 证书，确保 ProvisioningProfileReader
    /// 能通过 SecCertificateCreateWithData 解析出证书序列号与指纹。
    static func makeMinimalMobileProvisionData(
        uuid: String = "FIXTURE-PROFILE-UUID",
        bundleIdentifier: String = "com.example.seal"
    ) -> Data {
        let certificateEntries = [
            "<data>\(TestDeveloperCertificate.certificateBDER.base64EncodedString())</data>"
        ].joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>UUID</key>
            <string>\(uuid)</string>
            <key>Name</key>
            <string>Fixture Profile</string>
            <key>CreationDate</key>
            <date>2026-01-01T00:00:00Z</date>
            <key>ExpirationDate</key>
            <date>2027-01-01T00:00:00Z</date>
            <key>TeamIdentifier</key>
            <array><string>TTEAM000001</string></array>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>TTEAM000001.\(bundleIdentifier)</string>
            </dict>
            <key>DeveloperCertificates</key>
            <array>\(certificateEntries)</array>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    /// 生成一个带描述文件和可执行文件的 Signed Seal IPA fixture，并返回 AppBundleSigningIdentityReader。
    /// 测试可通过 inspector 闭包控制每个可执行文件的 CMS 读取结果。
    static func signedSeal(
        mainSigner: String,
        extensionSigner: String
    ) throws -> (data: Data, reader: AppBundleSigningIdentityReader) {
        let archiveURL = try make(
            apps: [AppSpec(
                directoryName: "Seal.app",
                bundleIdentifier: "com.example.seal",
                name: "Seal",
                version: "1.0.0",
                buildNumber: "1"
            )],
            includeShareExtension: true,
            includeMobileProvision: true
        )
        let data = try Data(contentsOf: archiveURL)
        let reader = AppBundleSigningIdentityReader { url in
            let serial = url.path.contains("PlugIns") ? extensionSigner : mainSigner
            return ExecutableSignerEvidence(serialNumber: serial, cmsValid: true, codeDirectoryValid: true)
        }
        return (data, reader)
    }
}
