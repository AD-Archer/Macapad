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
    @Published var pending: [PairRequest] = []

    var token: String?
    let windows = Windows()
    private let bonjour = Bonjour()
    private var bonjourUpdate: Task<Void, Never>?
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

    func pendingChanged(_ next: [PairRequest]) {
        pending = next
        windows.updatePairing(self)
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func refresh() {
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
        Pairing.shared.observe { next in Task { @MainActor in state.pendingChanged(next) } }
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
        Button("Copy API URL (local network)") { state.copy(state.lanURL) }
        if let url = state.tailscaleURL {
            Button("Copy API URL (Tailscale)") { state.copy(url) }
        }
        if let token = state.token {
            Button("Copy API Token") { state.copy(token) }
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
