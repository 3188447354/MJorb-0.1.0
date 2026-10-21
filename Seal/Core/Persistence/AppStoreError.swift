import Foundation

enum AppStoreError: LocalizedError {
    case corruptRecord
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .corruptRecord:
            return "应用记录数据损坏"
        case .invalidConfiguration:
            return "应用记录存储配置无效"
        }
    }
}
