import Foundation
import ZIPFoundation

enum IPAArchivePathEncoding: Equatable, Sendable {
    case utf8
    case archiveDefault

    var foundationEncoding: String.Encoding? {
        self == .utf8 ? .utf8 : nil
    }

    func path(for entry: Entry) -> String {
        switch self {
        case .utf8:
            return entry.path(using: .utf8)
        case .archiveDefault:
            return entry.path
        }
    }
}

enum IPAArchivePathPolicy {
    static func selectEncoding(
        utf8Archive: Archive?,
        defaultArchive: Archive,
        maximumMetadataSize: UInt64
    ) -> IPAArchivePathEncoding {
        if let utf8Archive,
           hasDeclaredMainExecutable(
               in: utf8Archive,
               pathEncoding: .utf8,
               maximumMetadataSize: maximumMetadataSize
           ) {
            return .utf8
        }
        if hasDeclaredMainExecutable(
            in: defaultArchive,
            pathEncoding: nil,
            maximumMetadataSize: maximumMetadataSize
        ) {
            return .archiveDefault
        }
        if let utf8Archive, hasMainAppInfo(in: utf8Archive, pathEncoding: .utf8) {
            return .utf8
        }
        return .archiveDefault
    }

    static func hasDeclaredMainExecutable(
        in archive: Archive,
        pathEncoding: String.Encoding?,
        maximumMetadataSize: UInt64
    ) -> Bool {
        let entries = Array(archive)
        func path(for entry: Entry) -> String {
            pathEncoding.map { entry.path(using: $0) } ?? entry.path
        }
        let infoEntries = entries.filter { entry in
            let components = path(for: entry).split(separator: "/")
            return components.count == 3
                && components[0] == "Payload"
                && components[1].hasSuffix(".app")
                && components[2] == "Info.plist"
        }
        guard infoEntries.count == 1,
              let infoEntry = infoEntries.first,
              infoEntry.uncompressedSize <= maximumMetadataSize else { return false }

        var infoData = Data()
        do {
            _ = try archive.extract(infoEntry) { chunk in
                let currentSize = UInt64(infoData.count)
                guard currentSize <= maximumMetadataSize,
                      UInt64(chunk.count) <= maximumMetadataSize - currentSize else {
                    throw CocoaError(.fileReadTooLarge)
                }
                infoData.append(chunk)
            }
        } catch {
            return false
        }
        guard let info = try? PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any],
        let executable = info["CFBundleExecutable"] as? String,
        executable.isEmpty == false,
        executable.contains("/") == false,
        executable.contains("\\") == false,
        executable.contains("\0") == false else { return false }

        let appRoot = path(for: infoEntry).split(separator: "/").dropLast().joined(separator: "/")
        let executablePath = "\(appRoot)/\(executable)"
        return entries.contains {
            path(for: $0) == executablePath && $0.type == .file && $0.uncompressedSize > 0
        }
    }

    private static func hasMainAppInfo(
        in archive: Archive,
        pathEncoding: String.Encoding?
    ) -> Bool {
        Array(archive).filter { entry in
            let path = pathEncoding.map { entry.path(using: $0) } ?? entry.path
            let components = path.split(separator: "/")
            return components.count == 3
                && components[0] == "Payload"
                && components[1].hasSuffix(".app")
                && components[2] == "Info.plist"
        }.count == 1
    }
}
