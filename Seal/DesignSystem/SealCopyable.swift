import SwiftUI
import UIKit

/// 标识符长按复制（2026-10-24）：Bundle ID / UDID / 证书序列号 / 邮箱等
/// 「只能看不能复制」的明细行统一走它 —— 长按出「复制」菜单，复制成功给
/// 一下轻震动（`.impact(weight: .light)`），不用再跳弹窗确认。
struct SealCopyableIdentifierModifier: ViewModifier {
    let value: String

    @State private var copyTrigger = 0

    func body(content: Content) -> some View {
        content
            .contextMenu {
                // 空值（如「读取失败」占位）不提供复制入口，免得拷出空串。
                if value.isEmpty == false {
                    Button {
                        UIPasteboard.general.string = value
                        copyTrigger += 1
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: copyTrigger)
    }
}

extension View {
    func sealCopyableIdentifier(_ value: String) -> some View {
        modifier(SealCopyableIdentifierModifier(value: value))
    }
}
