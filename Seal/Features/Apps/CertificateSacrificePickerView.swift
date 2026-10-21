import SwiftUI

struct CertificateSacrificePickerView: View {
    @ObservedObject var viewModel: AppsViewModel
    let session: SigningSession

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [CertificateSacrificeCandidate] = []
    @State private var selectedSerialNumber: String?
    @State private var isLoading = true
    @State private var failureMessage: String?
    @State private var isConfirmationPresented = false
    @State private var showsAllCandidates = false

    private var selectedCandidate: CertificateSacrificeCandidate? {
        candidates.first { $0.id == selectedSerialNumber }
    }

    private var visibleCandidates: [CertificateSacrificeCandidate] {
        session.app.isSeal ? candidates.filter { $0.isCurrentSealSigner } : candidates
    }

    private var orderedCandidates: [CertificateSacrificeCandidate] {
        guard let recommendedSerialNumber,
              let recommended = visibleCandidates.first(where: { $0.id == recommendedSerialNumber }) else {
            return visibleCandidates
        }
        return [recommended] + visibleCandidates.filter { $0.id != recommendedSerialNumber }
    }

    private var displayedCandidates: [CertificateSacrificeCandidate] {
        showsAllCandidates ? orderedCandidates : Array(orderedCandidates.prefix(3))
    }

    private var recommendedSerialNumber: String? {
        if session.app.isSeal,
           let currentSealSigner = candidates.first(where: { $0.isCurrentSealSigner }) {
            return currentSealSigner.id
        }
        return candidates.min { lhs, rhs in
            if lhs.affectedAppCount != rhs.affectedAppCount {
                return lhs.affectedAppCount < rhs.affectedAppCount
            }
            if let lhsDate = lhs.certificate.expirationDate {
                guard let rhsDate = rhs.certificate.expirationDate else { return true }
                return lhsDate < rhsDate
            }
            if rhs.certificate.expirationDate != nil { return false }
            return lhs.id < rhs.id
        }?.id
    }

    var body: some View {
        SealDrawer(title: "选择要撤销的证书", showsFooter: true) {
            VStack(alignment: .leading, spacing: 10) {
                if session.app.isSeal {
                    Text("当前证书正供 Seal 使用；撤销后需完成本次签名并覆盖安装才能恢复。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.sealWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.sealWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text("选择一张本机没有私钥的开发证书")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sealTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取 Apple 证书列表")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let failureMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(failureMessage)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.sealDanger)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重新读取") { Task { await loadCandidates() } }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.sealAccent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if visibleCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(session.app.isSeal ? "未找到当前 Seal 使用的证书" : "没有可选择的旧证书")
                            .font(.system(size: 14, weight: .semibold))
                        Text(session.app.isSeal
                            ? "确认当前 Apple ID 与安装 Seal 时使用的账号一致，然后重新读取。"
                            : "刷新 Apple 证书列表后再试。")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.sealTextSecondary)
                        Button("重新读取") { Task { await loadCandidates() } }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.sealAccent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ForEach(displayedCandidates) { candidate in
                        candidateRow(candidate)
                    }

                    if orderedCandidates.count > 3 {
                        Button(showsAllCandidates ? "收起证书列表" : "显示全部 \(orderedCandidates.count) 张证书") {
                            showsAllCandidates.toggle()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.sealAccent)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Text("影响数量按本机记录统计，其他设备上的应用无法核验。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
            .padding(.bottom, 8)
        } footer: {
            VStack(spacing: 8) {
                Button("撤销所选证书") {
                    isConfirmationPresented = true
                }
                .sealPrimaryAction(cornerRadius: 14)
                .disabled(isLoading || failureMessage != nil || selectedCandidate == nil)
                .opacity(isLoading || failureMessage != nil || selectedCandidate == nil ? 0.55 : 1)

                Button("取消") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
        }
        .task { await loadCandidates() }
        .presentationDetents([.fraction(0.56)])
        .confirmationDialog(
            "确认撤销证书？",
            isPresented: $isConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认撤销并继续签名", role: .destructive) {
                guard let selectedCandidate else { return }
                let serial = selectedCandidate.certificate.serialNumber
                dismiss()
                viewModel.confirmCertificateSacrificeAndRetry(serialNumber: serial)
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let selectedCandidate {
                Text("将撤销有效期至 \(expiryDateText(selectedCandidate.certificate.expirationDate))、序列号末尾 \(selectedCandidate.certificate.serialNumber.suffix(8)) 的证书。本机记录可确认影响 \(selectedCandidate.affectedAppCount) 个应用。撤销后无法恢复，其他设备上的应用影响未知。")
            }
        }
        .sealScreenBackground()
    }

    private func candidateRow(_ candidate: CertificateSacrificeCandidate) -> some View {
        let isSelected = candidate.id == selectedSerialNumber
        let isRecommended = candidate.id == recommendedSerialNumber
        return Button {
            selectedSerialNumber = candidate.id
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected ? Color.sealAccent : Color.sealTextSecondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Apple Development")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if candidate.isCurrentSealSigner || isRecommended {
                            Text(candidate.isCurrentSealSigner ? "当前 Seal · 优先" : "推荐")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(candidate.isCurrentSealSigner ? Color.sealWarning : Color.sealAccent)
                                .lineLimit(1)
                        }
                    }
                    Text("\(expiryText(candidate.certificate.expirationDate)) · 尾号 \(candidate.certificate.serialNumber.suffix(8))")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("本机影响 \(candidate.affectedAppCount) 个应用")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sealTextSecondary)
                }
                .foregroundStyle(Color.sealTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.sealAccent.opacity(0.07) : Color.sealSurface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.sealAccent.opacity(0.75) : Color.sealHairline.opacity(0.8), lineWidth: isSelected ? 1.4 : 0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apple Development，\(expiryText(candidate.certificate.expirationDate))，序列号末尾 \(candidate.certificate.serialNumber.suffix(8))，本机记录可确认影响 \(candidate.affectedAppCount) 个应用")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func expiryText(_ date: Date?) -> String {
        guard let date else { return "有效期未知" }
        return "有效期至 \(SealSettingsDateFormatter.string(from: date))"
    }

    private func expiryDateText(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return SealSettingsDateFormatter.string(from: date)
    }

    @MainActor
    private func loadCandidates() async {
        isLoading = true
        failureMessage = nil
        candidates = []
        selectedSerialNumber = nil
        do {
            candidates = try await viewModel.loadCertificateSacrificeCandidates()
            selectedSerialNumber = recommendedSerialNumber
        } catch let failure as ImportFailure {
            failureMessage = failure.userMessage
        } catch {
            failureMessage = "无法读取 Apple 证书列表，请关闭后重试。"
        }
        isLoading = false
    }
}
