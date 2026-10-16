import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛 / 锁屏上的 Seal 配对状态。系统决定是否展开和具体尺寸，界面只提供各状态内容。
struct PairingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            lockScreen(context.state, deviceName: context.attributes.deviceName)
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
                    trailing(for: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
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
                    }
                    .foregroundStyle(.white)
                    .padding(.top, context.state.stage == .code ? 2 : 8)
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
    private func trailing(for state: PairingActivityAttributes.ContentState) -> some View {
        switch state.stage {
        case .code:
            Text(grouped(state.code))
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .tracking(1.5)
                .foregroundStyle(.white)
        case .paired:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .preparing:
            ProgressView().tint(.white)
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
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
        case .preparing:
            EmptyView()
        }
    }

    private func lockScreen(_ state: PairingActivityAttributes.ContentState, deviceName: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                sealMark
                Text(state.title).font(.headline)
                Spacer()
                statusIcon(for: state.stage)
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
            if state.stage == .code {
                Text(deviceName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
    }

    @ViewBuilder
    private func statusIcon(for stage: PairingActivityAttributes.Stage) -> some View {
        if stage == .paired {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if stage == .failed {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
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
