import SwiftUI

struct AppleAccountDetailView: View {
    let account: AppleAccountRecord
    let relatedApps: [AppRecord]
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var hasRequestedInitialInventory = false

    private var currentAccount: AppleAccountRecord {
        viewModel.accounts.first(where: { $0.id == account.id }) ?? account
    }

    private var inventory: ApplePortalInventory? {
        viewModel.certificateInventory(for: account.id)
    }

    private var syncFailure: ImportFailure? {
        viewModel.certificateInventoryFailure(for: account.id)
    }

    private var isSyncing: Bool {
        viewModel.isCertificateInventoryLoading(accountID: account.id)
    }

    private var appItems: [AppleAccountAppItem] {
        guard let inventory else { return [] }
        return makeAppItems(from: inventory)
    }

    private var contentState: AppleAccountAppListState {
        let hasInventory = inventory != nil
        if isSyncing && hasInventory == false {
            return .loading
        }
        if let syncFailure, hasInventory == false {
            return .failure(syncFailure.userMessage)
        }
        let items = appItems
        if items.isEmpty {
            return .empty
        }
        return .loaded(items)
    }

    var body: some View {
        AppleAccountAppListView(
            state: contentState,
            quota: inventory?.appIDQuota,
            onRetry: refreshButtonTapped
        )
        .navigationTitle("已签名 App")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppleAccountRefreshToolbar(
                isSyncing: isSyncing,
                action: refreshButtonTapped
            )
        }
        .task {
            await loadInitialInventoryIfNeeded()
        }
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .sealScreenBackground()
    }

    private func makeAppItems(from inventory: ApplePortalInventory) -> [AppleAccountAppItem] {
        let now = Date()
        let snapshots = inventory.appIDs.filter { snapshot in
            ApplePortalAppIDPolicy.includes(
                expirationDate: snapshot.appIDExpirationDate,
                fetchedAt: now
            )
        }
        let items = snapshots.map { snapshot in
            AppleAccountAppItem(
                snapshot: snapshot,
                accountID: currentAccount.id,
                relatedApps: relatedApps,
                accountTeamID: currentAccount.teamID,
                knownAccountIDs: Set(viewModel.accounts.map(\.id))
            )
        }
        return items.sorted { first, second in
            if first.expiryDate != second.expiryDate {
                return AppleAccountAppNamePolicy.expirationComesBefore(first.expiryDate, second.expiryDate)
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    private func refreshButtonTapped() {
        Task {
            await refreshCurrentInventory()
        }
    }

    @MainActor
    private func loadInitialInventoryIfNeeded() async {
        await viewModel.load()
        guard hasRequestedInitialInventory == false else { return }
        guard viewModel.certificateInventory(for: account.id) == nil else { return }
        hasRequestedInitialInventory = true
        await viewModel.refreshAppIDInventory(for: currentAccount, force: false)
    }

    @MainActor
    private func refreshCurrentInventory() async {
        await viewModel.refreshAppIDInventory(for: currentAccount, force: true)
    }
}

private struct AppleAccountRefreshToolbar: ToolbarContent {
    let isSyncing: Bool
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: action) {
                AppleAccountRefreshButtonLabel(isSyncing: isSyncing)
            }
            .disabled(isSyncing)
        }
    }
}

private struct AppleAccountRefreshButtonLabel: View {
    let isSyncing: Bool

    var body: some View {
        Group {
            if isSyncing {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}

private enum AppleAccountAppListState: Equatable {
    case loading
    case failure(String)
    case empty
    case loaded([AppleAccountAppItem])
}

private struct AppleAccountAppListView: View {
    let state: AppleAccountAppListState
    let quota: ApplePortalAppIDQuotaSnapshot?
    let onRetry: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if case .loading = state {
                    // 加载态：名额卡与列表行都按最终版式画骨架，不再整块转圈
                    // （名额卡旧行为是直接隐藏，列表只有一句「正在读取」）。
                    skeletonQuotaCard
                } else {
                    appIDQuotaCard
                }
                content
            }
                .padding(20)
        }
    }

    private var appIDQuotaCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("App ID 名额")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let available = quota?.availableQuantity, available >= 0 {
                    Text("\(available) 个可新建")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.sealAccent)
                } else {
                    Text("Apple 未提供")
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
            Text("已有的 App ID 仍可继续用于签名。")
                .font(.footnote)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            skeletonAppList
        case .failure(let message):
            AppleAccountFailureCard(message: message, onRetry: onRetry)
        case .empty:
            ContentUnavailableView {
                Label("暂无签名应用", systemImage: "app.dashed")
            } description: {
                Text("这个 Apple ID 还没有签名过任何应用。")
            }
        case .loaded(let items):
            AppleAccountLoadedAppListView(items: items)
        }
    }
}

private struct AppleAccountLoadedAppListView: View {
    let items: [AppleAccountAppItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                AppleAccountAppRowView(item: item)
                if item.id != items.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .sealContentCard(.prominent)
    }
}

private struct AppleAccountAppRowView: View {
    let item: AppleAccountAppItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)
                .singleLine()
                .truncationMode(.tail)
                .textSelection(.enabled)
            accountDetailRow("App ID", item.appIdentifier)
            accountDetailRow("Bundle ID", item.bundleIdentifier, monospaced: true)
            accountDetailRow(
                "有效期至",
                item.expirationText,
                valueColor: AppleAccountAppNamePolicy.shouldHighlightExpiration(item.expiryDate, now: Date())
                    ? .sealDanger
                    : .sealTextSecondary
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    private func accountDetailRow(
        _ title: String,
        _ value: String,
        monospaced: Bool = false,
        valueColor: Color = .sealTextSecondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(valueColor)
                .singleLine()
                .truncationMode(monospaced ? .middle : .tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

extension AppleAccountAppListView {
    /// 名额卡骨架：与 `appIDQuotaCard` 同版式（标题行＋说明行）。
    private var skeletonQuotaCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SealSkeletonBar(width: 96, height: 16)
                Spacer(minLength: 8)
                SealSkeletonBar(width: 84, height: 16)
            }
            SealSkeletonBar(width: 220, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    /// 列表骨架：3 行 ×（名称灰块＋3 条明细灰块），与已加载列表同版式。
    private var skeletonAppList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    SealSkeletonBar(width: 150, height: 13)
                    SealSkeletonDetailRow(labelWidth: 48, valueWidth: 170)
                    SealSkeletonDetailRow(labelWidth: 64, valueWidth: 140)
                    SealSkeletonDetailRow(labelWidth: 56, valueWidth: 110)
                }
                .padding(.vertical, 12)
                if index < 2 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .sealContentCard(.prominent)
    }
}

private struct AppleAccountFailureCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("同步失败")
                .font(.headline)
                .foregroundStyle(Color.sealDanger)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("重新同步", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .sealContentCard(.prominent)
    }
}

private struct AppleAccountAppItem: Identifiable, Equatable {
    let id: String
    let appIdentifier: String
    let name: String
    let bundleIdentifier: String
    let expiryDate: Date?

    init(
        snapshot: ApplePortalAppIDSnapshot,
        accountID: UUID,
        relatedApps: [AppRecord],
        accountTeamID: String? = nil,
        knownAccountIDs: Set<UUID>? = nil
    ) {
        id = snapshot.id
        appIdentifier = AppleAccountAppNamePolicy.applicationIdentifier(
            for: snapshot.bundleIdentifier,
            accountID: accountID,
            relatedApps: relatedApps,
            fallbackAppleAppID: snapshot.identifier,
            accountTeamID: accountTeamID,
            knownAccountIDs: knownAccountIDs
        )
        name = AppleAccountAppNamePolicy.displayName(
            for: snapshot.bundleIdentifier,
            accountID: accountID,
            relatedApps: relatedApps,
            fallbackAppleName: snapshot.name,
            accountTeamID: accountTeamID,
            knownAccountIDs: knownAccountIDs
        )
        bundleIdentifier = snapshot.bundleIdentifier
        expiryDate = AppleAccountAppNamePolicy.expirationDate(
            for: snapshot.bundleIdentifier,
            snapshot: snapshot,
            accountID: accountID,
            relatedApps: relatedApps,
            accountTeamID: accountTeamID,
            knownAccountIDs: knownAccountIDs
        )
    }

    var expirationText: String {
        expiryDate.map(SealSettingsDateFormatter.stringWithoutSeconds(from:)) ?? "Apple 未提供"
    }
}

enum AppleAccountAppNamePolicy {
    static func expirationComesBefore(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case let (first?, second?): first < second
        case (_?, nil): true
        default: false
        }
    }

    static func shouldHighlightExpiration(_ expirationDate: Date?, now: Date) -> Bool {
        guard let expirationDate else { return false }
        return expirationDate.timeIntervalSince(now) <= 86_400
    }

    /// 悬空 `accountID` 陷阱家族（仓库 AGENTS.md）：删 Apple ID 再重新添加会
    /// 新建账号记录（新 UUID），而 `deleteAccount` 刻意保留应用绑定，旧 UUID
    /// 不是 `nil`、裸相等恒为假。本页四处富化判据此前全是裸 `accountID`
    /// 相等，悬空后名称 / App ID / 到期时间的本地富化全部落空。
    ///
    /// 与 `SigningCertificateSelectionPolicy.validateAccountAndTeam` 同口径分流：
    /// - 绑定账号**仍在**账号库 ⇒ 真的用了别的账号，不放行（保护不丢）；
    ///   未提供账号库快照（`knownAccountIDs == nil`）时按「仍在」处理，保持旧行为；
    /// - 绑定账号**已悬空**、或记录**从未绑定** ⇒ 改按签名 Team 判据：
    ///   `signingTeamID` 或任一 signingTarget 的 `teamIdentifier` 与账号
    ///   Team 大小写不敏感相等（且 Team 非空）才放行，换 Team 不放行。
    static func isAccountMatch(
        _ app: AppRecord,
        accountID: UUID,
        accountTeamID: String?,
        knownAccountIDs: Set<UUID>?
    ) -> Bool {
        if app.accountID == accountID { return true }
        if let boundAccountID = app.accountID {
            guard let knownAccountIDs,
                  knownAccountIDs.contains(boundAccountID) == false else { return false }
        }
        guard let teamID = accountTeamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              teamID.isEmpty == false else { return false }
        if let signingTeamID = app.signingTeamID?.trimmingCharacters(in: .whitespacesAndNewlines),
           signingTeamID.caseInsensitiveCompare(teamID) == .orderedSame {
            return true
        }
        return app.signingTargets.contains {
            $0.teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(teamID) == .orderedSame
        }
    }

    static func name(
        for bundleIdentifier: String,
        accountID: UUID,
        relatedApps: [AppRecord],
        accountTeamID: String? = nil,
        knownAccountIDs: Set<UUID>? = nil
    ) -> String {
        displayName(
            for: bundleIdentifier,
            accountID: accountID,
            relatedApps: relatedApps,
            accountTeamID: accountTeamID,
            knownAccountIDs: knownAccountIDs
        )
    }

    static func displayName(
        for bundleIdentifier: String,
        accountID: UUID,
        relatedApps: [AppRecord],
        fallbackAppleName: String? = nil,
        accountTeamID: String? = nil,
        knownAccountIDs: Set<UUID>? = nil
    ) -> String {
        let target = normalize(bundleIdentifier)
        guard target.isEmpty == false else { return nonBlank(fallbackAppleName) ?? "App 名称未记录" }

        let matchingApp = relatedApps.first { app in
            guard isAccountMatch(app, accountID: accountID, accountTeamID: accountTeamID, knownAccountIDs: knownAccountIDs) else { return false }
            let identifiers: [String] = [
                app.originalBundleIdentifier,
                app.mappedBundleIdentifier ?? "",
                app.preferredBundleIdentifier ?? ""
            ] + app.signingTargets.map(\.bundleIdentifier)
                + app.extensions.flatMap { [$0.originalBundleIdentifier, $0.mappedBundleIdentifier ?? ""] }
            return identifiers.contains { normalize($0) == target }
        }
        let appName = matchingApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if appName.isEmpty == false, let matchingApp {
            let isExtension = matchingApp.extensions.contains { ext in
                normalize(ext.originalBundleIdentifier) == target
                    || normalize(ext.mappedBundleIdentifier ?? "") == target
            }
            return isExtension ? "\(appName) · 扩展" : appName
        }
        return nonBlank(fallbackAppleName) ?? "App 名称未记录"
    }

    static func applicationIdentifier(
        for bundleIdentifier: String,
        accountID: UUID,
        relatedApps: [AppRecord],
        fallbackAppleAppID: String? = nil,
        accountTeamID: String? = nil,
        knownAccountIDs: Set<UUID>? = nil
    ) -> String {
        let target = normalize(bundleIdentifier)
        guard let value = relatedApps
            .filter({ isAccountMatch($0, accountID: accountID, accountTeamID: accountTeamID, knownAccountIDs: knownAccountIDs) })
            .lazy
            .flatMap(\.signingTargets)
            .first(where: { normalize($0.bundleIdentifier) == target })?
            .applicationIdentifier,
              value.isEmpty == false,
              value.contains("*") == false else {
            return nonBlank(fallbackAppleAppID) ?? "未记录"
        }
        return value
    }

    static func expirationDate(
        for bundleIdentifier: String,
        snapshot: ApplePortalAppIDSnapshot,
        accountID: UUID,
        relatedApps: [AppRecord],
        accountTeamID: String? = nil,
        knownAccountIDs: Set<UUID>? = nil
    ) -> Date? {
        let target = normalize(bundleIdentifier)
        if let exactTarget = relatedApps
            .filter({ isAccountMatch($0, accountID: accountID, accountTeamID: accountTeamID, knownAccountIDs: knownAccountIDs) })
            .lazy
            .flatMap(\.signingTargets)
            .first(where: { normalize($0.bundleIdentifier) == target }) {
            return exactTarget.profileExpirationDate
        }

        for app in relatedApps where isAccountMatch(app, accountID: accountID, accountTeamID: accountTeamID, knownAccountIDs: knownAccountIDs) {
            if normalize(app.mappedBundleIdentifier ?? "") == target
                || normalize(app.originalBundleIdentifier) == target {
                if let expiry = app.provisioningProfileExpirationDate ?? app.expiryDate {
                    return expiry
                }
            }
            if let ext = app.extensions.first(where: {
                normalize($0.mappedBundleIdentifier ?? $0.originalBundleIdentifier) == target
            }), let expiry = ext.provisioningProfileExpirationDate {
                return expiry
            }
        }
        return snapshot.provisioningProfileExpirationDate ?? snapshot.appIDExpirationDate
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
