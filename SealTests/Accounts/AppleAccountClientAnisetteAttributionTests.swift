import Foundation
import Testing
@testable import Seal

/// 登录链 `AppleAccountClient` 两处纯工厂的 anisette 归因前置（0.1.52 第 6 项
/// 第三轮，parts-0152/part-6.md §4）。
///
/// 此前 `AppleAuthenticationFailure.make` 与 `AppleAccountClient.failure(from:)`
/// 都只有一条 `isNetworkError → SEAL-NET-101` 判据：anisette 候选全灭（带
/// `AnisetteAllServersNetworkFailure` 来源标记）经登录链触发时，会被误报成
/// Apple 开发者服务请求未完成。新口径：标记错误归 `SEAL-ANI-116`
/// （operation `.authenticateAccount` / origin `.authentication`），裸网络
/// 错误仍保留 `SEAL-NET-101`。全部纯函数同步断言，无计时/竞速断言。
/// `validate` 的 catch 与 `SettingsViewModel` 的兜底不是纯函数，无测试宿主，
/// 只做源码级核对（见 parts-0152/part-6c.md）。
struct AppleAccountClientAnisetteAttributionTests {
    @Test
    func authenticationFailureMakeMapsAllServersFailureToAnisetteCode() {
        let marker = AnisetteAllServersNetworkFailure(
            lastURLErrorCode: URLError(.cannotConnectToHost).code.rawValue
        )
        let failure = AppleAuthenticationFailure.make(stage: .signIn, error: marker)

        #expect(failure.code == "SEAL-ANI-116")
        #expect(failure.title == "暂时连不上网络")
        #expect(failure.reason == "获取登录环境数据的服务全部无法连接，通常是当前网络暂时不可用。")
        #expect(failure.reason.contains("Apple") == false)
        #expect(failure.recovery == "检查网络连接后稍后重试")
        #expect(failure.operation == .authenticateAccount)
        #expect(failure.origin == .authentication)
        #expect(failure.condition == .authenticationEnvironmentServiceUnavailable)
        #expect(AppleServiceFailurePolicy.shouldRequireReverification(failure) == false)
        #expect(AppleServiceFailurePolicy.isTransient(failure))
    }

    @Test
    func authenticationFailureMakeKeepsWrappedMarkerAttributionForTeamLookup() {
        let marker = AnisetteAllServersNetworkFailure(lastURLErrorCode: -1004)
        let wrapped = NSError(
            domain: "Seal.Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: marker]
        )
        let failure = AppleAuthenticationFailure.make(stage: .teamLookup, error: wrapped)

        #expect(failure.code == "SEAL-ANI-116")
        #expect(failure.operation == .authenticateAccount)
        #expect(failure.origin == .authentication)
    }

    @Test
    func authenticationFailureMakeKeepsBareNetworkErrorOnNet101() {
        let failure = AppleAuthenticationFailure.make(
            stage: .signIn,
            error: URLError(.cannotConnectToHost)
        )

        #expect(failure.code == "SEAL-NET-101")
        #expect(failure.condition == .appleRequestTransportUnavailable)
        #expect(failure.operation == .authenticateAccount)
    }

    @Test
    func failureFromMapsAllServersFailureToAnisetteCode() {
        let marker = AnisetteAllServersNetworkFailure(
            lastURLErrorCode: URLError(.cannotConnectToHost).code.rawValue
        )
        let failure = AppleAccountClient.failure(from: marker)

        #expect(failure.code == "SEAL-ANI-116")
        #expect(failure.title == "暂时连不上网络")
        #expect(failure.reason == "获取登录环境数据的服务全部无法连接，通常是当前网络暂时不可用。")
        #expect(failure.recovery == "检查网络连接后稍后重试")
        #expect(failure.operation == .authenticateAccount)
        #expect(failure.origin == .authentication)
        #expect(failure.condition == .authenticationEnvironmentServiceUnavailable)
        #expect(AppleServiceFailurePolicy.shouldRequireReverification(failure) == false)
        #expect(AppleServiceFailurePolicy.isTransient(failure))
    }

    @Test
    func failureFromKeepsWrappedMarkerAttribution() {
        let marker = AnisetteAllServersNetworkFailure(lastURLErrorCode: -1004)
        let wrapped = NSError(
            domain: "Seal.Test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: marker]
        )
        let failure = AppleAccountClient.failure(from: wrapped)

        #expect(failure.code == "SEAL-ANI-116")
    }

    @Test
    func failureFromKeepsBareNetworkErrorOnNet101() {
        let failure = AppleAccountClient.failure(from: URLError(.cannotConnectToHost))

        #expect(failure.code == "SEAL-NET-101")
        #expect(failure.condition == .appleRequestTransportUnavailable)
        #expect(failure.operation == .authenticateAccount)
    }
}
