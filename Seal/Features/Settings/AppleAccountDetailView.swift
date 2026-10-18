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
            visibleAppIDCount: inventory?.usedBundleIDCount ?? 0,
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
            (snapshot.appIDExpirationDate ?? .distantPast) > now
        }
        let items = snapshots.map { snapshot in
            AppleAccountAppItem(
                snapshot: snapshot,
                accountID: currentAccount.id,
                relatedApps: relatedApps
            )
        }
        return items.sorted { first, second in
            first.name.localizedStandardCompare(second.name) == .orderedAscending
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
    let visibleAppIDCount: Int
    let onRetry: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if case .loading = state {
                    EmptyView()
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
                Text("Apple 返回的可新建额度")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let available = quota?.availableQuantity, available >= 0 {
                    Text("\(available) 个")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.sealAccent)
                } else {
                    Text("未提供")
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
            Text("Apple 列表返回 \(quota?.returnedCount ?? visibleAppIDCount) 项，当前有效 \(visibleAppIDCount) 个\(quota?.maxQuantity.map { " · Apple 返回上限 \($0) 个" } ?? "")。列表数量与可新建额度不同。")
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
            AppleAccountLoadingCard(title: "正在读取 App ID")
        case .failure(let message):
            AppleAccountFailureCard(message: message, onRetry: onRetry)
        case .empty:
            AppleAccountEmptyCard(
                icon: "app.dashed",
                title: "暂无签名应用",
                subtitle: "这个 Apple ID 还没有签名过任何应用。"
            )
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
            accountDetailRow("应用名称", item.name, emphasis: true)
            accountDetailRow("App ID", item.appIdentifier)
            accountDetailRow("Bundle ID", item.bundleIdentifier, monospaced: true)
            accountDetailRow("有效期至", item.expirationText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    private func accountDetailRow(
        _ title: String,
        _ value: String,
        emphasis: Bool = false,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .fontWeight(emphasis ? .semibold : .regular)
                .foregroundStyle(emphasis ? Color.primary : Color.sealTextSecondary)
                .lineLimit(1)
                .truncationMode(monospaced ? .middle : .tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct AppleAccountLoadingCard: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(title)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
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

private struct AppleAccountEmptyCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Color.sealTextSecondary)

            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .sealContentCard(.prominent)
    }
}

private struct AppleAccountAppItem: Identifiable, Equatable {
    let id: String
    let appIdentifier: String
    let name: String
    let bundleIdentifier: String
    let expiryDate: Date?

    init(snapshot: ApplePortalAppIDSnapshot, accountID: UUID, relatedApps: [AppRecord]) {
        id = snapshot.id
        appIdentifier = AppleAccountAppNamePolicy.applicationIdentifier(
            for: snapshot.bundleIdentifier,
            accountID: accountID,
            relatedApps: relatedApps
        )
        name = AppleAccountAppNamePolicy.displayName(
            for: snapshot.bundleIdentifier,
            accountID: accountID,
            relatedApps: relatedApps
        )
        bundleIdentifier = snapshot.bundleIdentifier
        expiryDate = AppleAccountAppNamePolicy.expirationDate(
            for: snapshot.bundleIdentifier,
            snapshot: snapshot,
            accountID: accountID,
            relatedApps: relatedApps
        )
    }

    var expirationText: String {
        expiryDate.map(SealSettingsDateFormatter.string(from:)) ?? "未记录"
    }
}

enum AppleAccountAppNamePolicy {
    static func name(for bundleIdentifier: String, accountID: UUID, relatedApps: [AppRecord]) -> String {
        displayName(for: bundleIdentifier, accountID: accountID, relatedApps: relatedApps)
    }

    static func displayName(for bundleIdentifier: String, accountID: UUID, relatedApps: [AppRecord]) -> String {
        let target = normalize(bundleIdentifier)
        guard target.isEmpty == false else { return "App 名称未记录" }

        let matchingApp = relatedApps.first { app in
            guard app.accountID == accountID else { return false }
            let identifiers: [String] = [
                app.originalBundleIdentifier,
                app.mappedBundleIdentifier ?? "",
                app.preferredBundleIdentifier ?? ""
            ] + app.signingTargets.map(\.bundleIdentifier)
                + app.extensions.flatMap { [$0.originalBundleIdentifier, $0.mappedBundleIdentifier ?? ""] }
            return identifiers.contains { normalize($0) == target }
        }
        let appName = matchingApp?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard appName.isEmpty == false, let matchingApp else { return "App 名称未记录" }
        let isExtension = matchingApp.extensions.contains { ext in
            normalize(ext.originalBundleIdentifier) == target
                || normalize(ext.mappedBundleIdentifier ?? "") == target
        }
        return isExtension ? "\(appName) · 扩展" : appName
    }

    static func applicationIdentifier(for bundleIdentifier: String, accountID: UUID, relatedApps: [AppRecord]) -> String {
        let target = normalize(bundleIdentifier)
        guard let value = relatedApps
            .filter({ $0.accountID == accountID })
            .lazy
            .flatMap(\.signingTargets)
            .first(where: { normalize($0.bundleIdentifier) == target })?
            .applicationIdentifier,
              value.isEmpty == false,
              value.contains("*") == false else {
            return "未记录"
        }
        return value
    }

    static func expirationDate(
        for bundleIdentifier: String,
        snapshot: ApplePortalAppIDSnapshot,
        accountID: UUID,
        relatedApps: [AppRecord]
    ) -> Date? {
        let target = normalize(bundleIdentifier)
        if let exactTarget = relatedApps
            .filter({ $0.accountID == accountID })
            .lazy
            .flatMap(\.signingTargets)
            .first(where: { normalize($0.bundleIdentifier) == target }) {
            return exactTarget.profileExpirationDate
        }

        for app in relatedApps where app.accountID == accountID {
            if normalize(app.mappedBundleIdentifier ?? "") == target
                || normalize(app.originalBundleIdentifier) == target {
                return app.provisioningProfileExpirationDate ?? app.expiryDate
            }
            if let ext = app.extensions.first(where: {
                normalize($0.mappedBundleIdentifier ?? $0.originalBundleIdentifier) == target
            }), let expiry = ext.provisioningProfileExpirationDate {
                return expiry
            }
        }
        return snapshot.provisioningProfileExpirationDate
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
