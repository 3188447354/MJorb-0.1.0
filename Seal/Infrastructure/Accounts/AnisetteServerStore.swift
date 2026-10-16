import Foundation

protocol AnisetteServerStore: Sendable {
    func selectedServerID() async -> String?
    func saveSelectedServerID(_ id: String) async
}

actor UserDefaultsAnisetteServerStore: AnisetteServerStore {
    private let key = "com.mjorb.seal.anisette-v3.selected-server"
    /// 一次性迁移标记，见 `migrateAwayFromMacIdentityDefaultsIfNeeded()`。
    private let migrationKey = "com.mjorb.seal.anisette-v3.selected-server.windows-migration"

    /// 这些服务器返回 **Mac 身份**，其 ADI 自 2026-10-12 起会被 Apple 以 `-80045`
    /// 拒绝（`ani.sidestore.io` 曾长期是 Seal 的默认首选，因此存量安装里
    /// `selected-server` 极可能正指向它）。
    ///
    /// 只清「曾经是默认值」的那几个，不动用户自己挑的其它服务器 —— 否则迁移会变成
    /// 覆盖用户设置。
    private static let supersededDefaultIDs: Set<String> = [
        "sidestore-io", "sidestore-app", "sidestore-zip", "sidestore-xyz",
    ]

    func selectedServerID() async -> String? {
        migrateAwayFromMacIdentityDefaultsIfNeeded()
        return UserDefaults.standard.string(forKey: key)
    }

    func saveSelectedServerID(_ id: String) async {
        UserDefaults.standard.set(id, forKey: key)
    }

    /// 把存量安装里指向「Mac 身份服务器」的旧选择清掉，让新的 Windows 首选生效。
    ///
    /// 为什么必须做：`AnisetteServerCatalog.prioritized(selectedID:)` 会把用户选中的
    /// 那台排到最前。老版本默认选中 `ani.sidestore.io`，若不迁移，即便把 Windows
    /// 服务器提到目录首位也永远不会被尝试 —— 登录照旧失败。只在首次运行做一次，
    /// 之后用户的选择不再被干预。
    private func migrateAwayFromMacIdentityDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: migrationKey) == false else { return }
        defaults.set(true, forKey: migrationKey)

        guard let current = defaults.string(forKey: key) else { return }
        guard Self.supersededDefaultIDs.contains(current) else { return }
        defaults.removeObject(forKey: key)
    }
}
