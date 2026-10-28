import CryptoKit
import Foundation
@preconcurrency import AltSign

protocol AnisetteProvider: Sendable {
    func fetch() async throws -> ALTAnisetteData
    /// 认证与后续门户请求使用同一份 Anisette，会话机器身份不得切换。
    func fetchForAuthentication() async throws -> ALTAnisetteData
    /// 针对兼容重试，仅可读取当前共享环境，不能重建或清理其他账号使用的环境。
    func fetchForCompatibilityRetry(expectedDeviceID: String) async throws -> ALTAnisetteData
    func resync(sim: String) async throws -> ALTAnisetteData
    func resetProvisioning() async
}

extension AnisetteProvider {
    /// 默认走 fetch，确保认证与后续请求使用相同来源。
    func fetchForAuthentication() async throws -> ALTAnisetteData {
        try await fetch()
    }
    /// 未实现只读获取的 provider 必须安全失败，不能回退到可能重建环境的 fetch。
    func fetchForCompatibilityRetry(expectedDeviceID: String) async throws -> ALTAnisetteData {
        throw AnisetteV3Error.unavailable
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
    /// 服务器返回的客户端身份会被 Apple 登录边缘直接拒掉（Xcode / Android），
    /// 该服务器不可用，需要换下一台（复刻 SideInstaller 的 failover）。
    case rejectedIdentity
}

// 手动实现 Equatable（因为有关联值）
extension AnisetteV3Error {
    static func == (lhs: AnisetteV3Error, rhs: AnisetteV3Error) -> Bool {
        switch (lhs, rhs) {
        case (.invalidIdentifier, .invalidIdentifier),
             (.invalidServerResponse, .invalidServerResponse),
             (.provisioningFailed, .provisioningFailed),
             (.staleProvisioning, .staleProvisioning),
             (.unavailable, .unavailable),
             (.rejectedIdentity, .rejectedIdentity):
            return true
        default:
            return false
        }
    }
}

struct AnisetteProvisioningState: Codable, Equatable, Sendable {
    let identifier: String
    let adiPB: String

    /// 建这份 ADI 时声明给 Apple 的客户端身份（身份戳）。
    ///
    /// Apple 拒绝「ADI 与声明系统不一致」的初始登录，返回 `-80045`，所以 ADI 只对
    /// 建它时用的那个身份有效。旧版本写入的条目没有这个字段，解码为 `nil`，一律
    /// 视为不匹配，迫使下一次重新 provisioning。
    let clientInfo: String?

    init?(identifier: String, adiPB: String, clientInfo: String? = nil) {
        guard identifier.isEmpty == false, adiPB.isEmpty == false else { return nil }
        self.identifier = identifier
        self.adiPB = adiPB
        self.clientInfo = clientInfo
    }

    /// 这份 ADI 是否对本次要声明的身份仍然有效。判定抽成纯函数，便于单测覆盖。
    func matches(clientInfo: String) -> Bool {
        self.clientInfo == clientInfo
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
