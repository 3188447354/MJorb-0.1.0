import Combine
import Foundation
@preconcurrency import AltSign

enum SettingsRoute: Hashable {
    case account
    case addAccount
    case certificates
    case accountDetail(UUID)
    case pairing
    /// ä»è®¾å¤‡é€šé“å¤±è´¥æ¢å¤æ—¶è¿›å…¥è®¾å¤‡é¡µï¼Œå¹¶ç«‹å³å±•ç¤ºæœ¬æ¬¡è¿æ¥è¯Šæ–­ã€‚
    /// è¿™ä¸æ˜¯ç‹¬ç«‹é¡µé¢ï¼šLocalDevVPN æ˜¯è®¾å¤‡è¿æ¥çš„ä¸€éƒ¨åˆ†ã€‚
    case pairingDiagnostic
    case storage
}

/// è‡ªç®¡ç†çŠ¶æ€çš„å±•ç¤ºæ¨¡å‹ï¼šView åªè¯»è¿™é‡Œï¼Œä¸è‡ªå·±çŒœçŠ¶æ€ã€‚
struct SelfManagementPresentation: Equatable, Sendable {
    let state: SelfManagementState
    let title: String
    let detail: String
    let allowsInstall: Bool
    let showsComputerRecovery: Bool

    init(_ state: SelfManagementState) {
        self.state = state
        let values: (String, String, Bool, Bool)
        switch state {
        case .externalBootstrap:
            values =
                ("ç”µè„‘ç­¾åï¼Œç­‰å¾…æœ¬æœºæ¥ç®¡", "å…ˆå‡†å¤‡ä¸€å¼  Seal è‡ªå·±èƒ½ç”¨çš„ç­¾åè¯ä¹¦ã€‚", true, false)
        case .preparingLocalIdentity:
            values =
                ("æ­£åœ¨å‡†å¤‡æœ¬æœºç­¾åèº«ä»½", "è¯·ä¿æŒ Seal åœ¨å‰å°ã€‚", false, false)
        case .localIdentityReady:
            values =
                ("æœ¬æœºèº«ä»½å·²å°±ç»ª", "ç°åœ¨å¯ä»¥æäº¤è¦†ç›–å®‰è£…ã€‚", true, false)
        case .awaitingReplacementConfirmation:
            values =
                ("å·²æäº¤å®‰è£…ï¼Œç­‰å¾…é‡æ–°æ‰“å¼€ Seal ç¡®è®¤", "è¯·ä¸Šæ»‘å›åˆ°ä¸»å±å¹•ï¼Œç­‰ iOS ç”¨æ–°ç‰ˆå®Œæˆæ›¿æ¢ï¼Œå†é‡æ–°æ‰“å¼€ Sealã€‚æœ¬é¡µä¼šè‡ªåŠ¨ç¡®è®¤å®‰è£…ç»“æœã€‚", false, false)
        case .selfManaged:
            values =
                ("Seal å·²ç”±æœ¬æœºç®¡ç†", "åç»­ç»­ç­¾å¤ç”¨æœ¬æœºè¯ä¹¦ã€‚", true, false)
        case .recoveryRequired:
            values =
                ("éœ€è¦ç”¨ç”µè„‘è¦†ç›–å®‰è£…æ¢å¤", "ä¸è¦å¸è½½ Sealã€‚", false, true)
        }
        title = values.0
        detail = values.1
        allowsInstall = values.2
        showsComputerRecovery = values.3
    }
}

/// è¯ä¹¦è¡Œæ ‡ç­¾çš„å›ºå®šå«ä¹‰ã€‚
enum CertificateRoleLabel: Equatable, Sendable {
    case currentSealSigner       // å½“å‰ Seal å®é™…ä½¿ç”¨
    case locallyUsable           // æœ¬æœºæŒæœ‰åŒ¹é…ç§é’¥
    case external                // Apple ç«¯å­˜åœ¨ä½†æœ¬æœºæ²¡æœ‰ç§é’¥
    case associatedOnThisDevice  // åªç»Ÿè®¡æœ¬æœºå·²å®‰è£… App
    case associationUnknown      // æ— æ³•ç¡®è®¤

    var title: String {
        switch self {
        case .currentSealSigner: return "å½“å‰ Seal å®é™…ä½¿ç”¨"
        case .locallyUsable: return "æœ¬æœºå¯ç”¨äºç­¾å"
        case .external: return "åªå­˜åœ¨äº Apple æœåŠ¡å™¨"
        case .associatedOnThisDevice: return "æœ¬æœºå·²å®‰è£… App åœ¨ç”¨"
        case .associationUnknown: return "å…³è”çŠ¶æ€æ— æ³•ç¡®è®¤"
        }
    }
}

/// è‡ªç®¡ç†çŠ¶æ€è§£æï¼šçœŸå®èº«ä»½ + æœªç»“ç®—äº‹åŠ¡ + ç­¾åè€…æ˜¯å¦æŒæœ‰æœ¬æœºç§é’¥ã€‚
/// äº‹åŠ¡åœ¨è¿›è¡Œä¸­æ—¶ä¼˜å…ˆå±•ç¤ºäº‹åŠ¡çŠ¶æ€ï¼›èº«ä»½è¯»ä¸å‡ºæ¥ä¸€å¾‹æŒ‰éœ€è¦æ¢å¤å¤„ç†ã€‚
enum SelfManagementStateResolver {
    static func resolve(
        identity: InstalledIdentity?,
        pendingTransaction: SelfReplacementTransaction?,
        signerHasLocalPrivateKey: Bool
    ) -> SelfManagementState {
        guard let identity, identity.isComplete,
              let signer = identity.mainTarget?.signerSerialNumber,
              SigningCertificateSelectionPolicy.normalizedSerialNumber(signer).isEmpty == false
        else {
            return .recoveryRequired
        }
        if let pendingTransaction {
            switch pendingTransaction.phase {
            case .prepared:
                return .localIdentityReady
            case .submitting, .awaitingReplacementConfirmation, .installedOldIdentity, .settling:
                return .awaitingReplacementConfirmation
            case .recoveryRequired:
                return .recoveryRequired
            case .confirmed:
                // loadPending ä¸ä¼šè¿”å›å·²ç¡®è®¤äº‹åŠ¡ï¼›é˜²å¾¡åˆ†æ”¯æŒ‰æ— äº‹åŠ¡å¤„ç†ã€‚
                break
            }
        }
        return signerHasLocalPrivateKey ? .selfManaged : .externalBootstrap
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    struct PendingTeamSelection: Identifiable {
        let id = UUID()
        let authenticated: AuthenticatedAppleAccount

        var teams: [AppleTeamRecord] { authenticated.teams }
    }

    enum AccountPhase: Equatable {
        case idle
        case authenticating
    }

    enum DiagnosticState: Equatable {
        case idle
        case running
        case ready(deviceIdentifier: String)
        case failed(ImportFailure)
    }

    enum PhonePairingState: Equatable {
        case idle
        case requestingLocalNetwork
        case waitingForSystemConfirmation
        case showingCode(String)
        case validating
        case waitingForLocalDevVPN
        case completed
        case failed(ImportFailure)
    }

    @Published private(set) var accounts: [AppleAccountRecord] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var fullAccountEmails: [UUID: String] = [:]
    @Published private(set) var appIconData: [UUID: Data] = [:]
    @Published private(set) var pairingRecord: PairingRecord?
    @Published private(set) var accountPhase: AccountPhase = .idle
    @Published private(set) var diagnosticState: DiagnosticState = .idle
    @Published private(set) var phonePairingState: PhonePairingState = .idle
    @Published private(set) var installDiagnostics: InstallChannelDiagnostics = .empty
    @Published private(set) var logs: [SealLogEntry] = []
    @Published private(set) var signingHistory: [SigningHistoryRecord] = []
    @Published private(set) var signingHistoryIconData: [UUID: Data] = [:]
    @Published private(set) var certificateInventories: [UUID: ApplePortalInventory] = [:]
    @Published private(set) var certificateInventoryLoadingIDs: Set<UUID> = []
    @Published private(set) var certificateInventoryFailures: [UUID: ImportFailure] = [:]
    @Published private(set) var certificateHealthStatuses: [UUID: CertificateHealthStatus] = [:]
    @Published private(set) var isCertificateOperationRunning = false
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var reminderHours = 24
    @Published private(set) var notificationStatus = NotificationScheduleStatus.disabled
    @Published private(set) var storageUsage: SettingsStorageUsage = .empty
    @Published private(set) var reclaimableSignedIPACacheCount = 0
    @Published private(set) var storageMaintenanceSummary: String?
    @Published private(set) var logExportText = ""
    @Published var alertFailure: ImportFailure?
    @Published var requestedRoute: SettingsRoute?
    @Published private(set) var pendingTeamSelection: PendingTeamSelection?
    @Published private(set) var selfManagement: SelfManagementPresentation =
        .init(.externalBootstrap)
    @Published private(set) var isSelfManagementLoading = true
    /// å½“å‰è¿è¡Œ Seal çš„çœŸå® CMS ç­¾åè€…ï¼›è¯»ä¸å‡ºæ¥æ—¶ä¸º nilï¼ˆè¯ä¹¦è¡Œæ®æ­¤æ‰“æ ‡ç­¾ï¼‰ã€‚
    @Published private(set) var sealActualSignerSerialNumber: String?

    let verificationBroker = VerificationCodeBroker()

    private let accountRepository: (any AccountRepository)?
    private let keychain: KeychainVault?
    private let accountClient: AppleAccountClient?
    private let pairingStore: PairingStore?
    private let installChannel: (any InstallChannel)?
    private let pairingTunnelProbe: any VPNOnDemandActivating
    private let appStore: (any AppStore)?
    private let fileStore: AppFileStore?
    private let logStore: SealLogStore?
    private let signingHistoryStore: SigningHistoryStore?
    private let applePortalInventoryService: ApplePortalInventoryService?
    private let applePortalCertificateService: ApplePortalCertificateService?
    private let notificationScheduler: ExpiryNotificationScheduler?
    private let notificationPreferences: NotificationPreferences?
    private let anisetteEnvironment: (any AnisetteEnvironmentManaging)?
    private let signingPreferenceStore: SigningPreferenceStore?
    private let operationCoordinator: OperationCoordinator?
    private let selfReplacementStore: SelfReplacementTransactionStore?
    private var phonePairingHost: PhonePairingHost?
    private var phonePairingLease: OperationCoordinator.Lease?
    private var isPhonePairingAutomaticCheckRunning = false
    private var certificateInventoryRefreshGate = ApplePortalInventoryRefreshGate()
    private var hasLoaded = false
    private var loadGeneration = SettingsLoadGenerationGate()
    private static let pairingAssistantInboxFileName = "SealPairing.mobiledevicepairing"
    private static let pairingAssistantSource = "Seal é…å¯¹åŠ©æ‰‹"

    init(
        accountRepository: any AccountRepository,
        keychain: KeychainVault,
        accountClient: AppleAccountClient,
        pairingStore: PairingStore,
        installChannel: any InstallChannel,
        appStore: any AppStore,
        fileStore: AppFileStore,
        logStore: SealLogStore,
        signingHistoryStore: SigningHistoryStore,
        notificationScheduler: ExpiryNotificationScheduler,
        notificationPreferences: NotificationPreferences,
        anisetteEnvironment: any AnisetteEnvironmentManaging,
        signingPreferenceStore: SigningPreferenceStore,
        operationCoordinator: OperationCoordinator? = nil,
        selfReplacementStore: SelfReplacementTransactionStore? = nil,
        pairingTunnelProbe: any VPNOnDemandActivating = LocalDevVPNOnDemandActivator()
    ) {
        self.accountRepository = accountRepository
        self.keychain = keychain
        self.accountClient = accountClient
        self.pairingStore = pairingStore
        self.installChannel = installChannel
        self.pairingTunnelProbe = pairingTunnelProbe
        self.appStore = appStore
        self.fileStore = fileStore
        self.logStore = logStore
        self.signingHistoryStore = signingHistoryStore
        self.applePortalInventoryService = ApplePortalInventoryService()
        self.applePortalCertificateService = ApplePortalCertificateService(logStore: logStore)
        self.notificationScheduler = notificationScheduler
        self.notificationPreferences = notificationPreferences
        self.anisetteEnvironment = anisetteEnvironment
        self.signingPreferenceStore = signingPreferenceStore
        self.operationCoordinator = operationCoordinator
        self.selfReplacementStore = selfReplacementStore
        notificationsEnabled = notificationPreferences.isEnabled
        reminderHours = notificationPreferences.leadHours
        // ç»­ç­¾å®Œæˆååˆ·æ–°æé†’çŠ¶æ€ï¼Œé¿å…æ˜¾ç¤ºæ—§æ—¥æœŸéœ€æ‰‹åŠ¨å¼€å…³æ‰æ›´æ–°
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshNotificationStatusAfterRenewal),
            name: .sealRenewalCompleted,
            object: nil
        )
    }

    init(startupFailure: ImportFailure) {
        accountRepository = nil
        keychain = nil
        accountClient = nil
        pairingStore = nil
        installChannel = nil
        pairingTunnelProbe = LocalDevVPNOnDemandActivator()
        appStore = nil
        fileStore = nil
        logStore = nil
        signingHistoryStore = nil
        applePortalInventoryService = nil
        applePortalCertificateService = nil
        notificationScheduler = nil
        notificationPreferences = nil
        anisetteEnvironment = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        selfReplacementStore = nil
        alertFailure = startupFailure
    }

    private init() {
        accountRepository = nil
        keychain = nil
        accountClient = nil
        pairingStore = nil
        installChannel = nil
        pairingTunnelProbe = LocalDevVPNOnDemandActivator()
        appStore = nil
        fileStore = nil
        logStore = nil
        signingHistoryStore = nil
        applePortalInventoryService = nil
        applePortalCertificateService = nil
        notificationScheduler = nil
        notificationPreferences = nil
        anisetteEnvironment = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        selfReplacementStore = nil
        hasLoaded = true
    }

    var environment: EnvironmentSnapshot {
        EnvironmentSnapshot(
            accountCount: accounts.count,
            verifiedAccountCount: accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }.count,
            hasPairingFile: pairingRecord != nil,
            channelIsReady: {
                guard case .ready = diagnosticState else { return false }
                return true
            }()
        )
    }

    func load(force: Bool = false) async {
        guard force || hasLoaded == false else { return }
        guard let accountRepository, let pairingStore else { return }
        let generation = loadGeneration.issue()

        do {
            let fetchedAccounts = try await accountRepository.fetchAll()
            guard loadGeneration.accepts(generation) else { return }
            let repairedAccounts = try await repairLegacyAccountStatuses(fetchedAccounts)
            guard loadGeneration.accepts(generation) else { return }
            let displayedAccounts = try await refreshedAccountDisplayNames(repairedAccounts)
            guard loadGeneration.accepts(generation) else { return }

            let loadedPairing: PairingRecord?
            do {
                loadedPairing = try await pairingStore.current()
            } catch {
                loadedPairing = PairingRecord(
                    deviceIdentifier: nil,
                    isRemotePairing: false,
                    validationStatus: .fileUnreadable
                )
            }
            guard loadGeneration.accepts(generation) else { return }

            let preferredAccountID: UUID?
            if let signingPreferenceStore {
                preferredAccountID = await signingPreferenceStore.activeAccountID()
            } else {
                preferredAccountID = nil
            }
            guard loadGeneration.accepts(generation) else { return }

            let selectableAccounts = displayedAccounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
            let resolvedAccountID: UUID?
            if let preferredAccountID, displayedAccounts.contains(where: { $0.id == preferredAccountID }) {
                resolvedAccountID = preferredAccountID
            } else if let current = activeAccountID, displayedAccounts.contains(where: { $0.id == current }) {
                resolvedAccountID = current
            } else {
                resolvedAccountID = selectableAccounts.first?.id
                if preferredAccountID == nil {
                    await signingPreferenceStore?.setActiveAccountID(resolvedAccountID)
                }
            }

            // å¿«é€Ÿæ˜¾ç¤ºæ ¸å¿ƒæ•°æ®
            accounts = displayedAccounts
            pairingRecord = loadedPairing
            activeAccountID = resolvedAccountID
            // è¯ä¹¦é¡µä¼šåœ¨è¿™é‡Œä¹‹åç«‹å³å‡ºç°ã€‚ç¼“å­˜å¿…é¡»å…ˆå°±ç»ªï¼Œä¸èƒ½æ’åœ¨é‚®ç®±ã€å›¾æ ‡ç­‰
            // éå…³é”®åå°è¯»å–ä¹‹åï¼Œå¦åˆ™â€œç¼“å­˜ä¼˜å…ˆâ€ä¼šå› ç«æ€é€€åŒ–ä¸ºæ¯æ¬¡è¿›å…¥éƒ½è”ç½‘åŒæ­¥ã€‚
            loadCertificateInventoryCache(for: displayedAccounts)
            hasLoaded = true

            // åå°åŠ è½½éå…³é”®æ•°æ®
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                _ = await self.importPairingAssistantInboxIfPresent()
                guard await self.isCurrentLoad(generation) else { return }

                let emails = await self.loadFullAccountEmails(for: displayedAccounts)
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run { self.fullAccountEmails = emails }

                let storedApps = (try? await self.appStore?.fetchAll()) ?? []
                let appIcons = await self.loadAppIcons(for: storedApps)
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run { self.appIconData = appIcons }

                let loadedLogs = (try? await self.logStore?.entries()) ?? []
                let loadedHistory = (try? await self.signingHistoryStore?.records()) ?? []
                let historyIcons = await self.loadSigningHistoryIcons(for: loadedHistory)
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run {
                    self.logs = loadedLogs
                    self.signingHistory = loadedHistory
                    self.signingHistoryIconData = historyIcons
                }

                var loadedNotificationsEnabled = await MainActor.run { self.notificationsEnabled }
                var loadedReminderHours = await MainActor.run { self.reminderHours }
                var loadedNotificationStatus = await MainActor.run { self.notificationStatus }
                let prefsEnabled = await MainActor.run { self.notificationPreferences?.isEnabled }
                let prefsLeadHours = await MainActor.run { self.notificationPreferences?.leadHours }
                if let prefsEnabled, let prefsLeadHours {
                    loadedNotificationsEnabled = prefsEnabled
                    loadedReminderHours = prefsLeadHours
                    if let notificationScheduler = self.notificationScheduler {
                        loadedNotificationStatus = await notificationScheduler.status(sealEnabled: loadedNotificationsEnabled)
                    }
                }
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run {
                    self.notificationsEnabled = loadedNotificationsEnabled
                    self.reminderHours = loadedReminderHours
                    self.notificationStatus = loadedNotificationStatus
                }

                let loadedStorageUsage: SettingsStorageUsage
                if let fileStore = self.fileStore {
                    loadedStorageUsage = (try? await fileStore.storageUsage()) ?? .empty
                } else {
                    loadedStorageUsage = .empty
                }
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run {
                    self.storageUsage = loadedStorageUsage
                }
                guard await self.isCurrentLoad(generation) else { return }
                await self.refreshLogExportText()
            }
        } catch {
            guard loadGeneration.accepts(generation) else { return }
            alertFailure = Self.failure(
                title: "æ— æ³•è¯»å–è®¾ç½®",
                reason: "æœ¬æœºä¿å­˜çš„è®¾ç½®è¯»ä¸å‡ºæ¥ï¼Œè®¾ç½®é¡¹æ— æ³•åŠ è½½ã€‚",
                recovery: "ä¸‹æ‹‰åˆ·æ–°é¡µé¢é‡è¯•",
                code: "SEAL-SET-001"
            )
        }
    }

    /// `loadGeneration` å±äºä¸» actorï¼›è„±ç¦»ä¸» actor çš„åå°è¯»å–å¿…é¡»åœ¨å‘å¸ƒå‰é‡æ–°ç¡®è®¤ä»£æ¬¡ã€‚
    private func isCurrentLoad(_ generation: Int) -> Bool {
        loadGeneration.accepts(generation)
    }

    func performLightweightLaunchCheck() async {
        await refreshPhonePairingStatus()
    }

    /// åœ¨å¯åŠ¨å’Œ iOS 27 è®¾å¤‡é¡µæ‰“å¼€æ—¶è‡ªåŠ¨å¤æ ¸å½“å‰é€šé“ï¼›å·²éªŒè¯çš„é…å¯¹å‡­æ®ä¸ä¼šå› ç¬æ—¶ä¸å¯è¾¾è¢«é™çº§ã€‚
    func refreshPhonePairingStatus() async {
        guard isPhonePairingAutomaticCheckRunning == false else { return }
        isPhonePairingAutomaticCheckRunning = true
        defer { isPhonePairingAutomaticCheckRunning = false }

        await load(force: true)
        guard pairingRecord != nil, diagnosticState != .running else { return }
        phonePairingState = .validating
        await validateImportedPairingWhenTunnelAvailable(
            successMessage: "LocalDevVPN æ­£å¸¸",
            waitingMessage: "é…å¯¹ä¿¡æ¯å·²å¯¼å…¥ï¼Œç­‰å¾… LocalDevVPN è¿æ¥åéªŒè¯"
        )
        phonePairingState = Self.phonePairingStateAfterAutomaticCheck(
            diagnosticState: diagnosticState
        )
    }

    static func phonePairingStateAfterAutomaticCheck(
        diagnosticState: DiagnosticState
    ) -> PhonePairingState {
        switch diagnosticState {
        case .ready:
            return .completed
        case let .failed(failure):
            return .failed(failure)
        case .idle, .running:
            return .waitingForLocalDevVPN
        }
    }

    var activeAccount: AppleAccountRecord? {
        guard let activeAccountID else { return nil }
        return accounts.first { $0.id == activeAccountID }
    }

    func fullEmail(for account: AppleAccountRecord) -> String {
        fullAccountEmails[account.id] ?? account.maskedEmail
    }

    func selectActiveAccount(_ account: AppleAccountRecord) async {
        guard AccountAvailabilityPolicy.isSelectable(account),
              accounts.contains(where: { $0.id == account.id }) else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] è®¾ç½®é¡µåˆ‡æ¢è´¦å·: \(account.id.uuidString.prefix(8))")
        if activeAccountID != account.id {
            invalidateCertificateInventoryRefresh(for: activeAccountID)
        }
        activeAccountID = account.id
        await signingPreferenceStore?.setActiveAccountID(account.id)
    }

    func selectCertificate(
        serialNumber: String,
        for account: AppleAccountRecord
    ) async {
        guard let accountRepository, let keychain else { return }
        let secret: AccountSecret?
        do {
            secret = try await keychain.load(accountID: account.id)
        } catch {
            alertFailure = Self.failure(
                title: "è¯ä¹¦ä¸å¯ç”¨",
                reason: "è¿™å¼ è¯ä¹¦åœ¨æœ¬æœºç¼ºå°‘å¯†é’¥ï¼Œæ— æ³•ä½¿ç”¨ã€‚",
                recovery: "é‡æ–°éªŒè¯ Apple ID",
                code: "SEAL-CERT-206"
            )
            return
        }
        guard let inventory = certificateInventories[account.id],
              inventory.certificates.contains(where: {
                  $0.serialNumber == serialNumber && $0.hasLocalPrivateKey
              }),
              let secret,
              // ç§é’¥åˆ¤å®šä¸ç­¾åé“¾è·¯ä¸€è‡´ï¼šæŒ‰ serial æŸ¥ keychain é‡Œä¿å­˜çš„å…¨éƒ¨ P12ï¼ˆå«å†å² mapï¼‰ï¼Œ
              // ä¸è¦æ±‚å®ƒæ­£æ˜¯å½“å‰ç»‘å®šçš„é‚£å¼ â€”â€”é€‰ä¸­å³å®Œæˆåˆ‡æ¢ã€‚
              secret.p12(for: serialNumber) != nil else {
            alertFailure = Self.failure(
                title: "è¯ä¹¦ä¸å¯ç”¨",
                reason: "è¿™å¼ è¯ä¹¦åœ¨æœ¬æœºç¼ºå°‘å¯†é’¥ï¼Œå½“å‰ç­¾åè¯ä¹¦æ²¡æœ‰æ›´æ¢ã€‚",
                recovery: "é€‰æ‹©å…¶ä»–è¯ä¹¦ï¼Œæˆ–é‡æ–°éªŒè¯ Apple ID",
                code: "SEAL-CERT-206a"
            )
            return
        }

        var updated = account
        updated.selectedCertificateSerialNumber = serialNumber
        do {
            try await accountRepository.save(updated)
            await load(force: true)
            try? await logStore?.append(
                category: .account,
                message: "å·²é€‰æ‹©ç­¾åè¯ä¹¦ï¼Œå®Œæ•´ Serialï¼š\(serialNumber)"
            )
            logs = (try? await logStore?.entries()) ?? logs
            await refreshLogExportText()
        } catch {
            alertFailure = Self.failure(
                title: "æ— æ³•é€‰æ‹©è¯ä¹¦",
                reason: "è¯ä¹¦é€‰æ‹©æœªèƒ½ä¿å­˜ã€‚",
                recovery: "é‡æ–°é€‰æ‹©ï¼›å¦‚æŒç»­å¤±è´¥è¯·é‡æ–°éªŒè¯ Apple ID",
                code: "SEAL-CERT-102"
            )
        }
    }

    func createLocalCertificate(for account: AppleAccountRecord) async {
        guard isCertificateOperationRunning == false,
              let keychain,
              let accountRepository,
              let applePortalCertificateService else { return }
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] åˆ›å»ºæœ¬åœ°è¯ä¹¦: è´¦å· \(account.id.uuidString.prefix(8))")
        guard let operationLease = await acquireOperation(.managingCertificate) else {
            alertFailure = operationConflictFailure(requested: .managingCertificate)
            return
        }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let originalSecret = try await keychain.load(accountID: account.id) else {
                await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "æ— æ³•åˆ›å»ºè¯ä¹¦",
                    reason: "æœ¬æœºæ²¡æœ‰å½“å‰ Apple ID çš„ç™»å½•å‡­æ®ã€‚",
                    recovery: "é‡æ–°éªŒè¯ Apple ID",
                    code: "SEAL-AUTH-105b"
                )
            }

            let material = try await applePortalCertificateService.createLocalCertificate(
                account: account,
                secret: originalSecret
            )
            try await persistCreatedCertificate(
                material,
                originalSecret: originalSecret,
                originalAccount: account,
                keychain: keychain,
                accountRepository: accountRepository,
                certificateService: applePortalCertificateService
            )
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            try? await logStore?.append(
                category: .account,
                message: "å·²åˆ›å»ºå¹¶ä¿å­˜æœ¬æœºç­¾åè¯ä¹¦ã€‚å®Œæ•´ Serialï¼š\(material.serialNumber)"
            )
            logs = (try? await logStore?.entries()) ?? logs
            await refreshLogExportText()
        } catch let failure as ImportFailure {
            alertFailure = failure
        } catch {
            alertFailure = Self.failure(
                title: "åˆ›å»ºç­¾åè¯ä¹¦å¤±è´¥",
                reason: "Apple æœªè¿”å›ç­¾åè¯ä¹¦ï¼Œå¯èƒ½ç½‘ç»œä¸ç¨³å®šæˆ– Apple æœåŠ¡å¼‚å¸¸ã€‚",
                recovery: "æ£€æŸ¥ç½‘ç»œåé‡æ–°åˆ›å»º",
                code: "SEAL-CERT-211"
            )
        }
    }

    func revokeCertificate(
        serialNumber: String,
        for account: AppleAccountRecord
    ) async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] æ’¤é”€è¯ä¹¦: åºåˆ—å· \(serialNumber.prefix(8))â€¦, è´¦å· \(account.id.uuidString.prefix(8))")
        guard isCertificateOperationRunning == false,
              let keychain,
              let accountRepository,
              let applePortalCertificateService else { return }
        guard let operationLease = await acquireOperation(.managingCertificate) else {
            alertFailure = operationConflictFailure(requested: .managingCertificate)
            return
        }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let originalSecret = try await keychain.load(accountID: account.id) else {
                await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "æ— æ³•æ’¤é”€è¯ä¹¦",
                    reason: "æœ¬æœºæ²¡æœ‰å½“å‰ Apple ID çš„ç™»å½•å‡­æ®ã€‚",
                    recovery: "é‡æ–°éªŒè¯ Apple ID",
                    code: "SEAL-AUTH-105c"
                )
            }

            // çœŸå®ç­¾åè€… A æ°¸è¿œä¸å¯æ’¤é”€ï¼šæ’¤äº†å½“å‰è¿è¡Œçš„ Seal ç«‹åˆ»ã€Œä¸å†å¯ç”¨ã€ã€‚
            // èº«ä»½è¯»ä¸å‡ºæ¥æ—¶æ— æ³•è¯æ˜ç›®æ ‡ä¸æ˜¯ Aï¼Œä¸€å¾‹æ‹’ç»ï¼ˆåªç›¸ä¿¡çœŸå® CMS ç­¾åè€…ï¼‰ã€‚
            let runningIdentity = SelfAppMetadata.current()?.installedIdentity
            guard runningIdentity?.isComplete == true,
                  let sealActualSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
                throw Self.failure(
                    title: "æ— æ³•æ’¤é”€è¯ä¹¦",
                    reason: "æ— æ³•ç¡®è®¤å½“å‰ Seal å®é™…ä½¿ç”¨çš„è¯ä¹¦ï¼Œä¸ºå®‰å…¨èµ·è§å·²åœæ­¢æ’¤é”€ã€‚",
                    recovery: "é‡å¯ Seal åé‡æ–°æ’¤é”€",
                    code: "SEAL-CERT-230"
                )
            }
            if CertificateRevocationImpact.isActualSealSigner(
                serialNumber: serialNumber,
                actualSealSignerSerialNumber: sealActualSigner
            ) {
                throw Self.failure(
                    title: "ä¸èƒ½æ’¤é”€è¿™å¼ è¯ä¹¦",
                    reason: "è¿™å¼ è¯ä¹¦æ­£åœ¨ç»™å½“å‰è¿è¡Œçš„ Seal ç­¾åï¼Œæ’¤é”€å Seal ä¼šç«‹å³æ— æ³•æ‰“å¼€ã€‚",
                    recovery: "å¦‚éœ€æ›´æ¢ç­¾åèº«ä»½ï¼Œè¯·ç”¨ç”µè„‘æŒ‰ç›¸åŒçš„åŒ…åé‡æ–°ç­¾åå®‰è£… Seal",
                    code: "SEAL-CERT-230a"
                )
            }

            try await applePortalCertificateService.revokeCertificate(
                serialNumber: serialNumber,
                account: account,
                secret: originalSecret
            )

            // çœŸå®æ°¸ä¹…åˆ é™¤ï¼šæ’¤é”€æˆåŠŸåï¼Œæœ¬æœº keychain ä¸­è¯¥åºåˆ—å·çš„ P12 ææ–™ä¸€å¹¶ç§»é™¤
            // ï¼ˆå«éæœ¬æœºåœ¨ç”¨çš„å­¤å„¿è¯ä¹¦ï¼‰ï¼›è´¦å·è®°å½•è‹¥æ­£ç»‘å®šè¯¥è¯ä¹¦ï¼Œåˆ™æ¸…ç©ºå…¶åºåˆ—å·ã€‚
            var clearedSecret = originalSecret
            clearedSecret.removeStoredCertificateMaterial(serialNumber: serialNumber)
            try await keychain.save(clearedSecret, for: account.id)

            var clearedAccount = account
            if CertificateRevocationImpact.isLocalCertificate(serialNumber: serialNumber, account: account) {
                clearedAccount.certificateSerialNumber = nil
                clearedAccount.selectedCertificateSerialNumber = nil
            }
            try await accountRepository.save(clearedAccount)
            replaceDisplayedAccount(clearedAccount)

            // æ’¤é”€æˆåŠŸï¼šæŒä¹…åŒ– dismissalï¼ŒApple åˆ—è¡¨å»¶è¿Ÿä¹Ÿå¸¦ä¸å›æ¥ã€‚
            dismissCertificate(serialNumber: serialNumber, accountID: account.id, persistent: true)
            certificateHealthStatuses[account.id] = await localCertificateHealthStatus(
                account: clearedAccount,
                portalState: .unknown
            )

            try? await logStore?.append(
                category: .account,
                message: "ç”¨æˆ·å·²æ˜ç¡®æ’¤é”€è¯ä¹¦ã€‚å®Œæ•´ Serialï¼š\(serialNumber)"
            )
            await load(force: true)
            // æ’¤é”€åä¸ç«‹å³ä» Portal å›è¯»æ¸…å•ï¼šApple ä¾§æ’¤é”€æœ‰ä¼ æ’­å»¶è¿Ÿï¼Œç«‹å³æ‹‰ä¼šæŠŠåˆšåˆ æ‰çš„
            // è¯ä¹¦åˆå¸¦å›æ¥ã€‚æœ¬åœ°å·²ç”¨ dismissCertificate(persistent:true) åŒæ­¥ç§»é™¤å¹¶æŒä¹…åŒ–ï¼Œ
            // ç”¨æˆ·ä¸‹æ‹‰åˆ·æ–°æ—¶è¿‡æ»¤æ‰ï¼Œä¸ä¼šé‡ç°ã€‚
            logs = (try? await logStore?.entries()) ?? logs
            await refreshLogExportText()
        } catch let failure as ImportFailure {
            await load(force: true)
            // æ’¤é”€å¤±è´¥ä¸ç«‹å³å›è¯»ï¼šå¤±è´¥æ—¶è¯ä¹¦çŠ¶æ€æœªå˜ï¼Œå›è¯»åªä¼šæŠŠåŸæ ·å¸¦å›æ¥ã€‚
            // ç”¨æˆ·æ‰‹åŠ¨ä¸‹æ‹‰åˆ·æ–°æ—¶å†å¯¹è´¦ã€‚
            // ç”¨æˆ·ç‚¹äº†æ’¤é”€å°±æ˜¯æƒ³è®©å®ƒæ¶ˆå¤±ï¼Œå…ˆä»å†…å­˜ç§»é™¤ï¼›Apple ä¾§è‹¥ä»åœ¨ï¼Œä¸‹æ¬¡åˆ·æ–°ä¼šå›æ¥ã€‚
            dismissCertificate(serialNumber: serialNumber, accountID: account.id, persistent: false)
            alertFailure = failure
        } catch {
            await load(force: true)
            // åŒä¸Šï¼šå¤±è´¥ä¸ç«‹å³å›è¯»ã€‚ç”¨æˆ·æ„å›¾æ˜ç¡®ï¼Œå…ˆä»å†…å­˜ç§»é™¤ï¼›ä¸‹æ¬¡åˆ·æ–°è‹¥è¿˜åœ¨ä¼šå›æ¥ã€‚
            dismissCertificate(serialNumber: serialNumber, accountID: account.id, persistent: false)
            alertFailure = Self.failure(
                title: "è¯ä¹¦æ’¤é”€å¤±è´¥",
                reason: "Apple æœåŠ¡å™¨æœªèƒ½æ’¤é”€æŒ‡å®šè¯ä¹¦ã€‚å¯èƒ½åŸå› ï¼šç½‘ç»œä¸ç¨³å®šã€æˆ–è¯¥è¯ä¹¦å·²è¢«æ’¤é”€ã€‚",
                recovery: "æ£€æŸ¥ç½‘ç»œåé‡è¯•ï¼›å¦‚æŒç»­å¤±è´¥è¯·åœ¨ã€Œæˆ‘çš„ã€ä¸­é‡æ–°åŒæ­¥è¯ä¹¦çŠ¶æ€",
                code: "SEAL-CERT-216"
            )
        }
    }

    /// ç”¨æˆ·ç¡®è®¤æ’¤é”€å€™é€‰ C åçš„æ¥ç®¡æµç¨‹ï¼šé‡æ‹‰è¿œç«¯æ¸…å•ã€é‡è¯»çœŸå®ç­¾åè€… Aï¼Œå†æ’¤ Cï¼›
    /// æ’¤å®Œé‡æ–°æ‹‰æ¸…å•ç¡®è®¤å‡ºç°ç©ºä½ï¼Œæ‰åˆ›å»ºæœ¬æœºèº«ä»½ Bã€‚B åˆ›å»ºå¤±è´¥ä¸æ¸…é™¤ A çš„ä»»ä½•è®°å½•ã€‚
    func revokeCertificateAndCreateLocal(
        serialNumber: String,
        for account: AppleAccountRecord
    ) async {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] æ’¤é”€è¯ä¹¦å¹¶é‡å»º: åºåˆ—å· \(serialNumber.prefix(8))â€¦, è´¦å· \(account.id.uuidString.prefix(8))")
        guard isCertificateOperationRunning == false,
              let keychain,
              let accountRepository,
              let applePortalCertificateService,
              let applePortalInventoryService else { return }
        guard let operationLease = await acquireOperation(.managingCertificate) else {
            alertFailure = operationConflictFailure(requested: .managingCertificate)
            return
        }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let originalSecret = try await keychain.load(accountID: account.id) else {
                await persistVerificationFailure(.localCredentialsMissing, for: account)
                throw Self.failure(
                    title: "æ— æ³•æ›´æ¢è¯ä¹¦",
                    reason: "æœ¬æœºæ²¡æœ‰å½“å‰ Apple ID çš„ç™»å½•å‡­æ®ã€‚",
                    recovery: "é‡æ–°éªŒè¯ Apple ID",
                    code: "SEAL-AUTH-105d"
                )
            }

            // ç”¨æˆ·ç¡®è®¤åã€æ’¤é”€å‰ï¼šé‡æ–°æ‹‰è¿œç«¯æ¸…å• + é‡æ–°è¯»å–çœŸå®ç­¾åè€… Aã€‚
            // ç¡®è®¤ä¸æ‰§è¡Œä¹‹é—´çŠ¶æ€å¯èƒ½å·²å˜åŒ–ï¼Œæ’¤é”€ä¸å¯é€†ï¼Œç»ä¸å¤ç”¨æ—§å¿«ç…§ã€‚
            let runningIdentity = SelfAppMetadata.current()?.installedIdentity
            guard runningIdentity?.isComplete == true,
                  let sealActualSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
                throw Self.failure(
                    title: "æ— æ³•æ›´æ¢è¯ä¹¦",
                    reason: "æ— æ³•ç¡®è®¤å½“å‰ Seal å®é™…ä½¿ç”¨çš„è¯ä¹¦ï¼Œä¸ºå®‰å…¨èµ·è§å·²åœæ­¢æ’¤é”€ã€‚",
                    recovery: "é‡å¯ Seal åé‡æ–°æ’¤é”€",
                    code: "SEAL-CERT-230"
                )
            }
            if CertificateRevocationImpact.isActualSealSigner(
                serialNumber: serialNumber,
                actualSealSignerSerialNumber: sealActualSigner
            ) {
                throw Self.failure(
                    title: "ä¸èƒ½æ’¤é”€è¿™å¼ è¯ä¹¦",
                    reason: "è¿™å¼ è¯ä¹¦æ­£åœ¨ç»™å½“å‰è¿è¡Œçš„ Seal ç­¾åï¼Œæ’¤é”€å Seal ä¼šç«‹å³æ— æ³•æ‰“å¼€ã€‚",
                    recovery: "å¦‚éœ€æ›´æ¢ç­¾åèº«ä»½ï¼Œè¯·ç”¨ç”µè„‘æŒ‰ç›¸åŒçš„åŒ…åé‡æ–°ç­¾åå®‰è£… Seal",
                    code: "SEAL-CERT-230a"
                )
            }
            let preRevokeInventory = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: originalSecret,
                scope: .certificates
            )
            guard preRevokeInventory.certificates.contains(where: {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                    == SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
            }) else {
                throw Self.failure(
                    title: "è¯ä¹¦çŠ¶æ€å·²å˜åŒ–",
                    reason: "è¿™å¼ è¯ä¹¦åœ¨ Apple é‚£è¾¹å·²å¤±æ•ˆï¼ˆå¯èƒ½åˆšè¢«æ’¤é”€ï¼‰ï¼Œæ²¡æœ‰åˆ›å»ºæ–°è¯ä¹¦ã€‚",
                    recovery: "é‡æ–°åŒæ­¥è¯ä¹¦åç¡®è®¤å½“å‰çŠ¶æ€",
                    code: "SEAL-CERT-219"
                )
            }

            try await applePortalCertificateService.revokeCertificate(
                serialNumber: serialNumber,
                account: account,
                secret: originalSecret
            )
            invalidateCertificateInventoryRefresh(for: account.id)
            // æ’¤é”€æˆåŠŸï¼šæŒä¹…åŒ– dismissalï¼Œé¿å… Apple åˆ—è¡¨å»¶è¿Ÿå¯¼è‡´æ—§è¯ä¹¦é‡ç°ã€‚
            dismissCertificate(serialNumber: serialNumber, accountID: account.id, persistent: true)

            // æ’¤é”€æˆåŠŸåé‡æ–°æ‹‰æ¸…å•ç¡®è®¤å‡ºç°ç©ºä½ï¼Œæ‰åˆ›å»º Bï¼›ç¡®è®¤ä¸äº†ç©ºä½å°±ä¸åˆ›å»ºï¼Œ
            // é¿å…åœ¨ä»æ—§æ»¡å‘˜çš„è´¦å·ä¸Šå†æ’ä¸€æ¬¡ç¡®å®šæ€§ 3022/7460ã€‚
            let postRevokeInventory = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: originalSecret,
                scope: .certificates
            )
            let targetStillActive = postRevokeInventory.certificates.contains(where: {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                    == SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
            })
            guard targetStillActive == false else {
                throw Self.failure(
                    title: "æœªèƒ½ç¡®è®¤è¯ä¹¦åé¢å·²é‡Šæ”¾",
                    reason: "æ’¤é”€è¯·æ±‚å·²æäº¤ï¼Œä½† Apple é‚£è¾¹è¿˜èƒ½çœ‹åˆ°è¿™å¼ è¯ä¹¦ï¼Œæ²¡æœ‰åˆ›å»ºæ–°è¯ä¹¦ã€‚",
                    recovery: "ç¨åé‡æ–°åŒæ­¥è¯ä¹¦å†è¯•",
                    code: "SEAL-CERT-231"
                )
            }

            var clearedSecret = originalSecret
            var clearedAccount = account
            if originalSecret.certificateSerialNumber?.caseInsensitiveCompare(serialNumber) == .orderedSame {
                clearedSecret.certificateP12 = nil
                clearedSecret.certificateSerialNumber = nil
                clearedSecret.certificateMachineIdentifier = nil
                clearedAccount.certificateSerialNumber = nil
                clearedAccount.selectedCertificateSerialNumber = nil
                try await keychain.save(clearedSecret, for: account.id)
                try await accountRepository.save(clearedAccount)
            }

            let material = try await applePortalCertificateService.createLocalCertificate(
                account: clearedAccount,
                secret: clearedSecret
            )
            try await persistCreatedCertificate(
                material,
                originalSecret: clearedSecret,
                originalAccount: clearedAccount,
                keychain: keychain,
                accountRepository: accountRepository,
                certificateService: applePortalCertificateService
            )
            await load(force: true)
            if let refreshedAccount = accounts.first(where: { $0.id == account.id }) {
                await refreshCertificateInventory(for: refreshedAccount, force: true)
            }
            try? await logStore?.append(
                category: .account,
                message: "ç”¨æˆ·å·²æ›´æ–°è¯ä¹¦ Serialï¼š\(serialNumber) -> \(material.serialNumber)"
            )
            logs = (try? await logStore?.entries()) ?? logs
            await refreshLogExportText()
        } catch let failure as ImportFailure {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = failure
        } catch {
            await load(force: true)
            await refreshCertificateInventory(for: account, force: true)
            alertFailure = Self.failure(
                title: "æ— æ³•å®Œæˆè¯ä¹¦å¤„ç†",
                reason: "å·²æŒ‰ä½ çš„é€‰æ‹©å¤„ç†è¯ä¹¦ï¼Œä½† Apple æˆ–æœ¬æœºä¿å­˜ç¯èŠ‚æ²¡æœ‰è¿”å›æ˜ç¡®çš„å¤±è´¥åŸå› ã€‚",
                recovery: "é‡æ–°åŒæ­¥è¯ä¹¦åç¡®è®¤å½“å‰çŠ¶æ€",
                code: "SEAL-CERT-212"
            )
        }
    }

    /// æ¸…ç†ä¸å¯ç”¨è¯ä¹¦ Â· ç¬¬ä¸€æ­¥ï¼šåˆ†æå¹¶ç»™å‡ºè®¡åˆ’ï¼ˆåªè¯»ï¼Œä¸æ’¤é”€ä»»ä½•è¯ä¹¦ï¼‰ã€‚
    /// è¿”å› nil è¡¨ç¤ºåˆ†æå¤±è´¥ï¼ˆå·²å¼¹é”™è¯¯ï¼‰ã€‚plan.revocable ä¸ºç©ºæ—¶ç”± UI æç¤ºã€Œæ— éœ€æ¸…ç†ã€ã€‚
    func prepareCertificateCleanup(
        for account: AppleAccountRecord,
        apps: [AppRecord]
    ) async -> CertificateCleanupPlan? {
        try? await logStore?.append(category: .system, level: .info, message: "[SEAL-OP] å‡†å¤‡è¯ä¹¦æ¸…ç†: è´¦å· \(account.id.uuidString.prefix(8))")
        guard isCertificateOperationRunning == false,
              let keychain,
              let applePortalInventoryService else { return nil }
        guard let operationLease = await acquireOperation(.managingCertificate) else {
            alertFailure = operationConflictFailure(requested: .managingCertificate)
            return nil
        }
        defer { releaseOperation(operationLease) }

        isCertificateOperationRunning = true
        defer { isCertificateOperationRunning = false }

        do {
            guard let secret = try await keychain.load(accountID: account.id) else {
                throw Self.failure(
                    title: "æ— æ³•åˆ†æè¯ä¹¦",
                    reason: "æœ¬æœºæ²¡æœ‰å½“å‰ Apple ID çš„ç™»å½•å‡­æ®ã€‚",
                    recovery: "é‡æ–°éªŒè¯ Apple ID",
                    code: "SEAL-AUTH-105g"
                )
            }
            // æ’¤é”€å†³ç­–å¿…é¡»åŸºäºå½“ä¸‹è¿œç«¯æ¸…å•ï¼Œä¸èƒ½ç”¨ç¼“å­˜ã€‚
            let inventory = try await applePortalInventoryService.fetchInventory(
                account: account,
                secret: secret,
                scope: .certificates
            )

            // ã€Œæœ¬æœºæœ‰å¯ç”¨ç§é’¥ã€å¿…é¡»æŸ¥ keychain é‡ŒæŒ‰ serial ä¿å­˜çš„å…¨éƒ¨ P12ï¼ˆå«å†å² mapï¼‰ï¼Œ
            // ä¸ç­¾åé“¾è·¯ secret.p12(for:) çš„æ— æ„Ÿå¤ç”¨å£å¾„ä¸€è‡´ï¼›åªçœ‹å½“å‰ç»‘å®šä¼šæŠŠä»å¯å¤ç”¨çš„
            // å†å²è¯ä¹¦è¯¯åˆ¤æˆå¯æ’¤é”€ã€‚
            var localUsableSerials = Set<String>()
            for certificate in inventory.certificates {
                guard let data = secret.p12(for: certificate.serialNumber),
                      let local = try? ALTCertificate(p12Data: data, password: nil) else { continue }
                let localSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(local.serialNumber)
                let remoteSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
                if localSerial == remoteSerial {
                    localUsableSerials.insert(remoteSerial)
                }
            }

            let deviceReferenced = await DeviceProfileInspector.referencedCertificateSerials()
            // Seal è‡ªä¿æŠ¤ï¼šçœŸå®ç­¾åè¯ä¹¦æ°¸è¿œä¸æ’¤ï¼Œé¿å…æ‰‹åŠ¨æ¸…ç†æŠŠ Seal è‡ªå·±å˜ç –ã€‚
            // åªç›¸ä¿¡çœŸå® CMS ç­¾åè€…ï¼ˆinstalledIdentityï¼‰ï¼Œä¸ä¿¡æè¿°æ–‡ä»¶æˆæƒåˆ—è¡¨ã€ä¸ä¿¡ DB è®°å½•ã€‚
            // èº«ä»½è¯»ä¸å‡ºæ¥æ—¶æ— æ³•è¯æ˜ä»»ä½•ä¸€å¼ è¯ä¹¦ä¸æ˜¯ Seal çš„å‘½ï¼Œè®¡åˆ’æ•´ä½“é˜»æ–­ã€‚
            let runningIdentity = SelfAppMetadata.current()?.installedIdentity
            guard runningIdentity?.isComplete == true,
                  let sealActualSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
                return CertificateCleanupPlan.blocked(reason: "æ— æ³•ç¡®è®¤å½“å‰ Seal å®é™…ä½¿ç”¨çš„è¯ä¹¦")
            }
            let plan = CertificateCleanupPolicy.makePlan(
                certificates: inventory.certificates,
                apps: apps,
                localUsableSerials: localUsableSerials,
                deviceReferencedSerials: deviceReferenced,
                sealActualSignerSerialNumber: sealActualSigner,
                identityConfidence: .complete
            )
            try? await logStore?.append(
                category: .account,
                message: "è¯ä¹¦æ¸…ç†åˆ†æï¼šè¿œç«¯ \(inventory.certificates.count) å¼ ï¼Œå¯æ’¤é”€ \(plan.revocable.count) å¼ ï¼Œä¿ç•™ \(plan.kept.count) å¼ ï¼Œè®¾å¤‡æ ¸éªŒ\(plan.deviceVerified ? "å·²å®Œæˆ" : "ä¸å¯ç”¨")"
            )
            return plan
        } catch let failure as ImportFailure {
            alertFailure = failure
            return nil
        } catch {
            alertFailure = Self.failure(
                title: "æ— æ³•åˆ†æè¯ä¹¦",
                reason: "ä» Apple è·å–è¯ä¹¦æ¸…å•å¤±è´¥ã€‚",
                recovery: "æ£€æŸ¥ç½‘ç»œåé‡è¯•ï¼›å¦‚æŒç»­å¤±è´¥è¯·åœ¨ã€Œæˆ‘çš„ã€ä¸­é‡æ–°éªŒè¯ Apple ID",
                code: "SEAL-CERT-217"
            )
            return nil
        }
    }

    /// æ¸…ç†ä¸å¯ç”¨è¯ä¹¦ Â· ç¬¬äºŒæ­¥ï¼šæ‰§è¡Œå·²ç¡®è®¤çš„è®¡åˆ’ â€”â€” å…ˆæ‰¹é‡æ’¤é”€ï¼Œå…¨éƒ¨æ’¤å®Œå†æ–°å»ºä¸€å¼ å¹¶ç»‘å®šã€‚
    /// æ‰§è¡Œå‰ä¼šé‡æ‹‰è¿œç«¯æ¸…å•æ±‚äº¤é›†ï¼šç¡®è®¤åçš„è¿™æ®µæ—¶é—´å†…çŠ¶æ€å¯èƒ½å˜åŒ–ï¼Œæ’¤é”€ä¸å¯é€†ï¼Œ
    /// ä¸å¤ç”¨æ›´æ—©çš„å¿«ç…§ïÛNuæÚ$z{-®éÜj×&–æu7F÷&RVÇ6R²&WGW&âfÇ6RĞ¢wV&BÆWBFö7VÖVçG5U$ÂÒf–ÆTÖævW"æFVfVÇBçW&Ç2€¢f÷#¢æFö7VÖVçDF—&V7F÷'’À¢–ã¢çW6W$FöÖ–äÖ6°¢’æf—'7BVÇ6R°¢&WGW&âfÇ6P¢Ğ ¢ÆWB–æ&÷…U$ÂÒFö7VÖVçG5U$ÂæVæF–æuF„6ö×öæVçB€¢6VÆbç—&–æt76—7FçD–æ&÷„f–ÆTæÖRÀ¢—4F—&V7F÷'“¢fÇ6P¢¢wV&Bf–ÆTÖævW"æFVfVÇBæf–ÆTW†—7G2†EFƒ¢–æ&÷…U$ÂçF‚’VÇ6R°¢&WGW&âfÇ6P¢Ğ ¢òòXú®iÈih~K»nzîZéîZÙYÊi{nh˜Şˆë~Xùn™HûÈÎ˜şXXŞizhHşK˜y¨NK©.ij^Xk.z¨¢wV&BÆWB÷W&F–öäÆV6RÒv—B7V—&T÷W&F–öâ‚ç&W6WGF–æu—&–ær’VÇ6R²&WGW&âfÇ6RĞ¢FVfW"²&VÆV6T÷W&F–öâ†÷W&F–öäÆV6R’Ğ ¢òòK¨ÎjÊj8iú^ûÈÎ™‹.jÚ.z¹îhiÚK»`¢wV&Bf–ÆTÖævW"æFVfVÇBæf–ÆTW†—7G2†EFƒ¢–æ&÷…U$ÂçF‚’VÇ6R°¢&WGW&âfÇ6P¢Ğ ¢Fò°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&Ræ–×÷'Df–ÆR†C¢–æ&÷…U$Â¢v—B–ç7FÆÄ6†ææVÃòç&W6WB‚¢F–væ÷7F–57FFRÒæ–FÆP¢–ç7FÆÄF–væ÷7F–72ÒæV×G¢G'“òf–ÆTÖævW"æFVfVÇBç&VÖ÷fT—FVÒ†C¢–æ&÷…U$Â¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÖW76vS¢%Â…6VÆbç—&–æt76—7FçE6÷W&6R[{.ˆz®XªXiXZ^˜XŞZûKúhşûÈÎzØ[è^yÉşZéîŠëîZH~‹ùîhê^š¨ÎŠø ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢v—BfÆ–FFT–×÷'FVE—&–æuv†VåGVææVÄf–Æ&ÆR€¢7V66W74ÖW76vS¢$Æö6ÄFWeeâ˜	®˜>jÚ>[‹ûÈ™È‹ùîhêRv’ÔfûÈ’"À¢v—F–ætÖW76vS¢.˜XŞZûKúhş[{.ZûÎXZ^ûÈÎzØ[èRÆö6ÄFWeeâ‹ùîhê^Yîš¨ÎŠø ¢¢&WGW&âG'VP¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢G'“òf–ÆTÖævW"æFVfVÇBç&VÖ÷fT—FVÒ†C¢–æ&÷…U$Â¢ÆW'Df–ÇW&RÒf–ÇW&P¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÆWfVÃ¢æW'&÷"À¢ÖW76vS¢%Â…6VÆbç—&–æt76—7FçE6÷W&6RXiXZ^y¨N˜XŞZûKúhşizk9^ZûÎXZR"À¢6öFS¢f–ÇW&Ræ6öFP¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&âfÇ6P¢Ò6F6‚°¢G'“òf–ÆTÖævW"æFVfVÇBç&VÖ÷fT—FVÒ†C¢–æ&÷…U$Â¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^hê^iKn˜XŞZûKúhò"À¢&V6öã¢%6VÂ˜XŞZûXªh˜¾[{.Xù˜i[hÚîûÈÎKØniÊÎiË®izk9^Šû¾Xùn8""À¢&V6÷fW'“¢.˜xŞik˜XŞZû’"À¢6öFS¢%4TÂÕ•"Ó#r ¢¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÆWfVÃ¢æW'&÷"À¢ÖW76vS¢%Â…6VÆbç—&–æt76—7FçE6÷W&6RXiXZ^y¨N˜XŞZûKúhşŠû¾XùnZK‹JR"À¢6öFS¢%4TÂÕ•"Ó#v ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&âfÇ6P¢Ğ¢Ğ ¢òòò”õ2#r²7F'G2&VÖ÷FR—&–æröâF†R†öæR—G6VÆbâF†R†÷7BöæÇ’7&VFW0¢òòò6æF–FFR7&VFVçF–Ã²F†Ræ÷&ÖÂ6†ææVÂF–væ÷7F–27F–ÆÂFV6–FW0¢òòòv†WF†W"—B&V6öÖW2F†RfW&–f–VB—&–ærW6VB'’–ç7FÆÂæB&VæWvÂà¢gVæ27F'E†öæU—&–ær‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒ[ÈZx¾h˜¾iË®˜XŞZû’"¢wV&B†öæU—&–æu&W6VçFF–öåöÆ–7’€¢Ö¦÷$õ5fW'6–öã¢&ö6W74–æfòç&ö6W74–æfòæ÷W&F–æu7—7FVÕfW'6–öâæÖ¦÷%fW'6–öà¢’çW6W5†öæU—&–ærVÇ6R°¢&WGW&à¢Ğ¢wV&B—&–æu7F÷&RÒæ–ÂÂ–ç7FÆÄ6†ææVÂÒæ–ÂVÇ6R°¢ÆWBf–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.˜XŞZûiÈŞXªiÊ®[{º¢"À¢&V6öã¢%6VÂy¨NŠëîZH~˜XŞZûX©şˆ;Ş‹ùk*XxnZH~Z[Ş8""À¢&V6÷fW'“¢.˜xŞikh™>[È6VÂYî˜xŞŠùR"À¢6öFS¢%4TÂÕ•"Ó#R ¢¢†öæU—&–æu7FFRÒæf–ÆVB†f–ÇW&R¢ÆW'Df–ÇW&RÒf–ÇW&P¢&WGW&à¢Ğ¢wV&B†öæU—&–æt†÷7BÓÒæ–ÂVÇ6R°¢&WGW&à¢Ğ¢wV&BÆWB÷W&F–öäÆV6RÒv—B7V—&T÷W&F–öâ‚ç&W6WGF–æu—&–ær’VÇ6R°¢ÆWBf–ÇW&RÒ÷W&F–öä6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢ç&W6WGF–æu—&–ær¢†öæU—&–æu7FFRÒæf–ÆVB†f–ÇW&R¢ÆW'Df–ÇW&RÒf–ÇW&P¢&WGW&à¢Ğ ¢†öæU—&–ætÆV6RÒ÷W&F–öäÆV6P¢ÆWB†÷7BÒ†öæU—&–æt†÷7B‚¢†öæU—&–æt†÷7BÒ†÷7@¢†÷7Bç7F'B²·vV²6VÆeÒWfVçB–à¢6VÆcòæ†æFÆU†öæU—&–ætWfVçB†WfVçB¢Ğ¢Ğ ¢gVæ2fÆ–FFU†öæU—&–ær‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒš¨ÎŠøh˜¾iË®˜XŞZû’"¢wV&B—&–æu&V6÷&BÒæ–ÂVÇ6R°¢v—B7F'E†öæU—&–ær‚¢&WGW&à¢Ğ¢†öæU—&–æu7FFRÒçfÆ–FF–æp¢v—BFW7E—&–æt6öææV7F–öâ‚¢†öæU—&–æu7FFRÒ6VÆbç†öæU—&–æu7FFTgFW$WFöÖF–46†V6²€¢F–væ÷7F–57FFS¢F–væ÷7F–57FFP¢¢Ğ ¢&—fFRgVæ2†æFÆU†öæU—&–ætWfVçB…òWfVçC¢†öæU—&–æt†÷7BäWfVçB’°¢7v—F6‚WfVçB°¢66Rç&WVW7F–ætÆö6ÄæWGv÷&³ ¢†öæU—&–æu7FFRÒç&WVW7F–ætÆö6ÄæWGv÷&°¢66Rçv—F–ætf÷%7—7FVÔ6öæf—&ÖF–öã ¢†öæU—&–æu7FFRÒçv—F–ætf÷%7—7FVÔ6öæf—&ÖF–öà¢66RÆWBç6†÷v–æt6öFR†6öFR“ ¢†öæU—&–æu7FFRÒç6†÷v–æt6öFR†6öFR¢66RÆWBæ6ö×ÆWFVB†f–ÆUU$Â“ ¢†öæU—&–æt†÷7BÒæ–À¢F6²²v—Bf–æ—6…†öæU—&–ær†C¢f–ÆUU$Â’Ğ¢66RÆWBæf–ÆVB†ÖW76vR“ ¢†öæU—&–æt†÷7BÒæ–À¢ÆWBf–ÇW&RÒ6VÆbç†öæU—&–æt†÷7Df–ÇW&R†ÖW76vS¢ÖW76vR¢†öæU—&–æu7FFRÒæf–ÆVB†f–ÇW&R¢ÆW'Df–ÇW&RÒf–ÇW&P¢&VÆV6U†öæU—&–ætÆV6R‚¢Ğ¢Ğ ¢&—fFRgVæ2f–æ—6…†öæU—&–ær†Bf–ÆUU$Ã¢U$Â’7–æ2°¢FVfW"²&VÆV6U†öæU—&–ætÆV6R‚’Ğ¢wV&BÆWB—&–æu7F÷&RVÇ6R²&WGW&âĞ¢Fò°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&Ræ–×÷'Df–ÆR†C¢f–ÆUU$Â¢v—B–ç7FÆÄ6†ææVÃòç&W6WB‚¢–ç7FÆÄF–væ÷7F–72ÒæV×G¢†öæU—&–æu7FFRÒçfÆ–FF–æp¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÖW76vS¢.[{.YÊ{;¾{¹şŠëî{ÚîZèÎh‰Kˆâ6VÂy¨NŠëîZH~˜XŞZûûÈÎ[ÈZx¾š¨ÎŠøÆö6ÄFWeeâ˜	®˜2 ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚ ¢wV&Bv—B—&–æuGVææVÅ&ö&Rç&ö&UGVææVÂ‚’VÇ6R°¢F–væ÷7F–57FFRÒæ–FÆP¢†öæU—&–æu7FFRÒçv—F–ætf÷$Æö6ÄFWeeà¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÖW76vS¢.ŠëîZH~˜XŞZûKúhş[{.KùŞZÙûÈÎzØ[èRÆö6ÄFWeeâ‹ùîhê^Yîš¨ÎŠø ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&à¢Ğ ¢v—B'Vä–ç7FÆÄ6†ææVÄ6†V6²‡7V66W74ÖW76vS¢.ŠëîZH~˜XŞZûY(ÂÆö6ÄFWeeâš¨ÎŠøZèÎh‰"¢†öæU—&–æu7FFRÒ6VÆbç†öæU—&–æu7FFTgFW$WFöÖF–46†V6²€¢F–væ÷7F–57FFS¢F–væ÷7F–57FFP¢¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢†öæU—&–æu7FFRÒæf–ÆVB†f–ÇW&R¢ÆW'Df–ÇW&RÒf–ÇW&P¢Ò6F6‚°¢ÆWBf–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^KùŞZÙ˜XŞZûKúhò"À¢&V6öã¢.{;¾{¹ş[{.ZèÎh‰ŠëîZH~˜XŞZûûÈÎKØb6VÂizk9^ZèXZKùŞZÙXzŞhÚî8""À¢&V6÷fW'“¢.˜xŞik˜XŞZû’"À¢6öFS¢%4TÂÕ•"Ó#b ¢¢†öæU—&–æu7FFRÒæf–ÆVB†f–ÇW&R¢ÆW'Df–ÇW&RÒf–ÇW&P¢Ğ¢Ğ ¢&—fFRgVæ2&VÆV6U†öæU—&–ætÆV6R‚’°¢wV&BÆWB†öæU—&–ætÆV6RVÇ6R²&WGW&âĞ¢6VÆbç†öæU—&–ætÆV6RÒæ–À¢&VÆV6T÷W&F–öâ‡†öæU—&–ætÆV6R¢Ğ ¢&—fFR7FF–2gVæ2†öæU—&–æt†÷7Df–ÇW&R†ÖW76vS¢7G&–ær’Óâ–×÷'Df–ÇW&R°¢ÆWBæ÷&ÖÆ—¦VBÒÖW76vRæÆ÷vW&66VB‚¢–bæ÷&ÖÆ—¦VBæ6öçF–ç2‚'W&Ö—76–öâ"’ÇÂæ÷&ÖÆ—¦VBæ6öçF–ç2‚&æWGv÷&²"’°¢&WGW&âf–ÇW&R€¢F—FÆS¢.iÊ®XXŠëiÊÎYË{Ù{¹Â"À¢&V6öã¢%6VÂizk9^YÊiÊÎiË®Y
şXªŠëîZH~˜XŞZû8""À¢&V6÷fW'“¢.YÊ{;¾{¹şŠëî{ÚîKŠŞXXŠë‚6VÂKÛşyJiÊÎYË{Ù{¹ÎYî˜xŞŠùR"À¢6öFS¢%4TÂÕ•"Ó#r ¢¢Ğ¢&WGW&âf–ÇW&R€¢F—FÆS¢.iÊ®ZèÎh‰ŠëîZH~˜XŞZû’"À¢&V6öã¢.{;¾{¹şiÊ®ZèÎh‰Kˆâ6VÂy¨N˜XŞZûzîŠêN8""À¢&V6÷fW'“¢.YÊ[ÈXùˆ^jŠ[ÈşKŠŞ˜hº’6VÎûÈÎZèÎh‰zîŠêNYî˜xŞŠùR"À¢6öFS¢%4TÂÕ•"Ó#‚ ¢¢Ğ ¢òòòh˜¾XªZûÎXZ^yJh‹~˜hºy¨N˜XŞZûih~K»n8 ¢òòòiJşhÈ”õ2r²&VÖ÷FU—&–æ~ûÈ‚æÖö&–ÆVFWf–6W—&–ærò¥4ôîûÈY(Â”õ2rÒÆö6¶F÷vîûÈ‚çÆ—7NûÈ8 ¢F—66&F&ÆU&W7VÇ@¢gVæ2–×÷'E—&–ætf–ÆR†B6÷W&6UU$Ã¢U$Â’7–æ2Óâ&ööÂ°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒZûÎXZ^˜XŞZûih~K»c¢Â‡6÷W&6UU$ÂæÆ7EF„6ö×öæVçB’"¢wV&BÆWB—&–æu7F÷&RVÇ6R²&WGW&âfÇ6RĞ¢wV&BÆWB÷W&F–öäÆV6RÒv—B7V—&T÷W&F–öâ‚ç&W6WGF–æu—&–ær’VÇ6R°¢ÆW'Df–ÇW&RÒ÷W&F–öä6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢ç&W6WGF–æu—&–ær¢&WGW&âfÇ6P¢Ğ¢FVfW"²&VÆV6T÷W&F–öâ†÷W&F–öäÆV6R’Ğ ¢ÆWBF–D66W72Ò6÷W&6UU$Âç7F'D66W76–æu6V7W&—G•66÷VE&W6÷W&6R‚¢FVfW"²–bF–D66W72²6÷W&6UU$Âç7F÷66W76–æu6V7W&—G•66÷VE&W6÷W&6R‚’ÒĞ ¢Fò°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&Ræ–×÷'Df–ÆR†C¢6÷W&6UU$Â¢v—B–ç7FÆÄ6†ææVÃòç&W6WB‚¢F–væ÷7F–57FFRÒæ–FÆP¢–ç7FÆÄF–væ÷7F–72ÒæV×G¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÖW76vS¢.h˜¾XªZûÎXZ^˜XŞZûih~K»nh‰X©şûÈÎzØ[è^yÉşZéîŠëîZH~‹ùîhê^š¨ÎŠø ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢v—BfÆ–FFT–×÷'FVE—&–æuv†VåGVææVÄf–Æ&ÆR€¢7V66W74ÖW76vS¢$Æö6ÄFWeeâ˜	®˜>jÚ>[‹ûÈ™È‹ùîhêRv’ÔfûÈ’"À¢v—F–ætÖW76vS¢.˜XŞZûKúhş[{.ZûÎXZ^ûÈÎzØ[èRÆö6ÄFWeeâ‹ùîhê^Yîš¨ÎŠø ¢¢&WGW&âG'VP¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢ÆW'Df–ÇW&RÒf–ÇW&P¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÆWfVÃ¢æW'&÷"À¢ÖW76vS¢.h˜¾XªZûÎXZ^˜XŞZûih~K»nZK‹JR"À¢6öFS¢f–ÇW&Ræ6öFP¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&âfÇ6P¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^Šû¾Xùn˜XŞZûih~K»b"À¢&V6öã¢.h˜˜ih~K»nizk9^Šû¾Xùnh‰nKˆŞiŠşiÈiXy¨N˜XŞZûih~K»n8""À¢&V6÷fW'“¢.˜xŞik˜hºih~K»b"À¢6öFS¢%4TÂÕ•"Ó#‚ ¢¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÆWfVÃ¢æW'&÷"À¢ÖW76vS¢.h˜¾XªZûÎXZ^˜XŞZûih~K»nŠû¾XùnZK‹JR"À¢6öFS¢%4TÂÕ•"Ó#† ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&âfÇ6P¢Ğ¢Ğ ¢òòòK¸^‹ùNY¹î{¸ş‹ør—&–æu7F÷&RZHŞjy¨NXzŞhÚîi[hÚîûÉ¾‹>yJikKªNyK{;¾{¹şih~K»nKùŞZÙYšûÈÎKˆŞXiXZ^iz^[ù~h‰nš)ŞZInyºî[Ù^8 ¢gVæ2—&–ætf–ÆTFFf÷$W‡÷'B‚’7–æ2ÓâFFò°¢wV&BÆWB—&–æu7F÷&RVÇ6R²&WGW&âæ–ÂĞ¢Fò°¢&WGW&âG'’v—B—&–æu7F÷&RæW‡÷'DFF‚¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢ÆW'Df–ÇW&RÒf–ÇW&P¢&WGW&âæ–À¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^ZûÎX{®˜XŞZûih~K»b"À¢&V6öã¢.iÊÎiË®˜XŞZûih~K»nizk9^Šû¾Xùnh‰nj
š¨ÎiÊ®˜	®‹ø~8""À¢&V6÷fW'“¢.˜xŞikZûÎXZ^˜XŞZûih~K»nYîXhŞŠùR"À¢6öFS¢%4TÂÕ•"Ó#– ¢¢&WGW&âæ–À¢Ğ¢Ğ ¢gVæ2FW7D6öææV7F–öâ‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkX¾Šù^‹ùîhêR"¢v—BÆöB†f÷&6S¢G'VR¢wV&BF–væ÷7F–57FFRÒç'Vææ–ærÂ–ç7FÆÄ6†ææVÂÒæ–ÂVÇ6R²&WGW&âĞ¢wV&B66÷VçG2æ—4V×G’ÓÒfÇ6RÀ¢ÆWB66÷VçD6Æ–VçBÀ¢ÆWB¶W–6†–âÀ¢ÆWB66÷VçE&W÷6—F÷'’VÇ6R°¢F–væ÷7F–57FFRÒæf–ÆVB€¢6VÆbæf–ÇW&R€¢F—FÆS¢.{Ë®[	zÛîYŞ‹JnXûr"À¢&V6öã¢.[	®iÊ®k{¾XªÆR”B"À¢&V6÷fW'“¢.k{¾Xª‹JnXûr"À¢6öFS¢%4TÂÔUD‚ÓFR ¢¢¢&WGW&à¢Ğ¢wV&B—&–æu&V6÷&BÒæ–ÂVÇ6R°¢F–væ÷7F–57FFRÒæf–ÆVB€¢6VÆbæf–ÇW&R€¢F—FÆS¢.ŠëîZH~iÊ®˜XŞZû’"À¢&V6öã¢.[	®iÊ®ZèÎh‰[Ù>X˜ŞŠëîZH~˜XŞZû’"À¢&V6÷fW'“¢.‹ùîhê^ŠëîZHr"À¢6öFS¢%4TÂÕ•"Ó#2 ¢¢¢&WGW&à¢Ğ ¢ÆWB6VÆV7FVBÒ7F—fT66÷Vç@¢óò66÷VçG2æf—'7B‡v†W&S¢²66÷VçDf–Æ&–Æ—G•öÆ–7’æ—56VÆV7F&ÆR‚C’Ò¢óò66÷VçG2æf—'7@¢wV&Bf"66÷VçBÒ6VÆV7FVBVÇ6R²&WGW&âĞ¢–b7F—fT66÷VçD”BÒ66÷VçBæ–B°¢7F—fT66÷VçD”BÒ66÷VçBæ–@¢v—B6–væ–æu&VfW&Væ6U7F÷&Sòç6WD7F—fT66÷VçD”B†66÷VçBæ–B¢Ğ ¢F–væ÷7F–57FFRÒç'Vææ–æp¢Fò°¢wV&BÆWB6V7&WBÒG'’v—B¶W–6†–âæÆöB†66÷VçD”C¢66÷VçBæ–B’VÇ6R°¢v—BW'6—7EfW&–f–6F–öäf–ÇW&R‚æÆö6Ä7&VFVçF–Ç4Ö—76–ærÂf÷#¢66÷VçB¢F‡&÷r6VÆbæf–ÇW&R€¢F—FÆS¢.‹JnXû~™ÈŠhš¨ÎŠø"À¢&V6öã¢.iÊÎiË®k*iÈ[Ù>X˜ÒÆR”By¨Ny›¾[Ù^XzŞhÚî8""À¢&V6÷fW'“¢.˜xŞikš¨ÎŠøÆR”B"À¢6öFS¢%4TÂÔUD‚ÓVR ¢¢Ğ ¢Fò°¢G'’v—B66÷VçD6Æ–VçBçfÆ–FFR†66÷VçC¢66÷VçBÂ6V7&WC¢6V7&WB¢66÷VçBç7FGW2ÒçfW&–f–V@¢66÷VçBçfW&–f–6F–öäf–ÇW&U&V6öâÒæ–À¢66÷VçBæÖ6¶VDVÖ–ÂÒÆT66÷VçD6Æ–VçBæÖ6²‡6V7&WBæVÖ–Â¢66÷VçBæÆ7EfW&–f–VDBÒFFR‚¢G'’v—B66÷VçE&W÷6—F÷'’ç6fR†66÷VçB¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢–bÆWB&V6öâÒÆU6W'f–6Tf–ÇW&UöÆ–7’çfW&–f–6F–öäf–ÇW&U&V6öâ†f÷#¢f–ÇW&R’°¢v—BW'6—7EfW&–f–6F–öäf–ÇW&R‡&V6öâÂf÷#¢66÷VçB¢Ğ¢F‡&÷rf–ÇW&P¢Ò6F6‚°¢–bÆU6W'f–6Tf–ÇW&UöÆ–7’æ—4æWGv÷&´W'&÷"†W'&÷"’°¢F‡&÷rÆU6W'f–6Tf–ÇW&UöÆ–7’ææWGv÷&´f–ÇW&R€¢VæFW&Ç––æs¢W'&÷"À¢÷W&F–öã¢çfÆ–FFT66÷Vç@¢¢Ğ¢F‡&÷r6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^š¨ÎŠøÆR”B"À¢&V6öã¢$ÆRš¨ÎŠø‹ùNY¹îK¨niÊ®yú^™IŠúşûÈÎ‹JnXû~x«nhiÊ®iKXù8""À¢&V6÷fW'“¢.zˆŞYî˜xŞŠù^ûÉ¾Zh.hÈ{ºŞZK‹J^XhŞ˜xŞikš¨ÎŠøÆR”B"À¢6öFS¢%4TÂÕdU$”e’ÓS ¢¢Ğ ¢v—B&Vg&W6„6W'F–f–6FT–çfVçF÷'’†f÷#¢66÷VçBÂf÷&6S¢G'VR¢–bÆWBf–ÇW&RÒ6W'F–f–6FT–çfVçF÷'”f–ÇW&W5¶66÷VçBæ–EÒ°¢F‡&÷rf–ÇW&P¢Ğ¢v—B'Vä–ç7FÆÄ6†ææVÄ6†V6²‡7V66W74ÖW76vS¢.zÛîYŞxêşZ(>j8kX¾jÚ>[‹‚"¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢v—Bf–æ—6„–ç7FÆÄ6†ææVÄ6†V6µv—F„f–ÇW&R€¢f–ÇW&RÀ¢ÆötÖW76vS¢.zÛîYŞxêşZ(>j8kX¾ZK‹JR ¢¢Ò6F6‚°¢v—Bf–æ—6„–ç7FÆÄ6†ææVÄ6†V6µv—F„f–ÇW&R€¢6VÆbæÆö6ÄFWeeåVæf–Æ&ÆTf–ÇW&RÀ¢ÆötÖW76vS¢.zÛîYŞxêşZ(>j8kX¾ZK‹JR ¢¢Ğ¢Ğ ¢òòòXú®j8iú^˜XŞZû’µeâ´Ö–æ–×W†W.ûÈÎKˆŞ™ÈŠhÆR”B‹JnXûp¢gVæ2FW7E—&–æt6öææV7F–öâ‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkX¾Šù^˜XŞZû‹ùîhêR"¢v—BÆöB†f÷&6S¢G'VR¢wV&B–ç7FÆÄ6†ææVÂÒæ–ÂVÇ6R°¢F–væ÷7F–57FFRÒæf–ÆVB€¢6VÆbæf–ÇW&R€¢F—FÆS¢.ŠëîZH~‹ùîhê^iÊ®[{º¢"À¢&V6öã¢$Æö6ÄFWeeâiÊ®Y
şXªh‰niÊ®ZèŠ8^8.Šû~XX‹ùîhêRv’Ôf’[›nh™>[ÈÆö6ÄFWeeî8""À¢&V6÷fW'“¢.h™>[ÈÆö6ÄFWeeâYî˜xŞikj8kX²"À¢6öFS¢%4TÂÕ•"Ó#B ¢¢¢&WGW&à¢Ğ¢wV&B—&–æu&V6÷&BÒæ–ÂVÇ6R°¢F–væ÷7F–57FFRÒæf–ÆVB€¢6VÆbæf–ÇW&R€¢F—FÆS¢.ŠëîZH~iÊ®˜XŞZû’"À¢&V6öã¢.[	®iÊ®ZèÎh‰[Ù>X˜ŞŠëîZH~˜XŞZû’"À¢&V6÷fW'“¢.‹ùîhê^ŠëîZHr"À¢6öFS¢%4TÂÕ•"Ó#2 ¢¢¢&WGW&à¢Ğ¢òò[Ë®X‹n˜xŞ{Úîx«nhûÈÎzîKùŞjøşjÊx+X{¾˜;Şˆ;Ş˜xŞikš¨ÎŠøûÈ˜şXXŞZK‹J^YîXÚKØşûÈ¢F–væ÷7F–57FFRÒæ–FÆP¢–ç7FÆÄF–væ÷7F–72ÒæV×G¢v—B–ç7FÆÄ6†ææVÃòç&W6WB‚¢v—B'Vä–ç7FÆÄ6†ææVÄ6†V6²‡7V66W74ÖW76vS¢.ŠëîZH~‹ùîhê^jÚ>[‹‚"¢Ğ ¢&—fFRgVæ2W'6—7EfW&–f–6F–öäf–ÇW&R€¢ò&V6öã¢66÷VçEfW&–f–6F–öäf–ÇW&U&V6öâÀ¢f÷"66÷VçC¢ÆT66÷VçE&V6÷&@¢’7–æ2°¢wV&BÆWB66÷VçE&W÷6—F÷'’VÇ6R²&WGW&âĞ¢f"WFFVBÒ66÷Vç@¢WFFVBç7FGW2ÒææVVG5fW&–f–6F–öà¢WFFVBçfW&–f–6F–öäf–ÇW&U&V6öâÒ&V6öà¢G'“òv—B66÷VçE&W÷6—F÷'’ç6fR‡WFFVB¢Ğ ¢&—fFRgVæ2&W—$ÆVv7”66÷VçE7FGW6W2€¢ò&V6÷&G3¢´ÆT66÷VçE&V6÷&EĞ¢’7–æ2F‡&÷w2Óâ´ÆT66÷VçE&V6÷&EÒ°¢wV&BÆWB66÷VçE&W÷6—F÷'’ÂÆWB¶W–6†–âVÇ6R²&WGW&â&V6÷&G2Ğ¢f"&W—&VBÒ&V6÷&G0¢f÷"–æFW‚–â&W—&VBæ–æF–6W2v†W&R&W—&VE¶–æFW…Òç7FGW2ÓÒææVVG5fW&–f–6F–öâ°¢ÆWB†4Æö6Å6V7&WBÒG'’v—B¶W–6†–âæÆöB†66÷VçD”C¢&W—&VE¶–æFW…Òæ–B’Òæ–À¢ÆWB7FGW2Ò66÷VçDf–Æ&–Æ—G•öÆ–7’ç&W—&VE7FGW2€¢f÷#¢&W—&VE¶–æFW…ÒÀ¢†4Æö6Å6V7&WC¢†4Æö6Å6V7&W@¢¢wV&B7FGW2Ò&W—&VE¶–æFW…Òç7FGW2VÇ6R²6öçF–çVRĞ¢&W—&VE¶–æFW…Òç7FGW2Ò7FGW0¢G'’v—B66÷VçE&W÷6—F÷'’ç6fR‡&W—&VE¶–æFW…Ò¢Ğ¢&WGW&â&W—&V@¢Ğ ¢gVæ2FW7DÆö6ÄFWeeâ‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkX¾ŠùRÆö6ÄFWeeâ"¢v—BÆöB†f÷&6S¢G'VR¢wV&BF–væ÷7F–57FFRÒç'Vææ–ærÂ–ç7FÆÄ6†ææVÂÒæ–ÂVÇ6R²&WGW&âĞ¢wV&B—&–æu&V6÷&BÒæ–ÂVÇ6R°¢F–væ÷7F–57FFRÒæf–ÆVB€¢6VÆbæf–ÇW&R€¢F—FÆS¢.ŠëîZH~iÊ®˜XŞZû’"À¢&V6öã¢.j8kX¾‹ùîhê^X˜Ş™ÈŠhXXZèÎh‰[Ù>X˜ŞŠëîZH~˜XŞZû’"À¢&V6÷fW'“¢.‹ùîhê^ŠëîZHr"À¢6öFS¢%4TÂÕ•"Ó#6 ¢¢¢&WGW&à¢Ğ¢v—B'Vä–ç7FÆÄ6†ææVÄ6†V6²‡7V66W74ÖW76vS¢$Æö6ÄFWeeâjÚ>[‹‚"¢òòeâY¹î‹>Y(ÎŠëî{Úîš^ˆz®Xªhê.kX¾˜;Ş‹[‹ù˜xÎûÉ¾y»Nhê^hê‹ù²”õ2#r˜XŞZû™‹një^ûÈÀ¢òòKˆŞˆ;ŞKéŞ‹YnzˆŞYîy¨NY
şXªj8iú^h˜ŞŠêyXÎ™Ú.K¸î(	Î[è^‹ùîhê^(	ŞXùK‹®(	ÎZèÎh‰(	Ş8 ¢–b†öæU—&–æu&W6VçFF–öåöÆ–7’€¢Ö¦÷$õ5fW'6–öã¢&ö6W74–æfòç&ö6W74–æfòæ÷W&F–æu7—7FVÕfW'6–öâæÖ¦÷%fW'6–öà¢’çW6W5†öæU—&–ær°¢†öæU—&–æu7FFRÒ6VÆbç†öæU—&–æu7FFTgFW$WFöÖF–46†V6²€¢F–væ÷7F–57FFS¢F–væ÷7F–57FFP¢¢Ğ¢Ğ ¢&—fFRgVæ2fÆ–FFT–×÷'FVE—&–æuv†VåGVææVÄf–Æ&ÆR€¢7V66W74ÖW76vS¢7G&–ærÀ¢v—F–ætÖW76vS¢7G&–æp¢’7–æ2°¢ÆWBGVææVÅ&V6†&ÆRÒv—B—&–æuGVææVÅ&ö&Rç&ö&UGVææVÂ‚¢wV&B—&–æufÆ–FF–öå7F'EöÆ–7’ç6†÷VÆE7F'DWFöÖF–6ÆÇ’€¢GVææVÅ&V6†&ÆS¢GVææVÅ&V6†&ÆP¢’VÇ6R°¢F–væ÷7F–57FFRÒæ–FÆP¢–ç7FÆÄF–væ÷7F–72ÒæV×G¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç—&–ærÂÖW76vS¢v—F–ætÖW76vR¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&à¢Ğ¢v—B'Vä–ç7FÆÄ6†ææVÄ6†V6²‡7V66W74ÖW76vS¢7V66W74ÖW76vR¢Ğ ¢&—fFRgVæ2'Vä–ç7FÆÄ6†ææVÄ6†V6²‡7V66W74ÖW76vS¢7G&–ær’7–æ2°¢wV&BÆWB–ç7FÆÄ6†ææVÂVÇ6R²&WGW&âĞ¢F–væ÷7F–57FFRÒç'Vææ–æp¢–bÆWB—&–æu7F÷&RÂ—&–æu&V6÷&BÒæ–Â°¢Fò°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&RæÖ&µfÆ–FF–ær‚¢Ò6F6‚°¢ÆWBf–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.˜XŞZûš¨ÎŠøZK‹JR"À¢&V6öã¢.izk9^KùŞZÙŠëîZH~˜XŞZûy¨Nš¨ÎŠø{¹>iéÎ8""À¢&V6÷fW'“¢.˜xŞik˜XŞZûŠëîZHr"À¢6öFS¢%4TÂÕ•"Ó#b ¢¢F–væ÷7F–57FFRÒæf–ÆVB†f–ÇW&R¢ÆW'Df–ÇW&RÒf–ÇW&P¢&WGW&à¢Ğ¢Ğ¢ÆWBF–væ÷7F–72Òv—B–ç7FÆÄ6†ææVÂæF–væ÷6R‚¢–ç7FÆÄF–væ÷7F–72ÒF–væ÷7F–70¢–bF–væ÷7F–72æ—5&VG’ÂÆWBFWf–6T–FVçF–f–W"ÒF–væ÷7F–72æFWf–6T–FVçF–f–W"°¢–bÆWB—&–æu7F÷&R°¢Fò°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&RæÖ&µfÆ–FFVB€¢FWf–6T–FVçF–f–W#¢FWf–6T–FVçF–f–W ¢¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢v—Bf–æ—6„–ç7FÆÄ6†ææVÄ6†V6µv—F„f–ÇW&R€¢f–ÇW&RÀ¢F–væ÷7F–73¢F–væ÷7F–72À¢ÆötÖW76vS¢.ŠëîZH~˜XŞZûj
š¨ÎZK‹JR ¢¢&WGW&à¢Ò6F6‚°¢v—Bf–æ—6„–ç7FÆÄ6†ææVÄ6†V6µv—F„f–ÇW&R€¢6VÆbæf–ÇW&R€¢F—FÆS¢.˜XŞZûš¨ÎŠøZK‹JR"À¢&V6öã¢.izk9^KùŞZÙ[Ù>X˜ŞŠëîZH~y¨N˜XŞZûš¨ÎŠø{¹>iéÎ8""À¢&V6÷fW'“¢.˜xŞik˜XŞZûŠëîZHr"À¢6öFS¢%4TÂÕ•"Ó#v" ¢’À¢F–væ÷7F–73¢F–væ÷7F–72À¢ÆötÖW76vS¢.ŠëîZH~˜XŞZûj
š¨ÎZK‹JR ¢¢&WGW&à¢Ğ¢Ğ¢F–væ÷7F–57FFRÒç&VG’†FWf–6T–FVçF–f–W#¢FWf–6T–FVçF–f–W"¢v—BÆöB†f÷&6S¢G'VR¢–ç7FÆÄF–væ÷7F–72ÒF–væ÷7F–70¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢æ–ç7FÆÆF–öâÀ¢ÖW76vS¢7V66W74ÖW76vP¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&à¢Ğ¢v—Bf–æ—6„–ç7FÆÄ6†ææVÄ6†V6µv—F„f–ÇW&R€¢F–væ÷7F–72æf–ÇW&Róò6VÆbæÆö6ÄFWeeåVæf–Æ&ÆTf–ÇW&RÀ¢F–væ÷7F–73¢F–væ÷7F–72À¢ÆötÖW76vS¢$Æö6ÄFWeeâj8kX¾ZK‹JR ¢¢Ğ ¢&—fFR7FF–2gVæ26†÷VÆE&öÆÆ&6µ—&–ær†gFW"f–ÇW&S¢–×÷'Df–ÇW&R’Óâ&ööÂ°¢²%4TÂÕ•"Ó#R"Â%4TÂÕ•"Ó#b"Â%4TÂÔ”å5DÄÂÓs2%Òæ6öçF–ç2†f–ÇW&Ræ6öFR¢Ğ ¢&—fFRgVæ2f–æ—6„–ç7FÆÄ6†ææVÄ6†V6µv—F„f–ÇW&R€¢òf–ÇW&S¢–×÷'Df–ÇW&RÀ¢F–væ÷7F–73¢–ç7FÆÄ6†ææVÄF–væ÷7F–73òÒæ–ÂÀ¢ÆötÖW76vS¢7G&–æp¢’7–æ2°¢f"VffV7F—fTf–ÇW&RÒf–ÇW&P¢f"VffV7F—fTF–væ÷7F–72ÒF–væ÷7F–70¢–b6VÆbç6†÷VÆE&öÆÆ&6µ—&–ær†gFW#¢f–ÇW&R’ÂÆWB—&–æu7F÷&R°¢Fò°¢–bÆWB&W7F÷&VBÒG'’v—B—&–æu7F÷&Rç&W7F÷&T&6·W–e&W6VçB‚’°¢—&–æu&V6÷&BÒ&W7F÷&V@¢v—B–ç7FÆÄ6†ææVÃòç&W6WB‚¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÖW76vS¢.ik˜XŞZûKúhşš¨ÎŠøZK‹J^ûÈÎ[{.ˆz®Xªh.ZHŞKˆ®KˆK»ŞXúşyJ˜XŞZûKúhò ¢¢–bÆWB–ç7FÆÄ6†ææVÂ°¢ÆWB&V6÷fW'”F–væ÷7F–72Òv—B–ç7FÆÄ6†ææVÂæF–væ÷6R‚¢VffV7F—fTF–væ÷7F–72Ò&V6÷fW'”F–væ÷7F–70¢–b&V6÷fW'”F–væ÷7F–72æ—5&VG’À¢ÆWBFWf–6T–FVçF–f–W"Ò&V6÷fW'”F–væ÷7F–72æFWf–6T–FVçF–f–W"°¢Fò°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&RæÖ&µfÆ–FFVB€¢FWf–6T–FVçF–f–W#¢FWf–6T–FVçF–f–W ¢¢F–væ÷7F–57FFRÒç&VG’†FWf–6T–FVçF–f–W#¢FWf–6T–FVçF–f–W"¢–ç7FÆÄF–væ÷7F–72Ò&V6÷fW'”F–væ÷7F–70¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç—&–ærÀ¢ÖW76vS¢.Kˆ®KˆK»Ş˜XŞZûKúhş[{.h.ZHŞ[›n˜xŞikš¨ÎŠøh‰X©ò ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢&WGW&à¢Ò6F6‚ÆWB&W7F÷&Tf–ÇW&R2–×÷'Df–ÇW&R°¢VffV7F—fTf–ÇW&RÒ&W7F÷&Tf–ÇW&P¢Ò6F6‚°¢VffV7F—fTf–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.˜XŞZûh.ZHŞš¨ÎŠøZK‹JR"À¢&V6öã¢.Kˆ®KˆK»Ş˜XŞZûKúhş[{.h.ZHŞûÈÎKØnš¨ÎŠø{¹>iéÎizk9^KùŞZÙ8""À¢&V6÷fW'“¢.˜xŞikj8kX²"À¢6öFS¢%4TÂÕ•"Ó# ¢¢Ğ¢ÒVÇ6R–bÆWB&V6÷fW'”f–ÇW&RÒ&V6÷fW'”F–væ÷7F–72æf–ÇW&R°¢VffV7F—fTf–ÇW&RÒ&V6÷fW'”f–ÇW&P¢Ğ¢Ğ¢Ğ¢Ò6F6‚°¢VffV7F—fTf–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.˜XŞZûh.ZHŞZK‹JR"À¢&V6öã¢.ik˜XŞZûKúhşKˆŞXúşyJûÈÎK‰NKˆ®KˆK»Ş˜XŞZûKúhşiÊ®ˆ;Şˆz®Xªh.ZHŞ8""À¢&V6÷fW'“¢.˜xŞik˜XŞZû’"À¢6öFS¢%4TÂÕ•"Ó#’ ¢¢ÆW'Df–ÇW&RÒVffV7F—fTf–ÇW&P¢Ğ¢Ğ¢–bÆWB—&–æu7F÷&R°¢Fò°¢–bÆWBFWf–6T–FVçF–f–W"ÒVffV7F—fTF–væ÷7F–73òæFWf–6T–FVçF–f–W"°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&RæÖ&µfÆ–FFVB€¢FWf–6T–FVçF–f–W#¢FWf–6T–FVçF–f–W ¢¢ÒVÇ6R°¢—&–æu&V6÷&BÒG'’v—B—&–æu7F÷&RæÖ&µVæF–æufÆ–FF–öâ‚¢Ğ¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.˜XŞZûx«nhKùŞZÙZK‹JR"À¢&V6öã¢$Æö6ÄFWeeâj8kX¾ZK‹J^YîûÈÎ˜XŞZûx«nhk*ˆ;ŞKùŞZÙX‹iÊÎiË®8""À¢&V6÷fW'“¢.˜xŞik˜XŞZûŠëîZH~YîXhŞj8kX²"À¢6öFS¢%4TÂÕ•"Ó#†" ¢¢Ğ¢Ğ¢v—BÆöB†f÷&6S¢G'VR¢–bÆWBVffV7F—fTF–væ÷7F–72²–ç7FÆÄF–væ÷7F–72ÒVffV7F—fTF–væ÷7F–72Ğ¢F–væ÷7F–57FFRÒæf–ÆVB†VffV7F—fTf–ÇW&R¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢æ–ç7FÆÆF–öâÀ¢ÆWfVÃ¢æW'&÷"À¢ÖW76vS¢%Â†ÆötÖW76vRûÙÅÂ†VffV7F—fTf–ÇW&RçF—FÆRûÙÅÂ†VffV7F—fTf–ÇW&Rç&V6öâ’"À¢6öFS¢VffV7F—fTf–ÇW&Ræ6öFP¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢Ğ ¢gVæ26WDæ÷F–f–6F–öç4Væ&ÆVB…òVæ&ÆVC¢&ööÂ’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒŠëî{Úî˜	®yú^[ÈX[3¢Â†Væ&ÆVB’"¢wV&BÆWBæ÷F–f–6F–öå66†VGVÆW"À¢ÆWBæ÷F–f–6F–öå&VfW&Væ6W2À¢ÆWB7F÷&RVÇ6R²&WGW&âĞ¢Fò°¢–bVæ&ÆVB°¢ÆWBw&çFVBÒG'’v—Bæ÷F–f–6F–öå66†VGVÆW"ç&WVW7DWF†÷&—¦F–öâ‚¢wV&Bw&çFVBVÇ6R°¢æ÷F–f–6F–öå&VfW&Væ6W2æ—4Væ&ÆVBÒG'VP¢æ÷F–f–6F–öç4Væ&ÆVBÒG'VP¢æ÷F–f–6F–öå7FGW2Òv—Bæ÷F–f–6F–öå66†VGVÆW"ç7FGW2‡6VÄVæ&ÆVC¢G'VR¢F‡&÷r6VÆbæf–ÇW&R€¢F—FÆS¢.˜	®yú^iÊ®[ÈY
ò"À¢&V6öã¢%6VÂXh^hù˜i.[{.[ÈY
şûÈÎKØn{;¾{¹şk*iÈhèK¨˜	®yú^iØ>™™8""À¢&V6÷fW'“¢.X˜Ş[è•†öæ^8ÎŠëî{Úî8Óî8Å6VÎ8Óî8Î˜	®yú^8ŞûÈÎXXŠë˜	®yú^Yî˜xŞŠù^8""À¢6öFS¢%4TÂÔäõD”e’Ó ¢¢Ğ¢Ğ¢æ÷F–f–6F–öå&VfW&Væ6W2æ—4Væ&ÆVBÒVæ&ÆV@¢æ÷F–f–6F–öç4Væ&ÆVBÒVæ&ÆV@¢G'’v—Bæ÷F–f–6F–öå66†VGVÆW"ç&W66†VGVÆR€¢3¢G'’v—B7F÷&RæfWF6„ÆÂ‚’À¢Væ&ÆVC¢Væ&ÆVBÀ¢ÆVD†÷W'3¢&VÖ–æFW$†÷W'0¢¢æ÷F–f–6F–öå7FGW2Òv—Bæ÷F–f–6F–öå66†VGVÆW"ç7FGW2‡6VÄVæ&ÆVC¢Væ&ÆVB¢Ò6F6‚ÆWBf–ÇW&R2–×÷'Df–ÇW&R°¢æ÷F–f–6F–öå7FGW2Òv—Bæ÷F–f–6F–öå66†VGVÆW"ç7FGW2€¢6VÄVæ&ÆVC¢æ÷F–f–6F–öå&VfW&Væ6W2æ—4Væ&ÆVBÀ¢66†VGVÆ–ætf–ÇW&S¢f–ÇW&Rç&V6öà¢¢ÆW'Df–ÇW&RÒf–ÇW&P¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æW'&÷"ÂÖW76vS¢f–ÇW&Rç&V6öâÂ6öFS¢f–ÇW&Ræ6öFR¢Ò6F6‚°¢ÆWBF–væ÷7F–2Òæ÷F–f–6F–öå66†VGVÆ–ætf–ÇW&RæF–væ÷7F–2†f÷#¢W'&÷"¢ÆWBf–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^Šëî{Úîhù˜i""À¢&V6öã¢.hù˜i.iÊ®ˆ;Şi»Nik8""À¢&V6÷fW'“¢.Xë¾{;¾{¹şŠëî{Úîh™>[È˜	®yú^iØ>™™Yî˜xŞŠùR"À¢6öFS¢%4TÂÔäõD”e’Ó& ¢¢æ÷F–f–6F–öå7FGW2Òv—Bæ÷F–f–6F–öå66†VGVÆW"ç7FGW2€¢6VÄVæ&ÆVC¢æ÷F–f–6F–öå&VfW&Væ6W2æ—4Væ&ÆVBÀ¢66†VGVÆ–ætf–ÇW&S¢f–ÇW&Rç&V6öà¢¢ÆW'Df–ÇW&RÒf–ÇW&P¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æW'&÷"ÂÖW76vS¢%4TÂÔäõD”e’Ó&[©^[.Šø®ijŞûÉ¥Â†F–væ÷7F–2’"Â6öFS¢f–ÇW&Ræ6öFR¢Ğ¢Ğ ¢ö&¦2&—fFRgVæ2&Vg&W6„æ÷F–f–6F–öå7FGW4gFW%&VæWvÂ‚’°¢F6²²Ö–ä7F÷"–à¢v—B6VÆbç&Vg&W6„æ÷F–f–6F–öå7FGW2‚¢Ğ¢Ğ ¢òòò‹Û¾˜xşX‹~ik˜	®yú^x«nhûÉ®jøşjÊ‹ù¾š^™Ú.˜;Ş‹>ûÈÎKˆŞXùr†4ÆöFVBZèXÚ¾[ÛY8Ş8 ¢Ö–ä7F÷ ¢gVæ2&Vg&W6„æ÷F–f–6F–öå7FGW2‚’7–æ2°¢òòKŠN™‹një^hùKªNûÉ¢ç6VÅ&VæWvÄ6ö×ÆWFVBYÊ˜xŞhé.ZèÎh‰Yîh˜ŞXùûÈÎy»Nhê^Šû¾[iŠşiky¨NûÈÎKˆŞyJyÚ.zy ¢wV&BÆWBæ÷F–f–6F–öå66†VGVÆW"ÂÆWBæ÷F–f–6F–öå&VfW&Væ6W2VÇ6R²&WGW&âĞ¢æ÷F–f–6F–öå7FGW2Òv—Bæ÷F–f–6F–öå66†VGVÆW"ç7FGW2‡6VÄVæ&ÆVC¢æ÷F–f–6F–öå&VfW&Væ6W2æ—4Væ&ÆVB¢Ğ ¢gVæ2&Vg&W6…7F÷&vUW6vR‚’7–æ2°¢wV&BÆWBf–ÆU7F÷&RVÇ6R°¢7F÷&vUW6vRÒæV×G¢&V6Æ–Ö&ÆU6–væVD•66†T6÷VçBÒ ¢&WGW&à¢Ğ¢Fò°¢ÆWB3¢´&V6÷&EĞ¢–bÆWB7F÷&R°¢2Ò‡G'“òv—B7F÷&RæfWF6„ÆÂ‚’’óòµĞ¢ÒVÇ6R°¢2ÒµĞ¢Ğ¢ÆWB†—7F÷'“¢µ6–væ–æt†—7F÷'•&V6÷&EĞ¢–bÆWB6–væ–æt†—7F÷'•7F÷&R°¢†—7F÷'’Ò‡G'“òv—B6–væ–æt†—7F÷'•7F÷&Rç&V6÷&G2‚’’óòµĞ¢ÒVÇ6R°¢†—7F÷'’ÒµĞ¢Ğ¢7F÷&vUW6vRÒG'’v—Bf–ÆU7F÷&Rç7F÷&vUW6vR†3¢2Â6–væ–æt†—7F÷'“¢†—7F÷'’¢&V6Æ–Ö&ÆU6–væVD•66†T6÷VçBÒ2æ6÷VçB°¢6–væVD•66†T6ÆVçWöÆ–7’æFV6—6–öâ†f÷#¢C’ÓÒç&V6Æ–Ö&ÆP¢Ğ¢Ò6F6‚°¢7F÷&vUW6vRÒæV×G¢&V6Æ–Ö&ÆU6–væVD•66†T6÷VçBÒ ¢Ğ¢Ğ ¢gVæ26ÆV%FV×÷&'”f–ÆW2‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkˆ^ynK‹Ni{n{É>ZÙ‚"¢wV&BÆWBf–ÆU7F÷&RVÇ6R²&WGW&âĞ¢wV&BÆWB÷W&F–öäÆV6RÒv—B7V—&T÷W&F–öâ‚æÖ–çF–æ–æu7F÷&vR’VÇ6R°¢ÆW'Df–ÇW&RÒ÷W&F–öä6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢æÖ–çF–æ–æu7F÷&vR¢&WGW&à¢Ğ¢FVfW"²&VÆV6T÷W&F–öâ†÷W&F–öäÆV6R’Ğ¢Fò°¢v—B&Vg&W6…7F÷&vUW6vR‚¢ÆWBFV×÷&'”&Vf÷&RÒ7F÷&vUW6vRçFV×÷&'¢G'’v—Bf–ÆU7F÷&Ræ6ÆV%FV×÷&'”f–ÆW2‚¢v—B&Vg&W6…7F÷&vUW6vR‚¢7F÷&vTÖ–çFVææ6U7VÖÖ'’Ò7F÷&vTÖ–çFVææ6U7VÖÖ'’çFV×÷&'”66†T6ÆV&VB€¢g&VVD'—FW3¢FV×÷&'”&Vf÷&RÒ7F÷&vUW6vRçFV×÷&'¢¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç7—7FVÒÀ¢ÖW76vS¢.K‹Ni{n{É>ZÙKˆîzÛîYŞ[z^KÙÎXË®[{.kˆ^yb ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^kˆ^yn{É>ZÙ‚"À¢&V6öã¢.K‹Ni{nih~K»nK¸ŞYÊKÛşyJûÈÎizk9^kˆ^yn8""À¢&V6÷fW'“¢.zˆŞYî˜xŞikkˆ^yb"À¢6öFS¢%4TÂÕ5Dõ$tRÓ ¢¢Ğ¢Ğ ¢gVæ26ÆV%VçW6VE7F÷&vTf–ÆW2‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkˆ^yniÊ®KÛşyJih~K»b"¢wV&BÆWBf–ÆU7F÷&RÂÆWB7F÷&RVÇ6R²&WGW&âĞ¢wV&BÆWB÷W&F–öäÆV6RÒv—B7V—&T÷W&F–öâ‚æÖ–çF–æ–æu7F÷&vR’VÇ6R°¢ÆW'Df–ÇW&RÒ÷W&F–öä6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢æÖ–çF–æ–æu7F÷&vR¢&WGW&à¢Ğ¢FVfW"²&VÆV6T÷W&F–öâ†÷W&F–öäÆV6R’Ğ¢Fò°¢v—B&Vg&W6…7F÷&vUW6vR‚¢ÆWB&V6Æ–Ö&ÆT&Vf÷&RÒ7F÷&vUW6vRçFV×÷&'’²7F÷&vUW6vRæ÷'†æV@¢ÆWB2ÒG'’v—B7F÷&RæfWF6„ÆÂ‚¢G'’v—Bf–ÆU7F÷&Ræ6ÆV%FV×÷&'”f–ÆW2‚¢òò‹ù˜xÎiŠşyJh‹~K‹¾Xªkˆ^ynûÈÎK‰Ni[NKŠ®kˆ^yniÉş™{NhÈiÈ’æÖ–çF–æ–æu7F÷&vRzyş{ª`¢òòûÈ„÷W&F–öä6ö÷&F–æF÷"XÙ^j{Ò(y"KˆŞKÉ®iÈ[›nXùZûÎXZ^ik[»®yºî[Ù^ûÈûÈÀ¢òòYºjÚNKˆŞ™ÈŠh8Îik[»®KùŞhªNiÉş8Ş(	N(	NyJh‹~[iŠşŠhz¸¾X‹¾h¨®z›®™{N˜x®iKîX{®iÚ^8 ¢G'’v—Bf–ÆU7F÷&Ræ6ÆV$÷'†æVDf–ÆW2€¢fÆ–D”G3¢6WB†2æÖ…Âæ–B’’À¢Ö–æ–×VÔvS¢ ¢¢v—B&Vg&W6…7F÷&vUW6vR‚¢7F÷&vTÖ–çFVææ6U7VÖÖ'’Ò7F÷&vTÖ–çFVææ6U7VÖÖ'’çVçW6VDf–ÆW46ÆV&VB€¢g&VVD'—FW3¢&V6Æ–Ö&ÆT&Vf÷&RÒ7F÷&vUW6vRçFV×÷&'’Ò7F÷&vUW6vRæ÷'†æV@¢¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç7—7FVÒÀ¢ÖW76vS¢.K‹Ni{n{É>ZÙY(ÎiÊ®KÛşyJih~K»n[{.kˆ^ynûÉ¾zÛîYŞ{É>ZÙ8ÆR”BXzŞhÚîY(ÎŠëîZH~˜XŞZûKúhş[{.KùŞyY’ ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^kˆ^yniÊ®KÛşyJih~K»b"À¢&V6öã¢.˜:Xˆnih~K»nK¸ŞYÊKÛşyJh‰niÊÎYËŠë[Ù^izk9^Šû¾Xùn8""À¢&V6÷fW'“¢.zˆŞYî˜xŞikkˆ^yb"À¢6öFS¢%4TÂÕ5Dõ$tRÓ" ¢¢Ğ¢Ğ ¢òòòkˆ^ynXúşXhŞyIşh‰y¨N[{.zÛîYÒ•8.XéşZx²•8ZèŠ8^Šë[Ù^Y(ÎyJh‹~XşZ[ŞKˆ[è¾KùŞyY8 ¢gVæ26ÆV%7F÷&VE6–væVE6¶vW2‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkˆ^yn[{.zÛîYÒ•"¢wV&BÆWBf–ÆU7F÷&RÂÆWB7F÷&RVÇ6R²&WGW&âĞ¢wV&BÆWB÷W&F–öäÆV6RÒv—B7V—&T÷W&F–öâ‚æÖ–çF–æ–æu7F÷&vR’VÇ6R°¢ÆW'Df–ÇW&RÒ÷W&F–öä6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢æÖ–çF–æ–æu7F÷&vR¢&WGW&à¢Ğ¢FVfW"²&VÆV6T÷W&F–öâ†÷W&F–öäÆV6R’Ğ ¢Fò°¢v—B&Vg&W6…7F÷&vUW6vR‚¢ÆWB6–væVD&Vf÷&RÒ7F÷&vUW6vRç6–væVD•0¢ÆWB&V6÷&G2ÒG'’v—B7F÷&RæfWF6„ÆÂ‚ ¢f÷"&V6÷&B–â&V6÷&G2v†W&R6–væVD•66†T6ÆVçWöÆ–7’æFV6—6–öâ†f÷#¢&V6÷&B’ÓÒç&V6Æ–Ö&ÆR°¢f"6ÆV&VE&V6÷&BÒ&V6÷&@¢6ÆV&VE&V6÷&Bæ6ÆV%6–væVD•66†TÖWFFF‚ ¢òòXX>i[hÚîXú®j~Šë{É>ZÙ{Ë®ZKûÈÎ{¹ŞKˆŞiKXi[{.ZèŠ8^‹ª¾K»Òş{ºŞzÛî‹XNjÎ8 ¢G'’v—B7F÷&Rç6fR†6ÆV&VE&V6÷&B¢Fò°¢G'’v—Bf–ÆU7F÷&Rç&VÖ÷fU6–væVD•66†R†”C¢&V6÷&Bæ–B¢Ò6F6‚°¢òòXŠ™šNiÊ®ZèÎh‰i{nh.ZHŞXéşŠë[Ù^ûÈÎzîKùŞyJh‹~K¸ŞXúşjÚ>[‹ZHŞyJxëiÈzÛîYŞXÈ^8 ¢G'“òv—B7F÷&Rç6fR‡&V6÷&B¢F‡&÷rW'&÷ ¢Ğ¢Ğ ¢v—B&Vg&W6…7F÷&vUW6vR‚¢7F÷&vTÖ–çFVææ6U7VÖÖ'’Ò7F÷&vTÖ–çFVææ6U7VÖÖ'’ç6–væVE6¶vW46ÆV&VB€¢g&VVD'—FW3¢6–væVD&Vf÷&RÒ7F÷&vUW6vRç6–væVD•0¢¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢ç7—7FVÒÀ¢ÖW76vS¢.[{.˜x®iKîXúş˜xŞ[»®ZèŠ8^{É>ZÙûÉ¾XéşZx²•8[{.ZèŠ8^‹ª¾K»Ş8høş‹ûih~K»n8‹JnXû~Y(ÎŠëîZH~˜XŞZûKúhşYØ~[{.KùŞyY’ ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^kˆ^ynzÛîYŞXÈR"À¢&V6öã¢.˜:Xˆn[{.zÛîYÒ•jÚ>YÊKÛşyJh‰niÊÎYËŠë[Ù^izk9^i»Nik8""À¢&V6÷fW'“¢.zˆŞYî˜xŞikkˆ^yb"À¢6öFS¢%4TÂÕ5Dõ$tRÓ2 ¢¢Ğ¢Ğ ¢gVæ26ÆV$•æE6–væ–æt66†R‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkˆ^yb•Y(ÎzÛîYŞ{É>ZÙ‚"¢v—B6ÆV%VçW6VE7F÷&vTf–ÆW2‚¢Ğ ¢òòòÆVv7’’&WF–æVBf÷"6ÆÂ×6—FR6ö×F–&–Æ—G’à¢òòò—G2æÖRæ÷rÖF6†W2F†R&VÂ÷W&F–öã¢&V6Æ–Ò&VvVæW&&ÆR6–væVB•6¶vW2à¢gVæ26ÆV%6–væVD•66†R‚’7–æ2°¢v—B6ÆV%7F÷&VE6–væVE6¶vW2‚¢Ğ ¢gVæ26ÆV$Æöw2‚’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒkˆ^™šNiz^[ùr"¢wV&BÆWBÆöu7F÷&RVÇ6R²&WGW&âĞ¢Fò°¢G'’v—BÆöu7F÷&Ræ6ÆV"‚¢Æöw2ÒµĞ¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^kˆ^yniz^[ùr"À¢&V6öã¢.iz^[ù~ih~K»nK¸ŞYÊKÛşyJûÈÎizk9^kˆ^yn8""À¢&V6÷fW'“¢.zˆŞYî˜xŞikkˆ^yb"À¢6öFS¢%4TÂÔÄôrÓ ¢¢Ğ¢Ğ ¢òòòiz^[ù~š^zØ[èR7F÷"ZèÎh‰XiXZ^Yîh˜Şh™>[ÈXˆnKª¾™Ú.iÛşûÈÎ˜şXXŞšinjÊZûÎX{®Šû¾X‹KˆŞZÙYÊy¨Niz~ih~K»n8 ¢gVæ2ÖFW&–Æ—¦TÆötW‡÷'B‚’7–æ2F‡&÷w2ÓâU$Â°¢wV&BÆWBÆöu7F÷&RVÇ6R°¢F‡&÷r–×÷'Df–ÇW&R€¢F—FÆS¢.izk9^ZûÎX{®iz^[ùr"À¢&V6öã¢.iz^[ù~iÈŞXª[	®iÊ®[{º®8""À¢&V6÷fW'“¢.‹ùNY¹îYîzˆŞX	XhŞŠùR"À¢6öFS¢%4TÂÔÄôrÓ""À¢6öæF—F–öã¢æÆöu6W'f–6UVæf–Æ&ÆRÀ¢7F–öã¢ç&WG'’À¢&WG'”F—7÷6—F–öã¢æÖçVÂÀ¢÷W&F–öã¢æW‡÷'DÆörÀ¢÷&–v–ã¢æÆöu7F÷&P¢¢Ğ¢Fò°¢&WGW&âG'’v—BÆöu7F÷&RæÖFW&–Æ—¦TW‡÷'B‚¢Ò6F6‚°¢F‡&÷r–×÷'Df–ÇW&R€¢F—FÆS¢.izk9^ZûÎX{®iz^[ùr"À¢&V6öã¢.iz^[ù~ih~K»nXiXZ^ZK‹J^ûÉ¥Â†W'&÷"æÆö6Æ—¦VDFW67&—F–öâ’"À¢&V6÷fW'“¢.j8iú^XúşyJZÙX*z›®™{NYî˜xŞŠùR"À¢6öFS¢%4TÂÔÄôrÓ""À¢6öæF—F–öã¢æÆötW‡÷'Df–ÆT–çfÆ–BÀ¢7F–öã¢ç&WG'’À¢&WG'”F—7÷6—F–öã¢æÖçVÂÀ¢÷W&F–öã¢æW‡÷'DÆörÀ¢÷&–v–ã¢æÆöu7F÷&P¢¢Ğ¢Ğ ¢òòòiz^[ù~š^KˆîZûÎX{®X[Kª¾YÎKˆK»Ò7F÷"{É>Xk.ûÈÎˆÎKˆŞiŠşŠhk"Fö7VÖVçG2™YÎX8ş[{.XXKˆjÚ^‰Şy¹8 ¢òòğ¢òòò6VÂÖÆörçG‡FiŠş{¹(	Îih~K»n(	ÔY(ÎXˆnKª¾™Ú.iÛşXxnZH~y¨N™YÎX8şûÉ¾Zè>Š*¾ˆ¨.kXh‰nX‰®kˆ^yni{nKˆŞ[©NXk>Zé ¢òòòXh^ˆ;ŞY
nyÈ¾X‹[{.iÈiz^[ù~8.‹ù˜xÎZx¾{¸KÉXXŠû¾Xùniz^[ù~ZÙX*ûÈÎŠû¾XùnZK‹J^h˜ŞY¹î˜[Ù>X˜ŞXh^ZÙ[ú¾xZ~8 ¢gVæ2ÆöuFW‡Df÷%f–Wv–ær‚’7–æ2Óâ7G&–ær°¢ÆWBFW‡C¢7G&–æp¢–bÆWBÆöu7F÷&RÂÆWBW‡÷'FVBÒG'“òv—BÆöu7F÷&RæW‡÷'EFW‡B‚’°¢FW‡BÒW‡÷'FV@¢ÒVÇ6R°¢FW‡BÒ6VÄÆöuFW‡Df÷&ÖGFW"æW‡÷'EFW‡B†Æöw2¢Ğ¢ÆötW‡÷'EFW‡BÒFW‡@¢&WGW&âFW‡@¢Ğ ¢gVæ2&W6WD6W'F–f–6FR†f÷"66÷VçC¢ÆT66÷VçE&V6÷&B’7–æ2°¢G'“òv—BÆöu7F÷&SòæVæB†6FVv÷'“¢ç7—7FVÒÂÆWfVÃ¢æ–æfòÂÖW76vS¢%µ4TÂÔõÒ˜xŞ{ÚîŠøKšc¢‹JnXûrÂ†66÷VçBæ–BçWV–E7G&–ærç&Vf—‚ƒ‚’’"¢wV&BÆWB66÷VçE&W÷6—F÷'’VÇ6R²&WGW&âĞ¢wV&BÆWB÷W&F–öäÆV6RÒv—B7V—&T÷W&F–öâ‚æÖæv–æt6W'F–f–6FR’VÇ6R°¢ÆW'Df–ÇW&RÒ÷W&F–öä6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢æÖæv–æt6W'F–f–6FR¢&WGW&à¢Ğ¢FVfW"²&VÆV6T÷W&F–öâ†÷W&F–öäÆV6R’Ğ¢f"WFFVBÒ66÷Vç@¢WFFVBæ6W'F–f–6FU6W&–ÄçVÖ&W"Òæ–À¢WFFVBç6VÆV7FVD6W'F–f–6FU6W&–ÄçVÖ&W"Òæ–À¢Fò°¢G'’v—B66÷VçE&W÷6—F÷'’ç6fR‡WFFVB¢G'’v—B¶W–6†–ãòæ6ÆV%6–væ–ætÖFW&–Â†66÷VçD”C¢66÷VçBæ–B¢–çfÆ–FFT6W'F–f–6FT–çfVçF÷'•&Vg&W6‚†f÷#¢66÷VçBæ–B¢6W'F–f–6FT–çfVçF÷&–W5¶66÷VçBæ–EÒÒæ–À¢v—BÆöB†f÷&6S¢G'VR¢G'“òv—BÆöu7F÷&SòæVæB€¢6FVv÷'“¢æ66÷VçBÀ¢ÖW76vS¢.iÊÎYËzÛîYŞŠøKšn{É>ZÙ[{.kˆ^™šNûÈÎKˆ¾jÊzÛîYŞKÉ®˜xŞikyK>Šû~ŠøKšb ¢¢Æöw2Ò‡G'“òv—BÆöu7F÷&SòæVçG&–W2‚’’óòÆöw0¢v—B&Vg&W6„ÆötW‡÷'EFW‡B‚¢Ò6F6‚°¢ÆW'Df–ÇW&RÒ6VÆbæf–ÇW&R€¢F—FÆS¢.izk9^i»NikŠøKšb"À¢&V6öã¢.kˆ^™šNi{ny¨NŠøKšnŠë[Ù^h‰niÊÎiË®{É>ZÙKùŞZÙZK‹J^8""À¢&V6÷fW'“¢.˜xŞikkˆ^™šNûÉ¾K¸ŞZK‹J^Šû~˜xŞikš¨ÎŠøÆR”B"À¢6öFS¢%4TÂÔ4U%BÓ ¢¢Ğ¢Ğ ¢&—fFRgVæ2÷W&F–öä6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢÷W&F–öä6ö÷&F–æF÷"ä¶–æB’Óâ–×÷'Df–ÇW&R°¢÷W&F–öä6ö÷&F–æF÷#òæ6öæfÆ–7Df–ÇW&R‡&WVW7FVC¢&WVW7FVB¢óò6VÆbæf–ÇW&R€¢F—FÆS¢.i¨.i{nizk9^hš~ŠÂ"À¢&V6öã¢.XúnKˆši8ŞKÙÎK¸ŞYÊZèÎh‰ûÈÎK‹®˜şXXŞzÛîYŞ8ŠøKšnh‰nih~K»nx«nhK©.y»Šhny¹nûÈÎ[Ù>X˜Şi8ŞKÙÎ[{.™‹¾jÚ.8""À¢&V6÷fW'“¢.zØ[è^[Ù>X˜Şi8ŞKÙÎZèÎh‰Yî˜xŞŠùR"À¢6öFS¢%4TÂÔõÓ ¢¢Ğ ¢&—fFRgVæ27V—&T÷W&F–öâ€¢ò¶–æC¢÷W&F–öä6ö÷&F–æF÷"ä¶–æBÀ¢”C¢UT”CòÒæ–À¢’7–æ2Óâ÷W&F–öä6ö÷&F–æF÷"äÆV6Sò°¢wV&BÆWB÷W&F–öä6ö÷&F–æF÷"VÇ6R°¢&WGW&âçVæ6ö÷&F–æFVB†¶–æBÂ”C¢”B¢Ğ¢òòˆz®XªzØ[è^[Ù>X˜Şi8ŞKÙÎZèÎh‰ûÈÎKˆŞ[Ë’.i¨.i{nizk9^hš~ŠÂ.[Ëz©p¢&WGW&âv—B÷W&F–öä6ö÷&F–æF÷"æ&Vv–åv—F–ær†¶–æBÂ”C¢”B¢Ğ ¢&—fFRgVæ2&VÆV6T÷W&F–öâ…òÆV6S¢÷W&F–öä6ö÷&F–æF÷"äÆV6R’°¢÷W&F–öä6ö÷&F–æF÷#òæVæB†ÆV6R¢Ğ ¢&—fFRgVæ2&Vg&W6„ÆötW‡÷'EFW‡B‚’7–æ2°¢òÒv—BÆöuFW‡Df÷%f–Wv–ær‚¢Ğ ¢7FF–2gVæ2&Wf–Wr‚’Óâ6WGF–æw5f–WtÖöFVÂ°¢ÆWBÖöFVÂÒ6WGF–æw5f–WtÖöFVÂ‚¢ÖöFVÂæ66÷VçG2Ò°¢ÆT66÷VçE&V6÷&B€¢Ö6¶VDVÖ–Ã¢&B¢¢¤–6Æ÷VBæ6öÒ"À¢66÷VçD–FVçF–f–W#¢'&Wf–WrÖ66÷VçB"À¢FVÔ”C¢%$Ud”UuDTÒ"À¢FVÔæÖS¢.KŠ®K«®Yº.™‰ò"À¢—4g&VUFVÓ¢G'VRÀ¢7FGW3¢çfW&–f–VBÀ¢6W'F–f–6FU6W&–ÄçVÖ&W#¢%$Ud”UrÔ4U%D”d”4DR"À¢6VÆV7FVD6W'F–f–6FU6W&–ÄçVÖ&W#¢%$Ud”UrÔ4U%D”d”4DR"À¢Æ7EfW&–f–VDC¢FFR‚¢¢Ğ¢ÖöFVÂæ7F—fT66÷VçD”BÒÖöFVÂæ66÷VçG2æf—'7Còæ–@¢ÖöFVÂægVÆÄ66÷VçDVÖ–Ç5¶ÖöFVÂæ66÷VçG5³Òæ–EÒÒ&FVÖô–6Æ÷VBæ6öÒ ¢ÖöFVÂç—&–æu&V6÷&BÒ—&–æu&V6÷&B€¢FWf–6T–FVçF–f–W#¢%$Ud”UrÔDUd”4R"À¢—5&VÖ÷FU—&–æs¢G'VP¢¢&WGW&âÖöFVÀ¢Ğ ¢&—fFR7FF–2ÆWBÆö6ÄFWeeåVæf–Æ&ÆTf–ÇW&RÒ–×÷'Df–ÇW&R€¢F—FÆS¢$Æö6ÄFWeeâiÊ®[{º¢"À¢&V6öã¢$Æö6ÄFWeeâiÊ®[{º®8.Šû~XX‹ùîhêRv’Ôf’[›nzîŠêBÆö6ÄFWeeâ[{.‹ùîhê^8""À¢&V6÷fW'“¢.yú^˜>K¨b"À¢6öFS¢%4TÂÔ”å5DÄÂÓsf ¢  ¢&—fFR7FF–2gVæ2f–ÇW&R€¢F—FÆS¢7G&–ærÀ¢&V6öã¢7G&–ærÀ¢&V6÷fW'“¢7G&–ærÀ¢6öFS¢7G&–æp¢’Óâ–×÷'Df–ÇW&R°¢–×÷'Df–ÇW&R€¢F—FÆS¢F—FÆRÀ¢&V6öã¢&V6öâÀ¢&V6÷fW'“¢&V6÷fW'’À¢6öFS¢6öFP¢¢Ğ§Ğ