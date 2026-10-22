import Foundation
import Testing
@testable import Seal

/// 签名链 `ApplePortalSigningFailure.make` 的 anisette 归因前置（0.1.52 第 6 项
/// 第二轮，parts-0152/part-6.md §4 最高优先吞没点）。
///
/// 此前 `make` 只有一条 `isNetworkError → SEAL-NET-102` 判据：anisette 候选
/// 全灭（带 `AnisetteAllServersNetworkFailure` 来源标记）经签名链触发时，
/// 会被误报成「与 Apple 开发者服务的请求未完成」。新口径：标记错误归
/// `SEAL-ANI-116`（operation `.sign` / origin `.applePortal`），裸网络
/// 错误仍保留 `SEAL-NET-102`。全部纯函数同步断言，无计时/竞速断言。
struct ApplePortalSigningAnisetteAttributionTests {
    @Test
    func allServersFailureIsAttributedToAnisetteNotNet102() {
        let marker = AnisetteAllServersNetworkFailure(
            lastURLErrorCode: URLError(.cannotConnectToHost).code.rawValue
        )
        let failure = ApplePortalSigningFailure.make(stage: .signing, error: marker)

        #expect(failure.code == "SEAL-ANI-116")
        #expect(failure.title == "暂时连不上网络")
        #expect(failure.reason.contains("全部无法连接"))
        #expect(failure.reason.contains("Apple 开发者服务") == false)
        #expect(failure.recovery == "检查网络连接后稍后重试")
        #expect(failure.operation == .sign)
        #expect(failure.origin == .applePortal)
        #expect(failure.condition == .authenticationEnvironmentServiceUnavailable)
        #expect(AppleServiceFailurePolicy.shouldRequireReverification(failure) == false)
        #expect(AppleServiceFailurePolicy.isTransient(failure))
    }

    @Test
    func wrappedAllServersFailureKeepsAnisetteAttribution() {
        let marker = AnisetteAllServersNetworkFailure(lastURLErrorCode: -1004)
        let wrapped = NSError(
            domain: "Seal.Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: marker]
        )
        let failure = ApplePortalSigningFailure.make(stage: .certificate, error: wrapped)

        #expect(failure.code == "SEAL-ANI-116")
    }

    @Test
    func bareNetworkErrorKeepsNet102() {
        let failure = ApplePortalSigningFailure.make(
            stage: .signing,
            error: URLError(.cannotConnectToHost)
        )

        #expect(failure.code == "SEAL-NET-102")
        #expect(failure.condition == .appleRequestTransportUnavailable)
    }
}
