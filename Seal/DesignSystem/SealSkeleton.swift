import SwiftUI

/// 骨架屏占位条（2026-10-24）：内容加载期间按最终版式先画灰块，内容一到原位替换，
/// 不再出现「转圈＋一行字」或「先显 0 再跳变」的半截状态。
///
/// 扫光形态有硬性约束：只能用占位灰自身的低对比明暗呼吸。白色高光带
/// 已在 2026-09-18 被用户实测否掉，这里不许出现。
struct SealSkeletonBar: View {
    /// 灰块宽度；nil 时撑满可用宽度。
    var width: CGFloat?
    var height: CGFloat = 14

    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.sealTextSecondary.opacity(breathing ? 0.16 : 0.28))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            .animation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: breathing
            )
            .onAppear { breathing = true }
    }
}

/// 一行明细骨架：左标签灰块＋右值灰块，与明细行「左名右值」的版式一致。
struct SealSkeletonDetailRow: View {
    var labelWidth: CGFloat = 72
    var valueWidth: CGFloat = 128

    var body: some View {
        HStack(spacing: 12) {
            SealSkeletonBar(width: labelWidth, height: 12)
            SealSkeletonBar(width: valueWidth, height: 12)
            Spacer(minLength: 0)
        }
    }
}
