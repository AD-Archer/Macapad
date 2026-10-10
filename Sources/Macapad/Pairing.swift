import Foundation
import Hummingbird

/// A device asking to pair. It waits until you click Allow or Deny on the Mac.
struct PairRequest: Sendable, Identifiable {
    enum Status: Sendable {
        case pending
        case approved(PairedDevice, token: String)
        case denied
    }

    /// Secret: only the asking device knows it, and it's how that device collects its token.
    let id: String
    let name: String
    let app: String?
    let network: NetworkKind
    let address: String
    /// Shown on the Mac and on the device so you can check they match.
    let code: String
    let expiresAt: Date
    var status: Status = .pending

    var isPending: Bool { if case .pending = status { return true } else { return false } }
}

enum PairError: LocalizedError {
    case busy, tooMany

    var errorDescription: String? {
        switch self {
        case .busy: return "This device already has a pairing request waiting on the Mac"
        case .tooMany: return "Too many pairing requests are waiting on the Mac; try again in a minute"
        }
    }
}

/// Pending pairing requests. They live in memory only and expire after two minutes.
final class Pairing: @unchecked Sendable {
    static let shared = Pairing()
    static let lifetime: TimeInterval = 120

    private let lock = NSLock()
    private var requests: [String: PairRequest] = [:]
    private var observers: [@Sendable ([PairRequest]) -> Void] = []

    /// Requests still waiting for a decision, oldest first.
    var pending: [PairRequest] {
        lock.withLock { requests.values.filter(\.isPending) }.sorted { $0.expiresAt < $1.expiresAt }
    }

    func create(name: String, app: String?, network: NetworkKind, address: String) throws -> PairRequest {
        let request = PairRequest(
            id: Config.randomHex(bytes: 16),
            name: name, app: app, network: network, address: address,
            code: String(format: "%04d", Int.random(in: 0...9999)),
            expiresAt: Date().addingTimeInterval(Self.lifetime)
        )
        try lock.withLock {
            let waiting = requests.values.filter(\.isPending)
            // Stops one noisy device from flooding the Mac with prompts.
            if network != .thisMac, waiting.contains(where: { $0.address == address }) { throw PairError.busy }
            if waiting.count >= 3 { throw PairError.tooMany }
            requests[request.id] = request
        }
        notify()
        Task { [id = request.id] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            self.lock.withLock { _ = self.requests.removeValue(forKey: id) }
            self.notify()
        }
        return request
    }

    /// The request's status, or nil once it has expired or its token was collected.
    /// Collecting an approved request removes it, so the token is handed out once.
    func collect(_ id: String) -> PairRequest.Status? {
        lock.withLock {
            guard let request = requests[id] else { return nil }
            if case .pending = request.status { return .pending }
            requests.removeValue(forKey: id)
            return request.status
        }
    }

    func approve(_ id: String) {
        let request = lock.withLock { requests[id] }
        guard let request, request.isPending else { return }
        let (device, token) = Devices.shared.add(name: request.name, app: request.app, network: request.network)
        lock.withLock { requests[id]?.status = .approved(device, token: token) }
        notify()
    }

    func deny(_ id: String) {
        lock.withLock {
            guard requests[id]?.isPending == true else { return }
            requests[id]?.status = .denied
        }
        notify()
    }

    func observe(_ observer: @escaping @Sendable ([PairRequest]) -> Void) {
        lock.withLock { observers.append(observer) }
    }

    private func notify() {
        let observers = lock.withLock { self.observers }
        let pending = self.pending
        observers.forEach { $0(pending) }
    }
}

/// The key inside the QR code the Mac shows. Whoever scans it pairs without a prompt
/// (seeing the screen is the proof), so a key only exists while the QR window is open,
/// works once, and expires after five minutes.
final class QRPairing: @unchecked Sendable {
    static let shared = QRPairing()
    static let lifetime: TimeInterval = 300

    private let lock = NSLock()
    private var key: String?
    private var expiresAt = Date.distantPast
    private var observers: [@Sendable (PairedDevice) -> Void] = []

    /// A fresh key; the previous one stops working.
    func issue() -> String {
        let key = Config.randomHex(bytes: 16)
        lock.withLock {
            self.key = key
            expiresAt = Date().addingTimeInterval(Self.lifetime)
        }
        return key
    }

    func revoke() {
        lock.withLock { key = nil }
    }

    /// Pairs a new device if `supplied` is the current key, using the key up.
    func redeem(_ supplied: String, name: String, app: String?, network: NetworkKind) -> (PairedDevice, String)? {
        let valid = lock.withLock { () -> Bool in
            guard let key, Date() < expiresAt, Devices.constantTimeEquals(key, supplied) else { return false }
            self.key = nil
            return true
        }
        guard valid else { return nil }
        let (device, token) = Devices.shared.add(name: name, app: app, network: network)
        let observers = lock.withLock { self.observers }
        observers.forEach { $0(device) }
        return (device, token)
    }

    /// Called with each device that pairs by QR code.
    func observe(_ observer: @escaping @Sendable (PairedDevice) -> Void) {
        lock.withLock { observers.append(observer) }
    }
}
