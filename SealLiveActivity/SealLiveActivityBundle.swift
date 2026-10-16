import SwiftUI
import WidgetKit

/// Live Activity 的视图必须住在 widget 扩展里，所以有这样一个只有一行的入口 target。
///
/// 它除了 `PairingActivityAttributes` 之外不与 App 共享任何代码（见该文件头说明）。
@main
struct SealLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        PairingLiveActivityWidget()
    }
}
