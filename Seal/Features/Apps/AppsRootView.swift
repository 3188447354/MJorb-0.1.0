import SwiftUI
import UniformTypeIdentifiers

struct AppsRootView: View {
    private enum ListMode: String, Identifiable, CaseIterable {
        case unsigned = "待安装"
        case installed = "已安装"

        var id: Self { self }
    }

    @ObservedObject var viewModel: AppsViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var sealTitleSize = 38
    @State private var mode: ListMode = .installed
    /// 内容页的连续位置（0 = 待安装，1 = 已安装），由分页器测量写入、驱动毛毛虫下划线。
    @State private var pagerProgress: CGFloat = 1
    @State private var detailApp: AppRecord?
    @State private var pendingDeleteApp: AppRecord?
    @State private var installedActionApp: AppRecord?
    @State private var operationAppID: UUID?
    @State private var didResolveInitialMode = false
    /// 系统通知点进来时，SwiftUI 的 sheet host 可能尚未挂载。先等根视图出现，
    /// 再在下一次主循环请求结果抽屉，避免状态已锁住列表而系统 sheet 没有呈现。
    @State private var isResultPresentationHostReady = false
    @State private var hasPendingBackgroundResultPresentation = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                header
                modeTabs
                appPager
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $viewModel.isImporterPresented,
                allowedContentTypes: [.item, .data, .archive, .ipaArchive, .zipArchive]
            ) { result in
                switch result {
                case .success(let url):
                    // 不在这里切 tab：等 versionCheck 出来，已安装被拦截的不跳，
                    // 只有真正要导入的才切到待签名页（见 consumeWorkflowState）。
                    Task { await viewModel.importSelectedFile(url) }
                case .failure(let error): viewModel.handleImporterFailure(error)
                }
            }
            .sheet(isPresented: $viewModel.isImportSheetPresented, onDismiss: cancelDraftIfNeeded) {
                if let draft = viewModel.sheetDraft {
                    ImportConfirmationView(
                        draft: draft,
                        replacementCandidate: viewModel.importReplacementCandidate,
                        isCommitting: viewModel.phase == .committing,
                        failure: viewModel.sheetFailure,
                        onCancel: { Task { await viewModel.cancelImport() } },
                        onPrimaryAction: {
                            Task {
                                await viewModel.performImportPrimaryAction()
                            }
                        },
                        onCreateCopy: { Task { await viewModel.confirmImportAsNewRecord() } },
                        onIconSelected: { data in viewModel.pendingImportIconData = data },
                        onNameSelected: { name in viewModel.pendingImportDisplayName = name }
                    )
                    .presentationDetents([.height(580)])
                    .presentationDragIndicator(.hidden)
                }
            }
            // 已安装包再导入：系统弹窗，不走抽屉
            .alert("已安装", isPresented: Binding(
                get: { viewModel.alreadyInstalledDraft != nil },
                set: { if !$0 { viewModel.alreadyInstalledDraft = nil } }
            )) {
                Button("知道了") {
                    viewModel.alreadyInstalledDraft = nil
                    Task { await viewModel.cancelImport() }
                }
            } message: {
                if let draft = viewModel.alreadyInstalledDraft {
                    Text("\(draft.parsedIPA.name) v\(draft.parsedIPA.version) 已安装，无需重复导入")
                }
            }
            .sheet(item: $viewModel.selectedOperationApp, onDismiss: operationSheetDismissed) { app in
                AppSigningSheet(
                    app: app,
                    viewModel: viewModel,
                    onFinish: { _ in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = .installed }
                    },
                    onDelete: {
                        pendingDeleteApp = app
                    }
                )
                .presentationDetents(operationDetents(for: app))
            }
            .sheet(item: installedActionSheet, onDismiss: {
                installedActionApp = nil
            }) { app in
                InstalledAppActionSheet(
                    app: app,
                    viewModel: viewModel,
                    onRenew: {
                        // The action drawer must relinquish its route before the
                        // renewal progress drawer starts. Otherwise SwiftUI can
                        // re-present this stale item for one frame when progress
                        // dismisses.
                        installedActionApp = nil
                        detailApp = nil
                        operationAppID = app.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            await viewModel.beginRenewalDirectly(for: app, overrideAccountID: nil)
                        }
                    }
                )
                .presentationDetents(installedOperationDetents)
            }
            .sheet(item: $viewModel.accountSelectionApp) { app in
                AccountSelectionView(
                    app: app,
                    accounts: viewModel.availableAccounts,
                    fullEmail: { viewModel.fullEmail(for: $0) },
                    onSelect: { viewModel.selectAccount($0, for: app) }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: batchRefreshSheet) { _ in
                BatchRefreshView(viewModel: viewModel)
                    .presentationDetents([.height(620), .large])
            }
            .sheet(item: $detailApp) { app in
                AppDetailView(appID: app.id, viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            }
            .alert(deleteAlertTitle, isPresented: Binding(
                get: { pendingDeleteApp != nil },
                set: { if !$0 { pendingDeleteApp = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDeleteApp = nil }
                Button("删除", role: .destructive) {
                    guard let app = pendingDeleteApp else { return }
                    pendingDeleteApp = nil
                    Task { _ = await viewModel.delete(app) }
                }
            } message: {
                Text(deleteAlertMessage)
            }
            .alert(item: rootAlertFailure) { failure in
                standardAlert(failure)
            }
            .task {
                // 后台续签已经得到终态时，通知进入必须先展示结果；不能被启动维护、
                // 设备核验或列表加载拖住，造成用户得点几次应用才看到抽屉。
                requestSettledBackgroundBatchResultPresentation()
                await settingsViewModel.load()
                // ── 启动关键路径（阻塞首屏，只做最少必要）──
                // 记录恢复（设备扫描发现 App）是新安装时列表有数据的唯一来源，
                // 必须在首屏前完成。孤儿清理 / 描述文件清理 / 设备核验不阻塞首屏，
                // 放后台延迟执行（用户操作开始时自动中止，下次再跑）。
                let recoveredRecords = await viewModel.runEssentialMaintenanceIfIdle()
                // 再恢复其余被中断项：上一轮留下的 running 项必须在任何新一轮续签覆盖队列文件之前
                // 降级为 unknown，否则它们既不会被重试也不会被清理，永久停在「运行中」。
                await viewModel.recoverInterruptedQueueIfNeeded()
                // 恢复出了记录就强制重载：`.onAppear` 可能并发先刷出空列表，
                // 不 force 的话恢复的记录要等后台核验才出现。
                await viewModel.load(force: recoveredRecords)
                resolveInitialModeIfNeeded()
                // ── 非关键路径（后台，不阻塞首屏）──
                Task {
                    await viewModel.runDeferredMaintenanceIfIdle()
                    await viewModel.refreshInstalledApps(userInitiated: false)
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                requestSettledBackgroundBatchResultPresentation()
                Task {
                    await viewModel.refreshInstalledApps(userInitiated: false)
                    if mode == .unsigned {
                        await viewModel.refreshUnsignedApps()
                    }
                }
            }
            .onChange(of: viewModel.isBatchRefreshSheetPresented) { isPresented in
                guard isPresented else { return }
                installedActionApp = nil
                detailApp = nil
                // 批量抽屉弹出时，单个操作的 sheet 必须一起清掉，否则批量关掉后它会闪出来。
                viewModel.dismissOperation()
            }
            .onReceive(NotificationCenter.default.publisher(for: BackgroundRenewalNotificationRoute.opened)) { _ in
                // 快捷指令成功通知的点击是一个明确的用户意图；不要只赌 scenePhase
                // 变化（冷启动和从通知中心回到已在后台的进程时序不同）。
                requestSettledBackgroundBatchResultPresentation()
            }
            // 真正要导入时才切到待签名页：
            // 2026-10-09 重设计：覆盖更新（含 Seal 自更新）也进待签名页，不再留在已安装页。
            .onChange(of: viewModel.isImportSheetPresented) { isPresented in
                guard isPresented else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = .unsigned }
            }
            .onChange(of: batchRefreshSheet.wrappedValue?.id) { sessionID in
                guard sessionID != nil else { return }
                // 后台续签结果优先于任何已点开的应用操作，避免两个 sheet 争夺呈现层。
                installedActionApp = nil
                detailApp = nil
            }
            .onChange(of: viewModel.importCompletionCount) { _ in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    mode = viewModel.lastImportCompletedInstalledApp ? .installed : .unsigned
                }
            }
            .onAppear {
                isResultPresentationHostReady = true
                requestSettledBackgroundBatchResultPresentation()
                // 安装后重开 App，提示不消失，要点别的页再回来才刷——强制重载
                Task {
                    await viewModel.syncSelfRecordOnLaunch()
                    await viewModel.load(force: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sealSelfRecordUpdated)) { _ in
                // 自安装重启后，记录与证书派生状态必须同一轮发布。
                Task { await viewModel.reloadSelfRecordSnapshot() }
            }
        }
        .sealScreenBackground()
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Seal")
                .font(.system(size: sealTitleSize, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                viewModel.presentImporter()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
                    // ⚠️ 玻璃尺寸**不**在这里定：label 不加 frame，`.glass` 样式按内容
                    // 自适应系统规范尺寸（约 36pt 圆）；44x44 的 frame 加在 Button 上
                    // 只保证 HIG 最小触控目标，不撑大玻璃（2026-10-04 用户反馈玻璃太大）。
            }
            .modifier(ImportButtonGlassModifier())
            .frame(width: 44, height: 44)
            .accessibilityLabel("导入应用")
            .accessibilityIdentifier("import-toolbar-button")
            .disabled(viewModel.phase != .idle)
        }
    }

    private var modeTabs: some View {
        CaterpillarSegmentedTabs(
            items: ListMode.allCases,
            title: { $0.rawValue },
            count: { mode in
                switch mode {
                case .unsigned: return viewModel.unsignedApps.count
                case .installed: return viewModel.installedApps.count
                }
            },
            selection: selectionBinding,
            progress: $pagerProgress
        )
        .accessibilityIdentifier("apps-stage-tabs")
    }

    /// 点标签时同时写 `mode`（驱动分页器）和 `pagerProgress`（驱动下划线）。
    private var selectionBinding: Binding<ListMode> {
        Binding(
            get: { mode },
            set: { newValue in
                mode = newValue
                // 点击时做补间，让下划线和内容页同步滑过去，而不是瞬移。
                if let index = ListMode.allCases.firstIndex(of: newValue) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        pagerProgress = CGFloat(index)
                    }
                }
            }
        )
    }

    private var appPager: some View {
        TabView(selection: $mode) {
            appPage(.unsigned, apps: viewModel.unsignedApps)
                .background(pageProgressProbe(index: 0))
                .tag(ListMode.unsigned)
            appPage(.installed, apps: viewModel.installedApps)
                .background(pageProgressProbe(index: 1))
                .tag(ListMode.installed)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .coordinateSpace(name: Self.pagerSpace)
        .accessibilityIdentifier("apps-stage-pager")
        // ⚠️ 这里**不能**再挂 `.animation(_:value:)`。
        // 分页切换由 `TabView` 自己的分页动画完成，进度由 `withAnimation` 显式驱动；
        // 再叠一层隐式动画会让两者各animate各的，`frame` 的中间值被反复写回
        // `pagerProgress`，下划线与内容页就会互相追着抖。
    }

    private static var pagerSpace: String { "apps-stage-pager-space" }

    /// 把「当前看到第几页」量成一个连续的小数，供毛毛虫下划线使用。
    ///
    /// 用测量而不是读滚动偏移：`TabView` 的分页滚动偏移没有公开可读的 API。
    ///
    /// ⚠️ 两个曾经让进度**完全不动**的坑（2026-10-16 实测定位）：
    /// 1. 只监听 `frame.minX` 不够：手指拖动时变的是分页器的滚动偏移，
    ///    页视图在分页器坐标系下的 `minX` 会在滑动过程中连续变化，但**用 `onChange`
    ///    只盯一个分量**时，初值不会被记录（没有 `.onAppear`），首帧之后若没有
    ///    逐帧回调就会停在初值。⇒ 改成整体监听 `frame` 并补 `.onAppear` 初始化。
    /// 2. `.background(_:)` 的默认对齐是 `.center`，`GeometryReader` 会撑满页面，
    ///    量到的宽度是**页宽**；分页器视口宽与页宽一致时才对，不一致就会算歪。
    ///    ⇒ 用 `.background(alignment: .topLeading)` 并显式取 `proxy.size.width`，
    ///    它就是这一页的宽度，也就是分页器的分页步长。
    private func pageProgressProbe(index: Int) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(Self.pagerSpace))
            Color.clear
                .onAppear { updatePagerProgress(index: index, frame: frame, width: proxy.size.width) }
                .onChange(of: frame) { newFrame in
                    updatePagerProgress(index: index, frame: newFrame, width: proxy.size.width)
                }
        }
        .allowsHitTesting(false)
    }

    private func updatePagerProgress(index: Int, frame: CGRect, width: CGFloat) {
        guard width > 0 else { return }
        // 本页在视口中的位置：0 = 正对、-1 = 完全滑到左侧、+1 = 完全滑到右侧。
        let offsetFromViewport = min(max(frame.minX / width, -1), 1)
        let candidate = CGFloat(index) - offsetFromViewport
        let clamped = min(max(candidate, 0), CGFloat(ListMode.allCases.count - 1))
        if abs(pagerProgress - clamped) > 0.0005 {
            pagerProgress = clamped
        }
    }

    private func appPage(_ pageMode: ListMode, apps: [AppRecord]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(pageMode)
                    .frame(height: 38)
                appList(pageMode, apps: apps)
            }
            .padding(.bottom, 30)
        }
        .refreshable {
            await refreshAppsPage(pageMode)
        }
    }

    private func pageHeader(_ pageMode: ListMode) -> some View {
        HStack(alignment: .center) {
            Text(sectionTitle(for: pageMode))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if pageMode == .installed, viewModel.installedApps.isEmpty == false {
                batchRefreshMenu
            } else {
                Color.clear.frame(width: 1, height: 30)
            }
        }
    }

    @ViewBuilder
    private func appList(_ pageMode: ListMode, apps: [AppRecord]) -> some View {
        if pageMode == .unsigned, viewModel.phase == .preparing || viewModel.phase == .committing {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在读取 IPA")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 116)
            .sealListCard(cornerRadius: 18)
        } else if apps.isEmpty {
            emptyState(pageMode)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    Button {
                        openApp(app, in: pageMode)
                    } label: {
                        ImportedAppRow(
                            app: app,
                            iconData: viewModel.iconData[app.id],
                            decodedImage: viewModel.decodedIcon(for: app.id)
                        )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if pageMode == .installed {
                            Button("查看详情") { detailApp = app }
                        }
                        if pageMode == .unsigned {
                            Button("删除 IPA", role: .destructive) { pendingDeleteApp = app }
                        } else if app.isSeal == false, isExpired(app) {
                            Button("删除记录", role: .destructive) { pendingDeleteApp = app }
                        }
                    }

                    if index < apps.count - 1 {
                        Divider()
                            .padding(.leading, 84)
                            .padding(.trailing, 18)
                    }
                }
            }
            .sealListCard(cornerRadius: 20)
        }
    }

    private func emptyState(_ pageMode: ListMode) -> some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIcon(for: pageMode))
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.sealAccent)
            Text(emptyTitle(for: pageMode))
                .font(.headline)
            if pageMode == .unsigned {
                Text("点击右上角 + 导入 IPA")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .sealListCard(cornerRadius: 20)
    }

    private func openApp(_ app: AppRecord, in pageMode: ListMode) {
        switch pageMode {
        case .unsigned:
            operationAppID = app.id
            viewModel.presentOperation(for: app)
        case .installed:
            // 通知进入时可能恰好还没有完成启动任务；先恢复已结算结果，不能让一次
            // 列表点击把应用操作抽屉与结果抽屉并发打开。
            if viewModel.hasSettledBackgroundBatchResultReadyForPresentation() {
                requestSettledBackgroundBatchResultPresentation()
                return
            }
            guard BatchResultPresentationPolicy.allowsInstalledAppAction(
                hasBatchResultSheet: viewModel.isBatchRefreshSheetPresented
            ) else {
                return
            }
            installedActionApp = app
        }
    }

    /// `task` 与通知 delegate 都可能早于 sheet presenter 建立，且通知唤醒会先经历
    /// inactive。先记住用户的打开意图，直到根 host 已挂载且 App 回到 active，才把它
    /// 转成唯一的业务抽屉状态；这样不会出现“列表被结果状态锁住，抽屉却没弹出来”。
    private func requestSettledBackgroundBatchResultPresentation() {
        hasPendingBackgroundResultPresentation = true
        flushSettledBackgroundBatchResultPresentationIfPossible()
    }

    private func flushSettledBackgroundBatchResultPresentationIfPossible() {
        guard BatchResultPresentationPolicy.shouldFlushPendingResultPresentation(
            hasPendingRequest: hasPendingBackgroundResultPresentation,
            isHostReady: isResultPresentationHostReady,
            isAppActive: scenePhase == .active
        ) else { return }
        Task { @MainActor in
            await Task.yield()
            guard BatchResultPresentationPolicy.shouldFlushPendingResultPresentation(
                hasPendingRequest: hasPendingBackgroundResultPresentation,
                isHostReady: isResultPresentationHostReady,
                isAppActive: scenePhase == .active
            ) else { return }
            hasPendingBackgroundResultPresentation = false
            _ = viewModel.presentSettledBackgroundBatchResultIfNeeded()
        }
    }

    /// 批量结果（尤其是通知进入后的已结算结果）拥有抽屉优先级。
    /// 这里在绑定读取侧再做一次门禁，而不只依赖点击时的 guard：SwiftUI 在同一轮
    /// 状态更新里可能已经开始呈现旧的 `installedActionApp`，否则会出现“应用操作一闪，
    /// 随后才显示续签结果”的错序。
    private var installedActionSheet: Binding<AppRecord?> {
        Binding(
            get: {
                BatchResultPresentationPolicy.shouldPresentInstalledAppAction(
                    hasBatchResultSheet: viewModel.isBatchRefreshSheetPresented,
                    hasInstalledAppAction: installedActionApp != nil
                ) ? installedActionApp : nil
            },
            set: { newValue in
                if newValue == nil || viewModel.isBatchRefreshSheetPresented == false {
                    installedActionApp = newValue
                }
            }
        )
    }

    /// `.sheet(item:)` 不能直接观察后台批次的临时会话，否则它会把后台“安装中”
    /// 当作前台抽屉。显式呈现开关只在用户回到 Seal、结果已结算后打开。
    private var batchRefreshSheet: Binding<BatchRefreshSession?> {
        Binding(
            get: {
                BatchResultPresentationPolicy.shouldPresentBatchResultSheet(
                    isPresentationRequested: viewModel.isBatchRefreshSheetPresented,
                    hasBatchRefreshSession: viewModel.batchRefreshSession != nil
                ) ? viewModel.batchRefreshSession : nil
            },
            set: { session in
                if session == nil {
                    viewModel.dismissBatchRefresh()
                }
            }
        )
    }

    private func operationSheetDismissed() {
        // A completed signing/renewal must never reveal an older action route
        // during the native dismissal transaction.
        installedActionApp = nil
        detailApp = nil
        viewModel.dismissOperation()
        guard let operationAppID else { return }
        self.operationAppID = nil
        Task { @MainActor in
            await viewModel.load(force: true)
            if viewModel.installedApps.contains(where: { $0.id == operationAppID }) {
                withAnimation { mode = .installed }
            }
        }
    }

    private func resolveInitialModeIfNeeded() {
        guard didResolveInitialMode == false else { return }
        didResolveInitialMode = true
        if viewModel.unsignedApps.isEmpty && viewModel.installedApps.isEmpty {
            mode = .unsigned
        } else {
            mode = .installed
        }
    }

    private func refreshAppsPage(_ pageMode: ListMode) async {
        switch pageMode {
        case .unsigned:
            await viewModel.refreshUnsignedApps()
        case .installed:
            // 下拉刷新是尽力读取设备状态；设备暂不可达时保留当前列表并静默结束，
            // 不能把每一次手势都升级成阻断式弹窗。
            await viewModel.refreshInstalledApps(userInitiated: false)
        }
    }
    private func sectionTitle(for pageMode: ListMode) -> String {
        switch pageMode {
        case .unsigned: "待安装应用"
        case .installed: "已安装应用"
        }
    }

    private func emptyTitle(for pageMode: ListMode) -> String {
        switch pageMode {
        case .unsigned: "暂无待安装应用"
        case .installed: "暂无已安装应用"
        }
    }

    private func emptyIcon(for pageMode: ListMode) -> String {
        switch pageMode {
        case .unsigned: "square.and.arrow.down"
        case .installed: "app.badge.checkmark"
        }
    }

    private func operationDetents(for app: AppRecord) -> Set<PresentationDetent> {
        if app.belongsInInstalledList { return installedOperationDetents }
        let extraExtensionHeight = CGFloat(min(app.extensions.count, 4)) * 10
        return [.height(CGFloat(660) + extraExtensionHeight), .large]
    }

    private var installedOperationDetents: Set<PresentationDetent> {
        [.height(560), .large]
    }

    private var deleteAlertTitle: String {
        pendingDeleteApp?.belongsInInstalledList == true ? "删除记录？" : "删除 IPA？"
    }

    private var deleteAlertMessage: String {
        guard pendingDeleteApp?.belongsInInstalledList == true else {
            return "删除后将从 Seal 的待安装列表中移除，并删除 Seal 保存的导入 IPA，不会影响手机上已安装的应用。"
        }
        return "删除后将从 Seal 的已安装列表中移除，不会卸载手机上的应用。"
    }

    private var batchRefreshMenu: some View {
        Button {
            viewModel.refreshAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("续签全部")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.sealAccent)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.sealAccent.opacity(0.10), in: Capsule())
        }
        .accessibilityLabel("续签全部")
    }

    private func isExpired(_ app: AppRecord, now: Date = Date()) -> Bool {
        guard let expiryDate = app.expiryDate else { return false }
        return expiryDate <= now
    }

    private func standardAlert(_ failure: ImportFailure) -> Alert {
        return Alert(
            title: Text(failure.title),
            message: Text(failure.userMessage),
            dismissButton: .default(Text(failure.recovery)) {
                viewModel.performAlertRecovery(for: failure)
            }
        )
    }

    private var rootAlertFailure: Binding<ImportFailure?> {
        Binding(
            get: {
                viewModel.selectedOperationApp == nil && installedActionApp == nil
                    ? viewModel.alertFailure
                    : nil
            },
            set: { viewModel.alertFailure = $0 }
        )
    }

    private func cancelDraftIfNeeded() {
        if viewModel.phase != .committing, viewModel.sheetDraft != nil {
            Task { await viewModel.cancelImport() }
        }
    }
}

/// 首页导入按钮的玻璃适配：iOS 26+ 必须用系统 `.glass` 按钮样式（真液态玻璃，
/// 自动适配“降低透明度”），**不能**在自定义 ButtonStyle 里手贴 `.glassEffect` ——
/// 后者在 ButtonStyle 上下文里渲染不出玻璃，只剩一个白圈描边（2026-10-03 真机截图），
/// 看着和 iOS 26 以下的回退一模一样，这就是“假玻璃”。
/// iOS 26 以下保留同尺寸、同命中区域的实色回退，不改变导入行为。
private struct ImportButtonGlassModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .buttonStyle(ImportFallbackButtonStyle())
        }
    }
}

private struct ImportFallbackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.sealSurface, in: Circle())
            .overlay {
                Circle().stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.7)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private extension UTType {
    static let ipaArchive = UTType(filenameExtension: "ipa") ?? .data
    static let zipArchive = UTType(filenameExtension: "zip") ?? .archive
}

private struct SealListCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.sealSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.55), lineWidth: 0.8)
            }
    }
}

private extension View {
    func sealListCard(cornerRadius: CGFloat) -> some View {
        modifier(SealListCardModifier(cornerRadius: cornerRadius))
    }
}
