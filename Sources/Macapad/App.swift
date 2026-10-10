import AppKit
import ServiceManagement
import SwiftUI

@main
struct MacapadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: delegate.state)
        } label: {
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "square.grid.3x3.fill")
            }
        }
    }

    /// The face glyph from the app bundle, as a template so macOS tints it for light/dark menu bars.
    /// Missing when running unbundled via `swift run`.
    private static let menuBarIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "Macapad"
        return image
    }()
}

@MainActor
final class AppState: ObservableObject {
    @Published var status = "Starting…"
    @Published var running = false
    @Published var hasAccessibility = Input.hasPermission
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var tailscaleHost: String?
    @Published var settings = SettingsStore.shared.current
    @Published var devices = Devices.shared.all
    /// Screens, scripts and apps that named themselves with `X-Macapad-Client`.
    @Published var clients = Clients.shared.all
    @Published var pending: [PairRequest] = []
    /// The key in the QR code while its window is open.
    @Published var qrKey: String?
    /// The last device that scanned the QR code, while its window is open.
    @Published var qrPaired: String?
    /// Ticks with the refresh timer, so "paused until" labels clear themselves when time's up.
    @Published var now = Date()
    /// What the "pause until a time" sheet in Settings is for, while it's open.
    @Published var pausePrompt: PausePrompt?
    /// The schedule open in Settings' editor sheet.
    @Published var editingSchedule: EditingSchedule?

    var token: String?
    let windows = Windows()
    private let bonjour = Bonjour()
    private var bonjourUpdate: Task<Void, Never>?
    private var qrRefresh: Task<Void, Never>?
    let port = Int(ProcessInfo.processInfo.environment["MACAPAD_PORT"] ?? "") ?? 7317

    /// Login items only work from a real .app bundle, not `swift run`.
    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Base URL for frontends on the same network.
    var lanURL: String { "http://\(ProcessInfo.processInfo.hostName):\(port)" }

    /// Base URL through `tailscale serve` (HTTPS), reachable from anywhere on your tailnet.
    var tailscaleURL: String? { tailscaleHost.map { "https://\($0)" } }

    /// A binding that saves straight to settings.json.
    func setting<T>(_ keyPath: WritableKeyPath<MacapadSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in
                self.settings[keyPath: keyPath] = value  // right away, so text fields don't lag
                SettingsStore.shared.update { $0[keyPath: keyPath] = value }
            }
        )
    }

    /// When everything comes back on, while it's paused.
    var pausedUntil: Date? { settings.pausedUntil.flatMap { $0 > now ? $0 : nil } }

    /// Pauses every device (and the owner token) until a time; nil turns everything back on.
    func pauseAll(until: Date?) {
        SettingsStore.shared.update { $0.pausedUntil = until }
    }

    func pause(_ device: PairedDevice, until: Date?) {
        Devices.shared.update(device.id) { $0.pausedUntil = until }
    }

    func setSchedule(_ device: PairedDevice, _ scheduleId: String?) {
        Devices.shared.update(device.id) { $0.scheduleId = scheduleId }
    }

    func remove(_ device: PairedDevice) {
        Devices.shared.remove(device.id)
        Clients.shared.removeAll(deviceId: device.id)
    }

    func pause(_ client: Client, until: Date?) {
        Clients.shared.update(client.id) { $0.pausedUntil = until }
    }

    func setSchedule(_ client: Client, _ scheduleId: String?) {
        Clients.shared.update(client.id) { $0.scheduleId = scheduleId }
    }

    /// Named clients calling with a paired device's token, or with the owner token (nil).
    func clients(of deviceId: String?) -> [Client] {
        clients.filter { $0.deviceId == deviceId }
    }

    func saveSchedule(_ schedule: Schedule) {
        SettingsStore.shared.update { settings in
            if let i = settings.schedules.firstIndex(where: { $0.id == schedule.id }) {
                settings.schedules[i] = schedule
            } else {
                settings.schedules.append(schedule)
            }
        }
    }

    func deleteSchedule(_ schedule: Schedule) {
        Devices.shared.clearSchedule(schedule.id)
        Clients.shared.clearSchedule(schedule.id)
        SettingsStore.shared.update { $0.schedules.removeAll { $0.id == schedule.id } }
    }

    /// Why a device is off right now, leaving out a pause of the whole Mac (shown separately).
    func offStatus(_ device: PairedDevice) -> OffStatus? {
        offStatus(Caller(device: device))
    }

    /// Why a client is off right now, counting its device's pause and schedule.
    func offStatus(_ client: Client) -> OffStatus? {
        offStatus(Caller(device: devices.first { $0.id == client.deviceId }, client: client))
    }

    private func offStatus(_ caller: Caller) -> OffStatus? {
        var settings = settings
        settings.pausedUntil = nil
        return Availability.check(caller, settings: settings, now: now)
    }

    func settingsChanged(_ next: MacapadSettings) {
        settings = next
        // Wait for typing in the name field to settle before re-advertising.
        bonjourUpdate?.cancel()
        bonjourUpdate = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            bonjour.apply(settings, port: port)
        }
    }

    func startDiscovery() {
        bonjour.apply(settings, port: port)
    }

    /// Shows the QR code with a fresh key.
    func showQR() {
        qrPaired = nil
        issueQR()
        windows.showQR(self)
    }

    /// New key in the QR code, replaced again before it expires.
    func issueQR() {
        let key = QRPairing.shared.issue()
        qrKey = key
        qrRefresh?.cancel()
        qrRefresh = Task {
            try? await Task.sleep(for: .seconds(QRPairing.lifetime - 5))
            guard !Task.isCancelled, qrKey == key else { return }
            issueQR()
        }
    }

    /// The QR window closed: nobody can use its code any more.
    func qrClosed() {
        QRPairing.shared.revoke()
        qrRefresh?.cancel()
        qrKey = nil
        qrPaired = nil
    }

    /// A device scanned the code; show who, and a new code for the next one.
    func qrRedeemed(_ device: PairedDevice) {
        guard qrKey != nil else { return }
        qrPaired = device.name
        issueQR()
    }

    /// What the QR code holds: `macapad://pair?v=1&id=…&name=…&key=…&url=…&url=…`.
    /// The urls are every address a device could reach this Mac at, best first. Nil when
    /// the Mac can't be found on any network, so a code would never work.
    var qrLink: String? {
        guard let qrKey else { return nil }
        let interfaces = Network.localInterfaces()
        var urls: [String] = []
        if settings.discoverable(.lan) {
            // Wi-Fi and Ethernet are en*; skip link-local 169.254 addresses.
            urls += interfaces
                .filter { $0.name.hasPrefix("en") && $0.address.isPrivate && $0.address.bytes.first != 169 }
                .compactMap(\.address.v4String)
        }
        if settings.discoverable(.tailscale) {
            urls += interfaces.filter(\.address.isTailscale).compactMap(\.address.v4String)
        }
        let unique = urls.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !unique.isEmpty else { return nil }

        // Encode everything but unreserved characters (and : / which are fine in a query and
        // keep the code less dense), so any URL parser reads it back the same.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/")
        let encode = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let params = [("v", "1"), ("id", settings.id), ("name", settings.displayName), ("key", qrKey)]
            + unique.map { ("url", "http://\($0):\(port)") }
        return "macapad://pair?" + params.map { "\($0)=\(encode($1))" }.joined(separator: "&")
    }

    func pendingChanged(_ next: [PairRequest]) {
        pending = next
        windows.updatePairing(self)
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func refresh() {
        now = Date()
        hasAccessibility = Input.hasPermission
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Login item: \(error.localizedDescription)"
        }
        refresh()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let state = AppState()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only; no Dock icon (also set via LSUIElement in the bundle).
        NSApp.setActivationPolicy(.accessory)

        if !Input.hasPermission { Input.requestPermission() }

        let token: String
        do {
            token = try Config.loadOrCreateToken()
        } catch {
            state.status = "Config error: \(error.localizedDescription)"
            return
        }
        state.token = token

        let server = Server(token: token, port: state.port)
        let state = self.state

        SettingsStore.shared.observe { next in Task { @MainActor in state.settingsChanged(next) } }
        Devices.shared.observe { next in Task { @MainActor in state.devices = next } }
        Clients.shared.observe { next in Task { @MainActor in state.clients = next } }
        Pairing.shared.observe { next in Task { @MainActor in state.pendingChanged(next) } }
        QRPairing.shared.observe { device in Task { @MainActor in state.qrRedeemed(device) } }
        state.startDiscovery()
        Task.detached {
            await MainActor.run {
                state.running = true
                state.status = "Running on port \(state.port)"
            }
            do {
                try await server.run()
                await MainActor.run { state.status = "Server stopped" }
            } catch {
                await MainActor.run { state.status = "Server error: \(error.localizedDescription)" }
            }
            await MainActor.run { state.running = false }
        }

        Task.detached {
            let host = await Tailscale.dnsName()
            await MainActor.run { state.tailscaleHost = host }
        }

        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in state.refresh() }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.status)
        if let until = state.pausedUntil {
            Text("Paused until \(Availability.describeUntil(until, now: state.now))")
            Button("Resume") { state.pauseAll(until: nil) }
        } else {
            Menu("Pause All Devices") {
                PauseOptions { state.pauseAll(until: $0) } pickTime: {
                    state.pausePrompt = PausePrompt(target: .all)
                    state.windows.showSettings(state)
                }
            }
        }
        if let request = state.pending.first {
            Button("Pairing request from \(request.name)…") { state.windows.updatePairing(state) }
        }
        if !state.hasAccessibility {
            Button("⚠️ Grant Accessibility Access…") {
                Input.requestPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        Divider()
        Button("Pair with QR Code…") { state.showQR() }
        Divider()
        Button("Copy API URL (local network)") { state.copy(state.lanURL) }
        if let url = state.tailscaleURL {
            Button("Copy API URL (Tailscale)") { state.copy(url) }
        }
        if let token = state.token {
            Button("Copy API Token") { state.copy(token) }
        }
        Divider()
        Toggle("Docs Page", isOn: state.setting(\.docsEnabled))
        if state.settings.docsEnabled {
            Button("Open Docs Page") { NSWorkspace.shared.open(URL(string: "http://localhost:\(state.port)/")!) }
        }
        Divider()
        Button("Settings…") { state.windows.showSettings(state) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Macapad") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum Tailscale {
    /// This Mac's MagicDNS name (e.g. "my-mac.tailnet-123.ts.net"), if Tailscale is installed and up.
    static func dnsName() async -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String, !name.isEmpty
        else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}
