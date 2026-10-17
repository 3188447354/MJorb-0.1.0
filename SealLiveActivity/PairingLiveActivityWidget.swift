import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛 / 锁屏上的 Seal 配对状态。系统决定是否展开和具体尺寸，界面只提供各状态内容。
struct PairingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(PairingDeepLink.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        sealMark
                        Text(context.state.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    status(for: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: context.state.stage == .code ? 6 : 0) {
                        if context.state.stage == .code {
                            Text(grouped(context.state.code))
                                .font(.system(size: 30, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .tracking(2)
                        }
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, context.state.stage == .code ? 2 : 12)
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                sealMark
            } compactTrailing: {
                compactTrailing(for: context.state)
            } minimal: {
                sealMark
            }
            .widgetURL(PairingDeepLink.url)
            .keylineTint(tint(for: context.state.stage))
        }
    }

    private var sealMark: some View {
        Image("SealBrandIcon")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private func status(for state: PairingActivityAttributes.ContentState) -> some View {
        HStack(spacing: 4) {
            statusIcon(for: state.stage)
            Text(statusText(for: state.stage))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(statusColor(for: state.stage))
    }

    @ViewBuilder
    private func statusIcon(for stage: PairingActivityAttributes.Stage) -> some View {
        switch stage {
        case .preparing, .code:
            Circle()
                .fill(Color.blue)
                .frame(width: 7, height: 7)
        case .paired:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private func statusText(for stage: PairingActivityAttributes.Stage) -> String {
        switch stage {
        case .preparing: return "准备配对"
        case .code: return "等待配对"
        case .paired: return "配对完成"
        case .failed: return "配对未完成"
        }
    }

    private func statusColor(for stage: PairingActivityAttributes.Stage) -> Color {
        switch stage {
        case .preparing, .code: return .blue
        case .paired: return .green
        case .failed: return .red
        }
    }

    @ViewBuilder
    private func compactTrailing(for state: PairingActivityAttributes.ContentState) -> some View {
        switch state.stage {
        case .code:
            Text(state.code)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
        case .paired:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .preparing:
            Circle()
                .fill(Color.blue)
                .frame(width: 7, height: 7)
        }
    }

    private func lockScreen(_ state: PairingActivityAttributes.ContentState) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                sealMark
                Text(state.title).font(.headline)
                Spacer()
                status(for: state)
            }
            if state.stage == .code {
                Text(grouped(state.code))
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .tracking(2.5)
            }
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(18)
    }

    private func tint(for stage: PairingActivityAttributes.Stage) -> Color {
        stage == .paired ? .green : (stage == .failed ? .red : .white)
    }

    private func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<middle]) \(code[middle...])"
    }
}
