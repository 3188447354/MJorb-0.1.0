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
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 9) {
                        HStack(spacing: 6) {
                            sealMark
                            Text(context.state.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            status(for: context.state)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)

                        pairingDetails(context.state, codeSize: 30)
                    }
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

    private var sealMarkImage: Image {
        Image("SealBrandIcon")
            .renderingMode(.original)
            .resizable()
    }

    @ViewBuilder
    private var sealMark: some View {
        if #available(iOS 18.0, *) {
            sealMarkImage
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFit()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityLabel("Seal")
        } else {
            sealMarkImage
                .scaledToFit()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityLabel("Seal")
        }
    }

    @ViewBuilder
    private func status(for state: PairingActivityAttributes.ContentState) -> some View {
        HStack(spacing: 4) {
            statusIcon(for: state.stage)
            Text(statusText(for: state.stage))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .layoutPriority(1)
        }
        .font(.caption2.weight(.semibold))
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
            Image(systemName: "checkmark.circle")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
        }
    }

    private func statusText(for stage: PairingActivityAttributes.Stage) -> String {
        switch stage {
        case .preparing: return "准备配对"
        case .code: return "等待配对"
        case .paired: return "配对完成"
        case .failed: return "配对失败"
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
            Text(grouped(state.code))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        case .paired:
            Image(systemName: "checkmark.circle")
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
            pairingDetails(state, codeSize: 36)
        }
        .foregroundStyle(.white)
        .padding(18)
    }

    @ViewBuilder
    private func pairingDetails(
        _ state: PairingActivityAttributes.ContentState,
        codeSize: CGFloat
    ) -> some View {
        VStack(spacing: state.stage == .code ? 6 : 4) {
            switch state.stage {
            case .preparing:
                Text("前往设置")
                    .font(.subheadline.weight(.semibold))
                instruction(state.detail)
            case .code:
                Text(grouped(state.code))
                    .font(.system(size: codeSize, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .tracking(2)
                instruction(state.detail)
            case .paired, .failed:
                Text(state.detail)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.78))
            .lineSpacing(4)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
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
