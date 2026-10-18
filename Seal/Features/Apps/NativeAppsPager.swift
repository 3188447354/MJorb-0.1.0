import SwiftUI
import UIKit

@MainActor
struct NativeAppsPager<Page: View>: UIViewControllerRepresentable {
    @Binding var selection: Int
    let progress: CaterpillarTabsProgress
    let pages: [Page]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> NativeAppsPagerController<Page> {
        let controller = NativeAppsPagerController(pages: pages, selectedPage: selection)
        controller.onProgress = { [progress] value in
            progress.value = value
        }
        controller.onSelection = { [weak coordinator = context.coordinator] page in
            coordinator?.parent.selection = page
        }
        return controller
    }

    func updateUIViewController(_ controller: NativeAppsPagerController<Page>, context: Context) {
        context.coordinator.parent = self
        controller.onProgress = { [progress] value in
            progress.value = value
        }
        controller.update(
            pages: pages,
            selectedPage: selection,
            animated: context.transaction.animation != nil
        )
    }

    final class Coordinator {
        var parent: NativeAppsPager

        init(_ parent: NativeAppsPager) {
            self.parent = parent
        }
    }
}

@MainActor
final class NativeAppsPagerController<Page: View>: UIViewController, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private var pages: [Page]
    private var hostingControllers: [UIHostingController<Page>] = []
    private var requestedPage: Int
    private var hasSetInitialOffset = false
    private var lastLayoutWidth: CGFloat = 0

    var onProgress: ((CGFloat) -> Void)?
    var onSelection: ((Int) -> Void)?

    init(pages: [Page], selectedPage: Int) {
        self.pages = pages
        self.requestedPage = selectedPage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "apps-stage-pager"
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        var previousPageView: UIView?
        for page in pages {
            let hostingController = UIHostingController(rootView: page)
            hostingController.view.backgroundColor = .clear
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(hostingController)
            scrollView.addSubview(hostingController.view)

            var constraints = [
                hostingController.view.topAnchor.constraint(equalTo: scrollView.frameLayoutGuide.topAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: scrollView.frameLayoutGuide.bottomAnchor),
                hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
            ]
            if let previousPageView {
                constraints.append(hostingController.view.leadingAnchor.constraint(equalTo: previousPageView.trailingAnchor))
            } else {
                constraints.append(hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor))
            }
            NSLayoutConstraint.activate(constraints)
            hostingController.didMove(toParent: self)
            hostingControllers.append(hostingController)
            previousPageView = hostingController.view
        }

        if let lastPageView = hostingControllers.last?.view {
            lastPageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor).isActive = true
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0 else { return }

        if hasSetInitialOffset == false {
            hasSetInitialOffset = true
            lastLayoutWidth = width
            scrollView.setContentOffset(CGPoint(x: CGFloat(clampedPage(requestedPage)) * width, y: 0), animated: false)
            publishProgress()
        } else if abs(width - lastLayoutWidth) > 0.5 {
            let previousWidth = max(lastLayoutWidth, 1)
            requestedPage = clampedPage(Int((scrollView.contentOffset.x / previousWidth).rounded()))
            lastLayoutWidth = width
            scrollView.setContentOffset(CGPoint(x: CGFloat(requestedPage) * width, y: 0), animated: false)
            publishProgress()
        }
    }

    func update(pages: [Page], selectedPage: Int, animated: Bool) {
        self.pages = pages
        for index in hostingControllers.indices where index < pages.count {
            hostingControllers[index].rootView = pages[index]
        }
        selectPage(selectedPage, animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        publishProgress()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleOnNearestPage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate == false {
            settleOnNearestPage()
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settleOnNearestPage()
    }

    private func selectPage(_ page: Int, animated: Bool) {
        let page = clampedPage(page)
        guard page != requestedPage else { return }
        requestedPage = page
        guard hasSetInitialOffset, scrollView.bounds.width > 0 else { return }

        let targetX = CGFloat(page) * scrollView.bounds.width
        guard abs(scrollView.contentOffset.x - targetX) > 0.5 else {
            settleOnNearestPage()
            return
        }
        scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: animated)
        if animated == false {
            settleOnNearestPage()
        }
    }

    private func settleOnNearestPage() {
        guard scrollView.bounds.width > 0 else { return }
        requestedPage = clampedPage(Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded()))
        publishProgress()
        onSelection?(requestedPage)
    }

    private func publishProgress() {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let value = min(max(scrollView.contentOffset.x / width, 0), CGFloat(max(pages.count - 1, 0)))
        onProgress?(value)
    }

    private func clampedPage(_ page: Int) -> Int {
        min(max(page, 0), max(pages.count - 1, 0))
    }
}
