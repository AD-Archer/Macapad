import AppKit

/// The system-wide Now Playing info (what Control Center shows, from any app), read through
/// mediaremote-adapter: macOS only lets Apple-signed processes use MediaRemote, so `/usr/bin/perl`
/// loads the adapter's framework and streams JSON lines to us. See Vendor/mediaremote-adapter/VENDORED.md.
///
/// Starts on first use and keeps running. When it isn't bundled, keeps dying or has nothing,
/// callers fall back to asking Spotify and Music.
final class SystemNowPlaying: @unchecked Sendable {
    static let shared = SystemNowPlaying()

    struct Track {
        var bundleId: String
        var app: String
        var playing: Bool
        var title: String
        var artist: String
        var album: String
        var duration: Int
        var position: Int
        /// Changes with the track, and again when its artwork shows up (it often arrives a moment later).
        var artworkKey: String?
        var artwork: Data?
    }

    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    /// The merged payload (the stream sends diffs).
    private var state: [String: Any] = [:]
    private var receivedAny = false
    private var lastStart: Date?
    /// Starts in a row that ended without sending anything; after a few we give up.
    private var deadStarts = 0
    private var appNames: [String: String] = [:]

    /// What's playing, or nil when nothing is (or the adapter isn't working).
    func current() -> Track? {
        lock.lock()
        defer { lock.unlock() }
        startIfNeeded()
        return receivedAny ? track() : nil
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    // MARK: Process

    private static func adapterFiles() -> (script: URL, framework: URL)? {
        // bundled app first, then a `swift run` from the repo after `just build`
        let candidates: [(URL, URL)] = [
            Bundle.main.resourceURL.map {
                ($0.appendingPathComponent("MediaRemoteAdapter/mediaremote-adapter.pl"),
                 $0.appendingPathComponent("MediaRemoteAdapter/MediaRemoteAdapter.framework"))
            },
            (URL(fileURLWithPath: "Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"),
             URL(fileURLWithPath: "build/mediaremote-adapter/MediaRemoteAdapter.framework")),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.0.path) && FileManager.default.fileExists(atPath: $0.1.path) }
            .map { (script: $0.0.standardizedFileURL, framework: $0.1.standardizedFileURL) }
    }

    /// Call with the lock held.
    private func startIfNeeded() {
        guard process == nil, deadStarts < 5 else { return }
        if let lastStart, Date().timeIntervalSince(lastStart) < 10 { return }
        guard let files = Self.adapterFiles() else {
            deadStarts = 5
            return
        }
        if lastStart == nil {
            // one left over from a Macapad that crashed or was force-quit (a normal quit stops it)
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            cleanup.arguments = ["-f", files.framework.path]
            try? cleanup.run()
            cleanup.waitUntilExit()
        }
        lastStart = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script.path, files.framework.path, "stream", "--micros", "--debounce=100"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.received(data)
            }
        }
        p.terminationHandler = { [weak self] _ in self?.ended() }
        do {
            try p.run()
            process = p
        } catch {
            deadStarts += 1
        }
    }

    private func ended() {
        lock.lock()
        defer { lock.unlock() }
        process = nil
        buffer.removeAll()
        if !receivedAny { deadStarts += 1 }
        receivedAny = false
        state = [:]
    }

    private func received(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  message["type"] as? String == "data",
                  let payload = message["payload"] as? [String: Any] else { continue }
            if message["diff"] as? Bool == true {
                for (key, value) in payload {
                    if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
                }
            } else {
                state = payload
            }
            receivedAny = true
            deadStarts = 0
        }
    }

    // MARK: Payload

    /// Call with the lock held.
    private func track() -> Track? {
        guard let bundleId = state["bundleIdentifier"] as? String,
              let title = state["title"] as? String, !title.isEmpty else { return nil }
        // a web page playing in Safari reports its WebKit process; show the browser
        let owner = state["parentApplicationBundleIdentifier"] as? String ?? bundleId
        let playing = state["playing"] as? Bool ?? false
        let duration = (state["durationMicros"] as? NSNumber)?.int64Value ?? 0
        var elapsed = (state["elapsedTimeMicros"] as? NSNumber)?.int64Value ?? 0
        if playing, let at = (state["timestampEpochMicros"] as? NSNumber)?.int64Value {
            elapsed += Int64(Date().timeIntervalSince1970 * 1_000_000) - at
        }
        if duration > 0 { elapsed = min(elapsed, duration) }
        let artist = state["artist"] as? String ?? ""
        let album = state["album"] as? String ?? ""
        let artwork = (state["artworkData"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        let key = artwork.map { "\(owner)|\(title)|\(artist)|\(album)|\($0.count)" }
        return Track(
            bundleId: owner,
            app: appName(owner),
            playing: playing,
            title: title,
            artist: artist,
            album: album,
            duration: Int(duration / 1000),
            position: Int(max(0, elapsed) / 1000),
            artworkKey: key,
            artwork: artwork
        )
    }

    /// "com.spotify.client" -> "Spotify". Call with the lock held.
    private func appName(_ bundleId: String) -> String {
        if let name = appNames[bundleId] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: #"\.app$"#, with: "", options: .regularExpression) }
            ?? bundleId
        appNames[bundleId] = name
        return name
    }
}
