import SwiftUI
import UIKit

struct CertificatesRootView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]

    @State private var isAddingAccount = false
    @State private var detailAccount: AppleAccountRecord?
    @State private var accountPendingDeletion: AppleAccountRecord?
    /// 删除账号成功震动触发器（计数递增即震一次）。
    @State private var deleteSuccessTrigger = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.accounts.isEmpty {
                    emptyState
                } else {
                    accountsList
                }
            }
            .padding(20)
        }
        .navigationTitle("Apple ID 证书")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: deleteSuccessTrigger)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { isAddingAccount = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fullScreenCover(isPresented: $isAddingAccount) {
            AddAccountView(viewModel: viewModel)
        }
        .confirmationDialog(
            "删除 Apple ID？",
            isPresented: Binding(
                get: { accountPendingDeletion != nil },
                set: { if !$0 { accountPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: accountPendingDeletion
        ) { account in
            Button("删除账号", role: .destructive) {
                accountPendingDeletion = nil
                Task {
                    await viewModel.deleteAccount(account)
                    // 账号已不在库＝删除成功，给一下轻反馈；失败走失败提示，不震。
                    if viewModel.accounts.contains(where: { $0.id == account.id }) == false {
                        deleteSuccessTrigger += 1
                    }
                }
            }
            Button("取消", role: .cancel) { accountPendingDeletion = nil }
        } message: { account in
            // 悬空 accountID 陷阱家族（见仓库 AGENTS.md）：`deleteAccount` 刻意保留
            // 应用绑定，删过再重新添加同一 Apple ID 会新建账号记录（新 UUID），
            // 旧 UUID 不是 `nil`、裸相等恒为假 ⇒ 只按 UUID 数关联应用会算成 0，
            // 删除确认文案会误报「没有关联应用」。绑定账号已不在账号库时改按
            // 签名 Team 判据（与 `SigningCertificateSelectionPolicy` 的悬空放行
            // 口径一致）：同 Team 才算关联，换 Team 不算；绑定账号仍在时不放行。
            let knownAccountIDs = Set(viewModel.accounts.map(\.id))
            let count = relatedApps.filter { app in
                if app.accountID == account.id { return true }
                guard let boundAccountID = app.accountID,
                      knownAccountIDs.contains(boundAccountID) == false,
                      account.teamID.isEmpty == false else { return false }
                return app.signingTeamID?.caseInsensitiveCompare(account.teamID) == .orderedSame
                    || app.signingTargets.contains {
                        $0.teamIdentifier.caseInsensitiveCompare(account.teamID) == .orderedSame
                    }
            }.count
            // ⚠️ 必须说清「会一并清除本机签名凭据」：本机证书私钥就存在该账号的
            // Keychain 条目里（`AccountSecret.certificateP12BySerial`），删账号会把它们
            // 一起删掉。之后重新添加同一个 Apple ID 会拿到**新的账号标识**，读不回旧私钥
            // ⇒ 下一次续签只能撤销旧证书、另建新证书；而撤销会让所有用旧证书签名的
            // 已安装应用失效，于是**自动重签全部受影响应用**。
            // 真机 2026-09-25 构建 39 反馈「点一个应用续签，结果签了三个」正是这条链路 ——
            // 行为本身是必要的（不重签那些应用会打不开），但用户事先毫不知情。
            // ⚠️ 刻意用三元表达式、与既有写法同构：`message:` 闭包是 `@ViewBuilder`，
            // 结果构建器对「只含赋值语句的 if/else 分支」的解析与普通闭包不同，
            // 这里不值得为了排版去冒这个风险（本机无 Swift 工具链，编译只能等 CI）。
            Text(
                count == 0
                    ? "删除后会移除这个账号，并清除本机保存的账号密码。"
                    : "这个账号关联过 \(count) 个应用。删除不会卸载应用，"
                        + "但会清除本机保存的账号密码——之后重新添加同一个 Apple ID 时，"
                        + "需要换一张签名证书，这 \(count) 个应用会自动重新签名安装一次。"
            )
        }
        .navigationDestination(
            isPresented: Binding(
                get: { detailAccount != nil },
                set: { if !$0 { detailAccount = nil } }
            )
        ) {
            if let account = detailAccount {
                AppleAccountDetailView(
                    account: account,
                    relatedApps: relatedApps,
                    viewModel: viewModel
                )
            }
        }
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .task {
            await viewModel.load()
            await viewModel.refreshApplePortalInventories()
        }
        .refreshable {
            await viewModel.load(force: true)
            await viewModel.refreshApplePortalInventories(force: true)
        }
        .onChange(of: viewModel.requestedRoute) { route in
            guard route == .addAccount else { return }
            viewModel.requestedRoute = nil
            isAddingAccount = true
        }
        .sealScreenBackground()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(Color.sealAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.accounts.isEmpty ? "添加 Apple ID" : "当前签名账号")
                    .font(.title3.weight(.semibold))
                Text(activeAccountSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
            }
            Spacer()
            Button { isAddingAccount = true } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.sealAccent.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .sealContentCard(.prominent)
    }

    private var activeAccountSubtitle: String {
        guard let account = viewModel.activeAccount else {
            return "选择一个已验证账号用于新的 IPA 签名"
        }
        return viewModel.fullEmail(for: account)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有 Apple ID", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("添加并验证 Apple ID 后即可签名、续签。")
                .font(.subheadline)
                .singleLine()
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .sealContentCard(.prominent)
    }

    private var accountsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.accounts.enumerated()), id: \.element.id) { index, account in
                accountRow(account)
                if index < viewModel.accounts.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.horizontal, 16)
        .sealContentCard(.prominent)
    }

    private func accountRow(_ account: AppleAccountRecord) -> some View {
        Button {
            detailAccount = account
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(viewModel.fullEmail(for: account))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .singleLine()
                    Spacer(minLength: 12)
                    Text(certificateStatusTitle(account))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(certificateStatusColor(account))
                        .singleLine()
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(accountDisplayName(account))
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                    Spacer(minLength: 12)
                    Text(appIDQuotaTitle(account))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        // 「暂未统计」→真值同位替换：数字滚动＋短淡入，不跳变。
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: appIDQuotaTitle(account))
                }
            }
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = viewModel.fullEmail(for: account)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label("复制邮箱", systemImage: "doc.on.doc")
            }
            Button("删除账号", role: .destructive) {
                accountPendingDeletion = account
            }
        }
    }

    private func isActive(_ account: AppleAccountRecord) -> Bool {
        viewModel.activeAccountID == account.id
    }

    private func accountDisplayName(_ account: AppleAccountRecord) -> String {
        let name = TeamNameDisplayFormatter.string(from: account.teamName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "名称未记录" : name
    }

    private func certificateStatusTitle(_ account: AppleAccountRecord) -> String {
        guard AccountAvailabilityPolicy.isSelectable(account) else { return "失效" }
        let serial = account.selectedCertificateSerialNumber ?? account.certificateSerialNumber
        guard let serial, serial.isEmpty == false else { return "未准备" }
        return "有效"
    }

    private func certificateStatusColor(_ account: AppleAccountRecord) -> Color {
        switch certificateStatusTitle(account) {
        case "有效":
            return Color.sealSuccess
        case "未准备":
            return Color.sealWarning
        default:
            return Color.sealDanger
        }
    }

    private func appIDQuotaTitle(_ account: AppleAccountRecord) -> String {
        if let inventory = viewModel.certificateInventory(for: account.id) {
            if let available = inventory.appIDQuota?.availableQuantity, available >= 0 {
                return "已注册 \(inventory.usedBundleIDCount) · 可新建 \(available)"
            }
            return "已注册 \(inventory.usedBundleIDCount) 个"
        }
        return "暂未统计"
    }
}
