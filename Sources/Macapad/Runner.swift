import AppKit

struct StepError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Executes a button's steps in order, stopping at the first failure.
enum Runner {
    /// Actions can run other actions; this caps the nesting so a loop can't hang the app.
    private static let maxActionDepth = 4

    static func run(_ steps: [Step], depth: Int = 0) async throws {
        for (index, step) in steps.enumerated() {
            do {
                try await run(step, depth: depth)
            } catch where depth == 0 {
                // only the outermost list numbers its steps; nested actions pass errors up as-is
                throw StepError(message: "Step \(index + 1): \(error.localizedDescription)")
            }
        }
    }

    static func run(_ step: Step, depth: Int = 0) async throws {
        switch step {
        case .action(let id):
            guard let action = Actions.shared.find(id) else {
                throw StepError(message: "No action with id '\(id)'")
            }
            guard depth < maxActionDepth else {
                throw StepError(message: "Action '\(id)' nests too deeply (does it run itself?)")
            }
            do {
                try await run(action.steps, depth: depth + 1)
            } catch where depth == 0 {
                throw StepError(message: "\(action.name): \(error.localizedDescription)")
            }
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
