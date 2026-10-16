import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛 / 锁屏上的配对码界面。
///
/// ## 设计要点（2026-10-16 按真机反馈重做）
///
/// - **码是主角**：用等宽字体大字展示，并按 `123 456` 分组 —— 系统设置里是一个数字框
///   一个数字框地输，分组后逐段核对不容易串位。
/// - **紧凑态只放码本身**：空间极小，任何标签都会把数字挤掉。左侧用一个图标表明
///   「这是在配对」，右侧直接给码。
/// - **展开态给出完整语境**：标题 + 大字码 + 一句说明，并显式写「点此返回 Seal」——
///   灵动岛点击只能启动 App，说不清用户就不知道能不能点。
/// - **完成态收起码**：配对成功后不再显示旧码，避免用户拿它去重试。
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
                    HStack(spacing: 6) {
                        Image(systemName: context.state.stage == .paired
                              ? "checkmark.seal.fill" : "number.square.fill")
                            .foregroundStyle(.white)
                        Text(context.state.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.stage == .code {
                        Text(grouped(context.state.code))
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .kerning(3)
                            .monospacedDigit()
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 3) {
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                        // 只在完成态提示可点：配对着的时候说「点此返回」会让用户
                        // 以为要离开当前流程。
                        if context.state.stage == .paired {
                            Text("点一下这里返回 Seal")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: context.state.stage == .paired ? "checkmark.seal.fill" : "number.square.fill")
                    .foregroundStyle(context.state.stage == .paired ? Color.green : Color.white)
            } compactTrailing: {
                // 紧凑态空间极小：只放码，不分组、不加单位。
                Text(context.state.stage == .code ? context.state.code : "✓")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(context.state.stage == .paired ? Color.green : Color.white)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: context.state.stage == .paired ? "checkmark.seal.fill" : "number.square.fill")
                    .foregroundStyle(context.state.stage == .paired ? Color.green : Color.white)
            }
            .widgetURL(PairingDeepLink.url)
            .keylineTint(context.state.stage == .paired ? .green : .white)
        }
    }

    private func lockScreen(_ state: PairingActivityAttributes.ContentState,
                            deviceName: String) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: state.stage == .paired ? "checkmark.seal.fill" : "number.square.fill")
                    .foregroundStyle(state.stage == .paired ? Color.green : Color.white)
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            if state.stage == .code {
                Text(grouped(state.code))
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .kerning(3)
                    .monospacedDigit()
            }

            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(deviceName)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(18)
    }

    /// 六位码分成 `123 456`：系统设置里是逐位输入，分组后更容易核对到哪一位。
    private func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }
}
