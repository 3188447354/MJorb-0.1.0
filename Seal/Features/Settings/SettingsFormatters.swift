import Foundation

extension Int64 {
    var sealFormattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

enum SealSettingsDateFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        // 所有用户可见时间统一精确到秒，包括描述文件和证书有效期。
        // 免费账号只有 7 天寿命；秒级显示也能辨认同一分钟内连续签发的不同 profile。
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

}

enum TeamNameDisplayFormatter {
    static func string(from name: String) -> String {
        let parts = name
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 2,
              parts.allSatisfy(isCJKText) else {
            return name
        }
        return "\(parts[1]) \(parts[0])"
    }

    private static func isCJKText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }
}
