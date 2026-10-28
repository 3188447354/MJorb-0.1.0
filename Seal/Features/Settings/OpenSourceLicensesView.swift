import SwiftUI

struct OpenSourceLicensesView: View {
    private let groups = OpenSourceLicenseCatalog.groups

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("组件与许可")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("查看随 Seal 提供的组件、来源和许可")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        NavigationLink {
                            OpenSourceLicenseDetailView(group: group)
                        } label: {
                            LicenseGroupRow(group: group)
                        }
                        .buttonStyle(.plain)

                        if index < groups.count - 1 {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .sealContentCard(.standard)

                Text("完整条款随应用提供；组件来源可在详情中查看。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 2)
            }
            .padding(20)
        }
        .navigationTitle("组件与许可")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
    }
}

private struct LicenseGroupRow: View {
    let group: OpenSourceLicenseGroup

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: group.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 36, height: 36)
                .background(
                    Color.sealAccent.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(group.componentCountLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary.opacity(0.75))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct OpenSourceLicenseDetailView: View {
    let group: OpenSourceLicenseGroup

    private var licenseText: String? {
        guard let resource = group.licenseResource,
              let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(group.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.sealTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(Array(group.components.enumerated()), id: \.element.id) { index, component in
                        Link(destination: component.sourceURL) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(component.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let note = component.note {
                                        Text(note)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.sealTextSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.sealAccent)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < group.components.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .sealContentCard(.standard)

                if let referenceURL = group.licenseReferenceURL,
                   let referenceLabel = group.licenseReferenceLabel {
                    Link(destination: referenceURL) {
                        Label(referenceLabel, systemImage: "arrow.up.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.sealAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sealContentCard(.standard)
                }

                if let licenseText {
                    LicenseTextCard(title: "完整许可文本", text: licenseText)
                    ForEach(group.additionalNoticeResources, id: \.self) { resource in
                        if let notice = Self.loadText(resource) {
                            LicenseTextCard(title: Self.noticeTitle(resource), text: notice)
                        }
                    }
                } else if let licenseURL = group.licenseURL {
                    Link(destination: licenseURL) {
                        Label("查看 Apple 官方条款", systemImage: "arrow.up.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.sealAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sealContentCard(.standard)
                }
            }
            .padding(20)
        }
        .navigationTitle(group.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
    }

    private static func loadText(_ resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func noticeTitle(_ resource: String) -> String {
        resource
            .replacingOccurrences(of: "NOTICE-", with: "补充声明 · ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

private struct LicenseTextCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.88))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .sealContentCard(.standard)
    }
}

private enum OpenSourceLicenseCatalog {
    static let groups: [OpenSourceLicenseGroup] = [
        .init(
            id: "MIT",
            title: "MIT",
            navigationTitle: "MIT",
            detail: "适用于以下组件。AltSign 的 MIT 标识依据原始上游配置声明。",
            licenseResource: "MIT",
            licenseReferenceURL: URL(string: "https://github.com/rileytestut/AltSign/blob/master/AltSign.podspec"),
            licenseReferenceLabel: "查看 AltSign 上游 MIT 声明",
            components: [
                .init(name: "AltSign", source: "https://github.com/sunuannian1/AltSign", note: "Seal 使用修改版；其余随包依赖按各自许可列出。"),
                .init(name: "ZIPFoundation", source: "https://github.com/weichsel/ZIPFoundation"),
                .init(name: "libdeflate", source: "https://github.com/SideStore/libdeflate")
            ]
        ),
        .init(
            id: "Apache-2.0",
            title: "Apache-2.0",
            navigationTitle: "Apache-2.0",
            detail: "适用于以下组件，并附带各自的第三方声明。",
            licenseResource: "Apache-2.0",
            additionalNoticeResources: ["NOTICE-swift-crypto", "NOTICE-swift-asn1"],
            components: [
                .init(name: "OpenSSL", source: "https://github.com/krzyzanowskim/OpenSSL"),
                .init(name: "swift-crypto", source: "https://github.com/apple/swift-crypto"),
                .init(name: "swift-asn1", source: "https://github.com/apple/swift-asn1")
            ]
        ),
        .init(
            id: "GPL-3.0",
            title: "GPL-3.0",
            navigationTitle: "GPL-3.0",
            detail: "适用于以下组件。",
            licenseResource: "GPL-3.0",
            components: [
                .init(name: "SideSign", source: "https://github.com/SideStore/SideSign")
            ]
        ),
        .init(
            id: "AGPL-3.0",
            title: "AGPL-3.0",
            navigationTitle: "AGPL-3.0",
            detail: "以下组件按 AGPL-3.0 发布。",
            licenseResource: "AGPL-3.0",
            components: [
                .init(name: "AnisetteKit", source: "https://github.com/mahee96/AnisetteKit"),
                .init(name: "Minimuxer", source: "https://github.com/SideStore/minimuxer"),
                .init(name: "CodeSignKit", source: "https://github.com/mahee96/CodeSignKit"),
                .init(name: "GSACryptoKit", source: "https://github.com/mahee96/GSACryptoKit"),
                .init(name: "ldid", source: "https://github.com/SideStore/ldid", note: "由 AltSign 的 NativeBridge 编译。")
            ]
        ),
        .init(
            id: "GPL-2.0",
            title: "GPL-2.0",
            navigationTitle: "GPL-2.0",
            detail: "适用于以下组件。",
            licenseResource: "GPL-2.0",
            components: [
                .init(name: "Unicorn Engine", source: "https://github.com/unicorn-engine/unicorn")
            ]
        ),
        .init(
            id: "LGPL-2.1",
            title: "LGPL-2.1",
            navigationTitle: "LGPL-2.1",
            detail: "适用于以下开源库。",
            licenseResource: "LGPL-2.1",
            components: [
                .init(name: "libimobiledevice", source: "https://github.com/libimobiledevice/libimobiledevice"),
                .init(name: "libimobiledevice-glue", source: "https://github.com/libimobiledevice/libimobiledevice-glue"),
                .init(name: "libusbmuxd", source: "https://github.com/libimobiledevice/libusbmuxd"),
                .init(name: "libplist", source: "https://github.com/libimobiledevice/libplist")
            ]
        ),
        .init(
            id: "zlib",
            title: "zlib",
            navigationTitle: "zlib",
            detail: "适用于 AltSign 使用的压缩组件。",
            licenseResource: "zlib",
            components: [
                .init(name: "minizip-ng", source: "https://github.com/zlib-ng/minizip-ng")
            ]
        )
    ]
}

private struct OpenSourceLicenseGroup: Identifiable {
    let id: String
    let title: String
    let navigationTitle: String
    let detail: String
    var licenseResource: String? = nil
    var licenseURL: URL? = nil
    var licenseReferenceURL: URL? = nil
    var licenseReferenceLabel: String? = nil
    var additionalNoticeResources: [String] = []
    let components: [OpenSourceLicenseComponent]

    var symbol: String { "doc.text" }
    var componentCountLabel: String { components.count == 1 ? "1 个组件" : "\(components.count) 个组件" }
}

private struct OpenSourceLicenseComponent: Identifiable {
    let name: String
    let sourceURL: URL
    let note: String?

    var id: String { name }

    init(name: String, source: String, note: String? = nil) {
        self.name = name
        self.sourceURL = URL(string: source)!
        self.note = note
    }
}
