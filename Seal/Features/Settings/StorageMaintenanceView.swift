import SwiftUI

struct StorageMaintenanceView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var confirmsTemporaryClear = false
    @State private var confirmsUnusedClear = false
    @State private var confirmsSignedPackageClear = false
    /// 首轮统计是否已跑完。`storageUsage` 初始是全 0 的 `.empty`，
    /// 首轮跑完前直接渲染会先显一轮「0 KB」假值再跳变 —— 用骨架挡住这段。
    /// 后续下拉刷新不重置它，沿用旧值，不闪骨架。
    @State private var storageLoaded = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                if storageLoaded {
                    summaryCard
                    usageCard
                } else {
                    skeletonSummaryCard
                    skeletonUsageCard
                }
                if hasMaintenanceActions {
                    actionCard
                }
                dangerNote
            }
            .padding(20)
        }
        .navigationTitle("存储与维护")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.refreshStorageUsage()
            storageLoaded = true
        }
        .refreshable { await viewModel.refreshStorageUsage() }
        .confirmationDialog(
            "清理临时缓存？",
            isPresented: $confirmsTemporaryClear,
            titleVisibility: .visible
        ) {
            Button("清理临时缓存", role: .destructive) {
                Task { await viewModel.clearTemporaryFiles() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除签名时的临时文件、导入缓存和失败残留。")
        }
        .confirmationDialog(
            "清理未使用文件？",
            isPresented: $confirmsUnusedClear,
            titleVisibility: .visible
        ) {
            Button("清理未使用文件", role: .destructive) {
                Task { await viewModel.clearUnusedStorageFiles() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清理临时缓存和不再使用的多余文件。已安装 App 的签名缓存、账号密码和设备配对信息不会删除。")
        }
        .confirmationDialog(
            "释放可重建安装缓存？",
            isPresented: $confirmsSignedPackageClear,
            titleVisibility: .visible
        ) {
            Button("释放可重建安装缓存", role: .destructive) {
                Task { await viewModel.clearStoredSignedPackages() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除已确认安装完成的 Signed.ipa 缓存。手机上的 App、原始 IPA、续签身份、描述文件、账号和设备配对信息均会保留；后续只更新描述文件不受影响。")
        }
        .sealScreenBackground()
    }

    private var summaryCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.sealAccent)
            Text(viewModel.storageUsage.total.sealFormattedByteCount)
                .font(.title2.weight(.semibold))
            Text("Seal 当前占用")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .sealContentCard(.prominent)
    }

    /// 汇总骨架：与 `summaryCard` 同版式（图标位＋大数字＋说明行）。
    private var skeletonSummaryCard: some View {
        VStack(spacing: 10) {
            SealSkeletonBar(width: 48, height: 48)
            SealSkeletonBar(width: 120, height: 28)
            SealSkeletonBar(width: 96, height: 16)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .sealContentCard(.prominent)
    }

    /// 明细骨架：6 行 ×（左名右值），与 `usageCard` 同版式。
    private var skeletonUsageCard: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                HStack {
                    SealSkeletonBar(width: 96, height: 14)
                    Spacer()
                    SealSkeletonBar(width: 72, height: 14)
                }
                .frame(minHeight: 54)
                if index < 5 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
        .sealContentCard(.standard)
    }

    private var usageCard: some View {
        VStack(spacing: 0) {
            usageRow("导入的 IPA", viewModel.storageUsage.originalIPAs)
            Divider()
            usageRow("签名缓存", viewModel.storageUsage.signedIPAs)
            Divider()
            usageRow("图标文件", viewModel.storageUsage.iconFiles)
            Divider()
            usageRow("本地记录", viewModel.storageUsage.records)
            Divider()
            usageRow("临时缓存", viewModel.storageUsage.temporary)
            Divider()
            usageRow("多余文件", viewModel.storageUsage.orphaned)
        }
        .padding(.horizontal, 16)
        .sealContentCard(.standard)
    }

    private var actionCard: some View {
        VStack(spacing: 12) {
            if viewModel.storageUsage.temporary > 0 {
                Button("清理临时缓存") { confirmsTemporaryClear = true }
                    .sealPrimaryAction(cornerRadius: 12)
            }
            if viewModel.reclaimableSignedIPACacheCount > 0 {
                Button("释放可重建安装缓存") { confirmsSignedPackageClear = true }
                    .sealOutlineAction(cornerRadius: 12)
            }
            if viewModel.storageUsage.temporary + viewModel.storageUsage.orphaned > 0 {
                Button("清理未使用文件") { confirmsUnusedClear = true }
                    .sealOutlineAction(cornerRadius: 12)
            }
        }
    }

    private var hasMaintenanceActions: Bool {
        viewModel.storageUsage.temporary > 0
            || viewModel.storageUsage.orphaned > 0
            || viewModel.reclaimableSignedIPACacheCount > 0
    }

    private var dangerNote: some View {
        Text(viewModel.storageMaintenanceSummary ?? "缓存和签名包可清理；账号、证书与配对信息会保留。")
            .font(.footnote)
            .foregroundStyle(Color.sealTextSecondary)
            .singleLine()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .sealContentCard(.compact)
    }

    private func usageRow(_ title: String, _ value: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.sealFormattedByteCount)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .frame(minHeight: 54)
    }
}
