import Foundation

struct ArchiveLimits: Equatable, Sendable {
    let maximumEntryCount: Int
    let maximumMetadataSize: UInt64
    let maximumIconSize: UInt64

    init(
        maximumEntryCount: Int = 50_000,
        maximumMetadataSize: UInt64 = 2 * 1_024 * 1_024,
        maximumIconSize: UInt64 = 20 * 1_024 * 1_024
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumMetadataSize = maximumMetadataSize
        self.maximumIconSize = maximumIconSize
    }
}
