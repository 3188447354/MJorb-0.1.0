import SwiftUI
// `NSUserActivityTypeLiveActivity` 由 WidgetKit 定义（不是 ActivityKit），
// 只 import ActivityKit 会编译不过。
import WidgetKit
import UIKit

struct RootTabView: View {
    @ObservedObject var appsViewModel: AppsViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    let certificateExportHandler: CertificateExportHandler
    /// 回到前台时补做钥匙串可访问性迁移（见 `AppContainer.migrateKeychainAccessibilityIfNeeded`）。
    ///
    /// 🔴 这个钩子不是锦上添花：进程若在**锁屏**时被快捷指令冷启动，那次迁移会被系统拒绝
    /// （`errSecInteractionNotAllowed`），而保活让这个进程活很久 —— 用户解锁后打开 Seal 时
    /// `SealApp.init()` 不会再跑。没有这个钩子，迁移就一直没有机会做，锁屏续签会继续失败。
    /// 迁移本身幂等（迁过就短路），所以每次回到前台调用都无所谓。
    let migrateKeychainAccessibility: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppSection = .apps
    @State private var isAppearanceThemePresented = false
    @State private var isCustomAccentColorPresented = false
    @State private var shouldPresentCustomAccentColorAfterThemeDismiss = false
    /// 外观抽屉已请求但还没拿到台面（被批量结果挡下或正等交接）时的意愿登记，
    /// 台面空出/转正时凭它补呈现，见 `claimRootSheet`。
    @State private var wantsAppearanceSheet = false
    /// 更新提示遇到签名、续签、导入或其他抽屉时只暂缓，不打断当前操作。
    @State private var wantsUpdateSheet = false
    @State private var launchCheckInProgress = false
    @State private var lastLaunchCheckAt: Date?
    @StateObject private var updateCoordinator = UpdatePresentationCoordinator()
    /// 全局抽屉仲裁器：根层持有，注入应用页共用 —— 更新抽屉、外观抽屉与
    /// 应用页四张业务抽屉同一时刻只许一张在场（2026-10-23 统一仲裁域）。
    @State private var sheetArbiter = SheetArbiter()
    @AppStorage("appearance.mode") private var appearanceRawValue = SealAppearance.system.rawValue
    @AppStorage("appearance.accent") private var accentRawValue = SealAccentTheme.system.rawValue
    @AppStorage(SealAccentTheme.customHexStorageKey) private var customAccentHex = SealAccentTheme.defaultCustomHex
    @AppStorage(PairingCodeNotification.pendingOpenKey) private var hasPendingPairingNotificationTap = false
    @AppStorage(BackgroundRenewalNotificationRoute.pendingTapKey)
    private var hasPendingBackgroundRenewalNotificationTap = false
    @AppStorage(BackgroundRenewalNotificationRoute.pendingTapRevisionKey)
    private var backgroundRenewalNotificationTapRevision = 0
    @State private var pendingUpdateInstallURL: URL?
    /// 相同完整性问题组合只提示一次，正常更新后不重复弹窗。
    @AppStorage("integrityWarningDismissedSignature") private var integrityWarningDismissedSignature = ""
    /// 自检告警（2026-10-25）：启动时跑一次，只对尚未确认过的问题组合提示。
    @State private var tamperCheckDone = false
    @State private var tamperFindings: [AppIntegrityIssue] = []
    @State private var isTamperWarningPresented = false

    var body: some View {
        let update = updatePresentation(mainTabs)
        let lifecycle = lifecycleHandling(update)
        let operationRouting = operationRouting(lifecycle)
        let urls = urlHandling(operationRouting)
        let appearance = appearancePresentation(urls)
        return integrityPresentation(appearance)
    }

    private func updatePresentation<Content: View>(_ content: Content) -> some View {
        content
        .tint(.sealAccent)
        .preferredColorScheme(SealAppearance(rawValue: appearanceRawValue)?.colorScheme)
        .toolbar(updateCoordinator.presentedNotice == nil ? .visible : .hidden, for: .tabBar)
        .sealScreenBackground()
        .background {
            Color.clear
                .sheet(item: updateNoticeItem, onDismiss: installPendingUpdateIfNeeded) { notice in
                    UpdateNoticeView(
                        notice: notice,
                        onDismiss: {
                            updateCoordinator.dismissNotice()
                        },
                        onInstall: { localURL in
                            pendingUpdateInstallURL = localURL
                            updateCoordinator.dismissNotice()
                        }
                    )
                    .onAppear {
                        updateCoordinator.markNoticePresented(version: notice.version)
                    }
                }
        }
    }

    private func lifecycleHandling<Content: View>(_ content: Content) -> some View {
        content
        .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in
            openPairingSettings()
        }
        .onChange(of: hasPendingPairingNotificationTap) { hasPendingTap in
            guard hasPendingTap else { return }
            schedulePendingPairingScreenRequest()
        }
        .onChange(of: backgroundRenewalNotificationTapRevision) { _, _ in
            routeToAppsForPendingBackgroundRenewalResult()
        }
        .task {
            updateCoordinator.sceneDidChange(isActive: scenePhase == .active)
            schedulePendingPairingScreenRequest()
            routeToAppsForPendingBackgroundRenewalResult()
            await LocalNetworkPermissionPrimer.requestIfNeeded()
            await performLaunchCheck(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            schedulePendingPairingScreenRequest()
            routeToAppsForPendingBackgroundRenewalResult()
        }
    }

    private func operationRouting<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: appsViewModel.shouldOpenSettings) { shouldOpen in
            guard shouldOpen else { return }
            selection = .settings
            settingsViewModel.requestedRoute = appsViewModel.requestedSettingsRoute
                ?? settingsViewModel.environment.nextSetupStep.map(SettingsRoute.init)
                ?? .account
            appsViewModel.requestedSettingsRoute = nil
            appsViewModel.shouldOpenSettings = false
        }
        .onChange(of: appsViewModel.shouldOpenApps) { shouldOpen in
            guard shouldOpen else { return }
            // 被双重认证中断的签名自动续跑：切回「应用」页，
            // 签名抽屉由 `selectedOperationApp` 在那边呈现。
            selection = .apps
            appsViewModel.shouldOpenApps = false
        }
        .onChange(of: scenePhase) { phase in
            updateCoordinator.sceneDidChange(isActive: phase == .active)
            guard phase == .active else { return }
            schedulePendingPairingScreenRequest()
            routeToAppsForPendingBackgroundRenewalResult()
            // 只回收已过期的配对活动，不中断仍在系统设置中进行的配对。
            settingsViewModel.discardExpiredPairingPresentationIfNeeded()
            // 此刻设备必然已解锁 ⇒ 是补做钥匙串迁移最可靠的时机（锁屏冷启动那次会被系统拒绝）。
            migrateKeychainAccessibility()
            Task {
                await performLaunchCheck()
                presentDeferredUpdateIfPossible()
            }
        }
        .onChange(of: updateCoordinator.presentedNotice?.id) { _, noticeID in
            guard noticeID != nil else {
                wantsUpdateSheet = false
                sheetArbiter.cancelPending(.appUpdate)
                return
            }
            // 自动更新提示等待当前操作自然结束，不通过仲裁器关闭签名/续签抽屉。
            claimRootSheet(.appUpdate)
        }
        .onChange(of: sheetArbiter.current) { current in
            // 外观抽屉经交接转正：此刻才真正置呈现状态。
            if current == .appearance, wantsAppearanceSheet {
                wantsAppearanceSheet = false
                isAppearanceThemePresented = true
            }
            // 台面空出来时补认领：认领时被批量结果挡下（不替用户消费未看过的
            // 结果）的根层抽屉，在结果抽屉关闭后于此重新认领。
            guard current == nil else { return }
            if updateCoordinator.presentedNotice != nil || wantsUpdateSheet {
                presentDeferredUpdateIfPossible()
            } else if wantsAppearanceSheet {
                claimRootSheet(.appearance)
            }
        }
        .onChange(of: sheetArbiter.pending) { pending in
            guard pending == .batchResult else { return }
            if sheetArbiter.current == .appUpdate {
                updateCoordinator.dismissNotice()
            } else if sheetArbiter.current == .appearance {
                wantsAppearanceSheet = false
                dismissRootArbitratedSheet()
            }
        }
        .onChange(of: appsViewModel.selectedOperationApp) { _, app in
            if app == nil { presentDeferredUpdateIfPossible() }
        }
        .onChange(of: appsViewModel.phase) { _, phase in
            if phase == .idle { presentDeferredUpdateIfPossible() }
        }
        .onChange(of: appsViewModel.isBatchRefreshSheetPresented) { _, isPresented in
            if isPresented == false { presentDeferredUpdateIfPossible() }
        }
        .onChange(of: isCustomAccentColorPresented) { isPresented in
            // 自定义颜色浮层关闭且主题抽屉没有接续打开时，外观认领释放。
            guard isPresented == false,
                  isAppearanceThemePresented == false,
                  sheetArbiter.current == .appearance else { return }
            _ = sheetArbiter.sheetDidDismiss(.appearance)
        }
    }

    private func urlHandling<Content: View>(_ content: Content) -> some View {
        content
        .onOpenURL { url in
            if LocalDevVPNLink.isCallback(url) {
                if appsViewModel.hasPendingVPNRecovery {
                    selection = .apps
                }
                Task {
                    await settingsViewModel.testLocalDevVPN()
                    await appsViewModel.resumePendingVPNAction()
                    await performLaunchCheck(force: true)
                }
                return
            }

            // LiveContainer 等外部应用请求导出签名证书
            if certificateExportHandler.canHandle(url) {
                certificateExportHandler.handle(url)
                return
            }

            // 点灵动岛 / 锁屏卡片跳回 Seal（`widgetURL` 给的 `seal://pairing`）。
            //
            // ⚠️ 必须并入**这一个** `onOpenURL`：SwiftUI 里同一个视图挂两个
            //    `onOpenURL` 是后者覆盖前者，分开放会静默吃掉上面的 LocalDevVPN 回调。
            //
            // 另一条路径 `onContinueUserActivity(NSUserActivityTypeLiveActivity)` 是
            // 在**没有** `widgetURL` 时系统才会走的；我们给了 deep link，所以正常走这里，
            // 但两条都接上，避免以后有人去掉 `widgetURL` 时变成「打开了 App 停在首页」。
            if url.scheme == PairingDeepLink.scheme, url.host == PairingDeepLink.host {
                openPairingSettings()
                return
            }

            guard url.isFileURL else { return }
            selection = .apps
            Task { await appsViewModel.importSelectedFile(url) }
        }
    }

    private func appearancePresentation<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $isAppearanceThemePresented, onDismiss: {
            if shouldPresentCustomAccentColorAfterThemeDismiss {
                // 接续打开自定义颜色浮层：同属外观认领，不释放台面，
                // 浮层关闭时才向仲裁报到（见 isCustomAccentColorPresented 的 onChange）。
                shouldPresentCustomAccentColorAfterThemeDismiss = false
                isCustomAccentColorPresented = true
            } else {
                _ = sheetArbiter.sheetDidDismiss(.appearance)
            }
        }) {
            AppearanceThemeSheet(
                appearanceRawValue: $appearanceRawValue,
                accentRawValue: $accentRawValue,
                customAccentHex: $customAccentHex,
                onCustomColorRequested: {
                    shouldPresentCustomAccentColorAfterThemeDismiss = true
                    isAppearanceThemePresented = false
                }
            )
            .presentationDetents([.height(454), .medium])
            .presentationDragIndicator(.hidden)
        }
        .overlay {
            if isCustomAccentColorPresented {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .transition(.opacity)
                CustomAccentColorEditor(
                    customHex: $customAccentHex,
                    accentRawValue: $accentRawValue,
                    isPresented: $isCustomAccentColorPresented,
                    onComplete: {},
                    onCancel: { isAppearanceThemePresented = true }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isCustomAccentColorPresented)
        // 自检警告：只提示、不锁死；同一版本的问题组合确认后不重复打断。
    }

    private func integrityPresentation<Content: View>(_ content: Content) -> some View {
        content
        .alert("检测到未知代码组件", isPresented: $isTamperWarningPresented) {
            Button("知道了", role: .cancel) {
                integrityWarningDismissedSignature = currentIntegrityWarningSignature
            }
        } message: {
            Text(integrityWarningMessage)
        }
        .onAppear {
            // UI 测试期间不显示启动自检警告，避免挡住既有用例。
            let isUITesting = ProcessInfo.processInfo.arguments.contains(uiTestingAgreementAcceptedArgument)
            if !tamperCheckDone {
                tamperCheckDone = true
                tamperFindings = AppIntegrityCheck.liveFindings()
                if !isUITesting, tamperFindings.isEmpty == false {
                    let paths = tamperFindings.map(\.imagePath)
                    Task { await settingsViewModel.recordIntegrityFindingPaths(paths) }
                }
            }
            guard !isUITesting else { return }
            if shouldPresentIntegrityWarning { isTamperWarningPresented = true }
        }
    }


    private var mainTabs: some View {
        TabView(selection: $selection) {
            AppsRootView(
                viewModel: appsViewModel,
                settingsViewModel: settingsViewModel,
                sheetArbiter: $sheetArbiter,
                isActiveTab: selection == .apps,
                onPageModalDismissed: { presentDeferredUpdateIfPossible() }
            )
            .tabItem {
                Label(AppSection.apps.title, systemImage: AppSection.apps.systemImage)
                    .accessibilityIdentifier("root-tab-apps")
            }
            .tag(AppSection.apps)

            SettingsRootView(
                viewModel: settingsViewModel,
                relatedApps: appsViewModel.apps,
                certificateExportHandler: certificateExportHandler,
                onAppearanceThemeRequested: { claimRootSheet(.appearance) },
                updateCoordinator: updateCoordinator
            )
            .tabItem {
                Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
                    .accessibilityIdentifier("root-tab-settings")
            }
            .tag(AppSection.settings)
        }
    }

    private var currentIntegrityWarningSignature: String {
        let identifiers = tamperFindings.map(\.warningIdentifier).sorted().joined(separator: ",")
        return identifiers
    }

    private var integrityWarningMessage: String {
        let components = Array(Set(tamperFindings.map(\.componentName))).sorted()
        guard components.isEmpty == false else {
            return "Seal 发现未识别的动态库正在运行。请检查来源，必要时导出日志反馈。"
        }
        return "Seal 发现未识别的动态库：\(components.joined(separator: "、"))。请检查来源，必要时导出日志反馈。"
    }

    private var shouldPresentIntegrityWarning: Bool {
        currentIntegrityWarningSignature.isEmpty == false
            && currentIntegrityWarningSignature != integrityWarningDismissedSignature
    }

    /// 从灵动岛 / 锁屏卡片跳回配对页。
    ///
    /// 复用 `requestedRoute` 而不是直接改 `navigationPath`：那条路径由
    /// `SettingsRootView` 持有，`requestedRoute` 是双方既有的约定（`.addAccount`
    /// 也走它），在这里自己推栈会因为视图还没出现而丢失。
    private func openPairingSettings() {
        selection = .settings
        settingsViewModel.requestedRoute = .pairing
        // 人已经回到 App：清掉通知回退；配对进行中保留码，成功或失败态立即收起。
        settingsViewModel.handlePairingPresentationOpen()
    }

    /// 通知点击回调可能赶在 UIKit 保存/恢复场景快照期间执行。
    /// 等应用稳定处于前台后再消费持久化路由，避免在状态恢复事务中改 SwiftUI 状态。
    private func schedulePendingPairingScreenRequest() {
        guard PairingCodeNotification.hasPendingPairingScreenRequest else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard scenePhase == .active,
                  PairingCodeNotification.consumePairingScreenRequest() else { return }
            openPairingSettings()
        }
    }

    /// 后台续签通知由应用页承接结果抽屉。通知可能从任意已选标签页打开 Seal，
    /// 因此在场景进入前台后先切回应用页，再由 AppsRootView 等宿主稳定后呈现结果。
    private func routeToAppsForPendingBackgroundRenewalResult() {
        guard scenePhase == .active,
              hasPendingBackgroundRenewalNotificationTap,
              BackgroundRenewalNotificationRoute.hasPendingTap else { return }
        // Do not mutate tab or sheet state from the notification delegate callback or
        // inside UIKit's scene-restoration transaction. The request is already durable;
        // one main-actor turn lets the restored scene settle without adding a timed delay.
        Task { @MainActor in
            await Task.yield()
            guard scenePhase == .active,
                  hasPendingBackgroundRenewalNotificationTap,
                  BackgroundRenewalNotificationRoute.hasPendingTap else { return }
            if selection != .apps {
                selection = .apps
                appsViewModel.noteBackgroundRenewalResultPresentation(
                    "续签通知点击后已切换到应用页，等待结果抽屉呈现"
                )
            }

            // A notification tap is an explicit request to see its result. Dismiss
            // passive root sheets; active signing / renewal work remains untouched.
            if sheetArbiter.current == .appUpdate {
                updateCoordinator.dismissNotice()
            } else if sheetArbiter.current == .appearance {
                wantsAppearanceSheet = false
                dismissRootArbitratedSheet()
            }
        }
    }

    private func installSelfUpdate(_ localURL: URL) {
        selection = .apps
        Task {
            let staged = await appsViewModel.importSelfUpdateFile(localURL)
            // 只有导入器确认更新包已进入受管理事务后才删除下载副本；失败时保留原文件，
            // 用户可以直接重试，不会因一次临时错误丢掉已下载的 IPA。
            if staged {
                UpdateIPADownloader.shared.clearCompletedDownload(for: localURL)
                UpdateIPADownloader.shared.deleteDownloadedFile(at: localURL)
            }
        }
    }

    private func installPendingUpdateIfNeeded() {
        // 取消/关闭更新抽屉后不立刻抬出排队中的第二张抽屉。
        // 已完成的批量结果仍保存在本机，用户后续进入应用页时可再次打开。
        wantsUpdateSheet = false
        let shouldPromoteTappedResult = BackgroundRenewalNotificationRoute.hasPendingTap
            && sheetArbiter.pending == .batchResult
        _ = sheetArbiter.sheetDidDismiss(
            .appUpdate,
            promotingPending: shouldPromoteTappedResult
        )
        guard let localURL = pendingUpdateInstallURL else { return }
        pendingUpdateInstallURL = nil
        installSelfUpdate(localURL)
    }

    /// 更新抽屉的呈现绑定：协调器持有「有更新可提示」，仲裁决定「现在能不能上台」。
    /// 呈现前会先等业务抽屉和应用页系统呈现层结束，避免更新提示打断用户操作。
    private var updateNoticeItem: Binding<UpdateNotice?> {
        Binding(
            get: {
                sheetArbiter.allowsPresentation(of: .appUpdate)
                    ? updateCoordinator.presentedNotice
                    : nil
            },
            set: { newValue in
                if newValue == nil {
                    updateCoordinator.presentedNotice = nil
                }
            }
        )
    }

    /// 根层抽屉（更新 / 外观）向全局仲裁认领台面。
    ///
    /// 批量结果抽屉在场时一律排队：不登记待呈现、更不关它 —— 未被用户
    /// 看过的结果不能被新抽屉替他消费（与应用页既有纪律同源）；台面空出
    /// 后由 `sheetArbiter.current` 的 onChange 补认领。更新抽屉的排队凭
    /// `presentedNotice` 还在，外观的排队凭 `wantsAppearanceSheet`。
    private func claimRootSheet(_ sheet: ArbitratedSheet) {
        if sheet == .appUpdate {
            wantsUpdateSheet = true
            // 当前有抽屉或应用页自己的系统呈现层时，只记住提示意图。
            // 尤其不能为了更新提示关闭正在进行的签名/续签操作。
            guard sheetArbiter.current == nil,
                  canPresentDeferredUpdate else { return }
        }
        if sheetArbiter.current == .batchResult {
            if sheet == .appearance { wantsAppearanceSheet = true }
            return
        }
        if sheet == .appearance { wantsAppearanceSheet = true }
        switch sheetArbiter.request(sheet) {
        case .present(let claimed):
            if claimed == .appearance {
                wantsAppearanceSheet = false
                isAppearanceThemePresented = true
            } else if claimed == .appUpdate {
                wantsUpdateSheet = false
            }
        case .dismissCurrentThenPresentPending:
            dismissRootArbitratedSheet()
        case .none:
            break
        }
    }

    private var canPresentDeferredUpdate: Bool {
        !appsViewModel.isImporterPresented
            && !appsViewModel.isImportSheetPresented
            && appsViewModel.accountSelectionApp == nil
            && appsViewModel.selectedOperationApp == nil
            && appsViewModel.alreadyInstalledDraft == nil
            && appsViewModel.alertFailure == nil
            && appsViewModel.phase == .idle
            && !appsViewModel.isBatchRefreshSheetPresented
    }

    private func presentDeferredUpdateIfPossible() {
        guard wantsUpdateSheet || updateCoordinator.presentedNotice != nil,
              sheetArbiter.current == nil,
              canPresentDeferredUpdate else { return }
        claimRootSheet(.appUpdate)
    }

    /// 按仲裁裁决关掉根层自己在场的那张抽屉。应用页的抽屉由应用页的
    /// 待呈现观察者负责关，这里只处理外观；更新抽屉不被交接强关，
    /// 它的关闭只走自己的按钮与 onDismiss 报到。
    private func dismissRootArbitratedSheet() {
        guard sheetArbiter.current == .appearance else { return }
        shouldPresentCustomAccentColorAfterThemeDismiss = false
        isAppearanceThemePresented = false
        isCustomAccentColorPresented = false
    }

    @MainActor
    private func performLaunchCheck(force: Bool = false) async {
        guard launchCheckInProgress == false else { return }
        if force == false,
           let lastLaunchCheckAt,
           Date().timeIntervalSince(lastLaunchCheckAt) < 60 {
            return
        }
        launchCheckInProgress = true
        lastLaunchCheckAt = Date()
        defer { launchCheckInProgress = false }

        // AppsRootView 负责应用页启动的严格顺序：自替换身份对账 → 队列恢复 → 读取结果。
        // 这里若并行 load，会让旧的 awaiting 载荷先被展示，首次打开就与结算后的真实状态竞争。
        await settingsViewModel.performLightweightLaunchCheck()
    }

}

extension SettingsRoute {
    init(_ step: EnvironmentSetupStep) {
        switch step {
        case .account: self = .addAccount
        case .pairing: self = .pairing
        }
    }
}
