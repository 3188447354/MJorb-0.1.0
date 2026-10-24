import SwiftUI
import UIKit

enum SealAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 主题色预设（2026-10-24 MJ 拍板，6 颗）：宝石蓝（默认）、朱砂红、金盏黄、
/// 翡翠绿、琥珀橙、紫罗兰；晴空青（与蓝太近）、玫瑰粉（与红同系）已砍。
/// 抽屉版式不动：`presetThemes` 仍按声明顺序出 6 颗，正好填满现有 3×2 格子。
/// 旧存量 rawValue（blue/pink）读不到时经 `current` 回落默认宝石蓝。
enum SealAccentTheme: String, CaseIterable, Identifiable {
    case system
    case red
    case yellow
    case green
    case amber
    case purple
    case custom

    static let customHexStorageKey = "appearance.customAccentHex"
    static let defaultCustomHex = "#1677FF"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "宝石蓝"
        case .red: "朱砂红"
        case .yellow: "金盏黄"
        case .green: "翡翠绿"
        case .amber: "琥珀橙"
        case .purple: "紫罗兰"
        case .custom: "自定义"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .system: .systemBlue
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .amber: .systemOrange
        case .purple: .systemPurple
        case .custom:
            let base = UIColor(sealHex: Self.customHex) ?? .systemBlue
            // 自定义色深色适配（2026-10-24）：亮色下用原值，深色下向白色提亮 30%，
            // 避免自定义深色在深底上糊成一片。预设色是系统语义色，本身已适配。
            return UIColor { trait in
                guard trait.userInterfaceStyle == .dark else { return base }
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                guard base.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return base }
                let amount: CGFloat = 0.3
                return UIColor(
                    red: red + (1 - red) * amount,
                    green: green + (1 - green) * amount,
                    blue: blue + (1 - blue) * amount,
                    alpha: alpha
                )
            }
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    static var current: SealAccentTheme {
        SealAccentTheme(rawValue: UserDefaults.standard.string(forKey: "appearance.accent") ?? "") ?? .system
    }

    static var presetThemes: [SealAccentTheme] {
        allCases.filter { $0 != .custom }
    }

    static var customHex: String {
        normalizedHex(UserDefaults.standard.string(forKey: customHexStorageKey)) ?? defaultCustomHex
    }

    static func normalizedHex(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#\(value.uppercased())"
    }
}

extension UIColor {
    convenience init?(sealHex: String) {
        guard let normalized = SealAccentTheme.normalizedHex(sealHex) else { return nil }
        let value = String(normalized.dropFirst())
        guard let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}
