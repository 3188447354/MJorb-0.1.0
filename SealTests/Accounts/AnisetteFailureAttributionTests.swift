import Foundation
import Testing
@testable import Seal

/// anisette 候选全灭 vs Apple 门户传输失败的分开归因（2026-10-22 log-46）。
///
/// 真机事件：17 台 anisette 候选全部 `URLError(-1004)`（本机网络不可达），
/// 旧链路把裸 `URLError` 一律归 `SEAL-NET-102`「与 Apple 开发者服务的请求
/// 没有完成」，文案指错方向。新口径：带 `AnisetteAllServersNetworkFailure`
/// 来源标记的全灭终局归 `SEAL-ANI-116`；裸网络错误仍保留 `SEAL-NET-102`。
struct AnisetteFailureAttributionTests {
    @Test
    func allServersNetworkFailureIsAttributedToAnisetteNotApple() {
        let marker = AnisetteAllServersNetworkFailure(
            lastURLErrorCode: URLError(.cannotConnectToHost).code.rawValue
        )

        #expect(
            AppleServiceFailurePolicy.transportAttribution(for: marker)
                == .anisetteServersUnreachable
        )
        #expect(AppleServiceFailurePolicy.isAnisetteAllServersNetworkFailure(marker))
    }

    @Test
    func wrappedAllServersNetworkFailureKeepsAnisetteAttribution() {
        let marker = AnisetteAllServersNetworkFailure(lastURLErrorCode: -1004)
        let wrapped = NSError(
            domain: "Seal.Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: marker]
        )

        #expect(
            AppleServiceFailurePolicy.transportAttribution(for: wrapped)
                == .anisetteServersUnreachable
        )
    }

    @Test
    func bareNetworkErrorKeepsApplePortalAttribution() {
        #expect(
            AppleServiceFailurePolicy.transportAttribution(for: URLError(.cannotConnectToHost))
                == .appleDeveloperServiceUnreachable
        )
        #expect(
            AppleServiceFailurePolicy.transportAttribution(for: URLError(.timedOut))
                == .appleDeveloperServiceUnreachable
        )
    }

    @Test
    func nonNetworkAndNonTerminalAnisetteErrorsAreNotTransportFailures() {
        #expect(
            AppleServiceFailurePolicy.transportAttribution(
                for: NSError(domain: "Other", code: 42)
            ) == .notTransportFailure
        )
        // 单台/非网络终局的 anisette 错误没有全灭标记，不得误报成本机网络全灭。
        #expect(
            AppleServiceFailurePolicy.transportAttribution(for: AnisetteV3Error.unavailable)
                == .notTransportFailure
        )
        #expect(
            AppleServiceFailurePolicy.transportAttribution(for: AnisetteV3Error.provisioningFailed)
                == .notTransportFailure
        )
    }

    @Test
    func classifierMapsAllServersFailureToAnisetteCodeWithoutBlamingApple() {
        let marker = AnisetteAllServersNetworkFailure(lastURLErrorCode: -1004)
        let failure = FailureClassifier.classify(
            marker,
            operation: .renew,
            origin: .applePortal
        )

        #expect(failure.code == "SEAL-ANI-116")
        #expect(failure.condition == .authenticationEnvironmentServiceUnavailable)
        #expect(failure.action == .retry)
        #expect(failure.retryDisposition == .manual)
        #expect(failure.operation == .renew)
        #expect(failure.reason.contains("Apple 开发者服务") == false)
        #expect(failure.recovery.contains("网络"))
        #expect(AppleServiceFailurePolicy.shouldRequireReverification(failure) == false)
        #expect(AppleServiceFailurePolicy.isTransient(failure))
    }

    @Test
    func classifierKeepsBareNetworkErrorOnNet102() {
        let failure = FailureClassifier.classify(
            URLError(.cannotConnectToHost),
            operation: .sign,
            origin: .applePortal
        )

        #expect(failure.code == "SEAL-NET-102")
        #expect(failure.condition == .appleRequestTransportUnavailable)
        #expect(failure.reason == "与 Apple 开发者服务的请求没有完成。")
    }

    @Test
    func anisetteUnreachableFailureUsesUserFacingNetworkCopy() {
        let failure = AppleServiceFailurePolicy.anisetteServersUnreachableFailure(
            operation: .authenticateAccount,
            origin: .authentication
        )

        #expect(failure.code == "SEAL-ANI-116")
        #expect(failure.title == "暂时连不上网络")
        #expect(failure.reason.contains("全部无法连接"))
        #expect(failure.reason.contains("Apple") == false)
        #expect(failure.recovery == "检查网络连接后稍后重试")
    }
}
