import SwiftUI

struct SealSheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Color.sealHairline.opacity(0.95))
            .frame(width: 40, height: 5)
            .accessibilityHidden(true)
    }
}

struct SealDrawerLayoutMeasurements: Equatable {
    var headerHeight: CGFloat = 0
    var contentHeight: CGFloat = 0
    var footerHeight: CGFloat = 0

    var totalHeight: CGFloat {
        headerHeight + contentHeight + footerHeight
    }
}

struct SealDrawerLayoutMeasurementsPreferenceKey: PreferenceKey {
    static let defaultValue = SealDrawerLayoutMeasurements()

    static func reduce(value: inout SealDrawerLayoutMeasurements, nextValue: () -> SealDrawerLayoutMeasurements) {
        let next = nextValue()
        value.headerHeight = max(value.headerHeight, next.headerHeight)
        value.contentHeight = max(value.contentHeight, next.contentHeight)
        value.footerHeight = max(value.footerHeight, next.footerHeight)
    }
}

/// Unified bottom-sheet container used throughout Seal.
/// The header and footer stay fixed while the body scrolls independently.
struct SealDrawer<Content: View, Footer: View>: View {
    let title: String?
    let level: SealScreenLevel
    let showsFooter: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    init(
        title: String? = nil,
        level: SealScreenLevel = .tertiary,
        showsFooter: Bool = true,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.level = level
        self.showsFooter = showsFooter
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                SealSheetGrabber()
                    .padding(.top, 10)
                if let title {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SealLayout.drawerHorizontalInset)
                }
            }
            .padding(.bottom, title == nil ? 10 : 14)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SealDrawerLayoutMeasurementsPreferenceKey.self,
                        value: SealDrawerLayoutMeasurements(headerHeight: geometry.size.height)
                    )
                }
            }

            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SealLayout.drawerHorizontalInset)
                    .padding(.vertical, 2)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: SealDrawerLayoutMeasurementsPreferenceKey.self,
                                value: SealDrawerLayoutMeasurements(contentHeight: geometry.size.height)
                            )
                        }
                    }
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsFooter {
                VStack(spacing: 10) {
                    Divider()
                        .overlay(Color.sealHairline.opacity(0.65))
                    footer()
                        .padding(.horizontal, SealLayout.drawerHorizontalInset)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                }
                .background(SealBackdrop(level: level))
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: SealDrawerLayoutMeasurementsPreferenceKey.self,
                            value: SealDrawerLayoutMeasurements(footerHeight: geometry.size.height)
                        )
                    }
                }
            }
        }
        .background(SealBackdrop(level: level).ignoresSafeArea())
        .presentationDragIndicator(.hidden)
        .compatibleClearPresentationBackground()
        .compatiblePresentationCornerRadius(SealLayout.drawerCornerRadius)
    }
}

extension SealDrawer where Footer == EmptyView {
    init(
        title: String? = nil,
        level: SealScreenLevel = .tertiary,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, level: level, showsFooter: false, content: content) { EmptyView() }
    }
}
