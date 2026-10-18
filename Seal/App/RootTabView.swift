import SwiftUI
// `NSUserActivityTypeLiveActivity` 由 WidgetKit 定义（不是 ActivityKit），
// 只 import ActivityKit 会编译不过。
import WidgetKit

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
    @State private var launchCheckInProgress = false
    @State private var lastLaunchCheckAt: Date?
    @AppStorage("appearance.mode") private var appearanceRawValue = SealAppearance.system.rawValue
    @AppStorage("appearance.accent") private var accentRawValue = SealAccentTheme.system.rawValue
    @AppStorage(SealAccentTheme.customHexStorageKey) private var customAccentHex = SealAccentTheme.defaultCustomHex
    @State private var updateNotice: UpdateNotice?
    @State private var lastUpdateCheckAt: Date?
    @State private var updateCheckInProgress = false

    var body: some View {
        TabView(selection: $selection) {
            AppsRootView(
                viewModel: appsViewModel,
                settingsViewModel: settingsViewModel
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
                onAppearanceThemeRequested: { isAppearanceThemePresented = true },
                onSelfUpdateInstall: { localURL in
                    installSelfUpdate(localURL)
                }
            )
            .tabItem {
                Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
                    .accessibilityIdentifier("root-tab-settings")
            }
            .tag(AppSection.settings)
        }
        .tint(.sealAccent)
        .preferredColorScheme(SealAppearance(rawValue: appearanceRawValue)?.colorScheme)
        .id("\(accentRawValue)-\(customAccentHex)")
        .sealScreenBackground()
        .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in
            openPairingSettings()
        }
        .task {
            await LocalNetworkPermissionPrimer.requestIfNeeded()
            await performLaunchCheck(force: true)
            // 更新抽屉只在首屏与本地检查稳定后呈现，避免启动瞬间叠两层流程。
            try? await Task.sleep(nanoseconds: 700_000_000)
            await performUpdateCheck()
        }
        .onChange(of: appsViewModel.shouldOpenSettings) { shouldOpen in
            guard shouldOpen else { return }
            selection = .settings
            settingsViewModel.requestedRoute = appsViewModel.requestedSettingsRoute
                ?? settingsViewModel.environment.nextSetupStep.map(SettingsRoute.init)
                ?? .account
            appsViewModel.requestedSettingsRoute = nil
            appsViewModel.shouldOpenSettings = false
        }
        .onChange(of: scenePhase) { phase in
            // 进后台停掉 misagent 保活心跳，省电。
            if phase == .background {
                appsViewModel.stopProfileServiceKeepalive()
            }
            guard phase == .active else { return }
            // 只回收已过期的配对活动，不中断仍在系统设置中进行的配对。
            settingsViewModel.discardExpiredPairingPresentationIfNeeded()
            // 此刻设备必然已解锁 ⇒ 是补做钥匙串迁移最可靠的时机（锁屏冷启动那次会被系统拒绝）。
            migrateKeychainAccessibility()
            // 回到前台启动 misagent 保活：保持 profile 服务热状态，下次续签注入更快。
            appsViewModel.startProfileServiceKeepalive()
            Task {
                await performLaunchCheck()
                await performUpdateCheck()
            }
        }
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
        .overlay {
            if let notice = updateNotice {
                UpdateNoticeView(
                    notice: notice,
                    onDismiss: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            updateNotice = nil
                        }
                    },
                    onInstall: { localURL in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            updateNotice = nil
                        }
                        installSelfUpdate(localURL)
                    }
                )
            }
        }
        .sheet(isPresented: $isAppearanceThemePresented) {
            AppearanceThemeSheet(
                appearanceRawValue: $appearanceRawValue,
                accentRawValue: $accentRawValue,
                customAccentHex: $customAccentHex,
                isThemeSheetPresented: $isAppearanceThemePresented
            )
            .presentationDetents([.height(454), .medium])
            .presentationDragIndicator(.hidden)
        }
    }

    /// 从灵动岛 / 锁屏卡片跳回配对页。
    ///
    /// 复用 `requestedRoute` 而不是直接改 `navigationPath`：那条路径由
    /// `SettingsRootView` 持有，`requestedRoute` 是双方既有的约定（`.addAccount`
    /// 也走它），在这里自己推栈会因为视图还没出现而丢失。
    private func openPairingSettings() {
        selection = .settings
        settingsViewModel.requestedRoute = .pairing
        // 人已经回到 App：
        //  - 浮在系统设置上方的配对码横幅没有存在意义了；
        //  - **灵动岛上那枚「配对成功」也要收掉** —— 这是它消失的唯一正常路径。
        settingsViewModel.dismissPairingPresentation()
    }

    private func installSelfUpdate(_ localURL: URL) {
        selection = .apps
        Task {
            let imported = await appsViewModel.importSelfUpdateFile(localURL)
            if imported {
                UpdateIPADownloader.shared.deleteDownloadedFile(at: localURL)
            }
        }
    }

    @MainActor
    private func performUpdateCheck() async {
        guard updateCheckInProgress == false else { return }
        if let last = lastUpdateCheckAt, Date().timeIntervalSince(last) < 60 {
            return
        }
        updateCheckInProgress = true
        defer { updateCheckInProgress = false }
        while scenePhase == .active && hasBlockingUpdateOperation {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard scenePhase == .active else { return }
        lastUpdateCheckAt = Date()
        if case .available(let notice) = await UpdateChecker.shared.check() {
            updateNotice = notice
        }
    }

    private var hasBlockingUpdateOperation: Bool {
        selection != .apps
            || appsViewModel.signingSession != nil
            || appsViewModel.selectedOperationApp != nil
            || appsViewModel.isImporterPresented
            || appsViewModel.isImportSheetPresented
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
