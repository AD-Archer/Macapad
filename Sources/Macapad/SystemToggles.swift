import CoreWLAN
import Foundation

/// Mac settings a `toggle` step switches on and off.
enum SystemSetting: String, Codable, Sendable, CaseIterable {
    case wifi, bluetooth, hiddenFiles, stageManager, darkMode
}

enum SystemToggles {
    /// Turns a setting on or off; nil flips it.
    static func set(_ setting: SystemSetting, on: Bool?) async throws {
        switch setting {
        case .wifi:
            guard let wifi = CWWiFiClient.shared().interface() else { throw StepError(message: "This Mac has no Wi-Fi") }
            try wifi.setPower(on ?? !wifi.powerOn())
        case .bluetooth:
            try Bluetooth.setPower(on ?? !Bluetooth.isOn())
        case .hiddenFiles:
            var show = on ?? false
            if on == nil { show = await !readBool("com.apple.finder", "AppleShowAllFiles") }
            try await Runner.exec("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", show ? "true" : "false"])
            // Finder only rereads it when it starts, and relaunches by itself.
            try? await Runner.exec("/usr/bin/killall", ["Finder"])
        case .stageManager:
            var enable = on ?? false
            if on == nil { enable = await !readBool("com.apple.WindowManager", "GloballyEnabled") }
            try await Runner.exec("/usr/bin/defaults", ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", enable ? "true" : "false"])
        case .darkMode:
            let value = on.map { $0 ? "true" : "false" } ?? "not dark mode"
            try await Runner.exec("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)"])
        }
    }

    /// A boolean preference of another app; false when it isn't set.
    private static func readBool(_ domain: String, _ key: String) async -> Bool {
        let value = (try? await Runner.output("/usr/bin/defaults", ["read", domain, key])) ?? "0"
        return ["1", "true", "yes"].contains(value.lowercased())
    }
}

/// Bluetooth power through IOBluetooth's preference functions (what `blueutil` uses). They aren't
/// public, so they're looked up when needed and a macOS without them gets an error, not a crash.
private enum Bluetooth {
    private typealias Get = @convention(c) () -> Int32
    private typealias Set = @convention(c) (Int32) -> Void

    private static let framework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

    static func isOn() throws -> Bool {
        guard let symbol = framework.flatMap({ dlsym($0, "IOBluetoothPreferenceGetControllerPowerState") }) else {
            throw StepError(message: "This version of macOS doesn't let Macapad switch Bluetooth")
        }
        return unsafeBitCast(symbol, to: Get.self)() != 0
    }

    static func setPower(_ on: Bool) throws {
        guard let symbol = framework.flatMap({ dlsym($0, "IOBluetoothPreferenceSetControllerPowerState") }) else {
            throw StepError(message: "This version of macOS doesn't let Macapad switch Bluetooth")
        }
        unsafeBitCast(symbol, to: Set.self)(on ? 1 : 0)
    }
}
