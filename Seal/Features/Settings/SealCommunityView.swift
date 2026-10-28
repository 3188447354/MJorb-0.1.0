import SwiftUI
import UIKit



struct SealCommunityView: View {
    @Environment(\.openURL) private var openURL

    private enum ActiveSheet: Identifiable {
        case gzh
        var id: Self { self }
    }
    @State private var activeSheet: ActiveSheet?
    @State private var saveCoordinator: AlbumSaveCoordinator?

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    // ⚠️ **这两行必须指向同一个群** ✗ —— 它们是**两条路径**，不是「链接 + 备份」✓：
    //   · `qqGroupNumber` → `mqqapi://card/show_pslcard?...&uin=<群号>&card_type=group`
    //     （**主路径**：QQ 装了就直接打开群资料卡 ✓）
    //   · `qqJoinURL` → 只在 **QQ 没装**、scheme 打不开时兜底 ✓
    // ⇒ 2026-09-20 换群时踩到：短链换了新群、群号还留着旧的 ⇒ **主路径会跳进旧群** ✗✗
    //   ⚠️ 短链 `qm.qq.com/q/XXXX` 是**不透明**的 ✗ —— 从链接本身**看不出群号** ✓，
    //   要抓落地页里的 `群号: <digits>` 或 `"groupcode":"<digits>"` 才知道 ✓。
    private let qqGroupNumber = "1051135067"
    private let qqJoinURL = URL(string: "https://qm.qq.com/q/8HfHpTmOzu")
    private let telegramFolderURL = URL(string: "https://t.me/addlist/vQ5-N-_q0qYzNWNl")

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                headerIntro

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("加入交流")
                    qqCard
                    telegramCard
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("关注官方动态")
                    gzhCard
                    douyinCard
                }

            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 32)
        }
        .navigationTitle("加入社群")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .gzh: gzhCodeSheet
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }

    private var headerIntro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("和 Seal 用户一起交流")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .singleLine()
            Text("反馈问题 · 分享经验 · 查看动态")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.sealTextSecondary)
            .singleLine()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gzhCard: some View {
        brandCard(
            brandImage: "BrandWechat",
            title: "关注公众号",
            subtitle: "教程 · 版本通知",
            value: nil,
            action: openGzhArticle
        )
    }

    private var qqCard: some View {
        brandCard(
            brandImage: "BrandQQ",
            title: "加入 QQ 群",
            subtitle: "群内交流与使用反馈",
            value: nil,
            action: joinQQGroup
        )
    }

    private var telegramCard: some View {
        brandCard(
            brandImage: "BrandTelegram",
            title: "加入 Telegram",
            subtitle: "交流群 · 发布频道",
            value: nil,
            action: openTelegramCommunity
        )
    }

    private var douyinCard: some View {
        brandCard(
            brandImage: "BrandDouyin",
            title: "关注抖音",
            subtitle: "视频教程 · 使用技巧",
            value: nil,
            action: openDouyin
        )
    }

    private var gzhCodeSheet: some View {
        VStack(spacing: 20) {
            // ⚠️ **圆弧框内包裹**（2026-09-20 用户要求）✗ ——
            // 原来这里是一张**裸图** ✗（只有「未加载」的占位才带圆角 ✗），
            // 与赞赏码**视觉不成套** ✗
            // ⇒ 套上和赞赏码**同款**的圆角白框（图片填满 ＋ `clipShape` 裁四角 ✓）。
            // ⚠️ 圆角取 **20**（240pt 宽按赞赏码 170→16 的比例放大 ✓，与下面占位一致 ✓）。
            Group {
                if let image = UIImage(named: "SealCommunityGzh") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    // 缺图占位（2026-10-24）：不再是大白框＋一行小字，改居中图标＋文案，
                    // 底色走内容面（深色下不刺眼）；有图时仍保留白色静区。
                    VStack(spacing: 10) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(Color.sealTextSecondary)
                        Text("公众号二维码未加载")
                            .font(.footnote)
                            .foregroundStyle(Color.sealTextSecondary)
                            .singleLine()
                    }
                    .frame(width: 240, height: 240)
                    .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .frame(width: 240, height: 240)
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.6), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

            Text("关注公众号，查看教程与更新。")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .singleLine()
                .padding(.horizontal, 24)

            Text("保存图片后，用微信扫一扫即可关注。")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .singleLine()
                .padding(.horizontal, 24)

            Button {
                saveCodeToAlbum(imageName: "SealCommunityGzh")
            } label: {
                Text("保存到相册")
                    .singleLine()
            }
            .sealPrimaryAction(cornerRadius: 14)
            .padding(.horizontal, 24)

            Button("关闭") { activeSheet = nil }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.bottom, 12)
        }
        .padding(.top, 24)
        .presentationDetents([.medium, .large])
    }

    /// 品牌图标卡片：用官方品牌图标（微信/QQ/抖音）替代通用 SF Symbol。
    private func brandCard(
        brandImage: String,
        title: String,
        subtitle: String?,
        value: String?,
        isExternal: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                brandIcon(brandImage)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.sealTextSecondary)
                            .singleLine()
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                }
                Image(systemName: isExternal ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .sealContentCard(.standard)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func brandIcon(_ imageName: String) -> some View {
        let image = Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: 46, height: 46)

        // Telegram 是透明圆形图标，保留圆形轮廓；QQ 素材是带浅色底的方形 PNG，
        // 需要统一圆角裁切，避免深色模式下浅色底板露成方块。
        if imageName == "BrandTelegram" {
            image
        } else {
            image.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    private func joinQQGroup() {
        // qm.qq.com 短链在系统浏览器里会先落到展示群二维码的落地页（即「扫一扫」），
        // 再唤起 QQ；改用 mqqapi scheme 直接打开 QQ 群资料卡，跳过中间落地页。
        let scheme = URL(string: "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=\(qqGroupNumber)&card_type=group&source=external")
        if let scheme {
            UIApplication.shared.open(scheme) { opened in
                if !opened, let fallback = qqJoinURL {
                    openURL(fallback)
                }
            }
        }
    }

    private func openDouyin() {
        if let url = URL(string: "https://v.douyin.com/r5NTxx_Ztyk/") {
            openURL(url)
        }
    }

    private func openGzhArticle() {
        if let url = URL(string: "https://mp.weixin.qq.com/s/q30q8SpERv2yg_vqSU_G_Q") {
            openURL(url)
        }
    }

    private func openTelegramCommunity() {
        guard let telegramFolderURL else { return }
        openURL(telegramFolderURL)
    }

    private func saveCodeToAlbum(imageName: String) {
        guard let image = UIImage(named: imageName) else {
            presentAlert("保存失败", "图片未加载，请检查网络后重试")
            return
        }
        let coordinator = AlbumSaveCoordinator { error in
            Task { @MainActor in
                handleSaveResult(error == nil)
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

    private func handleSaveResult(_ success: Bool) {
        if success {
            presentAlert("已保存到相册", "感谢您的支持")
        } else {
            presentAlert("保存失败", "请在系统设置中允许 Seal 访问相册后重试")
        }
    }

    private func presentAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

final class AlbumSaveCoordinator: NSObject, @unchecked Sendable {
    private let completion: @Sendable (Error?) -> Void

    init(completion: @escaping @Sendable (Error?) -> Void) {
        self.completion = completion
    }

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        completion(error)
    }
}
