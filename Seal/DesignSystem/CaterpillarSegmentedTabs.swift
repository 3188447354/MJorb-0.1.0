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
struct CaterpillarSegmentedTabs<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    var count: ((Item) -> Int)? = nil
    @Binding var selection: Item
    /// 内容页的连续位置，由分页容器写入。
    @Binding var progress: CGFloat

    /// 标签之间的水平间距。
    var spacing: CGFloat = 28
    /// 静止时下划线的高度。
    var indicatorHeight: CGFloat = 3
    /// 左右内边距，需与内容页一致，否则下划线与文字对不齐。
    var horizontalPadding: CGFloat = 20

    @State private var labelMidpoints: [CGFloat] = []
    @State private var labelWidths: [CGFloat] = []

    private static var space: String { "caterpillar-tabs" }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                label(item, index: index)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .background(alignment: .topLeading) { indicator }
        .coordinateSpace(name: Self.space)
    }

    // MARK: - 单个标签

    private func label(_ item: Item, index: Int) -> some View {
        // 该标签离当前位置有多近：1 = 完全选中，0 = 相邻或更远。
        let proximity = max(0, 1 - abs(progress - CGFloat(index)))

        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                selection = item
                progress = CGFloat(index)
            }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(title(item))
                        .font(.system(size: 17, weight: Self.weight(for: proximity)))
                        .foregroundStyle(
                            Color.sealAccent.blended(with: Color.sealTextSecondary, amount: 1 - proximity)
                        )
                    if let count {
                        Text("\(count(item))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                }
                // 占位：下划线统一由背景层的 indicator 绘制，这里只把标签撑到统一高度。
                Capsule()
                    .fill(Color.clear)
                    .frame(height: indicatorHeight)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TabMetricsKey.self,
                        value: [index: TabMetrics(midX: proxy.frame(in: .named(Self.space)).midX,
                                                 width: proxy.size.width)]
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title(item))，\($0(item)) 个" } ?? title(item))
        .accessibilityAddTraits(selection == item ? .isSelected : [])
        .onPreferenceChange(TabMetricsKey.self) { metrics in
            let total = items.count
            var midpoints = [CGFloat](repeating: 0, count: total)
            var widths = [CGFloat](repeating: 0, count: total)
            for (index, metric) in metrics where index < total {
                midpoints[index] = metric.midX
                widths[index] = metric.width
            }
            if labelMidpoints != midpoints { labelMidpoints = midpoints }
            if labelWidths != widths { labelWidths = widths }
        }
    }

    /// 按接近程度在 `medium` 与 `bold` 之间取字重。
    ///
    /// `Font.Weight` 不是数值类型，无法做算术插值，所以按区间离散取档再交给系统做
    /// 字体度量。视觉上足够连续，且不依赖任何私有 API。
    private static func weight(for proximity: CGFloat) -> Font.Weight {
        switch proximity {
        case ..<0.25: return .medium
        case ..<0.5: return .medium
        case ..<0.75: return .semibold
        default: return .bold
        }
    }

    // MARK: - 毛毛虫下划线

    private var indicator: some View {
        let geometry = indicatorGeometry
        return Capsule()
            .fill(Color.sealAccent)
            .frame(width: max(geometry.width, 1), height: indicatorHeight)
            .offset(x: geometry.x)
            .opacity(labelMidpoints.count == items.count ? 1 : 0)
    }

    /// 下划线的位置与宽度。
    ///
    /// 取「当前进度」左右两侧标签的中点作为**两端**：
    /// - 进度是整数时两端重合 ⇒ 宽度 = 标签宽度，即静止态；
    /// - 进度在两者之间时两端分开 ⇒ 先伸长覆盖两点之间，再随进度收拢到目标。
    /// 「先伸长、再收尾」的观感就来自这里，而不是对位置做简单插值。
    private var indicatorGeometry: (x: CGFloat, width: CGFloat) {
        guard labelMidpoints.count == items.count, !labelMidpoints.isEmpty else { return (0, 0) }

        let clamped = min(max(progress, 0), CGFloat(items.count - 1))
        let lower = Int(floor(clamped))
        let upper = min(lower + 1, items.count - 1)
        let t = clamped - CGFloat(lower)

        let lowerMid = labelMidpoints[lower]
        let upperMid = labelMidpoints[upper]
        // 宽度也插值，避免两项宽度不同时下划线跳动。
        let width = labelWidths[lower] + (labelWidths[upper] - labelWidths[lower]) * t
        let mid = lowerMid + (upperMid - lowerMid) * t
        return (mid - width / 2, width)
    }
}

private struct TabMetrics: Equatable {
    var midX: CGFloat
    var width: CGFloat
}

private struct TabMetricsKey: PreferenceKey {
    static var defaultValue: [Int: TabMetrics] { [:] }
    static func reduce(value: inout [Int: TabMetrics], nextValue: () -> [Int: TabMetrics]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension Color {
    /// 线性混色：`amount = 0` 取自己，`1` 取 `other`。
    ///
    /// 不叫 `mix` 是为了避开 iOS 18 起系统自带的 `Color.mix(with:by:)` —— 同名扩展
    /// 会在较新 SDK 上产生歧义调用。
    func blended(with other: Color, amount: CGFloat) -> Color {
        let t = min(max(amount, 0), 1)
        if t <= 0 { return self }
        if t >= 1 { return other }
        return Color(uiColor: UIColor(self).blended(with: UIColor(other), amount: t))
    }
}

private extension UIColor {
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }
        return UIColor(
            red: r1 + (r2 - r1) * amount,
            green: g1 + (g2 - g1) * amount,
            blue: b1 + (b2 - b1) * amount,
            alpha: a1 + (a2 - a1) * amount
        )
    }
}
