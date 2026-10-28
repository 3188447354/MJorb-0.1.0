import Foundation

/// Bundle ID helpers. Seal validates only local string format; Apple/iOS decide availability.
enum BundleIDPolicy {
    static func canonicalSealBundleIdentifier(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "SealOriginalBundleIdentifier") as? String
            ?? "com.mjorb.seal"
    }

    static func currentSealBundleIdentifier(bundle: Bundle = .main) -> String? {
        bundle.bundleIdentifier
    }

    static func isLegacySelfBundleIdentifier(_ bundleIdentifier: String, bundle: Bundle = .main) -> Bool {
        let canonical = canonicalSealBundleIdentifier(bundle: bundle)
        return bundleIdentifier != canonical
            && bundleIdentifier.hasPrefix(canonical + ".")
    }

    static func targetBundleIdentifier(
        for app: AppRecord,
        requestedBundleIdentifier: String? = nil,
        currentSealBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> String {
        if app.requiresLockedSigningIdentity || app.state == .installed || app.isSeal {
            if let mapped = normalized(app.mappedBundleIdentifier), mapped.isEmpty == false {
                return try validated(mapped)
            }
            if let preferred = normalized(app.preferredBundleIdentifier), preferred.isEmpty == false {
                return try validated(preferred)
            }
            throw ImportFailure(
                title: "续签记录不完整",
                reason: "未记录当前签名后的 Bundle ID。",
                recovery: "重新选择 IPA 签名并安装",
                code: "SEAL-BUNDLE-002"
            )
        }
        if let requested = normalized(requestedBundleIdentifier) {
            return try validated(requested)
        }
        if let preferred = normalized(app.preferredBundleIdentifier), preferred.isEmpty == false {
            return try validated(preferred)
        }
        if let mapped = normalized(app.mappedBundleIdentifier), mapped.isEmpty == false {
            return try validated(mapped)
        }
        return try validated(recommendedBundleIdentifier(for: app.originalBundleIdentifier))
    }

    static func recommendedBundleIdentifier(for original: String, teamID: String) -> String {
        // 这是签名面板展示的可编辑默认值，不是签名器的隐式改写规则。
        // 始终追加一次 Team，恢复记录时才能精确还原导入 IPA 的原始 Bundle ID。
        let value = normalized(original) ?? original
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard team.isEmpty == false else { return value }
        return "\(value).\(team)"
    }

    /// 无 teamID 时同样保留原始 Bundle ID。
    static func recommendedBundleIdentifier(for original: String) -> String {
        normalized(original) ?? original
    }

    static func isEditable(_ app: AppRecord) -> Bool {
        app.isSeal == false && app.requiresLockedSigningIdentity == false && app.state != .installed
    }

    static func displayMode(for app: AppRecord) -> String {
        "按 Apple / iOS 实际返回处理"
    }

    static func validationError(for value: String) -> String? {
        do {
            _ = try validated(value)
            return nil
        } catch let failure as ImportFailure {
            return failure.reason
        } catch {
            return "Bundle ID 格式无效"
        }
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validated(_ value: String) throws -> String {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            throw failure(reason: "不能为空")
        }
        // 这里只挡 Apple 明确不允许的字符；长度、段数和可用情况由 Apple 注册结果裁定。
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")
        guard identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            // ⚠️ 文案要说清**为什么**（2026-09-19 用户问「Bundle ID 能不能带符号/表情」）：
            // 这不是 Seal 的限制 ✗，而是 **Apple 的硬性规定** —— 带空格 / 中文 / 表情 / 符号的
            // Bundle ID 会被 Apple 直接拒绝，签名根本走不到底 ✗。
            throw failure(
                reason: "Apple 规定 Bundle ID 只能包含英文字母、数字、连字符和句点；空格、中文、表情及其它符号都不允许。需要表情请修改 App 名称。"
            )
        }
        return identifier
    }

    private static func failure(reason: String) -> ImportFailure {
        ImportFailure(
            title: "Bundle ID 无效",
            reason: reason,
            recovery: "修改 Bundle ID",
            code: "SEAL-BUNDLE-001"
        )
    }
}
