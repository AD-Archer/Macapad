import AppKit
import Darwin
import Hummingbird
import HTTPTypes

/// What a controller holds and moves right now (docs/api.md, "Live input"). Clients send their
/// whole state each time rather than presses and releases, so a lost packet can't leave a key down.
struct InputState: Decodable, Sendable {
    /// The UDP session; WebSocket input doesn't need one.
    var s: String?
    /// Goes up with each packet; older ones (UDP can reorder) are dropped.
    var n: Int?
    /// Key names held, from the `keystroke` vocabulary, plus modifiers and media keys.
    var keys: [String]?
    /// left, right or middle; others are ignored.
    var buttons: [String]?
    /// Pointer movement since the previous packet, in points.
    var dx: Int?
    var dy: Int?
    /// Scroll since the previous packet, in pixels; positive sy shows content further down.
    var sx: Int?
    var sy: Int?
    /// Asks the Mac to answer `{"type":"ok"}`, so the client knows its input arrives.
    var ack: Bool?
}

struct InputSession: Codable, ResponseEncodable {
    var session: String
    var udpPort: Int
    /// Seconds without packets before the session ends.
    var expiresAfter: Int
}

/// Turns streamed input state from controllers into held keys, mouse buttons and pointer
/// movement. Consoles send it over UDP after asking for a session over HTTP; web clients send
/// `input` messages on the WebSocket. When several send at once, a key is down while any holds it.
final class LiveInput: @unchecked Sendable {
    static let shared = LiveInput()

    /// A session ends after this long without packets.
    static let sessionLifetime: TimeInterval = 30
    /// What a client holds is let go after this long without hearing from it.
    static let releaseAfter: TimeInterval = 0.5

    enum Reply {
        case ok
        /// Unknown or expired session: get a new one.
        case session
        case off(OffStatus)

        var json: String {
            switch self {
            case .ok: return #"{"type":"ok"}"#
            case .session:
                return Server.encode(["type": "error", "reason": "session", "message": "Unknown or expired session. Ask for a new one."])
            case .off(let off):
                return Server.encode(["type": "error", "reason": "off", "message": off.message, "off": off])
            }
        }
    }

    private struct Source {
        var caller: Caller
        var udp: Bool
        var heard = Date()
        var lastN = Int.min
        var keys: Set<String> = []
        var buttons: Set<MouseButton> = []
        /// Availability is checked at most once a second.
        var checked = Date.distantPast
        var off: OffStatus?
    }

    // Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "app.macapad.input", qos: .userInteractive)
    private var sources: [String: Source] = [:]
    private var heldKeys: Set<CGKeyCode> = []
    private var heldModifiers: [CGKeyCode: CGEventFlags] = [:]
    private var heldButtons: Set<MouseButton> = []
    /// Like a real keyboard, the last key pressed repeats while it's held.
    private var repeating: (key: CGKeyCode, next: Date)?
    /// Volume and brightness keys held down, and when each presses again.
    private var mediaRepeats: [MediaKey: Date] = [:]
    private static let repeatingMedia: Set<MediaKey> = [.volumeUp, .volumeDown, .brightnessUp, .brightnessDown]
    private var lastLeftDown: (at: Date, point: CGPoint, count: Int)?
    private var timer: DispatchSourceTimer?
    private var udpSocket: Int32 = -1
    private var udpSource: DispatchSourceRead?
    /// When each address was last sent an error, so a stream of bad packets gets one answer a second.
    private var lastError: [String: Date] = [:]
    private(set) var udpPort: Int?

    private var flags: CGEventFlags { heldModifiers.values.reduce(into: []) { $0.formUnion($1) } }

    // MARK: Sessions

    /// A new UDP session for this caller.
    func openSession(for caller: Caller) -> String {
        let id = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        queue.sync {
            if sources.count >= 32, let oldest = sources.min(by: { $0.value.heard < $1.value.heard })?.key {
                sources[oldest] = nil
                sync()
            }
            sources[id] = Source(caller: caller, udp: true)
            startTimer()
        }
        return id
    }

    /// Input from a WebSocket connection; `id` names the connection. Nil = nothing to answer.
    func webSocket(_ state: InputState, id: String, caller: Caller) -> Reply? {
        queue.sync {
            if sources[id] == nil {
                sources[id] = Source(caller: caller, udp: false)
                startTimer()
            }
            return handle(state, id: id)
        }
    }

    /// Lets go of everything a client held (its WebSocket closed).
    func remove(_ id: String) {
        queue.async {
            guard self.sources.removeValue(forKey: id) != nil else { return }
            self.sync()
        }
    }

    // MARK: UDP

    /// Listens for input packets on a UDP port (the same number as the HTTP one).
    func listen(port: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readPackets() }
        queue.sync {
            udpSocket = fd
            udpSource = source
            udpPort = port
        }
        source.resume()
    }

    private func readPackets() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udpSocket, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0 else { return }
            guard count <= 1024 else { continue }
            let address = String(cString: inet_ntoa(from.sin_addr))
            // The same network rules as HTTP: a refused network gets no answer at all.
            guard SettingsStore.shared.current.allows(Network.classify(remote: address, headers: HTTPFields())) else { continue }
            guard let state = try? JSONDecoder().decode(InputState.self, from: Data(buffer[0..<count])) else { continue }

            let reply: Reply?
            if let id = state.s, sources[id]?.udp == true {
                reply = handle(state, id: id)
            } else {
                reply = .session
            }
            guard let reply else { continue }
            if case .ok = reply {} else {
                if let last = lastError[address], Date().timeIntervalSince(last) < 1 { continue }
                lastError[address] = Date()
                if lastError.count > 64 { lastError = lastError.filter { Date().timeIntervalSince($0.value) < 5 } }
            }
            let bytes = Array(reply.json.utf8)
            withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(udpSocket, bytes, bytes.count, 0, $0, fromLength) }
            }
        }
    }

    // MARK: Applying input

    private func handle(_ state: InputState, id: String) -> Reply? {
        guard var source = sources[id] else { return .session }
        let now = Date()
        if now.timeIntervalSince(source.checked) >= 1 {
            source.checked = now
            guard let caller = Self.current(source.caller) else {
                // The device was removed in Settings.
                sources[id] = nil
                sync()
                return .session
            }
            source.caller = caller
            source.off = Availability.check(caller, settings: SettingsStore.shared.current)
        }
        source.heard = now
        if let off = source.off {
            source.keys = []
            source.buttons = []
            sources[id] = source
            sync()
            return .off(off)
        }
        if let n = state.n {
            guard n > source.lastN else { return nil }
            source.lastN = n
        }

        let keys = Set((state.keys ?? []).prefix(16))
        // Media keys press when they first show up; volume and brightness repeat while held (in sync and tick).
        for name in keys.subtracting(source.keys) {
            if let media = MediaKey(rawValue: name) { DispatchQueue.main.async { Input.press(media) } }
        }
        source.keys = keys
        source.buttons = Set((state.buttons ?? []).compactMap(MouseButton.init))
        sources[id] = source
        sync()

        let dx = Self.clamp(state.dx), dy = Self.clamp(state.dy)
        if dx != 0 || dy != 0 {
            let dragging = [MouseButton.left, .right, .middle].first { heldButtons.contains($0) }
            _ = try? Input.moveMouse(dx: dx, dy: dy, dragging: dragging, flags: flags)
        }
        try? Input.scroll(dx: Self.clamp(state.sx), dy: Self.clamp(state.sy), pixels: true)
        return state.ack == true ? .ok : nil
    }

    /// Presses and releases whatever differs between what every client holds and what's down now.
    private func sync() {
        var wantKeys = Set<CGKeyCode>()
        var wantModifiers: [CGKeyCode: CGEventFlags] = [:]
        var wantButtons = Set<MouseButton>()
        var wantMedia = Set<MediaKey>()
        for source in sources.values {
            wantButtons.formUnion(source.buttons)
            wantMedia.formUnion(source.keys.compactMap(MediaKey.init).filter(Self.repeatingMedia.contains))
            for name in source.keys {
                let key = name.lowercased()
                if let modifier = Input.modifier(key) {
                    wantModifiers[modifier.code] = modifier.flag
                } else if let code = Input.keyCode(key) {
                    wantKeys.insert(code)
                }
            }
        }

        // Keys up before their modifiers, modifiers down before their keys.
        for code in heldKeys.subtracting(wantKeys) {
            heldKeys.remove(code)
            postKey(code, down: false)
        }
        for code in Set(heldModifiers.keys).subtracting(wantModifiers.keys) {
            heldModifiers[code] = nil
            postModifier(code)
        }
        for (code, flag) in wantModifiers where heldModifiers[code] == nil {
            heldModifiers[code] = flag
            postModifier(code)
        }
        for code in wantKeys.subtracting(heldKeys) {
            heldKeys.insert(code)
            postKey(code, down: true)
            repeating = (code, Date().addingTimeInterval(NSEvent.keyRepeatDelay))
        }
        if let key = repeating?.key, !heldKeys.contains(key) { repeating = nil }
        mediaRepeats = mediaRepeats.filter { wantMedia.contains($0.key) }
        for key in wantMedia where mediaRepeats[key] == nil {
            mediaRepeats[key] = Date().addingTimeInterval(0.4)
        }

        let at = Input.pointer
        for button in heldButtons.subtracting(wantButtons) {
            heldButtons.remove(button)
            try? Input.mouse(down: false, button, at: at, clickState: button == .left ? lastLeftDown?.count ?? 1 : 1, flags: flags)
        }
        for button in wantButtons.subtracting(heldButtons) {
            heldButtons.insert(button)
            var clicks = 1
            if button == .left {
                // A second press soon after, in the same spot, is a double-click.
                if let last = lastLeftDown, Date().timeIntervalSince(last.at) < NSEvent.doubleClickInterval,
                   hypot(at.x - last.point.x, at.y - last.point.y) < 6 {
                    clicks = min(last.count + 1, 3)
                }
                lastLeftDown = (Date(), at, clicks)
            }
            try? Input.mouse(down: true, button, at: at, clickState: clicks, flags: flags)
        }
    }

    private func postKey(_ code: CGKeyCode, down: Bool, repeated: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
        else { return }
        event.flags = flags.union(Input.extraFlags(for: code))
        if repeated { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    private func postModifier(_ code: CGKeyCode) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true)
        else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    // MARK: Timer

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(15))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Lets go of what silent clients hold, ends old sessions, and repeats the held key.
    private func tick() {
        let now = Date()
        var changed = false
        for (id, source) in sources {
            let quiet = now.timeIntervalSince(source.heard)
            if quiet > Self.sessionLifetime {
                sources[id] = nil
                changed = true
            } else if quiet > Self.releaseAfter, !source.keys.isEmpty || !source.buttons.isEmpty {
                sources[id]?.keys = []
                sources[id]?.buttons = []
                changed = true
            }
        }
        if changed { sync() }
        if let (key, next) = repeating, now >= next {
            postKey(key, down: true, repeated: true)
            repeating = (key, now.addingTimeInterval(NSEvent.keyRepeatInterval))
        }
        for (key, next) in mediaRepeats where now >= next {
            DispatchQueue.main.async { Input.press(key) }
            mediaRepeats[key] = now.addingTimeInterval(0.12)
        }
        if sources.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Helpers

    /// The caller with its device and client as they are now; nil once the device is unpaired.
    private static func current(_ caller: Caller) -> Caller? {
        var caller = caller
        if let device = caller.device {
            guard let now = Devices.shared.all.first(where: { $0.id == device.id }) else { return nil }
            caller.device = now
        }
        if let client = caller.client {
            caller.client = Clients.shared.all.first { $0.id == client.id } ?? client
        }
        return caller
    }

    private static func clamp(_ value: Int?) -> Int { max(-500, min(value ?? 0, 500)) }
}
