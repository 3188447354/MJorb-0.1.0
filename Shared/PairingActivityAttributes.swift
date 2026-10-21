import ActivityKit
import Foundation

/// 配对 Live Activity 的属性定义。此文件同时属于 Seal 与 SealLiveActivity target。
struct PairingActivityAttributes: ActivityAttributes {
    static let developerModePairingInstruction =
        "前往 设置 > 隐私与安全 > 开发者模式 > 选择 Pair with Seal 配对"

    enum Stage: String, Codable, Hashable, Sendable {
        /// 用户已主动开始配对，但系统尚未生成真实配对码。
        case preparing
        /// 系统给出真实六码，等待用户在设置中确认。
        case code
        /// 配对凭证已成功导入 Seal。
        case paired
        /// 配对未完成，旧码必须隐藏。
        case failed

        var isTerminal: Bool {
            self == .paired || self == .failed
        }
    }

    struct ContentState: Codable, Hashable, Sendable {
        var stage: Stage
        /// 仅 `.code` 可包含六码；其他状态必须为空。
        var code: String
        /// 由主 App 本地化后写入，扩展只负责展示。
        var title: String
        var detail: String

        init(stage: Stage, code: String, title: String, detail: String) {
            self.stage = stage
            self.code = code
            self.title = title
            self.detail = detail
        }
    }

    var deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    private enum CodingKeys: String, CodingKey {
        case deviceName
        // Decode the field written by older Seal versions, but never encode image bytes into
        // ActivityAttributes. The extension loads the icon from its bundled asset catalog.
        case sealIconPNG
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try container.decode(String.self, forKey: .deviceName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceName, forKey: .deviceName)
    }
}

enum PairingDeepLink {
    static let scheme = "seal"
    static let host = "pairing"
    static var url: URL { URL(string: "\(scheme)://\(host)")! }
}
