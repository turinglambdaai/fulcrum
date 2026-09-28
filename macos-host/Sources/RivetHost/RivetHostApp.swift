import SwiftUI
import AppKit
import Carbon.HIToolbox
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct FulcrumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Owns the floating panel, the global hotkey, and the clipboard watcher.
/// The SwiftUI scene graph stays inside the panel's content view.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var clipboardTimer: Timer?
    private var lastPasteboardChange: Int = -1
    private(set) var model: LauncherModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        let launcherModel = LauncherModel()
        model = launcherModel
        installPanel(model: launcherModel)
        installHotkey()
        installClipboardWatcher(model: launcherModel)
        launcherModel.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: panel

    private func installPanel(model: LauncherModel) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = NSColor.windowBackgroundColor

        let hosting = NSHostingView(rootView: LauncherView().environmentObject(model))
        panel.contentView = hosting
        centerOnActiveScreen(panel)
        self.panel = panel

        model.onToggle = { [weak self] in self?.togglePanel() }
        model.onHide = { [weak self] in self?.hidePanel() }
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        let screens = NSScreen.screens
        let screen = screens.first { $0 == NSScreen.main } ?? screens.first ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height / 4 - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let panel else { return }
        centerOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.beginSearch()
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: global hotkey

    private func installHotkey() {
        // Alt+Space (Option-Space) first; Ctrl+Alt+Space as the honest
        // fallback when Option-Space is taken (some keyboard layouts bind it
        // to character input).
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         { _, event, _ -> OSStatus in
                                             AppDelegate.shared?.hotkeyFired(event)
                                             return noErr
                                         },
                                         1, &eventType, nil, &eventHandler)
        guard status == noErr else {
            model?.setPersistentStatus("Fulcrum could not install its global hotkey handler (OSStatus \(status)).")
            return
        }

        if !registerHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) {
            if registerHotkey(keyCode: UInt32(kVK_Space),
                              modifiers: UInt32(controlKey | optionKey)) {
                model?.setPersistentStatus("Fulcrum is ready — press ⌃⌥Space anywhere (⌥Space was taken).")
            } else {
                model?.setPersistentStatus("Both ⌥Space and ⌃⌥Space are taken by other tools. Release one and restart Fulcrum.")
            }
        }
    }

    private func registerHotkey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var hotKeyID = EventHotKeyID(signature: OSType(0x46454C43) /* FULC */,
                                     id: 1)
        _ = hotKeyID
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0,
                                         &hotkeyRef)
        return status == noErr
    }

    fileprivate func hotkeyFired(_ event: EventRef?) -> OSStatus {
        DispatchQueue.main.async { [weak self] in
            self?.togglePanel()
        }
        return noErr
    }

    // MARK: clipboard watcher

    private func installClipboardWatcher(model: LauncherModel) {
        lastPasteboardChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let api = model.api else { return }
            let changeCount = NSPasteboard.general.changeCount
            guard changeCount != self.lastPasteboardChange else { return }
            self.lastPasteboardChange = changeCount
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.isEmpty else { return }
            let payload = String(text.prefix(100_000))
            Task.detached {
                _ = try? await api.clipboardRecord(payload)
            }
        }
    }
}

/// Bridge from LauncherModel's requests back to the AppDelegate on the main
/// thread.
extension AppDelegate {
    static var shared: AppDelegate?
}
