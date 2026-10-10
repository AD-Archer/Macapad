import AppKit
import Hummingbird
import IOKit.ps

/// `GET /api/status`: what the Mac is doing right now, for frontends with a screen to fill
/// (the clock, the song, a few numbers). Cheap enough to poll every couple of seconds.
struct MacStatus: Codable, ResponseEncodable {
    /// The Mac's clock, so a device with a wrong clock can show the right time.
    var time: Date
    /// Seconds east of UTC on the Mac, e.g. -14400 for New York in summer.
    var utcOffset: Int
    var mac: MacInfo
    /// The app in front, e.g. "Safari".
    var frontApp: String?
    var nowPlaying: NowPlaying?
    /// nil until the first fetch works (or with no internet).
    var weather: WeatherNow?
    var stats: MacStats
    /// Same as `/api/me`: set while this token can't run anything.
    var off: OffStatus?
}

struct NowPlaying: Codable, Sendable {
    /// The player's name, e.g. "Spotify" or "Safari".
    var app: String
    var bundleId: String?
    var playing: Bool
    var title: String
    var artist: String
    var album: String
    /// Milliseconds; 0 when the player doesn't say.
    var duration: Int
    var position: Int
    /// Changes when the track does. Fetch `/api/status/artwork` again when it changes; nil = no artwork.
    var artworkId: String?
}

struct MacStats: Codable, Sendable {
    /// Percent of all cores, 0–100, since the previous call (or over the last ~0.2s).
    var cpu: Double
    /// Bytes, the way Activity Monitor counts "Memory Used".
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    /// 0–100; nil on Macs without a battery.
    var battery: Int?
    var charging: Bool?
    var pluggedIn: Bool?
    /// Free bytes on the startup disk.
    var diskFree: UInt64?
    var diskTotal: UInt64?
    /// Seconds since boot.
    var uptime: Int
    /// nominal, fair, serious or critical
    var thermal: String
}

enum Status {
    static func current(mac: MacInfo, off: OffStatus?) async -> MacStatus {
        async let playing = NowPlayingReader.shared.current()
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        return MacStatus(
            time: Date(),
            utcOffset: TimeZone.current.secondsFromGMT(),
            mac: mac,
            frontApp: front,
            nowPlaying: await playing,
            weather: await Weather.shared.current(),
            stats: await stats(),
            off: off
        )
    }

    static func stats() async -> MacStats {
        let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let power = battery()
        return MacStats(
            cpu: await CPU.shared.percent(),
            memoryUsed: memoryUsed(),
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            battery: power?.percent,
            charging: power?.charging,
            pluggedIn: power?.pluggedIn,
            diskFree: disk?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
            diskTotal: disk?.volumeTotalCapacity.map { UInt64(max(0, $0)) },
            uptime: Int(ProcessInfo.processInfo.systemUptime),
            thermal: thermal()
        )
    }

    /// App memory + wired + compressed, like Activity Monitor's "Memory Used".
    private static func memoryUsed() -> UInt64 {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(info.internal_page_count) - UInt64(info.purgeable_count)
            + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private static func battery() -> (percent: Int, charging: Bool, pluggedIn: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                pluggedIn: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }

    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }
}

/// CPU use between two samples of the kernel's tick counters.
actor CPU {
    static let shared = CPU()
    private var last: (ticks: [UInt64], at: Date)?

    func percent() async -> Double {
        // no recent sample to compare against: take one, wait a moment, compare
        if last == nil || Date().timeIntervalSince(last!.at) > 10 {
            last = (Self.ticks(), Date())
            try? await Task.sleep(for: .milliseconds(200))
        }
        let now = Self.ticks()
        defer { last = (now, Date()) }
        guard let before = last?.ticks, before.count == 4, now.count == 4 else { return 0 }
        let delta = zip(now, before).map { $0 &- $1 }
        let total = delta.reduce(0, +)
        guard total > 0 else { return 0 }
        // user, system, idle, nice
        let busy = delta[0] + delta[1] + delta[3]
        return (Double(busy) / Double(total) * 1000).rounded() / 10
    }

    private static func ticks() -> [UInt64] {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [] }
        let t = info.cpu_ticks
        return [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]
    }
}

/// What's playing: the system-wide Now Playing info through mediaremote-adapter (any app; see
/// SystemNowPlaying), or else Spotify and Music asked over AppleScript. The first time AppleScript
/// is used, macOS asks whether Macapad may control each app.
actor NowPlayingReader {
    static let shared = NowPlayingReader()

    private struct Player {
        let name: String
        let bundleId: String
        let script: String
    }

    // One line, tab-separated: state, title, artist, album, duration ms, position ms, artwork url
    private static let players = [
        Player(name: "Spotify", bundleId: "com.spotify.client", script: """
        tell application id "com.spotify.client"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            return s & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t) as integer) & tab & ((player position * 1000) as integer) & tab & (artwork url of t)
        end tell
        """),
        Player(name: "Music", bundleId: "com.apple.Music", script: """
        tell application id "com.apple.Music"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            return s & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ((duration of t * 1000) as integer) & tab & ((player position * 1000) as integer) & tab & ""
        end tell
        """),
    ]

    private var cached: (value: NowPlaying?, at: Date)?
    /// Artwork for the current track, keyed by artworkId, at full size.
    private var artwork: (id: String, image: NSImage)?
    /// Where the artwork for an id comes from (a URL for Spotify, the player for Music, "system" for the adapter).
    private var artworkSource: [String: (player: String, url: String)] = [:]
    /// Artwork the adapter handed over, by artworkId.
    private var systemArtwork: [String: Data] = [:]

    func current() async -> NowPlaying? {
        // frontends poll; don't spawn osascript more than about once a second
        if let cached, Date().timeIntervalSince(cached.at) < 1 { return cached.value }
        let value = await read()
        cached = (value, Date())
        return value
    }

    private func read() async -> NowPlaying? {
        if let track = SystemNowPlaying.shared.current() {
            var id: String?
            if let key = track.artworkKey, let data = track.artwork {
                id = Self.hashId(key)
                remember(id!, source: ("system", ""))
                systemArtwork = [id!: data]
            }
            return NowPlaying(
                app: track.app, bundleId: track.bundleId, playing: track.playing, title: track.title,
                artist: track.artist, album: track.album, duration: track.duration, position: track.position, artworkId: id
            )
        }
        let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        var paused: NowPlaying?
        for player in Self.players where running.contains(player.bundleId) {
            guard let line = await Self.osascript(player.script), let track = parse(line, player: player) else { continue }
            if track.playing { return track }
            paused = paused ?? track
        }
        return paused
    }

    private func parse(_ line: String, player: Player) -> NowPlaying? {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 6, parts[0] != "stopped" else { return nil }
        let title = parts[1], artist = parts[2], album = parts[3]
        let id = Self.hashId("\(player.name)|\(title)|\(artist)|\(album)")
        let url = parts.count > 6 ? parts[6] : ""
        remember(id, source: (player.name, url))
        return NowPlaying(
            app: player.name,
            bundleId: player.bundleId,
            playing: parts[0] == "playing",
            title: title,
            artist: artist,
            album: album,
            duration: Int(parts[4]) ?? 0,
            position: Int(parts[5]) ?? 0,
            artworkId: (player.name == "Music" || !url.isEmpty) ? id : nil
        )
    }

    private static func hashId(_ key: String) -> String {
        String(format: "%08x", UInt32(truncatingIfNeeded: key.hashValue))
    }

    private func remember(_ id: String, source: (player: String, url: String)) {
        if artworkSource.count > 50 { artworkSource.removeAll() }
        artworkSource[id] = source
    }

    /// The current track's artwork as a square PNG, or nil when there isn't any.
    func artworkPNG(size: Int) async -> Data? {
        guard let track = await current(), let id = track.artworkId else { return nil }
        if artwork?.id != id {
            guard let image = await loadArtwork(id: id) else { return nil }
            artwork = (id, image)
        }
        guard let image = artwork?.image else { return nil }
        return await MainActor.run { Self.png(image, size: size) }
    }

    private func loadArtwork(id: String) async -> NSImage? {
        guard let source = artworkSource[id] else { return nil }
        if source.player == "system" {
            return systemArtwork[id].flatMap { NSImage(data: $0) }
        }
        if source.player == "Spotify" {
            guard let url = URL(string: source.url),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        // Music hands the artwork over as raw data; have it write a file we can read
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macapad-artwork-\(id)")
        let script = """
        tell application id "com.apple.Music"
            if (count of artworks of current track) is 0 then return "none"
            set d to raw data of artwork 1 of current track
        end tell
        set f to open for access (POSIX file "\(file.path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """
        guard await Self.osascript(script) == "ok", let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return NSImage(data: data)
    }

    @MainActor
    private static func png(_ image: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Runs AppleScript and returns what it printed, or nil if it failed.
    private static func osascript(_ source: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
