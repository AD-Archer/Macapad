import AppKit
import CoreLocation
import CoreWLAN
import Foundation

/// Wi-Fi networks that mean you're somewhere, like "Work": the office network and its 5 GHz twin.
/// Saved in settings.json; each paired device and named client can be set to work only there.
struct WiFiPlace: Codable, Equatable, Sendable, Identifiable {
    var id = String(UUID().uuidString.prefix(8)).lowercased()
    var name = ""
    /// Wi-Fi names (SSIDs). The Mac is at this place while it's on any of them.
    var networks: [String] = []

    func contains(_ network: String?) -> Bool { network.map(networks.contains) ?? false }

    /// "Work Wi-Fi", or the name as it is when it already says Wi-Fi.
    var label: String {
        let lower = name.lowercased()
        return lower.hasSuffix("wi-fi") || lower.hasSuffix("wifi") ? name : "\(name) Wi-Fi"
    }

    /// "Office, Office-5G"
    var summary: String { networks.isEmpty ? "No networks" : networks.joined(separator: ", ") }
}

/// Which Wi-Fi this Mac is on. macOS only tells apps that have Location access, so this asks for
/// it (when someone adds a Wi-Fi place) and says when it can't tell.
final class WiFi: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = WiFi()

    enum Access: Equatable, Sendable {
        case allowed
        case notAsked
        /// Turned down, or Location Services are off for the whole Mac.
        case denied
    }

    private let lock = NSLock()
    private var status = Access.notAsked
    private var cached: (network: String?, at: Date)?
    private var observers: [@Sendable () -> Void] = []
    /// Made on the main thread, which gets its callbacks.
    private var manager: CLLocationManager?

    /// Call once at launch, on the main thread.
    func start() {
        let manager = CLLocationManager()
        manager.delegate = self
        self.manager = manager
        statusChanged(manager.authorizationStatus)
    }

    var access: Access { lock.withLock { status } }

    /// The Wi-Fi this Mac is on. Nil when Wi-Fi is off, it isn't on one, or macOS won't say.
    /// Every press checks it, so it's remembered for a couple of seconds.
    var current: String? {
        lock.withLock {
            if let cached, Date().timeIntervalSince(cached.at) < 2 { return cached.network }
            let network = CWWiFiClient.shared().interface()?.ssid()
            cached = (network, Date())
            return network
        }
    }

    /// Wi-Fi networks this Mac has joined before, in its preferred order. macOS lists these
    /// without Location access.
    var remembered: [String] {
        let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        return profiles.compactMap(\.ssid).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Shows macOS's Location prompt the first time; after that only System Settings can change it.
    @MainActor
    func requestAccess() {
        switch access {
        case .allowed: return
        case .notAsked:
            NSApp.activate()
            manager?.requestWhenInUseAuthorization()
        case .denied:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        }
    }

    /// Called when Location access changes.
    func observe(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(observer) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        statusChanged(manager.authorizationStatus)
    }

    private func statusChanged(_ authorization: CLAuthorizationStatus) {
        let next: Access
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse: next = .allowed
        case .notDetermined: next = .notAsked
        default: next = .denied
        }
        let observers = lock.withLock { () -> [@Sendable () -> Void] in
            status = next
            cached = nil  // the name may have been hidden until now
            return self.observers
        }
        observers.forEach { $0() }
    }
}
