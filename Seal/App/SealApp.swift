import SwiftUI

@main
@MainActor
struct SealApp: App {
    private let container: AppContainer
    private let notificationPresenter: SealNotificationPresenter

    init() {
        let notificationPresenter = SealNotificationPresenter()
        notificationPresenter.install()
        self.notificationPresenter = notificationPresenter
        let container = AppContainer.live()
        self.container = container
        // App Intent / 后台回调不在 SwiftUI 的视图树里、拿不到 environment
        // ⇒ 把这份容器接出去给它们用（只读，见 `SealAppEnvironment`）。
        SealAppEnvironment.install(container)
        // 后台保活：快捷指令不打开 App 的续签里，只负责「点火」，真正让它跑完的是这个
        // （静音音频无限循环 —— 否则后台窗口只有约 30 秒，大包续签必然半途而废）。
        // 2026-10-05: 新增 stop() 机制，续签完成后通过 sealRenewalCompleted 通知停止，
        // 不再无条件常驻。用户要省电，保活只在需要时运行。
        // 幂等，重复调用无副作用。
        container.backgroundKeepAlive.start()
        // 2026-10-07: 定位保活退役。续签已优化到 4-12 秒，静音音频足够，
        // 定位只费电还挂箭头。LocationKeepAliveService 保留类定义以备后用。
        // 钥匙串可访问性迁移：**必须同步、且必须在任何钥匙串读取之前**。
        // 锁屏下的后台续签要现读账号密钥与 anisette，条目若还是 `WhenUnlocked` 就会失败
        // （真机表现：日志只剩一句 `Seal.KeychainError 1`）。见 `SealKeychainAccessibility`。
        container.migrateKeychainAccessibilityIfNeeded()
    }

    @State private var agreementAccepted = !needsAgreementOnboarding()

    var body: some Scene {
        WindowGroup {
            Group {
                if agreementAccepted {
                    RootTabView(
                        appsViewModel: container.appsViewModel,
                        settingsViewModel: container.settingsViewModel,
                        certificateExportHandler: container.certificateExportHandler,
                        migrateKeychainAccessibility: {
                            container.migrateKeychainAccessibilityIfNeeded()
                        }
                    )
                } else {
                    NavigationStack {
                        AgreementOnboardingView(
                            onAgreed: {
                                agreementAccepted = true
                            },
                            onDeclined: { /* 留在协议页，用户必须同意才能使用 */ }
                        )
                    }
                }
            }
        }
    }
}
