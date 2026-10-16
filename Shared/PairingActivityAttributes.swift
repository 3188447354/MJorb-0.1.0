import ActivityKit
import Foundation

/// 配对 Live Activity 的属性定义。
///
/// ⚠️ **这个文件同时属于两个 target**（`Seal` 和 `SealLiveActivity` 扩展），
/// 修改时必须两边都能编译：
/// - 只能依赖 `ActivityKit` / `Foundation`，**不能**引用 Seal 内部的任何类型
///   （`SealAccentTheme`、`SealLogStore`、配色常量都不行 —— 扩展里没有它们）。
/// - 文案必须由 App 侧**翻译好再放进 `ContentState`**：扩展里没有本地化表和语言设置，
///   自己在扩展里写 `Text("配对码")` 会得到一个永远中英不分、无法跟 App 语言走的界面。
///
/// 为什么用 Live Activity 而不是只在 App 内显示配对码：配对码要输进**系统设置**，
/// 而进设置就得离开 Seal。把码镜像到灵动岛/锁屏后，输码时它一直悬在顶上；
/// 输完点一下灵动岛即可跳回 Seal（iOS 对 Live Activity 的点击默认行为，
/// 见 Apple《Launching your app from a Live Activity》）。
struct PairingActivityAttributes: ActivityAttributes {

    /// 配对流程所处的阶段。
    ///
    /// 与 App 侧 `SettingsViewModel.PhonePairingState` 对应，但**刻意只保留三个**：
    /// 灵动岛能表达的只有「等着 / 这是码 / 好了」，把请求本地网络、校验中等中间态
    /// 也搬上去只会让一次配对闪好几次，反而看不清码。
    enum Stage: String, Codable, Hashable, Sendable {
        /// 服务已开始发布，系统还没给出配对码。
        case waiting
        /// 系统给出了配对码，等用户在「设置」里核对并确认。
        case code
        /// 已配对成功。
        case paired
    }

    /// 会随时间变化的部分。每次码变化或阶段推进都整体替换。
    struct ContentState: Codable, Hashable, Sendable {
        var stage: Stage
        /// 配对码原文（形如 `123456`）。由 App 侧保证非空才进入 `.code`。
        var code: String
        /// 已本地化的文案，见文件头说明。
        var title: String
        var detail: String

        init(stage: Stage, code: String, title: String, detail: String) {
            self.stage = stage
            self.code = code
            self.title = title
            self.detail = detail
        }
    }

    /// 固定不变的部分。目前只有设备名，用于让用户确认「是在给这台设备配对」。
    var deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
    }
}

/// 扩展与 App 约定的跳转地址，两个 target 共用。
///
/// ⚠️ **必须放在这个共享文件里**，不能留在扩展目录：主 App 并不编译
/// `SealLiveActivity/`，`RootTabView` 引用扩展里的类型会直接编译失败。
/// 两边用同一个字面量也很重要 —— 不一致会表现为「点了灵动岛回到了 App 却停在首页」
/// 这种没有任何报错的静默失败。
enum PairingDeepLink {
    static let scheme = "seal"
    static let host = "pairing"
    static var url: URL { URL(string: "\(scheme)://\(host)")! }
}
