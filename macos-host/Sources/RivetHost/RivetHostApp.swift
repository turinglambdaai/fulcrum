import SwiftUI
import AppKit
import Carbon.HIToolbox
import RivetEmbedding
import RivetRuntime
import RivetSystem

// Launcher with no SwiftUI scenes: the panel, the About and the update
// windows are AppKit windows owned by the delegate. A Settings scene used to
// carry the About panel, but on current macOS every SwiftUI window scene
// presents its window at launch — users saw a stray "Fulcrum Settings"
// window behind the launcher on every start. Accessory activation: no Dock
// icon; the menu bar glyph and the hotkey are the ways in, the launcher
// convention.
@main
enum FulcrumApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate  // NSApplication.delegate is not retained
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// The fulcrum brand mark — a lever with a knob, balanced on a wedge over
/// a ground bar — drawn as a template image (pure black + alpha) so it
/// follows the menu bar's light/dark appearance. Drawn in code for the
/// same reason movebit's droplet is: SwiftPM resource bundles cannot ship
/// inside a signed rivet app bundle.
private enum MenuBarIcon {
    static var fulcrum: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Ground bar
            let ground = NSBezierPath()
            ground.lineWidth = 1.6
            ground.lineCapStyle = .round
            ground.move(to: NSPoint(x: 3.2, y: 2.2))
            ground.line(to: NSPoint(x: 14.8, y: 2.2))
            ground.stroke()

            // The wedge: the fulcrum itself
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: 5.4, y: 3.0))
            wedge.line(to: NSPoint(x: 12.6, y: 3.0))
            wedge.line(to: NSPoint(x: 9.0, y: 9.5))
            wedge.close()
            wedge.fill()

            // The lever rests on the wedge apex; the knob marks the raised end
            let lever = NSBezierPath()
            lever.lineWidth = 1.5
            lever.lineCapStyle = .round
            lever.move(to: NSPoint(x: 3.2, y: 7.0))
            lever.line(to: NSPoint(x: 15.0, y: 12.8))
            lever.stroke()

            let knob = NSBezierPath(ovalIn: NSRect(x: 13.3, y: 11.1, width: 3.4, height: 3.4))
            knob.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fulcrum"
        return image
    }
}

/// Owns the floating panel, the global hotkey, and the clipboard watcher.
/// The SwiftUI scene graph stays inside the panel's content view.
/// AppKit delegates run on the main thread; Swift 6 concurrency makes that
/// explicit with @MainActor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var hotkeyRef: EventHotKeyRef?
    private var activeHotkeySpec: String?
    private var eventHandler: EventHandlerRef?
    private var clipboardTimer: Timer?
    private var keyMonitor: Any?
    private var lastPasteboardChange: Int = -1
    private(set) var model: LauncherModel?
    // Retained for the process lifetime: dropping it releases the lock file.
    private var instanceLease: RivetSingleInstance?
    // Menu bar presence: the discoverable way in when the hotkey is
    // forgotten, and the only quit affordance (Esc just hides).
    private var menuBar: RivetMenuBarController?
    // Update flow (updater 0.2): panel window + RPC orchestration.
    private var updateController: UpdateController?
    private var updateWindow: NSWindow?
    // About panel (menu bar + app menu + the `about` launcher row).
    private var aboutWindow: NSWindow?
    // Settings window (app menu ⌘, + the `settings` launcher row).
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance owns the global hotkey; second launches exit here via
        // the first-party rivet lease instead of growing a second panel. The
        // lease is retained so the lock holds for the process lifetime.
        let applicationID = ProcessInfo.processInfo.environment["FULCRUM_INSTANCE_ID"]
            ?? "site.jrtx.fulcrum"
        if let lease = try? RivetSingleInstance(applicationID: applicationID) {
            guard lease.isPrimary else {
                NSApp.terminate(nil)
                return
            }
            instanceLease = lease
        }
        Self.shared = self
        let launcherModel = LauncherModel()
        model = launcherModel
        let updater = UpdateController()
        updateController = updater
        updater.attach(model: launcherModel)
        launcherModel.onBackendReady = { [weak self] in
            self?.backendReady()
        }
        installPanel(model: launcherModel)
        installHotkeyHandler()
        applyHotkey("alt+space")
        installKeyMonitor()
        installMenuBar(model: launcherModel)
        installMenus()
        installClipboardWatcher(model: launcherModel)
        launcherModel.start()
        if ProcessInfo.processInfo.environment["FULCRUM_ACCEPTANCE"] == "1" {
            showPanel()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Opening the app while it is already running (Finder, Spotlight,
    /// `open -a Fulcrum`) summons the panel — the launcher convention, and
    /// the way in for someone who has forgotten both the hotkey and the
    /// menu bar glyph. There is no Dock icon to click.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    // MARK: main menu

    /// Pure AppKit bootstrap means no default menus. This restores the
    /// keyboard plumbing the SwiftUI scene layer used to provide for free:
    /// ⌘Q, the Edit six for the query field (⌘V paste, ⌘A select all) and
    /// the selectable status text, ⌘W/⌘M on the About and update windows.
    /// Accessory app: the menus show only while one of its windows is key.
    private func installMenus() {
        let i18n = I18nService.shared
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: i18n.t("trayAbout"),
                        action: #selector(showAboutFromMenu(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: i18n.t("traySettings"),
                        action: #selector(showSettingsFromMenu(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(withTitle: i18n.t("trayCheckUpdates"),
                        action: #selector(checkForUpdatesFromMenu(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: i18n.t("trayQuit"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAboutFromMenu(_ sender: Any?) {
        showAboutPanel()
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        showSettingsWindow()
    }

    @objc private func checkForUpdatesFromMenu(_ sender: Any?) {
        updateController?.checkForUpdates()
        showUpdatePanel()
    }

    // MARK: backend readiness

    /// The embedded backend answered health: read the host-rendered
    /// settings (hotkey, theme, language) into the app and arm the
    /// throttled silent update check (the throttle itself lives
    /// backend-side, so this is one cheap RPC the backend may decline).
    private func backendReady() {
        guard let model else { return }
        Task { [weak self] in
            if let api = model.api {
                if let spec = try? await api.getHotkey() {
                    self?.applyHotkey(spec)
                }
                self?.refreshExpansionEngine()
                if let theme = try? await api.getTheme() {
                    Self.applyTheme(theme)
                }
                if let rows = try? await api.settingsList(),
                   let language = rows.first(where: { $0.id == "language" }) {
                    // settings-list puts the value in the title column.
                    self?.model?.setLanguage(language.title)
                    self?.rebuildLocalizedMenus()
                }
            }
            self?.updateController?.silentStartupCheck()
        }
    }

    // MARK: theme

    /// The theme setting is backend-owned (settings-as-rows); the host
    /// consumes it as the app-wide NSAppearance, which the panel vibrancy
    /// follows.
    @MainActor
    static func applyTheme(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: update panel

    /// The update panel lives in its own small window: the launcher panel is
    /// transient (Esc hides it), while the update flow must survive focus
    /// changes until the user decides.
    nonisolated func showUpdatePanel() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let controller = self.updateController ?? UpdateController()
            self.updateController = controller
            let window = self.updateWindow ?? Self.makeUpdateWindow(controller: controller)
            self.updateWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func makeUpdateWindow(controller: UpdateController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Fulcrum"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: UpdatePanelView(controller: controller))
        return window
    }

    // MARK: about panel

    /// About lives in its own small window: the launcher panel is
    /// transient (Esc hides it), while the About panel must survive focus
    /// changes until the user dismisses it.
    nonisolated func showAboutPanel() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let window = self.aboutWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 240),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "About Fulcrum"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: AboutPanelView())
            self.aboutWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: settings window

    /// The settings window: a form over the backend settings store, the
    /// discoverable twin of the `settings` query rows. One instance, shown
    /// again (and reloaded) on every request so edits made through the
    /// launcher rows in between are reflected.
    nonisolated func showSettingsWindow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let api = self.model?.api else {
                self.model?.setPersistentStatus("Settings open once the backend is ready…")
                return
            }
            let settings = self.settingsModel ?? SettingsModel(api: api) { [weak self] key, value in
                self?.settingChanged(key, value)
            }
            self.settingsModel = settings
            let window = self.settingsWindow ?? Self.makeSettingsWindow(model: settings)
            self.settingsWindow = window
            Task { await settings.load() }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func makeSettingsWindow(model: SettingsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Fulcrum Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        return window
    }

    /// Writes that need a host-side follow-up: theme and hotkey arrive via
    /// State pushes and need nothing here.
    private func settingChanged(_ key: String, _ value: String) {
        switch key {
        case "language":
            model?.setLanguage(value)
            rebuildLocalizedMenus()
        case "expansion-enabled":
            refreshExpansionEngine()
        default:
            break
        }
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
        // Launcher contract: once activated, leaving Fulcrum dismisses the
        // panel on every host. AppKit handles the handoff atomically here;
        // Linux carries the explicit pre-activation guard for Wayland.
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // The content view's vibrancy material owns the visuals; the panel
        // itself is transparent so the rounded corners read cleanly.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

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
        // Paste-to-frontmost hides the whole app so the keystroke lands in
        // the previous one; summoning again brings it back.
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        centerOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.beginSearch()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        // Snippets may have changed while the panel was open; the
        // expansion engine picks up the new trigger table now.
        refreshExpansionEngine()
    }

    /// Fetches snippets + the expansion setting and refreshes the engine.
    func refreshExpansionEngine() {
        guard let model else { return }
        Task { [weak self] in
            guard let api = model.api else { return }
            let snippets = (try? await api.snippets()) ?? []
            var enabled = true
            if let rows = try? await api.settingsList(),
               let row = rows.first(where: { $0.id == "expansion-enabled" }) {
                // settings-list puts the value (on/off) in the title column.
                enabled = row.title != "off"
            }
            self?.expansionEngine.refresh(enabled: enabled,
                                          snippets: snippets)
        }
    }

    var panelIsKey: Bool { NSApp.keyWindow === panel }
    let expansionEngine = ExpansionEngine.shared

    // MARK: global hotkey

    /// Installs the Carbon event handler once (it cannot capture context
    /// and hops to the main actor through AppDelegate.shared).
    private func installHotkeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         { _, _, _ -> OSStatus in
                                             DispatchQueue.main.async {
                                                 AppDelegate.shared?.hotkeyFired()
                                             }
                                             return noErr
                                         },
                                         1, &eventType, nil, &eventHandler)
        guard status == noErr else {
            model?.setPersistentStatus("Fulcrum could not install its global hotkey handler (OSStatus \(status)).")
            return
        }
    }

    /// Binds the launcher hotkey from the settings spec ("alt+space", …).
    /// Runs at launch with the default and again whenever the backend
    /// pushes the hotkey State (startup pull or a settings change). A spec
    /// that does not parse or a taken combo falls back to Ctrl+Alt+Space
    /// with a status note — the launcher must never end up unreachable.
    func applyHotkey(_ spec: String) {
        if let previous = hotkeyRef {
            UnregisterEventHotKey(previous)
            hotkeyRef = nil
        }
        if let binding = Hotkey.parse(spec),
           registerHotkey(keyCode: binding.keyCode, modifiers: binding.modifiers) {
            activeHotkeySpec = spec
        } else if registerHotkey(keyCode: UInt32(kVK_Space),
                                 modifiers: UInt32(controlKey | optionKey)) {
            activeHotkeySpec = "ctrl+alt+space"
            if spec != "ctrl+alt+space" {
                model?.setPersistentStatus(
                    "Fulcrum is ready — \(Hotkey.display(spec)) was taken, using ⌃⌥Space.")
                return
            }
        } else {
            model?.setPersistentStatus(
                "The hotkeys Fulcrum tried are taken by other tools. Change it in settings → hotkey, or release the combo and restart Fulcrum.")
            return
        }
        if model?.ready == true {
            model?.setPersistentStatus(
                "Ready — press \(Hotkey.display(activeHotkeySpec ?? spec)) anywhere")
        }
    }

    private func registerHotkey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x46454C43) /* FULC */,
                                     id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0,
                                         &ref)
        if status == noErr {
            hotkeyRef = ref
        }
        return status == noErr
    }

    fileprivate func hotkeyFired() {
        togglePanel()
    }

    // MARK: panel keys

    /// Esc/↑↓ while the query field keeps focus. A local monitor is the only
    /// reliable interception point: the field editor sits at the head of the
    /// responder chain, so a key-handling background view never sees keyDown.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let panel = self.panel,
                  panel.isVisible,
                  event.window === panel else { return event }
            switch event.keyCode {
            case 53:                              // esc
              // In the ⌘K panel: back to the search rows.
              if self.model?.showingActions == true {
                  self.model?.closeActions()
              } else if self.model?.detailView != nil {
                  // A plugin detail panel dismisses before anything else.
                  self.model?.dismissDetailView()
              } else if self.model?.aiStream != nil {
                  // A finished AI answer dismisses first; the launcher
                  // stays for the next query.
                  self.model?.dismissAiStream()
              } else if self.model?.query.isEmpty == true {
                  // Alfred/Raycast convention: clear the query first,
                  // hide only when it is already empty — a stray Esc
                  // never throws away typed text.
                  self.model?.hide()
              } else {
                  self.model?.clearQuery()
              }
            case 48:
                  self.model?.completeFromSelection()     // tab autocomplete
                  return nil
            case 40 where event.modifierFlags.contains(.command):
                  self.model?.openActionsForSelection()   // ⌘K
            case 125: self.model?.moveSelection(1)   // down
            case 126: self.model?.moveSelection(-1)  // up
            default:  return event
            }
            return nil
        }
    }

    // MARK: menu bar

    /// First-party rivet menu bar: the brand glyph as a template icon (a
    /// text title reads as another menu, an icon reads as a status item);
    /// Open runs the same toggle as the hotkey; Check for Updates opens
    /// the update panel; Quit here (or ⌘Q while a window is key) is the
    /// way out of the resident process — there is no Dock icon.
    private func installMenuBar(model: LauncherModel) {
        let i18n = I18nService.shared
        let controller = RivetMenuBarController()
        controller.install(
            icon: MenuBarIcon.fulcrum,
            items: [
                .action(label: i18n.t("trayOpen"), identifier: "open", handler: { [weak self] in
                    self?.showPanel()
                }),
                .action(label: i18n.t("traySettings"), identifier: "settings", handler: { [weak self] in
                    self?.showSettingsWindow()
                }),
                .action(label: i18n.t("trayCheckUpdates"), identifier: "update", handler: { [weak self] in
                    guard let self else { return }
                    self.updateController?.checkForUpdates()
                    self.showUpdatePanel()
                }),
                .action(label: i18n.t("trayAbout"), identifier: "about", handler: { [weak self] in
                    self?.showAboutPanel()
                }),
                .action(label: i18n.t("trayQuit"), identifier: "quit", handler: {
                    NSApp.terminate(nil)
                })
            ])
        menuBar = controller
    }

    private func rebuildLocalizedMenus() {
        installMenus()
        if let model { installMenuBar(model: model) }
    }

    func refreshLocalizedMenus() {
        rebuildLocalizedMenus()
    }

    // MARK: clipboard watcher

    private func installClipboardWatcher(model: LauncherModel) {
        lastPasteboardChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop; Swift 6 requires that to
            // be stated when touching MainActor state.
            MainActor.assumeIsolated {
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
}

/// The Carbon hotkey callback is a C function pointer and cannot capture
/// context; it hops to the main actor through this shared reference.
extension AppDelegate {
    nonisolated(unsafe) static var shared: AppDelegate?
}
