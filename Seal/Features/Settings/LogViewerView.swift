import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 续签完成通知：AppsViewModel 发出，AppContainer 监听并停止后台保活（省电）
extension Notification.Name {
    static let sealRenewalCompleted = Notification.Name("sealRenewalCompleted")
    /// Seal 自身记录更新完成（自安装重启后的结算）：应用页收到后刷新列表，
    /// "有新版本待安装"标签自动消失，不用手动切页面。
    static let sealSelfRecordUpdated = Notification.Name("sealSelfRecordUpdated")
}

/// 日志查看页：只显示人话卡片，不显示原始日志。
/// 导出按钮在右上角（毛玻璃圆按钮，无文字）。
struct LogViewerView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var entries: [SealLogEntry] = []
    @State private var exportDocument: LogExportDocument?
    @State private var showClearConfirm = false
    @State private var selectedError: SealLogEntry?
    @State private var exportFailure: ImportFailure?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                diagnosticGuide

                Text("显示最近 \(entries.count) / \(LogViewerPolicy.maximumVisibleEntries) 条签名、续签和安装结果，最新记录在顶部。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if entries.isEmpty {
                    Text("暂无签名、续签或安装结果")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(entries) { entry in
                        LogEntryCard(entry: entry) {
                            selectedError = entry
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await loadEntries()
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    Button(action: { showClearConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.red)
                            .frame(width: 36, height: 36)
                            .glassButton()
                    }
                    Button(action: exportLogs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 36, height: 36)
                            .glassButton()
                    }
                }
            }
        }
        .alert("清空日志？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await clearLogs() }
            }
        } message: {
            Text("将删除所有本地日志，此操作不可恢复。")
        }
        .alert("解决办法", isPresented: Binding(
            get: { selectedError != nil },
            set: { if !$0 { selectedError = nil } }
        )) {
            Button("复制错误信息") {
                if let err = selectedError {
                    UIPasteboard.general.string = errorDetails(for: err)
                }
            }
        } message: {
            if let err = selectedError {
                Text(errorDetails(for: err))
            }
        }
        .alert(item: $exportFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text("\(failure.reason)\n\n\(failure.recovery)"),
                dismissButton: .default(Text("好的"))
            )
        }
        .task {
            await loadEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sealRenewalCompleted)) { _ in
            Task { await loadEntries() }
        }
        .sheet(item: $exportDocument) { document in
            ShareSheet(activityItems: [document.url])
        }
    }

    private var diagnosticGuide: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("开发者排障", systemImage: "stethoscope")
                .font(.system(size: 15, weight: .semibold))
            Text("这里只显示签名、续签和安装的成功或失败结果，不显示过程日志。")
            Text("页面保留最新 20 条，列表可上下滑动查看；点击失败记录可复制内容。")
            Text("导出 Seal-log.txt 可查看完整诊断日志，并把错误码、操作名称和大致时间一并发给开发者。")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func loadEntries() async {
        let loaded = await viewModel.logEntriesForViewing()
        await MainActor.run {
            entries = loaded
        }
    }

    private func exportLogs() {
        Task {
            do {
                let url = try await viewModel.materializeLogExport()
                await MainActor.run {
                    guard let document = LogExportDocument(url: url) else {
                        exportFailure = ImportFailure(
                            title: "无法导出日志",
                            reason: "日志文件写入后未找到。",
                            recovery: "稍后重试",
                            code: "SEAL-LOG-002"
                        )
                        return
                    }
                    exportDocument = document
                }
            } catch let failure as ImportFailure {
                await MainActor.run { exportFailure = failure }
            } catch {
                await MainActor.run {
                    exportFailure = ImportFailure(
                        title: "无法导出日志",
                        reason: error.localizedDescription,
                        recovery: "稍后重试",
                        code: "SEAL-LOG-002"
                    )
                }
            }
        }
    }

    private func clearLogs() async {
        await viewModel.clearLogs()
        await loadEntries()
    }

    private func errorDetails(for entry: SealLogEntry) -> String {
        var details = entry.message
        if let summary = LogViewerPolicy.operationSummary(for: entry) {
            let technicalSummary = summary.technicalSummary()
            if technicalSummary.isEmpty == false {
                details += "\n\n诊断码：\n\(technicalSummary)"
            }
        } else if let code = entry.code {
            details = "错误码：\(code)\n" + details
        }
        return details
    }
}

private struct LogEntryCard: View {
    let entry: SealLogEntry
    let onSelectError: () -> Void

    private var summary: RenewalRoundSummary? {
        LogViewerPolicy.operationSummary(for: entry)
    }

    var body: some View {
        Group {
            if LogViewerPolicy.operationResult(for: entry) == .failure {
                Button(action: onSelectError) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary {
                operationSummaryCard(summary)
            } else {
                HStack(spacing: 8) {
                    Text(SealSettingsDateFormatter.string(from: entry.timestamp))
                    Spacer(minLength: 4)
                    resultBadge(LogViewerPolicy.operationResult(for: entry)?.displayName ?? entry.level.displayName)
                }
                .font(.caption.weight(.semibold))

                Text(cleanMessage)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func operationSummaryCard(_ summary: RenewalRoundSummary) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(operationHeading(summary))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                resultBadge(operationResult(for: summary).displayName)
            }

            ForEach(summary.items.indices, id: \.self) { index in
                if index > 0 { Divider() }
                operationItem(summary.items[index])
            }

            Divider()
            Text(operationFooter(summary))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func operationItem(_ item: RenewalRoundItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(for: item.outcome))
                .font(.body.weight(.semibold))
                .foregroundStyle(color(for: item.outcome))
                .frame(width: 18)
            Text(item.appName)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(itemResultText(item))
                .font(.body)
                .foregroundStyle(color(for: item.outcome))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func operationHeading(_ summary: RenewalRoundSummary) -> String {
        let date = SealSettingsDateFormatter.string(from: entry.timestamp)
        let title = summary.operation.displayTitle(triggerSource: summary.triggerSource)
        guard summary.operation.showsAppCount else { return "\(date) · \(title)" }
        return "\(date) · \(title) · \(summary.items.count)个App"
    }

    private func operationFooter(_ summary: RenewalRoundSummary) -> String {
        let duration = RenewalRoundSummary.formatDuration(summary.totalDuration)
        if summary.operation == .singleSigning {
            return "\(summary.failedCount == 0 ? "完成" : "失败") · 共计 \(duration)"
        }

        var parts = ["\(summary.succeededCount)/\(summary.items.count) 成功"]
        if summary.failedCount > 0 { parts.append("\(summary.failedCount)失败") }
        if summary.needsActionCount > 0 { parts.append("\(summary.needsActionCount)未执行") }
        if summary.awaitingCount > 0 { parts.append("\(summary.awaitingCount)待确认") }
        return "完成 · 共计 \(duration) · " + parts.joined(separator: " · ")
    }

    private func itemResultText(_ item: RenewalRoundItem) -> String {
        switch item.outcome {
        case .succeeded:
            if let expiry = item.profileExpirationDate {
                return "成功，有效期至 \(RenewalRoundSummary.formatExpirationDate(expiry))"
            }
            return "成功"
        case .failed: return "失败"
        case .needsAction: return "未执行"
        case .awaitingConfirmation: return "待确认"
        }
    }

    private func operationResult(for summary: RenewalRoundSummary) -> SealLogEntry.OperationResult {
        if summary.awaitingCount > 0 { return .notFinal }
        return summary.failedCount + summary.needsActionCount > 0 ? .failure : .success
    }

    private func resultBadge(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(levelColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(levelColor.opacity(0.12), in: Capsule())
    }

    private var cleanMessage: String {
        entry.message
            .components(separatedBy: .newlines)
            .filter { line in
                !line.contains("━━━━━━━━") && !line.contains("────────────────")
            }
            .joined(separator: "\n")
    }

    private func symbol(for outcome: RenewalRoundItem.Outcome) -> String {
        switch outcome {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .needsAction: "exclamationmark.circle.fill"
        case .awaitingConfirmation: "clock.fill"
        }
    }

    private func color(for outcome: RenewalRoundItem.Outcome) -> Color {
        switch outcome {
        case .succeeded: .sealSuccess
        case .failed: .sealDanger
        case .needsAction, .awaitingConfirmation: .sealWarning
        }
    }

    private var levelColor: Color {
        switch LogViewerPolicy.operationResult(for: entry) {
        case .success: return .green
        case .failure: return .sealDanger
        case .notFinal, nil: break
        }
        return switch entry.level {
        case .info: .secondary
        case .warning: .sealWarning
        case .error: .sealDanger
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// iOS 26 原生毛玻璃按钮：直接作用在内容上，不套多余层级，低版本自动降级
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

extension View {
    func glassButton() -> some View {
        modifier(GlassButtonModifier())
    }
}
