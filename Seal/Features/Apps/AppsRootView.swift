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
    /// 全局抽屉仲裁器由 `RootTabView` 持有并注入：应用页抽屉与根层的
    /// 更新抽屉 / 外观抽屉共用同一个仲裁域（2026-10-23 统一）。
    @Binding var sheetArbiter: SheetArbiter
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var sealTitleSize = 38
    @State private var mode: ListMode = .installed
    /// 分页连续进度只刷新标签，不让每一帧手势都重建两个应用列表。
    @State private var pagerProgress = CaterpillarTabsProgress(value: 1)
    @State private var detailApp: AppRecord?
    @State private var pendingDeleteApp: AppRecord?
    @State private var installedActionApp: AppRecord?
    @State private var operationAppID: UUID?
    @State private var didResolveInitialMode = false
    /// 系统通知点进来时，SwiftUI 的 sheet host 可能尚未挂载。先等根视图出现，
    /// 再在下一次主循环请求结果抽屉，避免状态已锁住列表而系统 sheet 没有呈现。
    @State private var isResultPresentationHostReady = false
    @State private var hasPendingBackgroundResultPresentation = false
    /// 业务抽屉呈现仲裁：同一时刻只许一张在场，交接串行「关完再开」。
    /// 所有抽屉的呈现/关闭都先过它（判据本体在 `SheetArbiter`，可单测），
    /// 不再靠关后硬等延时或事后强清其他抽屉状态来防抢层。
    /// 仲裁器本体在 `RootTabView`（见上方注入的属性），本页只消费。
    /// 已安装操作抽屉点「续签」后、等操作抽屉关闭完成才点火的续签目标。
    /// 载荷先存这里，`installedActionSheetDismissed` 收到关闭完成事件后才消费。
    @State private var deferredRenewalApp: AppRecord?

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
                        onDismissProgress: { viewModel.dismissImportProgress() },
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
            .alert("已是最新版", isPresented: Binding(
                get: { viewModel.alreadyInstalledDraft != nil },
                set: { if !$0 { viewModel.alreadyInstalledDraft = nil } }
            )) {
                Button("知道了") {
                    viewModel.alreadyInstalledDraft = nil
                    Task { await viewModel.cancelImport() }
                }
            } message: {
                if let draft = viewModel.alreadyInstalledDraft {
                    Text("\(draft.parsedIPA.name) v\(draft.parsedIPA.version) 已安装，无需重复更新")
                }
            }
            .sheet(item: operationSheetItem, onDismiss: operationSheetDismissed) { app in
                AppSigningSheet(
                    app: app,
                    viewModel: viewModel,
                    onFinish: { _ in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = .installed }
                    },
                    onDelete: {
                        if app.replacesInstalledAppID != nil {
                            Task { _ = await viewModel.delete(app) }
                        } else {
                            pendingDeleteApp = app
                        }
                    }
                )
                .presentationDetents(operationDetents(for: app))
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.hidden)
            }
            .sheet(item: installedActionSheet, onDismiss: installedActionSheetDismissed) { app in
                InstalledAppActionSheet(
                    app: app,
                    viewModel: viewModel,
                    onRenew: {
                        // 交接走仲裁：登记「操作抽屉待呈现」后只关当前抽屉，
                        // 等它的关闭完成事件（installedActionSheetDismissed）
                        // 才点火续签。不再硬等 250ms 猜关闭动画是否结束 ——
                        // 旧写法既可能等不够（旧 item 重呈现一帧），也白慢一截。
                        deferredRenewalApp = app
                        _ = sheetArbiter.request(.operation)
                        installedActionApp = nil
                        detailApp = nil
                    }
                )
                .presentationDetents(installedOperationDetents)
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.hidden)
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
            .sheet(item: batchRefreshSheet, onDismiss: batchSheetDismissed) { _ in
                BatchRefreshView(viewModel: viewModel)
                    .presentationDetents([.height(620), .large])
            }
            .sheet(item: $detailApp, onDismiss: {
                _ = sheetArbiter.sheetDidDismiss(.detail)
            }) { app in
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
                // 启动时用设备隧道地址触发 LocalDevVPN 已配置的按需连接；探测独立运行，不阻塞首屏。
                Task { _ = await LocalDevVPNOnDemandActivator().probeTunnel() }
                // 后台续签已经得到终态时，通知进入必须先展示结果；不能被启动维护、
                // 设备核验或列表加载拖住，造成用户得点几次应用才看到抽屉。
                requestSettledBackgroundBatchResultPresentation()
                await viewModel.syncSelfRecordOnLaunch()
                await viewModel.reloadSelfRecordSnapshot()
                await settingsViewModel.load()
                // ── 启动关键路径（阻塞首屏，只做最少必要）──
                // 记录恢复（设备扫描发现 App）是新安装时列表有数据的唯一来源，
                // 必须在首屏前完成。孤儿清理 / 描述文件清理 / 设备核验不阻塞首屏，
                // 放后台延迟执行（用户操作开始时自动中止，下次再跑）。
                await viewModel.runEssentialMaintenanceIfIdle()
                // 再恢复其余被中断项：上一轮留下的 running 项必须在任何新一轮续签覆盖队列文件之前
                // 降级为 unknown，否则它们既不会被重试也不会被清理，永久停在「运行中」。
                await viewModel.recoverInterruptedQueueIfNeeded()
                // Seal 自替换会更新本机记录、证书身份和应用版本；启动时统一强制重载，
                // 避免新进程先展示旧快照，等用户手动刷新才纠正。
                await viewModel.load(force: true)
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
                    await viewModel.syncSelfRecordOnLaunch()
                    await viewModel.reloadSelfRecordSnapshot()
                    await viewModel.refreshInstalledApps(
                        userInitiated: false,
                        retryDeviceRecordRecovery: true
                    )
                    if mode == .unsigned {
                        await viewModel.refreshUnsignedApps()
                    }
                }
            }
            .onChange(of: viewModel.isBatchRefreshSheetPresented) { isPresented in
                guard isPresented else { return }
                // 批量抽屉（进行中或结果）请求呈现：先过仲裁。台上无人直接上台；
                // 有别的抽屉在场时只关那一张、登记待呈现，等它的关闭完成事件
                // 再上台 —— 不再无条件强清全部抽屉状态（旧补丁会把无关状态一起清掉，
                // 且关与开同帧发生仍可能抢层）。
                if sheetArbiter.request(.batchResult) == .dismissCurrentThenPresentPending {
                    dismissCurrentArbitratedSheet()
                }
            }
            .onChange(of: viewModel.hasPendingBatchResultAwaitingPresentation) { isAwaiting in
                // 持久化结果已被登记待呈现（冷/暖启动的 load、Seal 结算改写载荷
                // 都会走到这里）：若宿主已就绪且 App 在前台，立即经呈现层 flush，
                // 不必等下一次 scenePhase / 通知事件。
                guard isAwaiting else { return }
                requestSettledBackgroundBatchResultPresentation()
            }
            .onChange(of: viewModel.selectedOperationApp) { app in
                // 操作抽屉的呈现请求来自 ViewModel 多个入口（列表点按、续签点火、
                // 自动续跑）：统一在这里向仲裁登记。台上是批量结果时它只登记为
                // 待呈现 —— 绑定层门禁挡住它抢层，等结果抽屉关闭完成后再上台；
                // 刻意不去关结果抽屉：关它等于把未被用户看过的结果按「已关闭」
                // 结算（清载荷），新操作不配替用户消费结果。
                guard app != nil else {
                    sheetArbiter.cancelPending(.operation)
                    return
                }
                if sheetArbiter.request(.operation) == .dismissCurrentThenPresentPending,
                   sheetArbiter.current != .batchResult {
                    dismissCurrentArbitratedSheet()
                }
            }
            .onChange(of: sheetArbiter.pending) { pending in
                // 根层抽屉（更新 / 外观）在仲裁里登记待呈现且台上是本页抽屉时，
                // 由本页负责关掉自己那张，等关闭完成事件把台面让给根层。
                // 只认根层两种待呈现：本页内部的交接（续签点火、批量结果）
                // 各有自己的关抽屉路径，不在这里重复触发。批量结果在场时
                // 根层请求在认领侧就已被拦下（不会登记为待呈现），这里再
                // 兜一层：绝不替用户关掉还没看过的结果抽屉。
                guard pending == .appUpdate || pending == .appearance,
                      sheetArbiter.current != .batchResult else { return }
                switch sheetArbiter.current {
                case .operation, .installedAction, .detail:
                    dismissCurrentArbitratedSheet()
                default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: BackgroundRenewalNotificationRoute.opened)) { _ in
                // 快捷指令成功通知的点击是一个明确的用户意图；不要只赌 scenePhase
                // 变化（冷启动和从通知中心回到已在后台的进程时序不同）。
                requestSettledBackgroundBatchResultPresentation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sealRenewalCompleted)) { _ in
                requestSettledBackgroundBatchResultPresentation()
            }
            // 真正要导入时才切到待签名页：
            // 2026-10-09 重设计：覆盖更新（含 Seal 自更新）也进待签名页，不再留在已安装页。
            .onChange(of: viewModel.isImportSheetPresented) { isPresented in
                guard isPresented else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = .unsigned }
            }
            .onChange(of: viewModel.importCompletionCount) { _ in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    mode = viewModel.lastImportCompletedInstalledApp ? .installed : .unsigned
                }
            }
            .onAppear {
                isResultPresentationHostReady = true
                requestSettledBackgroundBatchResultPresentation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sealSelfRecordUpdated)) { _ in
                // 自安装重启后，记录与证书派生状态必须同一轮发布。
                Task {
                    await viewModel.reloadSelfRecordSnapshot()
                    await viewModel.load(force: true)
                }
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
            progress: pagerProgress
        )
        .accessibilityIdentifier("apps-stage-tabs")
    }

    /// 标签点击只改变目标页；连续滚动偏移由分页器几何测量统一驱动下划线。
    private var selectionBinding: Binding<ListMode> {
        Binding(
            get: { mode },
            set: { newValue in
                mode = newValue
            }
        )
    }

    private var appPager: some View {
        GeometryReader { proxy in
            NativeAppsPager(
                selection: pagerSelectionBinding,
                progress: pagerProgress,
                pages: [
                    appPage(.unsigned, apps: viewModel.unsignedApps),
                    appPage(.installed, apps: viewModel.installedApps)
                ]
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var pagerSelectionBinding: Binding<Int> {
        Binding(
            get: { ListMode.allCases.firstIndex(of: mode) ?? 0 },
            set: { index in
                guard ListMode.allCases.indices.contains(index) else { return }
                mode = ListMode.allCases[index]
            }
        )
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
                            Button("查看详情") {
                                if sheetArbiter.request(.detail) == .present(.detail) {
                                    detailApp = app
                                }
                            }
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
            // 先向仲裁登记，台上已有抽屉时不硬开第二张。
            guard sheetArbiter.request(.installedAction) == .present(.installedAction) else {
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
            guard viewModel.presentSettledBackgroundBatchResultIfNeeded() else { return }
            hasPendingBackgroundResultPresentation = false
        }
    }

    /// 批量结果（尤其是通知进入后的已结算结果）拥有抽屉优先级。
    /// 这里在绑定读取侧再做一次门禁，而不只依赖点击时的 guard：SwiftUI 在同一轮
    /// 状态更新里可能已经开始呈现旧的 `installedActionApp`，否则会出现“应用操作一闪，
    /// 随后才显示续签结果”的错序。门禁条件 = 既有结果优先政策 + 仲裁在场资格。
    private var installedActionSheet: Binding<AppRecord?> {
        Binding(
            get: {
                BatchResultPresentationPolicy.shouldPresentInstalledAppAction(
                    hasBatchResultSheet: viewModel.isBatchRefreshSheetPresented,
                    hasInstalledAppAction: installedActionApp != nil
                ) && sheetArbiter.allowsPresentation(of: .installedAction)
                    ? installedActionApp : nil
            },
            set: { newValue in
                if newValue == nil || viewModel.isBatchRefreshSheetPresented == false {
                    installedActionApp = newValue
                }
            }
        )
    }

    /// 操作抽屉绑定：仲裁不在场时不呈现（例如批量结果抽屉在场时
    /// ViewModel 侧刚置了 `selectedOperationApp`，它只登记为待呈现，
    /// 等结果抽屉关闭完成、仲裁把它转正后才真正上台）。
    private var operationSheetItem: Binding<AppRecord?> {
        Binding(
            get: {
                sheetArbiter.allowsPresentation(of: .operation)
                    ? viewModel.selectedOperationApp
                    : nil
            },
            set: { newValue in
                viewModel.selectedOperationApp = newValue
            }
        )
    }

    /// 已安装操作抽屉关闭完成：向仲裁报到，并消费等待中的交接。
    /// - 待呈现是操作抽屉（点「续签」的交接）：此刻才点火续签，续签抽屉
    ///   随后经 `selectedOperationApp` 的仲裁登记上台。
    /// - 待呈现是批量结果：什么都不用做，仲裁已把它转正，
    ///   `batchRefreshSheet` 绑定随状态变化自然呈现。
    private func installedActionSheetDismissed() {
        installedActionApp = nil
        _ = sheetArbiter.sheetDidDismiss(.installedAction)
        consumeDeferredRenewalIfArbitrationAllows()
    }

    /// 批量抽屉关闭完成：向仲裁报到。若有操作抽屉在待呈现，
    /// 仲裁已把它转正，`operationSheetItem` 绑定随状态变化自然呈现。
    private func batchSheetDismissed() {
        _ = sheetArbiter.sheetDidDismiss(.batchResult)
        consumeDeferredRenewalIfArbitrationAllows()
    }

    /// 消费「等交接的续签点火」：只有仲裁台上是操作抽屉（或空台可立即认领）
    /// 时才点火；被批量结果抢先时保留到那张抽屉关闭后再消费，不静默丢掉。
    private func consumeDeferredRenewalIfArbitrationAllows() {
        guard let app = deferredRenewalApp else { return }
        if sheetArbiter.current == nil {
            _ = sheetArbiter.request(.operation)
        }
        guard sheetArbiter.allowsPresentation(of: .operation) else { return }
        deferredRenewalApp = nil
        operationAppID = app.id
        Task { @MainActor in
            await viewModel.beginRenewalDirectly(for: app, overrideAccountID: nil)
            // 点火没能产生操作抽屉（例如账号解析失败提前返回）时释放台面，
            // 否则仲裁会把一个从未出现的抽屉当成在场，后续请求全被排队堵死。
            if viewModel.selectedOperationApp == nil,
               sheetArbiter.current == .operation {
                _ = sheetArbiter.sheetDidDismiss(.operation)
            }
        }
    }

    /// 按仲裁裁决关掉当前在场的那一张抽屉（只关它，不连带清其他状态）。
    private func dismissCurrentArbitratedSheet() {
        switch sheetArbiter.current {
        case .installedAction:
            installedActionApp = nil
        case .detail:
            detailApp = nil
        case .operation:
            viewModel.dismissOperation()
        case .batchResult:
            viewModel.dismissBatchRefresh()
        case .appUpdate, .appearance, nil:
            // 根层抽屉不在本页的关闭职责内（由 RootTabView 处理）。
            break
        }
    }

    /// `.sheet(item:)` 不能直接观察后台批次的临时会话，否则它会把后台“安装中”
    /// 当作前台抽屉。显式呈现开关只在用户回到 Seal、结果已结算后打开。
    private var batchRefreshSheet: Binding<BatchRefreshSession?> {
        Binding(
            get: {
                BatchResultPresentationPolicy.shouldPresentBatchResultSheet(
                    isPresentationRequested: viewModel.isBatchRefreshSheetPresented,
                    hasBatchRefreshSession: viewModel.batchRefreshSession != nil
                ) && sheetArbiter.allowsPresentation(of: .batchResult)
                    ? viewModel.batchRefreshSession : nil
            },
            set: { session in
                if session == nil {
                    viewModel.dismissBatchRefresh()
                }
            }
        )
    }

    private func operationSheetDismissed() {
        // 交接纪律归仲裁：操作抽屉关闭完成后才向仲裁报到，待呈现的抽屉
        // （如批量结果）随之转正。不再在这里强清其他抽屉状态 —— 仲裁保证
        // 同一时刻只有一张在场，能被清的本来就不该同时存在。
        _ = sheetArbiter.sheetDidDismiss(.operation)
        viewModel.dismissOperation()
        consumeDeferredRenewalIfArbitrationAllows()
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
            await viewModel.refreshInstalledApps(
                userInitiated: false,
                retryDeviceRecordRecovery: true
            )
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
        return [.height(CGFloat(660) + extraExtensionHeight)]
    }

    private var installedOperationDetents: Set<PresentationDetent> {
        [.height(560)]
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
