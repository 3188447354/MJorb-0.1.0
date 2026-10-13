import SwiftUI
import UIKit

/// 支持入口只承载用户主动支持、反馈和分享；社群动态仍归「加入社群」。
struct SupportSealView: View {
    @Environment(\.openURL) private var openURL

    @State private var isRewardPresented = false
    @State private var saveCoordinator: AlbumSaveCoordinator?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isAlertPresented = false

    private let qqGroupNumber = "1051135067"
    private let qqJoinURL = URL(string: "https://qm.qq.com/q/8HfHpTmOzu")
    private let websiteURL = URL(string: "https://ios.sealsign.eu.cc")!

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                header
                actionsCard
                Text("你的支持和反馈会帮助 Seal 持续改进。")
                    .font(.footnote)
                    .foregroundStyle(Color.sealTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .navigationTitle("支持 Seal")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .sheet(isPresented: $isRewardPresented) {
            rewardSheet
                .presentationDetents([.medium])
        }
        .alert(alertTitle, isPresented: $isAlertPresented) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 72, height: 72)
                .background(Color.sealAccent.opacity(0.12), in: Circle())
            Text("支持 Seal")
                .font(.title2.weight(.semibold))
            Text("让自签与续签工具持续稳定地更新")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button { isRewardPresented = true } label: {
                supportRow(
                    title: "赞赏支持",
                    detail: "每一份支持，都是持续更新的动力",
                    icon: "heart.fill",
                    iconColor: .pink
                )
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 50)

            Button(action: joinQQGroup) {
                supportRow(
                    title: "提交反馈",
                    detail: "加入 QQ 群，反馈问题或提出建议",
                    icon: "bubble.left.and.bubble.right.fill",
                    iconColor: Color.sealAccent
                )
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 50)

            ShareLink(item: websiteURL) {
                supportRow(
                    title: "分享 Seal",
                    detail: "将 Seal 分享给需要的人",
                    icon: "square.and.arrow.up",
                    iconColor: .orange,
                    trailingIcon: "square.and.arrow.up"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    private func supportRow(
        title: String,
        detail: String,
        icon: String,
        iconColor: Color,
        trailingIcon: String = "chevron.right"
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.sealTextSecondary)
            }
            Spacer(minLength: 12)
            Image(systemName: trailingIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 66)
        .contentShape(Rectangle())
    }

    private var rewardSheet: some View {
        VStack(spacing: 16) {
            Text("赞赏支持")
                .font(.title3.weight(.semibold))
                .padding(.top, 22)

            Group {
                if let image = UIImage(named: "SealCommunityReward") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text("赞赏码未加载")
                        .font(.footnote)
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
            .frame(width: 184, height: 184)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.6), lineWidth: 0.8)
            }

            Text("保存图片后，可在微信扫一扫中选择该图片。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button("保存到相册") { saveRewardCode() }
                .sealPrimaryAction(cornerRadius: 14)
                .padding(.horizontal, 24)

            Button("关闭") { isRewardPresented = false }
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.bottom, 14)
        }
    }

    private func joinQQGroup() {
        guard let scheme = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=\(qqGroupNumber)&card_type=group&source=external") else { return }
        UIApplication.shared.open(scheme) { opened in
            if opened == false, let fallbackURL = qqJoinURL {
                openURL(fallbackURL)
            }
        }
    }

    private func saveRewardCode() {
        guard let image = UIImage(named: "SealCommunityReward") else {
            presentAlert("保存失败", "赞赏码未加载，请稍后重试。")
            return
        }
        let coordinator = AlbumSaveCoordinator { error in
            Task { @MainActor in
                presentAlert(
                    error == nil ? "已保存到相册" : "保存失败",
                    error == nil ? "感谢你的支持。" : "请在系统设置中允许 Seal 访问相册后重试。"
                )
            }
        }
        saveCoordinator = coordinator
        UIImageWriteToSavedPhotosAlbum(
            image,
            coordinator,
            #selector(AlbumSaveCoordinator.image(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }

    private func presentAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        isAlertPresented = true
    }
}
