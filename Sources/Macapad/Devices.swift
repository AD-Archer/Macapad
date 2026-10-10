import CryptoKit
import Foundation
import Hummingbird

/// A frontend you approved on the Mac. It has its own token, so you can remove one
/// device without touching the others. Only a hash of the token is stored.
struct PairedDevice: Codable, Sendable, Identifiable, ResponseEncodable {
    var id: String
    var name: String
    /// The frontend that asked, e.g. "archersdesk". Optional.
    var app: String?
    /// The network it paired from.
    var network: NetworkKind
    var pairedAt: Date
    var lastSeen: Date?
    var tokenHash: String
    /// The schedule (in settings) this device works during. Nil = all the time.
    var scheduleId: String?
    /// While set and in the future, this device can't run anything. Far future = until turned back on.
    var pausedUntil: Date?

    /// Without the token hash, for API responses.
    var publicInfo: PairedDevice {
        var copy = self
        copy.tokenHash = ""
        return copy
    }
}

/// Who a valid token belongs to.
enum Caller: Sendable {
    /// The token in ~/.macapad/token: full access, for scripts and older frontends.
    case owner
    case device(PairedDevice)
}

/// Paired devices, saved in ~/.macapad/devices.json.
final class Devices: @unchecked Sendable {
    static let shared = Devices()

    private let lock = NSLock()
    private var devices: [PairedDevice]
    private var observers: [@Sendable ([PairedDevice]) -> Void] = []
    private var lastWrite = Date.distantPast
    private let fileURL = Config.directory.appendingPathComponent("devices.json")

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        devices = (try? decoder.decode([PairedDevice].self, from: Data(contentsOf: fileURL))) ?? []
    }

    var all: [PairedDevice] { lock.withLock { devices } }

    /// Adds a device and returns its new token (shown to the device once, never stored).
    func add(name: String, app: String?, network: NetworkKind) -> (PairedDevice, String) {
        let token = Config.randomHex(bytes: 32)
        let device = PairedDevice(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            name: name, app: app, network: network,
            pairedAt: Date(), lastSeen: Date(), tokenHash: Self.hash(token)
        )
        mutate { $0.append(device) }
        return (device, token)
    }

    func remove(_ id: String) {
        mutate { $0.removeAll { $0.id == id } }
    }

    func update(_ id: String, _ change: (inout PairedDevice) -> Void) {
        mutate { devices in
            guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
            change(&devices[i])
        }
    }

    /// Devices on a schedule that's being deleted go back to working all the time.
    func clearSchedule(_ scheduleId: String) {
        mutate { devices in
            for i in devices.indices where devices[i].scheduleId == scheduleId { devices[i].scheduleId = nil }
        }
    }

    /// The device a token belongs to, noting that it was just used.
    func authenticate(_ token: String) -> PairedDevice? {
        let hash = Self.hash(token)
        let (device, shouldSave) = lock.withLock { () -> (PairedDevice?, Bool) in
            guard let i = devices.firstIndex(where: { Self.constantTimeEquals($0.tokenHash, hash) }) else { return (nil, false) }
            devices[i].lastSeen = Date()
            // "Last used" only needs to be roughly right; don't rewrite the file on every press.
            let save = Date().timeIntervalSince(lastWrite) > 60
            return (devices[i], save)
        }
        if shouldSave { mutate { _ in } }
        return device
    }

    func observe(_ observer: @escaping @Sendable ([PairedDevice]) -> Void) {
        lock.withLock { observers.append(observer) }
    }

    private func mutate(_ change: (inout [PairedDevice]) -> Void) {
        let (next, observers) = lock.withLock { () -> ([PairedDevice], [@Sendable ([PairedDevice]) -> Void]) in
            change(&devices)
            lastWrite = Date()
            return (devices, self.observers)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(next) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        observers.forEach { $0(next) }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
