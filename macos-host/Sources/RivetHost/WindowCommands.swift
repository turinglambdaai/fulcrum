import AppKit
import ApplicationServices

/// Native window management for the `win.*` engine actions, executed by
/// the host: the backend cannot see other apps' windows. Targets the
/// frontmost application's focused window through the Accessibility API,
/// which means the app needs the Accessibility permission — commands
/// honestly report failure until it is granted.
enum WindowCommands {

    static func perform(id: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let window = frontmostAXWindow() else { return false }

        switch id {
        case "win.left": return move(window, screen: screen(of: window),
                                     x: 0, y: 0, w: 0.5, h: 1.0)
        case "win.right": return move(window, screen: screen(of: window),
                                      x: 0.5, y: 0, w: 0.5, h: 1.0)
        case "win.maximize": return move(window, screen: screen(of: window),
                                         x: 0, y: 0, w: 1.0, h: 1.0)
        case "win.almost-max": return move(window, screen: screen(of: window),
                                           x: 0.05, y: 0.06, w: 0.9, h: 0.88)
        case "win.center": return center(window)
        case "win.restore": return restore(window)
        default: return false
        }
    }

    static var permissionHint: String {
        "Window commands need Accessibility: System Settings → Privacy & Security → Accessibility → Fulcrum"
    }

    /// Original geometry per window, for Restore. AXUIElement is not
    /// Hashable; key on the window's title + pid, good enough for the
    /// common case and self-healing when stale.
    // MainActor-confined in practice (every caller runs on the main
    // thread); matches RowIcon.cache's opt-out.
    fileprivate nonisolated(unsafe) static var savedFrames: [String: CGRect] = [:]

    private static func key(for window: AXUIElement) -> String {
        let pid = window_pid(window)
        return "\(pid):\(window_title(window))"
    }

    private static func frontmostAXWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let windows = value as? [AXUIElement],
              let window = windows.first else { return nil }
        return window
    }

    private static func frame(of window: AXUIElement) -> CGRect {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &size) == .success else { return .zero }
        let pos = position as! AXValue
        let sz = size as! AXValue
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos, .cgPoint, &p)
        AXValueGetValue(sz, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin),
              let sz = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos) == .success
            && AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz) == .success
    }

    private static func screen(of window: AXUIElement) -> NSScreen {
        let f = frame(of: window)
        return NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main ?? NSScreen()
    }

    /// Fractions are relative to the target screen's visibleFrame (the
    /// area not covered by the menu bar or the Dock), like Raycast.
    private static func move(_ window: AXUIElement, screen: NSScreen,
                             x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Bool {
        let area = screen.visibleFrame
        return setFrame(window, CGRect(
            x: area.minX + area.width * x,
            y: area.minY + area.height * y,
            width: area.width * w,
            height: area.height * h))
    }

    private static func center(_ window: AXUIElement) -> Bool {
        let screen = screen(of: window)
        let area = screen.visibleFrame
        let f = frame(of: window)
        if f == .zero { return false }
        return setFrame(window, CGRect(
            x: area.midX - f.width / 2,
            y: area.midY - f.height / 2,
            width: f.width, height: f.height))
    }

    private static func restore(_ window: AXUIElement) -> Bool {
        let k = key(for: window)
        guard let saved = savedFrames[k] else { return false }
        return setFrame(window, saved)
    }

    // Save the pre-tile frame whenever a move command runs, so Restore
    // works without any UI to manage snapshots.
    static func performAndRemember(id: String) -> Bool {
        guard AXIsProcessTrusted(), let window = frontmostAXWindow() else {
            return false
        }
        if ["win.left", "win.right", "win.maximize", "win.almost-max", "win.center"]
            .contains(id) {
            savedFrames[key(for: window)] = frame(of: window)
        }
        return perform(id: id)
    }

    private static func window_pid(_ window: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return pid
    }

    private static func window_title(_ window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString,
                                            &value) == .success,
              let title = value as? String else { return "" }
        return title
    }
}
