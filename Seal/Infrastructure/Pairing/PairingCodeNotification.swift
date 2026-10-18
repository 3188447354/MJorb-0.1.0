import Foundation
import UserNotifications
/// 配对码的**通知回退路径**。
///
/// 什么时候会用到它：
/// - 签名环节把 `PlugIns/SealLiveActivity.appex` 剥掉了（显式描述文件就是这样，
///   见 SideInstaller 的 `sign_with_all_certs.sh`：非通配符 profile 下它直接
///   `rm -rf PlugIns`）；
/// - 用户在系统设置里关掉了 Seal 的「实时活动」。
///
/// 两种情况下灵动岛都不会出现，但配对码仍然需要能浮在「设置」上方 ——
/// 通知横幅做到这一点，而且不额外消耗 App ID。
///
/// ⚠️ 代价：**会弹系统的通知授权框**（首次配对时）。若同一安装里灵动岛可用，
/// 就**不应该**再去请求通知权限 —— 否则用户会看到一个本该没有的权限框。
/// 只有 Live Activity 预创建失败，或系统在出码前回收活动时，才会请求通知权限。
enum PairingCodeNotification {

    /// 同一条通知反复替换，避免码变了在通知中心堆一列。
    static let identifier = "seal.pairing.code"

    /// 请求通知权限。只在确定要走通知路径时调用。
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// 把配对码作为横幅推出，替换掉同 identifier 的上一条。
    static func present(code: String) async {
        await post(title: "配对码 \(code)", body: "在系统设置中核对此配对码")
    }

    /// 流程结束时清掉残留通知（回到 App 前台时也该清）。
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private static func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        // 立刻送达；`nil` trigger 表示马上投递。
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        // 先撤掉旧的同 id 通知，保证「替换」而不是「排队」。
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        try? await center.add(request)
    }
}
