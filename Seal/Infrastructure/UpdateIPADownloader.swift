import CryptoKit
import Foundation

/// 应用内更新 IPA 下载服务：后台 URLSession 流式下载到 Application Support/Seal/Downloads，
/// 带节流合并的进度回调、断点续传与（可选的）Release `.sha256` 完整性校验。
/// 遵循项目「大包流式处理」纪律，不整块载入内存。
///
/// 并发说明（不新增第 6 份手写并发盒）：
/// - 跨 delegate 回调「只恢复一次」的 continuation 一律复用既有 `ContinuationBox`；
/// - 进度由一个 NSLock 保护的节流持有者（`UpdateDownloadProgressCoalescer`）合并，
///   它不是 continuation 盒，只保存最新进度值与上次回调锚点，谁在保护它见其注释；
/// - 会话注册表由 `UpdateDownloadSessionController` 的 NSLock 保护，见其注释。
struct UpdateIPADownloader {
    static let shared = UpdateIPADownloader()

    /// 后台会话标识：进程被系统杀掉后，系统仍用同一标识把已完成任务的事件交还给新进程。
    static let backgroundSessionIdentifier = "eu.seal.update-ipa-download"

    static var downloadsDirectoryURL: URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return support.appending(path: "Seal/Downloads", directoryHint: .isDirectory)
    }

    private var downloadsDirectory: URL { Self.downloadsDirectoryURL }

    private var sessionController: UpdateDownloadSessionController { .shared }

    /// 下载 IPA 到本地，返回落盘文件 URL。
    /// - Parameter expectedSize: Release 元数据中的精确资产大小（响应无 Content-Length 时的进度分母）。
    /// - Parameter checksumURL: Release `.sha256` 资产直链；非 nil 时下载完成（落盘后、返回前）
    ///   先流式计算文件 SHA256 与之比对，不一致即删文件并抛 `ImportFailure`
    ///   （`SEAL-UPDATE-DL-506`），不会把损坏包交到安装链路。为 nil 时不做完整性校验，
    ///   由调用方按 fail closed 原则自行处置（现有调用方在校验阶段对 nil 单独判失败）。
    /// - Parameter onProgress: 节流合并后的进度回调（已接收字节数, 总字节数可空），见
    ///   `UpdateDownloadProgressPolicy`：约 150ms 或 256KB 增量才回调一次，终态必达。
    /// - 断点续传：失败 / 取消时系统给出的 resumeData 会持久化到 Downloads 目录
    ///   （按源 URL 摘要命名），下次调用优先续传；续传被服务端拒绝且没有新 resumeData 时，
    ///   自动回退一次全新下载（判据是纯函数 `UpdateDownloadResumePolicy`）。
    /// - 取消：Swift Task 取消会经 `withTaskCancellationHandler` 传导到传输任务，
    ///   并以 `cancel(byProducingResumeData:)` 停任务以便下次续传。
    func download(
        from url: URL,
        expectedSize: Int64? = nil,
        checksumURL: URL? = nil,
        onProgress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )

        let knownSize = expectedSize.flatMap { $0 > 0 ? $0 : nil }
        await onProgress(0, knownSize)

        var resumeData = UpdateDownloadResumeStore.load(for: url, in: downloadsDirectory)
        var attemptKind: UpdateDownloadAttemptKind =
            UpdateDownloadResumePolicy.startDecision(hasStoredResumeData: resumeData != nil) == .resume
                ? .resumed
                : .fresh
        var alreadyRetriedFresh = false

        while true {
            try Task.checkCancellation()
            let destination = downloadsDirectory
                .appending(path: "seal-update-\(UUID().uuidString).ipa")
            do {
                // 先快照成 let 再进闭包，避免并发闭包捕获循环可变量。
                let attemptResumeData = resumeData
                let attemptKindSnapshot = attemptKind
                let attemptAlreadyRetriedFresh = alreadyRetriedFresh
                let fileURL = try await withTaskCancellationHandler {
                    try await sessionController.download(
                        from: url,
                        resumeData: attemptResumeData,
                        attemptKind: attemptKindSnapshot,
                        alreadyRetriedFresh: attemptAlreadyRetriedFresh,
                        expectedSize: knownSize,
                        destination: destination,
                        onProgress: onProgress
                    )
                } onCancel: {
                    UpdateDownloadSessionController.shared.cancelActiveDownload()
                }
                // 成功：清掉续传残留与进行中记录，随后按需做完整性校验，校验失败不返回文件。
                UpdateDownloadResumeStore.clear(for: url, in: downloadsDirectory)
                UpdateDownloadPendingStore.clear(in: downloadsDirectory)
                if let checksumURL {
                    try await verifyChecksum(fileURL: fileURL, checksumURL: checksumURL)
                }
                return fileURL
            } catch let attemptFailure as UpdateDownloadAttemptFailure {
                switch attemptFailure.plan {
                case .discardResumeDataAndRetryFresh:
                    // 续传数据已被服务端拒绝且无新 resumeData：下载器已清掉持久化残留，
                    // 这里自动回退全新下载（只回退一次，alreadyRetriedFresh 钉住上限）。
                    alreadyRetriedFresh = true
                    resumeData = nil
                    attemptKind = .fresh
                    continue
                case .persistResumeDataAndFail, .fail:
                    throw attemptFailure.underlying
                }
            }
        }
    }

    /// 流式校验下载文件的 SHA256：校验文件本身只有一行文本，整块读入无碍；
    /// IPA 本体走 `AppFileStore.streamingSHA256`（CryptoKit 分块读，禁止整块载入）。
    private func verifyChecksum(fileURL: URL, checksumURL: URL) async throws {
        let checksumData: Data
        do {
            let (data, response) = try await URLSession.shared.data(from: checksumURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: fileURL)
                throw UpdateDownloadError.transport(URLError(.badServerResponse))
            }
            checksumData = data
        } catch let error as UpdateDownloadError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw UpdateDownloadError.transport(error)
        }

        let actual: String
        do {
            actual = try AppFileStore.streamingSHA256(url: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw UpdateDownloadChecksumPolicy.failure()
        }
        let classification = UpdateDownloadChecksumPolicy.classification(
            expectedChecksumText: String(data: checksumData, encoding: .utf8),
            actualSHA256: actual
        )
        guard classification == .verified else {
            try? FileManager.default.removeItem(at: fileURL)
            throw UpdateDownloadChecksumPolicy.failure()
        }
    }

    /// 删除指定下载文件（导入成功后清理）。
    func deleteDownloadedFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// AppDelegate 的 `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// 转发点：系统在后台事件全部交付后要求调用这个 handler，否则下次唤醒会被推迟。
    /// 接线在 `Seal/App/SealApp.swift` 的 `SealAppDelegate`（UIApplicationDelegateAdaptor）。
    static func setBackgroundSessionCompletionHandler(_ handler: @escaping () -> Void) {
        UpdateDownloadSessionController.setBackgroundCompletionHandler(handler)
    }

    static func isStorageFull(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (error.domain == NSPOSIXErrorDomain && error.code == 28)
    }
}

enum UpdateDownloadProgress {
    static func fraction(received: Int64, total: Int64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(max(Double(received) / Double(total), 0), 1)
    }
}

// MARK: - 进度节流（纯函数判据 + 线程安全持有者）

/// 进度回调的节流判据（纯函数，可单测）。
/// UI 只需要「数字在走」：约 150ms 或每多下 256KB 才回调一次；首个样本与终态必达。
enum UpdateDownloadProgressPolicy {
    static let minimumEmitInterval: TimeInterval = 0.15
    static let minimumEmitByteDelta: Int64 = 256 * 1024

    static func shouldEmit(
        received: Int64,
        lastEmittedReceived: Int64,
        lastEmittedAt: TimeInterval,
        now: TimeInterval,
        force: Bool
    ) -> Bool {
        if force { return true }
        if lastEmittedReceived < 0 { return true }
        // 续传/重开导致计数回退时立即回调，让 UI 回到真实位置而不是停在旧百分比。
        if received < lastEmittedReceived { return true }
        if received - lastEmittedReceived >= minimumEmitByteDelta { return true }
        if received != lastEmittedReceived, now - lastEmittedAt >= minimumEmitInterval { return true }
        return false
    }
}

/// 线程安全的进度持有者：`didWriteData` 在会话 delegate 队列上只把最新值写进来，
/// 是否回调 UI 由 `UpdateDownloadProgressPolicy` 决定；只有决定回调时才起一个 Task，
/// 不再像旧实现那样每块数据起一个无结构 Task 洪泛 UI。
/// 全部可变状态由内部 NSLock 保护（这就是它 `@unchecked Sendable` 的依据）。
final class UpdateDownloadProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmittedReceived: Int64 = -1
    private var lastEmittedAt: TimeInterval = 0
    private let sink: @Sendable (Int64, Int64?) async -> Void
    private let now: @Sendable () -> TimeInterval

    init(
        onProgress: @escaping @Sendable (Int64, Int64?) async -> Void,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.sink = onProgress
        self.now = now
    }

    func update(received: Int64, total: Int64?) {
        emit(received: received, total: total, force: false)
    }

    /// 终态（完成/失败前）强制回调一次最新值，保证 UI 数字必达终态。
    func finish(received: Int64, total: Int64?) {
        emit(received: received, total: total, force: true)
    }

    private func emit(received: Int64, total: Int64?, force: Bool) {
        lock.lock()
        let shouldEmit = UpdateDownloadProgressPolicy.shouldEmit(
            received: received,
            lastEmittedReceived: lastEmittedReceived,
            lastEmittedAt: lastEmittedAt,
            now: now(),
            force: force
        )
        if shouldEmit {
            lastEmittedReceived = received
            lastEmittedAt = now()
        }
        lock.unlock()
        guard shouldEmit else { return }
        let sink = self.sink
        Task { await sink(received, total) }
    }
}

// MARK: - 断点续传（纯函数判据 + 持久化）

enum UpdateDownloadAttemptKind: Equatable, Sendable {
    case fresh
    case resumed
}

/// 续传决策（纯函数，可单测）。
enum UpdateDownloadResumePolicy {
    enum StartDecision: Equatable, Sendable {
        case fresh
        case resume
    }

    /// 有持久化的 resumeData（按源 URL 存放，天然同源）才续传。
    static func startDecision(hasStoredResumeData: Bool) -> StartDecision {
        hasStoredResumeData ? .resume : .fresh
    }

    enum FailurePlan: Equatable, Sendable {
        /// 保存（新的）resumeData 后失败退出，下次调用优先续传。
        case persistResumeDataAndFail
        /// 续传数据已失效：丢弃它并在同一次调用内自动回退全新下载。
        case discardResumeDataAndRetryFresh
        /// 直接失败，不动续传状态。
        case fail
    }

    static func failurePlan(
        attempt: UpdateDownloadAttemptKind,
        errorCarriesResumeData: Bool,
        alreadyRetriedFresh: Bool,
        isCancellation: Bool
    ) -> FailurePlan {
        if isCancellation {
            // 用户主动取消：有 resumeData 就存好供下次续传，绝不自动重开下载。
            return errorCarriesResumeData ? .persistResumeDataAndFail : .fail
        }
        if errorCarriesResumeData {
            // 含切网络失败：系统给了 resumeData 就走续传，而不是删档重来。
            return .persistResumeDataAndFail
        }
        if attempt == .resumed, alreadyRetriedFresh == false {
            // 续传被服务端拒绝且没有给出新的 resumeData：判定续传数据失效，回退全新下载。
            return .discardResumeDataAndRetryFresh
        }
        return .fail
    }
}

/// resumeData 持久化：按源 URL 的 SHA256 摘要命名，与下载任务一一对应；
/// 文件只放不透明的系统 resumeData，不解析内容。
enum UpdateDownloadResumeStore {
    static func fileURL(for sourceURL: URL, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(sourceURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "seal-update-resume-\(String(digest.prefix(32))).data")
    }

    static func save(_ data: Data, for sourceURL: URL, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: sourceURL, in: directory), options: .atomic)
    }

    static func load(for sourceURL: URL, in directory: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: sourceURL, in: directory))
    }

    static func clear(for sourceURL: URL, in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: sourceURL, in: directory))
    }
}

/// 进行中下载的持久化记录：进程被杀后新进程靠它把后台任务的结果对上号
/// （源 URL + 目标落盘路径 + 是否已完成）。同一时刻只允许一笔更新下载，与 UI 单任务一致。
private struct UpdateDownloadPendingRecord: Codable {
    var sourceURL: String
    var destinationPath: String
    var expectedSize: Int64?
    var isFinished: Bool
}

private enum UpdateDownloadPendingStore {
    static func fileURL(in directory: URL) -> URL {
        directory.appending(path: "seal-update-pending.json")
    }

    static func save(_ record: UpdateDownloadPendingRecord, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: fileURL(in: directory), options: .atomic)
    }

    static func load(in directory: URL) -> UpdateDownloadPendingRecord? {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else { return nil }
        return try? JSONDecoder().decode(UpdateDownloadPendingRecord.self, from: data)
    }

    static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
    }
}

// MARK: - SHA256 校验分类（纯函数）

/// 下载文件与 Release `.sha256` 资产的比对结果分类（纯函数，可单测）。
enum UpdateDownloadChecksumPolicy {
    enum Classification: Equatable, Sendable {
        case verified
        case mismatch
        /// 校验资产取不到 / 内容不是合法的 shasum 输出：fail closed，同样不放行安装。
        case checksumUnavailable
    }

    static func classification(expectedChecksumText: String?, actualSHA256: String) -> Classification {
        guard let text = expectedChecksumText,
              let expected = UpdateChecker.expectedSHA256(from: text) else {
            return .checksumUnavailable
        }
        return UpdateChecker.hashMatches(expected: expected, actual: actualSHA256)
            ? .verified
            : .mismatch
    }

    /// 顺延现有 `SEAL-UPDATE-DL-501…505`（UpdateDownloadError）的唯一新码。
    static let failureCode = "SEAL-UPDATE-DL-506"

    static func failure() -> ImportFailure {
        ImportFailure(
            title: "更新包校验失败",
            reason: "下载的更新包与发布方提供的校验值不一致，文件可能已损坏或被替换。",
            recovery: "重新下载更新包",
            code: failureCode,
            condition: .signedArtifactInvalid,
            action: .retry,
            retryDisposition: .manual,
            origin: .fileStore
        )
    }
}

enum UpdateDownloadError: LocalizedError {
    case badHTTPStatus
    case saveFailed
    case insufficientStorage
    case timeout
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badHTTPStatus:
            return "下载失败（服务器响应异常）"
        case .saveFailed:
            return "下载文件保存失败"
        case .insufficientStorage:
            return "设备存储空间不足"
        case .timeout:
            return "网络下载超时，请检查网络后重试"
        case .transport:
            return "网络下载失败，请稍后重试"
        }
    }

    var code: String {
        switch self {
        case .badHTTPStatus: return "SEAL-UPDATE-DL-501"
        case .saveFailed: return "SEAL-UPDATE-DL-502"
        case .insufficientStorage: return "SEAL-UPDATE-DL-505"
        case .timeout: return "SEAL-UPDATE-DL-504"
        case .transport: return "SEAL-UPDATE-DL-503"
        }
    }
}

/// 一次下载尝试的内部失败载荷：把已映射好的用户错误与续传处置计划一起带回
/// `UpdateIPADownloader.download` 的重试循环，不对外暴露。
private struct UpdateDownloadAttemptFailure: Error {
    let underlying: Error
    let plan: UpdateDownloadResumePolicy.FailurePlan
}

// MARK: - 后台会话控制器

/// 单个下载任务在会话侧的登记状态。全部字段只在控制器的 NSLock 下读写
/// （delegate 回调与调用方并发到达），这是它 `@unchecked Sendable` 的依据。
private final class UpdateDownloadTaskState: @unchecked Sendable {
    let sourceURL: URL
    let destination: URL
    let expectedSize: Int64?
    let attemptKind: UpdateDownloadAttemptKind
    let alreadyRetriedFresh: Bool
    var task: URLSessionDownloadTask?
    var box: ContinuationBox<URL>?
    var coalescer: UpdateDownloadProgressCoalescer?
    var finishedFileURL: URL?
    var terminalFailure: UpdateDownloadAttemptFailure?
    var delivered = false

    init(
        sourceURL: URL,
        destination: URL,
        expectedSize: Int64?,
        attemptKind: UpdateDownloadAttemptKind,
        alreadyRetriedFresh: Bool
    ) {
        self.sourceURL = sourceURL
        self.destination = destination
        self.expectedSize = expectedSize
        self.attemptKind = attemptKind
        self.alreadyRetriedFresh = alreadyRetriedFresh
    }
}

/// 后台 URLSession 的唯一持有者（单例，会话永不 invalidate——后台会话失效会连带
/// 取消系统侧任务；进程重启后用同一 identifier 重建会话即可重新接上）。
///
/// 后台会话不能用前台会话的 async `download(for:delegate:)`：它没有 per-task delegate，
/// 结果只经会话 delegate 的 `didFinishDownloadingTo` / `didCompleteWithError` 交付，
/// 且临时文件必须在 `didFinishDownloadingTo` 返回前同步移走，否则系统会删掉它。
/// 这里用既有 `ContinuationBox` 把 delegate 事件桥回 async 世界（只恢复一次，迟到事件丢弃）。
/// `@unchecked Sendable` 的依据：全部可变状态由 NSLock 保护（静态 handler 另有一把静态锁），
/// `downloadsDirectory` 不可变，`session` 只在 init 里赋值一次且 URLSession 本身线程安全。
private final class UpdateDownloadSessionController: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = UpdateDownloadSessionController(
        downloadsDirectory: UpdateIPADownloader.downloadsDirectoryURL
    )

    private let downloadsDirectory: URL
    private let lock = NSLock()
    private var states: [Int: UpdateDownloadTaskState] = [:]
    private var activeTaskIdentifier: Int?
    private var session: URLSession!

    private static let backgroundHandlerLock = NSLock()
    private static var backgroundCompletionHandler: (() -> Void)?

    static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundHandlerLock.lock()
        backgroundCompletionHandler = handler
        backgroundHandlerLock.unlock()
    }

    private static func takeBackgroundCompletionHandler() -> (() -> Void)? {
        backgroundHandlerLock.lock()
        defer { backgroundHandlerLock.unlock() }
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        return handler
    }

    init(downloadsDirectory: URL) {
        self.downloadsDirectory = downloadsDirectory
        super.init()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: UpdateIPADownloader.backgroundSessionIdentifier
        )
        configuration.waitsForConnectivity = true
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "Seal.UpdateDownloadSession"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        adoptExistingTasks()
    }

    // MARK: 调用入口

    func download(
        from url: URL,
        resumeData: Data?,
        attemptKind: UpdateDownloadAttemptKind,
        alreadyRetriedFresh: Bool,
        expectedSize: Int64?,
        destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws -> URL {
        // 进程曾被杀、任务在系统侧已完成：delegate 在新进程里已把文件移到记录中的落盘路径，
        // 直接交还那个文件，不再发新请求。
        if let record = UpdateDownloadPendingStore.load(in: downloadsDirectory),
           record.isFinished,
           record.sourceURL == url.absoluteString {
            let recovered = URL(fileURLWithPath: record.destinationPath)
            if FileManager.default.fileExists(atPath: recovered.path) {
                UpdateDownloadPendingStore.clear(in: downloadsDirectory)
                return recovered
            }
            UpdateDownloadPendingStore.clear(in: downloadsDirectory)
        }

        let existingTasks = await session.getAllTasks()
        let existingTask = existingTasks
            .compactMap { $0 as? URLSessionDownloadTask }
            .first { task in
                (task.state == .running || task.state == .suspended)
                    && (task.originalRequest?.url == url || task.currentRequest?.url == url)
            }

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<URL>(continuation)
            let coalescer = UpdateDownloadProgressCoalescer(onProgress: onProgress)

            if let existingTask {
                attach(box: box, coalescer: coalescer, to: existingTask, fallbackURL: url)
                return
            }

            let state = UpdateDownloadTaskState(
                sourceURL: url,
                destination: destination,
                expectedSize: expectedSize,
                attemptKind: attemptKind,
                alreadyRetriedFresh: alreadyRetriedFresh
            )
            state.box = box
            state.coalescer = coalescer

            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 120
                task = session.downloadTask(with: request)
            }
            state.task = task

            lock.lock()
            states[task.taskIdentifier] = state
            activeTaskIdentifier = task.taskIdentifier
            lock.unlock()

            UpdateDownloadPendingStore.save(
                UpdateDownloadPendingRecord(
                    sourceURL: url.absoluteString,
                    destinationPath: destination.path,
                    expectedSize: expectedSize,
                    isFinished: false
                ),
                in: downloadsDirectory
            )
            task.resume()
        }
    }

    /// 取消当前下载：用 `cancel(byProducingResumeData:)` 而不是普通 cancel，
    /// 让系统把已下载部分做成 resumeData，经 didCompleteWithError 的 userInfo 回来后持久化。
    func cancelActiveDownload() {
        lock.lock()
        let task = activeTaskIdentifier.flatMap { states[$0]?.task }
        lock.unlock()
        task?.cancel(byProducingResumeData: { _ in })
    }

    // MARK: 任务接管（进程重启后）

    /// 新进程重建会话后，把系统交还的在途任务重新登记；
    /// 它们的落盘路径以持久化记录为准，没有记录的落到 recovered 路径，文件不丢。
    private func adoptExistingTasks() {
        let record = UpdateDownloadPendingStore.load(in: downloadsDirectory)
        session.getTasksWithCompletionHandler { _, _, downloadTasks in
            for task in downloadTasks where task.state == .running || task.state == .suspended {
                let sourceURL = task.originalRequest?.url
                    ?? task.currentRequest?.url
                    ?? URL(fileURLWithPath: "/")
                let destination: URL
                if let record, record.sourceURL == sourceURL.absoluteString {
                    destination = URL(fileURLWithPath: record.destinationPath)
                } else {
                    destination = self.downloadsDirectory.appending(
                        path: "seal-update-recovered-\(task.taskIdentifier).ipa"
                    )
                }
                let state = UpdateDownloadTaskState(
                    sourceURL: sourceURL,
                    destination: destination,
                    expectedSize: record?.expectedSize,
                    attemptKind: .fresh,
                    alreadyRetriedFresh: false
                )
                state.task = task
                self.lock.lock()
                if self.states[task.taskIdentifier] == nil {
                    self.states[task.taskIdentifier] = state
                }
                self.lock.unlock()
            }
        }
    }

    private func attach(
        box: ContinuationBox<URL>,
        coalescer: UpdateDownloadProgressCoalescer,
        to task: URLSessionDownloadTask,
        fallbackURL: URL
    ) {
        lock.lock()
        var state = states[task.taskIdentifier]
        if state == nil {
            let record = UpdateDownloadPendingStore.load(in: downloadsDirectory)
            let destination = record.map { URL(fileURLWithPath: $0.destinationPath) }
                ?? downloadsDirectory.appending(path: "seal-update-recovered-\(task.taskIdentifier).ipa")
            let created = UpdateDownloadTaskState(
                sourceURL: fallbackURL,
                destination: destination,
                expectedSize: record?.expectedSize,
                attemptKind: .fresh,
                alreadyRetriedFresh: false
            )
            created.task = task
            states[task.taskIdentifier] = created
            state = created
        }
        guard let state else {
            lock.unlock()
            box.resume(throwing: UpdateDownloadError.transport(URLError(.unknown)))
            return
        }
        let finished = state.finishedFileURL
        let failure = state.terminalFailure
        if finished == nil, failure == nil {
            state.box = box
            state.coalescer = coalescer
            activeTaskIdentifier = task.taskIdentifier
        }
        lock.unlock()

        if let finished {
            box.resume(returning: finished)
        } else if let failure {
            box.resume(throwing: failure)
        }
    }

    private func state(for task: URLSessionTask) -> UpdateDownloadTaskState? {
        lock.lock()
        defer { lock.unlock() }
        return states[task.taskIdentifier]
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let state = state(for: downloadTask) else { return }
        // totalBytesExpectedToWrite 在无 Content-Length（GitHub 302 重定向后的响应、
        // chunked transfer）时为 -1，不能作为进度分母；总大小仍未知时传 nil，
        // 由 UI 展示已下载字节数，不发假百分比。
        var expected = downloadTask.countOfBytesExpectedToReceive
        if expected <= 0 { expected = totalBytesExpectedToWrite }
        let total: Int64? = expected > 0 ? expected : state.expectedSize
        state.coalescer?.update(received: totalBytesWritten, total: total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 后台会话的临时文件在本方法返回后即被系统删除，必须同步移走。
        guard let state = state(for: downloadTask) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            if state.attemptKind == .resumed {
                UpdateDownloadResumeStore.clear(for: state.sourceURL, in: downloadsDirectory)
            }
            deliver(
                state: state,
                failure: UpdateDownloadAttemptFailure(
                    underlying: UpdateDownloadError.badHTTPStatus,
                    plan: .fail
                )
            )
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: state.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: state.destination.path) {
                try FileManager.default.removeItem(at: state.destination)
            }
            try FileManager.default.moveItem(at: location, to: state.destination)
        } catch let error as NSError where UpdateIPADownloader.isStorageFull(error) {
            deliver(
                state: state,
                failure: UpdateDownloadAttemptFailure(
                    underlying: UpdateDownloadError.insufficientStorage,
                    plan: .fail
                )
            )
            return
        } catch {
            deliver(
                state: state,
                failure: UpdateDownloadAttemptFailure(
                    underlying: UpdateDownloadError.saveFailed,
                    plan: .fail
                )
            )
            return
        }

        // 先落记录再恢复 continuation：进程若在此后立刻被杀，新进程能靠记录找回文件。
        UpdateDownloadPendingStore.save(
            UpdateDownloadPendingRecord(
                sourceURL: state.sourceURL.absoluteString,
                destinationPath: state.destination.path,
                expectedSize: state.expectedSize,
                isFinished: true
            ),
            in: downloadsDirectory
        )
        UpdateDownloadResumeStore.clear(for: state.sourceURL, in: downloadsDirectory)
        state.coalescer?.finish(
            received: downloadTask.countOfBytesReceived,
            total: state.expectedSize
        )

        lock.lock()
        state.finishedFileURL = state.destination
        let box = state.box
        let shouldDeliver = state.delivered == false
        state.delivered = true
        if activeTaskIdentifier == downloadTask.taskIdentifier { activeTaskIdentifier = nil }
        lock.unlock()
        if shouldDeliver { box?.resume(returning: state.destination) }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let state = state(for: task) else { return }

        lock.lock()
        let alreadyDelivered = state.delivered
        if activeTaskIdentifier == task.taskIdentifier { activeTaskIdentifier = nil }
        lock.unlock()
        // error == nil 的完成已由 didFinishDownloadingTo 交付，这里只收尾；
        // 若没等到 didFinish 就无错完成（异常路径），也要交付失败避免调用方永久挂起。
        guard let error else {
            if alreadyDelivered == false {
                UpdateDownloadPendingStore.clear(in: downloadsDirectory)
                deliver(
                    state: state,
                    failure: UpdateDownloadAttemptFailure(
                        underlying: UpdateDownloadError.transport(URLError(.badServerResponse)),
                        plan: .fail
                    )
                )
            }
            return
        }
        if alreadyDelivered { return }

        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let isCancellation = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let plan = UpdateDownloadResumePolicy.failurePlan(
            attempt: state.attemptKind,
            errorCarriesResumeData: resumeData != nil,
            alreadyRetriedFresh: state.alreadyRetriedFresh,
            isCancellation: isCancellation
        )
        switch plan {
        case .persistResumeDataAndFail:
            if let resumeData {
                UpdateDownloadResumeStore.save(resumeData, for: state.sourceURL, in: downloadsDirectory)
            }
        case .discardResumeDataAndRetryFresh:
            UpdateDownloadResumeStore.clear(for: state.sourceURL, in: downloadsDirectory)
        case .fail:
            break
        }
        UpdateDownloadPendingStore.clear(in: downloadsDirectory)

        let underlying: Error
        if isCancellation {
            underlying = CancellationError()
        } else if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            underlying = UpdateDownloadError.timeout
        } else {
            underlying = UpdateDownloadError.transport(error)
        }
        deliver(
            state: state,
            failure: UpdateDownloadAttemptFailure(underlying: underlying, plan: plan)
        )
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let pending = states.values.filter { $0.delivered == false }
        for state in pending { state.delivered = true }
        lock.unlock()
        for state in pending {
            state.box?.resume(
                throwing: UpdateDownloadAttemptFailure(
                    underlying: UpdateDownloadError.transport(error ?? URLError(.unknown)),
                    plan: .fail
                )
            )
        }
    }

    /// 后台事件全部交付完毕：调用系统给的 completion handler（在主队列），
    /// 否则系统会推迟下一次后台唤醒。handler 由 AppDelegate 转发点存入。
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let handler = Self.takeBackgroundCompletionHandler() else { return }
        DispatchQueue.main.async { handler() }
    }

    private func deliver(state: UpdateDownloadTaskState, failure: UpdateDownloadAttemptFailure) {
        lock.lock()
        if state.terminalFailure == nil { state.terminalFailure = failure }
        let box = state.box
        let shouldDeliver = state.delivered == false
        state.delivered = true
        lock.unlock()
        // 失败终态由 UI 切到失败阶段表达，这里不再补发进度（补发 0 会把进度条打回起点）。
        if shouldDeliver { box?.resume(throwing: failure) }
    }
}
