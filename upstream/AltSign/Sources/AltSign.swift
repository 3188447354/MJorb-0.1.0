//
//  AltSign.swift
//  AltSign
//
//  Created by Magesh K on 28/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

// `@_exported` 让宿主 App 只 `import AltSign` 就能看到 SwiftBridge 的公开符号
// （例如 `AltSignLogging`）。没有它，App 侧引用这些符号会报
// `cannot find 'AltSignLogging' in scope` —— 日志实现位于独立的 `SwiftBridge`
// target，而宿主并不 import 它（run 41 的实际编译错误）。
@_exported import SwiftBridge

public enum AltSign {
    public static var isLoggingEnabled: Bool {
        return AltSignLogging.isLoggingEnabled
    }

    public static func setLogging(_ enabled: Bool) {
        AltSignLogging.setLogging(enabled)
    }
}
