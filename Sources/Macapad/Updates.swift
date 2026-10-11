import AppKit
import Foundation
import SwiftUI

/// Where updates are at, for the menu and Settings.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    /// GitHub couldn't be reached. Only Settings shows this; being offline isn't worth a menu item.
    case checkFailed
    case available(String)
    case installing(String)
    /// Why, in the installer's words.
    case installFailed(String)
}

/// Updates from GitHub releases. A check asks github.com which release is the latest (nothing about this
/// Mac is sent). Installing runs that release's scripts/install.sh in the background, the same as the
/// one-command install: it builds the app here, swaps it into /Applications and opens the new copy,
/// which quits this one. Same certificate, so Accessibility access carries over.
enum Updates {
    static let repo = "AD-Archer/Macapad"
    static let installPath = "/Applications/Macapad.app"
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!
    static let homebrewCommand = "brew upgrade --cask macapad"
    /// The installer's output, for when an update fails.
    static let logURL = Config.directory.appendingPathComponent("update.log")
    static let checkEvery: TimeInterval = 6 * 60 * 60

    /// How this copy was installed, which decides how it updates.
    enum Method {
        /// The one-command install (or a downloaded zip) in /Applications: Macapad updates itself.
        case installer
        /// Homebrew owns the app; updating behind its back would confuse it.
        case homebrew
        /// Anywhere else, like a dev build in ~/Applications.
        case elsewhere
    }

    /// This copy's version; nil under `swift run`.
    static var current: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var method: Method {
        let casks = ["/opt/homebrew/Caskroom/macapad", "/usr/local/Caskroom/macapad"]
        if casks.contains(where: FileManager.default.fileExists(atPath:)) { return .homebrew }
        return Bundle.main.bundlePath == installPath ? .installer : .elsewhere
    }

    /// The latest release's version, like "0.3.14". releases/latest redirects to .../releases/tag/v0.3.14,
    /// like install.sh reads it, which also skips the API's rate limit.
    static func latest() async throws -> String {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let url = response.url?.absoluteString, let tag = url.range(of: "/tag/v") else {
            throw URLError(.badServerResponse)
        }
        let version = String(url[tag.upperBound...])
        // It goes into a shell command, so only digits and dots.
        guard !version.isEmpty, version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            throw URLError(.badServerResponse)
        }
        return version
    }

    /// "0.3.14" is newer than "0.3.9".
    static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    /// Starts installing `version` in the background. If the installer stops early, `failed` gets its
    /// last line; when it works, the new copy's launch quits this one first.
    static func install(_ version: String, failed: @escaping @Sendable (String) -> Void) throws {
        // install.sh asks for a password when it can't write here, and there's no Terminal to type it in.
        guard FileManager.default.isWritableFile(atPath: "/Applications") else {
            throw UpdateError("Your account can’t write to Applications. Run the install command in Terminal instead.")
        }
        try FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let tag = "v\(version)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "set -o pipefail; curl -fsSL https://raw.githubusercontent.com/\(repo)/\(tag)/scripts/install.sh | MACAPAD_REF=\(tag) bash",
        ]
        process.standardInput = FileHandle.nullDevice
        // A file, not a pipe: the installer outlives this app when it quits it.
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { process in
            try? log.close()
            guard process.terminationStatus != 0 else { return }
            failed(lastLine() ?? "The installer stopped (exit code \(process.terminationStatus)).")
        }
        try process.run()
    }

    /// The log's last line without install.sh's colours, e.g. "error: The build failed. The output above says why."
    private static func lastLine() -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init)
        return line?.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The menu bar's update line: only there when there's something to do.
struct UpdateMenuItems: View {
    @ObservedObject var state: AppState

    var body: some View {
        switch state.update {
        case .available(let version):
            switch Updates.method {
            case .installer:
                Button("Update to Macapad \(version)") { state.installUpdate(version) }
            case .homebrew:
                Button("Macapad \(version) Is Out: Copy Homebrew Command") { state.copy(Updates.homebrewCommand) }
            case .elsewhere:
                Button("Macapad \(version) Is Out…") { NSWorkspace.shared.open(Updates.releasesURL) }
            }
        case .installing(let version):
            Text("Updating to \(version)… (takes a few minutes)")
        case .installFailed(let why):
            Text("Update failed: \(why)")
            Button("Show What Happened") { NSWorkspace.shared.open(Updates.logURL) }
        default:
            EmptyView()
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section {
            LabeledContent("Version", value: Updates.current ?? "Run from source")
            Toggle("Check for updates", isOn: state.setting(\.checkForUpdates))
            if Updates.method == .installer {
                Toggle("Install updates by itself", isOn: state.setting(\.installUpdates))
                    .disabled(!state.settings.checkForUpdates)
            }
            HStack {
                Text(statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                actionButton
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(footer)
        }
    }

    private var statusText: String {
        switch state.update {
        case .idle: return Updates.current == nil ? "Updates need the app, not swift run" : "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .checkFailed: return "Couldn’t reach GitHub"
        case .available(let version): return "Macapad \(version) is out"
        case .installing(let version): return "Updating to \(version)…"
        case .installFailed(let why): return "Update failed: \(why)"
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch state.update {
        case .available(let version) where Updates.method == .installer:
            Button("Update") { state.installUpdate(version) }
        case .available where Updates.method == .homebrew:
            Button("Copy Command") { state.copy(Updates.homebrewCommand) }
        case .available:
            Button("Download") { NSWorkspace.shared.open(Updates.releasesURL) }
        case .installFailed:
            Button("Show What Happened") { NSWorkspace.shared.open(Updates.logURL) }
        case .checking, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check Now") { state.checkForUpdates() }
                .disabled(Updates.current == nil)
        }
    }

    private var footer: String {
        switch Updates.method {
        case .installer:
            return "Updating builds the new version on this Mac, like the install command, then reopens Macapad. It takes a few minutes and you keep Accessibility access."
        case .homebrew:
            return "Installed with Homebrew, so update with: \(Updates.homebrewCommand)"
        case .elsewhere:
            return "Macapad only updates itself from Applications. This copy is at \(Bundle.main.bundlePath)."
        }
    }
}
