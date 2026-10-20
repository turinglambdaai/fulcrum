import SwiftUI
import AppKit

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
                _ = try await api.settingsSet(key: key, value: value)
                error = nil
                onChanged(key, value)
                if key == "ai-provider" {
                    await refreshAiStatus()
                }
            } catch {
                self.error = "\(key): \(error)"
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    // Translation reads the observable backend setting, so switching language
    // immediately re-renders the visible settings surface.
    private func t(_ key: String) -> String {
        GeneratedI18n.tr(model.values["language"] ?? "zh", key)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                featuresTab
                    .tabItem { Label("Features", systemImage: "square.grid.2x2") }
                aiTab
                    .tabItem { Label("AI", systemImage: "sparkles") }
                syncTab
                    .tabItem { Label("Sync & Updates", systemImage: "arrow.triangle.2.circlepath") }
            }
            .padding(.top, 10)
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
        .frame(width: 560, height: 470)
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
                SettingField(title: t("setting.hotkey"), key: "hotkey",
                             placeholder: "alt+space", model: model)
                Text("Modifiers alt / ctrl / shift / cmd plus a key: space, a–z, 0–9, f1–f12, comma, period, minus, equal, tab. Applies immediately; a taken combo falls back to ⌃⌥Space.")
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
                SettingField(title: "Feed base URL", key: "update-base-url",
                             placeholder: "https://…", model: model)
            }
        }
        .formStyle(.grouped)
    }
}
