import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PairingSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// 仅由安装/续签通道失败的恢复入口启用；正常进入设备页不额外打扰用户。
    let runsConnectionDiagnosticOnAppear: Bool
    @State private var isFileImporterPresented = false
    @State private var isPairingExportWarningPresented = false
    @State private var isPairingFileExporterPresented = false
    @State private var pairingExportDocument: PairingExportDocument?

    init(
        viewModel: SettingsViewModel,
        runsConnectionDiagnosticOnAppear: Bool = false
    ) {
        self.viewModel = viewModel
        self.runsConnectionDiagnosticOnAppear = runsConnectionDiagnosticOnAppear
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            if presentationPolicy.usesPhonePairing {
                phonePairingContent
            } else {
                VStack(spacing: 20) {
                    hero
                    if runsConnectionDiagnosticOnAppear {
                        connectionDiagnostic
                    }
                    if let pairing = viewModel.pairingRecord {
                        details(pairing)
                        if pairing.validationStatus == .fileUnreadable || pairing.validationStatus == .deviceMismatch {
                            acquisitionGuide
                        }
                    } else {
                        acquisitionGuide
                    }
                    actions
                }
                .padding(20)
            }
        }
        .navigationTitle("设备")
        .navigationBarTitleDisplayMode(.inline)
        // 配对终态轻反馈（2026-10-24 全 App 震动通道）：配对完成一下、失败一下。
        .sensoryFeedback(trigger: viewModel.phonePairingState) { _, new in
            if new == .completed { return .success }
            if case .failed = new { return .error }
            return nil
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [
                UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                .propertyList,
                .json,
                .data,
                .item
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await viewModel.importPairingFile(at: url) }
            case .failure:
                break
            }
        }
        .fileExporter(
            isPresented: $isPairingFileExporterPresented,
            document: pairingExportDocument,
            contentType: PairingExportDocument.contentType,
            defaultFilename: "Seal-Pairing.mobiledevicepairing"
        ) { result in
            pairingExportDocument = nil
            if case .failure(let error) = result,
               (error as NSError).code != NSUserCancelledError {
                viewModel.alertFailure = ImportFailure(
                    title: "无法导出配对文件",
                    reason: "文件没有保存成功：\(error.localizedDescription)",
                    recovery: "请更换保存位置后重试",
                    code: "SEAL-PAIR-306"
                )
            }
        }
        .confirmationDialog(
            "导出设备配对凭据？",
            isPresented: $isPairingExportWarningPresented,
            titleVisibility: .visible
        ) {
            Button("导出配对文件") {
                preparePairingFileExport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("配对文件含设备连接密钥，请妥善保存，勿发给他人或上传公共网盘。")
        }
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .sealScreenBackground()
        .task {
            if presentationPolicy.usesPhonePairing {
                await viewModel.refreshPhonePairingStatus()
            } else if presentationPolicy.showsDesktopAssistant {
                _ = await viewModel.importPairingAssistantInboxIfPresent()
                if runsConnectionDiagnosticOnAppear {
                    // 桌面配对助手仍沿用完整诊断；iPhone 配对页改用轻量通道探测。
                    await viewModel.testLocalDevVPN()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active,
                  presentationPolicy.usesPhonePairing,
                  viewModel.pairingRecord?.isPaired == true else { return }
            // 从 LocalDevVPN 切回 Seal 时再探一次；通道正常只更新内部结果，不改动页面文案。
            Task { await viewModel.refreshPhonePairingStatus() }
        }
    }

    private var connectionDiagnostic: some View {
        let presentation = connectionDiagnosticPresentation
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(presentation.color)
                    .frame(width: 28, height: 28)
                    // 诊断运行中：运行箭头轻呼吸，停住即不再是「正在跑」。
                    .symbolEffect(.pulse, isActive: viewModel.diagnosticState == .running)
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备连接诊断")
                        .font(.headline)
                        .singleLine()
                    Text(presentation.detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                        .singleLine()
                }
            }

            Text("设备与电脑需连接同一 Wi-Fi，并开启 LocalDevVPN。")
                .font(.footnote)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()

            if connectionDiagnosticFailed {
                Button("打开 LocalDevVPN") {
                    openURL(LocalDevVPNLink.enableAndReturn) { result in
                        if result == false {
                            openURL(LocalDevVPNLink.appStore)
                        }
                    }
                }
                .sealOutlineAction(cornerRadius: 12)
            }

            Button(connectionDiagnosticIsRunning ? "正在检测…" : "重新检测") {
                Task { await viewModel.testLocalDevVPN() }
            }
            .sealOutlineAction(cornerRadius: 12)
            .disabled(connectionDiagnosticIsRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .sealContentCard(.standard)
        .accessibilityElement(children: .combine)
    }

    private var connectionDiagnosticPresentation: (detail: String, icon: String, color: Color) {
        switch viewModel.diagnosticState {
        case .idle:
            return ("准备检查 LocalDevVPN、设备响应和安装通道。", "network", .sealAccent)
        case .running:
            return ("正在检查 LocalDevVPN、设备响应和安装通道。", "arrow.triangle.2.circlepath", .sealAccent)
        case .ready:
            return ("LocalDevVPN 与设备安装通道已连接。", "checkmark.circle.fill", .sealSuccess)
        case .failed(let failure):
            return (failure.userReason, "exclamationmark.triangle.fill", .sealDanger)
        }
    }

    private var connectionDiagnosticIsRunning: Bool {
        if case .running = viewModel.diagnosticState { return true }
        return false
    }

    private var connectionDiagnosticFailed: Bool {
        if case .failed(let failure) = viewModel.diagnosticState {
            return failure.action == .openLocalDevVPN
        }
        return false
    }

    private var presentationPolicy: PhonePairingPresentationPolicy {
        PhonePairingPresentationPolicy(
            majorOSVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    private var phonePairingContent: some View {
        VStack(spacing: 20) {
            phonePairingHero
            phonePairingProgress
            phonePairingDetails
            if case let .showingCode(code) = viewModel.phonePairingState {
                pairingCode(code)
            }
            phonePairingAction
        }
        .padding(20)
    }

    private var phonePairingHero: some View {
        let presentation = phonePresentation
        return VStack(spacing: 10) {
            Group {
                if presentation.icon == "custom.pairingCode" {
                    Image("PairingCodeIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                } else {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 42, weight: .medium))
                        // 配对等待态（准备／系统确认／验证中）：图标轻呼吸。
                        .symbolEffect(.pulse, isActive: isPhonePairingWaiting)
                }
            }
            .foregroundStyle(presentation.color)
            Text(presentation.title)
                .font(.title2.weight(.semibold))
            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .singleLine()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .sealContentCard(.prominent)
    }

    private var phonePairingProgress: some View {
        HStack(spacing: 8) {
            phoneStep("开发者模式", index: 0)
            phoneStep("设备配对", index: 1)
            phoneStep("LocalDevVPN", index: 2)
            phoneStep("完成", index: 3)
        }
    }

    private func phoneStep(_ title: String, index: Int) -> some View {
        let current = phoneProgressIndex
        return VStack(spacing: 8) {
            Capsule()
                .fill(index < current ? Color.sealSuccess : index == current ? Color.sealAccent : Color.sealHairline)
                .frame(height: 6)
            Text(title)
                .font(.caption.weight(index == current ? .semibold : .regular))
                .foregroundStyle(index <= current ? Color.primary : Color.sealTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
    }

    private var phonePairingDetails: some View {
        VStack(spacing: 0) {
            phoneDetailRow("设备配对", phonePairingStatusText)
            Divider()
            phoneDetailRow("LocalDevVPN", localDevVPNStatusText)
            if let pairing = viewModel.pairingRecord {
                Divider()
                phoneDetailRow("设备 UDID", deviceIdentifierText(pairing))
                    .sealCopyableIdentifier(deviceIdentifierText(pairing))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sealContentCard(.standard)
    }

    private func phoneDetailRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .singleLine()
                .truncationMode(.middle)
        }
        .font(.subheadline)
        .frame(minHeight: 50)
    }

    private func pairingCode(_ code: String) -> some View {
        VStack(spacing: 8) {
            Text("配对码")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .tracking(5)
            Text("在系统设置中确认此配对码")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .sealContentCard(.standard)
    }

    @ViewBuilder
    private var phonePairingAction: some View {
        if hasStablePairing {
            if viewModel.phoneTunnelStatus == .unavailable {
                Button("重新检查") {
                    Task { await viewModel.validatePhonePairing() }
                }
                .sealPrimaryAction(cornerRadius: 12)
            }

            Button("重新配对") {
                Task { await viewModel.startPhonePairing() }
            }
            .sealOutlineAction(cornerRadius: 12)
        } else {
            switch viewModel.phonePairingState {
            case .idle:
                Button("开始设备配对") {
                    Task { await viewModel.startPhonePairing() }
                }
                .sealPrimaryAction(cornerRadius: 12)
            case .waitingForLocalDevVPN:
                Button("检查连接") {
                    Task { await viewModel.validatePhonePairing() }
                }
                .sealPrimaryAction(cornerRadius: 12)
            case .completed:
                Button("重新配对") {
                    Task { await viewModel.startPhonePairing() }
                }
                .sealOutlineAction(cornerRadius: 12)
            case .failed:
                Button("重新配对") {
                    Task { await viewModel.startPhonePairing() }
                }
                .sealPrimaryAction(cornerRadius: 12)
            case .requestingLocalNetwork, .waitingForSystemConfirmation, .showingCode:
                Button(viewModel.isCancellingPhonePairing ? "正在取消…" : "取消配对") {
                    viewModel.cancelPhonePairing()
                }
                .sealOutlineAction(cornerRadius: 12)
                .disabled(viewModel.isCancellingPhonePairing)
            case .validating:
                Button(phonePresentation.actionTitle) {}
                    .sealPrimaryAction(cornerRadius: 12)
                    .disabled(true)
            }
        }
    }

    private var phonePresentation: (title: String, detail: String, icon: String, color: Color, actionTitle: String) {
        // 配对已完成后，LocalDevVPN 的实时核验只更新下方状态行；不改动成功横幅。
        if hasStablePairing {
            let detail: String
            if viewModel.phoneTunnelStatus == .unavailable {
                detail = "通道未连接，签名与续签暂不可用。"
            } else {
                // 检查和自动恢复期间保持这句不变，避免配对成功横幅来回跳字。
                detail = "设备已配对，可开始签名与续签。"
            }
            return ("配对完成", detail, "checkmark.circle.fill", .sealSuccess, "重新配对")
        }
        switch viewModel.phonePairingState {
        case .idle:
            return ("准备配对", "在开发者模式中与 Seal 配对，完成后即可签名、安装和续签。", "iphone.and.arrow.forward", .sealAccent, "开始设备配对")
        case .requestingLocalNetwork:
            return ("准备配对", "正在请求本地网络权限。", "network", .sealAccent, "正在准备")
        case .waitingForSystemConfirmation:
            return ("在系统中配对", PairingActivityAttributes.developerModePairingInstruction, "gearshape.2", .sealAccent, "等待系统确认")
        case .showingCode:
            return ("确认配对码", "将下方配对码与系统设置中的提示核对后确认。", "custom.pairingCode", .sealAccent, "等待系统确认")
        case .validating:
            return ("验证连接", "正在检查 LocalDevVPN 是否可用。", "arrow.triangle.2.circlepath", .sealAccent, "正在检查连接…")
        case .waitingForLocalDevVPN:
            return ("等待 LocalDevVPN", "设备配对已保存。打开 LocalDevVPN 后继续检查。", "vpn", .sealWarning, "检查连接")
        case .completed:
            return ("配对完成", "设备已准备好，可签名、安装和续签。", "checkmark.circle.fill", .sealSuccess, "重新配对")
        case .failed:
            return ("需要重新配对", "未完成系统确认或本地网络不可用。", "exclamationmark.triangle.fill", .sealDanger, "重新配对")
        }
    }

    private var phoneProgressIndex: Int {
        // 配对一旦成功，后续 VPN 连接检查只反映在明细状态，不回退配对进度。
        if hasStablePairing {
            return 3
        }
        switch viewModel.phonePairingState {
        case .idle, .requestingLocalNetwork: return 0
        case .waitingForSystemConfirmation, .showingCode: return 1
        case .validating, .waitingForLocalDevVPN: return 2
        case .completed: return 3
        case .failed: return 1
        }
    }

    private var phonePairingStatusText: String {
        // 「设备配对」明细行只认配对记录：已验证即永久「已完成」。
        if viewModel.pairingRecord?.isPaired == true {
            return "已完成"
        }
        switch viewModel.phonePairingState {
        case .completed: return "已完成"
        case .waitingForLocalDevVPN, .validating: return "已保存，待验证"
        case .failed: return "未完成"
        case .idle where viewModel.pairingRecord?.isPaired == true: return "已完成"
        default: return "待配对"
        }
    }

    private var localDevVPNStatusText: String {
        switch viewModel.phoneTunnelStatus {
        case .checking: return "验证中"
        case .recovering: return "自动恢复中"
        case .ready: return "已验证"
        case .unavailable: return "通道异常"
        case .unchecked: break
        }
        switch viewModel.diagnosticState {
        case .ready: return "已验证"
        case .running: return "验证中"
        case .failed: return "验证失败"
        case .idle: return "待验证"
        }
    }

    /// 手机配对是否处于等待态（配对码确认／验证／等隧道期间图标呼吸）。
    private var isPhonePairingWaiting: Bool {
        guard hasStablePairing == false else { return false }
        switch viewModel.phonePairingState {
        case .requestingLocalNetwork, .waitingForSystemConfirmation, .showingCode,
             .validating, .waitingForLocalDevVPN:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    /// 正在重新配对时显示配对流程；其余状态保留已配对横幅。
    private var hasStablePairing: Bool {
        guard viewModel.pairingRecord?.isPaired == true else { return false }
        switch viewModel.phonePairingState {
        case .requestingLocalNetwork, .waitingForSystemConfirmation, .showingCode:
            return false
        case .idle, .validating, .waitingForLocalDevVPN, .completed, .failed:
            return true
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: heroIcon)
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(heroColor)
                // 设备验证中：运行箭头轻呼吸，验证完即停。
                .symbolEffect(.pulse, isActive: viewModel.pairingRecord?.validationStatus == .validating)
            Text(heroTitle)
                .font(.title2.weight(.semibold))
            Text(heroSubtitle)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .singleLine()
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .sealContentCard(.prominent)
    }

    private func details(_ pairing: PairingRecord) -> some View {
        VStack(spacing: 0) {
            detailRow("配对类型", pairing.isRemotePairing ? "远程配对" : "本机配对")
            Divider()
            detailRow("设备 UDID", deviceIdentifierText(pairing))
                .sealCopyableIdentifier(deviceIdentifierText(pairing))
            Divider()
            detailRow("配对状态", pairing.validationStatus.title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sealContentCard(.standard)
    }

    private var acquisitionGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接设备")
                .font(.headline)
                .singleLine()
            Text("电脑端生成配对文件后，可在此导入或由助手自动写入。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
            Text("Seal 仅支持 iOS 17.4 及以上。")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
                .singleLine()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .sealContentCard(.standard)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isFileImporterPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入配对文件").singleLine()
                }
            }
            .sealPrimaryAction(cornerRadius: 12)

            if viewModel.pairingRecord != nil {
                Button {
                    isPairingExportWarningPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出配对文件").singleLine()
                    }
                }
                .sealOutlineAction(cornerRadius: 12)
            }

            Button(viewModel.pairingRecord == nil ? "检查配对状态" : "重新检查配对") {
                Task {
                    await viewModel.testPairingConnection()
                }
            }
            .sealOutlineAction(cornerRadius: 12)
        }
    }

    private func preparePairingFileExport() {
        Task {
            guard let data = await viewModel.pairingFileDataForExport() else { return }
            pairingExportDocument = PairingExportDocument(data: data)
            isPairingFileExporterPresented = true
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .singleLine()
                .truncationMode(.middle)
        }
        .frame(minHeight: 54)
    }

    private var heroIcon: String {
        guard let status = viewModel.pairingRecord?.validationStatus else {
            return "iphone.badge.exclamationmark"
        }
        switch status {
        case .verified: return "checkmark.circle.fill"
        case .validating: return "arrow.triangle.2.circlepath"
        case .unverified: return "clock.badge.checkmark"
        case .deviceMismatch, .fileUnreadable: return "exclamationmark.triangle.fill"
        }
    }

    private var heroColor: Color {
        guard let status = viewModel.pairingRecord?.validationStatus else { return .sealWarning }
        switch status {
        case .verified: return .sealSuccess
        case .validating: return .sealAccent
        case .unverified: return .sealWarning
        case .deviceMismatch, .fileUnreadable: return .sealDanger
        }
    }

    private var heroTitle: String {
        guard let pairing = viewModel.pairingRecord else { return "未导入" }
        return pairing.validationStatus.title
    }

    private var heroSubtitle: String {
        guard let status = viewModel.pairingRecord?.validationStatus else {
            return "请先在电脑上完成设备配对。"
        }
        switch status {
        case .unverified:
            return "设备信息已保存。首次连接成功后会完成配对。"
        case .validating:
            return "正在确认当前 iPhone 是否匹配。"
        case .verified:
            return "已完成配对。连接暂时不可用也不会取消配对。"
        case .deviceMismatch:
            return "当前设备不匹配，请重新配对。"
        case .fileUnreadable:
            return "设备信息无法读取，请重新配对。"
        }
    }

    private func deviceIdentifierText(_ pairing: PairingRecord) -> String {
        if let id = pairing.validatedDeviceIdentifier, id.isEmpty == false { return id }
        if let id = pairing.deviceIdentifier, id.isEmpty == false { return id }
        return "待验证"
    }
}

private struct PairingExportDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "mobiledevicepairing") ?? .propertyList
    static var readableContentTypes: [UTType] { [contentType, .propertyList] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
