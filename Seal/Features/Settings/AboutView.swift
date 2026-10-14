import SwiftUI
import UIKit

struct AboutView: View {
    private enum UpdateStatus: Equatable {
        case checking
        case latest
        case available(String)
    }

    private var version: String {
        let short = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// 应用内更新安装回调（下载完成后触发）；为 nil 时回退跳转浏览器。
    private let onInstall: ((URL) -> Void)?

    @State private var isCheckingUpdate = false
    @State private var updateStatus: UpdateStatus = .checking
    @State private var availableUpdate: UpdateNotice?
    @State private var presentedUpdate: UpdateNotice?

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
            }
            .padding(20)
        }
        .navigationTitle("关于 Seal")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .task { await refreshUpdateStatus(presentUpdate: false) }
        .overlay {
            if let notice = presentedUpdate {
                UpdateNoticeView(
                    notice: notice,
                    onDismiss: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            presentedUpdate = nil
                        }
                    },
                    onInstall: installCallback
                )
            }
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
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
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
                .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
                }
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
        }
    }

    private func checkUpdate() {
        if let availableUpdate {
            presentedUpdate = availableUpdate
            return
        }
        Task { await refreshUpdateStatus(presentUpdate: true) }
    }

    private func refreshUpdateStatus(presentUpdate: Bool) async {
        guard isCheckingUpdate == false else { return }
        isCheckingUpdate = true
        updateStatus = .checking
        let notice = await UpdateChecker.shared.check(force: true)
        availableUpdate = notice
        updateStatus = notice.map { .available($0.version) } ?? .latest
        isCheckingUpdate = false
        if presentUpdate, let notice {
            presentedUpdate = notice
        }
    }

    /// 下载完成后先收起弹窗，再交给上层执行导入安装。
    private var installCallback: ((URL) -> Void)? {
        guard let onInstall else { return nil }
        return { localURL in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                presentedUpdate = nil
            }
            onInstall(localURL)
        }
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

