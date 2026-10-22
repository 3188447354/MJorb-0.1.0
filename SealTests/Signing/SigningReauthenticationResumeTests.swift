import Foundation
import Testing
@testable import Seal

/// 签名被双重认证中断（SEAL-AUTH-101a）后的自动续跑判据。
///
/// **为什么值得单独测**：它的错法不崩、不编译失败，只在真机上表现为
/// 「验证完了签名没动静」（该续的没续）或「刚验证完一个账号，某个八竿子
/// 打不着的失败签名自己跑起来了」（不该续的被重跑）。准入只有一条：
/// 这次失败必须是「双重认证没走完」—— 错误码或结构化动作任一命中。
struct SigningReauthenticationResumeTests {
    @Test
    func twoFactorCodeIsAnInterruption() {
        let failure = ImportFailure(
            title: "Apple ID 需要双重认证",
            reason: "r",
            recovery: "r",
            code: "SEAL-AUTH-101a"
        )
        #expect(failure.isTwoFactorInterruption)
    }

    @Test
    func twoFactorActionIsAnInterruption() {
        let failure = ImportFailure(
            title: "t",
            reason: "r",
            recovery: "r",
            code: "SEAL-AUTH-999",
            action: .enterNewVerificationCode
        )
        #expect(failure.isTwoFactorInterruption)
    }

    @Test
    func ordinaryFailuresAreNotInterruptions() {
        let network = ImportFailure(
            title: "t",
            reason: "r",
            recovery: "r",
            code: "SEAL-NET-101",
            action: .retry
        )
        #expect(network.isTwoFactorInterruption == false)

        let certificate = ImportFailure(
            title: "t",
            reason: "r",
            recovery: "r",
            code: "SEAL-CERT-204b",
            action: .fullResign
        )
        #expect(certificate.isTwoFactorInterruption == false)

        // 默认动作（.copyDiagnostics）的旧失败也不许被算进来。
        let legacy = ImportFailure(
            title: "t",
            reason: "r",
            recovery: "r",
            code: "SEAL-SIGN-500"
        )
        #expect(legacy.isTwoFactorInterruption == false)
    }
}
