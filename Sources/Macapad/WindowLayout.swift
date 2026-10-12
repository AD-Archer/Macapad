import AppKit
import ApplicationServices

/// Moves and resizes the front window through the Accessibility API (the same permission
/// Macapad already needs for key presses).
@MainActor
enum WindowLayout {
    /// Where windows were before Macapad last moved them, for `restore`. Newest last.
    private static var before: [(window: AXUIElement, frame: CGRect)] = []

    static func move(_ placement: WindowPlacement) throws {
        guard AXIsProcessTrusted() else {
            throw StepError(message: "Macapad needs Accessibility access to move windows (System Settings > Privacy & Security)")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw StepError(message: "No app is in front") }
        let name = app.localizedName ?? "The app in front"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attribute(axApp, kAXFocusedWindowAttribute), let frame = frame(of: window) else {
            throw StepError(message: "\(name) has no window to move")
        }

        if placement == .restore {
            guard let i = before.lastIndex(where: { CFEqual($0.window, window) }) else {
                throw StepError(message: "Macapad hasn't moved this window, so there's nothing to restore")
            }
            set(window, of: axApp, to: before.remove(at: i).frame)
            return
        }

        let screens = NSScreen.screens.map { axRect($0.visibleFrame) }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let current = screens.firstIndex(where: { $0.contains(center) })
            ?? screens.firstIndex(where: { $0.intersects(frame) }) ?? screens.indices.first
        else { throw StepError(message: "No screen found") }
        let target = rect(for: placement, frame: frame, in: screens[current],
                          next: screens[(current + 1) % screens.count])

        before.removeAll { CFEqual($0.window, window) }
        before.append((window, frame))
        if before.count > 30 { before.removeFirst() }
        set(window, of: axApp, to: target)
    }

    /// The frame for a placement, in Accessibility coordinates (top-left origin).
    private static func rect(for placement: WindowPlacement, frame: CGRect, in s: CGRect, next: CGRect) -> CGRect {
        func part(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: s.minX + s.width * x, y: s.minY + s.height * y, width: s.width * w, height: s.height * h).integral
        }
        switch placement {
        case .left: return part(0, 0, 0.5, 1)
        case .right: return part(0.5, 0, 0.5, 1)
        case .top: return part(0, 0, 1, 0.5)
        case .bottom: return part(0, 0.5, 1, 0.5)
        case .topLeft: return part(0, 0, 0.5, 0.5)
        case .topRight: return part(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return part(0, 0.5, 0.5, 0.5)
        case .bottomRight: return part(0.5, 0.5, 0.5, 0.5)
        case .leftThird: return part(0, 0, 1 / 3, 1)
        case .centerThird: return part(1 / 3, 0, 1 / 3, 1)
        case .rightThird: return part(2 / 3, 0, 1 / 3, 1)
        case .leftTwoThirds: return part(0, 0, 2 / 3, 1)
        case .rightTwoThirds: return part(1 / 3, 0, 2 / 3, 1)
        case .maximize: return s
        case .center:
            let w = min(frame.width, s.width), h = min(frame.height, s.height)
            return CGRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h).integral
        case .nextDisplay:
            // Same place and share of the screen, on the next one.
            let x = (frame.minX - s.minX) / s.width, y = (frame.minY - s.minY) / s.height
            let w = min(1, frame.width / s.width), h = min(1, frame.height / s.height)
            return CGRect(x: next.minX + next.width * max(0, min(x, 1 - w)), y: next.minY + next.height * max(0, min(y, 1 - h)),
                          width: next.width * w, height: next.height * h).integral
        case .restore: return frame
        }
    }

    private static func set(_ window: AXUIElement, of app: AXUIElement, to rect: CGRect) {
        // Apps with "enhanced UI" on (turned on by some assistive tools) animate each change
        // and drop the second one, so switch it off while moving.
        let enhanced: Bool? = attribute(app, "AXEnhancedUserInterface")
        if enhanced == true { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        // Size, move, size again: a window too big for where it's going gets clamped on the first try.
        setSize(window, rect.size)
        setPosition(window, rect.origin)
        setSize(window, rect.size)
        if enhanced == true { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    /// NSScreen rects have their origin at the bottom-left of the main screen; Accessibility's is at its top-left.
    private static func axRect(_ r: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? r.height
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(window, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
