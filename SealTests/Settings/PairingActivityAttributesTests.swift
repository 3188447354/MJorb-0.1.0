import Foundation
import Testing
@testable import Seal

struct PairingActivityAttributesTests {
    @Test
    func devicePageAndGuideShareTheRequestedDeveloperModeInstruction() {
        #expect(
            PairingActivityAttributes.developerModePairingInstruction
                == "前往 设置 > 隐私与安全 > 开发者模式 > 选择 Pair with Seal 配对"
        )
    }

    @Test
    func activityAttributesDoNotSerializeTheBundledSealIcon() throws {
        let attributes = PairingActivityAttributes(deviceName: "iPhone")
        let encoded = try JSONEncoder().encode(attributes)
        let decoded = try JSONDecoder().decode(PairingActivityAttributes.self, from: encoded)
        let state = PairingActivityAttributes.ContentState(
            stage: .preparing,
            code: "",
            title: "Seal",
            detail: "隐私与安全-开发者模式-与 Seal 配对"
        )
        let encodedState = try JSONEncoder().encode(state)

        #expect(decoded.deviceName == "iPhone")
        #expect(encoded.count + encodedState.count < 1_024)
        #expect(String(decoding: encoded, as: UTF8.self).contains("sealIconPNG") == false)
    }

    @Test
    func olderActivityAttributesDecodeAndDiscardTheLegacyIconBytes() throws {
        let decoded = try JSONDecoder().decode(
            PairingActivityAttributes.self,
            from: Data(#"{"deviceName":"iPhone","sealIconPNG":"AQID"}"#.utf8)
        )

        #expect(decoded.deviceName == "iPhone")
    }
}
