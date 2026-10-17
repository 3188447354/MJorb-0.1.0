import SwiftUI

enum SealLayout {
    static let screenHorizontalInset: CGFloat = 20
    static let drawerHorizontalInset: CGFloat = 22
    static let sectionSpacing: CGFloat = 12
    static let cardContentInset: CGFloat = 16
    static let compactCardCornerRadius: CGFloat = 14
    static let standardCardCornerRadius: CGFloat = 18
    static let prominentCardCornerRadius: CGFloat = 24
    static let drawerCornerRadius: CGFloat = 29
    static let primaryActionHeight: CGFloat = 54
    static let primaryActionCornerRadius: CGFloat = 14
}

enum SealContentCardStyle {
    case compact
    case standard
    case prominent

    var cornerRadius: CGFloat {
        switch self {
        case .compact: SealLayout.compactCardCornerRadius
        case .standard: SealLayout.standardCardCornerRadius
        case .prominent: SealLayout.prominentCardCornerRadius
        }
    }
}

struct GlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.secondary.opacity(0.18), lineWidth: 0.5)
                }
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.7)
                }
        } else {
            content
                .background(
                    Color.sealSurface,
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.7)
                }
        }
    }
}


struct SealSheetBackground: ViewModifier {
    let level: SealScreenLevel

    func body(content: Content) -> some View {
        content
            .background(SealBackdrop(level: level).ignoresSafeArea())
            .presentationDragIndicator(.hidden)
            .compatibleClearPresentationBackground()
            .compatiblePresentationCornerRadius(SealLayout.drawerCornerRadius)
    }
}

extension View {
    /// 系统 Liquid Glass 仅用于浮在内容上方的导航或操作层。
    /// 内容列表和信息卡应使用 `sealContentCard`，避免 iOS 26 上透出底层内容。
    func glassSurface(cornerRadius: CGFloat = 8) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Seal 的内容卡片：不使用 Liquid Glass，始终保持稳定的实色层级和描边。
    func sealContentCard(_ style: SealContentCardStyle = .standard) -> some View {
        sealContentCard(cornerRadius: style.cornerRadius)
    }

    func sealContentCard(cornerRadius: CGFloat) -> some View {
        background(
            Color.sealSurface,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    func compatibleClearPresentationBackground() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(.clear)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatiblePresentationCornerRadius(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            presentationCornerRadius(radius)
        } else {
            self
        }
    }

    func sealSheetBackground(_ level: SealScreenLevel = .tertiary) -> some View {
        modifier(SealSheetBackground(level: level))
    }

    func sealPrimaryAction() -> some View {
        buttonStyle(SealPrimaryActionStyle(cornerRadius: SealLayout.primaryActionCornerRadius))
    }

    func sealPrimaryAction(cornerRadius: CGFloat) -> some View {
        buttonStyle(SealPrimaryActionStyle(cornerRadius: cornerRadius))
    }

    func sealOutlineAction(cornerRadius: CGFloat) -> some View {
        buttonStyle(SealOutlineActionStyle(cornerRadius: cornerRadius))
    }

    func sealSecondaryDisabledAction(cornerRadius: CGFloat) -> some View {
        buttonStyle(SealSecondaryDisabledActionStyle(cornerRadius: cornerRadius))
    }
}

struct SealPrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: SealLayout.primaryActionHeight)
            .foregroundStyle(.white)
            .background(
                Color.sealAccent.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.28), lineWidth: 0.5)
            }
            .shadow(color: Color.sealAccent.opacity(isEnabled ? (configuration.isPressed ? 0.14 : 0.28) : 0.0), radius: 14, y: 7)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct SealOutlineActionStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: SealLayout.primaryActionHeight)
            .foregroundStyle(Color.sealAccent)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.sealAccent, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct SealSecondaryDisabledActionStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: SealLayout.primaryActionHeight)
            .foregroundStyle(Color.sealTextSecondary.opacity(0.75))
            .background(
                Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}
