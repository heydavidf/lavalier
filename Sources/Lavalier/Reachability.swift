import Foundation
import Network

/// Tracks whether the Mac has a usable network path.
final class Reachability: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lavalier.reachability")
    private let lock = NSLock()
    private var online = true

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
