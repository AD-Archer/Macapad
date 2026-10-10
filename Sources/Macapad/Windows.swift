import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Settings window, the QR code and the pairing prompt. Both are plain AppKit windows hosting
/// SwiftUI, because a menu-bar-only app has no Dock icon to bring SwiftUI scenes forward.
@MainActor
final class Windows {
    private var settings: NSWindow?
    private var pairing: NSPanel?
    private var qr: NSWindow?

    func showSettings(_ state: AppState) {
        if settings == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(state: state)))
            window.title = "Macapad Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settings = window
        }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }

    func showQR(_ state: AppState) {
        if qr == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: QRPairView(state: state)))
            window.title = "Pair with QR Code"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            // The code pairs without asking, so it must stop working once nobody's looking at it.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { state.qrClosed() }
            }
            qr = window
        }
        NSApp.activate()
        qr?.makeKeyAndOrderFront(nil)
    }

    /// Shows the prompt while requests are waiting; closes it when none are left.
    func updatePairing(_ state: AppState) {
        guard !state.pending.isEmpty else {
            pairing?.orderOut(nil)
            return
        }
        if pairing == nil {
            let panel = NSPanel(contentViewController: NSHostingController(rootView: PairPrompt(state: state)))
            panel.title = "Pairing Request"
            panel.styleMask = [.titled, .nonactivatingPanel]
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            pairing = panel
        }
        guard let pairing, !pairing.isVisible else { return }
        pairing.center()
        NSApp.activate()
        pairing.makeKeyAndOrderFront(nil)
        NSSound(named: "Glass")?.play()
    }
}

struct PairPrompt: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let request = state.pending.first {
            VStack(spacing: 14) {
                Image(systemName: deviceIcon(request))
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(spacing: 4) {
                    Text("“\(request.name)” wants to control this Mac")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(subtitle(request))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 4) {
                    Text(request.code.map(String.init).joined(separator: " "))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("Check this matches the code on the device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                HStack {
                    Button("Don’t Allow", role: .cancel) { Pairing.shared.deny(request.id) }
                        .keyboardShortcut(.cancelAction)
                    Button("Allow") { Pairing.shared.approve(request.id) }
                }
                .controlSize(.large)
                if state.pending.count > 1 {
                    Text("\(state.pending.count - 1) more waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(width: 340)
        }
    }

    private func subtitle(_ request: PairRequest) -> String {
        var parts = ["From \(request.network.label)"]
        if request.network != .thisMac, !request.address.isEmpty { parts[0] += " (\(request.address))" }
        if let app = request.app { parts.append("using \(app)") }
        return parts.joined(separator: ", ")
    }

    private func deviceIcon(_ request: PairRequest) -> String {
        let name = (request.name + " " + (request.app ?? "")).lowercased()
        if name.contains("iphone") || name.contains("phone") { return "iphone" }
        if name.contains("ipad") || name.contains("tablet") { return "ipad" }
        if name.contains("echo") || name.contains("display") { return "display" }
        return "macbook.and.iphone"
    }
}

struct QRPairView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            if let link = state.qrLink, let image = Self.qrImage(link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                VStack(spacing: 4) {
                    Text("Scan with a Macapad app")
                        .font(.headline)
                    Text("The device pairs with \(state.settings.displayName) right away. Each code works once, then a new one appears.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let name = state.qrPaired {
                    Label("Paired “\(name)”", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Copy Pairing Link") { state.copy(link) }
                Text("Anyone who can see this code can control your Mac. Close this window when you’re done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No device can find this Mac")
                    .font(.headline)
                Text("Turn on “Let devices find this Mac” for your local network or Tailscale in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { state.windows.showSettings(state) }
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    /// Black-on-white QR code, one pixel per module (scaled up without smoothing).
    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("This Mac") {
                TextField("Name", text: state.setting(\.name), prompt: Text(Host.current().localizedName ?? "Mac"))
                Toggle("Open at login", isOn: Binding(get: { state.openAtLogin }, set: { state.setOpenAtLogin($0) }))
                    .disabled(!state.isBundled)
            }

            Section {
                Toggle("Allow connections", isOn: state.setting(\.lanAllowed))
                Toggle("Let devices find this Mac", isOn: state.setting(\.lanDiscoverable))
                    .disabled(!state.settings.lanAllowed)
            } header: {
                Text("Local network")
            } footer: {
                Text("Phones and tablets on your Wi-Fi can find this Mac and ask to pair.")
            }

            Section {
                Toggle("Allow connections", isOn: state.setting(\.tailscaleAllowed))
                Toggle("Let devices find this Mac", isOn: state.setting(\.tailscaleDiscoverable))
                    .disabled(!state.settings.tailscaleAllowed)
                LabeledContent("Address", value: state.tailscaleHost ?? "Tailscale isn’t running")
            } header: {
                Text("Tailscale")
            } footer: {
                Text("Devices on your tailnet find this Mac by checking each computer on it, so this works from anywhere.")
            }

            Section {
                Toggle("Allow connections from the internet", isOn: state.setting(\.internetAllowed))
            } header: {
                Text("Internet")
            } footer: {
                Text("Only needed for port forwarding or Tailscale Funnel. Devices can never pair from the internet.")
            }

            Section("Paired devices") {
                if state.devices.isEmpty {
                    Text("No devices yet. Pair one from a Macapad frontend on your phone or tablet.")
                        .foregroundStyle(.secondary)
                }
                Button("Pair with QR Code…") { state.showQR() }
                ForEach(state.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(details(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { Devices.shared.remove(device.id) }
                    }
                }
            }

            Section {
                LabeledContent("Owner token") {
                    Button("Copy") { state.copy(state.token ?? "") }
                }
                LabeledContent("Config folder") {
                    Button("Open") { NSWorkspace.shared.open(Config.directory) }
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("The owner token has full access and works from any allowed network. Paired devices get their own.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
    }

    private func details(_ device: PairedDevice) -> String {
        var parts: [String] = []
        if let app = device.app { parts.append(app) }
        parts.append("paired over \(device.network.label)")
        if let seen = device.lastSeen {
            parts.append("last used \(seen.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}
