import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum DriverError: Error, CustomStringConvertible {
    case failure(String)
    var description: String { switch self { case .failure(let message): return message } }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func stringAttribute(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func walk(_ element: AXUIElement) -> [AXUIElement] { [element] + children(element).flatMap(walk) }
func waitFor<T>(_ description: String, timeout: TimeInterval = 60, probe: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline { if let value = probe() { return value }; Thread.sleep(forTimeInterval: 0.05) }
    throw DriverError.failure("timed out waiting for \(description)")
}
func findByIdentifier(_ root: AXUIElement, _ identifier: String) -> AXUIElement? {
    walk(root).first { stringAttribute($0, kAXIdentifierAttribute) == identifier }
}
func contains(_ root: AXUIElement, fragment: String) -> Bool {
    walk(root).contains { element in
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .contains { stringAttribute(element, $0).contains(fragment) }
    }
}
func replaceText(_ element: AXUIElement, with value: String, pid: pid_t) throws {
    guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
        throw DriverError.failure("could not focus FulcrumQuery")
    }
    // Use the Accessibility text-editing attributes rather than assigning
    // AXValue directly. SwiftUI's TextField exposes a writable value, but a
    // raw AXValue assignment updates the accessibility cache without sending
    // the editing notification that drives the Binding/onChange path. Replacing
    // the selected text is treated as a real native edit and therefore crosses
    // the same UI -> model -> RVT1 path as typing, without requiring the
    // GitHub runner's unavailable Input Monitoring permission.
    let existing = stringAttribute(element, kAXValueAttribute)
    var range = CFRange(location: 0, length: existing.utf16.count)
    if let rangeValue = AXValueCreate(.cfRange, &range),
       AXUIElementSetAttributeValue(element,
                                    kAXSelectedTextRangeAttribute as CFString,
                                    rangeValue) == .success,
       AXUIElementSetAttributeValue(element,
                                    kAXSelectedTextAttribute as CFString,
                                    value as CFString) == .success {
        _ = try waitFor("FulcrumQuery value \(value)", timeout: 5) {
            stringAttribute(element, kAXValueAttribute) == value ? true : nil
        }
        return
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let selectDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let selectUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false),
          let textDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let textUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        throw DriverError.failure("could not create keyboard events")
    }
    selectDown.flags = .maskCommand
    selectUp.flags = .maskCommand
    selectDown.postToPid(pid)
    selectUp.postToPid(pid)
    let utf16 = Array(value.utf16)
    textDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    textDown.postToPid(pid)
    textUp.postToPid(pid)
}
func pressReturn(pid: pid_t) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
        throw DriverError.failure("could not create Return key event")
    }
    down.postToPid(pid)
    up.postToPid(pid)
}
func snapshot(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
    var result: [String: Any] = ["role": stringAttribute(element, kAXRoleAttribute), "identifier": stringAttribute(element, kAXIdentifierAttribute), "title": stringAttribute(element, kAXTitleAttribute), "label": stringAttribute(element, kAXDescriptionAttribute), "value": stringAttribute(element, kAXValueAttribute)]
    if depth < 8 { result["children"] = children(element).map { snapshot($0, depth: depth + 1) } }
    return result
}
func writeJSON(_ value: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url) }

var diagnosticApplication: AXUIElement?
var diagnosticOutput: URL?
do {
    let arguments = CommandLine.arguments
    guard let pidIndex = arguments.firstIndex(of: "--pid"), pidIndex + 1 < arguments.count,
          let pid = Int32(arguments[pidIndex + 1]),
          let outputIndex = arguments.firstIndex(of: "--output"), outputIndex + 1 < arguments.count else {
        throw DriverError.failure("usage: macos-ax --pid PID --output DIRECTORY")
    }
    let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
    diagnosticOutput = output
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard AXIsProcessTrusted() else { throw DriverError.failure("accessibility access is unavailable") }
    NSPasteboard.general.clearContents()
    let application = AXUIElementCreateApplication(pid)
    diagnosticApplication = application
    let window: AXUIElement = try waitFor("Fulcrum window") { (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first }
    _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    let query: AXUIElement = try waitFor("FulcrumQuery") { findByIdentifier(window, "FulcrumQuery") }
    let acceptanceQuery: AXUIElement = try waitFor("FulcrumAcceptanceQuery") {
        findByIdentifier(window, "FulcrumAcceptanceQuery")
    }
    guard AXUIElementPerformAction(acceptanceQuery, kAXPressAction as CFString) == .success else {
        throw DriverError.failure("could not press FulcrumAcceptanceQuery")
    }
    _ = try waitFor("calculator result 144 from embedded backend") { contains(window, fragment: "144") ? true : nil }
    try writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility.json"))
    guard AXUIElementSetAttributeValue(query, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
        throw DriverError.failure("could not refocus FulcrumQuery before Return")
    }
    try pressReturn(pid: pid)
    _ = try waitFor("calculator action clipboard event") {
        NSPasteboard.general.string(forType: .string) == "144" ? true : nil
    }
    try writeJSON(["platform": "macos", "actions": ["set:FulcrumQuery=12*12", "press:Return"], "assertions": ["packaged SwiftUI window activated", "FulcrumQuery exposed through Accessibility", "query crossed RVT1 into the embedded backend", "native result list contains 144", "run-action emitted 144 to the native clipboard"]], to: output.appendingPathComponent("interaction-trace.json"))
    guard let running = NSRunningApplication(processIdentifier: pid), running.terminate() else { throw DriverError.failure("native application rejected termination") }
} catch {
    if let application = diagnosticApplication, let output = diagnosticOutput { try? writeJSON(snapshot(application), to: output.appendingPathComponent("accessibility-failure.json")) }
    FileHandle.standardError.write(Data("Fulcrum macOS acceptance failed: \(error)\n".utf8))
    exit(1)
}
