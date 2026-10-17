import SwiftUI

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

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    /// Release 的 Markdown 正文转换为抽屉中的简洁更新条目。
    private var changeItems: [String] {
        var items: [String] = []
        for line in notice.message.components(separatedBy: .newlines) {
            var text = line
            text = text.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*[-*•·]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { items.append(trimmed) }
        }
        return items
    }

    private var usesExpandedLayout: Bool {
        changeItems.count > 3 || changeItems.contains { $0.count > 26 }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .transition(.opacity)

                sheetContent
                    .frame(maxWidth: 560)
                    .frame(height: min(proxy.size.height * 0.9, 700))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: phase)
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            SealSheetGrabber()
                .padding(.top, 10)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 16).onEnded { value in
                    guard isDismissible, value.translation.height > 80 else { return }
                    onDismiss()
                })

            ScrollView(showsIndicators: false) {
                phaseContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.sealHairline.opacity(0.65))

            footer
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.52), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: -3)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .available:
            availableContent
        case .downloading(let received, let total):
            downloadingContent(received: received, total: total)
        case .verifying:
            progressContent(title: "正在验证更新包", detail: "核对版本与文件完整性")
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
            VStack(alignment: .leading, spacing: 7) {
                Text("发现新版本")
                    .font(.title3.weight(.bold))
                HStack(spacing: 4) {
                    Text("当前 \(displayVersion(currentVersion))  →")
                        .foregroundStyle(Color.sealTextSecondary)
                    Text("新版 \(displayVersion(notice.version))")
                        .foregroundStyle(Color.sealAccent)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if changeItems.isEmpty == false {
                Text("更新内容")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                Group {
                    if usesExpandedLayout {
                        ScrollView(showsIndicators: false) {
                            changesList
                        }
                        .frame(maxHeight: 190)
                    } else {
                        changesList
                    }
                }
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
        let progress = total.map { $0 > 0 ? min(Double(received) / Double($0), 1) : nil } ?? nil
        return VStack(alignment: .leading, spacing: 0) {
            Text("正在下载更新包")
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(downloadDetail(received: received, total: total))
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.top, 8)
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .tint(Color.sealAccent)
            .padding(.top, 22)
        }
        .padding(.top, 12)
    }

    private func progressContent(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.sealAccent)
                .frame(maxWidth: .infinity)
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.top, 14)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            Text("更新包验证通过")
                .font(.title3.weight(.bold))
            Text("正在打开更新确认")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
    }

    private func failureContent(_ failure: DownloadFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure == .verification ? "更新包校验失败" : failure == .storage ? "存储空间不足" : "下载未完成")
                .font(.title3.weight(.bold))
            Text(failure == .verification
                 ? "此更新包未通过校验，Seal 已停止使用它。\n当前 Seal 未更改"
                 : failure == .storage
                    ? "释放设备空间后，再下载更新包"
                    : "更新包未下载完整，当前 Seal 未更改")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private func downloadDetail(received: Int64, total: Int64?) -> String {
        guard received > 0 else { return "正在连接更新服务" }
        let receivedText = received.formatted(.byteCount(style: .file))
        guard let total, total > 0 else { return "已下载 \(receivedText)" }
        return "已下载 \(receivedText) / \(total.formatted(.byteCount(style: .file)))"
    }

    @MainActor
    private func startDownload() {
        if case .downloading = phase { return }
        guard let ipaURL = notice.ipaDownloadURL, let onInstall else {
            if let url = notice.downloadURL { openURL(url) }
            return
        }

        phase = .downloading(0, nil)
        downloadTask = Task {
            let localURL: URL
            do {
                localURL = try await UpdateIPADownloader.shared.download(
                        from: ipaURL,
                        onProgress: { @MainActor received, total in
                            phase = .downloading(received, total)
                        }
                    )
            } catch is CancellationError {
                phase = .available
                downloadTask = nil
                return
            } catch {
                phase = .failed(Self.isStorageFull(error) ? .storage : .download)
                downloadTask = nil
                return
            }

            phase = .verifying
            do {
                let parsed = try IPAParserService().parse(url: localURL)
                guard UpdateChecker.advertisedVersion(notice.version, matchesIPAVersion: parsed.version),
                      let checksumURL = notice.sha256DownloadURL else {
                    try? FileManager.default.removeItem(at: localURL)
                    phase = .failed(.verification)
                    downloadTask = nil
                    return
                }
                let actual = try AppFileStore.streamingSHA256(url: localURL)
                let checksumData: Data
                do {
                    let (data, response) = try await URLSession.shared.data(from: checksumURL)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        try? FileManager.default.removeItem(at: localURL)
                        phase = .failed(.download)
                        downloadTask = nil
                        return
                    }
                    checksumData = data
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: localURL)
                    phase = .failed(.download)
                    downloadTask = nil
                    return
                }
                guard let checksumText = String(data: checksumData, encoding: .utf8),
                      let expected = UpdateChecker.expectedSHA256(from: checksumText),
                      UpdateChecker.hashMatches(expected: expected, actual: actual) else {
                    try? FileManager.default.removeItem(at: localURL)
                    phase = .failed(.verification)
                    downloadTask = nil
                    return
                }

                phase = .ready
                try await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                onInstall(localURL)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: localURL)
                phase = .available
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                phase = .failed(.verification)
            }
            downloadTask = nil
        }
    }

    @MainActor
    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = .available
    }

    private func displayVersion(_ value: String) -> String {
        value.hasPrefix("v") || value.hasPrefix("V") ? value : "v\(value)"
    }

    private static func isStorageFull(_ error: Error) -> Bool {
        if let downloadError = error as? UpdateDownloadError,
           case .insufficientStorage = downloadError { return true }
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28)
    }
}
