import SwiftUI
import UIKit

struct AboutView: View {
    private enum UpdateStatus: Equatable {
        case checking
        case latest
        case available(String)
        case unavailable(UpdateCheckFailure)
    }

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    /// 应用内更新安装回调（下载完成后触发）；为 nil 时回退跳转浏览器。
    private let onInstall: ((URL) -> Void)?

    @State private var isCheckingUpdate = false
    @State private var updateStatus: UpdateStatus = .latest
    @State private var presentedUpdate: UpdateNotice?
    @State private var pendingUpdateInstallURL: URL?
    @State private var updateFailure: UpdateCheckFailure?

    init(onInstall: ((URL) -> Void)? = nil) {
        self.onInstall = onInstall
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                identity
                updateSection
                compatibilitySection
                legalSection
                Text("由 MJorb 打造")
                    .font(.footnote)
                    .foregroundStyle(Color.sealTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(20)
        }
        .navigationTitle("关于 Seal")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .sheet(
            item: $presentedUpdate,
            onDismiss: installPendingUpdateIfNeeded,
            content: { notice in
                UpdateNoticeView(
                    notice: notice,
                    onDismiss: {
                        presentedUpdate = nil
                    },
                    onInstall: installCallback
                )
                .presentationDetents([.large])
            }
        )
        .alert(updateFailure?.statusText ?? "暂时无法检查更新", isPresented: Binding(
            get: { updateFailure != nil },
            set: { if !$0 { updateFailure = nil } }
        )) {
            Button("重试") { checkUpdate() }
            Button("关闭", role: .cancel) {}
        } message: {
            Text(updateFailure?.detail ?? "请检查网络后重试")
        }
    }

    private var identity: some View {
        VStack(spacing: 10) {
            appIcon
            Text("Seal")
                .font(.title.weight(.semibold))
            Text("个人 IPA 自签与续签工具")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
            Text("版本 \(version)")
                .font(.footnote)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .sealContentCard(.prominent)
    }

    private var updateSection: some View {
        aboutSection("更新") {
            Button(action: checkUpdate) {
                HStack(spacing: 16) {
                    Text("检查更新")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    if isCheckingUpdate {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text(updateStatusText)
                            .foregroundStyle(Color.sealTextSecondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .frame(minHeight: 54)
            }
            .buttonStyle(.plain)
            .disabled(isCheckingUpdate)
        }
    }

    private var legalSection: some View {
        aboutSection("开源与法律") {
            NavigationLink { OpenSourceLicensesView() } label: {
                navigationRow("组件与许可")
            }
            .buttonStyle(.plain)
            Divider()
            NavigationLink { PrivacyNoticeView() } label: {
                navigationRow("隐私政策")
            }
            .buttonStyle(.plain)
            Divider()
            NavigationLink { UserAgreementView() } label: {
                navigationRow("用户协议")
            }
            .buttonStyle(.plain)
        }
    }

    private var compatibilitySection: some View {
        aboutSection("兼容性") {
            infoRow("最低支持", "iOS 17.4")
        }
    }

    @ViewBuilder
    private func aboutSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.leading, 8)
            VStack(spacing: 0, content: content)
                .padding(.horizontal, 16)
                .sealContentCard(.standard)
        }
    }

    private func navigationRow(_ title: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 16, weight: .medium))
        .frame(minHeight: 54)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .font(.system(size: 16, weight: .medium))
        .frame(minHeight: 54)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = Self.currentAppIcon() {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 72, height: 72)
                .background(Color.sealSurfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var updateStatusText: String {
        switch updateStatus {
        case .checking: return "正在检查"
        case .latest: return "已是最新版本"
        case .available(let version): return "\(version) 可更新"
        case .unavailable(let failure): return failure.statusText
        }
    }

    private func checkUpdate() {
        Task { await refreshUpdateStatus(presentUpdate: true) }
    }

    private func refreshUpdateStatus(presentUpdate: Bool) async {
        guard isCheckingUpdate == false else { return }
        isCheckingUpdate = true
        updateStatus = .checking
        let result = await UpdateChecker.shared.check(force: presentUpdate)
        let notice: UpdateNotice?
        switch result {
        case .unavailable(let failure):
            notice = nil
            updateStatus = .unavailable(failure)
        case .latest, .suppressed:
            notice = nil
            updateStatus = .latest
        case .available(let update):
            notice = update
            updateStatus = .available(update.version)
        }
        isCheckingUpdate = false
        if presentUpdate, let notice {
            presentedUpdate = notice
        } else if presentUpdate, case .unavailable(let failure) = result {
            updateFailure = failure
        }
    }

    private var installCallback: ((URL) -> Void)? {
        guard onInstall != nil else { return nil }
        return { localURL in
            pendingUpdateInstallURL = localURL
            presentedUpdate = nil
        }
    }

    private func installPendingUpdateIfNeeded() {
        guard let localURL = pendingUpdateInstallURL else { return }
        pendingUpdateInstallURL = nil
        onInstall?(localURL)
    }

    private static func currentAppIcon() -> UIImage? {
        guard
            let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
            let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primaryIcon["CFBundleIconFiles"] as? [String],
            let iconName = files.last
        else { return nil }
        return UIImage(named: iconName)
    }
}

