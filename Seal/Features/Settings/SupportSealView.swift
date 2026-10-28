import SwiftUI
import UIKit

/// 支持入口只承载用户主动支持；社群交流统一归「加入社群」。
struct SupportSealView: View {
    @Environment(\.openURL) private var openURL

    @State private var isRewardPresented = false
    @State private var rewardSheetDetent: PresentationDetent = .fraction(0.62)
    @State private var saveCoordinator: AlbumSaveCoordinator?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isAlertPresented = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                welcomeIntro
                impactSection
                supportSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 32)
        }
        .navigationTitle("支持 Seal")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .sheet(isPresented: $isRewardPresented) {
            rewardSheet
        }
        .alert(alertTitle, isPresented: $isAlertPresented) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var welcomeIntro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("让 Seal 持续前进")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .singleLine()
            Text("你的支持帮助 Seal 持续维护与改进。")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private var impactSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("支持能带来什么")

            VStack(spacing: 0) {
                impactRow(
                    title: "持续维护",
                    detail: "修复问题，稳步完善功能"
                )
                impactDivider
                impactRow(
                    title: "系统适配",
                    detail: "跟进 iOS 与签名环境变化"
                )
                impactDivider
                impactRow(
                    title: "体验打磨",
                    detail: "让日常操作更清晰顺手"
                )
            }
            .padding(.horizontal, 18)
            .sealContentCard(.standard)
        }
    }

    private var impactDivider: some View {
        Divider()
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("选择支持方式")

            Button {
                presentRewardSheet()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.pink.opacity(0.10))
                            .frame(width: 46, height: 46)
                        Image(systemName: "heart.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.pink)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("赞赏开发者")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .singleLine()
                        Text("微信赞赏码 · 支付宝支付")
                            .font(.footnote)
                            .foregroundStyle(Color.sealTextSecondary)
                            .singleLine()
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                .contentShape(Rectangle())
                .sealContentCard(.standard)
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开微信和支付宝支持方式")

            voluntaryNote
        }
    }

    private var voluntaryNote: some View {
        Text("完全自愿，不影响任何功能使用。")
            .font(.footnote)
            .foregroundStyle(Color.sealTextSecondary)
            .singleLine()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 2)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.sealTextSecondary)
            .singleLine()
    }

    private func impactRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .singleLine()
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    }

    private var rewardSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Text("感谢你的支持")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .singleLine()
                    Text("微信扫码，或选择下方支付方式。")
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                }
                .padding(.top, 20)

                rewardCode

                Text("保存二维码后，可在微信内扫一扫。")
                    .font(.footnote)
                    .foregroundStyle(Color.sealTextSecondary)
                    .multilineTextAlignment(.center)
                    .singleLine()
                    .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    Button("支付宝支付") { openAlipay() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(alipayBlue)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(alipayBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                    Button("打开微信") { openWechat() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(wechatGreen)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(wechatGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                Button {
                    saveRewardCode()
                } label: {
                    Label("保存赞赏码", systemImage: "square.and.arrow.down")
                        .singleLine()
                }
                .sealPrimaryAction(cornerRadius: 14)
                .padding(.horizontal, 24)

                Button("关闭") { isRewardPresented = false }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.sealBackground.ignoresSafeArea())
        .presentationDetents([.fraction(0.62), .large], selection: $rewardSheetDetent)
        .presentationDragIndicator(.visible)
    }

    private var rewardCode: some View {
        Group {
            if let image = UIImage(named: "SealCommunityReward") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 42, weight: .medium))
                    Text("赞赏码暂不可用")
                        .font(.footnote)
                        .singleLine()
                }
                .foregroundStyle(Color.sealTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.sealSurfaceElevated)
            }
        }
        .frame(width: 184, height: 184)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.6), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .accessibilityLabel("Seal 微信赞赏二维码")
    }

    private var alipayBlue: Color {
        Color(red: 22 / 255.0, green: 119 / 255.0, blue: 1.0)
    }

    private var wechatGreen: Color {
        Color(red: 7 / 255.0, green: 193 / 255.0, blue: 96 / 255.0)
    }

    private func openAlipay() {
        guard let url = URL(string: "https://qr.alipay.com/fkx11863lft7h3izxgreqbe") else { return }
        openURL(url)
    }

    private func presentRewardSheet() {
        rewardSheetDetent = .fraction(0.62)
        isRewardPresented = true
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
