import Foundation
import Network

/// Tracks the actual Wi-Fi path separately from the default route, which may be cellular.
/// The lock protects the cached path state and one-time monitor startup.
final class WiFiPathAvailability: @unchecked Sendable {
    static let shared = WiFiPathAvailability()

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "com.mjorb.seal.wifi-path")
    private let lock = NSLock()
    private var hasStarted = false
    private var available: Bool?

    private init() {}

    func start() {
        lock.lock()
        guard hasStarted == false else {
            lock.unlock()
            return
        }
        hasStarted = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.available = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// Returns immediately once Network.framework has delivered its current Wi-Fi path.
    /// Only the first cold read waits briefly for that initial snapshot; unknown is kept
    /// distinct from disconnected so a delayed system callback cannot create a false error.
    func isAvailable() async -> Bool? {
        start()
        for attempt in 0..<10 {
            let snapshot = currentAvailability()
            if let snapshot { return snapshot }
            guard attempt < 9 else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func currentAvailability() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return available
    }
}
