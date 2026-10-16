import SwiftUI
import UIKit

/// 「毛毛虫」分段标签栏。
///
/// 与常见分段控件的区别：下划线不是两帧之间做插值，而是**由连续进度驱动**。
/// 拖动内容页时进度跟着手指走，于是下划线会先向目标方向**伸长**（两端先动），
/// 中段随后跟上，再**收尾**贴到目标标签下方 —— 就是毛毛虫那样爬过去。
///
/// 进度语义：`progress ∈ [0, count-1]`，`0.4` 表示在第 0 与第 1 个标签之间、
/// 偏向前者六成的位置。点击标签时把进度补间到整数，所以点击和滑动共用同一条动画路径。
///
/// ## 几何是怎么算出来的（改这个文件前先读这段）
///
/// 早先的实现用「`GeometryReader` + `PreferenceKey` + 命名坐标系」测量每个标签的
/// `midX`，结果**七项症状全中**（下划线错位、宽度不对、两标签不等宽、字色不切换、
/// 点击不跳页、滑动异常、布局错乱）。三处根因：
///
/// 1. `.coordinateSpace(name:)` 挂在 HStack 上，而 `GeometryReader` 读 `.named(space)`
///    —— 命名坐标系**没有可靠地向下传递**，量到的 `midX` 全是错的或全 0。
/// 2. 用 `.onPreferenceChange` 回写 `@State` 再驱动**静态布局的 frame**（统一宽度），
///    这需要额外一轮布局 ⇒ 首帧必然不同步。
/// 3. 分页进度用 `frame.minX / proxy.size.width`，分母是**页宽**而非分页器视口宽。
///
/// 现在全部改成**确定性几何**：标签宽度用 `frame(width:)` 的提案回调算（这是纯粹的
/// 「给定提案返回尺寸」，与坐标系无关）；下划线放在 `.overlay(alignment: .topLeading)`
/// 里 —— overlay 的原点就是标签行的原点，**它就是坐标系本身**，不需要任何跨层传递。
struct CaterpillarSegmentedTabs<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    var count: ((Item) -> Int)? = nil
    @Binding var selection: Item
    /// 内容页的连续位置，由分页容器写入。
    @Binding var progress: CGFloat

    /// 标签之间的水平间距。
    var spacing: CGFloat = 24
    /// 静止时下划线的高度。
    var indicatorHeight: CGFloat = 3
    /// 左右内边距，需与内容页一致，否则下划线与文字对不齐。
    var horizontalPadding: CGFloat = 20
    /// 标签宽度下限，避免内容极短时下划线缩成一小段。
    var minTabWidth: CGFloat = 64

    @State private var tabWidth: CGFloat = 0
    /// 标签文字那一行的高度。下划线要贴在它下方，所以必须**量出来**而不是猜一个
    /// 常数 —— 一旦与真实行高不一致，下划线就会压住文字或浮在半空。
    @State private var labelHeight: CGFloat = 0

    private static var labelSpacing: CGFloat { 8 }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                tab(item, index: index)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .overlay(alignment: .topLeading) { indicator }
    }

    // MARK: - 单个标签

    private func tab(_ item: Item, index: Int) -> some View {
        // 该标签离当前位置有多近：1 = 完全选中，0 = 相邻或更远。
        // 颜色与字重都跟着它渐变，所以拖到一半时两边都是中间态。
        let proximity = max(0, min(1, 1 - abs(progress - CGFloat(index))))

        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                selection = item
                progress = CGFloat(index)
            }
        } label: {
            tabLabel(item, proximity: proximity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title(item))，\($0(item)) 个" } ?? title(item))
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }

    private func tabLabel(_ item: Item, proximity: CGFloat) -> some View {
        // 内容先按自然尺寸摆好；下面用同一个宽度把它居中，
        // 于是所有标签等宽、内容居中，既对称又不浪费横向空间。
        let content = HStack(spacing: 6) {
            Text(title(item))
                .font(.system(size: 17, weight: Self.weight(for: proximity)))
                .foregroundStyle(Color.sealAccent.blended(with: Color.sealTextSecondary,
                                                          amount: 1 - proximity))
            if let count {
                Text("\(count(item))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
            }
        }
        // `.fixedSize()` 让这一行保持自然尺寸，宽度与字重无关 ⇒ 量到的宽度稳定，
        // 不会因为选中态字重变化而反复触发重新布局。
        .fixedSize()

        return VStack(spacing: Self.labelSpacing) {
            content
                .frame(width: tabWidth > 0 ? tabWidth : nil, alignment: .center)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { recordLabelHeight(proxy.size.height) }
                            .onChange(of: proxy.size.height) { recordLabelHeight($0) }
                    }
                }
            // 占位：下划线由 overlay 里的 indicator 绘制，这里只把标签撑到统一高度。
            Capsule()
                .fill(Color.clear)
                .frame(width: tabWidth > 0 ? tabWidth : nil, height: indicatorHeight)
        }
        // 量宽：`frame(width:)` 的入参是**提案**、返回值是**实际采纳的尺寸**。
        // 传 `nil` 表示「按内容自然尺寸」，取回来的宽度就是这个标签的自然宽度。
        // 这一步与坐标系无关，所以不会像命名坐标系那样静默失效。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { recordTabWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { recordTabWidth($0) }
            }
        }
    }

    private func recordLabelHeight(_ height: CGFloat) {
        guard height > 0, abs(labelHeight - height) > 0.5 else { return }
        labelHeight = height
    }

    /// 统一宽度 = 所有标签里最宽的那个。
    ///
    /// 「待签名 2」与「已安装 12」字数、数字位数都不同 ⇒ 不统一就会一个宽一个窄、
    /// 下划线也跟着一长一短。取最宽者后两者都对齐到它、内容各自居中。
    private func recordTabWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let target = max(width, minTabWidth)
        guard abs(tabWidth - target) > 0.5 else { return }
        tabWidth = target
    }

    /// 按接近程度在 `medium` 与 `bold` 之间取字重。
    ///
    /// `Font.Weight` 不是数值类型，无法做算术插值，所以按区间离散取档再交给系统做
    /// 字体度量。视觉上足够连续，且不依赖任何私有 API。
    private static func weight(for proximity: CGFloat) -> Font.Weight {
        switch proximity {
        case ..<0.35: return .medium
        case ..<0.7: return .semibold
        default: return .bold
        }
    }

    // MARK: - 毛毛虫下划线

    /// 下划线所在的一行。`overlay(alignment: .topLeading)` 让它与标签行**原点重合**，
    /// 所以这里的 `offset(x:)` 直接就是屏幕上的水平位置。
    private var indicator: some View {
        let geometry = indicatorGeometry
        return VStack(spacing: 0) {
            // 顶到标签文字下方：用**量出来的**行高，不用猜的常数。
            Color.clear
                .frame(height: labelHeight + Self.labelSpacing)
            Capsule()
                .fill(Color.sealAccent)
                .frame(width: max(geometry.width, 1), height: indicatorHeight)
                .offset(x: geometry.x)
        }
        .padding(.horizontal, horizontalPadding)
        .allowsHitTesting(false)
        .opacity(tabWidth > 0 && labelHeight > 0 ? 1 : 0)
    }

    /// 下划线的位置与宽度。
    ///
    /// 取「当前进度」左右两侧标签的中点作为**两端**：
    /// - 进度是整数时两端重合 ⇒ 宽度 = 标签宽度，即静止态；
    /// - 进度在两者之间时两端分开 ⇒ 先伸长覆盖两点之间，再随进度收拢到目标。
    /// 「先伸长、再收尾」的观感就来自这里，而不是对位置做简单插值。
    private var indicatorGeometry: (x: CGFloat, width: CGFloat) {
        let lastIndex = max(items.count - 1, 0)
        let clamped = min(max(progress, 0), CGFloat(lastIndex))
        let lower = Int(floor(clamped))
        let upper = min(lower + 1, lastIndex)
        let t = clamped - CGFloat(lower)

        // 第 i 个标签的内容区中心（相对标签行内容起点）。
        let lowerMid = CGFloat(lower) * (tabWidth + spacing) + tabWidth / 2
        let upperMid = CGFloat(upper) * (tabWidth + spacing) + tabWidth / 2
        let mid = lowerMid + (upperMid - lowerMid) * t
        // 静止时宽度 = 标签宽度；过渡中两端分开 ⇒ 被拉开成「毛毛虫」。
        // 拉伸量随 `t` 收敛回 0，所以到位后自然收尾，不需要额外动画。
        let stretched = tabWidth + (upperMid - lowerMid) * (1 - abs(2 * t - 1))
        return (mid - stretched / 2, stretched)
    }
}

private extension Color {
    /// 线性混色：`amount = 0` 取自己，`1` 取 `other`。
    ///
    /// 不叫 `mix` 是为了避开 iOS 18 起系统自带的 `Color.mix(with:by:)` —— 同名扩展
    /// 会在较新 SDK 上产生歧义调用。
    ///
    /// `Color.sealAccent` 是动态色（随主题/深色模式变化），所以两端都先解析成具体
    /// RGBA 再插值。解析失败时退回端点色，绝不返回无效颜色 —— 无效值会让 SwiftUI
    /// 在渲染期断言崩溃，而这只是个装饰性下划线。
    func blended(with other: Color, amount: CGFloat) -> Color {
        let t = min(max(amount, 0), 1)
        if t <= 0.001 { return self }
        if t >= 0.999 { return other }
        guard let mixed = UIColor(self).blended(with: UIColor(other), amount: t) else {
            return t < 0.5 ? self : other
        }
        return Color(uiColor: mixed)
    }
}

private extension UIColor {
    /// 在两种颜色之间插值；任一颜色无法解析成 RGB 时返回 `nil`（调用方负责兜底）。
    func blended(with other: UIColor, amount: CGFloat) -> UIColor? {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return nil
        }
        return UIColor(
            red: r1 + (r2 - r1) * amount,
            green: g1 + (g2 - g1) * amount,
            blue: b1 + (b2 - b1) * amount,
            alpha: a1 + (a2 - a1) * amount
        )
    }
}
