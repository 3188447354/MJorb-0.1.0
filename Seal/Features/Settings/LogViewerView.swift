import SwiftUI
import UIKit
import MessageUI
import UniformTypeIdentifiers

/// 续签完成通知：AppsViewModel 发出，AppContainer 监听并停止后台保活（省电）。
extension Notification.Name {
    static let sealRenewalCompleted = Notification.Name("sealRenewalCompleted")
    static let sealSelfRecordUpdated = Notification.Name("sealSelfRecordUpdated")
}

private struct LogFailureDetail: Identifiable {
    let id = UUID()
    let title: String
    let reason: String
}

/// 仅显示签名、续签和安装的最终结果；完整诊断仍保留在导出日志中。
struct LogViewerView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var entries: [SealLogEntry] = []
    @State private var exportDocument: LogExportDocument?
    @State private var mailAttachment: LogMailAttachment?
    @State private var showClearConfirm = false
    @State private var selectedFailure: LogFailureDetail?
    @State private var exportFailure: ImportFailure?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Text("页面只显示最新 20 条结果；完整日志最多保留 1000 条，超出后会移除最早记录。无法解决时，可点邮件按钮发送日志至 mjorb@foxmail.com。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)

                ForEach(entries) { entry in
                    LogEntryRow(entry: entry) { title, reason in
                        selectedFailure = LogFailureDetail(title: title, reason: reason)
                    }
                    .padding(.vertical, 10)
                    Divider()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(Color(.systemBackground))
        .refreshable { await loadEntries() }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    Button { showClearConfirm = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.red)
                            .frame(width: 36, height: 36)
                            .glassSurface(cornerRadius: 18)
                    }
                    Button(action: exportLogs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 36, height: 36)
                            .glassSurface(cornerRadius: 18)
                    }
                    Button(action: emailLogs) {
                        Image(systemName: "envelope")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 36, height: 36)
                            .glassSurface(cornerRadius: 18)
                    }
                    .accessibilityLabel("邮件发送日志")
                }
            }
        }
        .alert("清空日志？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { Task { await clearLogs() } }
        } message: {
            Text("将删除所有本地日志，此操作不可恢复。")
        }
        .alert(item: $exportFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text("\(failure.reason)\n\n\(failure.recovery)"),
                dismissButton: .default(Text("好的"))
            )
        }
        .sheet(item: $selectedFailure) { detail in
            LogFailureReasonSheet(detail: detail)
        }
        .task { await loadEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .sealRenewalCompleted)) { _ in
            Task { await loadEntries() }
        }
        .sheet(item: $exportDocument) { document in
            ShareSheet(activityItems: [document.url])
        }
        .sheet(item: $mailAttachment) { attachment in
            LogMailComposer(attachmentData: attachment.data) {
                mailAttachment = nil
            }
        }
    }

    private func loadEntries() async {
        entries = await viewModel.logEntriesForViewing()
    }

    private func exportLogs() {
        Task {
            do {
                let url = try await viewModel.materializeLogExport()
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
            } catch let failure as ImportFailure {
                exportFailure = failure
            } catch {
                exportFailure = ImportFailure(
                    title: "无法导出日志",
                    reason: error.localizedDescription,
                    recovery: "稍后重试",
                    code: "SEAL-LOG-002"
                )
            }
        }
    }

    private func emailLogs() {
        Task {
            do {
                let url = try await viewModel.materializeLogExport()
                guard let document = LogExportDocument(url: url) else {
                    exportFailure = ImportFailure(
                        title: "无法导出日志",
                        reason: "日志文件写入后未找到。",
                        recovery: "稍后重试",
                        code: "SEAL-LOG-002"
                    )
                    return
                }
                guard MFMailComposeViewController.canSendMail() else {
                    exportDocument = document
                    return
                }
                mailAttachment = LogMailAttachment(data: try Data(contentsOf: document.url))
            } catch {
                exportFailure = ImportFailure(
                    title: "无法准备日志邮件",
                    reason: error.localizedDescription,
                    recovery: "使用分享按钮导出日志",
                    code: "SEAL-LOG-002"
                )
            }
        }
    }

    private func clearLogs() async {
        await viewModel.clearLogs()
        await loadEntries()
    }
}

private struct LogEntryRow: View {
    let entry: SealLogEntry
    let onSelectFailure: (String, String) -> Void

    private var summary: RenewalRoundSummary? {
        LogViewerPolicy.operationSummary(for: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let summary {
                HStack(spacing: 8) {
                    Text(heading(summary))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .singleLine()
                    Spacer(minLength: 2)
                    Text(statusTitle(summary))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor(summary))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusColor(summary).opacity(0.12), in: Capsule())
                }

                ForEach(summary.items.indices, id: \.self) { index in
                    itemRow(summary.items[index])
                }

                Text(footer(summary))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .singleLine()
                    .padding(.top, 1)
            } else {
                fallbackRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemRow(_ item: RenewalRoundItem) -> some View {
        HStack(spacing: 7) {
            Text(marker(item.outcome))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(outcomeColor(item.outcome))
                .frame(width: 14, alignment: .leading)

            Text(item.appName)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            switch item.outcome {
            case .succeeded:
                Text(item.profileExpirationDate.map {
                    "有效期至 \(RenewalRoundSummary.formatExpirationDate($0))"
                } ?? "成功")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .singleLine()
            case .failed:
                Button("查看失败原因") {
                    let reason = item.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSelectFailure(
                        "\(item.appName) 失败原因",
                        reason?.isEmpty == false ? reason! : entry.message
                    )
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.sealAccent)
                .lineLimit(1)
                .fixedSize()
            case .needsAction:
                Button("查看原因") {
                    let reason = item.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSelectFailure(
                        "\(item.appName) 未执行原因",
                        reason?.isEmpty == false ? reason! : entry.message
                    )
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.sealAccent)
                .lineLimit(1)
                .fixedSize()
            case .awaitingConfirmation:
                Text("等待确认")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sealWarning)
                    .singleLine()
            }
        }
        .frame(height: 23)
    }

    private var fallbackRow: some View {
        HStack(spacing: 7) {
            Text(SealSettingsDateFormatter.string(from: entry.timestamp))
                .font(.system(size: 13, weight: .semibold))
                .singleLine()
            Text("· \(categoryTitle(entry.category))")
                .font(.system(size: 13, weight: .semibold))
                .singleLine()
            Spacer(minLength: 2)
            if LogViewerPolicy.operationResult(for: entry) == .failure {
                Text("×")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.sealDanger)
                Button("查看失败原因") {
                    onSelectFailure("失败原因", entry.message)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.sealAccent)
                .lineLimit(1)
                .fixedSize()
            } else {
                Text("✓ 成功")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sealSuccess)
                    .singleLine()
            }
        }
        .frame(height: 23)
    }

    private func heading(_ summary: RenewalRoundSummary) -> String {
        let date = SealSettingsDateFormatter.string(from: entry.timestamp)
        let title = summary.operation.displayTitle(triggerSource: summary.triggerSource)
        if summary.operation == .batchRenewal {
            return "\(date) · \(title) · \(summary.items.count)个App"
        }
        return "\(date) · \(title)"
    }

    private func categoryTitle(_ category: SealLogEntry.Category) -> String {
        switch category {
        case .signing: "签名"
        case .renewal: "续签"
        case .installation: "安装"
        case .account, .pairing, .system: "操作"
        }
    }

    private func statusTitle(_ summary: RenewalRoundSummary) -> String {
        if summary.awaitingCount > 0 { return "待确认" }
        if summary.failedCount > 0 {
            return summary.succeededCount > 0 ? "部分失败" : "失败"
        }
        if summary.needsActionCount > 0 {
            return summary.succeededCount > 0 ? "部分未执行" : "未执行"
        }
        return "成功"
    }

    private func statusColor(_ summary: RenewalRoundSummary) -> Color {
        if summary.failedCount > 0 { return .sealDanger }
        if summary.needsActionCount > 0 || summary.awaitingCount > 0 { return .sealWarning }
        return .sealSuccess
    }

    private func footer(_ summary: RenewalRoundSummary) -> String {
        let duration = RenewalRoundSummary.formatDuration(summary.totalDuration)
        if summary.operation == .singleSigning
            || summary.operation == .singleRenewal
            || summary.operation == .singleUpdate {
            let failed = summary.failedCount + summary.needsActionCount > 0
            return "共计 \(duration) · \(failed ? "失败" : "成功")"
        }
        if summary.failedCount + summary.needsActionCount == 0 {
            return "共计 \(duration) · \(summary.succeededCount)/\(summary.items.count) 成功"
        }
        return "完成 · 共计 \(duration) · \(summary.succeededCount) 成功 · \(summary.failedCount + summary.needsActionCount)失败"
    }

    private func marker(_ outcome: RenewalRoundItem.Outcome) -> String {
        switch outcome {
        case .succeeded: "✓"
        case .failed: "×"
        case .needsAction: "!"
        case .awaitingConfirmation: "·"
        }
    }

    private func outcomeColor(_ outcome: RenewalRoundItem.Outcome) -> Color {
        switch outcome {
        case .succeeded: .sealSuccess
        case .failed: .sealDanger
        case .needsAction: .sealWarning
        case .awaitingConfirmation: .sealWarning
        }
    }
}

private struct LogFailureReasonSheet: View {
    let detail: LogFailureDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(detail.reason)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(Color(.systemBackground))
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = detail.reason
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct LogMailAttachment: Identifiable {
    let id = UUID()
    let data: Data
}

private struct LogMailComposer: UIViewControllerRepresentable {
    let attachmentData: Data
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients(["mjorb@foxmail.com"])
        composer.setSubject("Seal 诊断日志")
        composer.setMessageBody("附件是 Seal 诊断日志。", isHTML: false)
        composer.addAttachmentData(attachmentData, mimeType: "text/plain", fileName: "Seal-log.txt")
        return composer
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true, completion: onFinish)
        }
    }
}

private extension View {
    func singleLine() -> some View {
        lineLimit(1).minimumScaleFactor(0.72)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
