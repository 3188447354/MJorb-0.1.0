import Testing
@testable import Seal

struct VersionTests {
    @Test
    func comparesNumericVersionComponents() {
        #expect(Version.compareIfValid("v0.1.10", "0.1.9") == .orderedDescending)
        #expect(Version.compareIfValid("0.1.2", "v0.1.2") == .orderedSame)
    }

    @Test
    func rejectsMalformedVersionInsteadOfGuessing() {
        #expect(Version.compareIfValid("0.1.beta", "0.1.2") == nil)
        #expect(Version.compareIfValid("", "0.1.2") == nil)
    }
}
