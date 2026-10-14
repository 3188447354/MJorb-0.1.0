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

    private enum DownloadPhase: Equatable {
        case available
        case downloading(Int64, Int64?)
        case verifying
        case ready
        case failed(String)
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
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
        return items.isEmpty ? ["修复已知问题"] : items
    }

    private var usesExpandedLayout: Bool {
        changeItems.count > 3 || changeItems.contains { $0.count > 26 }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .transition(.opacity)

            sheetContent
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: phase)
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            if usesExpandedLayout, case .available = phase {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
            }

            switch phase {
            case .available:
                availableContent
            case .downloading(let received, let total):
                downloadingContent(received: received, total: total)
            case .verifying:
                progressContent(title: "正在验证更新包", detail: "检查版本与文件完整性")
            case .ready:
                readyContent
            case .failed(let reason):
                failureContent(reason)
            }
        }
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.52), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: -3)
        .accessibilityElement(children: .contain)
    }

    private var availableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 7) {
                Text("发现新版本")
                    .font(.title3.weight(.bold))
                Text(notice.version)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.sealAccent)
                Text("当前版本 \(currentVersion)")
                    .font(.footnote)
                    .foregroundStyle(Color.sealTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, usesExpandedLayout ? 18 : 26)

            Text("本次更新")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.top, 22)
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

            primaryButton("下载并更新", action: startDownload)
                .padding(.top, 22)
            secondaryButton("暂不更新", action: onDismiss)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 22)
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
        return VStack(spacing: 0) {
            Text("正在下载更新包")
                .font(.title3.weight(.bold))
                .padding(.top, 30)
            Text(downloadDetail(received: received, total: total))
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.top, 8)
            Group {
                if let progress {
                    ProgressView(value: progress)
                        .tint(Color.sealAccent)
                } else {
                    ProgressView()
                        .tint(Color.sealAccent)
                }
            }
            .padding(.top, 22)
            secondaryButton("取消下载", action: cancelDownload)
                .padding(.top, 19)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 22)
    }

    private func progressContent(title: String, detail: String) -> some View {
        VStack(spacing: 0) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.sealAccent)
                .padding(.top, 31)
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.top, 18)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.top, 8)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .padding(.top, 29)
            Text("更新包已准备好")
                .font(.title3.weight(.bold))
                .padding(.top, 18)
            Text("正在打开签名与安装")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.top, 8)
                .padding(.bottom, 29)
        }
        .frame(maxWidth: .infinity)
    }

    private func failureContent(_ reason: String) -> some View {
        let verificationFailure = reason.contains("安全校验") || reason.contains("文件与版本")
        return VStack(spacing: 0) {
            Image(systemName: verificationFailure ? "exclamationmark.shield" : "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.sealAccent)
                .padding(.top, 28)
            Text(verificationFailure ? "安全校验未通过" : "下载失败")
                .font(.title3.weight(.bold))
                .padding(.top, 15)
            Text(verificationFailure ? "已停止安装以保护你的设备" : "网络连接中断 请检查网络后重新下载")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            primaryButton("重新下载", action: startDownload)
                .padding(.top, 22)
            secondaryButton("暂不更新", action: onDismiss)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 22)
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
                phase = .failed("下载失败，请检查网络后重试")
                downloadTask = nil
                return
            }

            phase = .verifying
            do {
                let parsed = try IPAParserService().parse(url: localURL)
                guard UpdateChecker.advertisedVersion(notice.version, matchesIPAVersion: parsed.version),
                      let checksumURL = notice.sha256DownloadURL else {
                    try? FileManager.default.removeItem(at: localURL)
                    phase = .failed("下载的文件缺少安全校验信息，已中止安装")
                    downloadTask = nil
                    return
                }
                let actual = try AppFileStore.streamingSHA256(url: localURL)
                let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
                guard let checksumText = String(data: checksumData, encoding: .utf8),
                      let expected = UpdateChecker.expectedSHA256(from: checksumText),
                      UpdateChecker.hashMatches(expected: expected, actual: actual) else {
                    try? FileManager.default.removeItem(at: localURL)
                    phase = .failed("下载的文件安全校验未通过，已中止安装")
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
                phase = .failed("下载的文件安全校验未通过，已中止安装")
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
}
