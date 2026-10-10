import AppKit

struct StepError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Executes a button's steps in order, stopping at the first failure.
enum Runner {
    static func run(_ steps: [Step]) async throws {
        for (index, step) in steps.enumerated() {
            do {
                try await run(step)
            } catch {
                throw StepError(message: "Step \(index + 1): \(error.localizedDescription)")
            }
        }
    }

    static func run(_ step: Step) async throws {
        switch step {
        case .media(let key):
            await MainActor.run { Input.press(key) }
        case .keystroke(let combo):
            try Input.keystroke(combo)
        case .typeText(let text):
            try Input.type(text)
        case .openURL(let string):
            guard let url = URL(string: string), url.scheme != nil else {
                throw StepError(message: "'\(string)' is not a full URL (include https://)")
            }
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            if !opened { throw StepError(message: "Could not open \(string)") }
        case .openApp(let app):
            // A bundle id looks like "com.spotify.client"; anything else is treated as an app name.
            let isBundleID = app.contains(".") && !app.contains(" ") && !app.hasSuffix(".app")
            try await exec("/usr/bin/open", [isBundleID ? "-b" : "-a", app])
        case .shortcut(let name):
            try await exec("/usr/bin/shortcuts", ["run", name])
        case .appleScript(let source):
            try await exec("/usr/bin/osascript", ["-e", source])
        case .wait(let ms):
            try await Task.sleep(for: .milliseconds(max(0, min(ms, 60_000))))
        }
    }

    /// Runs a command-line tool and throws its error output if it fails.
    private static func exec(_ path: String, _ args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: StepError(message: output.isEmpty ? "\(path) exited with \(p.terminationStatus)" : output))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
