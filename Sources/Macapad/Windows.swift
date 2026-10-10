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

/// What a "pause until a time" sheet pauses.
enum PauseTarget: Identifiable, Equatable {
    case all
    case device(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .device(let id): return "device-" + id
        }
    }
}

/// An open "pause until a time" sheet, with the time picked so far.
struct PausePrompt: Identifiable {
    let target: PauseTarget
    let date = Draft(Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date())
    var id: String { target.id }
}

/// An editable copy for a sheet. Sheets keep their state in one of these rather than `@State`,
/// which is a macro the Command Line Tools toolchain can't build.
final class Draft<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// The ways to pause, for the menu bar and Settings menus.
struct PauseOptions: View {
    let pause: (Date) -> Void
    let pickTime: () -> Void

    var body: some View {
        Button("For 1 Hour") { pause(Date().addingTimeInterval(3600)) }
        Button("Until Tomorrow Morning") { pause(Availability.tomorrowMorning()) }
        Button("Until I Turn It Back On") { pause(Availability.indefinitely) }
        Divider()
        Button("Until a Time…") { pickTime() }
    }
}

struct PauseUntilSheet: View {
    let title: String
    @ObservedObject var date: Draft<Date>
    let onPause: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            DatePicker("Until", selection: $date.value, in: Date()...)
                .datePickerStyle(.graphical)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pause") {
                    onPause(date.value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// A schedule being added or edited in its sheet.
final class EditingSchedule: ObservableObject, Identifiable {
    @Published var schedule: Schedule
    @Published var confirmDelete = false
    let isNew: Bool
    var id: String { schedule.id }

    init(_ schedule: Schedule, isNew: Bool) {
        self.schedule = schedule
        self.isNew = isNew
    }
}

struct ScheduleEditor: View {
    @ObservedObject var editing: EditingSchedule
    /// How many devices follow this schedule, for the delete warning.
    let usedBy: Int
    let onSave: (Schedule) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var schedule: Schedule {
        get { editing.schedule }
        nonmutating set { editing.schedule = newValue }
    }
    private var isNew: Bool { editing.isNew }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New Schedule" : "Edit Schedule").font(.headline)

            TextField("Name", text: $editing.schedule.name, prompt: Text("Work hours"))

            VStack(alignment: .leading, spacing: 8) {
                Text("Days")
                HStack(spacing: 4) {
                    ForEach(Schedule.weekOrder, id: \.self) { day in
                        Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: dayBinding(day))
                            .toggleStyle(.button)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("All day", isOn: Binding(
                    get: { schedule.allDay },
                    set: { allDay in
                        schedule.start = allDay ? 0 : 9 * 60
                        schedule.end = allDay ? 0 : 17 * 60
                    }
                ))
                if !schedule.allDay {
                    HStack(spacing: 16) {
                        DatePicker("From", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                    }
                    .fixedSize()
                    if schedule.end < schedule.start {
                        Text("Ends the next morning.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Label(schedule.summary, systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !isNew {
                    Button("Delete Schedule…", role: .destructive) { editing.confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var saved = schedule
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if saved.name.isEmpty { saved.name = "Schedule" }
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(schedule.days.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .confirmationDialog("Delete “\(schedule.name)”?", isPresented: $editing.confirmDelete) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text(usedBy == 0 ? "No devices use it."
                : "\(usedBy == 1 ? "1 device uses" : "\(usedBy) devices use") it. They’ll work at all times.")
        }
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { schedule.days.contains(day) },
            set: { on in
                schedule.days.removeAll { $0 == day }
                if on { schedule.days.append(day) }
                schedule.days.sort()
            }
        )
    }

    private func timeBinding(_ keyPath: WritableKeyPath<Schedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = schedule[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                if let until = state.pausedUntil {
                    HStack {
                        Label("Paused until \(Availability.describeUntil(until, now: state.now))", systemImage: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Resume") { state.pauseAll(until: nil) }
                    }
                } else {
                    LabeledContent("Pause all devices") {
                        Menu("Pause") {
                            PauseOptions { state.pauseAll(until: $0) } pickTime: { state.pausePrompt = PausePrompt(target: .all) }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("Pause")
            } footer: {
                Text("While paused, no device can run anything on this Mac. Handy when you’re away from it.")
            }

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
                            if let off = state.offStatus(device) {
                                Text(offLabel(off))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Picker("Works", selection: Binding(
                            get: { device.scheduleId.flatMap { id in state.settings.schedules.contains { $0.id == id } ? id : nil } },
                            set: { state.setSchedule(device, $0) }
                        )) {
                            Text("Always").tag(String?.none)
                            ForEach(state.settings.schedules) { schedule in
                                Text(schedule.name).tag(Optional(schedule.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("When this device works")
                        Menu {
                            if let until = device.pausedUntil, until > state.now {
                                Button("Resume") { state.pause(device, until: nil) }
                            } else {
                                Menu("Pause") {
                                    PauseOptions { state.pause(device, until: $0) } pickTime: {
                                        state.pausePrompt = PausePrompt(target: .device(device.id))
                                    }
                                }
                            }
                            Divider()
                            Button("Remove Device", role: .destructive) { Devices.shared.remove(device.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }

            Section {
                ForEach(state.settings.schedules) { schedule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(schedule.name)
                            Text(schedule.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { state.editingSchedule = EditingSchedule(schedule, isNew: false) }
                    }
                }
                Button("Add Schedule…") { state.editingSchedule = EditingSchedule(Schedule(), isNew: true) }
            } header: {
                Text("Schedules")
            } footer: {
                Text("Pick a schedule next to a device to set when it works, like an office macro pad that’s only on during work hours. Outside those hours its buttons do nothing.")
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
        .frame(width: 480, height: 680)
        .sheet(item: $state.editingSchedule) { item in
            ScheduleEditor(
                editing: item,
                usedBy: state.devices.filter { $0.scheduleId == item.id }.count,
                onSave: state.saveSchedule,
                onDelete: { state.deleteSchedule(item.schedule) }
            )
        }
        .sheet(item: $state.pausePrompt) { prompt in
            PauseUntilSheet(title: pauseTitle(prompt.target), date: prompt.date) { date in
                switch prompt.target {
                case .all: state.pauseAll(until: date)
                case .device(let id):
                    if let device = state.devices.first(where: { $0.id == id }) { state.pause(device, until: date) }
                }
            }
        }
    }

    private func pauseTitle(_ target: PauseTarget) -> String {
        switch target {
        case .all: return "Pause all devices until…"
        case .device(let id): return "Pause “\(state.devices.first { $0.id == id }?.name ?? "device")” until…"
        }
    }

    private func offLabel(_ off: OffStatus) -> String {
        let until = off.until.map { Availability.describe($0, now: state.now) } ?? "you turn it back on"
        return off.reason == .device ? "Paused until \(until)" : "Off until \(until)"
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
