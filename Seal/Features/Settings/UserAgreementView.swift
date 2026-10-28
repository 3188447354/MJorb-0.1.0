import SwiftUI

/// Seal 用户协议。条款以 Seal 当前的个人 IPA 签名与续签功能为边界。
struct UserAgreementView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("生效日期：2026 年 10 月 17 日")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
                    .padding(.top, 4)

                policySection(
                    title: "引言",
                    body: "欢迎使用 Seal。Seal 由 MJorb（以下简称“开发者”或“我们”）开发。本协议约定您使用 Seal 的规则。请在使用前完整阅读；点击同意、安装、打开或继续使用 Seal，即表示您已理解并接受本协议及《隐私政策》。不同意的，请停止使用并删除本应用及其中保存的数据。"
                )

                policySection(
                    title: "一、服务性质",
                    body: "Seal 是运行在您个人 iOS 设备上的个人 IPA 自签、安装与续签工具。它可协助您使用自己的 Apple ID 管理签名证书、描述文件、App ID、已导入的 IPA 和已安装应用。\n\nSeal 不是 Apple 的产品，未获 Apple 赞助、认可或授权；Apple ID、App Store、iOS 及相关标识属于其各自权利人。Seal 不提供 Apple 开发者账号、第三方 IPA、应用内容或其运营服务。"
                )

                policySection(
                    title: "二、使用许可",
                    body: "在您遵守本协议和适用法律的前提下，开发者授予您一项可撤销、非独占、不可转让、不可再许可的个人使用许可，仅用于在您拥有或有权控制的设备上使用 Seal。除适用法律明确允许外，您不得复制、出售、出租、分发、修改、反编译或规避 Seal 的安全与使用限制，也不得删除版权或权利标识。\n\n未经开发者授权，您不得破解、注入 Seal，不得对 Seal 进行二次打包或以收费方式分发。Seal 免费提供，任何收费提供 Seal 的行为均未经开发者授权。"
                )

                policySection(
                    title: "三、您的责任",
                    body: "您应使用自己合法持有且有权使用的 Apple ID，并自行完成 Apple 要求的验证、开发者协议确认和安全设置。请勿共享密码、验证码、证书私钥或导出的签名材料。\n\n您导入、签名、安装或分发的 IPA、内容及数据必须来源合法，并由您自行确认其安全性、兼容性、许可和知识产权状况。不得利用 Seal 侵害他人权利、传播恶意软件、规避平台安全机制、进行欺诈或实施其他违法行为。\n\n您应自行备份重要数据。签名、证书、描述文件、Apple ID 状态以及第三方应用均可能受 Apple 或其提供方的规则和状态影响。"
                )

                policySection(
                    title: "四、Apple 与第三方服务",
                    body: "使用签名或续签功能时，Seal 会代表您与 Apple 服务及必要的第三方 Anisette 服务通信。您与这些服务之间的关系分别受其自身规则约束。\n\nApple 可能变更认证、证书、设备注册、App ID、描述文件、开发者资格或安装限制。此类变化可能导致功能受限、签名失败、已安装应用不可用或需重新验证；Seal 不能保证可绕过或改变这些规则。"
                )

                policySection(
                    title: "五、更新、功能变化与可用性",
                    body: "我们可能为修复问题、提升安全性或适配系统变化发布更新、调整或停止部分功能。更新包由您决定是否下载和安装；建议仅使用 Seal 提供的受信任更新入口并核对更新说明。\n\nSeal 按“现状”和“可用”基础提供。网络、设备状态、Apple 服务、第三方服务、系统限制及您导入的应用均可能影响结果。除适用法律不得排除的责任外，开发者不承诺任何签名、安装、续签或后台任务必然成功、持续可用或适用于特定目的。"
                )

                policySection(
                    title: "六、责任范围",
                    body: "您通过 Seal 操作的 Apple ID、证书、描述文件、IPA 和第三方应用由您自行管理和承担风险。对于第三方应用造成的内容、数据、兼容性、安全或法律问题，开发者不承担其提供者应承担的责任。\n\n在适用法律允许的范围内，开发者不对因网络中断、系统或 Apple 服务变更、第三方服务故障、设备丢失、用户操作或无法使用 Seal 所造成的间接、附带、特殊或后果性损失承担责任。本条不排除法律规定不得排除或限制的责任。"
                )

                policySection(
                    title: "七、隐私与数据",
                    body: "我们如何处理 Apple ID、设备信息、应用文件、日志、权限和外部服务通信，详见《隐私政策》。《隐私政策》是本协议的组成部分。"
                )

                policySection(
                    title: "八、知识产权与开源组件",
                    body: "Seal 的软件代码、界面、图标、文案及其他受保护内容的权利归其权利人所有。Seal 使用的开源组件依其各自许可证提供，相关信息可在应用内“开源许可”查看。"
                )

                policySection(
                    title: "九、协议变更、终止与争议",
                    body: "本协议发生实质变化时，我们会在应用内提示；继续使用更新后的 Seal 前可能需要您重新确认。您可随时停止使用并删除本应用。\n\n本协议的订立、效力、解释和履行适用中华人民共和国法律；如与强制性适用法律冲突，以该法律为准。因本协议产生争议，双方应先协商解决；协商不成的，可向有管辖权的人民法院提起诉讼。"
                )

                policySection(
                    title: "十、联系我们",
                    body: "开发者：MJorb\n联系渠道：mjorb520@gmail.com\n\n如您发现安全、隐私或使用问题，请通过上述渠道说明情况，并避免在公开消息中发送密码、验证码、完整日志或证书私钥。"
                )
            }
            .padding(20)
        }
        .navigationTitle(AgreementMetadata.Terms.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { agreementToolbar(title: AgreementMetadata.Terms.title, effectiveDate: AgreementMetadata.Terms.effectiveDate) }
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
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                    .singleLine()
            }
        }
    }
}
