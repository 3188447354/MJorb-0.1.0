//
//  AltSignLogging.swift
//  AltSign
//
//  Created by Magesh K on 28/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//
import Foundation

public enum AltSignLogging {
    public private(set) static var isLoggingEnabled = false

    public static func setLogging(_ enabled: Bool) {
        defer { debugLog("[AltSign] setLogging(\(enabled)) completed") }
        debugLog("[AltSign] setLogging(\(enabled)) invoked")
        isLoggingEnabled = enabled
    }

    /// 日志转发钩子。
    ///
    /// 为什么需要它：AltSign 的所有日志都走 `print()`，而 iOS 上 `print()` 只写
    /// stdout —— 既不进系统的 unified log，也不进宿主 App 自己的日志文件。结果是
    /// 认证失败时最有价值的两行
    ///   `sendAuthenticationRequest response Status: …`
    ///   `sendAuthenticationRequest response Data: …`
    /// （它们携带 Apple 返回的完整 `Status` 字典，也就是 `-80045` 的原始说明）
    /// 全部落进黑洞，真机排障时一条都看不到。
    ///
    /// 宿主 App 可以设这个闭包把日志接到自己的日志存储里。闭包为空时行为与之前
    /// 完全一致（仍然只 `print`），所以不设钩子的调用方不受影响。
    ///
    /// 用锁保护：AltSign 的回调可能来自任意队列，而这个属性可读可写。
    private static let relayLock = NSLock()
    private static var _relay: ((String) -> Void)?

    public static var relay: ((String) -> Void)? {
        get {
            relayLock.lock()
            defer { relayLock.unlock() }
            return _relay
        }
        set {
            relayLock.lock()
            _relay = newValue
            relayLock.unlock()
        }
    }

    /// 把一行日志同时交给 `print` 和转发钩子。
    static func emit(_ message: String) {
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
        } else {
            print("\(getTag(level: "[V]"))\(message)")
        }
        relay?(message)
    }
}

private func getTag(level: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let timestamp = formatter.string(from: Date())
    return "\(timestamp) \(level): "
}

@inline(__always)
public func debugLog(_ text: @autoclosure () -> String) {
    let message = text()
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
    } else {
        print("\(getTag(level: "[D]"))\(message)")
    }
}

@inline(__always)
public func verboseLog(_ text: @autoclosure () -> String) {
    if AltSignLogging.isLoggingEnabled {
        // 经 AltSignLogging.emit 而非直接 print()：这样宿主 App 设了 relay 钩子
        // 就能收到，否则日志（包含 -80045 的完整响应体）在真机上不可见。
        AltSignLogging.emit(text())
    }
}
