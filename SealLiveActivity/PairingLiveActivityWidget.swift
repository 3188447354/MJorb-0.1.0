import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛 / 锁屏上的配对码界面。
///
/// 三种形态都要给：锁屏卡片、灵动岛 compact（左右两小块）、灵动岛 expanded（长按展开）。
/// ⚠️ Apple 明确要求 compact 的 leading 与 trailing **指向同一个界面**，
/// 所以两者都挂同一个 `seal://pairing`。
struct PairingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            lockScreen(context.state, deviceName: context.attributes.deviceName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                // 锁屏卡片点按跳回 Seal 的配对面。
                .widgetURL(PairingDeepLink.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("配对码", systemImage: "number")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 展开态的 deep link 用 `Link`（Apple 允许 `widgetURL` 或 `Link` 二选一，
                    // 这里显式用 `Link`，避免根节点 `widgetURL` 在展开态被忽略时没有兜底）。
                    Link(destination: PairingDeepLink.url) {
                        Text(displayCode(context.state))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: context.state.stage == .paired ? "checkmark" : "number")
                    .foregroundStyle(.white)
            } compactTrailing: {
                // 紧凑态空间极小：只放码本身，不分组、不加单位。
                Text(displayCode(context.state))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.stage == .paired ? "checkmark" : "number")
                    .foregroundStyle(.white)
            }
            .widgetURL(PairingDeepLink.url)
            .keylineTint(.white)
        }
    }

    private func lockScreen(_ state: PairingActivityAttributes.ContentState,
                            deviceName: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.stage == .paired ? "checkmark.seal.fill" : "number")
                    .foregroundStyle(.white)
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            if state.stage == .code {
                Text(grouped(state.code))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .kerning(2)
            }
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(16)
    }

    /// 配对码显示文本：完成后不再显示码，避免用户拿旧码去试。
    private func displayCode(_ state: PairingActivityAttributes.ContentState) -> String {
        state.stage == .code ? state.code : "✓"
    }

    /// 六位码分成 `123 456`，比一串连续数字好读、也不容易看错位。
    private func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }
}
