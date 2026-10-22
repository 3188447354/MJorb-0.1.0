import Foundation
import Testing
@testable import Seal

/// 0.1.52 更新下载改造的纯函数判据：续传决策、进度节流、SHA256 比对分类。
/// 这些判据原先埋在 URLSession delegate 回调与 actor 状态里测不到，抽成纯函数后在此钉住。
struct UpdateDownloadPolicyTests {

    // MARK: 续传：起点决策

    @Test
    func resumeStartDecisionUsesStoredResumeData() {
        #expect(UpdateDownloadResumePolicy.startDecision(hasStoredResumeData: true) == .resume)
        #expect(UpdateDownloadResumePolicy.startDecision(hasStoredResumeData: false) == .fresh)
    }

    // MARK: 续传：失败处置矩阵

    /// 切网络等失败只要系统给了 resumeData，就保存它走续传，而不是删档重来。
    @Test
    func failureWithResumeDataPersistsItForNextAttempt() {
        #expect(
            UpdateDownloadResumePolicy.failurePlan(
                attempt: .fresh,
                errorCarriesResumeData: true,
                alreadyRetriedFresh: false,
                isCancellation: false
            ) == .persistResumeDataAndFail
        )
        #expect(
            UpdateDownloadResumePolicy.failurePlan(
                attempt: .resumed,
                errorCarriesResumeData: true,
                alreadyRetriedFresh: false,
                isCancellation: false
            ) == .persistResumeDataAndFail
        )
    }

    /// 续传被服务端拒绝且没有新 resumeData：判定续传数据失效，自动回退全新下载。
    @Test
    func failedResumeWithoutNewResumeDataFallsBackToFresh() {
        #expect(
            UpdateDownloadResumePolicy.failurePlan(
                attempt: .resumed,
                errorCarriesResumeData: false,
                alreadyRetriedFresh: false,
                isCancellation: false
            ) == .discardResumeDataAndRetryFresh
        )
    }

    /// 回退只许一次：已回退过全新下载再失败，直接失败，不无限循环。
    @Test
    func fallbackToFreshHappensAtMostOnce() {
        #expect(
            UpdateDownloadResumePolicy.failurePlan(
                attempt: .resumed,
                errorCarriesResumeData: false,
                alreadyRetriedFresh: true,
                isCancellation: false
            ) == .fail
        )
        #expect(
            UpdateDownloadResumePolicy.failurePlan(
                attempt: .fresh,
                errorCarriesResumeData: false,
                alreadyRetriedFresh: false,
                isCancellation: false
            ) == .fail
        )
    }

    /// 用户主动取消绝不自动重开下载；有 resumeData 时只保存供下次手动续传。
    @Test
    func cancellationNeverAutoRetries() {
        #expect(
            UpdateDownloadResumePolicy.failurePlan(
                attempt: .resumed,
                errorCarriesResumeData: true,
                alreadyRetriedFresh: false,
                isCancellation: true
            ) == .persistResumeDataAndFail
        )
        #expect(
            UpdateDownloadResumePolicy.failurePlan(
                attempt: .resumed,
                errorCarriesResumeData: false,
                alreadyRetriedFresh: false,
                isCancellation: true
            ) == .fail
        )
    }

    // MARK: 续传：持久化往返

    @Test
    func resumeStoreRoundTripsPerSourceURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "seal-resume-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urlA = try #require(URL(string: "https://github.com/a/Seal.ipa"))
        let urlB = try #require(URL(string: "https://github.com/a/Other.ipa"))
        let blob = Data([0x01, 0x02, 0x03])

        #expect(UpdateDownloadResumeStore.load(for: urlA, in: directory) == nil)
        UpdateDownloadResumeStore.save(blob, for: urlA, in: directory)
        #expect(UpdateDownloadResumeStore.load(for: urlA, in: directory) == blob)
        // 不同源 URL 互不串扰；同一 URL 的存储键稳定。
        #expect(UpdateDownloadResumeStore.load(for: urlB, in: directory) == nil)
        #expect(
            UpdateDownloadResumeStore.fileURL(for: urlA, in: directory)
                == UpdateDownloadResumeStore.fileURL(for: urlA, in: directory)
        )
        #expect(
            UpdateDownloadResumeStore.fileURL(for: urlA, in: directory)
                != UpdateDownloadResumeStore.fileURL(for: urlB, in: directory)
        )
        UpdateDownloadResumeStore.clear(for: urlA, in: directory)
        #expect(UpdateDownloadResumeStore.load(for: urlA, in: directory) == nil)
    }

    // MARK: 进度节流判据

    @Test
    func progressPolicyEmitsFirstSampleAndFinalState() {
        #expect(
            UpdateDownloadProgressPolicy.shouldEmit(
                received: 10,
                lastEmittedReceived: -1,
                lastEmittedAt: 0,
                now: 0,
                force: false
            )
        )
        // 终态必达：哪怕刚回调过、字节没变，force 也必须放行。
        #expect(
            UpdateDownloadProgressPolicy.shouldEmit(
                received: 10,
                lastEmittedReceived: 10,
                lastEmittedAt: 100,
                now: 100.01,
                force: true
            )
        )
    }

    @Test
    func progressPolicySuppressesBurstsWithinIntervalAndDelta() {
        // 间隔内、增量不足：不回调（这正是旧实现每块数据起一个 Task 洪泛 UI 的反面）。
        #expect(
            UpdateDownloadProgressPolicy.shouldEmit(
                received: 1_000,
                lastEmittedReceived: 900,
                lastEmittedAt: 10,
                now: 10.05,
                force: false
            ) == false
        )
        // 字节没变化：哪怕过了间隔也不回调假进度。
        #expect(
            UpdateDownloadProgressPolicy.shouldEmit(
                received: 900,
                lastEmittedReceived: 900,
                lastEmittedAt: 10,
                now: 11,
                force: false
            ) == false
        )
    }

    @Test
    func progressPolicyEmitsOnByteDeltaOrInterval() {
        #expect(
            UpdateDownloadProgressPolicy.shouldEmit(
                received: 900 + UpdateDownloadProgressPolicy.minimumEmitByteDelta,
                lastEmittedReceived: 900,
                lastEmittedAt: 10,
                now: 10.01,
                force: false
            )
        )
        #expect(
            UpdateDownloadProgressPolicy.shouldEmit(
                received: 901,
                lastEmittedReceived: 900,
                lastEmittedAt: 10,
                now: 10 + UpdateDownloadProgressPolicy.minimumEmitInterval,
                force: false
            )
        )
        // 计数回退（重开/续传位置变化）立即回调，让 UI 回到真实位置。
        #expect(
            UpdateDownloadProgressPolicy.shouldEmit(
                received: 100,
                lastEmittedReceived: 900,
                lastEmittedAt: 10,
                now: 10.01,
                force: false
            )
        )
    }

    // MARK: 进度节流持有者（合并行为）

    @Test
    func progressCoalescerMergesBurstsAndAlwaysDeliversFinish() async {
        let recorder = ProgressRecorder()
        let clock = ManualClock()
        let coalescer = UpdateDownloadProgressCoalescer(
            onProgress: { received, _ in await recorder.record(received) },
            now: { clock.now }
        )

        // 同一时刻涌入 100 个样本：只应回调第一个。
        for index in 0..<100 {
            coalescer.update(received: Int64(index), total: 1_000_000)
        }
        // 时钟走过节流间隔且字节有变化：放行一次。
        clock.now += UpdateDownloadProgressPolicy.minimumEmitInterval + 0.01
        coalescer.update(received: 200, total: 1_000_000)
        coalescer.update(received: 201, total: 1_000_000)
        // 终态必达：间隔内也强制回调最终值。
        coalescer.finish(received: 1_000_000, total: 1_000_000)

        try? await Task.sleep(nanoseconds: 100_000_000)
        let values = await recorder.values
        // 只断言集合与计数：回调经无结构 Task 交付，执行顺序不做保证，不在这里钉顺序防抖动。
        #expect(values.contains(0))
        #expect(values.contains(200))
        #expect(values.contains(201) == false)
        #expect(values.contains(1_000_000))
        #expect(values.count == 3)
    }

    // MARK: SHA256 比对分类

    @Test
    func checksumClassificationVerifiesMatchingDigest() {
        let hex = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        #expect(
            UpdateDownloadChecksumPolicy.classification(
                expectedChecksumText: "\(hex)  Seal.ipa\n",
                actualSHA256: hex
            ) == .verified
        )
        // 大小写不敏感（shasum 与流式计算两端的大小写约定可能不同）。
        #expect(
            UpdateDownloadChecksumPolicy.classification(
                expectedChecksumText: "\(hex.uppercased())  Seal.ipa",
                actualSHA256: hex
            ) == .verified
        )
    }

    @Test
    func checksumClassificationRejectsMismatch() {
        let hex = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        #expect(
            UpdateDownloadChecksumPolicy.classification(
                expectedChecksumText: "\(hex)  Seal.ipa",
                actualSHA256: String(repeating: "0", count: 64)
            ) == .mismatch
        )
    }

    /// 校验资产取不到或内容不合法，与不一致一样 fail closed，绝不放行安装。
    @Test
    func checksumClassificationFailsClosedWhenChecksumUnavailable() {
        let hex = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        #expect(
            UpdateDownloadChecksumPolicy.classification(
                expectedChecksumText: nil,
                actualSHA256: hex
            ) == .checksumUnavailable
        )
        #expect(
            UpdateDownloadChecksumPolicy.classification(
                expectedChecksumText: "not-a-hash  Seal.ipa",
                actualSHA256: hex
            ) == .checksumUnavailable
        )
        #expect(
            UpdateDownloadChecksumPolicy.classification(
                expectedChecksumText: "",
                actualSHA256: hex
            ) == .checksumUnavailable
        )
    }

    @Test
    func checksumFailureUsesTheNextUniqueUpdateDownloadCode() {
        // 现有 UpdateDownloadError 占用 501...505，新码顺延 506 且不得与它们重复。
        #expect(UpdateDownloadChecksumPolicy.failureCode == "SEAL-UPDATE-DL-506")
        let failure = UpdateDownloadChecksumPolicy.failure()
        #expect(failure.code == "SEAL-UPDATE-DL-506")
        let existingCodes = [
            UpdateDownloadError.badHTTPStatus.code,
            UpdateDownloadError.saveFailed.code,
            UpdateDownloadError.transport(URLError(.unknown)).code,
            UpdateDownloadError.timeout.code,
            UpdateDownloadError.insufficientStorage.code
        ]
        #expect(existingCodes.contains(failure.code) == false)
        #expect(Set(existingCodes).count == existingCodes.count)
    }
}

private actor ProgressRecorder {
    private(set) var values: [Int64] = []

    func record(_ value: Int64) {
        values.append(value)
    }
}

private final class ManualClock: @unchecked Sendable {
    var now: TimeInterval = 0
}
