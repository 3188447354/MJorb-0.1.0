import SwiftUI
import UIKit

/// 支持入口只承载用户主动支持；社群交流统一归「加入社群」。
struct SupportSealView: View {
    @Environment(\.openURL) private var openURL

    @State private var isRewardPresented = false
    @State private var saveCoordinator: AlbumSaveCoordinator?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isAlertPresented = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                header
                actionsCard
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
            // 「感谢你的喜欢」是**内容标题**（页面顶部另有导航标题「支持 Seal」）。
            // 按 2026-10-16 的文案要求：不再重复一个同名的内容标题。
            Text("感谢你的喜欢")
                .font(.title2.weight(.semibold))
            Text("你的鼓励让 Seal 走的更远")
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
                    title: "赞赏开发者",
                    detail: "一份心意，助力项目维护与更新",
                    icon: "heart.fill",
                    iconColor: .pink
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

            HStack(spacing: 12) {
                Button("支付宝支付") { openAlipay() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(alipayBlue)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(alipayBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button("打开微信") { openWechat() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(wechatGreen)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(wechatGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            Button("保存到相册") { saveRewardCode() }
                .sealPrimaryAction(cornerRadius: 14)
                .padding(.horizontal, 24)

            Button("关闭") { isRewardPresented = false }
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.bottom, 14)
        }
    }


    private func openAlipay() {
        guard let url = URL(string: "https://qr.alipay.com/fkx11863lft7h3izxgreqbe") else { return }
        openURL(url)
    }

    private func openWechat() {
        guard let url = URL(string: "weixin://") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened {
                Task { @MainActor in
                    presentAlert("无法打开微信", "请先安装微信，或在微信内点右上角「+」→「扫一扫」手动赞赏")
                }
            }
        }
    }

    private var alipayBlue: Color { Color(red: 22 / 255.0, green: 119 / 255.0, blue: 1.0) }
    private var wechatGreen: Color { Color(red: 7 / 255.0, green: 193 / 255.0, blue: 96 / 255.0) }
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

