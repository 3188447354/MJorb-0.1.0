import Foundation

/// 版本比较结果：用于导入时判断是升级、同版本还是降级
enum VersionCheckResult: Equatable, Sendable {
    /// 新记录，没有已存在的同 Bundle ID 记录
    case newApp
    /// 高版本：正常升级，直接覆盖
    case upgrade(oldVersion: String, newVersion: String)
    /// 同版本同内容：已是最新，阻止导入
    case alreadyLatest(version: String)
    /// 同版本但原始 IPA 已丢失：允许用户重新导入以恢复可管理的源文件
    case sameVersionRecovery(version: String)
    /// 低版本：降级警告，需要用户二次确认
    case downgrade(oldVersion: String, newVersion: String)
    /// 同营销版本但构建号更高：视为升级（例如 v0.1.0 build 68 → build 69）
    case buildUpgrade(oldBuild: String, newBuild: String, version: String)
    /// 同营销版本但构建号更低：视为降级
    case buildDowngrade(oldBuild: String, newBuild: String, version: String)
    /// 已安装记录没有保存旧版本（例如重装 Seal 后从设备恢复的记录），新 IPA 版本有效，
    /// 可以按首次补录版本进入覆盖签名流程。
    case missingInstalledVersion(newVersion: String)
    /// 版本号无法按数字段解析，不猜测升级或降级
    case unreadableVersion
}

struct ImportDraft: Equatable, Identifiable, Sendable {
    let appID: UUID
    let parsedIPA: ParsedIPA
    let stagedIPA: StagedIPA
    /// 版本检查结果（prepare 阶段计算，UI 用来决定是否弹框）
    let versionCheck: VersionCheckResult
    /// 由应用内更新器发起的 Seal 自更新。此标记必须贯穿导入到提交，不能因
    /// IPA Bundle ID 未匹配普通记录而退化成一个普通的新应用。
    let isSelfUpdate: Bool
    /// 准备阶段确认的当前 Seal 记录；提交时按 ID 再次核验，防止确认期间目标变化。
    let selfUpdateTargetRecordID: UUID?

    init(
        appID: UUID,
        parsedIPA: ParsedIPA,
        stagedIPA: StagedIPA,
        versionCheck: VersionCheckResult,
        isSelfUpdate: Bool = false,
        selfUpdateTargetRecordID: UUID? = nil
    ) {
        self.appID = appID
        self.parsedIPA = parsedIPA
        self.stagedIPA = stagedIPA
        self.versionCheck = versionCheck
        self.isSelfUpdate = isSelfUpdate
        self.selfUpdateTargetRecordID = selfUpdateTargetRecordID
    }

    var id: UUID { appID }
}
