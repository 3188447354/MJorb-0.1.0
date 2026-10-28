import SwiftUI
import UIKit

/// 应用内更新抽屉。
///
/// 下载、校验和进入签名是三个不同的阶段：只有在 IPA 已完成版本与完整性校验后，
/// 才把文件交给签名流程，避免把「已下载」误写成「已安装」。
struct UpdateNoticeView: View {
    let notice: UpdateNotice
    let onDismiss: () -> Void
    let onInstall: ((URL) -> Void)?
    @Environment(\.openURL) private var openURL

    @State private var phase: DownloadPhase = .available
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadGeneration = UUID()
    @State private var lastProgressPresentationAt = Date.distantPast
    @State private var fittedDetentHeight: CGFloat?
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var didMeasureInitialDetent = false

    private static let progressPresentationInterval: TimeInterval = 0.5

    private enum DownloadFailure: Equatable {
        case download
        case verification
        case storage
    }

    private enum DownloadPhase: Equatable {
        case available
        case downloading(Int64, Int64?)
        case verifying
        case ready
        case failed(DownloadFailure)
    }

    /// 进度数字属于下载阶段内部状态，不应每个字节回调都触发抽屉转场动画。
    private enum PhaseAnimationKey: Equatable {
        case available
        case downloading
        case verifying
        case ready
        case failed(DownloadFailure)
    }

    private var phaseAnimationKey: PhaseAnimationKey {
        switch phase {
        case .available: .available
        case .downloading: .downloading
        case .verifying: .verifying
        case .ready: .ready
        case .failed(let failure): .failed(failure)
        }
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    /// Release 的 Markdown 正文转换为抽屉中的简洁更新条目。
    private var changeItems: [String] {
        UpdateNoticeContentPolicy.changeItems(from: notice.message, version: notice.version)
    }

    var body: some View {
        SealDrawer(title: drawerTitle, showsFooter: true) {
            phaseContent.padding(.bottom, 12)
        } footer: {
            footer
        }
        .presentationDetents(availableDetents, selection: $selectedDetent)
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled(isDismissible == false)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: phaseAnimationKey)
        .onPreferenceChange(SealDrawerLayoutMeasurementsPreferenceKey.self) { measurements in
            updateFittedDetent(using: measurements)
        }
        .onDisappear {
            downloadGeneration = UUID()
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private var availableDetents: Set<PresentationDetent> {
        guard let fittedDetentHeight else { return [.medium, .large] }
        return [.height(fittedDetentHeight), .large]
    }

    private func updateFittedDetent(using measurements: SealDrawerLayoutMeasurements) {
        guard measurements.totalHeight > 0 else { return }
        let screenLimit = max(320, UIScreen.main.bounds.height - 80)
        let fittedHeight = min(max(measurements.totalHeight + 36, 320), screenLimit)
        guard abs((self.fittedDetentHeight ?? 0) - fittedHeight) > 1 else { return }

        let isExpanded = selectedDetent == .large
        self.fittedDetentHeight = fittedHeight
        if didMeasureInitialDetent == false || isExpanded == false {
            selectedDetent = .height(fittedHeight)
        }
        didMeasureInitialDetent = true
    }

    private var drawerTitle: String {
        switch phase {
        case .available:
            "发现新版本"
        case .downloading:
            "正在下载更新包"
        case .verifying:
            "正在验证更新包"
        case .ready:
            "更新包验证通过"
        case .failed(let failure):
            switch failure {
            case .download: "下载未完成"
            case .verification: "更新包校验失败"
            case .storage: "存储空间不足"
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .available:
            availableContent
        case .downloading(let received, let total):
            downloadingContent(received: received, total: total)
        case .verifying:
            progressContent(detail: "核对版本与文件完整性")
        case .ready:
            readyContent
        case .failed(let failure):
            failureContent(failure)
        }
    }

    private var isDismissible: Bool {
        switch phase {
        case .downloading(_, _), .verifying, .ready: false
        case .available, .failed(_): true
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .available:
            VStack(spacing: 4) {
                primaryButton("下载并更新", action: startDownload)
                secondaryButton("暂不更新", action: onDismiss)
            }
        case .downloading(_, _):
            secondaryButton("取消下载", action: cancelDownload)
        case .verifying, .ready:
            EmptyView()
        case .failed(let failure):
            VStack(spacing: 4) {
                if failure == .storage {
                    primaryButton("重试", action: startDownload)
                    secondaryButton("关闭", action: onDismiss)
                } else {
                    primaryButton("重新下载", action: startDownload)
                    secondaryButton("暂不更新", action: onDismiss)
                }
            }
        }
    }

    private var availableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("当前 \(displayVersion(currentVersion))  →")
                    .foregroundStyle(Color.sealTextSecondary)
                Text("新版 \(displayVersion(notice.version))")
                    .foregroundStyle(Color.sealAccent)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)

            if changeItems.isEmpty == false {
                Text("更新内容")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                changesList
            }
        }
        .padding(.top, 8)
    }

    private var changesList: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(changeItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(Color.sealAccent)
                        .frame(width: 5, height: 5)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func downloadingContent(received: Int64, total: Int64?) -> some View {
        let progress = UpdateDownloadProgress.inFlightFraction(received: received, total: total)
        return VStack(alignment: .leading, spacing: 0) {
            Text(downloadDetail(received: received, total: total))
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
                .padding(.top, 8)
            if received > 0 {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.sealAccent)
                        .padding(.top, 14)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.sealAccent)
                        Text("正在下载")
                            .font(.subheadline)
                            .foregroundStyle(Color.sealTextSecondary)
                            .singleLine()
                    }
                    .padding(.top, 14)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.sealAccent)
                    Text("正在连接更新源")
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                }
                .padding(.top, 14)
            }
        }
        .padding(.top, 12)
    }

    private func progressContent(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.sealAccent)
                .frame(maxWidth: .infinity)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private var readyContent: some View {
        Text("正在打开更新确认")
            .font(.subheadline)
            .foregroundStyle(Color.sealTextSecondary)
            .singleLine()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 22)
    }

    private func failureContent(_ failure: DownloadFailure) -> some View {
        Text(failure == .verification
             ? "更新包校验失败，Seal 未更改。"
             : failure == .storage
                ? "空间不足；释放空间后重试。"
                : "下载不完整，Seal 未更改。")
            .font(.subheadline)
            .foregroundStyle(Color.sealTextSecondary)
            .singleLine()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.white)
                .background(Color.sealAccent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private func downloadDetail(received: Int64, total: Int64?) -> String {
        guard received > 0 else {
            guard let total, total > 0 else {
                return "正在连接更新源，收到数据后显示下载进度"
            }
            return "正在连接更新源 · 安装包 \(total.formatted(.byteCount(style: .file)))"
        }
        let receivedText = received.formatted(.byteCount(style: .file))
        guard let total, total > 0,
              let progress = UpdateDownloadProgress.inFlightFraction(received: received, total: total) else {
            return "已下载 \(receivedText)"
        }
        let progressText = received >= total ? "正在完成下载" : "下载进度 \(progress.sealPercentText)"
        return "\(progressText) · 已下载 \(receivedText) / \(total.formatted(.byteCount(style: .file)))"
    }

    @MainActor
    private func startDownload() {
        if case .downloading = phase { return }
        guard let ipaURL = notice.ipaDownloadURL, let onInstall else {
            if let url = notice.downloadURL { openURL(url) }
            return
        }
        guard let expectedSHA256 = notice.expectedSHA256 else {
            phase = .failed(.verification)
            return
        }

        let generation = UUID()
        downloadGeneration = generation
        lastProgressPresentationAt = .distantPast
        phase = .downloading(0, notice.ipaDownloadSize)
        downloadTask = Task {
            let localURL: URL
            do {
                localURL = try await UpdateIPADownloader.shared.download(
                        from: ipaURL,
                        expectedSize: notice.ipaDownloadSize,
                        expectedSHA256: expectedSHA256,
                        onProgress: { @MainActor received, total in
                            guard downloadGeneration == generation,
                                  case .downloading(let previousBytes, _) = phase else { return }
                            let now = Date()
                            let reachedKnownEnd = total.map { received >= $0 } ?? false
                            guard previousBytes == 0
                                    || received < previousBytes
                                    || reachedKnownEnd
                                    || now.timeIntervalSince(lastProgressPresentationAt) >= Self.progressPresentationInterval else {
                                return
                            }
                            lastProgressPresentationAt = now
                            let displayedBytes = received < previousBytes
                                ? received
                                : max(received, previousBytes)
                            phase = .downloading(displayedBytes, total)
                        }
                    )
            } catch is CancellationError {
                guard downloadGeneration == generation else { return }
                phase = .available
                downloadTask = nil
                return
            } catch {
                guard downloadGeneration == generation else { return }
                phase = .failed(Self.downloadFailureKind(for: error))
                downloadTask = nil
                return
            }

            guard downloadGeneration == generation else {
                // 已下载并校验通过的包已在下载器里登记：抽屉被关 / 任务被取消都不删它，
                // 下次点「下载并更新」直接复用（见 UpdateIPADownloader 的完成登记）。
                // 只有判无效才丢弃。
                return
            }

            phase = .verifying
            do {
                // SHA256 已用检查更新时取得的清单摘要由下载器校验；此处再核对 IPA 内版本。
                let parsed = try IPAParserService().parse(url: localURL)
                guard UpdateChecker.advertisedVersion(notice.version, matchesIPAVersion: parsed.version) else {
                    UpdateIPADownloader.shared.discardCompletedDownload(at: localURL)
                    guard downloadGeneration == generation else { return }
                    phase = .failed(.verification)
                    downloadTask = nil
                    return
                }

                guard downloadGeneration == generation else {
                    // 同上：已校验的包保留登记、不删。
                    return
                }
                phase = .ready
                try await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, downloadGeneration == generation else {
                    // 同上：转交窗口里被取消，已校验的包保留登记、不删。
                    return
                }
                downloadGeneration = UUID()
                downloadTask = nil
                onInstall(localURL)
            } catch is CancellationError {
                // 取消发生在校验/转交阶段：包已下载并登记，保留不删。
                guard downloadGeneration == generation else { return }
                phase = .available
            } catch {
                UpdateIPADownloader.shared.discardCompletedDownload(at: localURL)
                guard downloadGeneration == generation else { return }
                phase = .failed(.verification)
            }
            if downloadGeneration == generation {
                downloadTask = nil
            }
        }
    }

    @MainActor
    private func cancelDownload() {
        downloadGeneration = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        phase = .available
    }

    private func displayVersion(_ value: String) -> String {
        value.hasPrefix("v") || value.hasPrefix("V") ? value : "v\(value)"
    }

    /// 下载阶段的失败归类：存储不足单独提示、SHA256 校验失败（SEAL-UPDATE-DL-506）
    /// 归校验失败、其余归下载失败。
    private static func downloadFailureKind(for error: Error) -> DownloadFailure {
        if let failure = error as? ImportFailure,
           failure.code == UpdateDownloadChecksumPolicy.failureCode {
            return .verification
        }
        return isStorageFull(error) ? .storage : .download
    }

    private static func isStorageFull(_ error: Error) -> Bool {
        if let downloadError = error as? UpdateDownloadError,
           case .insufficientStorage = downloadError { return true }
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28)
    }
}
