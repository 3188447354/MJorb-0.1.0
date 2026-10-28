import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 签名证书页「本机已安装 App」区域的纯判定：序列号取源与展示列表回落。
///
/// 抽成纯函数是为了能单测 —— 这层组合此前只写在视图里，五组中间集合无任何
/// 覆盖，真机恒空时只能靠猜（0.1.52 第 5 项定位，见 parts-0152/part-5.md）。
enum CertificateInstalledAppsPolicy {
    /// 证书序列号的统一取源，与 `SettingsViewModel.makeCertificateHealthStatus`
    /// 的健康口径同源：`selected ?? certificate ?? secret`，逐级跳过 nil 与
    /// 纯空白。旧实现只认 `certificateSerialNumber`：用户在证书页切换证书时
    /// `selectCertificate` 只写 `selected`，区域便拿旧/空序列号去比对 ——
    /// 空串经 `normalizedSerialNumber` 归一为 `"0"`，任何真实序列号都不
    /// 等于 `"0"`，结果恒空。
    static func effectiveCertificateSerialNumber(
        selectedCertificateSerialNumber: String?,
        certificateSerialNumber: String?,
        secretCertificateSerialNumber: String? = nil
    ) -> String {
        for candidate in [selectedCertificateSerialNumber, certificateSerialNumber, secretCertificateSerialNumber] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty == false { return trimmed }
        }
        return ""
    }

    static func effectiveCertificateSerialNumber(
        for account: AppleAccountRecord,
        secretCertificateSerialNumber: String? = nil
    ) -> String {
        effectiveCertificateSerialNumber(
            selectedCertificateSerialNumber: account.selectedCertificateSerialNumber,
            certificateSerialNumber: account.certificateSerialNumber,
            secretCertificateSerialNumber: secretCertificateSerialNumber
        )
    }

    /// 已安装区域最终展示哪份列表。
    enum Display: Equatable {
        /// 本地扫描命中的 App（扫描行渲染）。
        case localApps
        /// 记录口径的 App 列表（记录行渲染）。
        case recordApps([AppRecord])
        /// 无任何可展示记录，显示「暂无」。
        case empty
        /// 既无设备清单也无关联记录，显示「暂无关联记录」。
        case noAssociatedRecords
    }

    /// 展示列表的组合判定。
    ///
    /// 🔴 本地扫描分支的回落（根因 A）：旧实现只要本地扫描非 nil 就只认
    /// `locallyVisibleApps`，为空即整体显示「暂无」，把已算好的记录口径
    /// 列表全部丢弃 —— 而本地分支的同团队判据依赖扫描出的 `teamID`
    /// （私有 API，取不到为 nil）或 bundle ID 尾段，序列号再对不上时恒空。
    /// 新口径：本地扫描只能缩小到「已证实在机」的集合，不能把记录口径
    /// 已证实的关联整体吞成「暂无」；本地为空时先回落设备清单核验过的
    /// `installedApps`，再回落全量记录口径 `certificateApps`。
    static func display(
        hasLocalScan: Bool,
        locallyVisibleIsEmpty: Bool,
        hasInstalledBundleIdentifiers: Bool,
        installedApps: [AppRecord],
        certificateApps: [AppRecord]
    ) -> Display {
        if hasLocalScan {
            if locallyVisibleIsEmpty == false { return .localApps }
            if installedApps.isEmpty == false { return .recordApps(installedApps) }
            if certificateApps.isEmpty == false { return .recordApps(certificateApps) }
            return .empty
        }
        if hasInstalledBundleIdentifiers {
            return installedApps.isEmpty ? .empty : .recordApps(installedApps)
        }
        return certificateApps.isEmpty ? .noAssociatedRecords : .recordApps(certificateApps)
    }
}

struct SigningCertificateSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]
    let certificateExportHandler: CertificateExportHandler
    @State private var selectedAccountID: UUID?
    @State private var certificatePendingRevocation: ApplePortalCertificateSnapshot?
    @State private var installedBundleIdentifiers: Set<String>?
    @State private var localInstalledApps: [InstalledAppScanner.ScannedApp]?
    @State private var localInstalledIconData: [String: Data] = [:]
    @State private var isRefreshingInstalledBundleIdentifiers = false
    @State private var installedBundleIdentifierRetryRequested = false
    @State private var certificateExportAccount: AppleAccountRecord?
    @State private var certificateExportDocument: CertificateExportDocument?
    @State private var isCertificateFileExporterPresented = false
    @State private var certificateExportSucceeded = false

    var body: some View {
        certificatePage
        .fileExporter(
            isPresented: $isCertificateFileExporterPresented,
            document: certificateExportDocument,
            contentType: CertificateExportDocument.contentType,
            defaultFilename: "Seal-证书.p12"
        ) { result in
            certificateExportDocument = nil
            switch result {
            case .success:
                certificateExportSucceeded = true
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    viewModel.alertFailure = ImportFailure(title: "无法导出证书", reason: "证书没有保存成功。", recovery: "请更换保存位置后重试", code: "SEAL-CERT-EXPORT-102")
                }
            }
        }
        .alert("证书已保存", isPresented: $certificateExportSucceeded) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("可在需要的签名工具中导入。")
        }
        .confirmationDialog("导出证书到文件？", isPresented: Binding(
            get: { certificateExportAccount != nil },
            set: { if !$0 { certificateExportAccount = nil } }
        ), titleVisibility: .visible, presenting: certificateExportAccount) { account in
            Button("导出证书") {
                let serial = effectiveCertificateSerialNumber(for: account)
                Task {
                    do {
                        let data = try await certificateExportHandler.certificateForFile(account: account, serialNumber: serial)
                        certificateExportDocument = CertificateExportDocument(data: data)
                        isCertificateFileExporterPresented = true
                    } catch let failure as ImportFailure {
                        viewModel.alertFailure = failure
                    } catch {
                        viewModel.alertFailure = ImportFailure(title: "无法导出证书", reason: "无法读取本机证书。", recovery: "请重试", code: "SEAL-CERT-EXPORT-103")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("证书包含私钥，请妥善保管。此证书没有设置密码。")
        }
    }

    private var certificatePage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                accountCard

                if viewModel.isSelfManagementLoading || viewModel.selfManagement.isVisible {
                    selfManagementCard
                }

                Text("签名证书")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
                    .padding(.leading, 8)

                certificateContent
            }
            .padding(20)
        }
        .navigationTitle("签名证书")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .confirmationDialog(
            "撤销这张证书？",
            isPresented: Binding(
                get: { certificatePendingRevocation != nil },
                set: { if !$0 { certificatePendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤销证书", role: .destructive) {
                if let account = activeAccount,
                   let certificate = certificatePendingRevocation {
                    Task {
                        await viewModel.revokeCertificate(serialNumber: certificate.serialNumber, for: account)
                    }
                }
                certificatePendingRevocation = nil
            }
            Button("取消", role: .cancel) {
                certificatePendingRevocation = nil
            }
        } message: {
            if let certificate = certificatePendingRevocation {
                Text(revocationWarning(for: certificate))
            }
        }
        .task {
            if selectedAccountID == nil {
                selectedAccountID = viewModel.activeAccount?.id
            }
            await viewModel.load()
            await refreshInstalledBundleIdentifiers()
            await viewModel.refreshSelfManagementState()
            guard let account = activeAccount else { return }
            await viewModel.refreshCertificateHealthLocally(for: account)
            await viewModel.refreshCertificateInventory(for: account, force: false)
        }
        .refreshable {
            await viewModel.load(force: true)
            await refreshInstalledBundleIdentifiers()
            await viewModel.refreshSelfManagementState()
            guard let account = activeAccount else { return }
            await viewModel.refreshCertificateHealthLocally(for: account)
            await viewModel.refreshCertificateInventory(for: account, force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sealSelfRecordUpdated)) { _ in
            Task { await viewModel.refreshSelfManagementState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sealDeviceSessionWriterReleased)) { _ in
            guard installedBundleIdentifiers == nil else { return }
            Task { await refreshInstalledBundleIdentifiers() }
        }
        .sealScreenBackground()
    }

    private var activeAccount: AppleAccountRecord? {
        if let id = selectedAccountID, let account = viewModel.accounts.first(where: { $0.id == id }) {
            return account
        }
        return viewModel.activeAccount
    }

    /// 本页统一的证书序列号取源（健康口径，见 `CertificateInstalledAppsPolicy`）。
    ///
    /// View 拿不到 Keychain 里的 secret 本体：记录两级皆空时，用健康状态的
    /// `serialNumber` 兜底 —— 它正是 ViewModel 按
    /// `selected ?? certificate ?? secret` 算出的结果，与健康口径不分叉。
    private func effectiveCertificateSerialNumber(for account: AppleAccountRecord) -> String {
        let fromRecord = CertificateInstalledAppsPolicy.effectiveCertificateSerialNumber(for: account)
        if fromRecord.isEmpty == false { return fromRecord }
        let healthSerial = viewModel.certificateHealthStatus(for: account.id)?.serialNumber ?? ""
        return healthSerial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshInstalledBundleIdentifiers() async {
        guard isRefreshingInstalledBundleIdentifiers == false else {
            installedBundleIdentifierRetryRequested = true
            return
        }
        isRefreshingInstalledBundleIdentifiers = true
        defer { isRefreshingInstalledBundleIdentifiers = false }

        repeat {
            installedBundleIdentifierRetryRequested = false
            await scanInstalledBundleIdentifiersOnce()
        } while installedBundleIdentifierRetryRequested && installedBundleIdentifiers == nil
    }

    private func scanInstalledBundleIdentifiersOnce() async {
        let scanner = InstalledAppScanner()
        if let controlBundleIdentifier = Bundle.main.bundleIdentifier,
           let snapshot = await scanner.scanAllSnapshot(),
           InstalledAppRefreshProbePolicy.canUseLocalSnapshot(
                controlBundleIdentifier: controlBundleIdentifier,
                installedBundleIdentifiers: snapshot.map(\.bundleIdentifier)
           ) {
            await storeLocalInstalledApps(snapshot, using: scanner)
            installedBundleIdentifiers = Set(
                snapshot.compactMap {
                    InstalledAppRefreshProbePolicy.normalizedBundleIdentifier($0.bundleIdentifier)
                }
            )
            return
        }
        if let partialSnapshot = await scanner.scanAllSnapshot(allowPartialForRecovery: true) {
            await storeLocalInstalledApps(partialSnapshot, using: scanner)
        }
        installedBundleIdentifiers = await viewModel.scanInstalledAppBundleIdentifiers(for: relatedApps)
    }

    private func storeLocalInstalledApps(
        _ apps: [InstalledAppScanner.ScannedApp],
        using scanner: InstalledAppScanner
    ) async {
        localInstalledApps = apps
        let knownTeams = viewModel.accounts.map(\.teamID)
        let certificateBundleIdentifiers = Set(viewModel.accounts.flatMap { account in
            CertificateRevocationImpact.associatedApps(
                serialNumber: effectiveCertificateSerialNumber(for: account),
                apps: relatedApps
            ).map { $0.mappedBundleIdentifier ?? $0.preferredBundleIdentifier ?? $0.originalBundleIdentifier }
        }.compactMap(InstalledAppRefreshProbePolicy.normalizedBundleIdentifier))
        let teamBundleIdentifiers = Set(knownTeams.flatMap { teamID in
            CertificateRevocationImpact.sameTeamInstalledApps(teamID: teamID, scannedApps: apps)
                .compactMap { InstalledAppRefreshProbePolicy.normalizedBundleIdentifier($0.bundleIdentifier) }
        })
        let iconsToLoad = Set(apps.compactMap { app -> String? in
            let normalizedBundleIdentifier = InstalledAppRefreshProbePolicy.normalizedBundleIdentifier(
                app.bundleIdentifier
            )
            guard let normalizedBundleIdentifier,
                  teamBundleIdentifiers.contains(normalizedBundleIdentifier)
                    || certificateBundleIdentifiers.contains(normalizedBundleIdentifier) else { return nil }
            return normalizedBundleIdentifier
        })
        localInstalledIconData = await scanner.scanIconData(for: iconsToLoad)
    }

    private var selectableAccounts: [AppleAccountRecord] {
        viewModel.accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
    }

    @ViewBuilder
    private var accountCard: some View {
        VStack(spacing: 0) {
            if selectableAccounts.isEmpty {
                Text("请先添加并验证 Apple ID")
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                Menu {
                    ForEach(selectableAccounts) { account in
                        Button {
                            selectedAccountID = account.id
                            Task {
                                await viewModel.selectActiveAccount(account)
                                await viewModel.refreshCertificateHealthLocally(for: account)
                                await viewModel.refreshCertificateInventory(for: account, force: false)
                            }
                        } label: {
                            Text(viewModel.fullEmail(for: account))
                            if account.id == activeAccount?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Apple ID")
                            .foregroundStyle(.primary)
                            .singleLine()
                        Spacer()
                        if let account = activeAccount {
                            Text(viewModel.fullEmail(for: account))
                                .foregroundStyle(Color.sealTextSecondary)
                                .singleLine()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(Color.sealTextSecondary)
                        } else {
                            Text("请选择")
                                .foregroundStyle(Color.sealTextSecondary)
                                .singleLine()
                        }
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let account = activeAccount {
                    Divider()
                    detailRow("团队 ID", account.teamID.isEmpty ? "—" : account.teamID)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sealContentCard(.prominent)
    }

    @ViewBuilder
    private var certificateContent: some View {
        if let account = activeAccount {
            if viewModel.isCertificateInventoryLoading(accountID: account.id) {
                certificateLoadingCard
            } else if let failure = viewModel.certificateInventoryFailure(for: account.id),
                      viewModel.certificateInventory(for: account.id) == nil {
                // 证书同步失败且无缓存可看：行内失败行＋重试按钮，不再静默空卡。
                // 有缓存时仍显示缓存数据（失败由刷新入口的提示承载），不挡正常查看。
                certificateSyncFailureCard(account: account, failure: failure)
            } else {
                unifiedCertificateCard(account: account)
            }
        } else {
            noAccountCard
        }
    }

    private func certificateSyncFailureCard(account: AppleAccountRecord, failure: ImportFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("证书同步失败")
                .font(.headline)
                .foregroundStyle(Color.sealDanger)
                .singleLine()
            Text(failure.userMessage)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
            Button("重新同步") {
                Task { await viewModel.refreshCertificateInventory(for: account, force: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .sealContentCard(.prominent)
    }

    /// 自管理状态卡：当前真实签名者、本机可用身份、事务状态和下一步。
    /// View 只读 ViewModel 汇总好的展示模型，不自己猜状态。
    private var selfManagementCard: some View {
        if viewModel.isSelfManagementLoading {
            // 自管理卡加载态：转圈换成一行明细行骨架（标题行＋一行明细），
            // 与下方真实卡片的「标题＋明细行」版式一致。
            return AnyView(
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SealSkeletonBar(width: 140, height: 16)
                        Spacer(minLength: 8)
                        SealSkeletonBar(width: 96, height: 12)
                    }
                    SealSkeletonDetailRow(labelWidth: 96, valueWidth: 150)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .sealContentCard(.prominent)
            )
        }
        let presentation = viewModel.selfManagement
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if presentation.state == .awaitingReplacementConfirmation {
                    Button {
                        Task { await viewModel.refreshSelfManagementState() }
                    } label: {
                        Text("检查安装结果")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.sealAccent)
                            .singleLine()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.sealAccent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if presentation.detail.isEmpty == false {
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
            }
            if presentation.state != .externalBootstrap {
                HStack(spacing: 8) {
                    Text("当前实际签名者")
                        .font(.caption)
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                    Spacer(minLength: 8)
                    Text(viewModel.sealActualSignerSerialNumber.map(fullSerialText) ?? "读取失败")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .sealCopyableIdentifier(viewModel.sealActualSignerSerialNumber ?? "")
            }
            if presentation.showsComputerRecovery {
                Text("请勿卸载 Seal；用电脑按相同包名和团队覆盖安装。")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.sealDanger)
                    .singleLine()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .sealContentCard(.prominent))
    }

    /// 证书卡骨架：同步期间按最终卡片版式画灰块，不再只转圈。
    private var certificateLoadingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SealSkeletonBar(width: 140, height: 16)
                Spacer(minLength: 8)
                SealSkeletonBar(width: 96, height: 12)
            }
            SealSkeletonDetailRow(labelWidth: 72, valueWidth: 170)
            SealSkeletonDetailRow(labelWidth: 72, valueWidth: 130)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .sealContentCard(.prominent)
    }

    /// 单个证书卡片：本机在用证书（如有）在上，账号下其余证书（可撤销）合并展示。
    private func unifiedCertificateCard(account: AppleAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if effectiveCertificateSerialNumber(for: account).isEmpty == false {
                localCertificateSection(account: account)
            } else {
                missingCertificateHeader
                otherCertificatesSection(account: account)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .sealContentCard(.prominent)
    }

    private func localCertificateSection(account: AppleAccountRecord) -> some View {
        let health = viewModel.certificateHealthStatus(for: account.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(localCertificateDisplayName(account))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                Spacer(minLength: 12)
                Text(certificateSummary(health))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(certificateSummaryColor(health))
                    .singleLine()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        certificateSummaryColor(health).opacity(0.12),
                        in: Capsule()
                    )
            }
            .padding(.bottom, 8)

            Text(fullSerialText(effectiveCertificateSerialNumber(for: account)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
                .padding(.bottom, 14)

            Divider()

            VStack(spacing: 0) {
                certificateHealthRow(
                    expirationTitle(health),
                    value: expirationText(health),
                    state: nil
                )
                Divider()
                certificateHealthRow(
                    "本机证书密钥",
                    value: localPrivateKeyText(health),
                    state: health?.localPrivateKey
                )
                Divider()
                installedAppsSection(account: account)
                Divider()
                    Button {
                        certificateExportAccount = account
                    } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                        Text("导出证书到文件")
                            .font(.subheadline.weight(.semibold))
                            .singleLine()
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                    .foregroundStyle(Color.sealAccent)
                    .padding(.vertical, 12)
                    }
            }
        }
    }

    private var missingCertificateHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前没有本机可用证书")
                .font(.headline)
                .singleLine()
            Text("首次签名时将自动创建。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func otherCertificatesSection(account: AppleAccountRecord) -> some View {
        let certificates = nonLocalCertificates(account: account)
        if certificates.isEmpty {
            EmptyView()
        } else {
            Divider()
                .padding(.vertical, 14)
            Text("账号下的其他证书")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
                .padding(.bottom, 6)
            ForEach(Array(certificates.enumerated()), id: \.element.id) { index, certificate in
                if index > 0 { Divider() }
                remoteCertificateRow(certificate)
            }
        }
    }

    private func nonLocalCertificates(account: AppleAccountRecord) -> [ApplePortalCertificateSnapshot] {
        let inventory = viewModel.certificateInventory(for: account.id)
        let allCertificates = inventory?.certificates ?? []
        // 本机证书的认定与上方本机区同源（统一取源）：`isLocalCertificate`
        // 只认 `certificateSerialNumber`，切换过证书（只写 selected）时，
        // 正在用的那张会被同时列进「其他证书」并给出撤销入口 —— 必须按
        // effective 序列号一并排除（归一化比对，与全仓序列号口径一致）。
        let effectiveSerial = effectiveCertificateSerialNumber(for: account)
        let normalizedEffective = SigningCertificateSelectionPolicy.normalizedSerialNumber(effectiveSerial)
        return deduplicatedCertificates(allCertificates).filter { certificate in
            guard CertificateRevocationImpact.isLocalCertificate(
                serialNumber: certificate.serialNumber,
                account: account
            ) == false else { return false }
            guard effectiveSerial.isEmpty == false else { return true }
            return SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
                != normalizedEffective
        }
    }

    /// 证书角色的固定标签含义：真实签名者 > 本机持有私钥 > 仅 Apple 端存在；
    /// 身份读不出来时无法证明任何一张不是 Seal 的命，一律标「关联状态无法确认」。
    private func roleLabels(for certificate: ApplePortalCertificateSnapshot) -> [CertificateRoleLabel] {
        guard let signer = viewModel.sealActualSignerSerialNumber else {
            return [.associationUnknown]
        }
        var labels: [CertificateRoleLabel] = []
        if CertificateRevocationImpact.isActualSealSigner(
            serialNumber: certificate.serialNumber,
            actualSealSignerSerialNumber: signer
        ) {
            labels.append(.currentSealSigner)
        } else if certificate.hasLocalPrivateKey {
            labels.append(.locallyUsable)
        }
        guard let installedBundleIdentifiers else {
            labels.append(.associationUnknown)
            return labels
        }
        if CertificateRevocationImpact.installedAppsAssociated(
            serialNumber: certificate.serialNumber,
            apps: relatedApps,
            installedBundleIdentifiers: installedBundleIdentifiers
        ).isEmpty == false {
            labels.append(.associatedOnThisDevice)
        }
        return labels
    }

    private func remoteCertificateRow(
        _ certificate: ApplePortalCertificateSnapshot
    ) -> some View {
        let labels = roleLabels(for: certificate)
        // 真实签名者或「无法确认关联」都不提供撤销入口（ViewModel 层还有硬拒绝兜底）。
        let revocationAllowed = labels.contains(.currentSealSigner) == false
            && labels.contains(.associationUnknown) == false
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(certificate.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(labels, id: \.title) { label in
                        Text(label.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(label == .currentSealSigner ? Color.sealDanger : Color.sealTextSecondary)
                            .singleLine()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (label == .currentSealSigner ? Color.sealDanger : Color.sealTextSecondary).opacity(0.12),
                                in: Capsule()
                            )
                    }
                }
                Text(fullSerialText(certificate.serialNumber))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
                Text(expirationLine(certificate))
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
            }
            Spacer(minLength: 8)
            if revocationAllowed {
                VStack(spacing: 8) {
                    Button {
                        certificatePendingRevocation = certificate
                    } label: {
                        Text("撤销证书")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.sealDanger)
                            .singleLine()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.sealDanger.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func revocationWarning(for certificate: ApplePortalCertificateSnapshot) -> String {
        CertificateRevocationImpact.warningMessage(
            serialNumber: certificate.serialNumber,
            apps: relatedApps,
            isLocalCertificate: false,
            installedBundleIdentifiers: installedBundleIdentifiers
        )
    }

    private func certificateHealthRow(
        _ title: String,
        value: String,
        state: CertificateHealthStatus.CheckState?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                if let state {
                    Image(systemName: stateIcon(state))
                        .foregroundStyle(stateColor(state))
                        .accessibilityHidden(true)
                }
                Text(value)
                    .foregroundStyle(state.map { stateColor($0) } ?? Color.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }

    private func certificateSummary(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        if health.expirationState == .invalid { return "无效" }
        return health.isUsable ? "可用" : "无效"
    }

    private func certificateSummaryColor(_ health: CertificateHealthStatus?) -> Color {
        guard let health else { return Color.sealTextSecondary }
        if health.expirationState == .invalid { return Color.sealDanger }
        return health.isUsable ? Color.sealSuccess : Color.sealWarning
    }

    private func stateIcon(_ state: CertificateHealthStatus.CheckState) -> String {
        switch state {
        case .valid: "checkmark.circle.fill"
        case .invalid: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func stateColor(_ state: CertificateHealthStatus.CheckState) -> Color {
        switch state {
        case .valid: Color.sealSuccess
        case .invalid: Color.sealDanger
        case .unknown: Color.sealTextSecondary
        }
    }

    private func expirationTitle(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "证书有效期" }
        if health.portalPresence == .invalid { return "Apple 服务器证书状态" }
        return health.expirationState == .invalid ? "证书已过期" : "证书有效期至"
    }

    private func expirationText(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        if health.portalPresence == .invalid { return "已撤销或不存在" }
        guard let expirationDate = health.expirationDate else { return "无法确认" }
        return SealSettingsDateFormatter.string(from: expirationDate)
    }

    private func localPrivateKeyText(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        switch health.localPrivateKey {
        case .valid: return "可用"
        case .invalid: return "缺失或损坏（不能用于新签名）"
        case .unknown: return "无法确认"
        }
    }

    private func fullSerialText(_ serialNumber: String) -> String {
        "序列号 \(serialNumber)"
    }

    private func expirationLine(_ certificate: ApplePortalCertificateSnapshot) -> String {
        guard let expirationDate = certificate.expirationDate else {
            return "有效期：无法确认"
        }
        return "有效期至 \(SealSettingsDateFormatter.string(from: expirationDate))"
    }

    private func deduplicatedCertificates(
        _ certificates: [ApplePortalCertificateSnapshot]
    ) -> [ApplePortalCertificateSnapshot] {
        var seen = Set<String>()
        return certificates.filter { certificate in
            let key = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            return seen.insert(key).inserted
        }
    }

    private func localCertificateDisplayName(_ account: AppleAccountRecord) -> String {
        let localSerial = effectiveCertificateSerialNumber(for: account)
        guard localSerial.isEmpty == false,
              let inventory = viewModel.certificateInventory(for: account.id) else {
            return "本机证书"
        }
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(localSerial)
        return inventory.certificates.first {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) == normalized
        }?.displayName ?? "本机证书"
    }

    @ViewBuilder
    private func installedAppsSection(account: AppleAccountRecord) -> some View {
        let effectiveSerial = effectiveCertificateSerialNumber(for: account)
        let certificateApps = CertificateRevocationImpact.associatedApps(
            serialNumber: effectiveSerial,
            apps: relatedApps
        )
        let installedApps = CertificateRevocationImpact.installedAppsAssociated(
            serialNumber: effectiveSerial,
            apps: relatedApps,
            installedBundleIdentifiers: installedBundleIdentifiers ?? []
        )
        let locallyInstalledBundleIdentifiers = Set((localInstalledApps ?? []).compactMap {
            InstalledAppRefreshProbePolicy.normalizedBundleIdentifier($0.bundleIdentifier)
        })
        let localCertificateApps = CertificateRevocationImpact.installedAppsAssociated(
            serialNumber: effectiveSerial,
            apps: relatedApps,
            installedBundleIdentifiers: locallyInstalledBundleIdentifiers
        )
        let certificateBundleIdentifiers = Set(localCertificateApps.compactMap {
            InstalledAppRefreshProbePolicy.normalizedBundleIdentifier(
                $0.mappedBundleIdentifier ?? $0.preferredBundleIdentifier ?? $0.originalBundleIdentifier
            )
        })
        let sameTeamApps = CertificateRevocationImpact.sameTeamInstalledApps(
            teamID: account.teamID,
            scannedApps: localInstalledApps ?? []
        )
        let locallyVisibleApps = (localInstalledApps ?? []).filter { app in
            guard let bundleIdentifier = InstalledAppRefreshProbePolicy.normalizedBundleIdentifier(
                app.bundleIdentifier
            ) else { return false }
            return certificateBundleIdentifiers.contains(bundleIdentifier)
                || sameTeamApps.contains { $0.bundleIdentifier == app.bundleIdentifier }
        }
        let display = CertificateInstalledAppsPolicy.display(
            hasLocalScan: localInstalledApps != nil,
            locallyVisibleIsEmpty: locallyVisibleApps.isEmpty,
            hasInstalledBundleIdentifiers: installedBundleIdentifiers != nil,
            installedApps: installedApps,
            certificateApps: certificateApps
        )
        // 在构建器外把记录列表解出来：视图内只用最普通的 if / if let 分支，
        // 不把模式匹配塞进 @ViewBuilder（本机无工具链，编译只能等 CI，取最稳形态）。
        let recordApps: [AppRecord]? = {
            if case .recordApps(let apps) = display { return apps }
            return nil
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localInstalledApps != nil || installedBundleIdentifiers != nil ? "本机已安装 App" : "签名记录")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
                Spacer(minLength: 8)
                Text(localInstalledApps != nil ? "证书记录 / 同团队" : "由该证书签名")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
            }
            if display == .localApps {
                localInstalledAppRows(locallyVisibleApps, certificateBundleIdentifiers: certificateBundleIdentifiers)
            } else if let recordApps {
                installedAppRows(recordApps)
            } else if display == .noAssociatedRecords {
                ContentUnavailableView {
                    Label("暂无关联记录", systemImage: "tray")
                }
            } else {
                ContentUnavailableView {
                    Label("暂无", systemImage: "tray")
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func localInstalledAppRows(
        _ apps: [InstalledAppScanner.ScannedApp],
        certificateBundleIdentifiers: Set<String>
    ) -> some View {
        ForEach(apps, id: \.bundleIdentifier) { app in
            let bundleIdentifier = InstalledAppRefreshProbePolicy.normalizedBundleIdentifier(app.bundleIdentifier) ?? ""
            HStack(alignment: .center, spacing: 10) {
                localInstalledAppIcon(for: bundleIdentifier)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.subheadline.weight(.medium))
                        .singleLine()
                    Text(app.bundleIdentifier)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text(certificateBundleIdentifiers.contains(bundleIdentifier) ? "证书记录" : "同团队")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
            }
        }
    }

    @ViewBuilder
    private func localInstalledAppIcon(for bundleIdentifier: String) -> some View {
        ZStack {
            if let data = localInstalledIconData[bundleIdentifier], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.sealSurface)
                Image(systemName: "app.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.sealTextSecondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    private func installedAppRows(_ apps: [AppRecord]) -> some View {
        ForEach(apps) { app in
            HStack(alignment: .center, spacing: 10) {
                installedAppIcon(for: app)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.subheadline.weight(.medium))
                        .singleLine()
                    Text(app.mappedBundleIdentifier ?? app.originalBundleIdentifier)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func installedAppIcon(for app: AppRecord) -> some View {
        ZStack {
            if let data = viewModel.appIconData[app.id], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.sealSurface)
                Image(systemName: "app.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.sealTextSecondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    private var noAccountCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(Color.sealWarning)
            Text("未选择 Apple ID")
                .font(.headline)
                .singleLine()
            Text("请先添加并验证 Apple ID。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .singleLine()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .sealContentCard(.prominent)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .singleLine()
        }
        .padding(.vertical, 15)
    }
}

private struct CertificateExportDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "p12") ?? .data
    static var readableContentTypes: [UTType] { [contentType] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
