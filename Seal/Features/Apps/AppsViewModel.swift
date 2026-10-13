import Combine
import Foundation
import UIKit
@preconcurrency import Minimuxer

@MainActor
final class AppsViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case committing
    }

    enum SigningChannelStatus: Equatable {
        case idle
        case connecting
        case ready
        case unavailable
    }

    @Published private(set) var apps: [AppRecord]
    @Published private(set) var accounts: [AppleAccountRecord]
    @Published private(set) var fullAccountEmails: [UUID: String] = [:]
    /// æ¯ä¸ª**å·²å®‰è£…**åº”ç”¨çš„ã€Œæœ¬æœºæ˜¯å¦æŒæœ‰å½“å‰è¯ä¹¦ç§é’¥ã€ï¼ˆç•Œé¢åœ¨ã€Œè¯ä¹¦åºåˆ—å·ã€è¡Œä¸‹é¢ç”¨ï¼‰ã€‚
    /// ä¸ `fullAccountEmails` åœ¨**åŒä¸€æ‰¹** Keychain è¯»å–é‡Œç®—å‡ºï¼Œä¸é¢å¤–è¯»ä¸€æ¬¡é’¥åŒ™ä¸²ã€‚
    ///
    /// âš ï¸ **å®ƒå¿…é¡»è·Ÿç€ `apps` èµ°**ï¼šè¿™ä¸ªçŠ¶æ€çš„è¾“å…¥æ˜¯ã€Œè®°å½•é‡Œçš„ `certificateSerialNumber`ã€ï¼Œ
    /// è€Œç»­ç­¾ / è‡ªæ›¿æ¢ç»“ç®—ä¼šæ”¹æ‰é‚£ä¸ªå­—æ®µã€‚åªåœ¨è¿™é‡Œç®—ä¸€æ¬¡ï¼ˆæ—§å®ç°åªå†™åœ¨ `load()` çš„åå°ä»»åŠ¡é‡Œï¼‰
    /// ä¼šå‡ºç°**æ–‡æ¡ˆä¸é¢œè‰²ä¸åŒå¸§**ï¼šè¯¦æƒ…é¡µçš„é¢œè‰²è¯»çš„æ˜¯å½“å‰è®°å½•ã€å·²ç»å˜äº†ï¼Œ
    /// è€Œã€Œéœ€é‡æ–°ç­¾åã€æ–‡æ¡ˆè¯»çš„æ˜¯è¿™ä»½å¿«ç…§ã€è¿˜åœåœ¨æ—§åºåˆ—å·ä¸Šï¼Œè¦ç­‰ä¸‹ä¸€æ¬¡ `load()` æ‰æ¶ˆå¤±
    ///ï¼ˆ2026-10-08 çœŸæœºï¼šé‡æ–°ç»­ç­¾ + å®‰è£…æ›¿æ¢ Seal åæ­£æ˜¯è¿™ä¸ªç°è±¡ï¼‰ã€‚
    /// â‡’ éåˆå§‹åŒ–è·¯å¾„ä¸Šä»»ä½•å†™å…¥ `apps` çš„åœ°æ–¹éƒ½å¿…é¡»ç´§æ¥ç€è°ƒç”¨ `refreshCertAvailability()`ã€‚
    @Published private(set) var localCertificateAvailabilityByAppID:
        [UUID: ProfileOnlyRenewalPolicy.LocalCertificateAvailability] = [:]
    /// ä¸€æ¬¡ Keychain è¯»å–çš„ç»“æœï¼ˆä¸ `fullAccountEmails` åŒæ‰¹ï¼‰ã€‚
    /// å­˜ä¸‹æ¥æ˜¯ä¸ºäº†è®©ä¸Šé¢é‚£ä»½æ´¾ç”ŸçŠ¶æ€èƒ½åœ¨**è®°å½•å˜åŒ–æ—¶**å°±åœ°é‡ç®— â€”â€” ä¸å¿…å†è¯»ä¸€æ¬¡é’¥åŒ™ä¸²ã€‚
    private var accountSecrets: [UUID: AccountSecret] = [:]
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var iconData: [UUID: Data]
    /// è§£ç åçš„å›¾æ ‡ç¼“å­˜ï¼ˆæ€§èƒ½ä¼˜åŒ– 2026-10-04ï¼‰ï¼š`UIImage(data:)` çš„ PNG/JPEG è§£ç 
    /// åœ¨åˆ—è¡¨æ»šåŠ¨æ—¶é‡å¤è§¦å‘ï¼Œè¿™é‡ŒæŒ‰ App ID ç¼“å­˜è§£ç ç»“æœã€‚
    /// ç¡¬ä¸Šé™ 10 å¼ ï¼šNSCache çš„ totalCostLimit å¿…é¡»ä¼  cost æ‰ç”Ÿæ•ˆï¼Œè¿™é‡Œæ‰‹åŠ¨æ§åˆ¶ã€‚
    private let decodedIconCache = NSCache<NSString, UIImage>()
    private var decodedIconOrder: [NSString] = []
    private let decodedIconMaxCount = 10

    /// é—®é¢˜22ä¿®å¤ï¼šå†…å­˜è­¦å‘Šè§‚å¯Ÿè€… tokenï¼Œdeinit æ—¶ç§»é™¤ï¼Œé¿å…è§‚å¯Ÿè€…æ³„æ¼ã€‚
    /// nonisolated(unsafe)ï¼šNotificationCenter çš„ add/removeObserver çº¿ç¨‹å®‰å…¨ï¼›
    /// deinit æ˜¯ééš”ç¦»ä¸Šä¸‹æ–‡ï¼Œä¸èƒ½ç›´æ¥è®¿é—® @MainActor éš”ç¦»å±æ€§ã€‚
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// å–æŒ‡å®š App çš„è§£ç åå›¾æ ‡ï¼ˆèµ° NSCacheï¼Œæœªå‘½ä¸­æ—¶è§£ç å¹¶ç¼“å­˜ï¼‰ã€‚
    /// ç¡¬ä¸Šé™ 10 å¼ ï¼Œè¶…äº†åˆ æœ€æ—§çš„ã€‚
    func decodedIcon(for appID: UUID) -> UIImage? {
        let key = appID.uuidString as NSString
        if let cached = decodedIconCache.object(forKey: key) {
            // é—®é¢˜24ä¿®å¤ï¼šLRUï¼Œå‘½ä¸­æ—¶æŠŠ key ç§»åˆ°æœ«å°¾ï¼Œé¿å…å¸¸ç”¨å›¾æ ‡è¢«è¯¯åˆ 
            if let idx = decodedIconOrder.firstIndex(of: key) {
                decodedIconOrder.remove(at: idx)
                decodedIconOrder.append(key)
            }
            return cached
        }
        guard let data = iconData[appID], let image = UIImage(data: data) else {
            return nil
        }
        if decodedIconOrder.count >= decodedIconMaxCount,
           let oldest = decodedIconOrder.first {
            decodedIconCache.removeObject(forKey: oldest)
            decodedIconOrder.removeFirst()
        }
        // é—®é¢˜11ä¿®å¤ï¼štotalCostLimit åªæœ‰ä¼  cost æ‰ç”Ÿæ•ˆï¼ŒæŒ‰ RGBA ä¼°ç®—å†…å­˜å ç”¨
        let cost = Int(image.size.width * image.size.height * 4)
        decodedIconCache.setObject(image, forKey: key, cost: cost)
        if !decodedIconOrder.contains(key) {
            decodedIconOrder.append(key)
        }
        return image
    }

    /// å›¾æ ‡æ•°æ®æ›´æ–°æ—¶åŒæ­¥å¤±æ•ˆè§£ç ç¼“å­˜ã€‚
    func invalidateDecodedIcon(for appID: UUID) {
        let key = appID.uuidString as NSString
        decodedIconCache.removeObject(forKey: key)
        decodedIconOrder.removeAll { $0 == key }
    }

    /// æ¸…ç©ºè§£ç ç¼“å­˜ï¼ˆåŒæ—¶æ¸…é¡ºåºè¡¨ï¼‰ã€‚
    private func clearDecodedIconCache() {
        decodedIconCache.removeAllObjects()
        decodedIconOrder.removeAll()
    }
    @Published private(set) var phase: Phase
    @Published var isImporterPresented = false
    @Published var isImportSheetPresented: Bool
    @Published private(set) var sheetDraft: ImportDraft?
    @Published private(set) var sheetFailure: ImportFailure?
    /// å¯¼å…¥æ—¶ç”¨æˆ·é€‰çš„è‡ªå®šä¹‰å›¾æ ‡ï¼šrecord å»ºå¥½ååº”ç”¨ï¼ˆ.completed é‡Œï¼‰ã€‚
    @Published var pendingImportIconData: Data?
    /// å¯¼å…¥æ—¶ç”¨æˆ·æ”¹çš„è‡ªå®šä¹‰åç§°ï¼šrecord å»ºå¥½ååº”ç”¨ï¼ˆ.completed é‡Œï¼‰ã€‚
    @Published var pendingImportDisplayName: String?
    /// å·²å®‰è£…åŒ…å†å¯¼å…¥æ—¶çš„ç³»ç»Ÿå¼¹çª—ï¼ˆä¸èµ°æŠ½å±‰ï¼‰ï¼šéç©º â‡’ æ˜¾ç¤º"å·²å®‰è£…"å¼¹çª—ã€‚
    @Published var alreadyInstalledDraft: ImportDraft?
    /// å¯¼å…¥çš„ IPA ä¸æŸæ¡**å·²å®‰è£…**è®°å½•åŒèº«ä»½æ—¶çš„è¦†ç›–æ›´æ–°å€™é€‰ï¼ˆè§ `ImportReplacementPolicy`ï¼‰ã€‚
    /// éç©º â‡’ å¯¼å…¥ç¡®è®¤é¡µç»™ç”¨æˆ·ã€Œè¦†ç›–æ›´æ–° / æ–°å»ºå‰¯æœ¬ã€çš„é€‰æ‹©ï¼Œè€Œä¸æ˜¯ç›´æ¥å…¥åº“ã€‚
    @Published private(set) var importReplacementCandidate: AppRecord?
    @Published var alertFailure: ImportFailure?
    @Published var accountSelectionApp: AppRecord?
    @Published var selectedOperationApp: AppRecord?
    @Published var signingSession: SigningSession?
    @Published var batchRefreshSession: BatchRefreshSession?
    /// åå°å¿«æ·æŒ‡ä»¤ä¹Ÿä¼šå»ºç«‹æ‰¹é‡ä¼šè¯ä»¥æ±‡æ€»ç»“æœï¼Œä½†å®ƒä¸èƒ½è‡ªåŠ¨æŠ¢å å‰å°æŠ½å±‰ã€‚
    @Published private(set) var isBatchRefreshSheetPresented = false
    @Published private(set) var importCompletionCount = 0
    @Published private(set) var lastImportCompletedInstalledApp = false
    @Published var shouldOpenSettings = false
    @Published var requestedSettingsRoute: SettingsRoute?
    @Published private(set) var signingChannelStatus: SigningChannelStatus = .idle
    @Published private(set) var installingCachedPackageAppID: UUID?

    private struct PendingTeamSwitch {
        let app: AppRecord
        let account: AppleAccountRecord
        let requestedBundleIdentifier: String?
        let completionMode: SigningCompletionMode
    }
    private var pendingTeamSwitch: PendingTeamSwitch?

    private let workflow: ImportWorkflow?
    private let appStore: (any AppStore)?
    private let fileStore: AppFileStore?
    private let accountRepository: (any AccountRepository)?
    private let keychain: KeychainVault?
    private let signingCoordinator: SigningCoordinator?
    private let installChannel: (any InstallChannel)?
    private let renewalCoordinator: RenewalCoordinator?
    private let logStore: SealLogStore?
    private let signingHistoryStore: SigningHistoryStore?
    private let notificationScheduler: ExpiryNotificationScheduler?
    private let notificationPreferences: NotificationPreferences?
    private let backgroundRenewalNotifier: BackgroundRenewalNotifier?
    private let signingPreferenceStore: SigningPreferenceStore?
    private let operationCoordinator: OperationCoordinator?
    private let maintenanceJob: AppMaintenanceJob?
    private var signingTask: Task<Void, Never>?
    private var batchRefreshTask: Task<Void, Never>?
    private var channelTask: Task<Bool, Never>?
    /// ã€Œè¿™ä¸€è½®æ‰¹é‡ç»­ç­¾æ˜¯**å¿«æ·æŒ‡ä»¤åœ¨åå°**ç‚¹ç«çš„ã€â€”â€” è¯·æ±‚çº§ç¬æ€æ ‡è®°ã€‚
    ///
    /// ğŸ”´ ç”¨é€”åªæœ‰ä¸€ä¸ªï¼šå†³å®šæ‰¹é‡æ”¶å°¾æ—¶è¦ä¸è¦å‘ç³»ç»Ÿé€šçŸ¥ã€‚ç”¨æˆ·æ˜ç¡®è¦æ±‚
    /// **ã€Œåªæœ‰å¿«æ·æŒ‡ä»¤ç»­ç­¾æˆåŠŸæ‰é€šçŸ¥ï¼ŒSeal å†…æ‰‹åŠ¨ç»­ç­¾ä¸é€šçŸ¥ã€**ã€‚
    ///
    /// ğŸ”´ å¿…é¡»åœ¨ `runBatchRefresh` **å…¥å£å¤„**ï¼ˆä»»ä½• `guard` / `throw` ä¹‹å‰ï¼‰æ¶ˆè´¹å¹¶æ¸…ä½ â€”â€”
    /// é‚£é‡Œå°±æ˜¯ã€Œä¸€è½®ã€çš„èµ·ç‚¹ã€‚æ”¾åˆ°æ‹¿åˆ° `result` ä¹‹åæ¸…ä½æ˜¯é”™çš„ï¼šæœ¬è½®æœ‰ä¸‰æ¡**ä¸äº§ç”Ÿ
    /// `result`** çš„å‡ºå£ï¼ˆ`renewalCoordinator` ç¼ºå¤±ã€æŠ¢ä¸åˆ°æ“ä½œé”ã€`refreshAll` ç›´æ¥æŠ›é”™ï¼‰ï¼Œ
    /// æ ‡è®°ä¼š**è·¨è½®å­˜æ´»** â‡’ ç”¨æˆ·å…ˆè·‘ä¸€æ¬¡å¤±è´¥çš„å¿«æ·æŒ‡ä»¤ã€å†æ‰‹åŠ¨ç‚¹ã€Œç»­ç­¾å…¨éƒ¨ã€æ—¶
    /// å°±ä¼šæ”¶åˆ°ä¸€æ¡æœ¬ä¸è¯¥æœ‰çš„é€šçŸ¥ï¼ˆç”¨æˆ·æ˜ç¡®è¦æ±‚æ‰‹åŠ¨ç»­ç­¾ä¸é€šçŸ¥ï¼‰ã€‚
    private var backgroundTriggerRequested = false
    /// `refreshAll()` æ˜¯æ‰€æœ‰æ‰¹é‡ç»­ç­¾å”¯ä¸€å…¥å£ã€‚åå°å¿«æ·æŒ‡ä»¤åªé€šè¿‡è¿™ä¸ªç¬æ€æ ‡è®°
    /// å‘ŠçŸ¥å…¥å£ä¸è¦å±•ç¤º sheetï¼Œç»ä¸ç»•è¿‡å®ƒçš„å•é£/é˜Ÿåˆ—ä¿æŠ¤ã€‚
    private var backgroundBatchPresentationRequested = false
    /// åå°æ‰¹æ¬¡åªæŒä¹…åŒ–ç»“æœï¼›ç”¨æˆ·å›åˆ° Seal åå†æ¢å¤ä¸ºç»“æœæŠ½å±‰ã€‚
    private var isBackgroundBatchRefresh = false
    /// ã€Œæ’¤é”€å¹¶ç»§ç»­ç­¾åã€ï¼ˆSEAL-CERT-204eï¼‰ç¡®è®¤åï¼Œå› è¯ä¹¦è¢«æ’¤è€Œå¤±æ•ˆã€å¾…è‡ªåŠ¨é‡ç­¾çš„å·²è£… Appã€‚
    /// ä»…æœ¬æ¬¡ç­¾åé‡è¯•æˆåŠŸåæ‰ä¼šæ¶ˆè´¹ï¼›é‡è¯•å¤±è´¥æ—¶æ¸…ç©ºå¹¶æç¤ºæ‰‹åŠ¨ç»­ç­¾ã€‚
    private var certificateSacrificeResignQueue: [UUID] = []
    /// è¯ä¹¦è½®æ¢**å­æµç¨‹**è‡ªå·±çš„é˜¶æ®µç°¿è®° â€”â€” å®ƒ**ä¸å†™è¿›çˆ¶ä¼šè¯**ï¼ˆåˆ¤æ®è§
    /// `SigningStageAttribution`ï¼‰ï¼Œæ‰€ä»¥çˆ¶ä¼šè¯çš„ `InstallStageTimeline` ä¸èƒ½ç»™å®ƒå½“é—¸é—¨ã€‚
    ///
    /// å­æµç¨‹é‡ç­¾çš„æ˜¯**å¦ä¸€ä¸ª** Appï¼ˆé€šå¸¸æ˜¯ Seal è‡ªå·±ï¼‰ï¼Œå®ƒçš„é˜¶æ®µåªç”¨äºä¸¤ä»¶äº‹ï¼š
    /// â‘  ç•™ç—•ï¼ˆ`SEAL-STAGE-001`ï¼‰ï¼›â‘¡ è§¦å‘ Seal è‡ªæ›¿æ¢çš„ã€Œå›ä¸»å±ã€ã€‚
    /// åè€…å¿…é¡»åœ¨ `.installing` ä¸Š**åªè§¦å‘ä¸€æ¬¡**ï¼Œè€ŒåŒä¸€ä¸ªé˜¶æ®µä¼šè¢«é‡å¤æ¨é€
    /// â‡’ è¿™é‡Œå•ç‹¬è®°ã€ŒåŒä¸€ä¸ªå­æµç¨‹ App ä¸Šä¸€æ¬¡æ¨è¿›åˆ°å“ªä¸ªé˜¶æ®µã€ã€‚
    /// æ¯æ¬¡ `startSigning` / `restartSigning` å¼€æ–°ä¼šè¯æ—¶æ¸…ç©ºã€‚
    private var rotationSubflowStage: (appID: UUID, stage: SigningStage)?
    private var pendingVPNAction: PendingVPNAction?
    private var hasLoaded = false
    private var loadGeneration = 0
    // è‡ªæ›´æ–°ä¸‹è½½å¯¼å…¥å®Œæˆåï¼Œè‡ªåŠ¨æ‰“å¼€ç­¾åæŠ½å±‰ï¼ˆä»… Seal è‡ªèº«æ›´æ–°è§¦å‘ï¼‰
    private var autoOpenSigningAfterImport = false

    private enum PendingVPNAction {
        case signing(
            AppRecord,
            accountID: UUID?,
            requestedBundleIdentifier: String?,
            completionMode: SigningCompletionMode
        )
        case batch
    }

    init(
        workflow: ImportWorkflow,
        appStore: any AppStore,
        fileStore: AppFileStore,
        accountRepository: any AccountRepository,
        keychain: KeychainVault,
        signingCoordinator: SigningCoordinator,
        installChannel: any InstallChannel,
        renewalCoordinator: RenewalCoordinator,
        logStore: SealLogStore,
        signingHistoryStore: SigningHistoryStore,
        notificationScheduler: ExpiryNotificationScheduler,
        notificationPreferences: NotificationPreferences,
        backgroundRenewalNotifier: BackgroundRenewalNotifier? = nil,
        signingPreferenceStore: SigningPreferenceStore,
        operationCoordinator: OperationCoordinator? = nil,
        maintenanceJob: AppMaintenanceJob? = nil
    ) {
        self.workflow = workflow
        self.appStore = appStore
        self.fileStore = fileStore
        self.accountRepository = accountRepository
        self.keychain = keychain
        self.signingCoordinator = signingCoordinator
        self.installChannel = installChannel
        self.renewalCoordinator = renewalCoordinator
        self.logStore = logStore
        self.signingHistoryStore = signingHistoryStore
        self.notificationScheduler = notificationScheduler
        self.notificationPreferences = notificationPreferences
        self.backgroundRenewalNotifier = backgroundRenewalNotifier
        self.signingPreferenceStore = signingPreferenceStore
        self.operationCoordinator = operationCoordinator
        self.maintenanceJob = maintenanceJob
        apps = []
        accounts = []
        iconData = [:]
        decodedIconCache.removeAllObjects()
        decodedIconOrder.removeAll()
        decodedIconCache.countLimit = 10
        decodedIconCache.totalCostLimit = 50 * 1024 * 1024
        phase = .idle
        isImportSheetPresented = false
        // é—®é¢˜22ä¿®å¤ï¼šå­˜ä¸‹ tokenï¼Œdeinit æ—¶ç§»é™¤è§‚å¯Ÿè€…
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearDecodedIconCache()
        }
    }

    init(startupFailure: ImportFailure) {
        workflow = nil
        appStore = nil
        fileStore = nil
        accountRepository = nil
        keychain = nil
        signingCoordinator = nil
        installChannel = nil
        renewalCoordinator = nil
        logStore = nil
        signingHistoryStore = nil
        notificationScheduler = nil
        notificationPreferences = nil
        backgroundRenewalNotifier = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        maintenanceJob = nil
        apps = []
        accounts = []
        iconData = [:]
        decodedIconCache.removeAllObjects()
        decodedIconOrder.removeAll()
        phase = .idle
        isImportSheetPresented = false
        alertFailure = startupFailure
    }

    private init(apps: [AppRecord], draft: ImportDraft?) {
        alertFailure = nil
        workflow = nil
        appStore = nil
        fileStore = nil
        accountRepository = nil
        keychain = nil
        signingCoordinator = nil
        installChannel = nil
        renewalCoordinator = nil
        logStore = nil
        signingHistoryStore = nil
        notificationScheduler = nil
        notificationPreferences = nil
        backgroundRenewalNotifier = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        maintenanceJob = nil
        self.apps = apps
        accounts = []
        iconData = [:]
        decodedIconCache.removeAllObjects()
        decodedIconOrder.removeAll()
        phase = .idle
        sheetDraft = draft
        isImportSheetPresented = draft != nil
        hasLoaded = true
    }

    var unsignedApps: [AppRecord] {
        let installedKeys = installedAppIdentityKeys
        return apps
            .filter(\.belongsInUnsignedList)
            // 2026-10-09: è¦†ç›–æ›´æ–°åŒ…ï¼ˆreplacesInstalledAppID éç©ºï¼‰å°±æ˜¯è¦å’Œå·²å®‰è£…çš„åŒ IDï¼Œ
            // ä¸èƒ½ç”¨ identityKeys è¿‡æ»¤æ‰ï¼Œå¦åˆ™å¾…ç­¾åé¡µæ°¸è¿œç©ºã€‚
            .filter { $0.replacesInstalledAppID != nil || $0.userIdentityKeys.isDisjoint(with: installedKeys) }
            .sorted { lhs, rhs in
                if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }


    private var installedAppIdentityKeys: Set<String> {
        apps
            .filter(\.belongsInInstalledList)
            .reduce(into: Set<String>()) { result, app in
                result.formUnion(app.userIdentityKeys)
            }
    }

    var installedApps: [AppRecord] {
        apps.filter(\.belongsInInstalledList)
            .sorted { lhs, rhs in
                if lhs.isSeal != rhs.isSeal { return lhs.isSeal }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }

                let lhsRank = installedSortRank(for: lhs)
                let rhsRank = installedSortRank(for: rhs)
                if lhsRank != rhsRank { return lhsRank > rhsRank }

                let lhsExpiry = lhs.expiryDate ?? .distantPast
                let rhsExpiry = rhs.expiryDate ?? .distantPast
                if lhsExpiry != rhsExpiry { return lhsExpiry > rhsExpiry }

                if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var hasPendingVPNRecovery: Bool {
        pendingVPNAction != nil
    }

    var isBatchRefreshActive: Bool {
        batchRefreshTask != nil
    }

    var availableAccounts: [AppleAccountRecord] {
        accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
    }

    // Kept for existing call sites; locally available accounts remain selectable
    // while offline even if a fresh Portal validation has not run yet.
    var verifiedAccounts: [AppleAccountRecord] { availableAccounts }

    func selectActiveAccount(id: UUID) async {
        guard availableAccounts.contains(where: { $0.id == id }) else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] åˆ‡æ¢æ´»è·ƒè´¦å·: \(id.uuidString.prefix(8))")
        activeAccountID = id
        await signingPreferenceStore?.setActiveAccountID(id)
    }

    func refreshActiveAccountSelection() async {
        guard let signingPreferenceStore else { return }
        let storedID = await signingPreferenceStore.activeAccountID()
        if let storedID, accounts.contains(where: { $0.id == storedID }) {
            activeAccountID = storedID
        } else if let current = activeAccountID, accounts.contains(where: { $0.id == current }) {
            // Keep the in-memory choice. Do not clear it because connectivity changed.
        } else if activeAccountID == nil {
            activeAccountID = availableAccounts.first?.id
            if storedID == nil {
                await signingPreferenceStore.setActiveAccountID(activeAccountID)
            }
        }
    }

    private func installedSortRank(for app: AppRecord, now: Date = Date()) -> Int {
        guard let expiryDate = app.expiryDate else { return 1 }
        return expiryDate > now ? 2 : 0
    }

    func presentOperation(for app: AppRecord) {
        selectedOperationApp = app
    }

    func dismissOperation() {
        guard signingTask == nil else { return }
        selectedOperationApp = nil
        signingSession = nil
    }

    func beginRenewalDirectly(for app: AppRecord, overrideAccountID: UUID? = nil) async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å¼€å§‹ç»­ç­¾: \(app.displayName) (\(app.id.uuidString.prefix(8)))")
        guard app.belongsInInstalledList else {
            presentOperation(for: app)
            return
        }
        // é€‰æ‹©ä¼˜å…ˆçº§ï¼šç”¨æˆ·æ‰‹åŠ¨è¦†ç›– > è®°å½•è´¦å·ï¼ˆ**å¿…é¡»çœŸçš„å­˜åœ¨**ï¼‰> åŒ Team > æ´»è·ƒè´¦å· > ç¬¬ä¸€ä¸ªå¯é€‰è´¦å·ã€‚
        // âš ï¸ åˆ¤æ®é›†ä¸­åœ¨ `RenewalAccountResolver`ï¼šè®°å½•é‡Œçš„ `accountID` å¯èƒ½æ˜¯**æ‚¬ç©ºå¼•ç”¨**
        //ï¼ˆåˆ è¿‡ Apple ID å†é‡æ–°æ·»åŠ ä¹‹åï¼‰ï¼Œæ—§å®ç°åœ¨è¿™é‡Œç›´æ¥é‡‡ç”¨å®ƒ â‡’ ç»­ç­¾å¿…ç„¶è¢«æ‹’ï¼Œ
        // è€Œç•Œé¢è¿˜æ˜¾ç¤ºã€Œæœªè®°å½•Â·è‡ªåŠ¨é€‰æ‹©ã€ã€‚
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: app.accountID,
            recordedTeamID: app.signingTeamID,
            accounts: accounts,
            overrideAccountID: overrideAccountID,
            fallbackAccountID: activeAccountID
        )
        guard let account = await resolvedRenewalAccount(resolution, app: app) else { return }
        await beginSigning(
            for: app,
            accountID: account.id,
            requestedBundleIdentifier: nil,
            completionMode: .signAndInstall
        )
        if signingSession?.app.id == app.id {
            selectedOperationApp = signingSession?.app ?? app
        }
    }

    @discardableResult
    func refreshSigningChannel() async -> Bool {
        if let channelTask {
            return await channelTask.value
        }
        guard let installChannel else {
            signingChannelStatus = .unavailable
            return false
        }
        // ç”¨æˆ·ä¸»åŠ¨åˆ·æ–°ï¼ˆVPN æ¢å¤é‡è¯•ã€è®¾ç½®é¡µåˆ·æ–°ï¼‰ï¼šå…ˆæ¸…ç†”æ–­ï¼Œä¿è¯è¿™æ¬¡çœŸå®é‡è·‘è¯Šæ–­ï¼Œ
        // è€Œä¸æ˜¯æŠŠ 60 ç§’å‰çš„å¤±è´¥åŸæ ·è¿˜å›å»ã€‚
        await installChannel.clearFailureCooldown()

        signingChannelStatus = .connecting
        let task = Task {
            do {
                _ = try await installChannel.start()
                return true
            } catch {
                return false
            }
        }
        channelTask = task
        let ready = await task.value
        channelTask = nil
        signingChannelStatus = ready ? .ready : .unavailable
        return ready
    }

    /// éé˜»å¡ç‰ˆé€šé“å¯åŠ¨ï¼šæŠŠéš§é“è¯Šæ–­ï¼ˆreset + RSD æ¡æ‰‹ + è½®è¯¢ï¼Œå†·å¯åŠ¨æœ€é•¿ 75sï¼‰**ä¸¢åˆ°åå°å¹¶è¡Œ**ï¼Œ
    /// ç«‹åˆ»è¿”å›è®©ç­¾åé“¾è·¯å…ˆè·‘èµ·æ¥ã€‚
    ///
    /// æ—§è¡Œä¸ºæ˜¯åœ¨ç­¾åå‰ `await refreshSigningChannel()`ï¼Œäºæ˜¯æ•´æ®µéš§é“è¯Šæ–­éƒ½å‹åœ¨
    /// ã€Œæ­£åœ¨è¿æ¥è®¾å¤‡ã€è¿™ä¸€ä¸ªé˜¶æ®µä¸Š â€”â€” è¿™æ­£æ˜¯ã€Œç­¾å/ç»­ç­¾å¡åœ¨æ­£åœ¨è¿æ¥å¾ˆä¹…ã€çš„æ ¹å› ã€‚
    /// ç­¾åæœ¬èº«ï¼ˆç”³è¯·è¯ä¹¦ / AppID / æè¿°æ–‡ä»¶ / codesignï¼‰ä¸è¿è®¾å¤‡äº’ä¸ä¾èµ–ï¼Œä¸”å®‰è£…å‰
    /// `SigningCoordinator` ä¼šè‡ªå·± `await installChannel.start()`ï¼ˆ900s ç¼“å­˜å‘½ä¸­å³è¿”å›ï¼Œ
    /// å¹¶ç”±é€šé“å±‚å•é£åˆå¹¶å¹¶å‘å¯åŠ¨ï¼‰ï¼Œæ‰€ä»¥è¿™é‡Œä¸å¿…ç­‰ã€‚
    func beginSigningChannel() {
        guard channelTask == nil, let installChannel else { return }
        signingChannelStatus = .connecting
        let task = Task { [weak self] () -> Bool in
            let ready: Bool
            do {
                _ = try await installChannel.start()
                ready = true
            } catch {
                ready = false
            }
            await MainActor.run {
                self?.signingChannelStatus = ready ? .ready : .unavailable
                self?.channelTask = nil
            }
            return ready
        }
        channelTask = task
    }

    /// å¯åŠ¨ misagent ä¿æ´»å¿ƒè·³ï¼ˆ2026-10-04 é€šé“ä¼˜åŒ–ï¼‰ã€‚
    ///
    /// App å›åˆ°å‰å°æ—¶è°ƒç”¨ï¼šå®šæœŸè½»é‡é¢„çƒ­ profile æœåŠ¡ï¼Œä¿æŒ misagent çƒ­çŠ¶æ€ï¼Œ
    /// ä¸‹æ¬¡ç»­ç­¾æ³¨å…¥ä¸ç”¨é‡æ–°å»ºæœåŠ¡è¿æ¥ã€‚è¿›åå°æ—¶ `stopProfileServiceKeepalive()` åœæ‰ã€‚
    func startProfileServiceKeepalive() {
        guard let installChannel else { return }
        Task {
            await ProfileOnlyProvisioningProfileInstaller.shared.startKeepalive(using: installChannel)
        }
    }

    /// åœæ­¢ misagent ä¿æ´»å¿ƒè·³ã€‚App è¿›åå°æ—¶è°ƒç”¨ã€‚
    func stopProfileServiceKeepalive() {
        Task {
            await ProfileOnlyProvisioningProfileInstaller.shared.stopKeepalive()
        }
    }

    /// åŠ è½½åº”ç”¨åˆ—è¡¨ã€‚**åªè¯»**ï¼šä¸å†™ DBã€ä¸åŠ¨æ–‡ä»¶ã€‚
    ///
    /// è®°å½•æ¢å¤ / Seal è‡ªæ³¨å†Œ / å­¤å„¿æ–‡ä»¶æ¸…ç†æ›¾ç»æŒ‚åœ¨è¿™é‡Œï¼Œä¼šè®©ã€Œçœ‹åˆ—è¡¨ã€è¿™ç§çº¯è¯»å–åŠ¨ä½œ
    /// é¡ºæ‰‹æ”¹æ•°æ®ï¼Œå¹¶ä¸ç”¨æˆ·æ­£åœ¨è¿›è¡Œçš„ç­¾å / å®‰è£…äº¤é”™ã€‚å®ƒä»¬ç°åœ¨å½’ `runMaintenanceIfIdle()`ï¼Œ
    /// ç”±å¯åŠ¨æµç¨‹åœ¨ç©ºé—²æ—¶å•ç‹¬æ‰§è¡Œã€‚
    func load(force: Bool = false) async {
        guard force || hasLoaded == false, let appStore else { return }
        loadGeneration &+= 1
        let generation = loadGeneration

        do {
            let fetched = try await appStore.fetchAll()
            guard generation == loadGeneration else { return }

            var fetchedAccounts = try await accountRepository?.fetchAll() ?? []
            guard generation == loadGeneration else { return }
            fetchedAccounts = try await repairLegacyAccountStatuses(fetchedAccounts)
            guard generation == loadGeneration else { return }

            let preferredAccountID: UUID?
            if let signingPreferenceStore {
                preferredAccountID = await signingPreferenceStore.activeAccountID()
            } else {
                preferredAccountID = nil
            }
            guard generation == loadGeneration else { return }

            let selectableAccounts = fetchedAccounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
            let resolvedAccountID: UUID?
            if let preferredAccountID, fetchedAccounts.contains(where: { $0.id == preferredAccountID }) {
                resolvedAccountID = preferredAccountID
            } else if let current = activeAccountID, fetchedAccounts.contains(where: { $0.id == current }) {
                resolvedAccountID = current
            } else {
                resolvedAccountID = selectableAccounts.first?.id
                if preferredAccountID == nil {
                    await signingPreferenceStore?.setActiveAccountID(resolvedAccountID)
                }
            }

            // å¿«é€Ÿæ˜¾ç¤ºåº”ç”¨åˆ—è¡¨
            apps = fetched
            // 2026-10-09 é‡è®¾è®¡ï¼šè¯ä¹¦å¯ç”¨æ€§ä¸åœ¨è¿™é‡Œé‡ç®—ã€‚æ­¤æ—¶ accountSecrets è¿˜æ˜¯æ—§çš„ï¼Œ
            // ç”¨æ—§é’¥åŒ™ä¸²ç®—æ–°è®°å½•å¿…é”™ã€‚ç­‰é’¥åŒ™ä¸²é‡è¯»å›æ¥ï¼ˆä¸‹æ–¹çš„ refreshCertAvailabilityï¼‰
            // å†ç®—ã€‚UI çŸ­æš‚æ˜¾ç¤ºæ—§å€¼ï¼Œå¥½è¿‡æ˜¾ç¤ºé”™å€¼ã€‚
            accounts = fetchedAccounts
            activeAccountID = resolvedAccountID
            hasLoaded = true
            restorePendingBatchResultIfNeeded()

            // é‡è£…åè‡ªåŠ¨æ¢å¤ï¼šåˆ—è¡¨ä¸ºç©ºæ—¶æ‰«è®¾å¤‡æ‰¾å›ä¹‹å‰ç­¾è¿‡çš„åº”ç”¨
            if fetched.isEmpty {
                Task {
                    let recovery = OrphanAppRecoveryService(appStore: appStore)
                    let created = await recovery.recoverIfNeeded()
                    if created > 0 {
                        await load(force: true)
                    }
                }
            }

            // åå°åªåšã€Œè¯»å– + æ´¾ç”Ÿã€ï¼šé‚®ç®±ã€å›¾æ ‡ã€ç­¾åå†å²ã€é€šçŸ¥è°ƒåº¦ã€‚
            // æ¯ä¸€æ­¥éƒ½æ ¡éªŒåŠ è½½ä»£æ¬¡ â€”â€” å¿«é€Ÿè¿ç»­ loadï¼ˆå¯¼å…¥/ç­¾å/åˆ é™¤åéƒ½ä¼šè§¦å‘ï¼‰ä¼šåŒæ—¶å­˜åœ¨
            // å¤šä¸ªåå°ä»»åŠ¡ï¼Œæ—§ä»£æ¬¡çš„ä»»åŠ¡ä¸å¾—å›å†™ UI çŠ¶æ€ï¼Œå¦åˆ™æ–°æ•°æ®ä¼šè¢«æ—§æ•°æ®è¦†ç›–ã€‚
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                // âš ï¸ **ä¸€æ¬¡** Keychain è¯»å–åŒæ—¶å–‚ä¸¤ä¸ªç”¨é€”ï¼ˆé‚®ç®± + æœ¬æœºè¯ä¹¦çŠ¶æ€ï¼‰ï¼š
                // æ‹†æˆä¸¤æ¬¡è¯»ä¼šæŠŠ N ä¸ªè´¦å·çš„é’¥åŒ™ä¸²è®¿é—®ç¿»å€ï¼Œè€Œå®ƒä»¬æœ¬æ¥å°±è¦ä¸€èµ·ç”¨ã€‚
                let secrets = await self.loadAccountSecrets(for: fetchedAccounts)
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run {
                    self.accountSecrets = secrets
                    self.fullAccountEmails = secrets.mapValues { $0.email }
                    self.refreshCertAvailability()
                }

                var icons: [UUID: Data] = [:]
                if let fileStore = self.fileStore {
                    for app in fetched {
                        guard let path = app.displayIconRelativePath,
                              let data = try? await fileStore.read(relativePath: path) else { continue }
                        icons[app.id] = data
                    }
                }
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run {
                    self.iconData = icons
                    self.clearDecodedIconCache()
                }

                await self.seedSigningHistoryIfNeeded(apps: fetched, accounts: fetchedAccounts)

                guard await self.isCurrentLoad(generation) else { return }
                if let notificationScheduler = self.notificationScheduler,
                   let notificationPreferences = self.notificationPreferences {
                    do {
                        try await notificationScheduler.reschedule(apps: fetched, enabled: notificationPreferences.isEnabled, leadHours: notificationPreferences.leadHours)
                    } catch {
                        try? try? await self.logStore?.append(
                            category: .system,
                            level: .error,
                            message: NotificationSchedulingFailure.diagnostic(for: error),
                            code: "SEAL-NOTIFY-002a"
                        )
                    }
                }
            }
        } catch let failure as ImportFailure {
            guard generation == loadGeneration else { return }
            alertFailure = failure
        } catch {
            guard generation == loadGeneration else { return }
            alertFailure = ImportFailure(
                title: "æ— æ³•è¯»å–åº”ç”¨",
                reason: "æœ¬åœ°åº”ç”¨æ•°æ®è¯»å–å¤±è´¥ï¼Œåº”ç”¨åˆ—è¡¨æ— æ³•åŠ è½½ã€‚è¯·å…ˆå®Œå…¨é€€å‡ºå†é‡æ–°æ‰“å¼€ Sealï¼›å¦‚æœè¿˜æ˜¯åŠ è½½ä¸å‡ºæ¥ï¼Œ\(ImportFailure.sendLogToAuthor)ã€‚",
                recovery: "çŸ¥é“äº†",
                code: "SEAL-APP-002"
            )
        }
    }

    /// è‡ªæ›¿æ¢åçš„é€šçŸ¥ä¸èƒ½èµ°æ¸è¿›å¼ `load()`ï¼šè®°å½•å…ˆå‘å¸ƒã€é’¥åŒ™ä¸²æ´¾ç”ŸçŠ¶æ€åå‘å¸ƒæ—¶ï¼Œ
    /// ç”¨æˆ·å¯åœ¨ä¸¤è€…ä¹‹é—´æ‰“å¼€æŠ½å±‰å¹¶çœ‹åˆ°è¿‡æœŸçš„â€œéœ€é‡æ–°ç­¾åâ€ã€‚
    func reloadSelfRecordSnapshot() async {
        guard let appStore else { return }
        do {
            let fetchedApps = try await appStore.fetchAll()
            let fetchedAccounts = try await accountRepository?.fetchAll() ?? []
            let secrets = await loadAccountSecrets(for: fetchedAccounts)

            apps = fetchedApps
            accounts = fetchedAccounts
            accountSecrets = secrets
            fullAccountEmails = secrets.mapValues(\.email)
            refreshCertAvailability()
            hasLoaded = true
        } catch {
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "Seal è‡ªæ›¿æ¢çŠ¶æ€åŒæ­¥å¤±è´¥ï¼Œä¿ç•™å½“å‰ç•Œé¢çŠ¶æ€ã€‚è¯Šæ–­ï¼š\(ErrorDiagnosticFormatter.diagnostic(for: error))",
                code: "SEAL-APP-004"
            )
        }
    }

    /// åå°ä»»åŠ¡çš„åŠ è½½ä»£æ¬¡æ ¡éªŒã€‚`loadGeneration` å±äºä¸» actorï¼Œåå°ä»»åŠ¡å¿…é¡» `await` è®¿é—®ã€‚
    private func isCurrentLoad(_ generation: Int) -> Bool {
        loadGeneration == generation
    }

    /// ç©ºé—²æ—¶æ‰§è¡Œç»´æŠ¤ä½œä¸šï¼šè®°å½•æ¢å¤ â†’ Seal è‡ªæ³¨å†Œ â†’ å­¤å„¿æ–‡ä»¶æ¸…ç† â†’ è®¾å¤‡ç«¯æ—§æè¿°æ–‡ä»¶æ¸…ç†ã€‚
    ///
    /// äº’æ–¥ç”± `MaintenanceGate` ä¿è¯ï¼šéç©ºé—²ï¼ˆç”¨æˆ·æ­£åœ¨ç­¾å / å®‰è£… / ç»­ç­¾ï¼Œæˆ–å·²æœ‰ç»´æŠ¤ä½œä¸šåœ¨è·‘ï¼‰
    /// æ—¶ç›´æ¥è·³è¿‡æœ¬è½®ï¼Œ**ä¸åšä»»ä½•å†™å…¥æˆ–åˆ é™¤**ï¼Œä¹Ÿä¸é˜»å¡ç”¨æˆ·æ“ä½œã€‚
    /// è°ƒç”¨æ–¹åœ¨æ‹¿åˆ° `.completed` ä¹‹ååº”å½“é‡æ–° `load()` â€”â€” æ¢å¤ä¸è‡ªæ³¨å†Œå¯èƒ½æ–°å¢æˆ–æ›´æ–°äº†è®°å½•ã€‚
    ///
    /// **æ¯ä¸ªé `.completed` çš„ç»“æœéƒ½è¦ç•™ç—•**ï¼šçœŸæœºæ—¥å¿—é‡Œã€Œè®¾å¤‡ç«¯æ—§æè¿°æ–‡ä»¶æ¸…ç†ã€ä¸€æ¬¡éƒ½æ²¡å‡ºç°è¿‡
    /// ï¼ˆ`AppMaintenanceJob` é‚£æ¡æ—¥å¿—æ˜¯**æ— æ¡ä»¶**å†™çš„ï¼‰ï¼Œè€Œ `.skipped` åŸå…ˆåªæœ‰ä¸€å¥ `break`ã€
    /// `.failed` åªå¼¹çª—ä¸å†™æ—¥å¿— â€”â€” äºæ˜¯ã€Œprofile ä¸ºä»€ä¹ˆä¸€ç›´åœ¨å †ã€å®Œå…¨æ— æ³•å½’å› ã€‚
    @discardableResult
    /// Seal è‡ªæ³¨å†Œï¼šå¯åŠ¨æ—¶æ— æ¡ä»¶è°ƒç”¨ï¼Œä¸å—ç©ºé—²é—¨ç¦é™åˆ¶ã€‚
    /// è‡ªå®‰è£…é‡å¯åå¿…é¡»ç«‹å³åŒæ­¥è®°å½•ï¼Œå¦åˆ™"æœ‰æ–°ç‰ˆæœ¬å¾…å®‰è£…"æ ‡ç­¾ä¸æ¶ˆå¤±ã€‚
    func syncSelfRecordOnLaunch() async {
        await maintenanceJob?.syncSelfRecord()
    }

    /// å¯åŠ¨å…³é”®è·¯å¾„ï¼šåªè·‘è®°å½•æ¢å¤ï¼ˆè®¾å¤‡æ‰«æå‘ç° Appï¼‰ã€‚
    ///
    /// æ–°å®‰è£…æ—¶è¿™æ˜¯å·²å®‰è£…åˆ—è¡¨æœ‰æ•°æ®çš„å”¯ä¸€æ¥æºï¼Œå¿…é¡»åœ¨é¦–å±å‰å®Œæˆï¼›
    /// å­¤å„¿æ¸…ç†ä¸æè¿°æ–‡ä»¶æ¸…ç†ä¸é˜»å¡é¦–å±ï¼Œèµ° `runDeferredMaintenanceIfIdle()`ã€‚
    /// è¿”å› true è¡¨ç¤ºè¡¥å›äº†è®°å½•ï¼Œè°ƒç”¨æ–¹åº”å½“é‡æ–° `load()`ã€‚
    func runEssentialMaintenanceIfIdle() async -> Bool {
        guard let maintenanceJob else { return false }
        return await maintenanceJob.restoreRecordsIfIdle()
    }

    /// å¯åŠ¨éå…³é”®è·¯å¾„ï¼šå­¤å„¿æ–‡ä»¶æ¸…ç† + è®¾å¤‡ç«¯æ—§æè¿°æ–‡ä»¶æ¸…ç†ã€‚
    ///
    /// åœ¨é¦–å±å‡ºæ¥åäºåå°å»¶è¿Ÿæ‰§è¡Œï¼Œä¸é˜»å¡ç”¨æˆ·ã€‚ç”¨æˆ·ä¸€æ—¦å¼€å§‹ç­¾å / å®‰è£… / ç»­ç­¾ï¼Œ
    /// ä½œä¸šè‡ªåŠ¨ä¸­æ­¢ï¼ˆ`MaintenanceGate`ï¼‰ï¼Œæœªæ‰§è¡Œçš„æ­¥éª¤ä¸‹æ¬¡å†è·‘ã€‚
    /// æ—¥å¿—ç•™ç—•ä¸åŸ `runMaintenanceIfIdle()` çš„ `.completed` åˆ†æ”¯ä¿æŒä¸€è‡´ã€‚
    func runDeferredMaintenanceIfIdle() async {
        guard let maintenanceJob else { return }
        guard let report = await maintenanceJob.sweepIfIdle() else { return }
        if report.orphans.removedTotal > 0 {
            try? await logStore?.append(
                category: .system,
                message: "å·²æ¸…ç† \(report.orphans.removedTotal) ä¸ªæœªä½¿ç”¨çš„åº”ç”¨ç›®å½•",
                code: "SEAL-STORAGE-005"
            )
        }
        if report.orphans.skippedInFlightTransactions > 0 {
            // è·³è¿‡è¯´æ˜ç¡®å®å­˜åœ¨è¿›è¡Œä¸­çš„å¯¼å…¥äº‹åŠ¡ï¼›ç•™ç—•ä¾¿äºæ’æŸ¥ã€Œä¸ºä»€ä¹ˆæ²¡æ¸…å¹²å‡€ã€ã€‚
            try? await logStore?.append(
                category: .system,
                message: "æœ‰ \(report.orphans.skippedInFlightTransactions) ä¸ªå¯¼å…¥äº‹åŠ¡ç›®å½•ä»åœ¨è¿›è¡Œï¼Œæœ¬è½®æœªæ¸…ç†",
                code: "SEAL-STORAGE-008"
            )
        }
        if report.profiles.removed > 0 {
            try? await logStore?.append(
                category: .system,
                message: "å·²æ¸…ç† \(report.profiles.removed) ä»½è®¾å¤‡ç«¯æ—§æè¿°æ–‡ä»¶",
                code: "SEAL-PROFILE-321"
            )
        }
    }

    func runMaintenanceIfIdle() async -> AppMaintenanceJob.Outcome {
        guard let maintenanceJob else { return .skipped }
        let outcome = await maintenanceJob.run()
        switch outcome {
        case .skipped:
            // éç©ºé—²å°±è·³è¿‡æ˜¯**è®¾è®¡æ„å›¾**ï¼ˆä½ä¼˜å…ˆçº§ã€å¯æŠ¢å ï¼Œæ°¸ä¸é˜»å¡ç”¨æˆ·æ“ä½œï¼‰ï¼Œ
            // ä½†å¿…é¡»èƒ½å›ç­”ã€Œè¿™ä¸€è½®åˆ°åº•è·‘æ²¡è·‘ã€â€”â€” å¦åˆ™ profile å †ç§¯çœ‹èµ·æ¥åƒæ¸…ç†é€»è¾‘åäº†ã€‚
            try? await logStore?.append(
                category: .system,
                message: "ç»´æŠ¤ä½œä¸šæœ¬è½®è·³è¿‡ï¼šæœ‰å‰å°æ“ä½œæ­£åœ¨è¿›è¡Œï¼ˆä¸‹æ¬¡å¯åŠ¨æˆ–ç©ºé—²æ—¶å†è¯•ï¼‰",
                code: "SEAL-STORAGE-009"
            )
        case .completed(let report):
            if report.orphans.removedTotal > 0 {
                try? await logStore?.append(
                    category: .system,
                    message: "å·²æ¸…ç† \(report.orphans.removedTotal) ä¸ªæœªä½¿ç”¨çš„åº”ç”¨ç›®å½•",
                    code: "SEAL-STORAGE-005"
                )
            }
            if report.orphans.skippedInFlightTransactions > 0 {
                // è·³è¿‡è¯´æ˜ç¡®å®å­˜åœ¨è¿›è¡Œä¸­çš„å¯¼å…¥äº‹åŠ¡ï¼›ç•™ç—•ä¾¿äºæ’æŸ¥ã€Œä¸ºä»€ä¹ˆæ²¡æ¸…å¹²å‡€ã€ã€‚
                try? await logStore?.append(
                    category: .system,
                    message: "æœ‰ \(report.orphans.skippedInFlightTransactions) ä¸ªå¯¼å…¥äº‹åŠ¡ç›®å½•ä»åœ¨è¿›è¡Œï¼Œæœ¬è½®æœªæ¸…ç†",
                    code: "SEAL-STORAGE-008"
                )
            }
            if report.profiles.removed > 0 {
                try? await logStore?.append(
                    category: .system,
                    message: "å·²æ¸…ç† \(report.profiles.removed) ä»½è®¾å¤‡ç«¯æ—§æè¿°æ–‡ä»¶",
                    code: "SEAL-PROFILE-321"
                )
            }
        case .aborted(let stage, let reason):
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "ç»´æŠ¤ä½œä¸šåœ¨ã€Œ\(stage)ã€é˜¶æ®µè¢«æ‰“æ–­ï¼ˆ\(reason)ï¼‰ï¼Œæœªæ‰§è¡Œçš„æ­¥éª¤å·²è·³è¿‡",
                code: "SEAL-STORAGE-006"
            )
        case .failed(let failure):
            // åŸå…ˆåªå¼¹çª—ï¼šç”¨æˆ·åˆ’æ‰å¼¹çª—åæ—¥å¿—é‡Œä»€ä¹ˆéƒ½æ²¡ç•™ä¸‹ï¼Œäº‹åå®Œå…¨æŸ¥ä¸å‡ºæ˜¯å“ªä¸€æ­¥å¤±è´¥ã€‚
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "ç»´æŠ¤ä½œä¸šå¤±è´¥ï¼š\(failure.title)ï¼ˆ\(failure.code)ï¼‰",
                code: "SEAL-STORAGE-010"
            )
            alertFailure = failure
        }
        return outcome
    }

    func fullEmail(for account: AppleAccountRecord) -> String {
        fullAccountEmails[account.id] ?? "æœªè®°å½•"
    }

    /// è¯¥åº”ç”¨ã€Œæœ¬æœºæ˜¯å¦æŒæœ‰å½“å‰è¯ä¹¦ç§é’¥ã€â€”â€”ç•Œé¢åœ¨ã€Œè¯ä¹¦åºåˆ—å·ã€è¡Œä¸‹é¢æ®æ­¤ç»™ä¸€å¥è¯´æ˜ã€‚
    /// è¯»ä¸åˆ°æ—¶è¿”å› `.undetermined`ï¼ˆ**ä¸æ˜¾ç¤ºä»»ä½•è¯** â€”â€” ä¸èƒ½å‡­ç©ºæ–­è¨€ç¼ºç§é’¥ï¼‰ã€‚
    func localCertificateAvailability(
        for app: AppRecord
    ) -> ProfileOnlyRenewalPolicy.LocalCertificateAvailability {
        localCertificateAvailabilityByAppID[app.id] ?? .undetermined
    }

    /// ç”¨**å½“å‰**çš„ `apps` ä¸ `accountSecrets` é‡ç®—ä¸Šé¢é‚£ä»½æ´¾ç”ŸçŠ¶æ€ã€‚
    ///
    /// åˆ¤æ®ä¸€å¾‹èµ° `ProfileOnlyRenewalPolicy`ï¼ˆä¸ç»­ç­¾å‡†å…¥åŒæºï¼ŒR85â‘¡ï¼‰ï¼Œè¿™é‡Œåªè´Ÿè´£ã€Œä»€ä¹ˆæ—¶å€™ç®—ã€ã€‚
    /// åœ¨é’¥åŒ™ä¸²å¿«ç…§ä¸ `apps` å·²é…å¯¹æ—¶è°ƒç”¨ã€‚ç­¾åæˆåŠŸä¼šå…ˆå†™å…¥å®Œæˆè®°å½•ã€å†é‡è¯»é’¥åŒ™ä¸²ï¼Œ
    /// è¿™æ ·æŠ½å±‰ä¸ä¼šç»§ç»­æ‹¿æ—§åºåˆ—å·æ˜¾ç¤ºâ€œéœ€é‡æ–°ç­¾åâ€ã€‚
    private func refreshCertAvailability() {
        localCertificateAvailabilityByAppID = ProfileOnlyRenewalPolicy.availabilityByAppID(
            apps: apps,
            secretsByAccount: accountSecrets
        )
    }

    /// ç­¾åæˆåŠŸåç›´æ¥ç½® `.ready`ï¼šåˆšç”¨ç§é’¥ç­¾å®Œï¼Œæœ¬æœºä¸€å®šæœ‰ï¼Œä¸ç­‰é’¥åŒ™ä¸²é‡è¯»ã€‚
    /// ä¸‹æ¬¡é’¥åŒ™ä¸²é‡è¯»å `refreshCertAvailability()` ä¼šå†æ ¡éªŒï¼Œè‹¥çœŸæœ‰é—®é¢˜ä¼šçº å›æ¥ã€‚
    func markLocalCertificateReady(for appID: UUID) {
        localCertificateAvailabilityByAppID[appID] = .ready
    }

    /// ç­¾åæˆåŠŸåçš„æœ€å°çŠ¶æ€å¯¹è´¦ï¼šå…ˆè®©è§‚å¯Ÿä¸­çš„æŠ½å±‰æ”¶åˆ°æœ€æ–° Appï¼Œå†ä»¥æ–°é’¥åŒ™ä¸²å¿«ç…§é‡ç®—å…¨éƒ¨è¯ä¹¦æ–‡æ¡ˆã€‚
    /// ä¸èƒ½ä¾èµ– `load()` çš„åå°æ´¾ç”Ÿä»»åŠ¡ï¼›å®ƒä¼šåœ¨ç”¨æˆ·å·²ç»é‡æ–°æ‰“å¼€æŠ½å±‰ä¹‹åæ‰å®Œæˆã€‚
    private func reconcileAfterSuccessfulSigning(_ completed: AppRecord) async {
        if let index = apps.firstIndex(where: { $0.id == completed.id }) {
            apps[index] = completed
        }

        // åˆšå®Œæˆç­¾åè¿™ä¸€åˆ»å·²çŸ¥ç§é’¥å¯ç”¨ï¼Œå³ä½¿ Keychain è¯»å›å› ç¬æ—¶é”™è¯¯å¤±è´¥ä¹Ÿä¸èƒ½è¯¯æŠ¥â€œéœ€é‡æ–°ç­¾åâ€ã€‚
        markLocalCertificateReady(for: completed.id)

        let secrets = await loadAccountSecrets(for: accounts)
        guard secrets.isEmpty == false || accounts.isEmpty else { return }
        accountSecrets = secrets
        fullAccountEmails = secrets.mapValues(\.email)
        refreshCertAvailability()
        // æˆåŠŸç­¾åæ˜¯æ¯”ä¸€æ¬¡çŸ­æš‚ Keychain è¯»å–æ›´å¼ºçš„äº‹å®ï¼›ä¿ç•™è¯¥ç¡®å®šçŠ¶æ€ç›´åˆ°ä¸‹æ¬¡å®Œæ•´åŠ è½½å¤æ ¸ã€‚
        markLocalCertificateReady(for: completed.id)
    }

    /// å•é¡¹ç­¾åä¸å•é¡¹ç»­ç­¾å†™å…¥å’Œã€Œç»­ç­¾å…¨éƒ¨ã€ç›¸åŒçš„è½®æ¬¡è¯­æ³•ã€‚
    /// æ—¥å¿—é¡µ/å¯¼å‡ºé¡µåªè§£æè¿™ä¸€ä»½æ ¼å¼ï¼Œè€—æ—¶å–çœŸå®èµ·æ­¢æ—¶é—´ï¼Œä¸åšé¢„ä¼°ã€‚
    private func appendSingleOperationRound(
        operation: RenewalRoundOperation,
        app: AppRecord,
        startedAt: Date,
        outcome: RenewalRoundItem.Outcome,
        failure: ImportFailure? = nil
    ) async {
        let endedAt = Date()
        let item = RenewalRoundItem(
            appName: app.name,
            outcome: outcome,
            duration: endedAt.timeIntervalSince(startedAt),
            profileExpirationDate: outcome == .succeeded
                ? (app.provisioningProfileExpirationDate ?? app.expiryDate)
                : nil,
            failureCode: failure?.code,
            failureReason: failure?.reason,
            failureRecovery: failure?.recovery
        )
        let summary = RenewalRoundSummary(
            roundNumber: 0,
            triggerSource: .manual,
            operation: operation,
            startedAt: startedAt,
            endedAt: endedAt,
            items: [item]
        )
        let hasFailure = outcome == .failed || outcome == .needsAction
        try? await logStore?.append(
            category: operation == .singleSigning ? .signing : .renewal,
            level: hasFailure ? .warning : .info,
            message: summary.humanReadableMessage()
        )
    }

    /// ä¸€æ¬¡è¯»å®Œæ‰€æœ‰è´¦å·çš„å¯†é’¥ â€”â€” é‚®ç®±æ˜¾ç¤ºä¸ã€Œæœ¬æœºè¯ä¹¦çŠ¶æ€ã€éƒ½ä»è¿™é‡Œæ´¾ç”Ÿã€‚
    ///
    /// ä¸¤è€…å…±ç”¨ä¸€æ¬¡è¯»å–æ˜¯**åˆ»æ„çš„**ï¼šå®ƒä»¬æœ¬æ¥å°±è¦ä¸€èµ·ç”¨ï¼Œåˆ†ä¸¤æ¬¡è¯»ä¼šæŠŠ N ä¸ªè´¦å·çš„
    /// é’¥åŒ™ä¸²è®¿é—®ç¿»å€ï¼ˆæ—§å®ç°åªä¸ºé‚®ç®±è¯»ä¸€æ¬¡ï¼Œæœ¬è½®çš„è¯ä¹¦çŠ¶æ€å°±æ˜¯æ­è¿™è¶Ÿè½¦ï¼‰ã€‚
    private func loadAccountSecrets(
        for accounts: [AppleAccountRecord]
    ) async -> [UUID: AccountSecret] {
        guard let keychain else { return [:] }
        var values: [UUID: AccountSecret] = [:]
        for account in accounts {
            guard let secret = try? await keychain.load(accountID: account.id) else { continue }
            values[account.id] = secret
        }
        return values
    }

    func refreshUnsignedApps() async {
        await load(force: true)
    }

    /// - Parameter userInitiated: æ˜¯å¦ç”±ç”¨æˆ·ä¸»åŠ¨è§¦å‘ã€‚
    ///
    ///   âš ï¸ **é»˜è®¤ `false`**ï¼ˆ2026-09-25 æ”¹ï¼‰ï¼šä¸‰ä¸ªè°ƒç”¨ç‚¹ï¼ˆå¯åŠ¨ / å›å‰å° / ä¸‹æ‹‰åˆ·æ–°ï¼‰æœ¬æ¥
    ///   å…¨éƒ½æ˜¾å¼ä¼  `false`ï¼Œè€Œè®¾å¤‡æŸ¥è¯¢å¤±è´¥åœ¨ã€Œåˆšå¯åŠ¨ã€é€šé“è¿˜æ²¡å°±ç»ªã€æ—¶æ˜¯**é¢„æœŸ**ç°è±¡
    ///   ï¼ˆçœŸæœºæ„å»º 37ï¼šä¸‰æ¬¡ `SEAL-INSTALL-707` å…¨éƒ¨è½åœ¨å†·å¯åŠ¨æˆ–è‡ªæ›¿æ¢é‡å¯åçš„åå‡ ç§’å†…ï¼Œ
    ///   åŒä¸€æ¬¡ä¼šè¯ç¨åå°±è‡ªæ„ˆï¼‰ã€‚â‡’ é»˜è®¤å€¼å¿…é¡»åœ¨ã€Œ**ä¸æ‰“æ‰°ç”¨æˆ·**ã€çš„é‚£ä¸€ä¾§ï¼›æƒ³å¼¹é˜»æ–­å¼æç¤º
    ///   å¿…é¡»**æ˜¾å¼**ä¼  `true` â€”â€” å¦åˆ™å°†æ¥è°è°ƒç”¨ä¸å¸¦å‚æ•°çš„ç‰ˆæœ¬ï¼Œéƒ½ä¼šçªç„¶ç»™ç”¨æˆ·å¼¹çª—ã€‚
    func refreshInstalledApps(userInitiated: Bool = false) async {
        await load(force: true)
        let changed = await reconcileInstalledAppsWithDevice(userInitiated: userInitiated)
        if changed {
            await load(force: true)
        }
    }

    private func reconcileInstalledAppsWithDevice(userInitiated: Bool) async -> Bool {
        let installedRecords = installedApps
        guard installedRecords.isEmpty == false else { return false }

        // ğŸ”´ **ä¸å‰å°æ“ä½œäº’æ–¥**ï¼ˆ2026-09-26ï¼Œæ„å»º 46 çœŸæœºï¼‰ã€‚
        //
        // è®¾å¤‡æ ¸éªŒèµ°çš„æ˜¯åŒæ­¥ FFIï¼ˆ`Minimuxer.isAppInstalled`ï¼‰ï¼Œå’Œç­¾å / å®‰è£… / ç»­ç­¾
        // å…±ç”¨åŒä¸€æ¡ RSD ä¼šè¯ã€‚æ„å»º 46 æ—¥å¿—é‡Œ 3 æ¬¡ `SEAL-INSTALL-707`
        //ï¼ˆ01:25:01 / 01:26:40 / 01:29:11ï¼‰å…¨éƒ¨è½åœ¨ç»­ç­¾ä¸è‡ªæ›¿æ¢è¿›è¡Œä¸­ â€”â€”
        // å®ƒæ—¢æŠ¢ä¸åˆ°ä¼šè¯ï¼ˆé¢„ç®—å¿…ç„¶è¶…æ—¶ï¼‰ï¼ŒåˆæŠŠå¤±è´¥å¼¹çª—æ¨ç»™ç”¨æˆ·ã€‚
        // ä¸Šæ¸¸ `refresh` ç®¡çº¿åœ¨æ‰¹æ¬¡å¼€å§‹å¤„åªåš**ä¸€æ¬¡** `ensureMinimuxerReady()`ï¼Œ
        // æœŸé—´ä¸åšä»»ä½•å¹¶å‘çš„è®¾å¤‡æŸ¥è¯¢ â‡’ è¿™é‡Œå¯¹é½ï¼šæœ‰å‰å°æ“ä½œæ—¶**ç›´æ¥è·³è¿‡**ï¼Œ
        // ä¸æ¢æµ‹ã€ä¸æŠ¥é”™ã€ä¸å¼¹çª—ï¼ˆåˆ—è¡¨ä¿ç•™æœ¬åœ°å¿«ç…§ï¼Œä¸‹æ¬¡ç©ºé—²å†æ ¸éªŒï¼‰ã€‚
        //
        // âš ï¸ è¿™ä¸ `MaintenanceGate` æ˜¯**ä¸¤æ¡ä¸åŒçš„é—¸é—¨**ï¼šç»´æŠ¤ä½œä¸šæ˜¯ã€Œä½ä¼˜å…ˆçº§ã€
        //    å¯æŠ¢å ã€ï¼Œå®ƒè‡ªå·±ä¼šè®©è·¯ï¼›è€Œè¿™é‡Œæ˜¯**ç”¨æˆ·ä¸»åŠ¨æ‰“å¼€å·²å®‰è£…é¡µ**è§¦å‘çš„æ ¸éªŒï¼Œ
        //    å¿…é¡»ç”±å®ƒè‡ªå·±è®©è·¯ï¼Œå¦åˆ™å°±ä¼šå»æŠ¢ç»­ç­¾çš„è®¾å¤‡ä¼šè¯ã€‚
        guard operationCoordinator?.activeLease == nil else {
            try? await logStore?.append(
                category: .system,
                message: "å·²å®‰è£…é¡µè®¾å¤‡æ ¸éªŒè·³è¿‡ï¼šæœ‰å‰å°æ“ä½œæ­£åœ¨è¿›è¡Œï¼ˆé¿å…ä¸å…¶æŠ¢å åŒä¸€æ¡è®¾å¤‡ä¼šè¯ï¼‰",
                code: "SEAL-INSTALL-708"
            )
            return false
        }

        // å¯¼å…¥ä¸å·²å®‰è£… IPA ç›¸åŒï¼ˆç­¾ååçš„ Bundle ID ä¸€è‡´ï¼‰ä¼šæ®‹ç•™å¤šæ¡ç›¸åŒèº«ä»½çš„è®°å½•ï¼Œ
        // iOS æ— æ³•å¹¶å­˜åŒ Bundle ID çš„åº”ç”¨ï¼Œè¿™é‡ŒæŒ‰èº«ä»½åˆå¹¶å»é‡ï¼Œåªä¿ç•™çœŸå®å­˜åœ¨çš„ä¸€æ¡ã€‚
        var mutations = [await removeDuplicateInstalledRecords(installedRecords)]

        do {
            // ğŸ”´ **é˜³æ€§å¯¹ç…§**ï¼ˆ2026-09-26ï¼Œæ„å»º 49 çœŸæœºå¤ç›˜ï¼‰ã€‚æ‹¿æ­£åœ¨è¿è¡Œçš„ Seal è‡ªå·±å…ˆé—®ä¸€æ¬¡ï¼Œ
            // ç­”ä¸å‡ºæ¥å°±æ•´è½®ä¸åˆ ã€‚å§Šå¦¹è·¯å¾„ï¼ˆ`DeviceInstalledAppScanner`ã€`DeviceProfileCleaner`ï¼‰
            // éƒ½æœ‰è¿™ä¸€æ­¥ï¼Œå”¯ç‹¬è¿™é‡Œæ¼äº† â€”â€” è€Œå®ƒä»¬è°ƒçš„æ˜¯**åŒä¸€ä¸ª** `Minimuxer.isAppInstalled`ã€‚
            //
            // ä¸ºä»€ä¹ˆå¿…é¡»æœ‰ï¼šLockdown è·¯å¾„ä¸‹ `isAppInstalled` çš„å®ç°æ˜¯ `inst.lookup(appId:) != nil`ï¼Œ
            // è€Œ Rust ä¾§æŠŠ RPC å¤±è´¥ä¸ã€Œæ²¡æŸ¥åˆ°ã€è¿”å›æˆ**åŒä¸€ä¸ªç©ºæŒ‡é’ˆ** â‡’ é€šé“åŠåæ—¶å®ƒå¯¹**æ¯ä¸€ä¸ª**
            // Bundle ID éƒ½**é™é»˜ç­”ã€Œæ²¡è£…ã€**ï¼ˆä¸æŠ›é”™ã€åªç­”å¦ï¼‰ã€‚è€Œ `InstalledAppDeviceVerifier`
            // åªèƒ½æŠ“åˆ°**æŠ›é”™**çš„å¤±è´¥ï¼ˆ404 / è¶…æ—¶ / å†·å´ï¼‰ï¼ŒæŠ“ä¸åˆ°è¿™ç§ â‡’ æ²¡æœ‰è¿™ä¸€æ­¥ï¼Œ
            // ã€Œé€šé“è¯´å‡è¯ã€ä¸ã€ŒApp çœŸçš„æ²¡è£…ã€åœ¨ä»£ç é‡Œå®Œå…¨åŒå½¢ï¼Œè€Œä¸‹æ¸¸æ˜¯ `delete`
            //ï¼ˆè¿å¸¦ `fileStore.removeApp` åˆ æ‰æœ¬åœ°æ–‡ä»¶ï¼‰ã€‚
            // çœŸæœºå…ˆä¾‹ï¼šæœ¬ä»“ `DeviceProfileCleaner` çš„æ³¨é‡Šé‡Œå°±ç•™ç€ã€Œé˜³æ€§å¯¹ç…§æœªé€šè¿‡
            //ï¼ˆcom.mjorb.seal.<TEAM_ID> è¢«ç­”æˆæœªå®‰è£…ï¼‰ã€â€”â€” åŒä¸€ä¸ª APIã€åŒä¸€å°è®¾å¤‡ã€‚
            //
            // ä¸ã€Œå…ˆé—®å®Œã€å†åŠ¨æ‰‹ã€æ˜¯ä¸¤æ¡**äº’è¡¥**çš„ç½‘ï¼šé‚£æ¡é˜²ã€Œé—®ä¸€åŠé€šé“åäº†ã€ï¼Œ
            // è¿™æ¡é˜²ã€Œé€šé“ä»å¤´åˆ°å°¾éƒ½åœ¨è¯´å‡è¯ã€ï¼ˆé‚£ç§æƒ…å†µä¸‹æ¯æ¡æŸ¥è¯¢éƒ½æˆåŠŸè¿”å› `false`ï¼‰ã€‚
            //
            // ç ç”¨ `SEAL-INSTALL-739`ï¼ˆä¸åŒåŠŸèƒ½çš„ 707ã€Œæœªå®Œæˆã€ã€708ã€Œè·³è¿‡ã€åŒæ—ï¼‰â€”â€”
            // âš ï¸ **ä¸èƒ½**å¤ç”¨ 709ï¼š709 å·²ç»æ˜¯ `MinimuxerInstallChannel` çš„ã€Œå®‰å…¨æ¡æ‰‹æœªå®Œæˆã€ï¼Œ
            // åŒä¸€ä¸ªç è¯´ä¸¤ä»¶äº‹ä¼šè®©ç”¨æˆ·æŸ¥ç è¡¨æ—¶å¾—åˆ°é”™è¯¯è§£é‡Šã€‚
            guard let controlBundleID = Bundle.main.bundleIdentifier,
                  controlBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                try? await logStore?.append(
                    category: .system,
                    level: .warning,
                    message: "å·²å®‰è£…é¡µè®¾å¤‡æ ¸éªŒä¸­æ­¢ï¼šæ‹¿ä¸åˆ°é˜³æ€§å¯¹ç…§çš„ Bundle ID â‡’ æœ¬è½®ä¸€æ¡è®°å½•éƒ½ä¸åˆ ã€‚",
                    code: "SEAL-INSTALL-739"
                )
                return false
            }
            let controlInstalled = try await InstalledAppDeviceVerifier.isInstalled(bundleIdentifier: controlBundleID)
            guard controlInstalled else {
                try? await logStore?.append(
                    category: .system,
                    level: .warning,
                    message: "å·²å®‰è£…é¡µè®¾å¤‡æ ¸éªŒä¸­æ­¢ï¼šé˜³æ€§å¯¹ç…§æœªé€šè¿‡ï¼ˆ\(controlBundleID) è¢«ç­”æˆæœªå®‰è£…ï¼‰â‡’ é€šé“æ­¤åˆ»ä¸å¯ä¿¡ï¼Œæœ¬è½®ä¸€æ¡è®°å½•éƒ½ä¸åˆ ã€‚",
                    code: "SEAL-INSTALL-739"
                )
                return false
            }

            // ğŸ”´ **å…ˆé—®å®Œã€å†åŠ¨æ‰‹**ï¼ˆ2026-09-25 æ”¹ï¼‰ã€‚æ—§å®ç°æ˜¯ã€Œè¾¹é—®è¾¹åˆ ã€ï¼šåªè¦å¾ªç¯ä¸­é€”
            // é€šé“å˜åï¼ˆç¬¬ 1 æ¡å·²åˆ¤ã€Œè®¾å¤‡ä¸Šæ²¡æœ‰ã€å¹¶è¢«åˆ æ‰ã€ç¬¬ 2 æ¡æ‰æŠ›é”™ï¼‰ï¼Œå°±ä¼š**åˆ ä¸€åŠ**ã€‚
            // ç°åœ¨å…ˆæŠŠã€Œè®¾å¤‡ä¸Šç¡®è®¤ä¸å­˜åœ¨ã€çš„è®°å½•**å…¨éƒ¨æ”¶é›†å®Œ**ï¼Œä»»ä½•ä¸€æ¡æŸ¥è¯¢å¤±è´¥éƒ½**æ•´è½®ä¸­æ­¢ã€
            // ä¸€æ¡éƒ½ä¸åˆ **ï¼ˆfail closed â€”â€” ä¸æè¿°æ–‡ä»¶å›æ”¶è·¯å¾„çš„çº¦å®šä¸€è‡´ï¼‰ã€‚
            var missingOnDevice: [AppRecord] = []
            for app in installedRecords {
                guard let bundleIdentifier = installedBundleIdentifier(for: app) else { continue }

                let existsOnDevice = try await InstalledAppDeviceVerifier.isInstalled(
                    bundleIdentifier: bundleIdentifier
                )

                if existsOnDevice == false {
                    missingOnDevice.append(app)
                }
            }
            for app in missingOnDevice {
                mutations.append(await markMissingOnDevice(app))
            }
        } catch {
            if InstalledAppRefreshFailure.shouldLogDiagnostic(for: error) {
                try? await logStore?.append(
                    category: .system,
                    level: .warning,
                    message: "å·²å®‰è£…é¡µè®¾å¤‡æ ¸éªŒæœªå®Œæˆï¼Œå·²ä¿ç•™å½“å‰åˆ—è¡¨ï¼Œæœ¬è½®æœªåˆ é™¤ä»»ä½•è®°å½•ã€‚è¯Šæ–­ï¼š\(InstalledAppRefreshFailure.diagnostic(for: error))",
                    code: "SEAL-INSTALL-707"
                )
            }
            if userInitiated {
                alertFailure = ImportFailure(
                    title: "\u{65E0}\u{6CD5}\u{5237}\u{65B0}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}",
                    reason: "\u{672A}\u{80FD}\u{4ECE}\u{8BBE}\u{5907}\u{8BFB}\u{53D6}\u{771F}\u{5B9E}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}\u{72B6}\u{6001}\u{3002}",
                    recovery: "\u{91CD}\u{65B0}\u{8FDE}\u{63A5}\u{624B}\u{673A}\u{5E76}\u{5B8C}\u{6210}\u{914D}\u{5BF9}\u{540E}\u{91CD}\u{8BD5}",
                    code: "SEAL-INSTALL-707"
                )
            }
        }
        return InstalledAppRefreshPolicy.requiresReload(after: mutations)
    }

    /// å¤–éƒ¨å¸è½½åªæ”¹å˜è®¾å¤‡å­˜åœ¨çŠ¶æ€ï¼šç”¨æˆ·ä»å¯ä¿ç•™æœ¬åœ° IPA ä¸ç­¾åèº«ä»½åé‡æ–°å®‰è£…ã€‚
    /// `delete(_:)` æ˜¯ç”¨æˆ·æ˜ç¡®åˆ é™¤èµ„æ–™çš„æ“ä½œï¼Œç»ä¸èƒ½å¤ç”¨åˆ°è®¾å¤‡æ¢æµ‹è·¯å¾„ã€‚
    private func markMissingOnDevice(_ app: AppRecord) async -> Bool {
        guard let appStore else { return false }
        var updated = app
        updated.markMissingOnDevice()
        do {
            try await appStore.save(updated)
            try? await logStore?.append(
                category: .system,
                level: .info,
                message: "è®¾å¤‡ç¡®è®¤å·²å¸è½½ï¼šå·²ä»å·²å®‰è£…åˆ—è¡¨ç§»é™¤å¹¶ä¿ç•™æœ¬åœ°ç­¾åèµ„æ–™ï¼ˆ\(app.displayName)ï¼‰",
                code: "SEAL-INSTALL-740"
            )
            return true
        } catch {
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "è®¾å¤‡ç¡®è®¤å·²å¸è½½ï¼Œä½†æœ¬åœ°çŠ¶æ€æ›´æ–°å¤±è´¥ï¼›å·²ä¿ç•™ç°æœ‰åˆ—è¡¨ã€‚è¯Šæ–­ï¼š\(ErrorDiagnosticFormatter.diagnostic(for: error))",
                code: "SEAL-INSTALL-741"
            )
            return false
        }
    }

    private func installedBundleIdentifier(for app: AppRecord) -> String? {
        if let mapped = app.mappedBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           mapped.isEmpty == false {
            return mapped
        }
        if let preferred = app.preferredBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           preferred.isEmpty == false {
            return preferred
        }
        return nil
    }

    /// åˆå¹¶æœ¬æœºå·²å®‰è£…åˆ—è¡¨ä¸­ã€Œç­¾åå Bundle ID ç›¸åŒã€çš„é‡å¤è®°å½•ï¼Œåªä¿ç•™æœ€å¯ä¿¡çš„ä¸€æ¡ï¼Œ
    /// åˆ é™¤å…¶ä½™é‡å¤è®°å½•åŠå…¶æ–‡ä»¶å¤¹ã€‚ä»…å¤„ç†é Seal çš„ç¬¬ä¸‰æ–¹åº”ç”¨ï¼›Seal è‡ªèº«ç”± SelfAppRegistrar ç®¡ç†ã€‚
    private func removeDuplicateInstalledRecords(_ records: [AppRecord]) async -> Bool {
        var bestByBundle: [String: AppRecord] = [:]
        var duplicates: [AppRecord] = []
        for record in records where record.isSeal == false {
            guard let bundle = installedBundleIdentifier(for: record)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  bundle.isEmpty == false else {
                continue
            }
            if let existing = bestByBundle[bundle] {
                if preferKeeping(record, over: existing) {
                    duplicates.append(existing)
                    bestByBundle[bundle] = record
                } else {
                    duplicates.append(record)
                }
            } else {
                bestByBundle[bundle] = record
            }
        }
        var mutations: [Bool] = []
        for duplicate in duplicates {
            mutations.append(await delete(duplicate, refreshAfterDeletion: false))
        }
        return InstalledAppRefreshPolicy.requiresReload(after: mutations)
    }

    private func preferKeeping(_ lhs: AppRecord, over rhs: AppRecord) -> Bool {
        if lhs.hasSignedArtifact != rhs.hasSignedArtifact {
            return lhs.hasSignedArtifact
        }
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        // è®¾å¤‡ä¸Šåªæœ‰ä¸€ä¸ªåº”ç”¨ï¼Œä¿ç•™ state == .installed çš„é‚£æ¡æ›´æ¥è¿‘çœŸå®çŠ¶æ€ã€‚
        if lhs.state == .installed && rhs.state != .installed { return true }
        if rhs.state == .installed && lhs.state != .installed { return false }
        let lhsDate = lhs.lastInstalledAt ?? lhs.importedAt
        let rhsDate = rhs.lastInstalledAt ?? rhs.importedAt
        return lhsDate >= rhsDate
    }

    private func seedSigningHistoryIfNeeded(
        apps: [AppRecord],
        accounts: [AppleAccountRecord]
    ) async {
        guard let signingHistoryStore else { return }
        let existingRecords: [SigningHistoryRecord]
        do {
            existingRecords = try await signingHistoryStore.records()
        } catch {
            surfaceHistoryWarning(
                title: "ç­¾åå†å²è¯»å–å¤±è´¥",
                reason: "æ— æ³•è¯»å–å†å²è®°å½•ï¼Œå·²è·³è¿‡æœ¬æ¬¡å†å²å›å¡«ã€‚",
                code: "SEAL-HISTORY-004"
            )
            return
        }
        let existingKeys = Set(
            existingRecords.compactMap { record -> String? in
                guard let appID = record.appID else { return nil }
                return "\(record.accountID.uuidString)-\(appID.uuidString)"
            }
        )

        for app in apps where app.belongsInInstalledList {
            guard let accountID = app.accountID,
                  let account = accounts.first(where: { $0.id == accountID }) else {
                continue
            }
            let key = "\(accountID.uuidString)-\(app.id.uuidString)"
            guard existingKeys.contains(key) == false else { continue }
            let record = SigningHistoryRecord(
                app: app,
                account: account,
                action: .imported,
                result: .success,
                signedAt: app.importedAt,
                attemptedBundleIdentifier: app.preferredBundleIdentifier,
                finalSignedBundleIdentifier: app.mappedBundleIdentifier,
                lifecycleStatus: .active
            )
            do {
                try await signingHistoryStore.append(record)
            } catch {
                surfaceHistoryWarning(
                    title: "ç­¾åå†å²å›å¡«æœªå®Œæˆ",
                    reason: "éƒ¨åˆ†å·²æœ‰åº”ç”¨çš„å†å²è®°å½•æ— æ³•ä¿å­˜ã€‚",
                    code: "SEAL-HISTORY-004a"
                )
                return
            }
        }
    }

    func presentImporter() {
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] æ‰“å¼€å¯¼å…¥å™¨") }
        guard phase == .idle else { return }
        isImporterPresented = true
    }

    func importSelectedFile(_ url: URL) async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å¯¼å…¥æ–‡ä»¶: \(url.lastPathComponent)")
        _ = await importSelectedFile(url, autoOpenSigning: false)
    }

    /// åº”ç”¨å†…æ›´æ–°ä¸‹è½½å®Œæˆåå¯¼å…¥ Seal è‡ªèº« IPAï¼ŒæˆåŠŸåè‡ªåŠ¨æ‰“å¼€ç­¾åæŠ½å±‰è¦†ç›–å®‰è£…ã€‚
    /// è¿”å› true è¡¨ç¤º IPA å·²æˆåŠŸå…¥åº“ï¼ˆè®°å½•å·²æäº¤ï¼‰ï¼›å¤±è´¥æ—¶ä¿ç•™ä¸‹è½½æºä¾›ç”¨æˆ·é‡è¯•ã€‚
    @discardableResult
    func importSelfUpdateFile(_ url: URL) async -> Bool {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å¯¼å…¥è‡ªæ›´æ–°æ–‡ä»¶: \(url.lastPathComponent)")
        return await importSelectedFile(url, autoOpenSigning: true)
    }

    @discardableResult
    private func importSelectedFile(_ url: URL, autoOpenSigning: Bool) async -> Bool {
        guard let workflow else { return false }
        // `RootTabView` can hand a downloaded Seal update to this method after
        // another user-selected IPA has already entered its confirmation flow.
        // Do not silently discard that deliberate update request: the file is
        // retained by the downloader, and the user gets the same actionable
        // transaction conflict as every other foreground import.
        guard phase == .idle else {
            alertFailure = operationConflictFailure(requested: .importing)
            return false
        }
        guard let operationLease = await acquireOperation(.importing) else {
            alertFailure = operationConflictFailure(requested: .importing)
            return false
        }
        defer { releaseOperation(operationLease) }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        alertFailure = nil
        sheetFailure = nil
        importReplacementCandidate = nil
        isImportSheetPresented = false
        autoOpenSigningAfterImport = autoOpenSigning
        phase = .preparing
        await workflow.prepare(sourceURL: url)
        await consumeWorkflowState()
        if case .completed = await workflow.state {
            return true
        }
        return false
    }

    func confirmImport() async {
        guard let workflow else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ç¡®è®¤å¯¼å…¥: è¦†ç›–æ›´æ–°=\(importReplacementCandidate != nil)")
        guard let operationLease = await acquireOperation(.importing) else {
            sheetFailure = operationConflictFailure(requested: .importing)
            isImportSheetPresented = true
            return
        }
        defer { releaseOperation(operationLease) }
        guard let draft = sheetDraft else {
            sheetFailure = ImportFailure(
                title: "æ— æ³•å¯¼å…¥ IPA",
                reason: "å¯¼å…¥ç¡®è®¤ä¿¡æ¯å·²å¤±æ•ˆï¼Œè¯·é‡æ–°é€‰æ‹© IPAã€‚",
                recovery: "é‡æ–°é€‰æ‹©",
                code: "SEAL-IPA-211"
            )
            isImportSheetPresented = true
            phase = .idle
            return
        }

        phase = .committing
        sheetFailure = nil
        isImportSheetPresented = true
        // ç”¨æˆ·åœ¨ç¡®è®¤é¡µé€‰çš„æ˜¯ã€Œè¦†ç›–æ›´æ–°ã€è¿˜æ˜¯ã€Œæ–°å»ºå‰¯æœ¬ã€ï¼Œå°±åœ¨è¿™ä¸€æ­¥å®šä¸‹æ¥ã€‚
        // ç›®æ ‡è®°å½•ä¼šåœ¨ `ImportWorkflow.commit` é‡Œ**æŒ‰ id å¤æ ¸**åæ‰çœŸçš„æ›¿æ¢ã€‚
        let target: ImportCommitTarget = importReplacementCandidate.map { .replaceInstalled(appID: $0.id) } ?? .newRecord
        await workflow.confirm(preferredDraft: draft, target: target)
        await consumeWorkflowState()
    }

    func retryImport() async {
        guard let workflow, sheetDraft != nil else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] é‡è¯•å¯¼å…¥")
        guard let operationLease = await acquireOperation(.importing) else {
            sheetFailure = operationConflictFailure(requested: .importing)
            isImportSheetPresented = true
            return
        }
        defer { releaseOperation(operationLease) }
        phase = .committing
        sheetFailure = nil
        await workflow.retry()
        await consumeWorkflowState()
    }

    /// å¯¼å…¥ç¡®è®¤é¡µä¸èƒ½æŠŠæ‰€æœ‰å¤±è´¥éƒ½é”™è¯¯åœ°é€è¿›åŒä¸€æ¡ `workflow.retry()`ï¼š
    /// é‡æ–°é€‰æ‹© IPA ä¸é‡æ–°æäº¤å½“å‰äº‹åŠ¡æ˜¯ä¸¤ç§ä¸åŒçš„æ¢å¤åŠ¨ä½œã€‚è¿™é‡Œåªæ¶ˆè´¹å·²ç»“æ„åŒ–çš„
    /// failure actionï¼›å†å²å¤±è´¥åˆ™ç»´æŒæ—§è¡Œä¸ºï¼Œç›´åˆ°å„å‘å°„ç‚¹å®Œæˆè¿ç§»ã€‚
    func performImportPrimaryAction() async {
        guard let failure = sheetFailure else {
            await confirmImport()
            return
        }
        guard failure.hasStructuredSemantics else {
            await retryImport()
            return
        }
        switch failure.action {
        case .retry:
            await retryImport()
        case .reimportIPA:
            await reselectImportIPA()
        default:
            break
        }
    }

    private func reselectImportIPA() async {
        await cancelImport()
        guard alertFailure == nil else { return }
        presentImporter()
    }

    func cancelImport() async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å–æ¶ˆå¯¼å…¥")
        var cleanupFailure: ImportFailure?
        if let workflow {
            await workflow.cancel()
            cleanupFailure = await workflow.takeCleanupFailure()
        }
        sheetDraft = nil
        sheetFailure = nil
        importReplacementCandidate = nil
        alreadyInstalledDraft = nil
        pendingImportIconData = nil
        pendingImportDisplayName = nil
        isImportSheetPresented = false
        phase = .idle
        if let cleanupFailure {
            alertFailure = cleanupFailure
        }
    }

    /// ç”¨æˆ·åœ¨å¯¼å…¥ç¡®è®¤é¡µé€‰æ‹©ã€Œæ–°å»ºå‰¯æœ¬ï¼ˆä¸è¦†ç›–ï¼‰ã€ï¼šæ”¾å¼ƒè¦†ç›–æ›´æ–°ï¼ŒæŒ‰åŸè¡Œä¸ºæ–°å»ºä¸€æ¡
    /// å¾…ç­¾åè®°å½•ã€‚è¿™æ˜¯ã€ŒåŒä¸€ä¸ª IPA å¯¼å…¥å¤šä¸ªå‰¯æœ¬ã€ç”¨ä¸åŒ Bundle ID åˆ†åˆ«ç­¾ååŒæ—¶å®‰è£…ã€
    /// é‚£æ¡åˆ»æ„ä¿ç•™è·¯å¾„çš„å…¥å£ã€‚
    func confirmImportAsNewRecord() async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å¯¼å…¥ç¡®è®¤ä¸ºæ–°å»ºå‰¯æœ¬ï¼ˆä¸è¦†ç›–ï¼‰")
        importReplacementCandidate = nil
        await confirmImport()
    }

    /// å¯¼å…¥åŒ…æ˜¯å¦ä¸æŸæ¡å·²å®‰è£…è®°å½•åŒèº«ä»½ï¼ˆâ‡’ å¯ä»¥è¦†ç›–æ›´æ–°ï¼‰ã€‚
    /// è¯»**å½“å‰**è®°å½•è€Œä¸æ˜¯ `apps` å¿«ç…§ï¼šç”¨æˆ·å¯èƒ½åœ¨å¯¼å…¥å‰åˆšè£…è¿‡ä¸œè¥¿ã€‚
    /// è¯»å¤±è´¥å›è½ nil â€”â€” é‚£åªä¼šè®©æœ¬æ¬¡èµ°ã€Œæ–°å»ºã€ï¼Œä¸ä¼šç ´åä»»ä½•å·²æœ‰è®°å½•ã€‚
    private func replacementCandidate(for draft: ImportDraft) async -> AppRecord? {
        guard let appStore, let records = try? await appStore.fetchAll() else { return nil }
        return ImportReplacementPolicy.installedReplacementCandidate(
            for: draft.parsedIPA,
            in: records
        )
    }

    /// Seal è‡ªæ›´æ–°çš„è¦†ç›–å€™é€‰ï¼šinstalledReplacementCandidate æŠŠ Seal æ’é™¤åœ¨å¤–ï¼Œ
    /// è¿™é‡Œå•ç‹¬æ‰¾ Seal è®°å½•ã€‚è¿”å› nil è¡¨ç¤ºä¸æ˜¯ Seal è‡ªæ›´æ–°æˆ–æ— éœ€ç¡®è®¤ã€‚
    private func sealReplacementCandidate(for draft: ImportDraft) async -> AppRecord? {
        guard let appStore, let records = try? await appStore.fetchAll() else { return nil }
        // åªå¤„ç† Seal è‡ªèº«çš„ IPA
        let sealBundleIDs = ["com.mjorb.seal", "com.mjorb.Seal"]
        guard sealBundleIDs.contains(where: {
            draft.parsedIPA.bundleIdentifier.caseInsensitiveCompare($0) == .orderedSame
        }) else { return nil }
        return records.first(where: { $0.isSeal && $0.belongsInInstalledList })
    }

    /// è¦†ç›–æ›´æ–°çš„ç»“æœå¿…é¡»ç•™ç—•ã€‚
    ///
    /// ç”¨æˆ·ç‚¹ã€Œè¦†ç›–æ›´æ–°ã€åï¼Œ`ImportWorkflow.commit` ä¼š**æŒ‰ id å¤æ ¸**ç›®æ ‡è®°å½•ï¼›å¤æ ¸ä¸è¿‡
    ///ï¼ˆè®°å½•è¢«åˆ ã€æˆ–å·²ä¸å†æ˜¯å·²å®‰è£…çŠ¶æ€ï¼‰æ—¶ä¼š**å®‰å…¨å›è½**æˆæ–°å»ºä¸€æ¡å¾…ç­¾åè®°å½• â€”â€”
    /// ç»“æœåˆå›åˆ°ã€Œå¾…ç­¾åã€é¡µï¼Œçœ‹èµ·æ¥å°±åƒã€Œè¦†ç›–æ›´æ–°æ²¡ç”Ÿæ•ˆã€ã€‚
    /// é™é»˜å›è½ä¼šè®©è¿™ä¸ªç°è±¡æ°¸è¿œæŸ¥ä¸å‡ºåŸå› ï¼Œæ‰€ä»¥æˆåŠŸä¸å›è½å„ç•™ä¸€æ¡å¸¦ç æ—¥å¿—ã€‚
    private func logImportReplacementOutcome(
        requested: AppRecord?,
        record: AppRecord
    ) async {
        guard let requested else { return }
        if record.belongsInInstalledList {
            try? await logStore?.append(
                category: .installation,
                level: .info,
                message: "å¯¼å…¥è¦†ç›–æ›´æ–°ï¼š\(record.displayName) v\(requested.version) â†’ v\(record.version)ï¼Œ"
                    + "å·²æ›¿æ¢å·²å®‰è£…è®°å½• \(record.id.uuidString)",
                code: "SEAL-IPA-212"
            )
        } else {
            try? await logStore?.append(
                category: .installation,
                level: .warning,
                message: "è¦†ç›–æ›´æ–°ç›®æ ‡å·²å¤±æ•ˆï¼ˆè®°å½• \(requested.id.uuidString) å·²ä¸æ˜¯å·²å®‰è£…çŠ¶æ€ï¼‰ï¼Œ"
                    + "å·²å›è½ä¸ºæ–°å»ºå¾…ç­¾åè®°å½•ï¼š\(record.displayName)",
                code: "SEAL-IPA-213"
            )
        }
    }

    func handleImporterFailure(_ error: Error) {
        let cocoaError = error as? CocoaError
        guard cocoaError?.code != .userCancelled else { return }
        alertFailure = ImportFailure(
            title: "æ— æ³•é€‰æ‹© IPA",
            reason: "æ²¡èƒ½é€‰ä¸­æ–‡ä»¶ï¼Œå¯èƒ½æ˜¯æ–‡ä»¶è¢«ç§»åŠ¨ã€åˆ é™¤äº†ï¼Œæˆ– iCloud ä¸Šçš„æ–‡ä»¶è¿˜æ²¡ä¸‹è½½åˆ°æœ¬æœºã€‚è¯·ç¡®è®¤æ–‡ä»¶è¿˜åœ¨åŸä½ç½®ï¼ˆiCloud çš„æ–‡ä»¶å…ˆç‚¹ä¸€ä¸‹ä¸‹è½½ä¸‹æ¥ï¼‰ã€‚",
            recovery: "é‡æ–°é€‰æ‹©",
            code: "SEAL-IPA-206"
        )
    }

    func performAlertRecovery(for failure: ImportFailure) {
        alertFailure = nil
        if failure.code == "SEAL-AUTH-115",
           let pending = pendingTeamSwitch {
            pendingTeamSwitch = nil
            let isRenewal = pending.app.belongsInInstalledList
            startSigning(
                app: pending.app,
                account: pending.account,
                requestedBundleIdentifier: isRenewal ? nil : pending.requestedBundleIdentifier,
                completionMode: pending.completionMode
            )
            return
        }
        let recovery = failure.recovery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recovery != "çŸ¥é“äº†" else { return }
        if failure.hasStructuredSemantics {
            switch failure.action {
            case .reimportIPA:
                presentImporter()
            default:
                if let route = settingsRoute(for: failure) {
                    openSettings(route: route)
                }
            }
            return
        }
        if failure.code.hasPrefix("SEAL-IPA-") {
            presentImporter()
        } else if let route = settingsRoute(for: failure) {
            openSettings(route: route)
        }
    }

    func openSettings(route: SettingsRoute) {
        requestedSettingsRoute = route
        shouldOpenSettings = true
    }

    func requestSigning(for app: AppRecord) async {
        guard signingTask == nil, batchRefreshTask == nil else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] è¯·æ±‚ç­¾å: \(app.displayName) (\(app.id.uuidString.prefix(8)))")
        await load(force: true)
        // å·²å®‰è£…åº”ç”¨çš„å•é¡¹ç»­ç­¾ä¸â€œå…¨éƒ¨ç»­ç­¾/é‡è¯•å¤±è´¥é¡¹â€å¿…é¡»å…±ç”¨åŒä¸€ä¸ªé˜Ÿåˆ—ï¼š
        // è¿™æ · profile-onlyã€å®Œæ•´é‡ç­¾ã€Seal-last ä¸å¯åŠ¨æœŸè‡ªæ›¿æ¢ç»“ç®—ä¸ä¼šå„èµ°ä¸€ä»½è§„åˆ™ã€‚
        if app.belongsInInstalledList {
            startBatchRefresh(appIDs: [app.id])
            return
        }
        let availableAccounts = accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
        guard availableAccounts.isEmpty == false else {
            alertFailure = accounts.isEmpty
                ? AccountAvailabilityFailure.missingAccount(operation: .sign)
                : AccountAvailabilityFailure.accountNeedsVerification(operation: .sign)
            return
        }

        // å®½æ¾ç­–ç•¥ï¼šå·²å®‰è£…åº”ç”¨æ²¡æœ‰è®°å½•ç­¾åè´¦å·æ—¶ï¼Œä¸æ‹’ç»ï¼Œè®©ç”¨æˆ·é€‰æ‹©è´¦å·è¿›è¡Œç»­ç­¾
        continueSigningRequest(for: app, availableAccounts: availableAccounts)
    }

    /// æŠŠ `RenewalAccountResolver` çš„ç»“æœå˜æˆã€Œè´¦å·ã€æˆ–ã€Œä¸€æ¡è¯´æ¸…åŸå› çš„æç¤º + æ—¥å¿—ã€ã€‚
    ///
    /// âš ï¸ æ¯æ¡å¤±è´¥å‡ºå£éƒ½å¿…é¡»ç•™ç—•ï¼šæ—§å®ç°åªè®¾ `alertFailure`ã€**ä¸€è¡Œæ—¥å¿—éƒ½ä¸å†™** â‡’
    /// çœŸæœºä¸Šç‚¹ã€Œç«‹å³ç»­ç­¾ã€è¢«æ‹’ä¹‹åï¼Œæ—¥å¿—é‡Œä¸€æ¡çº¿ç´¢éƒ½æ²¡æœ‰
    ///ï¼ˆ2026-09-24 æ„å»º 34 å®æµ‹ï¼š`SEAL-AUTH-104b` åœ¨ 233 è¡Œæ—¥å¿—é‡Œ**é›¶å‘½ä¸­**ï¼Œ
    /// è€Œã€Œç‚¹äº†ç»­ç­¾å´ä»€ä¹ˆéƒ½æ²¡å‘ç”Ÿã€æ­£æ˜¯æœ€éœ€è¦æ—¥å¿—çš„åœºæ™¯ï¼‰ã€‚
    /// åˆ¤æ®æŒ‰ `AGENTS.md` Â§4ï¼šæ‹¿ç€è¿™æ¡æ—¥å¿—è¦èƒ½è¯´å‡ºä¸‹ä¸€æ­¥åšä»€ä¹ˆã€‚
    private func resolvedRenewalAccount(
        _ resolution: RenewalAccountResolver.Resolution,
        app: AppRecord
    ) async -> AppleAccountRecord? {
        switch resolution {
        case .resolved(let id):
            guard let account = verifiedAccounts.first(where: { $0.id == id }) else {
                // è§£æå™¨åˆšåˆ¤å®šå¯ç”¨ã€è¿™é‡Œå´æŸ¥ä¸åˆ°ï¼šåªå¯èƒ½è¢«å¹¶å‘æ”¹åŠ¨ï¼Œå¦‚å®æŠ¥å‡ºå³å¯ã€‚
                await logAccountResolutionFailure(
                    app: app,
                    code: "SEAL-AUTH-104b",
                    detail: "è§£æå‡ºçš„è´¦å·å·²ä¸å¯ç”¨"
                )
                alertFailure = ImportFailure(
                    title: "Apple ID ä¸å¯ç”¨",
                    reason: "è¯·é€‰æ‹©ä¸€ä¸ªå·²éªŒè¯çš„ Apple ID è¿›è¡Œç»­ç­¾ã€‚",
                    recovery: "å»ã€Œæˆ‘çš„ã€",
                    code: "SEAL-AUTH-104b"
                )
                return nil
            }
            return account
        case .recordedAccountNeedsVerification(let id):
            let email = accounts.first(where: { $0.id == id })?.maskedEmail ?? "è®°å½•ä¸­çš„ Apple ID"
            await logAccountResolutionFailure(
                app: app,
                code: "SEAL-AUTH-104f",
                detail: "è®°å½•çš„ç­¾åè´¦å·éœ€é‡æ–°éªŒè¯ï¼ˆ\(email)ï¼‰"
            )
            alertFailure = ImportFailure(
                title: "Apple ID éœ€è¦é‡æ–°éªŒè¯",
                reason: "\(app.name) è®°å½•çš„ç­¾åè´¦å·ï¼ˆ\(email)ï¼‰å½“å‰ä¸å¯ç”¨ï¼Œéœ€è¦å…ˆåœ¨ã€Œæˆ‘çš„ã€é‡Œé‡æ–°éªŒè¯åæ‰èƒ½ç»­ç­¾ã€‚",
                recovery: "å‰å¾€ã€Œæˆ‘çš„ã€é‡æ–°éªŒè¯ Apple ID",
                code: "SEAL-AUTH-104f",
                condition: .accountVerificationRequired,
                action: .reauthenticateAccount,
                route: .account,
                retryDisposition: .manual,
                operation: .renew,
                origin: .authentication
            )
            return nil
        case .recordedAccountMissing(let teamID):
            let team = (teamID?.isEmpty == false ? teamID! : "æœªçŸ¥")
            await logAccountResolutionFailure(
                app: app,
                code: "SEAL-AUTH-104g",
                detail: "è®°å½•çš„è´¦å·å·²ä¸å­˜åœ¨ï¼Œä¸”æ²¡æœ‰åŒ Teamï¼ˆ\(team)ï¼‰çš„å¯ç”¨è´¦å·"
            )
            alertFailure = ImportFailure(
                title: "æ‰¾ä¸åˆ°åŸæ¥çš„ç­¾åè´¦å·",
                reason: "\(app.name) åŸæ¥ç”±å›¢é˜Ÿ \(team) çš„ Apple ID ç­¾åï¼Œè¯¥è´¦å·å·²è¢«åˆ é™¤ï¼Œå½“å‰ä¹Ÿæ²¡æœ‰åŒä¸€å›¢é˜Ÿçš„å¯ç”¨è´¦å·ã€‚æ¢ç”¨å…¶ä»–å›¢é˜Ÿçš„è´¦å·ç»­ç­¾ä¼šå¯¼è‡´å®ƒä¹‹å‰ä¿å­˜çš„ç™»å½•ä¿¡æ¯å’Œæ•°æ®ç”¨ä¸äº†ï¼Œå› æ­¤æ²¡æœ‰è‡ªåŠ¨ç»§ç»­ã€‚",
                recovery: "å‰å¾€ã€Œæˆ‘çš„ã€æ·»åŠ åŸå›¢é˜Ÿçš„ Apple ID",
                code: "SEAL-AUTH-104g",
                condition: .recordedSigningIdentityUnavailable,
                action: .addAccount,
                route: .account,
                retryDisposition: .manual,
                operation: .renew,
                origin: .authentication
            )
            return nil
        case .noSelectableAccount:
            let failure = accounts.isEmpty
                ? AccountAvailabilityFailure.missingAccount(operation: .renew)
                : AccountAvailabilityFailure.accountNeedsVerification(operation: .renew)
            await logAccountResolutionFailure(
                app: app,
                code: failure.code,
                detail: "æ²¡æœ‰å¯ç”¨çš„ Apple IDï¼ˆè´¦å·è®°å½• \(accounts.count) æ¡ï¼‰"
            )
            alertFailure = failure
            return nil
        }
    }

    /// ç»­ç­¾è¢«æ‹’æ—¶çš„ç»Ÿä¸€ç•™ç—•ã€‚
    ///
    /// åˆ»æ„æŠŠã€Œåº”ç”¨ã€è®°å½•é‡Œçš„è´¦å· UUIDã€è®°å½•é‡Œçš„ Teamã€è´¦å·è®°å½•æ¡æ•°ã€ä¸€èµ·å†™è¿›å» â€”â€”
    /// åªè¯´ä¸€å¥ã€Œä¸å¯ç”¨ã€çš„æ—¥å¿—ï¼Œç”¨æˆ·å’Œæ’æŸ¥è€…éƒ½çœ‹ä¸å‡ºä¸‹ä¸€æ­¥åšä»€ä¹ˆã€‚
    private func logAccountResolutionFailure(
        app: AppRecord,
        code: String,
        detail: String
    ) async {
        let bundleID = app.mappedBundleIdentifier
            ?? app.preferredBundleIdentifier
            ?? app.originalBundleIdentifier
        try? await logStore?.append(
            category: .signing,
            level: .error,
            message: "ç»­ç­¾è¢«æ‹’ [\(code)] \(app.name)ï¼ˆ\(bundleID)ï¼‰ï¼š\(detail)"
                + "ï¼›è®°å½•è´¦å·=\(app.accountID?.uuidString ?? "æ— ")"
                + "ï¼Œè®°å½• Team=\(app.signingTeamID ?? "æ— ")"
                + "ï¼Œè´¦å·è®°å½• \(accounts.count) æ¡ï¼ˆå¯ç”¨ \(verifiedAccounts.count) æ¡ï¼‰",
            code: code
        )
    }

    func beginSigning(
        for app: AppRecord,
        accountID: UUID,
        requestedBundleIdentifier: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall
    ) async {
        guard signingTask == nil, batchRefreshTask == nil else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å¼€å§‹ç­¾å: \(app.displayName) (\(app.id.uuidString.prefix(8))), ç»­ç­¾=\(app.belongsInInstalledList)")
        let isRenewal = app.belongsInInstalledList
        // ğŸ”´ ç»­ç­¾çš„è´¦å·åˆ¤æ®é›†ä¸­åœ¨ `RenewalAccountResolver`ã€‚
        // æ—§å†™æ³• `(isRenewal ? app.accountID : nil) ?? accountID` æœ‰ä¸ªéšè”½æ­»è§’ï¼š
        // åˆ è¿‡ Apple ID ä¹‹åè®°å½•é‡Œçš„ `accountID` æ˜¯**æ‚¬ç©º UUID**ï¼ˆä¸æ˜¯ `nil`ï¼‰ï¼Œ
        // äºæ˜¯ `??` å…œåº•**æ°¸è¿œä¸ä¼šæ‰§è¡Œ** â€”â€” å³ä½¿ç”¨æˆ·åœ¨æŠ½å±‰é‡Œæ‰‹åŠ¨é€‰äº†è´¦å·ä¹Ÿä¼šè¢«å¿½ç•¥ï¼Œ
        // ä¸€å¾‹å¼¹ã€ŒApple ID ä¸å¯ç”¨ã€ã€‚ï¼ˆä¸è¯ä¹¦è½®æ¢è‡ªåŠ¨æ¢å¤é‡Œé‚£å¥
        // `candidate.accountID == accountID` æ˜¯åŒä¸€ä¸ªé™·é˜±çš„ä¸¤ç§è¡¨ç°ã€‚ï¼‰
        var account: AppleAccountRecord
        if isRenewal {
            let resolution = RenewalAccountResolver.resolve(
                recordedAccountID: app.accountID,
                recordedTeamID: app.signingTeamID,
                accounts: accounts,
                fallbackAccountID: accountID
            )
            guard let resolved = await resolvedRenewalAccount(resolution, app: app) else { return }
            account = resolved
        } else {
            // å…¨æ–°ç­¾åï¼šè´¦å·æ˜¯ç”¨æˆ·åœ¨ç­¾åé¡µæ˜ç¡®é€‰å®šçš„ï¼Œä¸æ›¿æ¢ã€ä¸çŒœæµ‹ã€‚
            guard let picked = verifiedAccounts.first(where: { $0.id == accountID }) else {
                await logAccountResolutionFailure(
                    app: app,
                    code: "SEAL-AUTH-104b",
                    detail: "æ‰€é€‰è´¦å·ä¸å¯ç”¨"
                )
                alertFailure = ImportFailure(
                    title: "Apple ID ä¸å¯ç”¨",
                    reason: "è¯·é€‰æ‹©ä¸€ä¸ªå·²éªŒè¯çš„ Apple ID",
                    recovery: "å»ã€Œæˆ‘çš„ã€",
                    code: "SEAL-AUTH-104b"
                )
                return
            }
            account = picked
        }

        // Seal è¦†ç›–å®‰è£…è‡ªå·±ï¼ˆå†…éƒ¨æ›´æ–°/è‡ªç»­ç­¾ï¼‰çš„ç­¾åèº«ä»½ = TeamID + Bundle IDï¼›Bundle ID ç”±
        // isSeal åˆ†æ”¯ä¿ç•™ï¼Œä½† TeamID å–å†³äºæ‰€é€‰è´¦å·ã€‚è‹¥ Team å˜åŒ–ï¼ŒiOS åˆ¤ä¸ºå…¨æ–°åº”ç”¨ï¼Œæ¸…ç©ºæœ¬åœ°
        // å®¹å™¨ï¼ˆAccounts.json / Seal.sqliteï¼‰å¹¶ä½¿ Keychain è®¿é—®ç»„å¤±é… â€”â€” å³ã€Œæ›´æ–°å Apple ID
        // å¤±æ•ˆéœ€é‡æ–°æ·»åŠ ã€ã€‚è¿™é‡ŒæŒ‰å½“å‰è¿è¡Œ Seal çš„çœŸå®ç­¾å Team çº æ­£è´¦å·ï¼Œä¿ä½èº«ä»½ï¼›åªæœ‰æ‰¾ä¸åˆ°
        // åŒ Team è´¦å·ï¼ˆå¦‚é¦–æ¬¡ä»ä»–äººè´¦å·åˆ‡åˆ°è‡ªå·±è´¦å·ï¼‰æ‰å…è®¸åˆ‡æ¢å¹¶æç¤ºä¼šé‡ç½®æœ¬åœ°æ•°æ®ã€‚
        if app.isSeal,
           let currentSealTeam = SelfAppMetadata.current()?.signingTeamIdentifier,
           currentSealTeam.isEmpty == false,
           account.teamID.caseInsensitiveCompare(currentSealTeam) != .orderedSame {
            if let sameTeamAccount = verifiedAccounts.first(where: {
                $0.teamID.caseInsensitiveCompare(currentSealTeam) == .orderedSame
            }) {
                account = sameTeamAccount
                try? await logStore?.append(
                    category: .signing,
                    message: "Seal è‡ªæ›´æ–°æ²¿ç”¨åŒ Team è´¦å· \(sameTeamAccount.maskedEmail)ï¼Œé¿å…æ›´æ–°å Apple ID å¤±æ•ˆ"
                )
            } else {
                pendingTeamSwitch = PendingTeamSwitch(
                    app: app,
                    account: account,
                    requestedBundleIdentifier: requestedBundleIdentifier,
                    completionMode: completionMode
                )
                alertFailure = ImportFailure(
                    title: "æ›´æ–°å°†é‡ç½®æœ¬åœ°æ•°æ®",
                    reason: "å½“å‰ Seal ç”±å¦ä¸€ä¸ªå›¢é˜Ÿçš„è´¦å·ç­¾åï¼Œæ”¹ç”¨æ‰€é€‰ Apple ID è¦†ç›–å®‰è£…ä¼šæ¸…ç©ºå·²æ·»åŠ çš„ Apple ID ä¸å·²å®‰è£…åº”ç”¨ï¼Œéœ€é‡æ–°æ·»åŠ ã€‚",
                    recovery: "ç»§ç»­ç­¾å",
                    code: "SEAL-AUTH-115"
                )
                return
            }
        }

        if isRenewal == false {
            await selectActiveAccount(id: account.id)
        }
        startSigning(
            app: app,
            account: account,
            requestedBundleIdentifier: isRenewal ? nil : requestedBundleIdentifier,
            completionMode: completionMode
        )
    }

    private func continueSigningRequest(
        for app: AppRecord,
        availableAccounts: [AppleAccountRecord]
    ) {
        if app.belongsInInstalledList {
            guard let accountID = app.accountID,
                  let account = availableAccounts.first(where: { $0.id == accountID }) else {
                alertFailure = ImportFailure(
                    title: "ç­¾åè´¦å·ä¸å¯ç”¨",
                reason: "ä¸Šæ¬¡ç­¾åè¿™ä¸ªåº”ç”¨çš„ Apple ID å·²è¢«åˆ é™¤æˆ–å‡­æ®å¤±æ•ˆã€‚",
                recovery: "å»ã€Œæˆ‘çš„ã€æ·»åŠ è´¦å·",
                    code: "SEAL-AUTH-104c"
                )
                return
            }
            startSigning(app: app, account: account)
        } else if let activeAccountID,
                  let account = availableAccounts.first(where: { $0.id == activeAccountID }) {
            startSigning(app: app, account: account)
        } else if availableAccounts.count == 1, let account = availableAccounts.first {
            startSigning(app: app, account: account)
        } else {
            accountSelectionApp = app
        }
    }

    func resumePendingVPNAction() async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] æ¢å¤ VPN åç»§ç»­æ“ä½œ")
        guard let action = pendingVPNAction else {
            _ = await refreshSigningChannel()
            return
        }
        alertFailure = nil
        guard await refreshSigningChannel() else {
            presentVPNRecovery(for: action)
            return
        }
        pendingVPNAction = nil
        switch action {
        case .signing(
            let app,
            let accountID,
            let requestedBundleIdentifier,
            let completionMode
        ):
            if let accountID {
                await beginSigning(
                    for: app,
                    accountID: accountID,
                    requestedBundleIdentifier: requestedBundleIdentifier,
                    completionMode: completionMode
                )
            } else {
                await requestSigning(for: app)
            }
        case .batch:
            startBatchRefresh()
        }
    }

    func cancelPendingVPNRecovery() {
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å–æ¶ˆ VPN æ¢å¤") }
        pendingVPNAction = nil
        alertFailure = nil
    }

    func selectAccount(_ account: AppleAccountRecord, for app: AppRecord) {
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ä¸ºåº”ç”¨é€‰æ‹©è´¦å·: \(app.displayName)ï¼Œè´¦å· \(account.id.uuidString.prefix(8))") }
        accountSelectionApp = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false else { return }
            await self?.selectActiveAccount(id: account.id)
            self?.startSigning(app: app, account: account)
        }
    }

    func chooseAnotherAccount(for app: AppRecord) async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ä¸ºåº”ç”¨æ¢è´¦å·: \(app.displayName)")
        await load(force: true)
        guard accounts.contains(where: { AccountAvailabilityPolicy.isSelectable($0) }) else {
            let operation: FailureOperation = app.belongsInInstalledList ? .renew : .sign
            alertFailure = accounts.isEmpty
                ? AccountAvailabilityFailure.missingAccount(operation: operation)
                : AccountAvailabilityFailure.accountNeedsVerification(operation: operation)
            return
        }
        accountSelectionApp = app
    }

    func retrySigning() {
        guard let session = signingSession else { return }
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] é‡è¯•ç­¾å: \(session.app.displayName)") }
        restartSigning(session)
    }

    /// ã€Œé‡æ–°ç­¾åã€åœºæ™¯ï¼šç­¾ååŒ…å·²ç¼ºå¤±/æŸå/è¿‡æœŸ/è®¾å¤‡ä¸ç¬¦/ç»“æ„ä¸å®Œæ•´ï¼Œ
    /// å¿…é¡»å¼ºåˆ¶é‡æ–°èµ°å®Œæ•´ç­¾åï¼ˆä¸å¤ç”¨æœ¬æœºç¼“å­˜çš„æ—§ç­¾ååŒ…ï¼‰ï¼Œå¦åˆ™ä¼šå¯¹åŒä¸€ä¸ªååŒ…åå¤å®‰è£…ã€‚
    func retrySigningFromScratch() {
        guard let session = signingSession else { return }
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ä»å¤´é‡æ–°ç­¾å: \(session.app.displayName)") }
        restartSigning(
            session,
            forceResign: true
        )
    }

    /// ç”¨æˆ·å·²åœ¨ Lara å®Œæˆ 3-App Bypass åç»§ç»­ç­¾åï¼šè·³è¿‡å…è´¹è´¦å·è®¾å¤‡ä¸Šé™é¢„æ£€ï¼Œ
    /// äº¤å› installd æœ€ç»ˆè£å†³ï¼ˆæœªçœŸæ­£ç»•è¿‡æ—¶ installd ä»ä¼šæ‹’ç»å¹¶è½åˆ° iOS æ‹’ç»åˆ†æ”¯ï¼‰ã€‚
    func continueBypassingDeviceLimit() {
        guard let session = signingSession else { return }
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ç»•è¿‡è®¾å¤‡é™åˆ¶ç»§ç»­ç­¾å: \(session.app.displayName)") }
        restartSigning(
            session,
            bypassFreeAccountDeviceLimit: true
        )
    }

    /// ç­¾åå¤±è´¥é¡µã€Œæ’¤é”€å¹¶ç»§ç»­ç­¾åã€ï¼ˆSEAL-CERT-204eï¼‰ä¸€é”®æµç¨‹ï¼š
    /// æ’¤é”€è´¦å·ä¸‹æ‰€æœ‰æœ¬æœºæ— ç§é’¥çš„è¯ä¹¦ â†’ è‡ªåŠ¨é‡è¯•æœ¬æ¬¡ç­¾å â†’ æˆåŠŸåè‡ªåŠ¨é‡ç­¾å› æ­¤å¤±æ•ˆçš„
    /// å…¶ä½™å·²è£… Appã€‚æ’¤é”€ä¼šè®©ä»ç”¨æ—§è¯ä¹¦çš„ App ç«‹å³æ‰“ä¸å¼€ï¼Œç¡®è®¤å¼¹çª—å·²åœ¨å¤±è´¥é¡µç»™å‡ºã€‚
    func confirmCertificateSacrificeAndRetry() {
        guard let session = signingSession,
              case .failed(let failure) = session.status,
              failure.code == "SEAL-CERT-204e",
              signingTask == nil,
              batchRefreshTask == nil,
              let signingCoordinator else { return }
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ç¡®è®¤è¯ä¹¦ç‰ºç‰²å¹¶é‡è¯•ç­¾å: \(session.app.displayName)") }
        // èµ°åŒä¸€æ¡é˜¶æ®µæ¨è¿›è·¯å¾„ï¼ˆè€Œä¸æ˜¯ç›´æ¥èµ‹å€¼ `status`ï¼‰ï¼šé˜¶æ®µä¸ã€Œæœ¬é˜¶æ®µèµ·ç‚¹ã€ä¸€èµ·è½ã€‚
        // ç»•è¿‡ `updateSigningStage` çš„è¯ï¼Œè¿›åº¦ä¼°ç®—çš„èµ·ç‚¹ä¼šåœåœ¨**ä¸Šä¸€ä¸ª**é˜¶æ®µ â€”â€”
        // è¡¨ç°æ˜¯è¿›åº¦ä»æ—§é˜¶æ®µçš„æ•°å€¼å¼€å§‹çˆ¬ï¼Œè€Œä¸æ˜¯ä»æœ¬é˜¶æ®µçš„åœ°æ¿å€¼èµ·ã€‚
        updateSigningStage(.preparingCertificate)
        signingTask = Task { [weak self] in
            guard let self else { return }
            var retrySession: SigningSession?
            // defer ä¿è¯å–æ¶ˆè·¯å¾„ä¹Ÿé‡Šæ”¾ signingTaskï¼ˆrestartSigning æœ‰ signingTask == nil é—¨ç¦ï¼Œ
            // æ¼æ¸…ä¼šæŠŠåç»­æ‰€æœ‰é‡è¯•å¡æ­»ï¼‰ï¼›æˆåŠŸæ—¶åœ¨ defer é‡Œæ¥åŠ›é‡å¯ç­¾åã€‚
            defer {
                signingTask = nil
                if let retrySession {
                    restartSigning(
                        retrySession
                    )
                }
            }
            do {
                let result = try await signingCoordinator
                    .revokeKeylessCertificatesAfterConfirmation(accountID: session.account.id)
                try? await logStore?.append(
                    category: .signing,
                    message: "ç”¨æˆ·ç¡®è®¤æ’¤é”€ \(result.revokedSerials.count) å¼ æ— é’¥åŒ™è¯ä¹¦ï¼Œç»§ç»­æœ¬æ¬¡ç­¾å"
                )
                certificateSacrificeResignQueue = result.affectedInstalledApps
                    .map(\.id)
                    .filter { $0 != session.app.id }
                retrySession = session
            } catch is CancellationError {
                signingSession = nil
            } catch let sacrificeFailure as ImportFailure {
                signingSession?.status = .failed(sacrificeFailure)
            } catch {
                try? await logStore?.append(category: .signing, level: .error,
                    message: "SEAL-SIGN-500 åº•å±‚è¯Šæ–­ï¼š\(ErrorDiagnosticFormatter.diagnostic(for: error))",
                    code: "SEAL-SIGN-500")
                signingSession?.status = .failed(Self.unexpectedSigningFailure(error))
            }
        }
    }

    /// è¯ä¹¦æ’¤é”€æµç¨‹æ”¶å°¾ï¼šæœ¬æ¬¡ç­¾å**æˆåŠŸ**å…³é—­è¿›åº¦é¡µåï¼Œè‡ªåŠ¨æ‰¹é‡é‡ç­¾å› æ’¤é”€è€Œå¤±æ•ˆçš„
    /// å…¶ä½™å·²è£… Appï¼ˆå¤ç”¨ç»­ç­¾é˜Ÿåˆ—ï¼Œè¦†ç›–å®‰è£…ä¸æ–°å¢è®¾å¤‡æ§½ä½ï¼‰ï¼›é‡è¯•æœªæˆåŠŸåˆ™æ¸…ç©ºé˜Ÿåˆ—ï¼Œ
    /// ç•™æ—¥å¿—å¼•å¯¼æ‰‹åŠ¨ç»­ç­¾ã€‚
    private func resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: Bool) {
        let queue = certificateSacrificeResignQueue
        certificateSacrificeResignQueue = []
        guard queue.isEmpty == false else { return }
        guard signingSucceeded else {
            Task { [weak self] in
                try? await self?.logStore?.append(
                    category: .signing,
                    level: .warning,
                    message: "ç­¾åé‡è¯•æœªæˆåŠŸï¼Œ\(queue.count) ä¸ªå› è¯ä¹¦æ’¤é”€è€Œå¤±æ•ˆçš„åº”ç”¨è¯·ç¨åæ‰‹åŠ¨ç»­ç­¾"
                )
            }
            return
        }
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .signing,
                message: "æœ¬æ¬¡ç­¾åå·²å®Œæˆï¼Œå¼€å§‹è‡ªåŠ¨é‡ç­¾ \(queue.count) ä¸ªå› è¯ä¹¦æ’¤é”€è€Œå¤±æ•ˆçš„åº”ç”¨"
            )
        }
        startBatchRefresh(appIDs: queue)
    }


    /// å–æ¶ˆå½“å‰ç­¾å / ç»­ç­¾ï¼ˆè¿è¡Œä¸­æŠ½å±‰çš„ã€Œå–æ¶ˆã€ï¼‰ã€‚è½¯å–æ¶ˆï¼Œè¯­ä¹‰åŒ `cancelBatchRefresh`ï¼š
    /// ç•Œé¢ç«‹å³å…³é—­ã€åç»­æ­¥éª¤åœæ­¢ï¼Œä½†**å·²ç»ä¸‹å‘åˆ°è®¾å¤‡çš„é‚£æ¬¡å®‰è£…ä¸ä¼šè¢«ä¸­æ–­**ï¼Œ
    /// å®ƒä¼šç”± installd è‡ªå·±è·‘å®Œå¹¶æŒ‰å®‰è£…æ ¡éªŒç»“æœè½åº“ã€‚
    func cancelSigning() {
        let appName = signingSession?.app.displayName
        if let appName {
            Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å–æ¶ˆç­¾å: \(appName)") }
        }
        signingTask?.cancel()
        signingSession = nil
        selectedOperationApp = nil
        guard let appName else { return }
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .signing,
                level: .warning,
                message: "ç”¨æˆ·å–æ¶ˆç­¾å/ç»­ç­¾ï¼š\(appName)ï¼Œæ­£åœ¨è¿›è¡Œçš„å®‰è£…ä¼šç”±è®¾å¤‡è‡ªè¡Œå®Œæˆ",
                code: "SEAL-SIGN-012"
            )
            await self?.load(force: true)
        }
    }

    func dismissSigningResult() {
        guard let signingSession else { return }
        if case .running = signingSession.status { return }
        var signingSucceeded = false
        if case .succeeded = signingSession.status { signingSucceeded = true }
        self.signingSession = nil
        selectedOperationApp = nil
        // ç»“æœå·²åœ¨ runSigning ç»“æŸæ—¶ä½œä¸º RenewalRoundSummary å†™å…¥ï¼›å…³é—­æŠ½å±‰åªæ˜¯ UI
        // æ¸…ç†ï¼Œä¸èƒ½å†åˆ¶é€ ä¸€æ¡æ—§æ ¼å¼ç»“æœæ—¥å¿—ï¼Œå¦åˆ™å•ç‹¬ç»­ç­¾ä¼šæ˜¾ç¤ºä¸¤æ¬¡ç»“æœã€‚
        // è¿›åº¦é¡µå…³é—­åå†å‘èµ·æ‰¹é‡é‡ç­¾ï¼šä¸¤ä¸ª sheet åŒæŒ‚ AppsRootViewï¼Œ
        // åŒæ—¶å¼¹å‡ºä¼šå¯¼è‡´æ‰¹é‡ç»­ç­¾é¡µè¢«ç›–ä½ã€‚
        resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: signingSucceeded)
    }

    @discardableResult
    func updatePreferredBundleIdentifier(for app: AppRecord, value: String) async -> Bool {
        guard let appStore, BundleIDPolicy.isEditable(app) else { return false }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ä¿®æ”¹ Bundle ID: \(app.displayName) -> \(value)")
        guard let operationLease = await acquireOperation(.updatingApp, appID: app.id) else {
            alertFailure = operationConflictFailure(requested: .updatingApp)
            return false
        }
        defer { releaseOperation(operationLease) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationError = BundleIDPolicy.validationError(for: trimmed) {
            alertFailure = ImportFailure(
                title: "åº”ç”¨ ID æ— æ•ˆ",
                reason: validationError,
                recovery: "ä¿®æ”¹åº”ç”¨ ID",
                code: "SEAL-BUNDLE-001a"
            )
            return false
        }
        do {
            var updated = app
            updated.preferredBundleIdentifier = trimmed
            try await appStore.save(updated)
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "æ— æ³•ä¿å­˜åº”ç”¨ ID",
                reason: "Bundle ID æ²¡èƒ½ä¿å­˜åˆ°æœ¬æœºã€‚è¯·æ£€æŸ¥æœ¬æœºå­˜å‚¨ç©ºé—´æ˜¯å¦å……è¶³ï¼Œç„¶åé‡æ–°è¾“å…¥ä¿å­˜ï¼›å¦‚æœåå¤å¤±è´¥ï¼Œ\(ImportFailure.sendLogToAuthor)ã€‚",
                recovery: "çŸ¥é“äº†",
                code: "SEAL-BUNDLE-003"
            )
            return false
        }
    }

    @discardableResult
    func updatePreferredDisplayName(for app: AppRecord, name: String) async -> Bool {
        guard let appStore else { return false }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ä¿®æ”¹æ˜¾ç¤ºå: \(app.displayName) -> \(name)")
        guard let operationLease = await acquireOperation(.updatingApp, appID: app.id) else {
            alertFailure = operationConflictFailure(requested: .updatingApp)
            return false
        }
        defer { releaseOperation(operationLease) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            alertFailure = ImportFailure(
                title: "App åç§°æ— æ•ˆ",
                reason: "App åç§°ä¸èƒ½ä¸ºç©ºã€‚",
                recovery: "ä¿®æ”¹ App åç§°",
                code: "SEAL-CUSTOM-001"
            )
            return false
        }
        do {
            var updated = app
            updated.preferredDisplayName = trimmed == app.name ? nil : trimmed
            try await appStore.save(updated)
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "æ— æ³•ä¿å­˜ App åç§°",
                reason: "App åç§°æ²¡èƒ½ä¿å­˜åˆ°æœ¬æœºã€‚è¯·æ£€æŸ¥æœ¬æœºå­˜å‚¨ç©ºé—´æ˜¯å¦å……è¶³ï¼Œç„¶åé‡æ–°è¾“å…¥ä¿å­˜ï¼›å¦‚æœåå¤å¤±è´¥ï¼Œ\(ImportFailure.sendLogToAuthor)ã€‚",
                recovery: "çŸ¥é“äº†",
                code: "SEAL-CUSTOM-002"
            )
            return false
        }
    }

    @discardableResult
    func updatePreferredIcon(for app: AppRecord, data: Data?) async -> Bool {
        guard let appStore, let fileStore else { return false }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] ä¿®æ”¹å›¾æ ‡: \(app.displayName) (\(app.id.uuidString.prefix(8)))")
        guard let operationLease = await acquireOperation(.updatingApp, appID: app.id) else {
            alertFailure = operationConflictFailure(requested: .updatingApp)
            return false
        }
        defer { releaseOperation(operationLease) }
        do {
            var updated = app
            if let data {
                updated.preferredIconRelativePath = try await fileStore.storePreferredIcon(data: data, appID: app.id)
            } else {
                try await fileStore.removePreferredIcon(appID: app.id)
                updated.preferredIconRelativePath = nil
            }
            try await appStore.save(updated)
            let newIconData: Data?
            if let path = updated.displayIconRelativePath,
               let data = try? await fileStore.read(relativePath: path) {
                newIconData = data
            } else {
                newIconData = nil
            }
            await MainActor.run {
                iconData[updated.id] = newIconData
            }
            invalidateDecodedIcon(for: updated.id)
            // é—®é¢˜8ä¿®å¤ï¼šè·Ÿ updatePreferredDisplayName ä¿æŒä¸€è‡´ï¼Œä¿å­˜æˆåŠŸååˆ·æ–° appsï¼Œ
            // é¿å…åç»­ç”¨æ—§è®°å½•ä¿å­˜æ—¶æŠŠæ–°å›¾æ ‡è·¯å¾„è¦†ç›–æ‰ã€‚
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "æ— æ³•ä¿å­˜ App å›¾æ ‡",
                reason: "å›¾æ ‡æ–‡ä»¶æ²¡èƒ½å†™å…¥æœ¬æœºå­˜å‚¨ï¼Œå¯èƒ½æ˜¯å­˜å‚¨ç©ºé—´ä¸è¶³ã€‚è¯·æ¸…ç†ä¸€äº›ç©ºé—´åï¼Œé‡æ–°é€‰æ‹©å›¾æ ‡ã€‚",
                recovery: "çŸ¥é“äº†",
                code: "SEAL-CUSTOM-003"
            )
            return false
        }
    }

    func retryInstallationForCurrentSigningSession() async {
        guard let session = signingSession else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] é‡è¯•å®‰è£…: \(session.app.displayName)")
        await load(force: true)
        guard let signedApp = apps.first(where: { $0.id == session.app.id && $0.hasSignedArtifact }) else {
            alertFailure = ImportFailure(
                title: "æ— æ³•é‡æ–°å®‰è£…",
                reason: "æœ¬æœºæ²¡æœ‰å¯ç”¨äºå®‰è£…çš„ç­¾ååŒ…ã€‚",
                recovery: "é‡æ–°ç­¾å",
                code: "SEAL-INSTALL-715"
            )
            return
        }
        let succeeded = await installSignedArtifact(signedApp)
        guard succeeded, let installed = apps.first(where: { $0.id == signedApp.id }) else { return }
        var updatedSession = session
        updatedSession.status = .succeeded(installed)
        signingSession = updatedSession
    }

    func installSignedArtifact(_ app: AppRecord) async -> Bool {
        guard let signingCoordinator else { return false }
        // ç­¾åæˆ–æ‰¹é‡ç»­ç­¾å ç”¨è®¾å¤‡é€šé“æ—¶ï¼Œç”±ä¸‹æ–¹çš„ OperationCoordinator
        // ç­‰å¾…å¹¶ä¸²è¡ŒåŒ–ï¼›å®ƒä»¬æ˜¯æ­£å¸¸è¿ç»­æ“ä½œï¼Œä¸åº”è®©ç”¨æˆ·æ‰‹åŠ¨é‡è¯•ã€‚
        // è¿™é‡Œåªæ‹¦ä½å¦ä¸€æ¡â€œå·²ç­¾ååŒ…å®‰è£…â€æœ¬èº«ï¼Œé¿å…åŒä¸€ä»½ IPA è¢«é‡å¤ä¸‹å‘ã€‚
        guard installingCachedPackageAppID == nil else {
            alertFailure = operationConflictFailure(requested: .installing)
            return false
        }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å®‰è£…å·²ç­¾ååŒ…: \(app.displayName) (\(app.id.uuidString.prefix(8)))")
        guard let operationLease = await acquireOperation(.installing, appID: app.id) else {
            alertFailure = operationConflictFailure(requested: .installing)
            return false
        }
        defer { releaseOperation(operationLease) }
        installingCachedPackageAppID = app.id
        defer { installingCachedPackageAppID = nil }
        do {
            let installed = try await signingCoordinator.installSignedArtifact(
                appID: app.id,
                // è¿™æ¡å…¥å£åŸæ¥ä¼ çš„æ˜¯ç©ºå›è°ƒï¼šSeal ä»ã€Œå·²ç­¾åã€æ¡£é‡æ–°å®‰è£…æ—¶ï¼Œè‡ªæ›¿æ¢
                // æ°¸è¿œæ‹¿ä¸åˆ°ã€Œè¯¥å›ä¸»å±äº†ã€â‡’ installd ä¸€ç›´ç­‰æ—§è¿›ç¨‹è®©ä½ï¼ˆ894 ç§’ä¸Šé™ï¼‰ã€‚
                // ä¸è¯ä¹¦è½®æ¢å­æµç¨‹æ˜¯åŒä¸€ä¸ªå‘ï¼Œä¸€èµ·è¡¥ä¸Šã€‚
                progress: { [weak self] update in
                    await self?.updateSigningStage(update.stage, subject: update.subject)
                }
            )
            try? await logStore?.append(
                category: .signing,
                message: "å·²ä½¿ç”¨æœ¬æœºä¿å­˜çš„ç­¾ååŒ…å®Œæˆå®‰è£…ï¼š\(installed.displayName)"
            )
            await cleanTemporaryFilesIfNeeded(appID: app.id)
            await load(force: true)
            return true
        } catch let failure as ImportFailure {
            alertFailure = failure
            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: "ç­¾ååŒ…å®‰è£…å¤±è´¥ï¼š\(failure.reason)",
                code: failure.code
            )
        } catch {
            try? await logStore?.append(category: .signing, level: .error,
                message: "SEAL-SIGN-500 åº•å±‚è¯Šæ–­ï¼š\(ErrorDiagnosticFormatter.diagnostic(for: error))",
                code: "SEAL-SIGN-500")
            alertFailure = Self.unexpectedSigningFailure(error)
        }
        await load(force: true)
        return false
    }


    /// å¢“ç¢‘è¦è¦†ç›–è¿™ä¸ª App çš„**å…¨éƒ¨**ç”Ÿæ•ˆ Bundle ID å½¢æ€ï¼ˆä¸» App ï¼‹ æ‰©å±•ï¼‰ï¼š
    /// æ‰«å›çš„å€™é€‰æ˜¯æŒ‰è®¾å¤‡ç«¯ profile çš„ Bundle ID **é€ä¸ª**åˆ¤å®šçš„ â€”â€” åªè®°ä¸» Appï¼Œ
    /// æ‰©å±•çš„ profile ä»ä¼šè¢«ææˆå€™é€‰ï¼ˆ`isExtensionBundleID` åªæœ‰åœ¨çˆ¶ App ä¹Ÿåœ¨å€™é€‰é‡Œæ—¶æ‰å‘½ä¸­ï¼‰ã€‚
    private static func tombstoneBundleIdentifiers(for app: AppRecord) -> [String] {
        var identifiers: [String] = []
        if let main = ProfileReclaimPolicy.effectiveBundleID(
            mapped: app.mappedBundleIdentifier,
            preferred: app.preferredBundleIdentifier
        ) {
            identifiers.append(main)
        }
        for extensionRecord in app.extensions {
            if let extensionID = ProfileReclaimPolicy.effectiveBundleID(
                mapped: extensionRecord.mappedBundleIdentifier,
                preferred: nil
            ) {
                identifiers.append(extensionID)
            }
        }
        return identifiers
    }

    func delete(_ app: AppRecord, refreshAfterDeletion: Bool = true) async -> Bool {
        guard let appStore, let fileStore else { return false }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] åˆ é™¤åº”ç”¨: \(app.displayName) (\(app.id.uuidString.prefix(8)))")
        guard let operationLease = await acquireOperation(.maintainingStorage, appID: app.id) else {
            // åå°çš„å»é‡æ¸…ç†ä¸å‰å°åˆ é™¤å…±ç”¨æ­¤æ–¹æ³•ï¼›ä»…å‰å°ç”¨æˆ·åŠ¨ä½œéœ€è¦å¼¹å‡ºå†²çªæç¤ºã€‚
            if refreshAfterDeletion {
                alertFailure = operationConflictFailure(requested: .maintainingStorage)
            }
            return false
        }
        defer { releaseOperation(operationLease) }
        do {
            try await appStore.delete(id: app.id)
            do {
                try await fileStore.removeApp(appID: app.id)
            } catch {
                do {
                    try await appStore.save(app)
                } catch {
                    alertFailure = ImportFailure(
                        title: "åº”ç”¨åˆ é™¤å¤±è´¥",
                        reason: "æœ¬åœ°æ–‡ä»¶åˆ é™¤å¤±è´¥ï¼Œå¹¶ä¸”åº”ç”¨æ•°æ®åº“è®°å½•æœªèƒ½æ¢å¤ã€‚",
                        recovery: "é‡æ–°æ‰“å¼€ Seal è®©å¯åŠ¨æ¢å¤æ£€æŸ¥æœ¬åœ°æ–‡ä»¶",
                        code: "SEAL-APP-ROLLBACK-001"
                    )
                    await load(force: true)
                    return false
                }
                throw error
            }

            // è®°å¢“ç¢‘ï¼šåˆ é™¤è®°å½•**ä¸ä¼š**å¸è½½è®¾å¤‡ä¸Šçš„åº”ç”¨ï¼ˆç¡®è®¤æ–‡æ¡ˆå°±æ˜¯è¿™ä¹ˆå†™çš„ï¼‰ï¼Œ
            // è€Œè®¾å¤‡ç«¯æ‰«å›ä¼šæŠŠã€Œè®¾å¤‡ä¸Šè£…ç€ã€è®°å½•é‡Œæ²¡æœ‰ã€çš„ Seal ç­¾ååº”ç”¨è¡¥å›åˆ—è¡¨ â€”â€”
            // å°‘äº†è¿™ä¸€ç¬”ï¼Œç”¨æˆ·åˆ ä¸€æ¬¡ã€ä¸‹æ¬¡å¯åŠ¨åˆå›æ¥ä¸€æ¬¡ï¼Œæ°¸è¿œåˆ ä¸æ‰ã€‚
            // åªåœ¨**å·²å®‰è£…åˆ—è¡¨**é‡Œçš„è®°å½•ä¸Šè®°ï¼šå¾…ç­¾åè®°å½•æ²¡æœ‰è®¾å¤‡ç«¯ profileï¼Œæ‰«å›æœ¬æ¥å°±çœ‹ä¸è§å®ƒã€‚
            if app.belongsInInstalledList {
                DismissedInstalledRecordTombstones.insert(
                    Self.tombstoneBundleIdentifiers(for: app)
                )
            }

            var historyFailure: ImportFailure?
            if let signingHistoryStore {
                do {
                    try await signingHistoryStore.markDeleted(appID: app.id)
                } catch {
                    historyFailure = ImportFailure(
                        title: "åº”ç”¨å·²åˆ é™¤",
                        reason: "ã€Œ\(app.displayName)ã€å’Œæœ¬åœ°æ–‡ä»¶å·²åˆ é™¤ï¼Œä½†ç­¾åå†å²çŠ¶æ€æœªèƒ½åŒæ­¥ã€‚",
                        recovery: "ç¨ååœ¨è®¾ç½®æ—¥å¿—ä¸­æ ¸å¯¹ï¼›å¦‚ä»å¤±è´¥è¯·é‡æ–°æ‰“å¼€ Seal",
                        code: "SEAL-HISTORY-003"
                    )
                }
            }
            if refreshAfterDeletion {
                await load(force: true)
            }
            if let historyFailure {
                alertFailure = historyFailure
            }
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "æ— æ³•ç§»é™¤åº”ç”¨",
                reason: "ã€Œ\(app.displayName)ã€çš„æœ¬åœ°æ–‡ä»¶æ²¡èƒ½åˆ æ‰ã€‚è¯·å…ˆå®Œå…¨é€€å‡ºå†é‡æ–°æ‰“å¼€ Sealï¼Œç„¶åå†åˆ ä¸€æ¬¡ï¼›å¦‚æœè¿˜æ˜¯åˆ ä¸æ‰ï¼Œ\(ImportFailure.sendLogToAuthor)ã€‚",
                recovery: "çŸ¥é“äº†",
                code: "SEAL-APP-003"
            )
            return false
        }
    }

    func refreshAll() {
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å…¨éƒ¨ç»­ç­¾") }
        let presentsSheet = backgroundBatchPresentationRequested == false
        backgroundBatchPresentationRequested = false
        startBatchRefresh(presentsSheet: presentsSheet)
    }

    /// ã€Œä¸æ‰“å¼€ Appã€çš„ç»­ç­¾å…¥å£ï¼šApp Intentï¼ˆå¿«æ·æŒ‡ä»¤ï¼‰èµ°è¿™é‡Œã€‚
    ///
    /// ä¸ç•Œé¢ä¸Šçš„ã€Œå…¨éƒ¨ç»­ç­¾ã€**å¤ç”¨åŒä¸€æ¡é“¾è·¯**ï¼ˆ`refreshAll` â‡’ `startBatchRefresh`ï¼‰â€”â€”
    /// ã€ŒSeal æœ€åã€æ’åºã€é˜Ÿåˆ—æŒä¹…åŒ–ã€ä¸­æ–­æ¢å¤ã€å•é£é—¸é—¨ï¼ˆ`batchRefreshTask` / `signingTask`ï¼‰
    /// å…¨éƒ¨ä¸€è‡´ã€‚**ä¸è¦**åœ¨è¿™é‡Œå¦èµ·ä¸€å¥—ï¼šé‚£ä¼šç»•è¿‡å•é£åˆ¤æ®ï¼Œé€ å‡ºç¬¬äºŒæ¬¡ installd å‘½ä»¤
    /// ï¼ˆå†å²äº‹æ•…ï¼Œè§å®ˆå« R05ï¼‰ã€‚
    ///
    /// âš ï¸ å¿…é¡»ç•™ç—•ã€Œæ˜¯è°è§¦å‘çš„ã€ï¼šçœŸæœºæ’æŸ¥çš„ç¬¬ä¸€ä¸ªé—®é¢˜æ°¸è¿œæ˜¯ã€Œç”¨æˆ·å½“æ—¶æ˜¯ä¸æ˜¯è‡ªå·±ç‚¹çš„ã€ï¼Œ
    /// è€Œè¿™æ¡é“¾è·¯åœ¨åå°è·‘ã€ç•Œé¢ä¸Šä»€ä¹ˆéƒ½æ²¡æœ‰ â€”â€” æ—¥å¿—æ˜¯å”¯ä¸€çš„è¯æ®ã€‚
    ///
    /// ğŸ”´ **ç‚¹ç«å‰å¿…é¡»å…ˆç­‰è®¾å¤‡é€šé“çœŸæ­£å°±ç»ª**ï¼ˆ2026-09-26 æ„å»º 53 çœŸæœºï¼‰ã€‚
    ///
    /// å¿«æ·æŒ‡ä»¤è§¦å‘èµ°çš„æ˜¯**å†·å¯åŠ¨çš„æ–°è¿›ç¨‹**ï¼ˆ`SEAL-BACKGROUND-001` ä¼šä¸ `-006`
    /// åœ¨åŒä¸€ç§’å‡ºç°ï¼Œå› ä¸ºå®ƒæ˜¯ `SealApp.init()` é‡Œå‘çš„ï¼‰ï¼Œæ­¤æ—¶è®¾å¤‡é€šé“è¿˜åœ¨èµ·æ­¥ã€‚
    /// è€Œ `SigningCoordinator` é‡Œé‚£é“ã€Œprofile-only ä¹‹å‰å…ˆ `isReady()`ã€çš„é—¸é—¨
    /// **åªæ˜¯ä¸€æ¬¡è£¸ TCP å¯è¾¾æ€§æ¢æµ‹**ï¼ˆ`Minimuxer.ready()` â†’ `testDeviceConnection`ï¼Œ
    /// è¿çš„æ˜¯ `rsdPort` / `lockdowndPort`ï¼‰â€”â€” éš§é“ç«¯å£ä¸€é€šå®ƒå°±æ”¾è¡Œã€‚
    /// æ„å»º 53 çš„æ—¥å¿—æ­£æ˜¯è¿™ä¸ªç»„åˆï¼šé—¸é—¨æ”¾è¡Œï¼ˆ**æ²¡æœ‰** `SEAL-PROFILE-360`ï¼‰ï¼Œ
    /// ç´§æ¥ç€ `SEAL-PROFILE-363` çš„ `fallbackReason` å´å†™ç€
    /// ã€Œè®¾å¤‡ç«¯æè¿°æ–‡ä»¶æšä¸¾ä¸å¯ç”¨ï¼ˆé€šé“æœªå°±ç»ªæˆ–è§£æå¤±è´¥ï¼‰ã€ï¼Œ
    /// æœ€ç»ˆä¸¤é¡¹éƒ½ä»¥ `Minimuxer.MinimuxerError 1`ï¼ˆ`NoConnection`ï¼‰å¤±è´¥ï¼›
    /// è€ŒåŒä¸€æ„å»ºã€å‡ åˆ†é’Ÿå‰çš„å‰å°ç»­ç­¾ 2/2 æˆåŠŸã€‚
    /// â‡’ ç‚¹ç«å‰æ”¹ç”¨**å¼ºåˆ¤æ®**ï¼š`installChannel.start()` ä¼šèµ°å®Œæ•´ä¸ªè¯Šæ–­
    /// ï¼ˆreset + RSD æ¡æ‰‹ + è½®è¯¢ï¼›å·²å°±ç»ªæ—¶ 900 ç§’ç¼“å­˜ç§’å›ã€å¤±è´¥ç†”æ–­ 60 ç§’ã€å•é£åˆå¹¶å¹¶å‘å¯åŠ¨ï¼‰ã€‚
    func refreshAllFromBackgroundTrigger() {
        Task { [weak self] in
            guard let self else { return }
            try? try? await self.logStore?.append(
                category: .renewal,
                message: "å¿«æ·æŒ‡ä»¤åœ¨åå°è§¦å‘ã€Œç»­ç­¾å…¨éƒ¨åº”ç”¨ã€ï¼ˆæœªæ‰“å¼€ Appï¼‰",
                code: "SEAL-BACKGROUND-006"
            )
            await self.awaitDeviceChannelBeforeBackgroundRenewal()
            // ğŸ”´ **è®©ä½**ï¼ˆ2026-09-27ï¼‰ï¼šå·²æœ‰ç­¾å/ç»­ç­¾åœ¨è·‘æ—¶**ä¸é‡å¤ç‚¹ç«**ã€‚
            //
            // ä¸¤ç§æƒ…å½¢éƒ½è¦è®©ï¼š
            //   Â· ç”¨æˆ·æ­£åœ¨**æ‰‹åŠ¨**ç»­ç­¾/ç­¾å â‡’ é‚£ä¸€è½®æœ¬æ¥å°±ä¼šæŠŠåº”ç”¨ç»­å®Œï¼Œå†ç‚¹ä¸€æ¬¡ç«
            //     åªä¼šå¤šé€ ä¸€æ¬¡ installd å‘½ä»¤ï¼ˆå†å²äº‹æ•…ï¼Œè§å®ˆå« R05ï¼‰ï¼›
            //   Â· ä¸Šä¸€è½®**åå°**è§¦å‘è¿˜åœ¨è·‘ â‡’ åŒç†ï¼Œé‡å¤ç‚¹ç«æ¯«æ— æ”¶ç›Šã€‚
            // âš ï¸ å¿…é¡»ç•™ç—•ï¼šè¿™æ¡é“¾è·¯åœ¨åå°è·‘ã€ç•Œé¢ä¸Šä»€ä¹ˆéƒ½æ²¡æœ‰ï¼Œæ—¥å¿—æ˜¯å”¯ä¸€è¯æ®ã€‚
            //    æ²¡æœ‰è¿™æ¡æ—¥å¿—æ—¶ï¼Œç”¨æˆ·æŠ¥ã€Œå¿«æ·æŒ‡ä»¤æ²¡ç»­ä¸Šã€ä¸ã€Œå…¶å®è¢«è®©ä½äº†ã€åœ¨æ—¥å¿—ä¸Š
            //    é•¿å¾—ä¸€æ¨¡ä¸€æ ·ã€‚
            guard self.hasActiveSigningWork == false else {
                let blocker = self.activeOperationDescription
                try? try? await self.logStore?.append(
                    category: .renewal,
                    message: "åå°è§¦å‘è®©ä½ï¼š\(blocker)å°šæœªå®Œæˆï¼Œ"
                        + "æœ¬è½®ä¸é‡å¤ç‚¹ç«ï¼ˆè¿›è¡Œä¸­çš„é‚£ä¸€è½®ä¼šå®Œæˆç»­ç­¾ï¼‰",
                    code: "SEAL-BACKGROUND-014"
                )
                // ğŸ”´ **åªç»™ã€Œä¸ä¼šè‡ªåŠ¨è¡¥ä¸Šã€çš„é‚£ä¸€æ¡£å‘é€šçŸ¥**ï¼ˆ2026-09-28 å®šæ¡ˆï¼‰ï¼š
                //   Â· æŒ¡ä½çš„æ˜¯ç­¾å / ç»­ç­¾ â‡’ é‚£ä¸€è½®è‡ªå·±ä¼šç»™å‡ºç»“è®ºï¼ˆåå°è½®ä¼šå‘é€šçŸ¥ï¼Œ
                //     æ‰‹åŠ¨è½®ç”¨æˆ·æ­¤åˆ»å°±åœ¨ App é‡Œçœ‹ç€ï¼‰ï¼Œå†å‘ä¸€æ¡ã€Œæœªæ‰§è¡Œã€åªæ˜¯é‡å¤ï¼›
                //   Â· æŒ¡ä½çš„æ˜¯å¯¼å…¥é…å¯¹æ–‡ä»¶ / ç®¡ç†è¯ä¹¦ç­‰**ä¸ç»è¿‡è¿™ä¸¤ä¸ªä»»åŠ¡**ã€å´åŒæ ·å ç€
                //     è®¾å¤‡é€šé“çš„æ“ä½œ â‡’ é‚£é¡¹æ“ä½œ**æ ¹æœ¬ä¸ä¼šç»­ç­¾**ï¼Œæ²¡æœ‰ä»»ä½•ä¸€è½®ä¼šè¡¥ä¸Šï¼Œ
                //     ç”¨æˆ·ç‚¹äº†å¿«æ·æŒ‡ä»¤å´ä»€ä¹ˆéƒ½æ”¶ä¸åˆ°ï¼ˆæœ€å®¹æ˜“è¯¯åˆ¤æˆã€ŒæˆåŠŸäº†ã€ï¼‰ã€‚
                if self.hasActiveRenewalWork == false {
                    await self.notifyBackgroundRenewalSkipped(
                        .blockedByOtherOperation(blocker)
                    )
                }
                return
            }
            // æ ‡è®°ã€Œè¿™ä¸€è½®æ˜¯å¿«æ·æŒ‡ä»¤ç‚¹ç«çš„ã€â€”â€” æ‰¹é‡æ”¶å°¾å¤„æ®æ­¤å†³å®šè¦ä¸è¦å‘ç³»ç»Ÿé€šçŸ¥ã€‚
            // âš ï¸ æ”¾åœ¨è®©ä½ `guard` **ä¹‹å**ï¼šè¢«è®©ä½æ—¶æœ¬è½®æ ¹æœ¬æ²¡è·‘ï¼Œæ ‡è®°ä¸è¯¥ç½®ä½
            //    ï¼ˆè®©ä½é‚£ä¸€æ¡£è‹¥ç¡®å®éœ€è¦é€šçŸ¥ï¼Œç”±ä¸Šé¢é‚£æ®µ**ç›´æ¥**å‘ï¼Œä¸é è¿™ä¸ªæ ‡è®°ï¼‰ã€‚
            self.backgroundTriggerRequested = true
            self.backgroundBatchPresentationRequested = true
            self.refreshAll()
        }
    }

    /// æ˜¯å¦å·²æœ‰ç­¾å/ç»­ç­¾ï¼ˆæˆ–ä»»ä½•å ç”¨è®¾å¤‡é€šé“çš„æ“ä½œï¼‰åœ¨è·‘ã€‚
    ///
    /// ğŸ”´ ç”¨é€”æ˜¯**è®©ä½**ä¸**ä¸å†é™é»˜ä¸¢å¼ƒ**ï¼ˆ2026-09-27ï¼‰ï¼š
    ///   Â· åå°è§¦å‘ä¸æ‰‹åŠ¨æ“ä½œç›¸é‡æ—¶å¿…é¡»è®©æ‰‹åŠ¨é‚£ä¸€è½®è·‘å®Œï¼Œè€Œä¸æ˜¯é‡å¤ç‚¹ç«ï¼›
    ///   Â· åè¿‡æ¥ï¼Œç”¨æˆ·æ‰‹åŠ¨ç‚¹çš„è¯·æ±‚è¢«åå°æ‰¹é‡æŒ¡ä½æ—¶å¿…é¡»æœ‰å¯è§åé¦ˆï¼ˆè§
    ///     `operationInProgressFailure`ï¼‰ã€‚
    ///
    /// âš ï¸ é™¤ä¸¤ä¸ªä»»åŠ¡å¤–è¿˜è¦çœ‹ `operationCoordinator.activeLease`ï¼šå¯¼å…¥é…å¯¹æ–‡ä»¶ã€
    /// ç®¡ç†è¯ä¹¦ç­‰æ“ä½œ**ä¸ç»è¿‡è¿™ä¸¤ä¸ªä»»åŠ¡**ï¼Œä½†å®ƒä»¬åŒæ ·å ç€è®¾å¤‡é€šé“ â€”â€” åªçœ‹ä»»åŠ¡ä¼šè®©
    /// åå°è§¦å‘åœ¨è¿™ç§æƒ…å†µä¸‹ç…§æ—§ç‚¹ç«ï¼Œç„¶ååœ¨ `runBatchRefresh` çš„å–é”å¤„ç™½ç­‰ 30 ç§’ã€‚
    ///
    /// âš ï¸ **ä¸ `hasActiveRenewalWork` çš„åŒºåˆ«æ˜¯ã€Œé‚£é¡¹æ“ä½œä¼šä¸ä¼šæŠŠåº”ç”¨ç»­å®Œã€**ï¼š
    /// è®©ä½é€šçŸ¥åªå‘ç»™åè€…ä¸ºå‡çš„æƒ…å†µï¼ˆè§ `refreshAllFromBackgroundTrigger`ï¼‰ã€‚
    private var hasActiveSigningWork: Bool {
        hasActiveRenewalWork || operationCoordinator?.activeLease != nil
    }

    /// æ˜¯å¦æœ‰**ç­¾å / ç»­ç­¾**æ­£åœ¨è·‘ï¼ˆå³ã€Œé‚£ä¸€è½®æœ¬èº«ä¼šæŠŠåº”ç”¨ç»­å®Œã€ï¼‰ã€‚
    ///
    /// ğŸ”´ è¿™ä¸ªåŒºåˆ†æ˜¯ 2026-09-28 ä¸ºã€Œè®©ä½è¦ä¸è¦å‘é€šçŸ¥ã€åŠ çš„ï¼šè®©ä½ç»™ç»­ç­¾ â‡’ é‚£ä¸€è½®ä¼šç»™å‡º
    /// ç»“è®ºï¼ˆåå°è½®è‡ªå·±å‘é€šçŸ¥ã€æ‰‹åŠ¨è½®ç”¨æˆ·åœ¨åœºï¼‰â‡’ **ä¸å‘**ï¼›è®©ä½ç»™é…å¯¹å¯¼å…¥ / è¯ä¹¦ç®¡ç†
    /// â‡’ é‚£é¡¹æ“ä½œä¸ç»­ç­¾ã€æ²¡æœ‰ä»»ä½•ä¸€è½®ä¼šè¡¥ä¸Š â‡’ **å¿…é¡»å‘**ã€‚
    private var hasActiveRenewalWork: Bool {
        signingTask != nil || batchRefreshTask != nil
    }

    /// å½“å‰å ç”¨é€šé“çš„æ“ä½œåï¼Œç”¨äºã€Œè®©ä½ã€æ—¥å¿—ä¸å†²çªæç¤ºï¼›è¯»ä¸åˆ°æ—¶ç»™ä¸€å¥å…œåº•ã€‚
    private var activeOperationDescription: String {
        if batchRefreshTask != nil { return "ã€Œç»­ç­¾å…¨éƒ¨åº”ç”¨ã€" }
        if signingTask != nil { return "å•åº”ç”¨ç­¾å / ç»­ç­¾" }
        if let lease = operationCoordinator?.activeLease { return "ã€Œ\(lease.kind.title)ã€" }
        return "å¦ä¸€é¡¹æ“ä½œ"
    }

    /// ã€Œå·²æœ‰æ“ä½œåœ¨è¿›è¡Œã€çš„å¯æ“ä½œæç¤ºï¼ˆ**ä¸å†é™é»˜ä¸¢å¼ƒ**ï¼‰ã€‚
    ///
    /// ğŸ”´ ä¸ºä»€ä¹ˆå¿…é¡»æœ‰ï¼ˆ2026-09-27ï¼‰ï¼šç­¾å/ç»­ç­¾å…¥å£çš„ `guard` åŸæ¥ä¸€å¾‹ç›´æ¥ `return` â€”â€”
    /// ç”¨æˆ·ç‚¹äº†ã€Œç»­ç­¾å…¨éƒ¨ã€/ã€Œç­¾åã€å´**ä»€ä¹ˆéƒ½ä¸å‘ç”Ÿ**ï¼Œæ—¥å¿—é‡Œä¹Ÿä¸€è¡Œæ²¡æœ‰ã€‚
    /// çœŸæœºä¸Šè¿™æœ€å®¹æ˜“è¢«è¯¯è¯»æˆã€Œå¿«æ·æŒ‡ä»¤çš„è‡ªåŠ¨ç»­ç­¾æŠŠé€šé“å ä½äº† / æ‰‹åŠ¨å’Œè‡ªåŠ¨äº’ç›¸å½±å“ã€ï¼Œ
    /// è€Œå®é™…åªæ˜¯ã€Œå‰ä¸€é¡¹è¿˜æ²¡åšå®Œã€ã€‚ç°åœ¨æ˜ç¡®è¯´å‡º**è¢«è°æŒ¡ä½**ã€ä»¥åŠä¸‹ä¸€æ­¥åšä»€ä¹ˆã€‚
    ///
    /// âš ï¸ æ–‡æ¡ˆåˆ»æ„ç‚¹æ˜ã€Œä¹Ÿå¯èƒ½æ˜¯å¿«æ·æŒ‡ä»¤åœ¨åå°è§¦å‘ã€ï¼šåå°é‚£ä¸€è½®**æ²¡æœ‰ç•Œé¢**ï¼Œ
    /// ç”¨æˆ·åªçœ‹åˆ°è‡ªå·±ç‚¹çš„é‚£ä¸€ä¸‹æ²¡ååº”ã€‚
    private static func operationInProgressFailure(blockedBy blocker: String) -> ImportFailure {
        ImportFailure(
            title: "å·²æœ‰æ“ä½œåœ¨è¿›è¡Œ",
            reason: "\(blocker)å°šæœªå®Œæˆï¼ˆå¯èƒ½æ˜¯ä½ åˆšå‘èµ·çš„ï¼Œä¹Ÿå¯èƒ½æ˜¯å¿«æ·æŒ‡ä»¤åœ¨åå°è§¦å‘çš„è‡ªåŠ¨ç»­ç­¾ï¼‰ã€‚"
                + "ä¸ºé¿å…åŒæ—¶æ‰§è¡Œä¸¤æ¬¡å®‰è£…ã€æŠŠè®¾å¤‡ä¸Šçš„åº”ç”¨è£…åï¼Œæœ¬æ¬¡è¯·æ±‚æ²¡æœ‰å¼€å§‹ã€‚",
            recovery: "ç­‰å®ƒå®Œæˆåå†è¯•",
            code: "SEAL-OP-002"
        )
    }

    /// åå°è§¦å‘çš„ç‚¹ç«å‰ç½®ï¼š**å…ˆæŠŠè®¾å¤‡é€šé“æ‹‰èµ·æ¥ï¼Œå†ç»­ç­¾**ï¼ˆè§ `refreshAllFromBackgroundTrigger`ï¼‰ã€‚
    ///
    /// âš ï¸ **åˆ»æ„ä¸è°ƒ `clearFailureCooldown()`**ï¼šé‚£æ˜¯ã€Œç”¨æˆ·ä¸»åŠ¨åˆ·æ–°ã€çš„è¯­ä¹‰ï¼ˆè®¾ç½®é¡µé‡Œç‚¹é‡è¯•ï¼‰ã€‚
    /// è¿™é‡Œåªå€Ÿ `start()` è‡ªå·±çš„ä¸‰ä»¶å¥—ï¼ˆ900 ç§’æˆåŠŸç¼“å­˜ / 60 ç§’å¤±è´¥ç†”æ–­ / å•é£ï¼‰ï¼Œ
    /// æ‰€ä»¥é€šé“æœ¬æ¥å°±å¥½çš„æ—¶å€™å®ƒ**ç§’å›**ï¼Œä¸ä¼šå¹³ç™½å¤šç­‰ä¸€è½® 75 ç§’è¯Šæ–­ã€‚
    ///
    /// âš ï¸ **ç­‰ä¸åˆ°ä¹Ÿå¿…é¡»ç…§å¸¸ç‚¹ç«**ï¼šè¿™æ¡é“¾è·¯çš„ä»·å€¼æ˜¯ã€Œä¸æ‰“å¼€ App ä¹Ÿèƒ½ç»­ã€ï¼Œ
    /// æ”¹æˆã€Œé€šé“ä¸æˆå°±ä»€ä¹ˆéƒ½ä¸åšã€ç­‰äºæŠŠåŠŸèƒ½å…³æ‰ï¼ˆæŠ€èƒ½ Â§7.18 çš„å‘ï¼‰ã€‚
    /// ç­‰ä¸åˆ°å°±ç‚¹ç«ï¼Œè®© `RenewalCoordinator` çš„**é€šé“ç¬æ—¶é”™è¯¯é‡è¯•**å»å…œåº•ï¼Œ
    /// å¹¶ç•™ç—• `-009`ï¼ˆå¸¦åŸå› ä¸ç­‰å¾…ç§’æ•°ï¼‰ä¾›çœŸæœºå¯¹è´¦ã€‚
    private func awaitDeviceChannelBeforeBackgroundRenewal() async {
        guard let installChannel else { return }
        let startedAt = Date()
        try? await logStore?.append(
            category: .renewal,
            message: "åå°è§¦å‘ï¼šå…ˆç¡®è®¤è®¾å¤‡é€šé“å°±ç»ªå†ç‚¹ç«ï¼ˆå†·å¯åŠ¨æ—¶é€šé“å¯èƒ½è¿˜åœ¨èµ·æ­¥ï¼‰",
            code: "SEAL-BACKGROUND-007"
        )
        let failureDetail: String?
        do {
            _ = try await installChannel.start()
            failureDetail = nil
        } catch {
            let nsError = error as NSError
            failureDetail = "\(nsError.domain) \(nsError.code)"
        }
        let waited = Int(Date().timeIntervalSince(startedAt))
        if let failureDetail {
            try? await logStore?.append(
                category: .renewal,
                level: .warning,
                message: "åå°è§¦å‘ï¼šè®¾å¤‡é€šé“æœªå°±ç»ªï¼ˆ\(failureDetail)ï¼‰ï¼Œç­‰å¾… \(waited) ç§’åä»ç…§å¸¸ç‚¹ç«ï¼›"
                    + "æœ¬è½®å¤±è´¥çš„é¡¹ä¼šæŒ‰ã€Œé€šé“ç¬æ—¶é”™è¯¯ã€è‡ªåŠ¨é‡è¯•",
                code: "SEAL-BACKGROUND-009"
            )
        } else {
            try? await logStore?.append(
                category: .renewal,
                message: "åå°è§¦å‘ï¼šè®¾å¤‡é€šé“å·²å°±ç»ªï¼ˆç­‰å¾… \(waited) ç§’ï¼‰ï¼Œå¼€å§‹ç»­ç­¾",
                code: "SEAL-BACKGROUND-008"
            )
        }
    }

    /// ã€Œé‡è¯•å¤±è´¥é¡¹ã€ï¼šåªé‡è¯•ä¸Šä¸€è½®å¤±è´¥çš„ Appï¼Œé¿å…å¯¹å·²æˆåŠŸåº”ç”¨é‡å¤ç­¾å/ä¸Šä¼ /å®‰è£…ã€‚
    func refreshFailedItems() {
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] é‡è¯•å¤±è´¥çš„ç»­ç­¾é¡¹") }
        let failedIDs = batchRefreshSession?.items
            .filter { $0.state == .failed }
            .map { $0.id } ?? []
        guard failedIDs.isEmpty == false else {
            alertFailure = ImportFailure(
                title: "æ— æ³•å®šä½å¤±è´¥é¡¹",
                reason: "æœ¬è½®æ²¡æœ‰å¯è¯†åˆ«çš„å¤±è´¥åº”ç”¨ï¼Œæœªé‡æ–°å¤„ç†å·²æˆåŠŸåº”ç”¨ã€‚",
                recovery: "æŸ¥çœ‹ç»­ç­¾ç»“æœï¼›å¦‚ç¡®éœ€å…¨éƒ¨ç»­ç­¾ï¼Œè¯·é‡æ–°å‘èµ·å…¨éƒ¨ç»­ç­¾",
                code: "SEAL-RENEW-QUEUE-006"
            )
            return
        }
        startBatchRefresh(appIDs: failedIDs)
    }

    /// å–æ¶ˆæœ¬è½®æ‰¹é‡ç»­ç­¾ï¼ˆè¿è¡Œä¸­æŠ½å±‰çš„ã€Œå–æ¶ˆç»­ç­¾ã€ï¼‰ã€‚
    ///
    /// è¯­ä¹‰æ˜¯**è½¯å–æ¶ˆ**ï¼šç«‹å³å…³æ‰ç•Œé¢å¹¶åœæ­¢åç»­é¡¹ï¼Œä½†**å·²ç»å¼€å§‹çš„é‚£ä¸€æ¬¡å®‰è£…ä¸ä¼šè¢«ä¸­æ–­** â€”â€”
    /// `Minimuxer.stageAndInstall` æ˜¯åŒæ­¥é˜»å¡ FFIï¼Œæ²¡æœ‰å–æ¶ˆæœºåˆ¶ï¼Œå¼ºè¡Œä¸¢å¼ƒåªä¼šç•™ä¸‹
    /// ã€ŒåŒ…ä¼ äº†ä¸€åŠã€çš„çŠ¶æ€ã€‚æ‰€ä»¥ï¼š
    ///   - å–æ¶ˆå‘ç”Ÿåœ¨ç­¾å/ç”³è¯·è¯ä¹¦é˜¶æ®µ â†’ åç¨‹åœ¨ä¸‹ä¸€ä¸ª `Task.checkCancellation()` é€€å‡ºï¼Œ
    ///     é˜Ÿåˆ—é¡¹è¢«æ ‡å› `pending`ï¼Œä¸‹æ¬¡ç»­ç­¾ä¼šé‡æ–°å¤„ç†ï¼›
    ///   - å–æ¶ˆå‘ç”Ÿåœ¨å®‰è£…é˜¶æ®µ â†’ æœ¬æ¬¡å®‰è£…ç”± installd è‡ªå·±è·‘å®Œï¼Œåº”ç”¨ä¼šæ­£å¸¸è£…ä¸Šï¼Œ
    ///     è®°å½•åœ¨å®‰è£…æ ¡éªŒé€šè¿‡åç…§å¸¸è½åº“ï¼ˆåˆ—è¡¨åˆ·æ–°å³ä¸ºå‡†ï¼‰ã€‚
    ///
    /// ä¸åšã€Œå‡è£…å·²åœæ­¢ã€çš„å‡è±¡ï¼šæ—¥å¿—é‡Œæ˜ç¡®è®°ä¸€ç¬”ï¼Œç”¨æˆ·ä¸å¼€å‘è€…éƒ½èƒ½å¯¹ä¸Šè´¦ã€‚
    func cancelBatchRefresh() {
        Task { try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å–æ¶ˆæ‰¹é‡ç»­ç­¾") }
        // å·²ç»ˆæ€é¡¹æ•°æ‰æ˜¯çœŸå®å·²å¤„ç†æ•°ï¼›currentIndex æ˜¯æœ€åå®Œæˆé¡¹çš„é˜Ÿåˆ—ä¸‹æ ‡ï¼Œ
        // å¹¶è¡Œæ—¶å®Œæˆé¡ºåºæ˜¯ä¹±çš„ï¼Œä¸èƒ½æ‹¿å®ƒå½“è®¡æ•°ï¼ˆBatchRefreshView åŒä¸€æ•™è®­ï¼‰ã€‚
        let processed = batchRefreshSession?.items.filter {
            switch $0.state {
            case .completed, .failed, .waiting, .awaitingSealConfirmation: return true
            case .running, .preparingSealUpdate: return false
            }
        }.count ?? 0
        let total = batchRefreshSession?.total ?? 0
        batchRefreshTask?.cancel()
        isBatchRefreshSheetPresented = false
        batchRefreshSession = nil
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .renewal,
                level: .warning,
                message: "ç”¨æˆ·å–æ¶ˆæ‰¹é‡ç»­ç­¾ï¼šå·²å¤„ç† \(processed)/\(total)ï¼Œæ­£åœ¨è¿›è¡Œçš„å®‰è£…ä¼šç”±è®¾å¤‡è‡ªè¡Œå®Œæˆ",
                code: "SEAL-RENEW-011"
            )
            await self?.load(force: true)
        }
    }

    func dismissBatchRefresh() {
        isBatchRefreshSheetPresented = false
        guard let batchRefreshSession else { return }
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "æ‰¹é‡ç»­ç­¾ç»“æœæŠ½å±‰å·²å…³é—­ï¼ˆ\(batchRefreshSession.status)ï¼‰", code: "SEAL-RENEW-025") }
        switch batchRefreshSession.status {
        case .preparing, .running, .preparingSealUpdate:
            return
        case .completed, .failed:
            clearPendingBatchResult()
            self.batchRefreshSession = nil
        }
    }

    private func startBatchRefresh(
        appIDs: [UUID]? = nil,
        presentsSheet: Bool = true
    ) {
        guard renewalCoordinator != nil else { return }
        guard batchRefreshTask == nil,
              signingTask == nil else {
            // ä¸å†é™é»˜ä¸¢å¼ƒï¼ˆ2026-09-27ï¼‰ï¼šåŸæ¥è¿™é‡Œç›´æ¥ `return`ï¼Œç”¨æˆ·ç‚¹äº†ã€Œç»­ç­¾å…¨éƒ¨ã€
            // å´ä»€ä¹ˆéƒ½ä¸å‘ç”Ÿã€æ—¥å¿—é‡Œä¹Ÿä¸€è¡Œæ²¡æœ‰ â€”â€” çœŸæœºä¸Šæœ€å®¹æ˜“è¢«è¯¯è¯»æˆ
            // ã€Œå¿«æ·æŒ‡ä»¤çš„è‡ªåŠ¨ç»­ç­¾æŠŠé€šé“å ä½äº† / æ‰‹åŠ¨å’Œè‡ªåŠ¨äº’ç›¸å½±å“ã€ã€‚
            alertFailure = Self.operationInProgressFailure(blockedBy: activeOperationDescription)
            return
        }
        isBackgroundBatchRefresh = presentsSheet == false
        isBatchRefreshSheetPresented = presentsSheet
        batchRefreshSession = BatchRefreshSession()
        batchRefreshTask = Task { [weak self] in
            guard let self else { return }
            // ä¸å†å‰ç½® `await refreshSigningChannel()`ï¼šæ•´æ®µéš§é“è¯Šæ–­ï¼ˆreset + 18s RSD æ¡æ‰‹ +
            // 36Ã—500ms è½®è¯¢ï¼Œç¡¬è¶…æ—¶ 75sï¼‰å‹åœ¨ã€Œæ­£åœ¨è¿æ¥è®¾å¤‡ã€ä¸Šï¼Œæ˜¯ã€Œç‚¹ç»­ç­¾åå¡å¾ˆä¹…ã€çš„
            // ç¬¬äºŒä¸ªå…¥å£ï¼ˆç¬¬ä¸€ä¸ªæ˜¯å•ç­¾ï¼Œè§ runSigningï¼‰ã€‚
            //
            // æ”¹ä¸ºå¹¶è¡Œé¢„çƒ­ï¼šå…ˆæ¸…ç†”æ–­ï¼ˆè¿™æ˜¯ç”¨æˆ·å‘èµ·çš„æ–°ä¼šè¯ï¼‰ï¼Œå†è®©é€šé“åœ¨åå°å¼€å§‹è¯Šæ–­ï¼Œ
            // åŒæ—¶ç«‹åˆ»è¿›å…¥ç»­ç­¾å¾ªç¯ â€”â€” ç¬¬ä¸€ä¸ª App çš„è¯ä¹¦/æè¿°æ–‡ä»¶ç”³è¯·ä¸éš§é“è¯Šæ–­é‡å ï¼Œ
            // å®‰è£…å‰ SigningCoordinator ä¼š await åŒä¸€æ¡é€šé“ï¼ˆé€šé“å±‚å•é£åˆå¹¶ï¼Œåªè¯Šæ–­ä¸€æ¬¡ï¼‰ã€‚
            //
            // é€šé“çœŸä¸å¯ç”¨æ—¶ä¸ä¼šé€€åŒ–æˆ NÃ—75sï¼šé€šé“å±‚æœ‰å¤±è´¥ç†”æ–­ï¼ˆ60 ç§’çª—å£ï¼‰ï¼Œ
            // ç¬¬ä¸€ä¸ª App ä»˜æ‰è¯Šæ–­ä»£ä»·å¹¶å†™å…¥ç†”æ–­ï¼Œåç»­ App åœ¨çª—å£å†…å¿«é€Ÿå¤±è´¥ï¼Œ
            // é€ä¸ªç»™å‡ºå¯æ“ä½œæ–‡æ¡ˆï¼Œè€Œä¸æ˜¯æ•´æ‰¹å¡æ­»åœ¨ä¸€ä¸ªé˜¶æ®µä¸Šã€‚
            await self.installChannel?.clearFailureCooldown()
            self.beginSigningChannel()
            await self.runBatchRefresh(appIDs: appIDs)
        }
    }

    private func presentVPNRecovery(for action: PendingVPNAction) {
        pendingVPNAction = action
        alertFailure = ImportFailure(
            title: "éœ€è¦æ¢å¤è¿æ¥",
            reason: Self.connectionRecoveryReason,
            recovery: "æ¢å¤è¿æ¥",
            code: "SEAL-INSTALL-706"
        )
    }

    /// å¯åŠ¨æ¢å¤ï¼šæŠŠä¸Šä¸€è½®è¢«ä¸­æ–­ç•™ä¸‹çš„ `running` é¡¹é™çº§ä¸º `unknown`ã€‚
    ///
    /// å¿…é¡»æ”¾åœ¨**å¯åŠ¨è·¯å¾„**ä¸Šï¼Œä¸èƒ½ç­‰åˆ°ç»­ç­¾å‰ï¼š`run(queue:)` ä¼šç”¨æ–°é˜Ÿåˆ—æ•´ä½“è¦†ç›–é˜Ÿåˆ—æ–‡ä»¶ï¼Œ
    /// ä¸€æ—¦å¼€å§‹æ–°ä¸€è½®ï¼Œä¸Šä¸€è½®çš„ `running` æ®‹ç•™å°±è¢«å†²æ‰äº†ï¼Œå†æ¢å¤ä¹Ÿæ¥ä¸åŠã€‚
    ///
    /// æ¢å¤åªæ”¹çŠ¶æ€ã€ä¸åšä»»ä½•ç­¾å/å®‰è£…åŠ¨ä½œ â€”â€” è¢«ä¸­æ–­çš„é¡¹ç»“æœæœªçŸ¥ï¼Œè´¸ç„¶é‡åšå¯èƒ½é€ æˆ
    /// ç¬¬äºŒæ¬¡å®‰è£…æˆ–è¯¯åˆ æ–° profileã€‚æ­¤å¤„åªè®©ç”¨æˆ·çŸ¥æƒ…ï¼Œç”±ç”¨æˆ·å†³å®šä¸‹ä¸€æ­¥ã€‚
    func recoverInterruptedQueueIfNeeded() async {
        guard let renewalCoordinator else { return }
        // âš ï¸ **é¡ºåºï¼šå…ˆæ¢å¤æ‰¹é‡ç»­ç­¾ç»“æœï¼Œå†ç»“ç®—é˜Ÿåˆ—ã€‚**
        //
        // Seal è‡ªå·±æ›¿æ¢è‡ªå·±æ—¶ï¼Œè¿›ç¨‹å¿…ç„¶åœ¨é˜Ÿåˆ—é¡¹è¿˜æ˜¯ `running` çš„æ—¶å€™è¢«æ€ã€‚å½“å‰å®ç°å…ˆç”±
        // `SelfAppRegistrar` è¯»å–æ–°è¿è¡ŒåŒ…èº«ä»½ï¼Œå†æŠŠ `awaitingSealConfirmation` ç»“ç®—æˆç»ˆæ€ï¼›
        // è¿™é‡Œä»…æ¶ˆè´¹å·²ç»ç”±æ–°è¿›ç¨‹ç¡®è®¤çš„ç»ˆæ€ï¼Œç»ä¸è®©æ—§è¿›ç¨‹ä¼ªé€ æˆåŠŸã€‚
        restorePendingBatchResultIfNeeded(replacingRestoredSession: true)
        let settled = settledQueueStates(from: loadPendingBatchResultPayload())
        do {
            let outcome = try await renewalCoordinator.recoverInterruptedQueue(settled: settled)
            if outcome.settledFromResult > 0 {
                // æ­£å¸¸è·¯å¾„ä¹Ÿè¦ç•™ç—•ï¼šå¦åˆ™ä¸‹æ¬¡åªçœ‹åˆ°ã€Œ0 ä¸ªæœªçŸ¥ã€ï¼Œ
                // æ— æ³•åˆ¤æ–­æ˜¯ã€Œæœ¬æ¥å°±æ²¡æœ‰è¢«ä¸­æ–­çš„é¡¹ã€è¿˜æ˜¯ã€Œè¢«ç»“æœç»“ç®—æ‰äº†ã€ã€‚
                try? await logStore?.append(
                    category: .renewal,
                    level: .info,
                    message: "ä¸Šæ¬¡ç»­ç­¾è¢«ä¸­æ–­ï¼Œä½† \(outcome.settledFromResult) ä¸ªåº”ç”¨çš„ç»“æœ"
                        + "å·²ä»æŒä¹…åŒ–è½½è·ç»“ç®—ï¼ˆä¸å†æ ‡ä¸ºæœªçŸ¥ï¼‰",
                    code: "SEAL-RENEW-026"
                )
            }
            guard outcome.downgraded > 0 else { return }
            let identifiers = outcome.downgradedAppIDs
                .map(\.uuidString)
                .joined(separator: ", ")
            try? await logStore?.append(
                category: .renewal,
                level: .warning,
                message: "ä¸Šæ¬¡ç»­ç­¾è¢«ä¸­æ–­ï¼Œ\(outcome.downgraded) ä¸ªåº”ç”¨çš„ç»“æœæœªçŸ¥ï¼Œéœ€è¦é‡æ–°æ ¸éªŒ"
                    + "ï¼ˆé˜Ÿåˆ—é¡¹ï¼š\(identifiers)ï¼‰",
                code: "SEAL-RENEW-007"
            )
        } catch {
            let nsError = error as NSError
            try? await logStore?.append(
                category: .renewal,
                level: .warning,
                message: "ç»­ç­¾é˜Ÿåˆ—æ¢å¤å¤±è´¥ï¼š\(nsError.domain) \(nsError.code)",
                code: "SEAL-RENEW-008"
            )
        }
    }

    /// ä»æŒä¹…åŒ–è½½è·é‡Œå–å‡º**å·²ç»æœ‰ç»“è®º**çš„é¡¹ï¼ˆappID â†’ é˜Ÿåˆ—çŠ¶æ€ï¼‰ã€‚
    ///
    /// åˆ¤æ®æœ¬ä½“åœ¨ `PendingBatchResultPayload`ï¼ˆé‚£é‡Œå¯å•æµ‹ â€”â€” æœ¬ç±»æ˜¯ `@MainActor`ã€
    /// ä¾èµ–ä¸€å¤§å †ã€æµ‹è¯•æ„é€ ä¸å‡ºæ¥ï¼‰ï¼›è¿™é‡Œåªç•™ä¸€å±‚è½¬è°ƒï¼Œå…å¾—ã€ŒåŒä¸€æ¡è§„åˆ™ä¸¤ä»½å®ç°ã€ã€‚
    private func settledQueueStates(from payload: [String: Any]?) -> [UUID: RefreshQueueItem.State] {
        PendingBatchResultPayload.settledQueueStates(from: payload)
    }

    private func runBatchRefresh(appIDs: [UUID]? = nil) async {
        // ğŸ”´ **ç¬¬ä¸€ä»¶äº‹å°±æ˜¯è¯»å¹¶æ¸…ä½**ï¼šæ ‡è®°åªå±äºã€Œè¿™ä¸€è½®ã€ï¼Œè€Œæœ¬å‡½æ•°å°±æ˜¯é‚£ä¸€è½®ã€‚
        // æ”¾åœ¨è¿™é‡Œï¼ˆè€Œä¸æ˜¯æ‹¿åˆ° `result` ä¹‹åï¼‰æ˜¯å› ä¸ºæœ¬è½®æœ‰ä¸‰æ¡**ä¸äº§ç”Ÿ result** çš„å‡ºå£ â€”â€”
        // `renewalCoordinator` ç¼ºå¤±ã€æŠ¢ä¸åˆ°æ“ä½œé”ã€ä»¥åŠ `refreshAll` ç›´æ¥æŠ›é”™ â€”â€”
        // è‹¥åªåœ¨æˆåŠŸè·¯å¾„æ¸…ä½ï¼Œæ ‡è®°ä¼š**è·¨è½®å­˜æ´»**ï¼šç”¨æˆ·å…ˆè·‘ä¸€æ¬¡å¤±è´¥çš„å¿«æ·æŒ‡ä»¤ç»­ç­¾ã€
        // ä¹‹åæ‰‹åŠ¨ç‚¹ã€Œç»­ç­¾å…¨éƒ¨ã€æ—¶ä¼šæ”¶åˆ°ä¸€æ¡æœ¬ä¸è¯¥æœ‰çš„é€šçŸ¥ï¼ˆç”¨æˆ·æ˜ç¡®è¦æ±‚æ‰‹åŠ¨ç»­ç­¾ä¸é€šçŸ¥ï¼‰ã€‚
        let wasBackgroundTriggered = consumeBackgroundTriggerFlag()
        guard let renewalCoordinator else { return }
        guard let operationLease = await acquireOperation(.renewing) else {
            batchRefreshSession = nil
            batchRefreshTask = nil
            isBatchRefreshSheetPresented = false
            isBackgroundBatchRefresh = false
            // ç­‰ä¸åˆ°é”ï¼ˆ`beginWaiting` é»˜è®¤ 30 ç§’ï¼‰è¯´æ˜ç¡®å®æœ‰å¦ä¸€é¡¹æ“ä½œé•¿æœŸå ç€é€šé“ â€”â€”
            // å¿…é¡»è¯´å‡ºæ¥ï¼ˆ2026-09-27ï¼‰ï¼šå¦åˆ™ç”¨æˆ·çœ‹åˆ°çš„æ˜¯ã€Œç‚¹äº†ç»­ç­¾ã€æŠ½å±‰ä¸€é—ªå°±æ²¡äº†ã€ï¼Œ
            // æ—¥å¿—é‡Œä¹Ÿåªæœ‰æ²‰é»˜ï¼ŒçœŸæœºä¸Šä¼šè¢«è¯¯è¯»æˆã€Œè¢«å¿«æ·æŒ‡ä»¤çš„è‡ªåŠ¨ç»­ç­¾æŒ¡ä½ã€ã€‚
            alertFailure = operationCoordinator?.conflictFailure(requested: .renewing)
                ?? Self.operationInProgressFailure(blockedBy: activeOperationDescription)
            // ğŸ”´ åå°é‚£ä¸€è½®**æ²¡æœ‰ä»»ä½•ç•Œé¢**ï¼š`alertFailure` è°ä¹Ÿçœ‹ä¸è§ â‡’ å¿…é¡»å‘é€šçŸ¥ï¼Œ
            //    å¦åˆ™ç”¨æˆ·ç‚¹äº†å¿«æ·æŒ‡ä»¤å´ä»€ä¹ˆéƒ½æ”¶ä¸åˆ°ï¼ˆæœ€å®¹æ˜“è¯¯åˆ¤æˆã€Œç»­ç­¾æˆåŠŸäº†ã€ï¼‰ã€‚
            //    è¿™é‡Œå±äºã€Œç­‰ 30 ç§’ä»æ²¡ç­‰åˆ°ã€ä¸ä¼šè‡ªåŠ¨è¡¥ä¸Šã€é‚£ä¸€æ¡£ï¼ˆ2026-09-28 å®šæ¡ˆï¼‰ã€‚
            if wasBackgroundTriggered {
                await notifyBackgroundRenewalSkipped(
                    .operationLockTimeout(activeOperationDescription)
                )
            }
            return
        }
        defer { releaseOperation(operationLease) }
        // æ‰¹é‡ç»­ç­¾åªä½¿ç”¨å·²ä¿å­˜ä¼šè¯ï¼›ä¼šè¯è¿‡æœŸä¼šå¿«é€Ÿå¤±è´¥ï¼Œå¹¶ç»Ÿä¸€å¼•å¯¼åˆ°ã€Œæˆ‘çš„ã€é¡µé‡æ–°éªŒè¯ã€‚
        do {
            // å±€éƒ¨é—­åŒ…å˜é‡é»˜è®¤é€ƒé€¸ï¼Œå¯ç›´æ¥ä¼ ç»™ @escaping å‚æ•°çš„ refreshAll/refreshFailedItemsï¼›
            // å£°æ˜å¤„ä¸èƒ½å†™ @escapingï¼ˆä»…å‡½æ•°å‚æ•°ä½åˆæ³•ï¼‰ã€‚
            let progress: @Sendable (BatchRefreshEvent) async -> Void = { [weak self] event in
                await self?.consumeBatchEvent(event)
            }
            let result: BatchRefreshResult
            let triggerSource: RenewalTriggerSource = wasBackgroundTriggered ? .shortcut : .manual
            if let appIDs {
                result = try await renewalCoordinator.refresh(appIDs: appIDs, triggerSource: triggerSource, progress: progress)
            } else {
                // ğŸ”´ å¿«æ·æŒ‡ä»¤è§¦å‘ = å…¨é‡ç»­ç­¾ï¼ˆ2026-10-03 ç”¨æˆ·æ˜ç¡®è¦æ±‚ï¼‰ï¼š
                // è§¦å‘å°±èµ°ç»­ç­¾ï¼Œä¸åšé¢„æµ‹å¼è¿‡æ»¤ã€‚ä¹‹å‰é¢„æµ‹å¼ï¼ˆ48h çª—å£ï¼‰è®©æµ‹è¯•è¿ç‚¹æ—¶
                // æ¯è½® 0 ä¸ªçº³å…¥ã€é™é»˜ç»“æŸ â€”â€” ç”¨æˆ·è¦çš„æ˜¯"ç‚¹äº†å°±æœ‰åŠ¨ä½œ"ã€‚
                result = try await renewalCoordinator.refreshAll(triggerSource: triggerSource, progress: progress)
            }
            // æ‹¿åˆ°ç»“æœå°±å‘é€šçŸ¥ï¼ˆæ ‡è®°å·²åœ¨å‡½æ•°å…¥å£è¯»å¹¶æ¸…ä½ï¼Œè§é‚£é‡Œçš„è¯´æ˜ï¼‰ã€‚
            if result.total == 0 {
                batchRefreshSession = nil
                if wasBackgroundTriggered {
                    // ğŸ”´ é¢„æµ‹å¼åå°è½®ã€Œæ²¡æœ‰åˆ°æœŸçš„åº”ç”¨ã€æ˜¯**æ­£å¸¸**çš„ï¼ˆè¯´æ˜å¤§å®¶éƒ½è¿˜å¥åº·ï¼‰ï¼Œ
                    // ä¸æ˜¯å¼‚å¸¸ â€”â€” ä¸èƒ½ç•™ä¸€ä¸ªã€Œæ²¡æœ‰å¯ç»­ç­¾çš„åº”ç”¨ã€çš„è¿‡æœŸ alertï¼Œ
                    // å¦åˆ™ä¸‹æ¬¡ç”¨æˆ·è¿› App ä¼šçœ‹åˆ°ä¸€æ¡è«åå…¶å¦™çš„æŠ¥é”™ã€‚
                    // é€šçŸ¥ä¹Ÿä¸å‘ï¼ˆ`notifyBackgroundRenewalIfNeeded` æœ¬æ¥å°±åªåœ¨ total > 0 æ—¶å‘ï¼‰ã€‚
                    try? await logStore?.append(
                        category: .renewal,
                        level: .info,
                        message: "åå°é¢„æµ‹å¼ç»­ç­¾ï¼šæœ¬è½®æ²¡æœ‰éœ€è¦ç»­ç­¾çš„åº”ç”¨ï¼ˆéƒ½åœ¨æœ‰æ•ˆæœŸå†…ï¼‰ï¼Œé™é»˜ç»“æŸ",
                        code: "SEAL-RENEW-029"
                    )
                } else {
                    alertFailure = ImportFailure(
                        title: "æ²¡æœ‰å¯ç»­ç­¾çš„åº”ç”¨",
                        reason: "å½“å‰æ²¡æœ‰å·²å®‰è£…çš„åº”ç”¨è®°å½•",
                        recovery: "çŸ¥é“äº†",
                        code: "SEAL-RENEW-001"
                    )
                }
            } else {
                if result.awaitingConfirmation > 0 {
                    // ä¸èƒ½è®©æ—§è¿›ç¨‹å…³é—­å¹¶æ¸…æ‰è½½è·ã€‚Seal çš„ç»“æœåªèƒ½ç”±ä¸‹ä¸€æ¬¡å¯åŠ¨ä¸­
                    // `SelfAppRegistrar` è¯»çœŸå®è¿è¡ŒåŒ…èº«ä»½åç»“ç®—ã€‚
                    batchRefreshSession?.status = .preparingSealUpdate
                    persistPendingBatchResult(forceSealAwaiting: true)
                } else {
                    batchRefreshSession?.status = .completed(result)
                    // éè‡ªæ›¿æ¢ï¼ˆå« Seal èµ° profile-onlyã€åªæ¢æè¿°æ–‡ä»¶æ²¡æ¢è¿›ç¨‹ï¼‰å·²æ‹¿åˆ°ç»ˆæ€ï¼Œ
                    // ç…§æ ·æŒä¹…åŒ–ã€‚å¿«æ·æŒ‡ä»¤åœ¨åå°è·‘å®Œè¿™ä¸€è½®åè¿›ç¨‹å¾ˆå¯èƒ½è¢«ç³»ç»Ÿå›æ”¶ï¼›åªç•™åœ¨
                    // å†…å­˜é‡Œçš„è¯ï¼Œä¸‹æ¬¡è¿› Seal å°±æ¢å¤ä¸å‡ºã€Œç»­ç­¾æˆåŠŸã€æŠ½å±‰
                    //ï¼ˆ2026-09-29 çœŸæœºåé¦ˆã€Œé€šçŸ¥æˆåŠŸäº†ã€è¿› App æŠ½å±‰å´æœ‰å»¶è¿Ÿã€ï¼‰ã€‚
                    persistPendingBatchResult(forceSealAwaiting: false)
                }
                // ç»­ç­¾å®Œæˆæ¸…ç†å›¾ç‰‡è§£ç ç¼“å­˜ï¼Œé‡Šæ”¾ç»­ç­¾è¿‡ç¨‹ä¸­ç§¯ç´¯çš„å†…å­˜
                clearDecodedIconCache()
                // æ·±åº¦æ¸…ç†ï¼šURLSession ç¼“å­˜ã€ä¸´æ—¶æ–‡ä»¶
                URLCache.shared.removeAllCachedResponses()
                // è®°å½•ç¼“å­˜çŠ¶æ€ç”¨äºè¯Šæ–­å†…å­˜å¢é•¿
                let iconDataCount = iconData.count
                let iconDataBytes = iconData.values.reduce(0) { $0 + $1.count }
                let cacheOrderCount = decodedIconOrder.count
                try? await logStore?.append(
                    category: .system,
                    level: .info,
                    message: "ç»­ç­¾å®Œæˆç¼“å­˜çŠ¶æ€ï¼šiconData \(iconDataCount)é¡¹/\(iconDataBytes/1024)KBï¼Œè§£ç ç¼“å­˜ \(cacheOrderCount)é¡¹",
                    code: "SEAL-MEM-001"
                )
                // ç»­ç­¾å®Œæˆç«‹å³å¼ºåˆ¶é•œåƒæ—¥å¿—åˆ° Documentsï¼Œè·³è¿‡ 30 ç§’èŠ‚æµï¼Œ
                // è®©ç”¨æˆ·è¿›æ—¥å¿—é¡µç«‹é©¬èƒ½çœ‹åˆ°æœ¬è½®æ—¥å¿—ã€‚
                // å¿…é¡» awaitï¼šæ—¥å¿—é¡µæ”¶åˆ° .sealRenewalCompleted åç›´æ¥è¯»æ–‡ä»¶ï¼Œ
                // fire-and-forget ä¼šé€ æˆ"åˆ·æ–°äº†ä½†è¯»åˆ°æ—§æ–‡ä»¶"çš„ç«æ€ã€‚
                // æ³¨æ„é¡ºåºï¼šå¿…é¡»æ”¾åœ¨æ‰€æœ‰ append ä¹‹åï¼Œå¦åˆ™æœ¬è½®æœ€åå‡ æ¡
                // ï¼ˆå«ä¸Šé¢çš„ SEAL-MEM-001ï¼‰è¦ç­‰ä¸‹ä¸ª 30 ç§’çª—å£æ‰è½ç›˜ã€‚
                await logStore?.forceMirrorToDocuments()
                // ç»­ç­¾åç«‹å³é‡æ’é€šçŸ¥ï¼ˆç”¨æ–°åˆ°æœŸæ—¶é—´ï¼‰ï¼Œå¹¶åˆ·æ–°çŠ¶æ€ï¼Œé¿å…æé†’æ—¶é—´æ»å
                // åŒæ—¶åˆ·æ–°å†…å­˜ä¸­çš„åº”ç”¨åˆ—è¡¨ï¼Œè®©å·²å®‰è£…é¡µç«‹å³æ˜¾ç¤ºæ–°æ—¥æœŸ
                // ä¸¤é˜¶æ®µæäº¤ï¼šé‡æ’å®Œæˆåå†å‘ .sealRenewalCompletedï¼Œè§‚å¯Ÿè€…è¯»åˆ°çš„æ˜¯æ–°çŠ¶æ€ï¼Œä¸ç”¨ç¡2ç§’ç¢°è¿æ°”
                await self.rescheduleNotificationsAfterRenewal()
                // é€šçŸ¥åœæ­¢åå°ä¿æ´»ï¼ˆçœç”µï¼‰ï¼šå¿«æ·æŒ‡ä»¤è§¦å‘çš„ç»­ç­¾å·²å®Œæˆï¼Œä¸éœ€è¦å†å åå°
                NotificationCenter.default.post(name: .sealRenewalCompleted, object: nil)
                // è½®æ¬¡æ€»ç»“å·²ç”± RenewalCoordinator å†™å…¥ SEAL-RENEW-ROUND
                //ï¼ˆäººè¯å±‚ï¼šæ¯ App ç»“æœ+è€—æ—¶ã€æœ¬è½®æ€»è€—æ—¶ã€æˆåŠŸ/å¤±è´¥æ•°ï¼‰ï¼Œ
                // è¿™é‡Œä¸å†é‡å¤å†™ SEAL-RENEW-009ï¼Œé¿å…ä¸€è½®ä¸¤æ¡æ€»ç»“ã€‚
                await notifyBackgroundRenewalIfNeeded(
                    wasBackgroundTriggered: wasBackgroundTriggered,
                    result: result
                )
                if result.needsAction > 0 {
                    // å¿…é¡»æ˜¾å¼è¯´å‡ºæ¥ï¼šè¿™äº›åº”ç”¨**æ ¹æœ¬æ²¡è¢«å¤„ç†**ï¼Œè€Œåˆ—è¡¨é‡Œå®ƒä»¬åªæ˜¯ã€Œç­‰å¾…ä¸­ã€ï¼Œ
                    // ä¸è¯´æ¸…æ¥šç”¨æˆ·ä¼šä»¥ä¸ºæ•´è½®éƒ½æˆåŠŸäº†ã€‚
                    alertFailure = ImportFailure(
                        title: "æœ‰ \(result.needsAction) ä¸ªåº”ç”¨æœ¬è½®æœªæ‰§è¡Œ",
                        reason: "å®ƒä»¬ç¼ºå°‘ç»­ç­¾æ‰€éœ€çš„å‰ç½®æ¡ä»¶ï¼Œå¸¸è§åŸå› æ˜¯æ²¡æœ‰å¯ç”¨çš„ Apple è´¦å·ã€‚",
                        recovery: "åˆ°ã€Œæˆ‘çš„ã€æ·»åŠ å¹¶å®Œæˆè´¦å·éªŒè¯åé‡æ–°ç»­ç­¾",
                        code: "SEAL-RENEW-010"
                    )
                }
                await cleanTemporaryFilesIfNeeded()
            }
            await load(force: true)
        } catch is CancellationError {
            batchRefreshSession = nil
            await load(force: true)
            // å–æ¶ˆ**åˆ»æ„ä¸å‘é€šçŸ¥**ï¼šè¿™æ¡è·¯å¾„åªå¯èƒ½æ˜¯æœ¬è½®ä»»åŠ¡è¢«å–æ¶ˆï¼ˆApp è¢«æ”¶èµ° / ç”¨æˆ·ç¦»å¼€ï¼‰ï¼Œ
            // ä¸æ˜¯ã€Œè¯•è¿‡äº†æ²¡æˆã€ï¼Œå¼¹ä¸€æ¡å¤±è´¥é€šçŸ¥ä¼šè¯¯å¯¼ã€‚
        } catch let failure as ImportFailure {
            batchRefreshSession?.status = .failed(Self.renewalGuidance(for: failure))
            // ğŸ”´ æ•´è½®æŠ›é”™æ˜¯**æœ€å¤§çš„é™é»˜å£å­**ï¼ˆ2026-09-28 æŒ–å‡ºï¼‰ï¼šåŸæ¥åªå†™è¿›
            //    `batchRefreshSession.status`ï¼Œè€Œå¿«æ·æŒ‡ä»¤é‚£ä¸€è½®æ ¹æœ¬æ²¡æœ‰ç•Œé¢ â‡’ ç”¨æˆ·
            //    ä»€ä¹ˆéƒ½æ”¶ä¸åˆ°ã€‚é€é¡¹ `failed` è®¡æ•°è¦†ç›–ä¸åˆ°è¿™é‡Œï¼ˆæ•´è½®æ²¡äº§å‡º resultï¼‰ã€‚
            if wasBackgroundTriggered {
                await notifyBackgroundRenewalSkipped(.roundFailed(title: failure.title))
            }
        } catch {
            batchRefreshSession?.status = .failed(
                ImportFailure(
                    title: "æ— æ³•ç»­ç­¾åº”ç”¨",
                    reason: "æœ¬è½®ç»­ç­¾æ²¡èƒ½è·‘å®Œï¼ŒSeal æ²¡æ‹¿åˆ°å…·ä½“åŸå› ã€‚ç¨ç­‰ç‰‡åˆ»åé‡æ–°å‘èµ·ç»­ç­¾ï¼›å¦‚æœåå¤å¤±è´¥ï¼Œ\(ImportFailure.sendLogToAuthor)ã€‚",
                    recovery: "çŸ¥é“äº†",
                    code: "SEAL-RENEW-500a"
                )
            )
            if wasBackgroundTriggered {
                await notifyBackgroundRenewalSkipped(.roundFailed(title: "æ— æ³•ç»­ç­¾åº”ç”¨"))
            }
        }
        if wasBackgroundTriggered {
            // æ—§è¿›ç¨‹çš„å®‰è£…é˜¶æ®µç»ä¸èƒ½é—ç•™ç»™æ–°è¿›ç¨‹æ˜¾ç¤ºï¼›æœ€ç»ˆç»“æœå·²åœ¨ä¸Šé¢æŒä¹…åŒ–ã€‚
            batchRefreshSession = nil
        }
        batchRefreshTask = nil
        isBackgroundBatchRefresh = false
    }

    /// è¯»ä¸€æ¬¡å¹¶æ¸…ä½ã€‚**åœ¨ `runBatchRefresh` å…¥å£å¤„è°ƒç”¨**ï¼ˆæ‹¿åˆ° `result` ä¹‹å‰ï¼‰â€”â€”
    /// æœ¬è½®æœ‰ä¸‰æ¡ä¸äº§ç”Ÿ `result` çš„å‡ºå£ï¼ˆåè°ƒå™¨ç¼ºå¤±ã€æŠ¢ä¸åˆ°é”ã€æ•´è½®æŠ›é”™ï¼‰ï¼Œ
    /// åªåœ¨æˆåŠŸè·¯å¾„æ¸…ä½ä¼šè®©æ ‡è®°è·¨è½®å­˜æ´»ï¼Œå®³å¾—ä¹‹åçš„æ‰‹åŠ¨ç»­ç­¾è¯¯å‘é€šçŸ¥ã€‚
    private func consumeBackgroundTriggerFlag() -> Bool {
        let requested = backgroundTriggerRequested
        backgroundTriggerRequested = false
        return requested
    }

    /// ç»­ç­¾åé‡æ’é€šçŸ¥ï¼šawait å®Œæˆåæ‰è¿”å›ï¼Œè°ƒç”¨æ–¹å‘ .sealRenewalCompleted æ—¶çŠ¶æ€å·²æ˜¯æ–°çš„ã€‚
    /// ä¸¤é˜¶æ®µæäº¤çš„ä¸€éƒ¨åˆ†ï¼šæ¶ˆé™¤ fire-and-forget + ç¡2ç§’çš„ç«æ€ã€‚
    private func rescheduleNotificationsAfterRenewal() async {
        await self.load(force: true)
        let hasScheduler = self.notificationScheduler != nil
        let hasPrefs = self.notificationPreferences != nil
        let hasStore = self.appStore != nil
        try? await self.logStore?.append(
            category: .system,
            level: .info,
            message: "[SEAL-NOTIF-DBG] ç»­ç­¾åé‡æ’é€šçŸ¥ï¼šscheduler=\(hasScheduler), prefs=\(hasPrefs), store=\(hasStore)"
        )
        if let scheduler = self.notificationScheduler,
           let prefs = self.notificationPreferences,
           let store = self.appStore {
            let apps = (try? await store.fetchAll()) ?? []
            try? await self.logStore?.append(
                category: .system,
                level: .info,
                message: "[SEAL-NOTIF-DBG] é‡æ’é€šçŸ¥ï¼šapps=\(apps.count), enabled=\(prefs.isEnabled)"
            )
            do {
                try await scheduler.reschedule(apps: apps, enabled: prefs.isEnabled, leadHours: prefs.leadHours)
                try? await self.logStore?.append(
                    category: .system,
                    level: .info,
                    message: "[SEAL-NOTIF-DBG] é‡æ’é€šçŸ¥æˆåŠŸ"
                )
            } catch {
                try? await self.logStore?.append(
                    category: .system,
                    level: .error,
                    message: "[SEAL-NOTIF-DBG] é‡æ’é€šçŸ¥å¤±è´¥ï¼š\(error.localizedDescription)"
                )
            }
        }
    }

    /// å¿«æ·æŒ‡ä»¤åå°ç»­ç­¾ç»“æŸåçš„**ç³»ç»Ÿé€šçŸ¥**ï¼ˆæˆåŠŸã€éƒ¨åˆ†å¤±è´¥ã€å…¨å¤±è´¥éƒ½èµ°è¿™é‡Œï¼‰ã€‚
    ///
    /// ğŸ”´ åªæœ‰å¿«æ·æŒ‡ä»¤ç‚¹ç«çš„é‚£ä¸€è½®ä¼šèµ°åˆ°è¿™é‡Œï¼ˆ`wasBackgroundTriggered` æ¥è‡ª
    /// `refreshAllFromBackgroundTrigger()` ç½®çš„è¯·æ±‚çº§æ ‡è®°ï¼‰ï¼›Seal å†…æ‰‹åŠ¨ã€Œç»­ç­¾å…¨éƒ¨ã€
    /// æ°¸è¿œæ˜¯ `false`ï¼Œç”¨æˆ·æ˜ç¡®è¦æ±‚æ‰‹åŠ¨ç»­ç­¾ä¸å‘é€šçŸ¥ã€‚
    ///
    /// åˆ¤æ®ä¸æ–‡æ¡ˆåœ¨ `BackgroundRenewalNotificationResult`ï¼ˆçº¯ç±»å‹ã€å¯å•æµ‹ï¼‰ï¼›
    /// æ²¡æƒé™æ—¶åªç•™æ—¥å¿—ã€ä¸å»è¦æƒé™ï¼ˆåŸå› è§ `BackgroundRenewalNotifier`ï¼‰ã€‚
    private func notifyBackgroundRenewalIfNeeded(
        wasBackgroundTriggered: Bool,
        result: BatchRefreshResult
    ) async {
        guard wasBackgroundTriggered else { return }
        guard let backgroundRenewalNotifier else { return }
        let delivery = await backgroundRenewalNotifier.post(
            BackgroundRenewalNotificationResult(
                total: result.total,
                succeeded: result.succeeded,
                failed: result.failed,
                needsAction: result.needsAction,
                awaitingConfirmation: result.awaitingConfirmation
            )
        )
        // æ— è®ºå‘æ²¡å‘éƒ½ç•™ç—•ï¼šçœŸæœºä¸Šã€Œç”¨æˆ·è¯´æ²¡æ”¶åˆ°é€šçŸ¥ã€ä¸ã€Œå…¶å®æ²¡ç»™æƒé™ã€å¿…é¡»èƒ½åˆ†è¾¨ã€‚
        try? await logStore?.append(
            category: .renewal,
            level: delivery == .delivered ? .info : .warning,
            message: "å¿«æ·æŒ‡ä»¤åå°ç»­ç­¾é€šçŸ¥ï¼š\(Self.describeNotificationDelivery(delivery))",
            code: "SEAL-BACKGROUND-015"
        )
    }

    /// æœ¬è½®**æ ¹æœ¬æ²¡è·‘èµ·æ¥**æ—¶çš„é€šçŸ¥ï¼ˆè®©ä½ç»™éç»­ç­¾æ“ä½œ / ç­‰é”è¶…æ—¶ / æ•´è½®æŠ›é”™ï¼‰ã€‚
    ///
    /// ğŸ”´ ä¸‰ç§æƒ…å½¢éƒ½**ä¸ä¼šè‡ªåŠ¨è¡¥ä¸Š**ï¼Œè€Œå¿«æ·æŒ‡ä»¤é‚£ä¸€è½®æ²¡æœ‰ç•Œé¢ â‡’ ä¸å‘å°±æ˜¯é™é»˜ä¸¢å¤±ã€‚
    /// è®©ä½ç»™ã€Œç­¾å/ç»­ç­¾ã€çš„é‚£ä¸€æ¡£åˆ»æ„ä¸èµ°è¿™é‡Œï¼ˆé‚£ä¸€è½®è‡ªå·±ä¼šç»™å‡ºç»“è®ºï¼‰ã€‚
    private func notifyBackgroundRenewalSkipped(
        _ reason: BackgroundRenewalSkippedNotice.Reason
    ) async {
        guard let backgroundRenewalNotifier else { return }
        let delivery = await backgroundRenewalNotifier.post(
            BackgroundRenewalSkippedNotice(reason: reason)
        )
        try? await logStore?.append(
            category: .renewal,
            level: delivery == .delivered ? .info : .warning,
            message: "å¿«æ·æŒ‡ä»¤åå°ç»­ç­¾é€šçŸ¥ï¼ˆæœªæ‰§è¡Œ/æ•´è½®å¤±è´¥ï¼‰ï¼š"
                + "\(Self.describeNotificationDelivery(delivery))",
            code: "SEAL-BACKGROUND-016"
        )
    }

    private static func describeNotificationDelivery(
        _ delivery: BackgroundRenewalNotificationDelivery
    ) -> String {
        switch delivery {
        case .delivered:
            return "å·²å‘å‡º"
        case .skippedNothingToRenew:
            return "æœ¬è½®æ²¡æœ‰éœ€è¦ç»­ç­¾çš„é¡¹ï¼ŒæŒ‰è§„åˆ™ä¸å‘"
        case .skippedNotAuthorized:
            return "ç”¨æˆ·æœªå¼€å¯ Seal çš„é€šçŸ¥æƒé™ï¼Œæœªå‘å‡º"
        case .failed(let detail):
            return "æŠ•é€’å¤±è´¥ï¼š\(detail)"
        }
    }

    /// æ‰¹é‡ç»­ç­¾å¤±è´¥æ–‡æ¡ˆå¼•å¯¼ï¼šè®¤è¯/ä¼šè¯ç±»é—®é¢˜ç»Ÿä¸€å¼•å¯¼åˆ°â€œæˆ‘çš„â€é¡µé‡æ–°éªŒè¯ï¼›
    /// ç½‘ç»œç±»ä¸å…¶ä»–å¤±è´¥ä¿ç•™åŸå§‹å¯æ“ä½œä¿¡æ¯ã€‚
    private static func renewalGuidance(for failure: ImportFailure) -> ImportFailure {
        guard failure.code.hasPrefix("SEAL-AUTH-") else { return failure }
        return ImportFailure(
            title: "Apple ID ä¸å¯ç”¨",
            reason: "æœ¬è½®ç»­ç­¾å› ä¸º Apple ID çš„é—®é¢˜æ²¡èƒ½å®Œæˆï¼šå¯èƒ½è¿˜æ²¡æ·»åŠ è´¦å·ã€è´¦å·å·²è¢«åˆ é™¤ï¼Œæˆ–ç™»å½•ä¼šè¯è¿‡æœŸã€‚è¯·åˆ°ã€Œæˆ‘çš„ã€é‡Œæ·»åŠ è´¦å·æˆ–é‡æ–°éªŒè¯åå†ç»­ç­¾ã€‚",
            recovery: "çŸ¥é“äº†",
            code: failure.code
        )
    }

    private func consumeBatchEvent(_ event: BatchRefreshEvent) {
        guard batchRefreshSession != nil else { return }
        switch event {
        case .prepared(let apps):
            batchRefreshSession?.items = apps.map {
                BatchRefreshSession.Item(id: $0.id, name: $0.displayName, isSeal: $0.isSeal, state: .waiting)
            }
            batchRefreshSession?.total = apps.count
        case .started(let total):
            batchRefreshSession?.total = total
            batchRefreshSession?.status = .running
        case .appInstallProgress(let index, let total, let app, let progress):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.recordInstallProgress(progress)
        case .appWorkUnits(_, _, _, let units):
            // é˜¶æ®µå†…éƒ¨çš„å¯æ•°è¿›åº¦ï¼šåªå–‚åº•éƒ¨è½¨é“ï¼Œ**ä¸åŠ¨é˜¶æ®µã€ä¸åŠ¨ä»»ä½•è®¡æ•°**ã€‚
            // index / app è¿™é‡Œç”¨ä¸ä¸Šï¼ˆä¼šè¯å·²æŒ‰ .appProgress å¯¹é½åˆ°å½“å‰é¡¹ï¼‰ï¼Œ
            // é‡‡ä¿¡ä¸ä¸¢å¼ƒéƒ½é›†ä¸­åœ¨ `recordWorkUnits` é‡Œã€‚
            batchRefreshSession?.recordWorkUnits(units)
        case .appRenewalExecutionPath(let index, let total, let app, let path):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.currentRenewalExecutionPath = path
        case .appAwaitingSealConfirmation(let index, let total, let app):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.currentInstallProgress = nil
            batchRefreshSession?.installStartedAt = nil
            batchRefreshSession?.status = .preparingSealUpdate
            updateBatchItem(
                appID: app.id,
                name: app.displayName,
                isSeal: true,
                state: .awaitingSealConfirmation
            )
        case .appProgress(let index, let total, let app, let stage):
            if batchRefreshSession?.currentIndex != index {
                batchRefreshSession?.currentRenewalExecutionPath = nil
            }
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            // é˜¶æ®µæ¨è¿›é›†ä¸­èµ° advanceStageï¼šå®ƒåŒæ—¶è´Ÿè´£å®‰è£…èµ·ç‚¹è®¡æ—¶ä¸ä¸Šä¼ è¿›åº¦çš„æ¸…ç†ï¼Œ
            // é¿å…ã€Œä¸Šä¸€é¡¹çš„ 87% / å·²ç­‰å¾…ã€æ³„æ¼åˆ°ä¸‹ä¸€é¡¹ã€‚
            // å®ƒè¿”å›çš„ `Tick` åŒæ—¶æ˜¯ã€Œæ˜¯å¦é¦–æ¬¡è¿›å…¥è¯¥é˜¶æ®µã€çš„åˆ¤æ® â€”â€” ä¸‹é¢è§¦å‘ã€Œå›ä¸»é¡µã€è¦ç”¨ã€‚
            // `?? .clear` åªæ˜¯è®©ç±»å‹ç¡®å®šä¸‹æ¥ï¼›å‡½æ•°å¼€å¤´çš„ `guard batchRefreshSession != nil`
            // å·²ç»ä¿è¯è¿™é‡Œæ‹¿å¾—åˆ°çœŸå®çš„ `Tick`ã€‚
            let tick = batchRefreshSession?.advanceStage(stage) ?? .clear
            let itemState: BatchRefreshSession.Item.State = app.isSeal && (stage == .pushing || stage == .installing) ? .preparingSealUpdate : .running
            if app.isSeal && (stage == .pushing || stage == .installing) {
                batchRefreshSession?.status = .preparingSealUpdate
                persistPendingBatchResult(forceSealAwaiting: true)
                // æ‰¹é‡ç»­ç­¾ Sealï¼šè¿›å…¥ .installingï¼ˆä¸Šä¼ å®Œæˆï¼‰ååŒæ ·è‡ªåŠ¨å›ä¸»é¡µè§¦å‘ iOS æ›¿æ¢ï¼Œ
                // ä¸å•ç­¾ SigningProgressView è¡Œä¸ºä¸€è‡´ã€‚Seal è‡ªç»­ç­¾å¿…ç„¶æ›¿æ¢è¿è¡Œä¸­çš„è‡ªå·±ï¼Œ
                // è¿›ç¨‹ä¼šè¢«æ–°åŒ…ç»ˆæ­¢ï¼Œå…¶åæ’é˜Ÿçš„ç»­ç­¾é¡¹ä¼šä¸€å¹¶ä¸­æ–­ï¼ˆä¸æ‰‹æŒ‰ Home ç›¸åŒï¼‰ã€‚
                //
                // `.restart` é—¸é—¨ï¼š`.installing` ä¼šè¢«**é‡å¤æ¨é€**ï¼Œä¸è®¾é—¸é—¨å°±ä¼šæ’å‡ºå¤šä¸ª
                // ã€Œå›ä¸»é¡µã€ä»»åŠ¡ã€‚è¿™ç§é‡å¤æœ¬èº«æ˜¯è‰¯æ€§çš„ï¼ˆç¬¬ä¸€ä¸ªä»»åŠ¡è½¬åœºåè¿›ç¨‹è¢«æŒ‚èµ·ï¼Œåç»­
                // ä»»åŠ¡ä¸ä¼šæ‰§è¡Œï¼›è½¬åœºå¤±è´¥æ—¶ç¬¬ä¸€ä¸ª `exit(0)` å·²ç»“æŸè¿›ç¨‹ï¼‰ï¼Œä½†**æ¯ä¸ªä»»åŠ¡éƒ½ä¼š
                // å†™ä¸€éã€Œä¸Šä¼ å®Œæˆ / è§¦å‘è½¬åœºã€æ—¥å¿—**ï¼ŒæŠŠçœŸæœºæ’æŸ¥æœ€å…³é”®çš„é‚£æ®µæ—¶åºä¿¡æ¯æ·¹æ²¡ã€‚
                // å•ç­¾é‚£æ¡é“¾è·¯æœ¬æ¥å°±ç”¨åŒä¸€ä¸ªé—¸é—¨ï¼Œè¿™é‡Œä¸å®ƒå¯¹é½ã€‚
                if stage == .installing, tick == .restart {
                    SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)
                }
            } else {
                batchRefreshSession?.status = .running
            }
            updateBatchItem(appID: app.id, name: app.displayName, isSeal: app.isSeal, state: itemState, stage: stage)
        case .appSucceeded(let index, let total, let app):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.currentInstallProgress = nil
            batchRefreshSession?.installStartedAt = nil
            batchRefreshSession?.succeeded += 1
            updateBatchItem(appID: app.id, name: app.displayName, isSeal: app.isSeal, state: .completed)
            Task { [weak self] in
                await self?.recordSigningHistory(
                    app: app,
                    action: .renew,
                    result: .success,
                    attemptedBundleIdentifier: app.preferredBundleIdentifier ?? app.mappedBundleIdentifier,
                    finalSignedBundleIdentifier: app.mappedBundleIdentifier,
                    lifecycleStatus: .active
                )
            }
        case .appFailed(let index, let total, let app, let failure):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.currentInstallProgress = nil
            batchRefreshSession?.installStartedAt = nil
            // ã€Œæœ¬è½®æœªæ‰§è¡Œã€ä¸æ˜¯å¤±è´¥ï¼šå®ƒæ ¹æœ¬æ²¡è¢«å°è¯•è¿‡ï¼Œä¸‹ä¸€æ­¥åŠ¨ä½œä¹Ÿä¸åŒï¼ˆå»è¡¥å‰ç½®æ¡ä»¶ï¼Œ
            // ä¸æ˜¯é‡è¯•ï¼‰ã€‚å¤ç”¨å¤±è´¥äº‹ä»¶åªæ˜¯ä¸ºäº†è®©å®ƒåœ¨åˆ—è¡¨é‡Œå¯è§ï¼Œè®¡æ•°ä¸çŠ¶æ€éƒ½å¿…é¡»åˆ†å¼€ï¼Œ
            // å¦åˆ™ç”¨æˆ·ä¼šä»¥ä¸ºã€Œé‡è¯•å°±èƒ½å¥½ã€ï¼Œè€ŒçœŸå®åŸå› æ˜¯ç¼ºè´¦å·ã€‚
            let isNeedsAction = failure.code == RenewalCoordinator.requiresActionCode
            if isNeedsAction == false {
                batchRefreshSession?.failed += 1
            }
            updateBatchItem(
                appID: app.id,
                name: app.displayName,
                isSeal: app.isSeal,
                state: isNeedsAction ? .waiting : .failed
            )
            Task { [weak self] in
                await self?.recordSigningHistory(
                    app: app,
                    action: .renew,
                    result: .failed,
                    attemptedBundleIdentifier: app.preferredBundleIdentifier ?? app.mappedBundleIdentifier,
                    lifecycleStatus: app.belongsInInstalledList ? .active : .unknown,
                    failure: failure
                )
            }
        }
    }

    private func updateBatchItem(
        appID: UUID,
        name: String,
        isSeal: Bool,
        state: BatchRefreshSession.Item.State,
        stage: SigningStage? = nil
    ) {
        guard batchRefreshSession != nil else { return }
        if let index = batchRefreshSession?.items.firstIndex(where: { $0.id == appID }) {
            batchRefreshSession?.items[index].name = name
            batchRefreshSession?.items[index].isSeal = isSeal
            batchRefreshSession?.items[index].state = state
            batchRefreshSession?.items[index].stage = stage
        } else {
            batchRefreshSession?.items.append(.init(id: appID, name: name, isSeal: isSeal, state: state, stage: stage))
        }
    }

    /// æŠŠå½“å‰æ‰¹é‡ç»­ç­¾ç»“æœæŒä¹…åŒ–åˆ°è½½è·ï¼Œä¾›ä¸‹æ¬¡å¯åŠ¨æ¢å¤ç»“æœæŠ½å±‰ã€‚
    ///
    /// - Parameter forceSealAwaiting: æ˜¯å¦æŠŠ Seal é¡¹å†™æˆ `awaitingSealConfirmation`ã€‚
    ///   åªæœ‰ã€ŒSeal è¦†ç›–å®‰è£…å·²æäº¤ã€ç­‰å¾…æ–°è¿›ç¨‹æ ¸éªŒè¿è¡ŒåŒ…èº«ä»½ã€æ—¶æ‰è¯¥ä¼  `true`ï¼›
    ///   å…¶ä½™ï¼ˆæ²¡æœ‰ Sealï¼Œæˆ– Seal èµ° profile-onlyã€åªæ¢æè¿°æ–‡ä»¶æ²¡æ¢è¿›ç¨‹ï¼‰éƒ½å·²æ‹¿åˆ°ç»ˆæ€ï¼Œ
    ///   å¿…é¡»ä¼  `false` â€”â€” å¦åˆ™è½½è·ä¼šæŠŠä¸€ä¸ªå…¶å®å·²ç»æˆåŠŸçš„ Seal è®°æˆã€Œç­‰å¾…æ ¸éªŒã€ï¼Œ
    ///   ä¸‹æ¬¡å¯åŠ¨éä½†æ¢å¤ä¸å‡ºæˆåŠŸï¼Œè¿˜ä¼šè¯¯æ ‡æˆã€Œç»“æœæœªçŸ¥ã€ã€‚
    private func persistPendingBatchResult(forceSealAwaiting: Bool) {
        guard let session = batchRefreshSession else {
            Task { try? await logStore?.append(category: .renewal, level: .warning, message: "æ‰¹é‡ç»­ç­¾ç»“æœæœªèƒ½æŒä¹…åŒ–ï¼šå½“å‰æ²¡æœ‰è¿›è¡Œä¸­çš„ä¼šè¯", code: "SEAL-RENEW-022") }
            return
        }
        let itemPayload = session.items.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "name": item.name,
                "isSeal": item.isSeal,
                "state": (item.isSeal && forceSealAwaiting)
                    ? BatchRefreshSession.Item.State.awaitingSealConfirmation.storageValue
                    : item.state.storageValue
            ]
        }
        let succeeded = itemPayload.filter { ($0["state"] as? String) == "completed" }.count
        let payload: [String: Any] = [
            "succeeded": succeeded,
            "failed": session.failed,
            "total": session.total,
            "timestamp": Date().timeIntervalSince1970,
            "items": itemPayload
        ]
        UserDefaults.standard.set(payload, forKey: Self.pendingBatchResultKey)
        UserDefaults.standard.synchronize()
        // åŒä¿é™©ï¼šåŒæ—¶å†™å…¥ JSON æ–‡ä»¶ï¼Œé¿å… Seal è‡ªç­¾è¦†ç›–å®‰è£…æ—¶ UserDefaults ä¸¢å¤±
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.pendingBatchResultFileURL, options: .atomic)
        }
        let sealNote = forceSealAwaiting ? "Seal ç­‰å¾…æ–°è¿›ç¨‹æ ¸éªŒ" : "Seal æ— å¾…æ ¸éªŒé¡¹"
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "æ‰¹é‡ç»­ç­¾ç»“æœå·²æŒä¹…åŒ–ï¼ˆå…± \(session.total)ï¼ŒæˆåŠŸ \(succeeded)ï¼Œå¤±è´¥ \(session.failed)ï¼Œ\(sealNote)ï¼Œæ˜ç»† \(itemPayload.count) é¡¹ï¼‰", code: "SEAL-RENEW-023") }
    }

    /// è¯»å–ã€Œå¾…æ¢å¤çš„æ‰¹é‡ç»­ç­¾ç»“æœã€è½½è·ã€‚
    ///
    /// ä¼˜å…ˆä»æ–‡ä»¶è¯»å–ï¼ˆæ›´å¯é ï¼Œé¿×­µçkh‘éì¶»§q«^u]J
BˆHØ]Ú]˜Z[\™H\È[\Ü˜Z[\™HÂˆ[\˜Z[\™HH˜Z[\™Bˆ™]\›ˆš[ˆHØ]ÚÂˆ[\˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åykï9aîºacykîy¥¡ù.íˆ‹ˆ™X\ÛÛˆ¹§+9§.ºacykîy¥¡ù.í¹¥è9¬åz+îùcå¹¢%¹¨(zj£9§*º`&º/áøà ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬9kï9aizacykîy¥¡ù.í¹d#¹a£z+åH‹ˆÛÙNˆ”ÑPSTRT‹LŒXH‚ˆ
Bˆ™]\›ˆš[ˆBˆB‚ˆ[˜È\İÛÛ›™Xİ[ÛŠ
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9­bú+åz/ç¹£©HŠBˆ]ØZ]ØY
›Ü˜ÙNˆYJBˆİX\™XYÛ›ÜİXÔİ]HOHœ[›š[™Ë[œİ[Ú[›™[OHš[[ÙHÈ™]\›ˆBˆİX\™XØÛİ[Ëš\Ñ[\HOH˜[ÙKˆ]XØÛİ[ÛY[ˆ]Ù^XÚZ[‹ˆ]XØÛİ[™\ÜÚ]ÜH[ÙHÂˆXYÛ›ÜİXÔİ]HH™˜Z[Y
ˆÙ[‹™˜Z[\™Jˆ]Nˆ¹ï.¹l$yëo¹d#z-)¹cíÈ‹ˆ™X\ÛÛˆ¹l&¹§*¹­îùb¨\HQ‹ˆ™XÛİ™\Nˆ¹­îùb¨:-)¹cíÈ‹ˆÛÙNˆ”ÑPSPUULLH‚ˆ
Bˆ
Bˆ™]\›‚ˆBˆİX\™Z\š[™Ô™XÛÜ™OHš[[ÙHÂˆXYÛ›ÜİXÔİ]HH™˜Z[Y
ˆÙ[‹™˜Z[\™Jˆ]Nˆº+¯¹i!ù§*ºacykîH‹ˆ™X\ÛÛˆ¹l&¹§*¹k£9¢$9odùbcz+¯¹i!úacykîH‹ˆ™XÛİ™\Nˆº/ç¹£©z+¯¹i!È‹ˆÛÙNˆ”ÑPSTRT‹LŒÈ‚ˆ
Bˆ
Bˆ™]\›‚ˆB‚ˆ]Ù[XİYHXİ]™PXØÛİ[ˆÏÈXØÛİ[Ë™š\œİ
Ú\™NˆÈXØÛİ[]˜Z[Xš[]TÛXŞKš\ÔÙ[XİX›J	
HJBˆÏÈXØÛİ[Ë™š\œİˆİX\™˜\ˆXØÛİ[HÙ[XİY[ÙHÈ™]\›ˆBˆYˆXİ]™PXØÛİ[QOHXØÛİ[šYÂˆXİ]™PXØÛİ[QHXØÛİ[šYˆ]ØZ]ÚYÛš[™Ô™Y™\™[˜ÙTİÜ™OËœÙ]Xİ]™PXØÛİ[Q
XØÛİ[šY
BˆB‚ˆXYÛ›ÜİXÔİ]HHœ[›š[™ÂˆÈÂˆİX\™]ÙXÜ™]HH]ØZ]Ù^XÚZ[‹›ØY
XØÛİ[QˆXØÛİ[šY
H[ÙHÂˆ]ØZ]\œÚ\İ™\šYšXØ][Û‘˜Z[\™J›ØØ[Ü™Y[X[ÓZ\ÜÚ[™Ë›ÜˆXØÛİ[
Bˆ›İÈÙ[‹™˜Z[\™Jˆ]Nˆº-)¹cíúg :) zj£:+àH‹ˆ™X\ÛÛˆ¹§+9§.¹¬¨y§"yodùbcH\HQ9æ¡9ænùoeyaëy£k¸à ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬:j£:+àH\HQ‹ˆÛÙNˆ”ÑPSPUULLYH‚ˆ
BˆB‚ˆÈÂˆH]ØZ]XØÛİ[ÛY[˜[Y]JXØÛİ[ˆXØÛİ[ÙXÜ™]ˆÙXÜ™]
BˆXØÛİ[œİ]\ÈH™\šYšYYˆXØÛİ[™\šYšXØ][Û‘˜Z[\™T™X\ÛÛˆHš[ˆXØÛİ[›X\ÚÙY[XZ[H\PXØÛİ[ÛY[›X\ÚÊÙXÜ™]™[XZ[
BˆXØÛİ[›\İ™\šYšYY]H]J
BˆH]ØZ]XØÛİ[™\ÜÚ]ÜKœØ]™JXØÛİ[
BˆHØ]Ú]˜Z[\™H\È[\Ü˜Z[\™HÂˆYˆ]™X\ÛÛˆH\TÙ\šXÙQ˜Z[\™TÛXŞK™\šYšXØ][Û‘˜Z[\™T™X\ÛÛŠ›Üˆ˜Z[\™JHÂˆ]ØZ]\œÚ\İ™\šYšXØ][Û‘˜Z[\™J™X\ÛÛ‹›ÜˆXØÛİ[
BˆBˆ›İÈ˜Z[\™BˆHØ]ÚÂˆYˆ\TÙ\šXÙQ˜Z[\™TÛXŞKš\Ó™]ÛÜšÑ\œ›ÜŠ\œ›ÜŠHÂˆ›İÈ\TÙ\šXÙQ˜Z[\™TÛXŞK›™]ÛÜšÑ˜Z[\™Jˆ[™\›Z[™Îˆ\œ›Ü‹ˆÜ\˜][Ûˆ˜[Y]PXØÛİ[ˆ
BˆBˆ›İÈÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åzj£:+àH\HQ‹ˆ™X\ÛÛˆ\H:j£:+àz/å9fç¹.¡¹§*¹çéze&z+ëûï#:-)¹cíùâ­¹  y§*¹¥.ycæ8à ˆ‹ˆ™XÛİ™\Nˆ¹ê#yd#ºaãz+å{ï&ùi ¹£ yîëyi,z-)ya£zaãy¥¬:j£:+àH\HQ‹ˆÛÙNˆ”ÑPSU‘T’Q–KML‚ˆ
BˆB‚ˆ]ØZ]™Yœ™\ÚÙ\YšXØ]R[™[ÜJ›ÜˆXØÛİ[›Ü˜ÙNˆYJBˆYˆ]˜Z[\™HHÙ\YšXØ]R[™[ÜQ˜Z[\™\ÖØXØÛİ[šYHÂˆ›İÈ˜Z[\™BˆBˆ]ØZ][’[œİ[Ú[›™[ÚXÚÊİXØÙ\ÜÓY\ÜØYÙNˆ¹ëo¹d#yã«ùh ù¨à9­bù«hùn.ŠBˆHØ]Ú]˜Z[\™H\È[\Ü˜Z[\™HÂˆ]ØZ]š[š\Ú[œİ[Ú[›™[ÚXÚÕÚ]˜Z[\™Jˆ˜Z[\™KˆÙÓY\ÜØYÙNˆ¹ëo¹d#yã«ùh ù¨à9­bùi,z-)H‚ˆ
BˆHØ]ÚÂˆ]ØZ]š[š\Ú[œİ[Ú[›™[ÚXÚÕÚ]˜Z[\™JˆÙ[‹›ØØ[]•”•[˜]˜Z[X›Q˜Z[\™KˆÙÓY\ÜØYÙNˆ¹ëo¹d#yã«ùh ù¨à9­bùi,z-)H‚ˆ
BˆBˆB‚ˆËËÈ9cê¹¨à9§ézacykîJÕ”ŠÓZ[š[]^\»ï#9.#zg :) H\HQ:-)¹cíÂˆ[˜È\İZ\š[™ĞÛÛ›™Xİ[ÛŠ
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9­bú+åzacykîz/ç¹£©HŠBˆ]ØZ]ØY
›Ü˜ÙNˆYJBˆİX\™[œİ[Ú[›™[OHš[[ÙHÂˆXYÛ›ÜİXÔİ]HH™˜Z[Y
ˆÙ[‹™˜Z[\™Jˆ]Nˆº+¯¹i!ú/ç¹£©y§*¹l,yîêˆ‹ˆ™X\ÛÛˆ“ØØ[]•”ˆ9§*¹d+ùbª9¢%¹§*¹k¢z(áxà º+íùab:/ç¹£©HÚKQšH9nm¹¢dùo ØØ[]•”¸à ˆ‹ˆ™XÛİ™\Nˆ¹¢dùo ØØ[]•”ˆ9d#ºaãy¥¬9¨à9­bÈ‹ˆÛÙNˆ”ÑPSTRT‹LŒ‚ˆ
Bˆ
Bˆ™]\›‚ˆBˆİX\™Z\š[™Ô™XÛÜ™OHš[[ÙHÂˆXYÛ›ÜİXÔİ]HH™˜Z[Y
ˆÙ[‹™˜Z[\™Jˆ]Nˆº+¯¹i!ù§*ºacykîH‹ˆ™X\ÛÛˆ¹l&¹§*¹k£9¢$9odùbcz+¯¹i!úacykîH‹ˆ™XÛİ™\Nˆº/ç¹£©z+¯¹i!È‹ˆÛÙNˆ”ÑPSTRT‹LŒÈ‚ˆ
Bˆ
Bˆ™]\›‚ˆBˆËÈ9o.¹b-ºaãyïk¹â­¹  {ï#9èk¹/çy«ãù«(yà®yaîú`ïz ïzaãy¥¬:j£:+à{ï":`oùacyi,z-)yd#¹chy/cûï"BˆXYÛ›ÜİXÔİ]HHšYBˆ[œİ[XYÛ›ÜİXÜÈH™[\Bˆ]ØZ][œİ[Ú[›™[Ëœ™\Ù]

Bˆ]ØZ][’[œİ[Ú[›™[ÚXÚÊİXØÙ\ÜÓY\ÜØYÙNˆº+¯¹i!ú/ç¹£©y«hùn.ŠBˆB‚ˆš]˜]H[˜È\œÚ\İ™\šYšXØ][Û‘˜Z[\™JˆÈ™X\ÛÛˆXØÛİ[™\šYšXØ][Û‘˜Z[\™T™X\ÛÛ‹ˆ›ÜˆXØÛİ[ˆ\PXØÛİ[™XÛÜ™ˆ
H\Ş[˜ÈÂˆİX\™]XØÛİ[™\ÜÚ]ÜH[ÙHÈ™]\›ˆBˆ˜\ˆ\]YHXØÛİ[ˆ\]Yœİ]\ÈH›™YYÕ™\šYšXØ][Û‚ˆ\]Y™\šYšXØ][Û‘˜Z[\™T™X\ÛÛˆH™X\ÛÛ‚ˆOÈ]ØZ]XØÛİ[™\ÜÚ]ÜKœØ]™J\]Y
BˆB‚ˆš]˜]H[˜È™\Z\“YØXŞPXØÛİ[İ]\Ù\ÊˆÈ™XÛÜ™ÎˆĞ\PXØÛİ[™XÛÜ™Bˆ
H\Ş[˜È›İÜÈOˆĞ\PXØÛİ[™XÛÜ™HÂˆİX\™]XØÛİ[™\ÜÚ]ÜK]Ù^XÚZ[ˆ[ÙHÈ™]\›ˆ™XÛÜ™ÈBˆ˜\ˆ™\Z\™YH™XÛÜ™Âˆ›Üˆ[™^[ˆ™\Z\™Yš[™XÙ\ÈÚ\™H™\Z\™YÚ[™^Kœİ]\ÈOH›™YYÕ™\šYšXØ][ÛˆÂˆ]\ÓØØ[ÙXÜ™]HH]ØZ]Ù^XÚZ[‹›ØY
XØÛİ[Qˆ™\Z\™YÚ[™^KšY
HOHš[ˆ]İ]\ÈHXØÛİ[]˜Z[Xš[]TÛXŞKœ™\Z\™Yİ]\Êˆ›Üˆ™\Z\™YÚ[™^Kˆ\ÓØØ[ÙXÜ™]ˆ\ÓØØ[ÙXÜ™]ˆ
BˆİX\™İ]\ÈOH™\Z\™YÚ[™^Kœİ]\È[ÙHÈÛÛ[YHBˆ™\Z\™YÚ[™^Kœİ]\ÈHİ]\ÂˆH]ØZ]XØÛİ[™\ÜÚ]ÜKœØ]™J™\Z\™YÚ[™^JBˆBˆ™]\›ˆ™\Z\™YˆB‚ˆ[˜È\İØØ[]•”Š
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9­bú+åHØØ[]•”ˆŠBˆ]ØZ]ØY
›Ü˜ÙNˆYJBˆİX\™XYÛ›ÜİXÔİ]HOHœ[›š[™Ë[œİ[Ú[›™[OHš[[ÙHÈ™]\›ˆBˆİX\™Z\š[™Ô™XÛÜ™OHš[[ÙHÂˆXYÛ›ÜİXÔİ]HH™˜Z[Y
ˆÙ[‹™˜Z[\™Jˆ]Nˆº+¯¹i!ù§*ºacykîH‹ˆ™X\ÛÛˆ¹¨à9­bú/ç¹£©ybczg :) yab9k£9¢$9odùbcz+¯¹i!úacykîH‹ˆ™XÛİ™\Nˆº/ç¹£©z+¯¹i!È‹ˆÛÙNˆ”ÑPSTRT‹LŒØH‚ˆ
Bˆ
Bˆ™]\›‚ˆBˆ]ØZ][’[œİ[Ú[›™[ÚXÚÊİXØÙ\ÜÓY\ÜØYÙNˆ“ØØ[]•”ˆ9«hùn.ŠBˆËÈ”ˆ9fçº, ùd£:+¯¹ïkºhmz!ê¹bª9£¨¹­bú`ïz-l:/æzaã;ï&ùæí9£©y£ª:/æÈSÔÈÈ:acykîzf-¹«­{ï#ˆËÈ9.#z ïy/§z-e¹ê#yd#¹æ¡9d+ùbª9¨à9§éy¢cz+ªyåc:gh¹.ã¸ '9o¡z/ç¹£©x 'ycæ9..¸ '9k£9¢$8 'xà ‚ˆYˆÛ™TZ\š[™Ô™\Ù[][Û”ÛXŞJˆXZ›Ü“ÔÕ™\œÚ[Ûˆ›ØÙ\ÜÒ[™›Ëœ›ØÙ\ÜÒ[™›Ë›Ü\˜][™ÔŞ\İ[U™\œÚ[Û‹›XZ›Ü•™\œÚ[Û‚ˆ
K\Ù\ÔÛ™TZ\š[™ÈÂˆÛ™TZ\š[™Ôİ]HHÙ[‹œÛ™TZ\š[™Ôİ]PY\]]ÛX]XĞÚXÚÊˆXYÛ›ÜİXÔİ]NˆXYÛ›ÜİXÔİ]Bˆ
BˆBˆB‚ˆš]˜]H[˜È˜[Y]R[\ÜYZ\š[™ÕÚ[•[›™[]˜Z[X›JˆİXØÙ\ÜÓY\ÜØYÙNˆİš[™ËˆØZ][™ÓY\ÜØYÙNˆİš[™Âˆ
H\Ş[˜ÈÂˆ][›™[™XXÚX›HH]ØZ]Z\š[™Õ[›™[›Ø™Kœ›Ø™U[›™[

BˆİX\™Z\š[™Õ˜[Y][Û”İ\ÛXŞKœÚİ[İ\]]ÛX]XØ[Jˆ[›™[™XXÚX›Nˆ[›™[™XXÚX›Bˆ
H[ÙHÂˆXYÛ›ÜİXÔİ]HHšYBˆ[œİ[XYÛ›ÜİXÜÈH™[\BˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœZ\š[™ËY\ÜØYÙNˆØZ][™ÓY\ÜØYÙJBˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

Bˆ™]\›‚ˆBˆ]ØZ][’[œİ[Ú[›™[ÚXÚÊİXØÙ\ÜÓY\ÜØYÙNˆİXØÙ\ÜÓY\ÜØYÙJBˆB‚ˆš]˜]H[˜È[’[œİ[Ú[›™[ÚXÚÊİXØÙ\ÜÓY\ÜØYÙNˆİš[™ÊH\Ş[˜ÈÂˆİX\™][œİ[Ú[›™[[ÙHÈ™]\›ˆBˆXYÛ›ÜİXÔİ]HHœ[›š[™ÂˆYˆ]Z\š[™ÔİÜ™KZ\š[™Ô™XÛÜ™OHš[ÂˆÈÂˆZ\š[™Ô™XÛÜ™HH]ØZ]Z\š[™ÔİÜ™K›X\šÕ˜[Y][™Ê
BˆHØ]ÚÂˆ]˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆºacykîzj£:+àyi,z-)H‹ˆ™X\ÛÛˆ¹¥è9¬åy/çykf:+¯¹i!úacykîyæ¡:j£:+àyîäù§§8à ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬:acykîz+¯¹i!È‹ˆÛÙNˆ”ÑPSTRT‹LŒˆ‚ˆ
BˆXYÛ›ÜİXÔİ]HH™˜Z[Y
˜Z[\™JBˆ[\˜Z[\™HH˜Z[\™Bˆ™]\›‚ˆBˆBˆ]XYÛ›ÜİXÜÈH]ØZ][œİ[Ú[›™[™XYÛ›ÜÙJ
Bˆ[œİ[XYÛ›ÜİXÜÈHXYÛ›ÜİXÜÂˆYˆXYÛ›ÜİXÜËš\Ô™XYK]]šXÙRY[YšY\ˆHXYÛ›ÜİXÜË™]šXÙRY[YšY\ˆÂˆYˆ]Z\š[™ÔİÜ™HÂˆÈÂˆZ\š[™Ô™XÛÜ™HH]ØZ]Z\š[™ÔİÜ™K›X\šÕ˜[Y]Y
ˆ]šXÙRY[YšY\ˆ]šXÙRY[YšY\‚ˆ
BˆHØ]Ú]˜Z[\™H\È[\Ü˜Z[\™HÂˆ]ØZ]š[š\Ú[œİ[Ú[›™[ÚXÚÕÚ]˜Z[\™Jˆ˜Z[\™KˆXYÛ›ÜİXÜÎˆXYÛ›ÜİXÜËˆÙÓY\ÜØYÙNˆº+¯¹i!úacykîy¨(zj£9i,z-)H‚ˆ
Bˆ™]\›‚ˆHØ]ÚÂˆ]ØZ]š[š\Ú[œİ[Ú[›™[ÚXÚÕÚ]˜Z[\™JˆÙ[‹™˜Z[\™Jˆ]Nˆºacykîzj£:+àyi,z-)H‹ˆ™X\ÛÛˆ¹¥è9¬åy/çykf9odùbcz+¯¹i!ùæ¡:acykîzj£:+àyîäù§§8à ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬:acykîz+¯¹i!È‹ˆÛÙNˆ”ÑPSTRT‹LŒØˆ‚ˆ
KˆXYÛ›ÜİXÜÎˆXYÛ›ÜİXÜËˆÙÓY\ÜØYÙNˆº+¯¹i!úacykîy¨(zj£9i,z-)H‚ˆ
Bˆ™]\›‚ˆBˆBˆXYÛ›ÜİXÔİ]HHœ™XYJ]šXÙRY[YšY\ˆ]šXÙRY[YšY\ŠBˆ]ØZ]ØY
›Ü˜ÙNˆYJBˆ[œİ[XYÛ›ÜİXÜÈHXYÛ›ÜİXÜÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆš[œİ[][Û‹ˆY\ÜØYÙNˆİXØÙ\ÜÓY\ÜØYÙBˆ
BˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

Bˆ™]\›‚ˆBˆ]ØZ]š[š\Ú[œİ[Ú[›™[ÚXÚÕÚ]˜Z[\™JˆXYÛ›ÜİXÜË™˜Z[\™HÏÈÙ[‹›ØØ[]•”•[˜]˜Z[X›Q˜Z[\™KˆXYÛ›ÜİXÜÎˆXYÛ›ÜİXÜËˆÙÓY\ÜØYÙNˆ“ØØ[]•”ˆ9¨à9­bùi,z-)H‚ˆ
BˆB‚ˆš]˜]Hİ]XÈ[˜ÈÚİ[›Û˜XÚÔZ\š[™ÊY\ˆ˜Z[\™Nˆ[\Ü˜Z[\™JHOˆ›ÛÛÂˆÈ”ÑPSTRT‹LŒH‹”ÑPSTRT‹LŒˆ‹”ÑPSRS”ÕSMÌÈ—K˜ÛÛZ[œÊ˜Z[\™K˜ÛÙJBˆB‚ˆš]˜]H[˜Èš[š\Ú[œİ[Ú[›™[ÚXÚÕÚ]˜Z[\™JˆÈ˜Z[\™Nˆ[\Ü˜Z[\™KˆXYÛ›ÜİXÜÎˆ[œİ[Ú[›™[XYÛ›ÜİXÜÏÈHš[ˆÙÓY\ÜØYÙNˆİš[™Âˆ
H\Ş[˜ÈÂˆ˜\ˆY™™Xİ]™Q˜Z[\™HH˜Z[\™Bˆ˜\ˆY™™Xİ]™QXYÛ›ÜİXÜÈHXYÛ›ÜİXÜÂˆYˆÙ[‹œÚİ[›Û˜XÚÔZ\š[™ÊY\ˆ˜Z[\™JK]Z\š[™ÔİÜ™HÂˆÈÂˆYˆ]™\İÜ™YHH]ØZ]Z\š[™ÔİÜ™Kœ™\İÜ™P˜XÚİ\Y”™\Ù[

HÂˆZ\š[™Ô™XÛÜ™H™\İÜ™Yˆ]ØZ][œİ[Ú[›™[Ëœ™\Ù]

BˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆœZ\š[™ËˆY\ÜØYÙNˆ¹¥¬:acykîy/èy kúj£:+àyi,z-){ï#9mìº!ê¹bª9 h¹i#y."¹. 9.ïycëùå*:acykîy/èy kÈ‚ˆ
BˆYˆ][œİ[Ú[›™[Âˆ]™XÛİ™\QXYÛ›ÜİXÜÈH]ØZ][œİ[Ú[›™[™XYÛ›ÜÙJ
BˆY™™Xİ]™QXYÛ›ÜİXÜÈH™XÛİ™\QXYÛ›ÜİXÜÂˆYˆ™XÛİ™\QXYÛ›ÜİXÜËš\Ô™XYKˆ]]šXÙRY[YšY\ˆH™XÛİ™\QXYÛ›ÜİXÜË™]šXÙRY[YšY\ˆÂˆÈÂˆZ\š[™Ô™XÛÜ™HH]ØZ]Z\š[™ÔİÜ™K›X\šÕ˜[Y]Y
ˆ]šXÙRY[YšY\ˆ]šXÙRY[YšY\‚ˆ
BˆXYÛ›ÜİXÔİ]HHœ™XYJ]šXÙRY[YšY\ˆ]šXÙRY[YšY\ŠBˆ[œİ[XYÛ›ÜİXÜÈH™XÛİ™\QXYÛ›ÜİXÜÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆœZ\š[™ËˆY\ÜØYÙNˆ¹."¹. 9.ïzacykîy/èy kùmì¹ h¹i#ynmºaãy¥¬:j£:+ày¢$9b§È‚ˆ
BˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

Bˆ™]\›‚ˆHØ]Ú]™\İÜ™Q˜Z[\™H\È[\Ü˜Z[\™HÂˆY™™Xİ]™Q˜Z[\™HH™\İÜ™Q˜Z[\™BˆHØ]ÚÂˆY™™Xİ]™Q˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆºacykîy h¹i#zj£:+àyi,z-)H‹ˆ™X\ÛÛˆ¹."¹. 9.ïzacykîy/èy kùmì¹ h¹i#{ï#9/aºj£:+àyîäù§§9¥è9¬åy/çykf8à ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬9¨à9­bÈ‹ˆÛÙNˆ”ÑPSTRT‹LŒL‚ˆ
BˆBˆH[ÙHYˆ]™XÛİ™\Q˜Z[\™HH™XÛİ™\QXYÛ›ÜİXÜË™˜Z[\™HÂˆY™™Xİ]™Q˜Z[\™HH™XÛİ™\Q˜Z[\™BˆBˆBˆBˆHØ]ÚÂˆY™™Xİ]™Q˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆºacykîy h¹i#yi,z-)H‹ˆ™X\ÛÛˆ¹¥¬:acykîy/èy kù.#ycëùå*;ï#9.%9."¹. 9.ïzacykîy/èy kù§*º ïz!ê¹bª9 h¹i#xà ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬:acykîH‹ˆÛÙNˆ”ÑPSTRT‹LŒH‚ˆ
Bˆ[\˜Z[\™HHY™™Xİ]™Q˜Z[\™BˆBˆBˆYˆ]Z\š[™ÔİÜ™HÂˆÈÂˆYˆ]]šXÙRY[YšY\ˆHY™™Xİ]™QXYÛ›ÜİXÜÏË™]šXÙRY[YšY\ˆÂˆZ\š[™Ô™XÛÜ™HH]ØZ]Z\š[™ÔİÜ™K›X\šÕ˜[Y]Y
ˆ]šXÙRY[YšY\ˆ]šXÙRY[YšY\‚ˆ
BˆH[ÙHÂˆZ\š[™Ô™XÛÜ™HH]ØZ]Z\š[™ÔİÜ™K›X\šÔ[™[™Õ˜[Y][ÛŠ
BˆBˆHØ]ÚÂˆ[\˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆºacykîyâ­¹  y/çykf9i,z-)H‹ˆ™X\ÛÛˆ“ØØ[]•”ˆ9¨à9­bùi,z-)yd#»ï#:acykîyâ­¹  y¬¨z ïy/çykf9b,9§+9§.¸à ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬:acykîz+¯¹i!ùd#¹a£y¨à9­bÈ‹ˆÛÙNˆ”ÑPSTRT‹LŒˆ‚ˆ
BˆBˆBˆ]ØZ]ØY
›Ü˜ÙNˆYJBˆYˆ]Y™™Xİ]™QXYÛ›ÜİXÜÈÈ[œİ[XYÛ›ÜİXÜÈHY™™Xİ]™QXYÛ›ÜİXÜÈBˆXYÛ›ÜİXÔİ]HH™˜Z[Y
Y™™Xİ]™Q˜Z[\™JBˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆš[œİ[][Û‹ˆ]™[ˆ™\œ›Ü‹ˆY\ÜØYÙNˆ—
ÙÓY\ÜØYÙJ{ïg
Y™™Xİ]™Q˜Z[\™K]J{ïg
Y™™Xİ]™Q˜Z[\™Kœ™X\ÛÛŠH‹ˆÛÙNˆY™™Xİ]™Q˜Z[\™K˜ÛÙBˆ
BˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

BˆB‚ˆ[˜ÈÙ]›İYšXØ][ÛœÑ[˜X›Y
È[˜X›Yˆ›ÛÛ
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH:+¯¹ïkº`&¹çéyo 9alÎˆ
[˜X›Y
HŠBˆİX\™]›İYšXØ][Û”ØÚY[\‹ˆ]›İYšXØ][Û”™Y™\™[˜Ù\Ëˆ]\İÜ™H[ÙHÈ™]\›ˆBˆÈÂˆYˆ[˜X›YÂˆ]Ü˜[YHH]ØZ]›İYšXØ][Û”ØÚY[\‹œ™\]Y\İ]]Üš^˜][ÛŠ
BˆİX\™Ü˜[Y[ÙHÂˆ›İYšXØ][Û”™Y™\™[˜Ù\Ëš\Ñ[˜X›YHYBˆ›İYšXØ][ÛœÑ[˜X›YHYBˆ›İYšXØ][Û”İ]\ÈH]ØZ]›İYšXØ][Û”ØÚY[\‹œİ]\ÊÙX[[˜X›YˆYJBˆ›İÈÙ[‹™˜Z[\™Jˆ]Nˆº`&¹çéy§*¹o 9d+È‹ˆ™X\ÛÛˆ”ÙX[9a¡y£ä:a¤¹mì¹o 9d+ûï#9/a¹ìîùîçù¬¨y§"y£¢9.¢:`&¹çéy§`úfd8à ˆ‹ˆ™XÛİ™\Nˆ¹bcyo TÛ™xà#:+¯¹ïk¸à#O¸à#ÙX[8à#O¸à#:`&¹çéxà#{ï#9a`z+®:`&¹çéyd#ºaãz+åxà ˆ‹ˆÛÙNˆ”ÑPSS“ÕQ–KLH‚ˆ
BˆBˆBˆ›İYšXØ][Û”™Y™\™[˜Ù\Ëš\Ñ[˜X›YH[˜X›Yˆ›İYšXØ][ÛœÑ[˜X›YH[˜X›YˆH]ØZ]›İYšXØ][Û”ØÚY[\‹œ™\ØÚY[Jˆ\ÎˆH]ØZ]\İÜ™K™™]Ú[

Kˆ[˜X›Yˆ[˜X›YˆXYİ\œÎˆ™[Z[™\’İ\œÂˆ
Bˆ›İYšXØ][Û”İ]\ÈH]ØZ]›İYšXØ][Û”ØÚY[\‹œİ]\ÊÙX[[˜X›Yˆ[˜X›Y
BˆHØ]Ú]˜Z[\™H\È[\Ü˜Z[\™HÂˆ›İYšXØ][Û”İ]\ÈH]ØZ]›İYšXØ][Û”ØÚY[\‹œİ]\ÊˆÙX[[˜X›Yˆ›İYšXØ][Û”™Y™\™[˜Ù\Ëš\Ñ[˜X›YˆØÚY[[™Ñ˜Z[\™Nˆ˜Z[\™Kœ™X\ÛÛ‚ˆ
Bˆ[\˜Z[\™HH˜Z[\™BˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆ™\œ›Ü‹Y\ÜØYÙNˆ˜Z[\™Kœ™X\ÛÛ‹ÛÙNˆ˜Z[\™K˜ÛÙJBˆHØ]ÚÂˆ]XYÛ›ÜİXÈH›İYšXØ][Û”ØÚY[[™Ñ˜Z[\™K™XYÛ›ÜİXÊ›Üˆ\œ›ÜŠBˆ]˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åz+¯¹ïk¹£ä:a¤ˆ‹ˆ™X\ÛÛˆ¹£ä:a¤¹§*º ïy¦í9¥¬8à ˆ‹ˆ™XÛİ™\Nˆ¹c®ùìîùîçú+¯¹ïk¹¢dùo :`&¹çéy§`úfd9d#ºaãz+åH‹ˆÛÙNˆ”ÑPSS“ÕQ–KL˜H‚ˆ
Bˆ›İYšXØ][Û”İ]\ÈH]ØZ]›İYšXØ][Û”ØÚY[\‹œİ]\ÊˆÙX[[˜X›Yˆ›İYšXØ][Û”™Y™\™[˜Ù\Ëš\Ñ[˜X›YˆØÚY[[™Ñ˜Z[\™Nˆ˜Z[\™Kœ™X\ÛÛ‚ˆ
Bˆ[\˜Z[\™HH˜Z[\™BˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆ™\œ›Ü‹Y\ÜØYÙNˆ”ÑPSS“ÕQ–KL˜H9n¥yl`º+â¹¥«{ï&—
XYÛ›ÜİXÊH‹ÛÙNˆ˜Z[\™K˜ÛÙJBˆBˆB‚ˆØš˜Èš]˜]H[˜È™Yœ™\Ú›İYšXØ][Û”İ]\ĞY\”™[™]Ø[

HÂˆ\ÚÈÈXZ[XİÜˆ[‚ˆ]ØZ]Ù[‹œ™Yœ™\Ú›İYšXØ][Û”İ]\Ê
BˆBˆB‚ˆËËÈ:/núaãùb-ù¥¬:`&¹çéyâ­¹  {ï&¹«ãù«(z/æúhmzghº`ïz, ûï#9.#ycåÈ\ÓØYY9k¢9cjùolydãxà ‚ˆXZ[XİÜ‚ˆ[˜È™Yœ™\Ú›İYšXØ][Û”İ]\Ê
H\Ş[˜ÈÂˆËÈ9.):f-¹«­y£ä9.©;ï&‹œÙX[™[™]Ø[ÛÛ\]Y9g*:aãy£¤¹k£9¢$9d#¹¢cycä{ï#9æí9£©z+îùl,y¦+ù¥¬9æ¡;ï#9.#yå*9çhL¹éä‚ˆİX\™]›İYšXØ][Û”ØÚY[\‹]›İYšXØ][Û”™Y™\™[˜Ù\È[ÙHÈ™]\›ˆBˆ›İYšXØ][Û”İ]\ÈH]ØZ]›İYšXØ][Û”ØÚY[\‹œİ]\ÊÙX[[˜X›Yˆ›İYšXØ][Û”™Y™\™[˜Ù\Ëš\Ñ[˜X›Y
BˆB‚ˆ[˜È™Yœ™\ÚİÜ˜YÙU\ØYÙJ
H\Ş[˜ÈÂˆİX\™]š[TİÜ™H[ÙHÂˆİÜ˜YÙU\ØYÙHH™[\Bˆ™XÛZ[XX›TÚYÛ™YTPØXÚPÛİ[Hˆ™]\›‚ˆBˆÈÂˆ]\ÎˆĞ\™XÛÜ™BˆYˆ]\İÜ™HÂˆ\ÈH
OÈ]ØZ]\İÜ™K™™]Ú[

JHÏÈ×BˆH[ÙHÂˆ\ÈH×BˆBˆ]\İÜNˆÔÚYÛš[™Ò\İÜT™XÛÜ™BˆYˆ]ÚYÛš[™Ò\İÜTİÜ™HÂˆ\İÜHH
OÈ]ØZ]ÚYÛš[™Ò\İÜTİÜ™Kœ™XÛÜ™Ê
JHÏÈ×BˆH[ÙHÂˆ\İÜHH×BˆBˆİÜ˜YÙU\ØYÙHHH]ØZ]š[TİÜ™KœİÜ˜YÙU\ØYÙJ\Îˆ\ËÚYÛš[™Ò\İÜNˆ\İÜJBˆ™XÛZ[XX›TÚYÛ™YTPØXÚPÛİ[H\Ë˜Ûİ[ÂˆÚYÛ™YTPØXÚPÛX[\ÛXŞK™XÚ\Ú[ÛŠ›Üˆ	
HOHœ™XÛZ[XX›BˆBˆHØ]ÚÂˆİÜ˜YÙU\ØYÙHH™[\Bˆ™XÛZ[XX›TÚYÛ™YTPØXÚPÛİ[HˆBˆB‚ˆ[˜ÈÛX\•[\Ü˜\Qš[\Ê
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9®!yä!¹.-9¥í¹ï$ùkfŠBˆİX\™]š[TİÜ™H[ÙHÈ™]\›ˆBˆİX\™]Ü\˜][Û“X\ÙHH]ØZ]XÜ]Z\™SÜ\˜][ÛŠ›XZ[Z[š[™ÔİÜ˜YÙJH[ÙHÂˆ[\˜Z[\™HHÜ\˜][ÛÛÛ™›Xİ˜Z[\™J™\]Y\İYˆ›XZ[Z[š[™ÔİÜ˜YÙJBˆ™]\›‚ˆBˆY™\ˆÈ™[X\ÙSÜ\˜][ÛŠÜ\˜][Û“X\ÙJHBˆÈÂˆ]ØZ]™Yœ™\ÚİÜ˜YÙU\ØYÙJ
Bˆ][\Ü˜\P™Y›Ü™HHİÜ˜YÙU\ØYÙK[\Ü˜\BˆH]ØZ]š[TİÜ™K˜ÛX\•[\Ü˜\Qš[\Ê
Bˆ]ØZ]™Yœ™\ÚİÜ˜YÙU\ØYÙJ
BˆİÜ˜YÙSXZ[[˜[˜ÙTİ[[X\HHİÜ˜YÙSXZ[[˜[˜ÙTİ[[X\K[\Ü˜\PØXÚPÛX\™Y
ˆœ™YY]\Îˆ[\Ü˜\P™Y›Ü™HHİÜ˜YÙU\ØYÙK[\Ü˜\Bˆ
BˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆœŞ\İ[KˆY\ÜØYÙNˆ¹.-9¥í¹ï$ùkf9.#¹ëo¹d#yméy/g9c.¹mì¹®!yä!ˆ‚ˆ
BˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

BˆHØ]ÚÂˆ[\˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åy®!yä!¹ï$ùkf‹ˆ™X\ÛÛˆ¹.-9¥í¹¥¡ù.í¹.ãyg*9/oùå*;ï#9¥è9¬åy®!yä!¸à ˆ‹ˆ™XÛİ™\Nˆ¹ê#yd#ºaãy¥¬9®!yä!ˆ‹ˆÛÙNˆ”ÑPSTÕÔQÑKLXH‚ˆ
BˆBˆB‚ˆ[˜ÈÛX\•[\ÙYİÜ˜YÙQš[\Ê
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9®!yä!¹§*¹/oùå*9¥¡ù.íˆŠBˆİX\™]š[TİÜ™K]\İÜ™H[ÙHÈ™]\›ˆBˆİX\™]Ü\˜][Û“X\ÙHH]ØZ]XÜ]Z\™SÜ\˜][ÛŠ›XZ[Z[š[™ÔİÜ˜YÙJH[ÙHÂˆ[\˜Z[\™HHÜ\˜][ÛÛÛ™›Xİ˜Z[\™J™\]Y\İYˆ›XZ[Z[š[™ÔİÜ˜YÙJBˆ™]\›‚ˆBˆY™\ˆÈ™[X\ÙSÜ\˜][ÛŠÜ\˜][Û“X\ÙJHBˆÈÂˆ]ØZ]™Yœ™\ÚİÜ˜YÙU\ØYÙJ
Bˆ]™XÛZ[XX›P™Y›Ü™HHİÜ˜YÙU\ØYÙK[\Ü˜\H
ÈİÜ˜YÙU\ØYÙK›Üœ[™Yˆ]\ÈHH]ØZ]\İÜ™K™™]Ú[

BˆH]ØZ]š[TİÜ™K˜ÛX\•[\Ü˜\Qš[\Ê
BˆËÈ:/æzaã9¦+ùå*9¢-ù..ùbª9®!yä!»ï#9.%9¥m9.*¹®!yä!¹§'úeí9£ y§"H›XZ[Z[š[™ÔİÜ˜YÙH9éçùî©‚ˆËÈ;ï"Ü\˜][ÛÛÛÜ™[˜]Üˆ9cey©ïH8¡äˆ9.#y/&¹§"ynm¹cäykï9aiy¥¬9nî¹æë¹oe{ï"{ï#ˆËÈ9fè9«i9.#zg :) xà#9¥¬9nî¹/çy¢©9§'øà#x %8 %9å*9¢-ùl,y¦+ú) yêâùb.ù¢¢¹ênºeí:aâ¹¥/¹aî¹§ixà ‚ˆH]ØZ]š[TİÜ™K˜ÛX\“Üœ[™Y\š[\Êˆ˜[Y\QÎˆÙ]
\Ë›X\
šY
JKˆZ[š[][PYÙNˆˆ
Bˆ]ØZ]™Yœ™\ÚİÜ˜YÙU\ØYÙJ
BˆİÜ˜YÙSXZ[[˜[˜ÙTİ[[X\HHİÜ˜YÙSXZ[[˜[˜ÙTİ[[X\K[\ÙYš[\ĞÛX\™Y
ˆœ™YY]\Îˆ™XÛZ[XX›P™Y›Ü™HHİÜ˜YÙU\ØYÙK[\Ü˜\HHİÜ˜YÙU\ØYÙK›Üœ[™Yˆ
BˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆœŞ\İ[KˆY\ÜØYÙNˆ¹.-9¥í¹ï$ùkf9d£9§*¹/oùå*9¥¡ù.í¹mì¹®!yä!»ï&ùëo¹d#yï$ùkf8à P\HQ9aëy£k¹d£:+¯¹i!úacykîy/èy kùmì¹/çyåfH‚ˆ
BˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

BˆHØ]ÚÂˆ[\˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åy®!yä!¹§*¹/oùå*9¥¡ù.íˆ‹ˆ™X\ÛÛˆº`ê9b!¹¥¡ù.í¹.ãyg*9/oùå*9¢%¹§+9g,:+¬9oey¥è9¬åz+îùcå¸à ˆ‹ˆ™XÛİ™\Nˆ¹ê#yd#ºaãy¥¬9®!yä!ˆ‹ˆÛÙNˆ”ÑPSTÕÔQÑKLˆ‚ˆ
BˆBˆB‚ˆËËÈ9®!yä!¹cëùa£yå'ù¢$9æ¡9mì¹ëo¹d#HTxà ¹c§ùiâÈTxà yk¢z(áz+¬9oeyd£9å*9¢-ù`cùioy. 9o¢ù/çyåfxà ‚ˆ[˜ÈÛX\”İÜ™YÚYÛ™YXÚØYÙ\Ê
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9®!yä!¹mì¹ëo¹d#HTHŠBˆİX\™]š[TİÜ™K]\İÜ™H[ÙHÈ™]\›ˆBˆİX\™]Ü\˜][Û“X\ÙHH]ØZ]XÜ]Z\™SÜ\˜][ÛŠ›XZ[Z[š[™ÔİÜ˜YÙJH[ÙHÂˆ[\˜Z[\™HHÜ\˜][ÛÛÛ™›Xİ˜Z[\™J™\]Y\İYˆ›XZ[Z[š[™ÔİÜ˜YÙJBˆ™]\›‚ˆBˆY™\ˆÈ™[X\ÙSÜ\˜][ÛŠÜ\˜][Û“X\ÙJHB‚ˆÈÂˆ]ØZ]™Yœ™\ÚİÜ˜YÙU\ØYÙJ
Bˆ]ÚYÛ™Y™Y›Ü™HHİÜ˜YÙU\ØYÙKœÚYÛ™YT\Âˆ]™XÛÜ™ÈHH]ØZ]\İÜ™K™™]Ú[

B‚ˆ›Üˆ™XÛÜ™[ˆ™XÛÜ™ÈÚ\™HÚYÛ™YTPØXÚPÛX[\ÛXŞK™XÚ\Ú[ÛŠ›Üˆ™XÛÜ™
HOHœ™XÛZ[XX›HÂˆ˜\ˆÛX\™Y™XÛÜ™H™XÛÜ™ˆÛX\™Y™XÛÜ™˜ÛX\”ÚYÛ™YTPØXÚSY]Y]J
B‚ˆËÈ9a`ù¥l9£k¹cê¹¨!ú+¬9ï$ùkf9ï.¹i,{ï#9îçy.#y¥.ya¦ymì¹k¢z(áz.ªù.ïKùîëyëoº-a9¨/8à ‚ˆH]ØZ]\İÜ™KœØ]™JÛX\™Y™XÛÜ™
BˆÈÂˆH]ØZ]š[TİÜ™Kœ™[[İ™TÚYÛ™YTPØXÚJ\Qˆ™XÛÜ™šY
BˆHØ]ÚÂˆËÈ9b(:fi9§*¹k£9¢$9¥í¹ h¹i#yc§ú+¬9oe{ï#9èk¹/çyå*9¢-ù.ãycëù«hùn.9i#yå*9ã¬9§"yëo¹d#yc!xà ‚ˆOÈ]ØZ]\İÜ™KœØ]™J™XÛÜ™
Bˆ›İÈ\œ›Ü‚ˆBˆB‚ˆ]ØZ]™Yœ™\ÚİÜ˜YÙU\ØYÙJ
BˆİÜ˜YÙSXZ[[˜[˜ÙTİ[[X\HHİÜ˜YÙSXZ[[˜[˜ÙTİ[[X\KœÚYÛ™YXÚØYÙ\ĞÛX\™Y
ˆœ™YY]\ÎˆÚYÛ™Y™Y›Ü™HHİÜ˜YÙU\ØYÙKœÚYÛ™YT\Âˆ
BˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆœŞ\İ[KˆY\ÜØYÙNˆ¹mìºaâ¹¥/¹cëúaãynî¹k¢z(áyï$ùkf;ï&ùc§ùiâÈTxà ymì¹k¢z(áz.ªù.ïxà y£ãú/ì9¥¡ù.í¸à z-)¹cíùd£:+¯¹i!úacykîy/èy kùgaùmì¹/çyåfH‚ˆ
BˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

BˆHØ]ÚÂˆ[\˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åy®!yä!¹ëo¹d#yc!H‹ˆ™X\ÛÛˆº`ê9b!¹mì¹ëo¹d#HTH9«hùg*9/oùå*9¢%¹§+9g,:+¬9oey¥è9¬åy¦í9¥¬8à ˆ‹ˆ™XÛİ™\Nˆ¹ê#yd#ºaãy¥¬9®!yä!ˆ‹ˆÛÙNˆ”ÑPSTÕÔQÑKLÈ‚ˆ
BˆBˆB‚ˆ[˜ÈÛX\’TP[™ÚYÛš[™ĞØXÚJ
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9®!yä!ˆTH9d£9ëo¹d#yï$ùkfŠBˆ]ØZ]ÛX\•[\ÙYİÜ˜YÙQš[\Ê
BˆB‚ˆËËÈYØXŞHTH™]Z[™Y›ÜˆØ[\Ú]HÛÛ\]Xš[]K‚ˆËËÈ]È˜[YH›İÈX]Ú\ÈH™X[Ü\˜][Ûˆ™XÛZ[H™YÙ[™\˜X›HÚYÛ™YTHXÚØYÙ\Ë‚ˆ[˜ÈÛX\”ÚYÛ™YTPØXÚJ
H\Ş[˜ÈÂˆ]ØZ]ÛX\”İÜ™YÚYÛ™YXÚØYÙ\Ê
BˆB‚ˆ[˜ÈÛX\“ÙÜÊ
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH9®!zfi9¥éyoåÈŠBˆİX\™]ÙÔİÜ™H[ÙHÈ™]\›ˆBˆÈÂˆH]ØZ]ÙÔİÜ™K˜ÛX\Š
BˆÙÜÈH×Bˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

BˆHØ]ÚÂˆ[\˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åy®!yä!¹¥éyoåÈ‹ˆ™X\ÛÛˆ¹¥éyoåù¥¡ù.í¹.ãyg*9/oùå*;ï#9¥è9¬åy®!yä!¸à ˆ‹ˆ™XÛİ™\Nˆ¹ê#yd#ºaãy¥¬9®!yä!ˆ‹ˆÛÙNˆ”ÑPSSÑËLH‚ˆ
BˆBˆB‚ˆËËÈ9¥éyoåúhmyëbyo¡HXİÜˆ9k£9¢$9a¦yaiyd#¹¢cy¢dùo 9b!¹.ªúgh¹§oûï#:`oùaczi¥¹«(ykï9aîº+îùb,9.#ykf9g*9æ¡9¥éù¥¡ù.í¸à ‚ˆ[˜ÈX]\šX[^™SÙÑ^Ü

H\Ş[˜È›İÜÈOˆT“ÂˆİX\™]ÙÔİÜ™H[ÙHÂˆ›İÈ[\Ü˜Z[\™Jˆ]Nˆ¹¥è9¬åykï9aî¹¥éyoåÈ‹ˆ™X\ÛÛˆ¹¥éyoåù§#yb¨yl&¹§*¹l,yîê¸à ˆ‹ˆ™XÛİ™\Nˆº/å9fç¹d#¹ê#y`&ya£z+åH‹ˆÛÙNˆ”ÑPSSÑËLˆ‹ˆÛÛ™][Ûˆ›ÙÔÙ\šXÙU[˜]˜Z[X›KˆXİ[Ûˆœ™]Kˆ™]Q\ÜÜÚ][Ûˆ›X[X[ˆÜ\˜][Ûˆ™^ÜÙËˆÜšYÚ[ˆ›ÙÔİÜ™Bˆ
BˆBˆÈÂˆ™]\›ˆH]ØZ]ÙÔİÜ™K›X]\šX[^™Q^Ü

BˆHØ]ÚÂˆ›İÈ[\Ü˜Z[\™Jˆ]Nˆ¹¥è9¬åykï9aî¹¥éyoåÈ‹ˆ™X\ÛÛˆ¹¥éyoåù¥¡ù.í¹a¦yaiyi,z-){ï&—
\œ›Ü‹›ØØ[^™Y\ØÜš\[ÛŠH‹ˆ™XÛİ™\Nˆ¹¨à9§éycëùå*9kf9`ª9ênºeí9d#ºaãz+åH‹ˆÛÙNˆ”ÑPSSÑËLˆ‹ˆÛÛ™][Ûˆ›ÙÑ^Üš[R[˜[YˆXİ[Ûˆœ™]Kˆ™]Q\ÜÜÚ][Ûˆ›X[X[ˆÜ\˜][Ûˆ™^ÜÙËˆÜšYÚ[ˆ›ÙÔİÜ™Bˆ
BˆBˆB‚ˆËËÈ9¥éyoåúhmy.#¹kï9aî¹aly.ªùd#9. 9.ïHXİÜˆ9ï$ùa¬»ï#: #9.#y¦+ú) y¬`ˆØİ[Y[È:eg9`ãùmì¹ab9. 9«iz$/yææ8à ‚ˆËËÂˆËËÈÙX[[ÙË9¦+ùîæx '9¥¡ù.í¸ 'P\9d£9b!¹.ªúgh¹§oùaá¹i!ùæ¡:eg9`ãûï&ùk ú(ªú" ¹­`y¢%¹b&¹®!yä!¹¥í¹.#yn¥9a¬ùk¦‚ˆËËÈ\9a¡z ïyd)¹ç"ùb,9mì¹§"y¥éyoåøà º/æzaã9iâùîâ9/&9ab:+îùcå¹¥éyoåùkf9`ª;ï#:+îùcå¹i,z-)y¢cyfçº` 9odùbcya¡ykf9oêùáiøà ‚ˆ[˜ÈÙÕ^›Ü•šY]Ú[™Ê
H\Ş[˜ÈOˆİš[™ÈÂˆ]^ˆİš[™ÂˆYˆ]ÙÔİÜ™K]^ÜYHOÈ]ØZ]ÙÔİÜ™K™^Ü^

HÂˆ^H^ÜYˆH[ÙHÂˆ^HÙX[ÙÕ^›Ü›X]\‹™^Ü^
ÙÜÊBˆBˆÙÑ^Ü^H^ˆ™]\›ˆ^ˆB‚ˆ[˜È™\Ù]Ù\YšXØ]J›ÜˆXØÛİ[ˆ\PXØÛİ[™XÛÜ™
H\Ş[˜ÈÂˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
Ø]YÛÜNˆœŞ\İ[K]™[ˆš[™›ËY\ÜØYÙNˆ–ÔÑPSSÔH:aãyïkº+ày.iˆ:-)¹cíÈ
XØÛİ[šY]ZYİš[™Ëœ™Yš^

JHŠBˆİX\™]XØÛİ[™\ÜÚ]ÜH[ÙHÈ™]\›ˆBˆİX\™]Ü\˜][Û“X\ÙHH]ØZ]XÜ]Z\™SÜ\˜][ÛŠ›X[˜YÚ[™ĞÙ\YšXØ]JH[ÙHÂˆ[\˜Z[\™HHÜ\˜][ÛÛÛ™›Xİ˜Z[\™J™\]Y\İYˆ›X[˜YÚ[™ĞÙ\YšXØ]JBˆ™]\›‚ˆBˆY™\ˆÈ™[X\ÙSÜ\˜][ÛŠÜ\˜][Û“X\ÙJHBˆ˜\ˆ\]YHXØÛİ[ˆ\]Y˜Ù\YšXØ]TÙ\šX[[X™\ˆHš[ˆ\]YœÙ[XİYÙ\YšXØ]TÙ\šX[[X™\ˆHš[ˆÈÂˆH]ØZ]XØÛİ[™\ÜÚ]ÜKœØ]™J\]Y
BˆH]ØZ]Ù^XÚZ[Ë˜ÛX\”ÚYÛš[™ÓX]\šX[
XØÛİ[QˆXØÛİ[šY
Bˆ[˜[Y]PÙ\YšXØ]R[™[ÜT™Yœ™\Ú
›ÜˆXØÛİ[šY
BˆÙ\YšXØ]R[™[ÜšY\ÖØXØÛİ[šYHHš[ˆ]ØZ]ØY
›Ü˜ÙNˆYJBˆOÈ]ØZ]ÙÔİÜ™OË˜\[™
ˆØ]YÛÜNˆ˜XØÛİ[ˆY\ÜØYÙNˆ¹§+9g,9ëo¹d#z+ày.i¹ï$ùkf9mì¹®!zfi;ï#9."ù«(yëo¹d#y/&ºaãy¥¬9å,ú+íú+ày.iˆ‚ˆ
BˆÙÜÈH
OÈ]ØZ]ÙÔİÜ™OË™[šY\Ê
JHÏÈÙÜÂˆ]ØZ]™Yœ™\ÚÙÑ^Ü^

BˆHØ]ÚÂˆ[\˜Z[\™HHÙ[‹™˜Z[\™Jˆ]Nˆ¹¥è9¬åy¦í9¥¬:+ày.iˆ‹ˆ™X\ÛÛˆ¹®!zfi9¥í¹æ¡:+ày.iº+¬9oey¢%¹§+9§.¹ï$ùkf9/çykf9i,z-)xà ˆ‹ˆ™XÛİ™\Nˆºaãy¥¬9®!zfi;ï&ù.ãyi,z-)z+íúaãy¥¬:j£:+àH\HQ‹ˆÛÙNˆ”ÑPSPÑT•LLH‚ˆ
BˆBˆB‚ˆš]˜]H[˜ÈÜ\˜][ÛÛÛ™›Xİ˜Z[\™J™\]Y\İYˆÜ\˜][ÛÛÛÜ™[˜]Ü‹’Ú[™
HOˆ[\Ü˜Z[\™HÂˆÜ\˜][ÛÛÛÜ™[˜]ÜË˜ÛÛ™›Xİ˜Z[\™J™\]Y\İYˆ™\]Y\İY
BˆÏÈÙ[‹™˜Z[\™Jˆ]Nˆ¹¦ ¹¥í¹¥è9¬åy¢iú(c‹ˆ™X\ÛÛˆ¹cé¹. :hny¤ãy/g9.ãyg*9k£9¢$;ï#9..º`oùacyëo¹d#xà z+ày.i¹¢%¹¥¡ù.í¹â­¹  y.¤¹æî:)¡¹æå»ï#9odùbcy¤ãy/g9mìºf.ù«h¸à ˆ‹ˆ™XÛİ™\Nˆ¹ëbyo¡yodùbcy¤ãy/g9k£9¢$9d#ºaãz+åH‹ˆÛÙNˆ”ÑPSSÔLH‚ˆ
BˆB‚ˆš]˜]H[˜ÈXÜ]Z\™SÜ\˜][ÛŠˆÈÚ[™ˆÜ\˜][ÛÛÛÜ™[˜]Ü‹’Ú[™ˆ\QˆURQÈHš[ˆ
H\Ş[˜ÈOˆÜ\˜][ÛÛÛÜ™[˜]Ü‹“X\ÙOÈÂˆİX\™]Ü\˜][ÛÛÛÜ™[˜]Üˆ[ÙHÂˆ™]\›ˆ[˜ÛÛÜ™[˜]Y
Ú[™\Qˆ\Q
BˆBˆËÈ:!ê¹bª9ëbyo¡yodùbcy¤ãy/g9k£9¢$;ï#9.#yo.H¹¦ ¹¥í¹¥è9¬åy¢iú(c¹o.yê¥Âˆ™]\›ˆ]ØZ]Ü\˜][ÛÛÛÜ™[˜]Ü‹˜™YÚ[•ØZ][™ÊÚ[™\Qˆ\Q
BˆB‚ˆš]˜]H[˜È™[X\ÙSÜ\˜][ÛŠÈX\ÙNˆÜ\˜][ÛÛÛÜ™[˜]Ü‹“X\ÙJHÂˆÜ\˜][ÛÛÛÜ™[˜]ÜË™[™
X\ÙJBˆB‚ˆš]˜]H[˜È™Yœ™\ÚÙÑ^Ü^

H\Ş[˜ÈÂˆÈH]ØZ]ÙÕ^›Ü•šY]Ú[™Ê
BˆB‚ˆİ]XÈ[˜È™]šY]Ê
HOˆÙ][™ÜÕšY]Ó[Ù[Âˆ][Ù[HÙ][™ÜÕšY]Ó[Ù[

Bˆ[Ù[˜XØÛİ[ÈHÂˆ\PXØÛİ[™XÛÜ™
ˆX\ÚÙY[XZ[ˆ™
ŠŠXÛİY˜ÛÛH‹ˆXØÛİ[Y[YšY\ˆœ™]šY]ËXXØÛİ[‹ˆX[RQˆ”‘U’QUÕPSH‹ˆX[S˜[YNˆ¹.*¹.®¹fèºf'È‹ˆ\Ñœ™YUX[NˆYKˆİ]\Îˆ™\šYšYYˆÙ\YšXØ]TÙ\šX[[X™\ˆ”‘U’QUËPÑT•Q’PĞUH‹ˆÙ[XİYÙ\YšXØ]TÙ\šX[[X™\ˆ”‘U’QUËPÑT•Q’PĞUH‹ˆ\İ™\šYšYY]ˆ]J
Bˆ
BˆBˆ[Ù[˜Xİ]™PXØÛİ[QH[Ù[˜XØÛİ[Ë™š\œİËšYˆ[Ù[™[XØÛİ[[XZ[ÖÛ[Ù[˜XØÛİ[ÖÌKšYHH™[[ĞXÛİY˜ÛÛH‚ˆ[Ù[œZ\š[™Ô™XÛÜ™HZ\š[™Ô™XÛÜ™
ˆ]šXÙRY[YšY\ˆ”‘U’QUËQU’PÑH‹ˆ\Ô™[[İTZ\š[™ÎˆYBˆ
Bˆ™]\›ˆ[Ù[ˆB‚ˆš]˜]Hİ]XÈ]ØØ[]•”•[˜]˜Z[X›Q˜Z[\™HH[\Ü˜Z[\™Jˆ]Nˆ“ØØ[]•”ˆ9§*¹l,yîêˆ‹ˆ™X\ÛÛˆ“ØØ[]•”ˆ9§*¹l,yîê¸à º+íùab:/ç¹£©HÚKQšH9nm¹èkº+©ØØ[]•”ˆ9mìº/ç¹£©xà ˆ‹ˆ™XÛİ™\Nˆ¹çéz`dù.¡ˆ‹ˆÛÙNˆ”ÑPSRS”ÕSMÌ˜H‚ˆ
B‚‚ˆš]˜]Hİ]XÈ[˜È˜Z[\™Jˆ]Nˆİš[™Ëˆ™X\ÛÛˆİš[™Ëˆ™XÛİ™\Nˆİš[™ËˆÛÙNˆİš[™Âˆ
HOˆ[\Ü˜Z[\™HÂˆ[\Ü˜Z[\™Jˆ]Nˆ]Kˆ™X\ÛÛˆ™X\ÛÛ‹ˆ™XÛİ™\Nˆ™XÛİ™\KˆÛÙNˆÛÙBˆ
BˆBŸB