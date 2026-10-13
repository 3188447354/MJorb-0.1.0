import Testing
@testable import Seal

@Suite("主题色存储")
struct SealAppearanceTests {
    @Test("自定义 HEX 会规范化，并保留纯黑")
    func customHexNormalizationPreservesExactBlack() {
        #expect(SealAccentTheme.normalizedHex("#000000") == "#000000")
        #expect(SealAccentTheme.normalizedHex(" 1677ff ") == "#1677FF")
    }

    @Test("自定义项不进入六个预设色网格")
    func customAccentIsNotAPreset() {
        #expect(SealAccentTheme.presetThemes.count == 6)
        #expect(SealAccentTheme.presetThemes.contains(.custom) == false)
    }

    @Test("错误 HEX 不会被误存为主题色")
    func invalidHexIsRejected() {
        #expect(SealAccentTheme.normalizedHex("#00000") == nil)
        #expect(SealAccentTheme.normalizedHex("#GG0000") == nil)
        #expect(SealAccentTheme.normalizedHex("#00000000") == nil)
    }
}
