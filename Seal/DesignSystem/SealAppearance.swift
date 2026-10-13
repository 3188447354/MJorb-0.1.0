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

enum SealAccentTheme: String, CaseIterable, Identifiable {
    case system
    case green
    case blue
    case purple
    case amber
    case pink
    case custom

    static let customHexStorageKey = "appearance.customAccentHex"
    static let defaultCustomHex = "#1677FF"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "经典蓝"
        case .green: "翡翠绿"
        case .blue: "晴空青"
        case .purple: "紫罗兰"
        case .amber: "琥珀橙"
        case .pink: "玫瑰粉"
        case .custom: "自定义"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .system: .systemBlue
        case .green: .systemGreen
        case .blue: .systemCyan
        case .purple: .systemPurple
        case .amber: .systemOrange
        case .pink: .systemPink
        case .custom: UIColor(sealHex: Self.customHex) ?? .systemBlue
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
