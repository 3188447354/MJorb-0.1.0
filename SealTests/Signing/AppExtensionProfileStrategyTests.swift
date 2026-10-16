import Testing
@testable import Seal

struct AppExtensionProfileStrategyTests {

    private let originalMain = "com.example.video"
    private let mappedMain = "com.example.video.seal.TEAM123"
    private let mappedShare = "com.example.video.seal.TEAM123.Share"
    private let mappedWidget = "com.example.video.seal.TEAM123.Widget"

    @Test
    func sharedMainProfileOnlySubmitsTheMainAppToApple() {
        let mappings = [
            originalMain: mappedMain,
            "com.example.video.Share": mappedShare,
            "com.example.video.Widget": mappedWidget
        ]

        #expect(
            AppExtensionProfileStrategy.sharedMainProfile.portalMappings(
                from: mappings,
                originalMainBundleID: originalMain
            ) == [originalMain: mappedMain]
        )
    }

    @Test
    func sharedMainProfileValidatesExtensionsAgainstTheMainProfile() {
        #expect(
            AppExtensionProfileStrategy.sharedMainProfile.expectedProfileBundleID(
                for: mappedShare,
                mappedMainBundleID: mappedMain
            ) == mappedMain
        )
    }

    @Test
    func independentProfilesKeepsEveryBundleAsAPortalAndProfileTarget() {
        let mappings = [
            originalMain: mappedMain,
            "com.example.video.Share": mappedShare,
            "com.example.video.Widget": mappedWidget
        ]

        #expect(
            AppExtensionProfileStrategy.independentProfiles.portalMappings(
                from: mappings,
                originalMainBundleID: originalMain
            ) == mappings
        )
        #expect(
            AppExtensionProfileStrategy.independentProfiles.expectedProfileBundleID(
                for: mappedShare,
                mappedMainBundleID: mappedMain
            ) == mappedShare
        )
    }

    @Test
    func onlySealAndLiveContainerUseIndependentProfilesByDefault() {
        #expect(AppExtensionProfileStrategy.defaultFor(isSeal: false, isLiveContainer: false) == .sharedMainProfile)
        #expect(AppExtensionProfileStrategy.defaultFor(isSeal: true, isLiveContainer: false) == .independentProfiles)
        #expect(AppExtensionProfileStrategy.defaultFor(isSeal: false, isLiveContainer: true) == .independentProfiles)
    }

    @Test
    func ordinaryAppWithExtensionsUsesTheSharedDefault() {
        let app = AppRecord(
            originalBundleIdentifier: originalMain,
            name: "Video",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .imported,
            ipaRelativePath: "Video.ipa",
            importedAt: .now,
            extensions: [
                AppExtensionRecord(
                    name: "LiveProcess",
                    originalBundleIdentifier: "com.example.video.LiveProcess"
                )
            ]
        )

        #expect(app.effectiveExtensionProfileStrategy == .sharedMainProfile)
    }

    @Test
    func liveContainerAlwaysUsesIndependentProfilesByDefault() {
        let app = AppRecord(
            originalBundleIdentifier: "com.kdt.livecontainer",
            name: "LiveContainer",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .imported,
            ipaRelativePath: "LiveContainer.ipa",
            importedAt: .now
        )

        #expect(app.effectiveExtensionProfileStrategy == .independentProfiles)
    }

    @Test
    func persistedIndependentStrategyRemainsIndependent() {
        let app = AppRecord(
            originalBundleIdentifier: originalMain,
            name: "Video",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            provisioningProfileUUID: "main-profile",
            ipaRelativePath: "Video.ipa",
            importedAt: .now,
            extensions: [
                AppExtensionRecord(
                    name: "Share",
                    originalBundleIdentifier: "com.example.video.Share",
                    provisioningProfileUUID: "extension-profile"
                )
            ],
            extensionProfileStrategy: .independentProfiles
        )

        #expect(app.effectiveExtensionProfileStrategy == .independentProfiles)
    }

    @Test
    func sharedProfileKeepsTheExtensionAsTheRecordedSigningTarget() {
        let target = SigningTargetRecord(
            binding: ProvisioningProfileBinding(
                bundleIdentifier: mappedMain,
                profileUUID: "shared-profile",
                profileName: "Shared",
                teamIdentifier: "TEAM123",
                creationDate: .now,
                expirationDate: .now.addingTimeInterval(7 * 86_400),
                certificateSerialNumbers: ["1234"],
                deviceIdentifiers: ["device"],
                entitlements: [:]
            ),
            signedBundleIdentifier: mappedShare
        )

        #expect(target.bundleIdentifier == mappedShare)
        #expect(target.profileUUID == "shared-profile")
    }

    @Test
    func sharedProfileBlockerIsNilWhenEveryExtensionEntitlementIsCoveredByTheMainApp() {
        let blocker = AppExtensionProfileStrategy.sharedProfileBlocker(
            mainBundleID: mappedMain,
            entitlementsByBundleID: [
                mappedMain: ["application-identifier", "increased-memory-limit"],
                mappedShare: ["application-identifier"],
                mappedWidget: ["application-identifier", "increased-memory-limit"]
            ]
        )

        #expect(blocker == nil)
    }

    @Test
    func sharedProfileBlockerReportsTheFirstUncoveredExtensionDeterministically() {
        let blocker = AppExtensionProfileStrategy.sharedProfileBlocker(
            mainBundleID: mappedMain,
            entitlementsByBundleID: [
                mappedWidget: ["com.apple.developer.kernel.increased-memory-limit"],
                mappedMain: ["application-identifier"],
                mappedShare: ["com.apple.developer.networking.wifi-info"]
            ]
        )

        // 两个扩展都不被主 App 覆盖 ⇒ 必须稳定地选**字典序最小**的那个，
        // 否则同一份 IPA 的日志会抖、对不上。
        #expect(
            blocker == AppExtensionProfileStrategy.SharedProfileBlocker(
                extensionBundleID: mappedShare,
                entitlements: ["com.apple.developer.networking.wifi-info"]
            )
        )
    }

    @Test
    func sharedProfileBlockerIgnoresExtensionsThatAskForNothingExtra() {
        let blocker = AppExtensionProfileStrategy.sharedProfileBlocker(
            mainBundleID: mappedMain,
            entitlementsByBundleID: [
                mappedMain: [],
                mappedShare: [],
                mappedWidget: []
            ]
        )

        #expect(blocker == nil)
    }

    @Test
    func profileTopologyKeepsUnsupportedExtensionCapabilitiesAsAnIndependentProfileBlocker() {
        // `increased-memory-limit` 不是当前门户 feature API 可提交的开关，但它仍然是
        // IPA 的真实扩展能力。不能因为它不会送进 updateAppId 就把 LiveProcess 错判为
        // 可以共用主描述文件；否则扩展会失去自己的 App ID / profile / App Group 绑定链路。
        let topology = AppExtensionProfileStrategy.profileTopologyEntitlements(from: [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "get-task-allow",
            "com.apple.developer.kernel.increased-memory-limit"
        ])

        #expect(topology == ["com.apple.developer.kernel.increased-memory-limit"])
        #expect(AppExtensionProfileStrategy.sharedProfileBlocker(
            mainBundleID: mappedMain,
            entitlementsByBundleID: [
                mappedMain: [],
                mappedShare: topology
            ]
        )?.extensionBundleID == mappedShare)
    }

    // MARK: - 能力被拒时的请求集清空范围（2026-09-24，构建 30 真机）

    @Test
    func downgradeUnderSharedProfileClearsEveryBundleEmbeddingThatProfile() {
        // 共享模式下门户**只为主 App** 提交能力，而每个扩展嵌入的都是这一份描述文件
        // ⇒ 主 App 被 Apple 拒（3001）时，**所有** bundle 的请求集都要清空。
        // 只清主 App 自己会让扩展的请求集留着 ⇒ 签后逐 bundle 校验必报
        // SEAL-ENTITLEMENT-401（真机：LiveContainer 连续两次装不上，而它的扩展
        // 恰好请求了被拒的 com.apple.developer.kernel.increased-memory-limit）。
        #expect(
            AppExtensionProfileStrategy.affectedBundles(
                whenDowngrading: mappedMain,
                strategy: .sharedMainProfile,
                mappedMainBundleID: mappedMain,
                mappedBundleIdentifiers: [mappedMain, mappedShare, mappedWidget]
            ) == [mappedMain, mappedShare, mappedWidget].sorted()
        )
    }

    @Test
    func downgradeUnderIndependentProfilesTouchesOnlyTheBundleItself() {
        // 独立模式下每个 bundle 有自己的 App ID 与描述文件 ⇒ 降级只影响它自己。
        // 顺手把别人的请求集也清掉，会让那些 bundle 白白丢掉本可授予的能力。
        #expect(
            AppExtensionProfileStrategy.affectedBundles(
                whenDowngrading: mappedShare,
                strategy: .independentProfiles,
                mappedMainBundleID: mappedMain,
                mappedBundleIdentifiers: [mappedMain, mappedShare, mappedWidget]
            ) == [mappedShare]
        )
    }

    @Test
    func downgradeAlwaysIncludesTheBundleThatWasRejected() {
        // 🔴 不变量：无论哪种策略，**被拒的那个 bundle 自己一定在结果里**。
        // 这条防的是「调用方传来的列表漏了它」⇒ 静默退化回原来那个 bug
        // （主 App 反而没被清空、扩展的请求集留着）。
        for strategy in AppExtensionProfileStrategy.allCases {
            let affected = AppExtensionProfileStrategy.affectedBundles(
                whenDowngrading: mappedMain,
                strategy: strategy,
                mappedMainBundleID: mappedMain,
                mappedBundleIdentifiers: [mappedShare, mappedWidget]  // ← 刻意漏掉主 App
            )
            #expect(
                affected.contains(mappedMain),
                "\(strategy) 下被拒的 bundle 必须出现在结果里"
            )
        }
    }

    @Test
    func downgradeResultIsDeduplicatedAndStablySorted() {
        // 映射后 ID 在「扩展 ID 需要哈希缩短」那条路径上理论上存在碰撞面
        // ⇒ 结果必须去重；顺序也要稳定，否则同一份 IPA 的日志会抖、对不上。
        #expect(
            AppExtensionProfileStrategy.affectedBundles(
                whenDowngrading: mappedMain,
                strategy: .sharedMainProfile,
                mappedMainBundleID: mappedMain,
                mappedBundleIdentifiers: [mappedWidget, mappedMain, mappedWidget, mappedShare]
            ) == [mappedMain, mappedShare, mappedWidget]
        )
    }

    @Test
    func downgradeUnderSharedProfileTouchesOnlyTheExtensionWhenItIsNotTheMainApp() {
        // 共享模式下理论上只有主 App 会走门户写入；万一传进来的是扩展，
        // 也必须只清它自己 —— 不能顺手把整份描述文件下所有 bundle 都清掉。
        #expect(
            AppExtensionProfileStrategy.affectedBundles(
                whenDowngrading: mappedShare,
                strategy: .sharedMainProfile,
                mappedMainBundleID: mappedMain,
                mappedBundleIdentifiers: [mappedMain, mappedShare, mappedWidget]
            ) == [mappedShare]
        )
    }
}
