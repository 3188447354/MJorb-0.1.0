import SwiftUI

/// Seal 隐私政策。内容与当前功能、权限和外部通信保持一致。
struct PrivacyNoticeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("生效日期：2026 年 10 月 17 日")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.top, 4)

                policySection(
                    title: "引言与适用范围",
                    body: "Seal 由 MJorb（以下简称“开发者”或“我们”）开发。本政策说明 Seal 在您的设备上处理哪些信息、为何处理、会与哪些服务通信，以及您如何管理这些信息。本政策适用于 Seal iOS 应用，不适用于您通过 Seal 打开的第三方网页、第三方应用或第三方服务。"
                )

                policySection(
                    title: "一、处理的信息与用途",
                    body: "Apple ID、认证所需密码、双重认证结果、会话令牌及签名证书材料：仅在您主动添加或验证 Apple ID、签名或续签时处理，用于与 Apple 完成认证、证书、App ID 和描述文件操作。相关凭据与私钥材料存放在本机 iOS 钥匙串，关闭 iCloud 同步；我们不会接收或查看您的明文密码。\n\n设备信息：包括 UDID、设备名称、型号、系统版本和配对状态，用于设备配对、向 Apple 注册设备、申请描述文件及安装应用。\n\n应用与 IPA 信息：包括您导入 IPA 的文件内容、名称、版本、Bundle ID、扩展信息、签名记录、已安装应用状态及描述文件信息，用于解析、签名、安装、续签和展示。\n\n诊断日志：包括操作时间、错误码、脱敏后的技术诊断，用于在本机排查问题。日志会自动脱敏；只有您主动导出或分享时，才会离开设备。\n\n设置与偏好：包括主题、提醒、已选择的 Anisette 服务和更新提示状态，用于保存您的使用选择。"
                )

                policySection(
                    title: "二、权限与系统能力",
                    body: "本地网络：用于发现、配对并连接同一设备以安装应用。\n\n通知：仅在您允许后，用于应用到期提醒、后台续签结果及 Live Activity 不可用时的配对码提示。\n\n定位：仅当您启用后台自动续签并授予权限时使用，以尝试让续签任务在锁屏或后台期间继续运行。Seal 不读取、不展示、不保存或上传您的地理位置；拒绝该权限不会影响前台手动签名。\n\n相册“添加照片”：仅在您主动保存赞赏码图片时使用，Seal 不读取您的相册。\n\n您可随时在“设置 > 隐私与安全性”中修改系统权限；关闭权限可能使相应功能无法使用。"
                )

                policySection(
                    title: "三、信息的对外传输",
                    body: "Apple：签名、续签、设备注册和 Apple ID 认证需要通过加密连接向 Apple 服务发送必要的认证信息、设备标识、证书和描述文件数据。Apple 对其收到信息的处理适用其自身隐私政策。\n\nAnisette 服务：为完成 Apple 认证，Seal 会向您选择或自动切换的 Anisette 服务发送设备环境标识及认证准备数据，并从其取得认证所需响应。该服务由独立第三方运营；其可能处理连接信息及请求数据，开发者无法控制其独立的数据处理。请仅在您接受相应服务风险时使用。\n\nGitHub：检查更新时，Seal 会访问 GitHub Releases API；下载更新时会访问 GitHub 提供的发布资产。GitHub 可依据其规则处理网络连接信息。\n\n我们不会出售个人信息，不使用广告 SDK，不进行跨 App 或跨网站跟踪，也不将您的信息用于定向广告。"
                )

                policySection(
                    title: "四、本地存储、保留与删除",
                    body: "账号凭据、认证材料和签名私钥存放在 iOS 钥匙串；应用记录、导入文件、设置和日志存放在本机应用容器。删除 Apple ID 会删除对应的本机凭据；您可在应用内清空日志、删除导入文件和相关记录。\n\n卸载应用通常会删除应用容器中的数据，但系统钥匙串数据的保留行为可能受 iOS、备份和恢复机制影响。若您不再使用 Seal，建议先在应用内删除全部 Apple ID 和导入内容，再卸载应用。"
                )

                policySection(
                    title: "五、安全措施与风险提示",
                    body: "Seal 使用系统钥匙串保存敏感凭据，并使用 HTTPS/TLS 与支持该协议的服务通信。没有任何网络传输或设备存储方式可以保证绝对安全。请妥善保管设备和 Apple ID，不要向他人提供密码、验证码、导出的日志或签名材料。"
                )

                policySection(
                    title: "六、您的选择与权利",
                    body: "您可以在 Seal 内查看和删除已添加的 Apple ID、应用记录和日志；可以拒绝非必要权限；可以不使用更新检查或第三方 Anisette 服务。Seal 不建立独立用户账号，因此没有需要向开发者申请的线上账号注销流程。若您认为本政策所述处理有误，可通过 mjorb520@gmail.com 联系开发者。"
                )

                policySection(
                    title: "七、未成年人",
                    body: "Seal 面向具备相应民事行为能力、能够合法管理其 Apple ID 和设备的用户。未成年人应在监护人同意和指导下使用；请勿在未获监护人同意的情况下提交 Apple ID 或其他个人信息。"
                )

                policySection(
                    title: "八、政策更新与联系我们",
                    body: "功能、权限、外部服务或适用规则发生实质变化时，我们会更新本政策并在应用内提示。涉及个人信息处理目的、方式或范围的重大变化，将在继续处理前请您重新确认。\n\n开发者：MJorb\n联系渠道：mjorb520@gmail.com"
                )

                Text("本隐私政策是《Seal 用户协议》的组成部分。")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .navigationTitle(AgreementMetadata.Privacy.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { agreementToolbar(title: AgreementMetadata.Privacy.title, effectiveDate: AgreementMetadata.Privacy.effectiveDate) }
        .sealScreenBackground()
    }

    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.body.weight(.semibold))
            Text(body).font(.subheadline).foregroundStyle(Color.sealTextSecondary).lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .sealContentCard(.compact)
    }

    @ToolbarContentBuilder
    private func agreementToolbar(title: String, effectiveDate: String) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text("v\(AgreementVersion.current) · \(effectiveDate) 生效")
                    .font(.caption2)
                    .foregroundStyle(Color.sealTextSecondary)
            }
        }
    }
}
