import Foundation

/// 含扩展 IPA 的描述文件分配策略。
///
/// 普通 IPA 默认共享主描述文件；能力不兼容的扩展单独分配。Seal 与 LiveContainer 默认独立。
///
/// 普通 IPA 共享模式下，门户只为主 App 申请一份描述文件；不兼容扩展单独申请，
/// 兼容扩展继续共享，避免无谓消耗 App ID。
///
enum AppExtensionProfileStrategy: String, Codable, CaseIterable, Equatable, Sendable {
    case sharedMainProfile
    case independentProfiles
    case selectiveProfiles

    /// 默认策略。
    static func defaultFor(isSeal: Bool, isLiveContainer: Bool) -> Self {
        isSeal || isLiveContainer ? .independentProfiles : .sharedMainProfile
    }

    /// 为「共用主描述文件是否安全」保留 IPA 的真实能力边界。
    ///
    /// 这不是门户 `updateAppId` 的 feature 请求集：后者只能包含 Apple 当前公开 API
    /// 能提交的开关；这里必须额外看到像 LiveProcess 的 increased-memory-limit 这类原始
    /// entitlement，否则会把需要独立 App ID、profile 和 App Group 关联的扩展误判成共享。
    static func profileTopologyEntitlements(from rawEntitlements: Set<String>) -> Set<String> {
        rawEntitlements.subtracting([
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "get-task-allow"
        ])
    }

    func portalMappings(
        from mappings: [String: String],
        originalMainBundleID: String,
        independentBundleIdentifiers: Set<String> = []
    ) -> [String: String] {
        switch self {
        case .sharedMainProfile:
            guard let mappedMainBundleID = mappings[originalMainBundleID] else { return [:] }
            return [originalMainBundleID: mappedMainBundleID]
        case .independentProfiles:
            return mappings
        case .selectiveProfiles:
            return mappings.filter {
                $0.key == originalMainBundleID || independentBundleIdentifiers.contains($0.value)
            }
        }
    }

    func expectedProfileBundleID(
        for signedBundleID: String,
        mappedMainBundleID: String,
        independentBundleIdentifiers: Set<String> = []
    ) -> String {
        switch self {
        case .sharedMainProfile:
            return mappedMainBundleID
        case .independentProfiles:
            return signedBundleID
        case .selectiveProfiles:
            return independentBundleIdentifiers.contains(signedBundleID) ? signedBundleID : mappedMainBundleID
        }
    }

    /// 共享主描述文件隐含一个前提：**主 App 的能力集 ⊇ 每个保留扩展的能力集**。
    ///
    /// 真机实证（构建 27，`Seal-log(7)(1).txt`）：`LiveProcess` 请求
    /// `com.apple.developer.kernel.increased-memory-limit`，而该能力只声明在扩展上、不在主 App 上
    /// ⇒ 共享模式下门户**只为主 App** 提交能力（`portalMappings` 只有主 App）⇒ 主描述文件不授予它
    /// ⇒ 签后逐 bundle 校验必报 `SEAL-ENTITLEMENT-401`（LiveContainer 连续 5 次签不上）。
    /// ⚠️ 独立模式下不会有这个问题：扩展有自己的 App ID，能力会被提交到它自己那份上。
    /// ⇒ 只要出现这种扩展，就必须回退独立描述文件（否则只能「明确失败」，用户就装不上了）。
    struct SharedProfileBlocker: Equatable, Sendable {
        let extensionBundleID: String
        let entitlements: [String]

        /// 该扩展的**能力读不出来**（而不是「读出来发现它要得更多」）。
        ///
        /// ⚠️ 两种成因必须分开：前者的处置是「保守走独立」，后者是「它确实需要独立」。
        /// 日志里也得分得清，否则真机看到「扩展 X 请求了未声明的能力 」后面是空白，
        /// 根本不知道该去修能力解析还是该接受独立模式。
        ///
        /// 带默认值 ⇒ 既有调用点与单测的 memberwise 初始化不受影响。
        var isUnreadable: Bool = false
    }

    /// 同上，但**期望集合由调用方显式传入**，且 `entitlementsByBundleID` 里**缺失条目按
    /// 「读不到能力」处理 ⇒ 直接判为阻塞**（fail closed）。
    ///
    /// ⚠️ 为什么需要它（2026-10-16 全局共享化时补）：签名链路是按
    /// `mappings.values`（映射后 Bundle ID）去 `applications` 里取能力的，
    /// 取不到就 `continue` **静默跳过** ⇒ 该 bundle 在 `entitlementsByBundleID` 里**根本没有键**。
    /// 上面那个 2 参数版本用 `?? []` 把缺失当空集 ⇒ 差集为空 ⇒ 判「共享安全」。
    ///
    /// **在默认独立时这无所谓；一旦默认改为共享，它就是把 LiveProcess 那个 401 回归
    /// 放回来的入口。** 所以签名链路必须用这个版本：读不到扩展能力时**保守走独立**，
    /// 多花一个 App ID，也好过签出一个扩展拿不到能力的包。
    static func sharedProfileBlocker(
        mainBundleID: String,
        entitlementsByBundleID: [String: Set<String>],
        expectedBundleIdentifiers: [String]
    ) -> SharedProfileBlocker? {
        sharedProfileBlockers(
            mainBundleID: mainBundleID,
            entitlementsByBundleID: entitlementsByBundleID,
            expectedBundleIdentifiers: expectedBundleIdentifiers
        ).first
    }

    static func sharedProfileBlockers(
        mainBundleID: String,
        entitlementsByBundleID: [String: Set<String>],
        expectedBundleIdentifiers: [String]
    ) -> [SharedProfileBlocker] {
        let mainEntitlements = entitlementsByBundleID[mainBundleID] ?? []
        let others = Set(expectedBundleIdentifiers).subtracting([mainBundleID])

        // 先判「读不到」：`nil` 与「真的是空集」必须区分开 —— 前者不能当作安全。
        let unreadable = others
            .filter { entitlementsByBundleID[$0] == nil }
            .sorted()
        let unreadableBlockers = unreadable.map { bundleID in
            SharedProfileBlocker(
                extensionBundleID: bundleID,
                entitlements: [],
                isUnreadable: true
            )
        }

        let blockers = others
            .compactMap { bundleID -> SharedProfileBlocker? in
                guard let entitlements = entitlementsByBundleID[bundleID] else { return nil }
                let extra = entitlements.subtracting(mainEntitlements).sorted()
                guard extra.isEmpty == false else { return nil }
                return SharedProfileBlocker(extensionBundleID: bundleID, entitlements: extra)
            }
            .sorted { $0.extensionBundleID < $1.extensionBundleID }
        return (unreadableBlockers + blockers).sorted {
            $0.extensionBundleID < $1.extensionBundleID
        }
    }

    /// 返回每个不能安全共用主描述文件的扩展。读不到扩展能力时也按独立处理。
    static func independentBundleIdentifiers(
        mainBundleID: String,
        entitlementsByBundleID: [String: Set<String>],
        expectedBundleIdentifiers: [String]
    ) -> Set<String> {
        let mainEntitlements = entitlementsByBundleID[mainBundleID] ?? []
        return Set(expectedBundleIdentifiers.filter { bundleID in
            guard bundleID != mainBundleID,
                  let entitlements = entitlementsByBundleID[bundleID] else { return bundleID != mainBundleID }
            return entitlements.subtracting(mainEntitlements).isEmpty == false
        })
    }

    static func resolvedStrategy(
        mainBundleID: String,
        expectedBundleIdentifiers: [String],
        independentBundleIdentifiers: Set<String>
    ) -> Self {
        let extensionCount = expectedBundleIdentifiers.filter { $0 != mainBundleID }.count
        if independentBundleIdentifiers.isEmpty { return .sharedMainProfile }
        return independentBundleIdentifiers.count == extensionCount ? .independentProfiles : .selectiveProfiles
    }

    /// 返回第一个「请求了主 App 未声明能力」的扩展；没有则 `nil`。
    ///
    /// 结果**稳定排序**（按扩展 Bundle ID 字典序、能力名排序）—— 否则同一份 IPA 的日志会抖，
    /// 对不上（同 R26 那条「主 App 之外的条目仍要按原序稳定排序」）。
    static func sharedProfileBlocker(
        mainBundleID: String,
        entitlementsByBundleID: [String: Set<String>]
    ) -> SharedProfileBlocker? {
        let mainEntitlements = entitlementsByBundleID[mainBundleID] ?? []
        let blockers = entitlementsByBundleID
            .filter { $0.key != mainBundleID }
            .map { ($0.key, $0.value.subtracting(mainEntitlements).sorted()) }
            .filter { $0.1.isEmpty == false }
            .sorted { $0.0 < $1.0 }
        guard let first = blockers.first else { return nil }
        return SharedProfileBlocker(extensionBundleID: first.0, entitlements: first.1)
    }

    /// 把「想要的策略」解析成「本次真正可用的策略」。
    ///
    /// 只可能把 `.sharedMainProfile` 降级成独立或混合分配，永不反向 ——
    /// 反向（独立→共享）会静默丢扩展能力，正是这条要防的。
    ///
    /// - Parameter expectedBundleIdentifiers: 本次签名**应当**存在的映射后 Bundle ID 集合。
    ///   传入时会用 fail-closed 版本判阻塞（读不到某个扩展的能力 ⇒ 保守走独立）；
    ///   传 `nil`（默认）保持原有语义，供纯函数单测使用。
    static func resolvedForSigning(
        requested: Self,
        mainBundleID: String,
        entitlementsByBundleID: [String: Set<String>],
        expectedBundleIdentifiers: [String]? = nil
    ) -> Self {
        guard requested == .sharedMainProfile else { return requested }
        let independent = independentBundleIdentifiers(
            mainBundleID: mainBundleID,
            entitlementsByBundleID: entitlementsByBundleID,
            expectedBundleIdentifiers: expectedBundleIdentifiers ?? Array(entitlementsByBundleID.keys)
        )
        let extensionCount = (expectedBundleIdentifiers ?? Array(entitlementsByBundleID.keys))
            .filter { $0 != mainBundleID }
            .count
        if independent.isEmpty { return .sharedMainProfile }
        return independent.count == extensionCount ? .independentProfiles : .selectiveProfiles
    }

    /// 某个 bundle 的能力被 Apple 拒绝、描述文件降级为空时，**还有哪些 bundle 的请求集必须一并清空**。
    ///
    /// 为什么需要它（2026-09-24 真机，构建 30，LiveContainer 连续两次 `SEAL-ENTITLEMENT-401`）：
    /// 共享模式下门户**只为主 App** 提交能力（`portalMappings` 只留主 App），而签出的**每个扩展
    /// 嵌入的都是这一份主描述文件** ⇒ 主 App 的能力一旦被 Apple 拒（3001 ⇒
    /// `downgradedToEmptyEntitlements`），**所有嵌入它的 bundle 的请求集都必须一起清空** ✗。
    /// 只清主 App 那一份的话，签后逐 bundle 校验会拿「扩展的请求集」去对「什么都不授予的主描述文件」
    /// ⇒ 必报 `SEAL-ENTITLEMENT-401`，把一个**本来能装、能跑的包**拦下
    /// （真机症状就是 LiveContainer 装不上，而抖音因为扩展不依赖被拒的能力照样能签）。
    ///
    /// ⚠️ **这不是「静默降级」** —— 必须与 `RELEASE_NOTES` 那条「不产出表面成功但无法运行的 IPA」对齐着读：
    /// 上游 `SideSign` 的 `CodeSignerAPI.prepare` 以**描述文件授予集**为起点、
    /// 只保留 App 也声明过的键 ⇒ 描述文件没有的能力**根本不会写进 Mach-O**
    /// ⇒ 签出的包**本来就是自洽的**（扩展确实不带那个能力，与描述文件一致）。
    /// 清空请求集只是让 Seal 的**账本**与**实际产物**一致 —— 不清才是错的：
    /// 那是拿一个**比产物更宽**的集合去对账，必然假红。
    ///
    /// ⚠️ 因此也**不要**把这里理解成「把扩展的能力丢掉」：那些能力 Apple 本来就没批，
    /// 独立模式下同样拿不到（它自己的 App ID 也会被 3001 拒）。
    /// 想真正拿到它们，只能让 Apple 接受这次提交 —— 那是另一件事。
    static func affectedBundles(
        whenDowngrading bundleIdentifier: String,
        strategy: Self,
        mappedMainBundleID: String,
        mappedBundleIdentifiers: [String],
        independentBundleIdentifiers: Set<String> = []
    ) -> [String] {
        switch strategy {
        case .sharedMainProfile:
            // 只有主 App 会走门户写入（`portalMappings` 只留主 App）；
            // 它被降级 ⇒ 那份共享描述文件对**所有**嵌入它的 bundle 都不再授予任何能力。
            guard bundleIdentifier == mappedMainBundleID else { return [bundleIdentifier] }
            // ⚠️ **必须把 `bundleIdentifier` 自己并进去**（不变量：结果恒含被降级的那个 bundle）——
            // 否则一旦调用方传来的 `mappedBundleIdentifiers` 漏了主 App，
            // 这里就会**悄悄退化回**「只清主 App 之外的、却不清主 App」那个原始 bug ✗。
            // ⚠️ 去重 + 稳定排序：`mappings` 是 `[原始 ID: 映射后 ID]`，映射后 ID 在
            // 「扩展 ID 需要哈希缩短」那条路径上理论上存在碰撞面 ⇒ 不能假定 values 互不相同。
            return Set(mappedBundleIdentifiers + [bundleIdentifier]).sorted()
        case .independentProfiles:
            // 每个 bundle 有自己的 App ID 与描述文件 ⇒ 降级只影响它自己。
            return [bundleIdentifier]
        case .selectiveProfiles:
            if bundleIdentifier == mappedMainBundleID {
                return Set(mappedBundleIdentifiers.filter {
                    $0 == mappedMainBundleID || independentBundleIdentifiers.contains($0) == false
                } + [mappedMainBundleID]).sorted()
            }
            return [bundleIdentifier]
        }
    }
}
