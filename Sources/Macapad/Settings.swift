import AppKit
import Foundation

/// Where a request came from, as far as Macapad's settings care.
enum NetworkKind: String, Codable, Sendable {
    /// A program on this Mac (localhost or one of the Mac's own addresses).
    case thisMac
    /// Another device on the same Wi-Fi or Ethernet.
    case lan
    /// A device on your tailnet, directly or through `tailscale serve`.
    case tailscale
    /// Anything else: port forwarding, Tailscale Funnel, a VPN you didn't expect.
    case internet

    var label: String {
        switch self {
        case .thisMac: return "this Mac"
        case .lan: return "your local network"
        case .tailscale: return "Tailscale"
        case .internet: return "the internet"
        }
    }
}

/// What the menu bar's Settings window controls. Saved in ~/.macapad/settings.json.
struct MacapadSettings: Codable, Equatable, Sendable {
    /// Stable id for this Mac, so frontends can tell it's the same Mac on LAN and Tailscale.
    var id = UUID().uuidString.lowercased()
    /// Name shown to devices looking for this Mac. Empty = the Mac's own name.
    var name = ""
    var lanAllowed = true
    var lanDiscoverable = true
    var tailscaleAllowed = true
    var tailscaleDiscoverable = true
    var internetAllowed = false
    /// Serve the docs page at / (toggled in Settings).
    var docsEnabled = false
    /// While set and in the future, nothing runs, from any device. Far future = until turned back on.
    var pausedUntil: Date?
    /// Hours devices can be set to work in. Devices without one work all the time.
    var schedules: [Schedule] = [.workHours]
    /// Where the weather is for, like "Burlington, VT". Empty = wherever the Mac's internet connection says.
    var weatherPlace = ""
    /// Ask GitHub every few hours whether there's a newer Macapad.
    var checkForUpdates = true
    /// Install a newer Macapad as soon as one is found, instead of waiting for a click in the menu.
    var installUpdates = false

    /// The name to advertise and show in pairing.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (Host.current().localizedName ?? "Mac") : trimmed
    }

    func allows(_ network: NetworkKind) -> Bool {
        switch network {
        case .thisMac: return true
        case .lan: return lanAllowed
        case .tailscale: return tailscaleAllowed
        case .internet: return internetAllowed
        }
    }

    /// Whether devices on this network can see the Mac's details and ask to pair.
    /// Pairing is never offered to the internet.
    func discoverable(_ network: NetworkKind) -> Bool {
        switch network {
        case .thisMac: return true
        case .lan: return lanAllowed && lanDiscoverable
        case .tailscale: return tailscaleAllowed && tailscaleDiscoverable
        case .internet: return false
        }
    }

    init() {}

    // Decode field by field so settings files from older versions keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MacapadSettings()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        lanAllowed = try c.decodeIfPresent(Bool.self, forKey: .lanAllowed) ?? d.lanAllowed
        lanDiscoverable = try c.decodeIfPresent(Bool.self, forKey: .lanDiscoverable) ?? d.lanDiscoverable
        tailscaleAllowed = try c.decodeIfPresent(Bool.self, forKey: .tailscaleAllowed) ?? d.tailscaleAllowed
        tailscaleDiscoverable = try c.decodeIfPresent(Bool.self, forKey: .tailscaleDiscoverable) ?? d.tailscaleDiscoverable
        internetAllowed = try c.decodeIfPresent(Bool.self, forKey: .internetAllowed) ?? d.internetAllowed
        docsEnabled = try c.decodeIfPresent(Bool.self, forKey: .docsEnabled) ?? d.docsEnabled
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        schedules = try c.decodeIfPresent([Schedule].self, forKey: .schedules) ?? d.schedules
        weatherPlace = try c.decodeIfPresent(String.self, forKey: .weatherPlace) ?? d.weatherPlace
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        installUpdates = try c.decodeIfPresent(Bool.self, forKey: .installUpdates) ?? d.installUpdates
    }
}

final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()

    private let lock = NSLock()
    private var value: MacapadSettings
    private var observers: [@Sendable (MacapadSettings) -> Void] = []
    private let fileURL = Config.directory.appendingPathComponent("settings.json")

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode(MacapadSettings.self, from: Data(contentsOf: fileURL)) {
            value = saved
        } else {
            value = MacapadSettings()
            write(value)
        }
    }

    var current: MacapadSettings { lock.withLock { value } }

    func update(_ change: (inout MacapadSettings) -> Void) {
        let (next, changed, observers) = lock.withLock { () -> (MacapadSettings, Bool, [@Sendable (MacapadSettings) -> Void]) in
            var next = value
            change(&next)
            let changed = next != value
            value = next
            return (next, changed, self.observers)
        }
        guard changed else { return }
        write(next)
        observers.forEach { $0(next) }
    }

    /// Called after every change (on the caller's thread).
    func observe(_ observer: @escaping @Sendable (MacapadSettings) -> Void) {
        lock.withLock { observers.append(observer) }
    }

    private func write(_ settings: MacapadSettings) {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
