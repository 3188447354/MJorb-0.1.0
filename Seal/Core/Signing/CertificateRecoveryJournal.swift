import Foundation

struct CertificateRecoveryJournalEntry: Codable, Equatable, Sendable {
    let accountID: UUID
    var revokedSerialNumbers: [String]
    var updatedAt: Date
}

/// 已确认撤销、但仍可能影响设备上应用的证书记录。
/// 只保存序列号和账号本地 ID，不保存 Apple 凭据；恢复仍须由用户发起一次签名操作。
actor CertificateRecoveryJournalStore {
    enum StoreError: Error {
        case unreadable
    }

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func revokedSerialNumbers(for accountID: UUID) throws -> [String] {
        try load().first(where: { $0.accountID == accountID })?.revokedSerialNumbers ?? []
    }

    func record(accountID: UUID, revokedSerialNumbers: [String]) throws {
        let normalized = Set(revokedSerialNumbers.map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        }.filter { !$0.isEmpty })
        guard normalized.isEmpty == false else { return }

        var entries = try load()
        if let index = entries.firstIndex(where: { $0.accountID == accountID }) {
            entries[index].revokedSerialNumbers = Array(
                Set(entries[index].revokedSerialNumbers).union(normalized)
            ).sorted()
            entries[index].updatedAt = Date()
        } else {
            entries.append(CertificateRecoveryJournalEntry(
                accountID: accountID,
                revokedSerialNumbers: normalized.sorted(),
                updatedAt: Date()
            ))
        }
        try save(entries)
    }

    func clear(accountID: UUID) throws {
        try save(load().filter { $0.accountID != accountID })
    }

    private func load() throws -> [CertificateRecoveryJournalEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([CertificateRecoveryJournalEntry].self, from: data) else {
            throw StoreError.unreadable
        }
        return entries
    }

    private func save(_ entries: [CertificateRecoveryJournalEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries.sorted { $0.accountID.uuidString < $1.accountID.uuidString })
        try data.write(to: fileURL, options: .atomic)
    }
}
