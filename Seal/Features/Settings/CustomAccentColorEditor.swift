import SwiftUI
import UIKit

/// 浮在“外观与主题”抽屉之上的取色器：编辑过程只修改草稿，完成后才写入 AppStorage。
struct CustomAccentColorEditor: View {
    @Binding var customHex: String
    @Binding var accentRawValue: String
    @Binding var isPresented: Bool

    @State private var color: HSBAColor
    @State private var hexInput: String

    init(
        customHex: Binding<String>,
        accentRawValue: Binding<String>,
        isPresented: Binding<Bool>
    ) {
        self._customHex = customHex
        self._accentRawValue = accentRawValue
        self._isPresented = isPresented
        let initial = HSBAColor(hex: customHex.wrappedValue) ?? HSBAColor(hex: SealAccentTheme.defaultCustomHex)!
        _color = State(initialValue: initial)
        _hexInput = State(initialValue: initial.hex)
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("自定义主题色")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white.opacity(0.75), lineWidth: 2))
                    .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
            }

            saturationBrightnessField
            hueSlider
            hexField

            HStack(spacing: 12) {
                Button("取消") { isPresented = false }
                    .buttonStyle(AccentEditorSecondaryButtonStyle())
                Button("完成") {
                    guard let normalized = SealAccentTheme.normalizedHex(hexInput) else { return }
                    customHex = normalized
                    accentRawValue = SealAccentTheme.custom.rawValue
                    isPresented = false
                }
                .buttonStyle(AccentEditorPrimaryButtonStyle(tint: color.swiftUIColor))
                .disabled(SealAccentTheme.normalizedHex(hexInput) == nil)
            }
        }
        .padding(20)
        .frame(maxWidth: 332)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 26, y: 12)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    private var saturationBrightnessField: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            Rectangle()
                .fill(Color(hue: color.hue, saturation: 1, brightness: 1))
                .overlay(LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing))
                .overlay(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 3)
                        .frame(width: 22, height: 22)
                        .shadow(color: Color.black.opacity(0.28), radius: 3)
                        .position(
                            x: color.saturation * width,
                            y: (1 - color.brightness) * height
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    color.saturation = min(max(value.location.x / width, 0), 1)
                    color.brightness = min(max(1 - value.location.y / height, 0), 1)
                    synchronizeHex()
                })
        }
        .frame(height: 178)
        .accessibilityLabel("饱和度与明度")
    }

    private var hueSlider: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.red, .magenta, .blue, .cyan, .green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.sealAccent.opacity(0.72), lineWidth: 1.5))
                        .shadow(color: Color.black.opacity(0.18), radius: 3)
                        .offset(x: color.hue * width - 11)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    color.hue = min(max(value.location.x / width, 0), 1)
                    synchronizeHex()
                })
        }
        .frame(height: 18)
        .accessibilityLabel("色相")
    }

    private var hexField: some View {
        HStack(spacing: 10) {
            Text("HEX")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
            TextField("#1677FF", text: $hexInput)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: hexInput) { value in
                    guard let incoming = HSBAColor(hex: value) else { return }
                    color = incoming
                }
                .accessibilityLabel("十六进制颜色")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.sealSurfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.6), lineWidth: 0.8)
        }
    }

    private func synchronizeHex() {
        hexInput = color.hex
    }
}

struct SpectrumRing: View {
    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [.red, .magenta, .blue, .cyan, .green, .yellow, .red],
                    center: .center
                ),
                lineWidth: 4
            )
            .overlay(Circle().fill(Color.sealSurface).padding(4))
    }
}

private struct HSBAColor {
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat

    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init?(hex: String) {
        guard let uiColor = UIColor(sealHex: hex) else { return nil }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        if uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            self.init(hue: hue, saturation: saturation, brightness: brightness)
            return
        }
        var white: CGFloat = 0
        guard uiColor.getWhite(&white, alpha: &alpha) else { return nil }
        self.init(hue: 0, saturation: 0, brightness: white)
    }

    var swiftUIColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var hex: String {
        let uiColor = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return SealAccentTheme.defaultCustomHex
        }
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

private struct AccentEditorPrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(tint.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct AccentEditorSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Color.sealSurfaceElevated.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
