import Foundation
@preconcurrency import Minimuxer

struct InstalledAppDeviceVerifier {
    static func isInstalled(
        bundleIdentifier: String,
        operationCoordinator: OperationCoordinator? = nil
    ) async throws -> Bool {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            throw NSError(
                domain: "SealInstalledAppDeviceVerifier",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundle identifier"]
            )
        }

        guard let operationLease = await InstalledAppInventoryOperationLease.begin(
            using: operationCoordinator
        ) else {
            throw unavailableError(code: 5, description: "Device inventory conflicts with an active device operation")
        }

        // ⚠️ **必须有界**：`isAppInstalled` 是同步阻塞 FFI，在一条已死的 RSD 缓存会话上
        // **不报错、只阻塞到操作系统放弃**（与安装路径同一个失败模式）。
        // 只放到 `Task.detached` 是不够的 —— 那只是把它挪出主线程，**阻塞本身仍然无界**。
        // 超时按「不知道」处理（抛错），调用方本来就 fail closed（保守跳过，不删数据）。
        let probeID: UUID
        switch await InstalledAppRefreshProbeGate.shared.begin() {
        case .ready(let id):
            probeID = id
        case .inFlight:
            await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            throw unavailableError(code: 3, description: "Device probe is already in progress")
        case .coolingDown:
            await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            throw unavailableError(code: 4, description: "Device probe is cooling down after a timeout")
        }

        let outcome = await BlockingCall.bounded(
            seconds: InstalledAppRefreshProbePolicy.timeoutSeconds,
            cancelsWorkOnTimeout: false,
            onLateCompletion: { _ in
                await InstalledAppRefreshProbeGate.shared.finish(probeID: probeID, timedOut: true)
                await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            },
            onWorkNeverStarted: {
                await InstalledAppRefreshProbeGate.shared.finish(probeID: probeID, timedOut: false)
                await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
            }
        ) {
            // ⚠️ 不重置 Install provider：它不能清 Rust RSD 缓存，还可能拆掉正在服务安装的连接。
            return try Minimuxer.isAppInstalled(bundleId: identifier)
        }
        guard let outcome else {
            // 超时/取消时由 FFI 的迟到完成回调（或未启动回调）释放闸门。
            if Task.isCancelled { throw CancellationError() }
            throw unavailableError(code: 2, description: "Device probe timed out")
        }
        // 正常完成时释放；超时/取消时不走到这里，避免重叠查询。
        await InstalledAppRefreshProbeGate.shared.finish(probeID: probeID, timedOut: false)
        await InstalledAppInventoryOperationLease.end(operationLease, using: operationCoordinator)
        if Task.isCancelled {
            throw CancellationError()
        }
        return try outcome.get()
    }

    private static func unavailableError(code: Int, description: String) -> NSError {
        NSError(
            domain: "SealInstalledAppDeviceVerifier",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
