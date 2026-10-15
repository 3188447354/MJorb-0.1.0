import Foundation
import Network

/// Triggers iOS local-network permission before notification permission.
/// It only performs a short probe and never opens or selects VPN.
///
/// ⚠️ 为什么不能一探完就返回：本地网络那个系统弹窗是**异步**的，探针拿到
/// `.ready/.failed/.cancelled` 或超时只说明「请求已经发出去了」，**不说明用户已经
/// 点过**。之前这里是 0.8 秒硬超时，于是调用方几乎立刻继续往下走、紧接着去请求通知
/// 权限 —— 两个系统弹窗就叠在一起互相打架（真机现象：弹窗同时出现、或其中一个被吞）。
///
/// 现在改成：探针结束后再**保持一段静默期**（`dialogClearance`），让用户把当前这个
/// 弹窗点完，之后才把控制权交回调用方。调用方是 `await` 它的，所以「点完一个再出现
/// 第二个」是天然成立的，不需要额外的调度器。
enum LocalNetworkPermissionPrimer {
    /// 探针本身的最长等待：等系统把弹窗显示出来。
    private static let probeTimeout: TimeInterval = 2.0
    /// 探针结束后的静默期：留给用户点掉那个弹窗。
    /// 取值偏保守 —— 宁可稍慢也不要叠弹窗；用户点得早就直接进下一屏。
    private static let dialogClearance: TimeInterval = 6.0
    /// 「本地网络」只在一个安装里请求一次。系统自己也会记，但这里再挡一道：
    /// 没有它，每次冷启动都会重新跑探针并占用 6 秒静默期。
    private static let requestedKey = "SealLocalNetworkPermissionRequested"

    static func requestIfNeeded() async {
        guard UserDefaults.standard.bool(forKey: requestedKey) == false else { return }
        UserDefaults.standard.set(true, forKey: requestedKey)

        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host("10.7.0.1"),
                port: NWEndpoint.Port(integerLiteral: 62078),
                using: .tcp
            )
            let queue = DispatchQueue(label: "com.mjorb.seal.local-network-permission")
            let probe = LocalNetworkPermissionProbe(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    probe.finish()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + probeTimeout) {
                probe.finish()
            }
        }

        // 弹窗可能仍在屏幕上；等它消失，再让调用方去请求下一个权限。
        try? await Task.sleep(nanoseconds: UInt64(dialogClearance * 1_000_000_000))
    }
}

private final class LocalNetworkPermissionProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, Never>
    private let lock = NSLock()
    private var isFinished = false

    init(connection: NWConnection, continuation: CheckedContinuation<Void, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        let shouldFinish = isFinished == false
        if shouldFinish { isFinished = true }
        lock.unlock()
        guard shouldFinish else { return }
        connection.cancel()
        continuation.resume()
    }
}
