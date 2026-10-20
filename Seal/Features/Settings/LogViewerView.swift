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
                    let info = (err.code.map { "错误码：\($0)\n" } ?? "") + err.message
                    UIPasteboard.general.string = info
                }
            }
        } message: {
            if let err = selectedError {
                Text(err.message)
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
}

private struct LogEntryCard: View {
    let entry: SealLogEntry
    let onSelectError: () -> Void

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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(SealSettingsDateFormatter.string(from: entry.timestamp))
                Spacer(minLength: 4)
                Text(LogViewerPolicy.operationResult(for: entry)?.displayName ?? entry.level.displayName)
                Text(entry.category.displayName)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(levelColor)

            if let code = entry.code {
                Text(code)
                    .font(.caption.monospaced())
                    .foregroundStyle(levelColor)
                    .textSelection(.enabled)
            }

            Text(entry.message)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var levelColor: Color {
        switch LogViewerPolicy.operationResult(for: entry) {
        case .success: return .green
        case .failure: return .sealDanger
        case nil: break
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
