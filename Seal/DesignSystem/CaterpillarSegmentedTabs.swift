import SwiftUI
import UIKit

/// 应用页的两项分组标签。
///
/// 标签与下划线共用同一套「等分」几何：无论标题、数量或选中字重如何变化，
/// 两项都各占内容区的一半，下划线不会向左挤压或按旧文字宽度偏移。
struct CaterpillarSegmentedTabs<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    var count: ((Item) -> Int)? = nil
    @Binding var selection: Item
    @Binding var progress: CGFloat

    var spacing: CGFloat = 16
    var indicatorHeight: CGFloat = 3

    // Generic SwiftUI views cannot declare static stored properties.  Keep this
    // as an instance constant so the tab geometry remains compile-compatible.
    private let labelSpacing: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var labelHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 35
    @ScaledMetric(relativeTo: .body) private var labelFontSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var countFontSize: CGFloat = 13

    var body: some View {
        GeometryReader { proxy in
            let itemCount = max(items.count, 1)
            let totalSpacing = CGFloat(itemCount - 1) * spacing
            let tabWidth = max(0, (proxy.size.width - totalSpacing) / CGFloat(itemCount))

            VStack(spacing: labelSpacing) {
                HStack(spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        tab(item, index: index, width: tabWidth)
                    }
                }
                Color.clear.frame(height: indicatorHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomLeading) {
                indicator(tabWidth: tabWidth)
            }
        }
        .frame(height: controlHeight)
    }

    private func tab(_ item: Item, index: Int, width: CGFloat) -> some View {
        let proximity = max(0, min(1, 1 - abs(progress - CGFloat(index))))

        return Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                selection = item
                progress = CGFloat(index)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(item))
                    .font(.system(size: labelFontSize, weight: Self.weight(for: proximity)))
                    .foregroundStyle(
                        Color.sealAccent.blended(
                            with: Color.sealTextSecondary,
                            amount: 1 - proximity
                        )
                    )
                if let count {
                    Text("\(count(item))")
                        .font(.system(size: countFontSize, weight: .medium))
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
            .lineLimit(1)
            .frame(width: width, height: labelHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title(item))，\($0(item)) 个" } ?? title(item))
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }

    private func indicator(tabWidth: CGFloat) -> some View {
        let geometry = indicatorGeometry(tabWidth: tabWidth)
        return Capsule()
            .fill(Color.sealAccent)
            .frame(width: max(geometry.width, 1), height: indicatorHeight)
            .offset(x: geometry.x)
            .allowsHitTesting(false)
    }

    private func indicatorGeometry(tabWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let lastIndex = max(items.count - 1, 0)
        let clamped = min(max(progress, 0), CGFloat(lastIndex))
        let lower = Int(floor(clamped))
        let upper = min(lower + 1, lastIndex)
        let t = clamped - CGFloat(lower)
        let lowerMid = CGFloat(lower) * (tabWidth + spacing) + tabWidth / 2
        let upperMid = CGFloat(upper) * (tabWidth + spacing) + tabWidth / 2
        let mid = lowerMid + (upperMid - lowerMid) * t
        let stretched = tabWidth + (upperMid - lowerMid) * (1 - abs(2 * t - 1))
        return (mid - stretched / 2, stretched)
    }

    private static func weight(for proximity: CGFloat) -> Font.Weight {
        switch proximity {
        case ..<0.35: return .medium
        case ..<0.7: return .semibold
        default: return .bold
        }
    }
}

private extension Color {
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
