import SwiftUI

extension View {
    /// 单行动：占一行、站不下自动缩小字号（最小 0.72），不强行换行。
    /// 抽屉与详情页的 UI 铁律（2026-10-05）：动态长文本统一走它，不再各处
    /// 手写 `lineLimit(1)`（65 处）与 `minimumScaleFactor`（30 处）两张皮。
    /// 原先锁在 `LogViewerView` 私有扩展里，2026-10-24 提共享层。
    func singleLine() -> some View {
        lineLimit(1).minimumScaleFactor(0.72)
    }
}

extension Double {
    /// 0…1 进度 → "42%"（三处百分比拼接的唯一入口）。
    var sealPercentText: String {
        "\(Int(self * 100))%"
    }
}
