import CryptoKit
import Foundation
@preconcurrency import AltSign

protocol AnisetteProvider: Sendable {
    func fetch() async throws -> ALTAnisetteData
    /// 认证与后续门户请求使用同一份 Anisette，会话机器身份不得切换。
    func fetchForAuthentication() async throws -> ALTAnisetteData
    func resync(sim: String) async throws -> ALTAnisetteData
    func resetProvisioning() async
    /// 兼容旧调用；实现可以始终使用同一个远程 Anisette 会话。
    func preferRemoteOnNextFetch() async
}

extension AnisetteProvider {
    /// 默认无操作；只有同时具备本地/远程双通道的实现需要覆盖
    func preferRemoteOnNextFetch() async {}
    /// 默认走 fetch，确保认证与后续请求使用相同来源。
    func fetchForAuthentication() async throws -> ALTAnisetteData {
        try await fetch()
    }
    func resync(sim: String) async throws -> ALTAnisetteData {
        throw AnisetteV3Error.unavailable
    }
}

protocol AnisetteEnvironmentManaging: AnisetteProvider {
    func availableServers() async -> [AnisetteServer]
    func selectedServerID() async -> String?
    func selectServer(id: String) async
}

enum AnisetteV3Error: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidServerResponse
    case provisioningFailed
    case staleProvisioning
    case unavailable
    case localGenerationFailed(String)
}

// 手动实现 Equatable（因为有关联值）
extension AnisetteV3Error {
    static func == (lhs: AnisetteV3Error, rhs: AnisetteV3Error) -> Bool {
        switch (lhs, rhs) {
        case (.invalidIdentifier, .invalidIdentifier),
             (.invalidServerResponse, .invalidServerResponse),
             (.provisioningFailed, .provisioningFailed),
             (.staleProvisioning, .staleProvisioning),
             (.unavailable, .unavailable):
            return true
        case (.localGenerationFailed(let a), .localGenerationFailed(let b)):
            return a == b
        default:
            return false
        }
    }
}

struct AnisetteProvisioningState: Codable, Equatable, Sendable {
    let identifier: String
    let adiPB: String

    init?(identifier: String, adiPB: String) {
        guard identifier.isEmpty == false, adiPB.isEmpty == false else { return nil }
        self.identifier = identifier
        self.adiPB = adiPB
    }
}

struct AnisetteV3Identity: Equatable, Sendable {
    let encodedIdentifier: String
    let localUserID: String
    let deviceIdentifier: String

    init(bytes: Data) throws {
        guard bytes.count == 16 else {
            throw AnisetteV3Error.invalidIdentifier
        }

        encodedIdentifier = bytes.base64EncodedString()
        localUserID = SHA256.hash(data: bytes)
            .map { String(format: "%02X", $0) }
            .joined()

        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        deviceIdentifier = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-")
    }
}
