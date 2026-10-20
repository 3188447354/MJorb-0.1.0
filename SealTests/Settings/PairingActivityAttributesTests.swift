import Foundation
import Testing
@testable import Seal

struct PairingActivityAttributesTests {
    @Test
    func sealIconSurvivesActivityAttributeEncoding() throws {
        let icon = Data(repeating: 0x89, count: 1_800)
        let attributes = PairingActivityAttributes(deviceName: "iPhone", sealIconPNG: icon)
        let encoded = try JSONEncoder().encode(attributes)
        let decoded = try JSONDecoder().decode(PairingActivityAttributes.self, from: encoded)
        let state = PairingActivityAttributes.ContentState(
            stage: .preparing,
            code: "",
            title: "Seal",
            detail: "隐私与安全-开发者模式-与 Seal 配对"
        )
        let encodedState = try JSONEncoder().encode(state)

        #expect(decoded.sealIconPNG == icon)
        #expect(encoded.count + encodedState.count < 4_096)
    }

    @Test
    func olderActivityAttributesDecodeWithoutAnIcon() throws {
        let decoded = try JSONDecoder().decode(
            PairingActivityAttributes.self,
            from: Data(#"{"deviceName":"iPhone"}"#.utf8)
        )

        #expect(decoded.sealIconPNG == nil)
    }
}
