import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Settings window state: one string per backend key, written through the
/// settings-set RPC as the user edits. The backend owns validation (hotkey
/// grammar, numeric ranges, provider names); a refusal surfaces inline and
/// the form reloads the backend's truth instead of keeping a value that
/// never landed. The query-syntax rows in the launcher keep working — this
/// window is the discoverable face of the same settings store.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var values: [String: String] = [:]
    @Published var error: String?
    @Published var aiStatus = ""
    @Published var aiKeyDraft = ""
    @Published var aiKeyNotice = ""
    // Per-command bindings (#48): what is bindable, what is bound, and the
    // id currently recording a hotkey (drives the inline "Press keys…" UI).
    @Published var commands: [[String]] = []
    @Published var bindings: [[String]] = []
    @Published var recordingId: String?
    @Published var bindingError: String?

    private let api: FulcrumAPI
    /// Host side effects that must follow a write (language table, the
    /// snippet expansion engine); theme and hotkey arrive via State pushes.
    private let onChanged: (String, String) -> Void

    init(api: FulcrumAPI, onChanged: @escaping (String, String) -> Void) {
        self.api = api
        self.onChanged = onChanged
    }

    func load() async {
        if let rows = try? await api.settingsList() {
            var loaded: [String: String] = [:]
            for row in rows {
                // settings-list rows carry the value in the title column.
                loaded[row.id] = row.title
            }
            values = loaded
        }
        await refreshAiStatus()
    }

    func refreshAiStatus() async {
        aiStatus = (try? await api.aiStatus()) ?? ""
    }

    func set(_ key: String, _ value: String) {
        guard values[key] != value else { return }
        values[key] = value
        Task {
            do {
                let accepted = try await api.settingsSet(key: key, value: value)
                if accepted {
                    error = nil
                    onChanged(key, value)
                    if key == "ai-provider" {
                        await refreshAiStatus()
                    }
                } else {
                    self.error = key == "hotkey"
                        ? "That shortcut is not supported. Record another key combination."
                        : "\(key): that value is not supported."
                    await load()
                }
            } catch {
                self.error = "\(key): the setting could not be saved."
                await load()
            }
        }
    }

    func saveAiKey() {
        let key = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            let status = (try? await api.runAction(id: "ai.key", arg: key)) ?? "error"
            aiKeyNotice = status == "ok"
                ? "Key saved — stored on this Mac only, never synced."
                : status
            aiKeyDraft = ""
            await refreshAiStatus()
        }
    }

    // ---- per-command bindings (#48) ---------------------------------------

    func loadBindings() async {
        commands = (try? await api.bindingsCommands()) ?? []
        bindings = (try? await api.bindingsList()) ?? []
    }

    private func currentBinding(_ id: String) -> [String]? {
        bindings.first(where: { $0.first == id })
    }

    func saveBinding(id: String, alias: String, hotkey: String) {
        Task {
            do {
                let ok = try await api.bindingSet(id: id, alias: alias, hotkey: hotkey)
                if ok {
                    bindingError = nil
                } else {
                    // The backend refuses duplicates, the summon hotkey, and
                    // unknown commands; say so instead of blinking.
                    bindingError = "\(id): the backend refused this binding (taken combo, the summon hotkey, or an unknown command)."
                }
                await loadBindings()
            } catch {
                bindingError = "\(id): \(error)"
            }
        }
    }

    func clearBinding(id: String) {
        Task {
            _ = try? await api.bindingClear(id: id)
            await loadBindings()
        }
    }

    /// A recorded combo lands here from HotkeyRecorder; empty spec means
    /// the user cancelled with Esc.
    func recordFinished(id: String, spec: String?) {
        recordingId = nil
        guard let spec, !spec.isEmpty else { return }
        let alias = currentBinding(id)?[1] ?? ""
        saveBinding(id: id, alias: alias, hotkey: spec)
    }

    func isOn(_ key: String) -> Bool {
        values[key] == "on"
    }

    func toggle(_ key: String) -> Binding<Bool> {
        Binding(get: { self.isOn(key) },
                set: { self.set(key, $0 ? "on" : "off") })
    }

    func choice(_ key: String, default fallback: String = "") -> Binding<String> {
        Binding(get: { self.values[key] ?? fallback },
                set: { self.set(key, $0) })
    }

    func number(_ key: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { Int(self.values[key] ?? "") ?? fallback },
                set: { self.set(key, String($0)) })
    }
}

/// A text field that commits on ⏎ and on losing focus — never per
/// keystroke, so the backend validates whole values (a half-typed hotkey
/// would be refused on every character otherwise).
private struct SettingField: View {
    let title: String
    let key: String
    var placeholder = ""
    @ObservedObject var model: SettingsModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft, prompt: Text(placeholder))
            .focused($focused)
            .onAppear { draft = model.values[key] ?? "" }
            .onChange(of: model.values[key]) { _, current in
                if !focused { draft = current ?? "" }
            }
            .onSubmit { commit() }
            .onChange(of: focused) { _, now in
                if !now { commit() }
            }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != (model.values[key] ?? "") {
            model.set(key, value)
        }
    }
}

/// One bindable command row: alias field, hotkey display + record button.
private struct CommandBindingRow: View {
    @ObservedObject var model: SettingsModel
    let command: [String]
    @State private var aliasDraft = ""
    @State private var recorder: HotkeyRecorder?

    var body: some View {
        let id = command.first ?? ""
        let binding = model.bindings.first(where: { $0.first == id })
        let alias = binding?[1] ?? ""
        let hotkey = binding?[2] ?? ""
        HStack(spacing: 10) {
            Text(command.count > 1 ? command[1] : id)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("alias", text: $aliasDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onAppear { aliasDraft = alias }
                .onChange(of: alias) { _, current in aliasDraft = current }
                .onSubmit {
                    let trimmed = aliasDraft.trimmingCharacters(in: .whitespaces)
                    if trimmed != alias { model.saveBinding(id: id, alias: trimmed, hotkey: hotkey) }
                }
            if model.recordingId == id {
                Button("Press keys… (Esc cancels)") {}
                    .controlSize(.small)
                    .disabled(true)
            } else {
                Button(hotkey.isEmpty ? "Record" : Hotkey.display(hotkey)) {
                    model.recordingId = id
                    recorder = HotkeyRecorder { spec in
                        model.recordFinished(id: id, spec: spec)
                        recorder = nil
                    }
                    recorder?.start()
                }
                .controlSize(.small)
            }
            if !hotkey.isEmpty || !alias.isEmpty {
                Button("Clear") { model.clearBinding(id: id) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 1)
    }
}

/// Captures the next modifier+key press inside this window as a hotkey
/// spec. A local monitor is enough — the user records in the settings
/// window — so no Input Monitoring permission is involved. Esc cancels.
@MainActor
final class HotkeyRecorder {
    private let finish: (String?) -> Void
    private var monitor: Any?

    init(finish: @escaping (String?) -> Void) { self.finish = finish }

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged { return nil }  // modifiers alone: keep waiting
            if event.keyCode == UInt16(kVK_Escape) {
                self.stop(); self.finish(nil); return nil
            }
            let mask = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function])
            guard mask != [] else { return event }  // bare key: ignore, keep waiting
            guard let spec = Hotkey.spec(forKeyCode: UInt32(event.keyCode),
                                         modifiers: Self.carbonMask(mask)) else {
                return event  // unmappable key: keep waiting
            }
            self.stop()
            self.finish(spec)
            return nil
        }
    }

    func cancel() {
        stop()
        finish(nil)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func carbonMask(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }
}

/// Global summon shortcut editor. Recording produces only canonical values
/// accepted by the shared backend grammar, so macOS users never need to know
/// or type the transport spelling (for example, `alt+space`).
private struct GlobalHotkeySetting: View {
    let title: String
    @ObservedObject var model: SettingsModel
    @State private var recorder: HotkeyRecorder?
    @State private var isRecording = false

    var body: some View {
        LabeledContent(title) {
            if isRecording {
                Button("Press keys… (Esc cancels)") {}
                    .disabled(true)
            } else {
                Button(Hotkey.display(model.values["hotkey"] ?? "alt+space")) {
                    isRecording = true
                    recorder = HotkeyRecorder { spec in
                        isRecording = false
                        if let spec, !spec.isEmpty {
                            model.set("hotkey", spec)
                        }
                        recorder = nil
                    }
                    recorder?.start()
                }
                .help("Record a new global shortcut")
                .accessibilityIdentifier("settings-record-hotkey")
            }
        }
        .onDisappear {
            if isRecording { recorder?.cancel() }
            recorder = nil
            isRecording = false
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, features, ai, commands, sync

    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "General"
        case .features: return "Features"
        case .ai: return "AI"
        case .commands: return "Commands"
        case .sync: return "Sync & Updates"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .features: return "square.grid.2x2"
        case .ai: return "sparkles"
        case .commands: return "keyboard"
        case .sync: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: SettingsSection? = .general

    // Translation reads the observable backend setting, so switching language
    // immediately re-renders the visible settings surface.
    private func t(_ key: String) -> String {
        GeneratedI18n.tr(model.values["language"] ?? "zh", key)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(SettingsSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                        .accessibilityIdentifier("settings-sidebar-\(section.rawValue)")
                }
                .listStyle(.sidebar)
                .frame(width: 170)

                Divider()

                Group {
                    switch selection ?? .general {
                    case .general: generalTab
                    case .features: featuresTab
                    case .ai: aiTab
                    case .commands: commandsTab
                    case .sync: syncTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 720, height: 520)
        .task { await model.load() }
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker(t("setting.language"), selection: model.choice("language", default: "zh")) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                Picker(t("setting.theme"), selection: model.choice("theme", default: "system")) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section {
                GlobalHotkeySetting(title: t("setting.hotkey"), model: model)
                Text("Select the current shortcut, then press the new modifier and key combination. Applies immediately; a taken combo falls back to ⌃⌥Space.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Stepper("\(t("setting.max-results")): \(model.number("max-results", default: 12).wrappedValue)",
                        value: model.number("max-results", default: 12), in: 5...25)
            }
        }
        .formStyle(.grouped)
    }

    private var featuresTab: some View {
        Form {
            Section("Clipboard") {
                Toggle(t("setting.clipboard-enabled"), isOn: model.toggle("clipboard-enabled"))
                SettingField(title: "History limit", key: "clipboard-limit",
                             placeholder: "1000", model: model)
            }
            Section("Search") {
                Toggle(t("setting.web-search-enabled"), isOn: model.toggle("web-search-enabled"))
                Picker("Default bang", selection: model.choice("default-engine", default: "!g")) {
                    ForEach(["!g", "!d", "!gh", "!so", "!w", "!yt", "!m", "!t"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }
            Section("Snippets") {
                Toggle(t("setting.expansion-enabled"), isOn: model.toggle("expansion-enabled"))
                Text("Needs the Accessibility permission on macOS.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Plugins") {
                Toggle(t("setting.plugins-enabled"), isOn: model.toggle("plugins-enabled"))
                SettingField(title: "Call timeout (ms)", key: "plugins-timeout-ms",
                             placeholder: "2000", model: model)
            }
        }
        .formStyle(.grouped)
    }

    private var aiTab: some View {
        Form {
            Section {
                Picker(t("setting.ai-provider"), selection: model.choice("ai-provider", default: "")) {
                    Text("Off").tag("")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                    Text("Ollama").tag("ollama")
                }
                SettingField(title: "Model", key: "ai-model",
                             placeholder: "provider default", model: model)
                SettingField(title: "Base URL", key: "ai-base-url",
                             placeholder: "provider default", model: model)
                SettingField(title: "Persona", key: "ai-persona",
                             placeholder: "prepended to every request", model: model)
            }
            Section("API key") {
                HStack {
                    SecureField("API key", text: $model.aiKeyDraft)
                        .onSubmit { model.saveAiKey() }
                    Button("Save") { model.saveAiKey() }
                        .disabled(model.aiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 6) {
                    Image(systemName: model.aiStatus == "ready"
                          ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.aiStatus == "ready" ? .green : .secondary)
                    Text(model.aiStatus == "ready" ? "Ready" : model.aiStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !model.aiKeyNotice.isEmpty {
                    Text(model.aiKeyNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("Stored in ai-keys.json on this Mac; never mirrored to the sync folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var commandsTab: some View {
        Form {
            Section {
                Text("Give a command your own shorthand (it ranks like a name) and a global hotkey that runs it with the panel hidden. Combos are recorded in this window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let bindingError = model.bindingError {
                    Text(bindingError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section("Commands") {
                ForEach(model.commands, id: \.self) { command in
                    CommandBindingRow(model: model, command: command)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.loadBindings() }
    }

    private var syncTab: some View {
        Form {
            Section("Sync (beta)") {
                SettingField(title: "Sync folder", key: "sync-root",
                             placeholder: "empty = off", model: model)
                Text("A folder a file sync service replicates (iCloud Drive, Dropbox, Syncthing); settings and snippets mirror there.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                Text("Fulcrum checks signed releases automatically. You can also choose Check for Updates from the app menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
