import SwiftUI
import UIKit
import PhotosUI

struct ImportConfirmationView: View {
    let draft: ImportDraft
    /// 检测到「已安装的同身份记录」时非空 ⇒ 本次可以走**覆盖更新**。
    /// 覆盖更新会替换那条记录及其 IPA，是破坏性操作 ⇒ 由用户在这里显式选择。
    let replacementCandidate: AppRecord?
    let isCommitting: Bool
    let failure: ImportFailure?
    let onCancel: () -> Void
    let onDismissProgress: () -> Void
    let onPrimaryAction: () -> Void
    /// 「新建副本（不覆盖）」：放弃覆盖更新，按原行为新建一条待签名记录。
    let onCreateCopy: () -> Void
    /// 用户选的自定义图标（nil = 使用原图）。
    let onIconSelected: (Data?) -> Void
    /// 用户改的自定义名称（nil = 使用原名）。
    let onNameSelected: (String?) -> Void

    @State private var didTapPrimaryAction = false
    @State private var showDowngradeConfirm = false
    @State private var isIconActionsPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var customIconData: Data?
    @State private var customDisplayName: String?
    @State private var isNameEditorPresented = false

    private var showsProgress: Bool {
        isCommitting || didTapPrimaryAction
    }

    private var isOverwriteUpdate: Bool {
        failure == nil && replacementCandidate != nil
    }

    private var isSealUpdate: Bool {
        isOverwriteUpdate && targetsSealUpdate
    }

    private var targetsSealUpdate: Bool {
        replacementCandidate?.isSeal == true
    }

    private var isVersionUnrecognized: Bool {
        if case .unreadableVersion = draft.versionCheck { return true }
        return false
    }

    private var isDowngrade: Bool {
        switch draft.versionCheck {
        case .downgrade, .buildDowngrade: true
        default: false
        }
    }

    var body: some View {
        SealDrawer(title: drawerTitle) {
            VStack(spacing: 14) {
                header
                if let failure {
                    failureCard(failure)
                } else {
                    summaryCard
                }
            }
            .padding(.bottom, 12)
        } footer: {
            if isVersionUnrecognized {
                Button("关闭", action: onCancel)
                    .sealPrimaryAction(cornerRadius: 14)
            } else {
                VStack(spacing: 10) {
                    Button {
                        guard showsProgress == false else { return }
                        // 版本检查：根据结果决定是否直接导入还是弹确认
                        switch draft.versionCheck {
                        case .alreadyLatest, .unreadableVersion:
                            // 已是最新，不允许导入（按钮已禁用，这里兜底）
                            return
                        case .downgrade, .buildDowngrade:
                            if isSealUpdate {
                                didTapPrimaryAction = true
                                onPrimaryAction()
                            } else {
                                showDowngradeConfirm = true
                            }
                        case .upgrade, .buildUpgrade, .missingInstalledVersion, .sameVersionRecovery, .newApp:
                            didTapPrimaryAction = true
                            onPrimaryAction()
                        }
                    } label: {
                        if showsProgress {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(isSealUpdate ? "正在准备更新" : "正在导入")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text(primaryActionTitle)
                        }
                    }
                    .sealPrimaryAction(cornerRadius: 14)
                    .disabled(showsProgress)
                    .accessibilityIdentifier("import-confirmation-primary")

                    if isOverwriteUpdate, isSealUpdate == false, isVersionUnrecognized == false {
                        Button("新建副本（不覆盖）", action: onCreateCopy)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundColor(Color.sealAccent)
                            .disabled(showsProgress)
                            .accessibilityIdentifier("import-confirmation-new-copy")
                    }

                    if isCommitting {
                        Button("收起并继续", action: onDismissProgress)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundColor(Color.sealTextSecondary)
                            .accessibilityIdentifier("import-confirmation-dismiss-progress")
                    } else {
                        Button(isSealUpdate || targetsSealUpdate ? "暂不更新" : "取消导入", action: onCancel)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundColor(Color.sealTextSecondary)
                    }
                }
            }
        }
        .interactiveDismissDisabled(showsProgress)
        .accessibilityIdentifier("import-confirmation")
        // 降级警告
        .alert(isSealUpdate ? "确认降级" : "确定要降级吗？", isPresented: $showDowngradeConfirm) {
            Button("取消", role: .cancel) {}
            Button(isSealUpdate ? "确认降级并继续" : "继续降级", role: .destructive) {
                didTapPrimaryAction = true
                onPrimaryAction()
            }
        } message: {
            switch draft.versionCheck {
            case .downgrade(let oldVersion, let newVersion):
                Text("当前已安装 \(oldVersion)，新包是旧版本 \(newVersion)，降级可能导致数据丢失。")
            case .buildDowngrade(_, _, _):
                Text("当前与新包版本号相同，但新包构建较旧，降级可能导致数据丢失。")
            default:
                Text("降级可能导致数据丢失。")
            }
        }
        .onChange(of: isCommitting) { newValue in
            if newValue == false { didTapPrimaryAction = false }
        }
        .onChange(of: failure?.code) { _ in
            didTapPrimaryAction = false
        }
    }

    private var drawerTitle: String {
        if failure != nil { return targetsSealUpdate ? "更新未完成" : "导入失败" }
        if isVersionUnrecognized { return "无法确认版本" }
        if isSealUpdate { return isDowngrade ? "确认降级" : "确认更新" }
        return isOverwriteUpdate ? "覆盖更新" : "导入 IPA"
    }

    private var primaryActionTitle: String {
        if let recovery = failure?.recovery { return recovery }
        if isSealUpdate { return isDowngrade ? "确认降级并继续" : "确认并继续" }
        if isOverwriteUpdate {
            switch draft.versionCheck {
            case .downgrade, .buildDowngrade:
                return "继续降级"
            default:
                return "覆盖更新"
            }
        }
        return "导入应用"
    }

    private var header: some View {
        HStack(spacing: 14) {
            appIcon
            VStack(alignment: .leading, spacing: 5) {
                Text(customDisplayName ?? draft.parsedIPA.name)
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityIdentifier("import-confirmation-name")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("v\(draft.parsedIPA.version) · \(formattedSize)")
                    .font(.system(size: 13, weight: .regular))
                    .accessibilityIdentifier("import-confirmation-version")
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        if isVersionUnrecognized {
            unrecognizedVersionSummaryCard
        } else if isSealUpdate {
            sealUpdateSummaryCard
        } else {
            standardSummaryCard
        }
    }

    private var unrecognizedVersionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("无法比较版本变化")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text("IPA 版本号无法识别，本次不会覆盖已安装应用")
                .font(.system(size: 13))
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private var sealUpdateSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow("版本变化", sealVersionChange)
                .accessibilityIdentifier("import-summary-version-change")
            Divider().padding(.leading, 14)
            Text("确认后进入签名安装\n安装成功后替换当前 Seal")
                .font(.system(size: 13))
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private var standardSummaryCard: some View {
        VStack(spacing: 0) {
            summaryRow("状态", migrationSummary)
                .accessibilityIdentifier("import-summary-compatibility")
                .accessibilityValue(migrationSummary)
            Divider().padding(.leading, 14)
            Button {
                isNameEditorPresented = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("App 名称")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 96, alignment: .leading)
                    Spacer(minLength: 12)
                    Text(customDisplayName ?? "使用原名")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color.sealTextSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import-summary-name")
            Divider().padding(.leading, 14)
            Button {
                isIconActionsPresented = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("App 图标")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 96, alignment: .leading)
                    Spacer(minLength: 12)
                    Text(customIconData == nil ? "使用原图" : "已自定义")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.sealTextSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color.sealTextSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import-summary-icon")
            Divider().padding(.leading, 14)
            summaryRow("Bundle ID", draft.parsedIPA.bundleIdentifier, monospaced: true)
                .accessibilityIdentifier("import-summary-bundle-id")
                .accessibilityValue(draft.parsedIPA.bundleIdentifier)
            Divider().padding(.leading, 14)
            summaryRow("扩展", extensionSummary)
                .accessibilityIdentifier("import-summary-extensions")
                .accessibilityValue(extensionSummary)
            Divider().padding(.leading, 14)
            if replacementCandidate != nil {
                summaryRow("版本变化", overwriteSummary)
                    .accessibilityIdentifier("import-summary-overwrite")
                    .accessibilityValue(overwriteSummary)
                Divider().padding(.leading, 14)
            }
        }
        .padding(.horizontal, 16)
        .sealContentCard(.compact)
        .sheet(isPresented: $isIconActionsPresented) {
            AppIconSelectionSheet { action in
                isIconActionsPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    switch action {
                    case .photos:
                        isPhotoPickerPresented = true
                    case .files:
                        // 导入抽屉里暂只支持相册，文件入口在签名页
                        isPhotoPickerPresented = true
                    case .original:
                        customIconData = nil
                        onIconSelected(nil)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isNameEditorPresented) {
            AppNameEditorSheet(initialValue: customDisplayName ?? draft.parsedIPA.name) { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == draft.parsedIPA.name {
                    customDisplayName = nil
                    onNameSelected(nil)
                } else {
                    customDisplayName = trimmed
                    onNameSelected(trimmed)
                }
                return true
            }
            .presentationDetents([.medium, .large])
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            Task {
                defer { selectedPhotoItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await MainActor.run {
                    customIconData = data
                    onIconSelected(data)
                }
            }
        }
    }

    private var overwriteSummary: String {
        switch draft.versionCheck {
        case .buildUpgrade(_, _, let version):
            return "同版本更新 · v\(version)"
        case .buildDowngrade(_, _, let version):
            return "同版本降级 · v\(version)"
        case .missingInstalledVersion(let version):
            return "旧版本未记录 · v\(version)"
        case .sameVersionRecovery(let version):
            return "源 IPA 缺失 · 重新导入 v\(version)"
        case .unreadableVersion:
            return "无法比较版本变化"
        case .upgrade(let oldVersion, let newVersion), .downgrade(let oldVersion, let newVersion):
            return "v\(oldVersion) → v\(newVersion)"
        case .alreadyLatest(let version):
            return "已是最新版 · v\(version)"
        case .newApp:
            return "v\(draft.parsedIPA.version)"
        }
    }

    private var sealVersionChange: String {
        switch draft.versionCheck {
        case .buildUpgrade(_, _, let version):
            return "同版本更新 · v\(version)"
        case .buildDowngrade(_, _, let version):
            return "同版本降级 · v\(version)"
        case .missingInstalledVersion(let version):
            return "旧版本未记录 · v\(version)"
        case .sameVersionRecovery(let version):
            return "源 IPA 缺失 · 重新导入 v\(version)"
        case .alreadyLatest(let version):
            return "已是最新版 · v\(version)"
        case .upgrade(let oldVersion, let newVersion), .downgrade(let oldVersion, let newVersion):
            return "v\(oldVersion) → v\(newVersion)"
        case .newApp:
            return "v\(draft.parsedIPA.version)"
        case .unreadableVersion:
            return "无法比较版本变化"
        }
    }

    private func summaryRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .regular, design: monospaced ? .monospaced : .default))
                .foregroundColor(Color.sealTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func failureCard(_ failure: ImportFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.sealWarning)
            Text(failure.userMessage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if failure.recovery.isEmpty == false {
                Text(failure.recovery)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .sealContentCard(.compact)
    }

    @ViewBuilder private var appIcon: some View {
        Group {
            if let data = customIconData ?? draft.parsedIPA.iconData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurface)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: draft.parsedIPA.fileSize, countStyle: .file)
    }

    private var extensionSummary: String {
        draft.parsedIPA.extensions.isEmpty ? "无" : "\(draft.parsedIPA.extensions.count) 个"
    }

    private var migrationSummary: String {
        isOverwriteUpdate ? "将替换已安装的应用" : "可导入"
    }
}
