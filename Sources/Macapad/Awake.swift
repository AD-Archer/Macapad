import AppKit
import IOKit.pwr_mgt

/// One of the two "stay awake" modes, as `/api/status` reports it.
struct AwakeMode: Codable, Sendable, Equatable {
    var on: Bool
    /// When it turns itself off; nil while off or when it lasts until turned off.
    var until: Date?

    static let off = AwakeMode(on: false)
}

/// Keeps the Mac awake (no display or idle sleep), and the mouse jiggler, which nudges the
/// pointer when the Mac has been idle so it never counts as away. Both last until turned off,
/// their time runs out, or Macapad quits.
final class Awake: @unchecked Sendable {
    static let shared = Awake()

    enum Kind: Sendable { case keepAwake, jiggler }

    /// How long the Mac has to sit idle before the jiggler nudges the pointer.
    static let jiggleAfter: TimeInterval = 30

    private let lock = NSLock()
    private var modes: [Kind: AwakeMode] = [.keepAwake: .off, .jiggler: .off]
    private var observers: [@Sendable () -> Void] = []

    // Main thread only.
    private var assertion: IOPMAssertionID?
    private var timer: Timer?
    private var lastJiggle = Date.distantPast

    func mode(_ kind: Kind) -> AwakeMode {
        lock.withLock {
            let mode = modes[kind] ?? .off
            if let until = mode.until, until <= Date() { return .off }
            return mode
        }
    }

    /// Turns a mode on or off (nil flips it), for `minutes` or until turned off.
    @discardableResult
    func set(_ kind: Kind, on: Bool?, minutes: Int? = nil) -> AwakeMode {
        let turnOn = on ?? !mode(kind).on
        let until = turnOn ? minutes.map { Date().addingTimeInterval(TimeInterval(max(1, $0)) * 60) } : nil
        let next = AwakeMode(on: turnOn, until: until)
        lock.withLock { modes[kind] = next }
        DispatchQueue.main.async { self.apply() }
        return next
    }

    func observe(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(observer) }
    }

    /// Matches the power assertion and the timer to the modes. Main thread.
    private func apply() {
        let keepAwake = mode(.keepAwake).on, jiggler = mode(.jiggler).on
        if keepAwake, assertion == nil {
            var id = IOPMAssertionID(0)
            let made = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Macapad: Keep Mac awake" as CFString, &id
            )
            if made == kIOReturnSuccess { assertion = id }
        } else if !keepAwake, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }

        if keepAwake || jiggler, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.tick() }
        } else if !keepAwake, !jiggler {
            timer?.invalidate()
            timer = nil
        }
        for observer in lock.withLock({ observers }) { observer() }
    }

    /// Every few seconds while either mode is on: ends modes whose time is up, and jiggles.
    private func tick() {
        let expired = lock.withLock { () -> Bool in
            var changed = false
            for (kind, mode) in modes where mode.until.map({ $0 <= Date() }) ?? false {
                modes[kind] = .off
                changed = true
            }
            return changed
        }
        if expired { apply() }
        guard mode(.jiggler).on else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.jiggleAfter, Date().timeIntervalSince(lastJiggle) >= Self.jiggleAfter else { return }
        lastJiggle = Date()
        // A pixel over and straight back, so the pointer doesn't wander; the activity
        // declaration resets the idle timer even where synthetic events don't.
        let at = Input.pointer
        _ = try? Input.moveMouse(dx: 1, dy: 0, from: at)
        _ = try? Input.moveMouse(dx: -1, dy: 0, from: CGPoint(x: at.x + 1, y: at.y))
        var activity = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("Macapad mouse jiggler" as CFString, kIOPMUserActiveLocal, &activity)
    }
}
