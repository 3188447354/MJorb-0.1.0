import SwiftUI
import UIKit

struct AboutView: View {
    @ObservedObject var updateCoordinator: UpdatePresentationCoordinator
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    /// 检查更新失败的内嵌文案（失败不再弹窗，行内给重试）。
    @State private var updateFailureDetail: String?

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
                    if updateCoordinator.isChecking {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text(updateStatusText)
                            .foregroundStyle(Color.sealTextSecondary)
                            .singleLine()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .frame(minHeight: 54)
            }
            .buttonStyle(.plain)
            .disabled(updateCoordinator.isChecking)
            // 检查更新失败：行内失败行＋重试按钮，不再弹窗；
            // 「已是最新版本」本就由上方状态行显示，也不再弹窗。
            if let updateFailureDetail {
                Divider()
                HStack(spacing: 12) {
                    Text(updateFailureDetail)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.sealDanger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("重试", action: checkUpdate)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.sealAccent)
                }
                .frame(minHeight: 44)
            }
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
        switch updateCoordinator.status {
        case .unchecked: return "点击检查更新"
        case .checking: return "正在检查"
        case .latest: return "已是最新版本"
        case .available(let version): return "\(version) 可更新"
        case .unavailable(let failure): return failure.statusText
        }
    }

    private func checkUpdate() {
        updateFailureDetail = nil
        Task {
            guard let result = await updateCoordinator.checkManually() else { return }
            switch result {
            case .unavailable(let failure):
                updateFailureDetail = failure.detail
            case .latest, .available:
                break
            }
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


