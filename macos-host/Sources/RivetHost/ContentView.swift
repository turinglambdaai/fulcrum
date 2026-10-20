import SwiftUI
import AppKit
import RivetEmbedding
import RivetRuntime

/// Product accent, mirroring the site palette (#D97706 amber).
enum FulcrumTheme {
    static let accent = Color(red: 217 / 255, green: 119 / 255, blue: 6 / 255)
    static let cornerRadius: CGFloat = 12
    static let rowHeight: CGFloat = 44
}

/// Adapter over the generated `RivetAPI`: rows travel as `[[String]]` per
/// the backend contract; the UI keeps a typed struct.
struct ResultRow: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let arg: String
    let icon: String
    let hint: String
    let badge: String

    /// Column 0 (`id`) is the *action* id and repeats across rows of the
    /// same provider ("app.launch" for every app). SwiftUI identity needs a
    /// per-row key. (action id, arg) is unique for engine providers, but
    /// FPP1 plugins legitimately return several rows that share an arg
    /// (Epoch's UTC and local render of one timestamp) — the row title
    /// disambiguates those.
    var rowId: String { id + "\u{1F}" + arg + "\u{1F}" + title }

    var displaySubtitle: String {
        subtitle.isEmpty ? kind : subtitle
    }

    static func from(_ cells: [String]) -> ResultRow? {
        guard cells.count == 8 else { return nil }
        return ResultRow(id: cells[0], title: cells[1], subtitle: cells[2],
                         kind: cells[3], arg: cells[4], icon: cells[5],
                         hint: cells[6], badge: cells[7])
    }
}

/// Icon provider. Application rows point at real .app bundles, so render
/// the actual dock icon (Raycast-style recognition beats any glyph);
/// everything else gets a tuned SF Symbol.
enum RowIcon {
    // NSCache is thread-safe at runtime; Swift just cannot see it.
    fileprivate nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    static func view(for row: ResultRow) -> some View {
        let size: CGFloat = 28
        // The row contract carries the app bundle path in the subtitle
        // column (arg is the engine action id), so dock icons come from
        // there.
        if row.kind == "Application", row.subtitle.hasSuffix(".app") {
            return AnyView(AppIconView(path: row.subtitle, size: size))
        }
        return AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(FulcrumTheme.accent.opacity(0.12))
                Image(systemName: symbol(for: row))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FulcrumTheme.accent)
            }
            .frame(width: size, height: size)
        )
    }

    private static func symbol(for row: ResultRow) -> String {
        switch row.kind {
        case "Calculator": return "equal.circle.fill"
        case "Clipboard": return "doc.on.clipboard"
        case "Snippet": return "text.quote"
        case "Quicklink": return "link"
        case "Web Search": return "globe"
        case "Plugin": return "puzzlepiece.extension"
        case "System": return row.id == "sys.lock" ? "lock.fill" : "gearshape"
        case "Setting": return "switch.2"
        case "Window": return "rectangle.split.2x1"
        case "Update": return "arrow.down.circle"
        case "AI": return "sparkles"
        case "File": return "doc"
        default: return "circle.grid.2x2"
        }
    }
}

/// Resized dock icon for an .app bundle, cached by path.
private struct AppIconView: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    private var icon: NSImage {
        let key = path as NSString
        if let cached = RowIcon.cache.object(forKey: key) {
            return cached
        }
        let raw = NSWorkspace.shared.icon(forFile: path)
        let resized = NSImage(size: NSSize(width: size * 2, height: size * 2))
        resized.lockFocus()
        raw.draw(in: NSRect(x: 0, y: 0, width: size * 2, height: size * 2))
        resized.unlockFocus()
        RowIcon.cache.setObject(resized, forKey: key)
        return resized
    }
}

/// Under-window vibrancy with rounded corners: the panel material Raycast
/// made the standard for launchers. Hairline edge keeps it crisp on both
/// appearance modes.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = FulcrumTheme.cornerRadius
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor =
            NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// One result row, Raycast-style: leading icon, title + muted subtitle,
/// trailing badge, and — only on the selected row — the ↵ affordance chip.
/// The selection highlight is an inset rounded rectangle, not the
/// system full-width bar; pointer hover paints a whisper of the same tint
/// so mouse users see what a click would land on.
struct ResultRowView: View {
    let row: ResultRow
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            RowIcon.view(for: row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.displaySubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if !row.badge.isEmpty {
                Text(row.badge)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(FulcrumTheme.accent.opacity(0.14)))
                    .foregroundStyle(FulcrumTheme.accent)
            }
            if isSelected {
                Text("↵")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FulcrumTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(FulcrumTheme.accent.opacity(0.14)))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: FulcrumTheme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected
                      ? FulcrumTheme.accent.opacity(0.14)
                      : hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.hovering = hovering
        }
    }
}

/// Live AI answer, decoded from the ai-stream State the backend pushes
/// while the model responds. Idle means "nothing to show".
struct AiStreamState: Equatable {
    let phase: String
    let text: String
    let error: String?
}

/// The streaming answer panel: a header with the live phase, the growing
/// text, and the hand-off hint once the answer is on the clipboard.
struct AiStreamView: View {
    let state: AiStreamState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FulcrumTheme.accent)
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.phase == "running" {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            ScrollView {
                Text(displayText)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 170)
            if state.phase == "done" {
                Text(I18nService.shared.t("aiCopiedHint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if let error = state.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var header: String {
        switch state.phase {
        case "running": return I18nService.shared.t("aiRunning")
        case "error": return I18nService.shared.t("aiFailed")
        default: return I18nService.shared.t("aiAnswer")
        }
    }

    private var displayText: String {
        if state.phase == "running" {
            return state.text.isEmpty ? "…" : state.text + " ▍"
        }
        return state.text
    }
}

/// A FPP2 plugin detail payload: plain text plus key-value pairs, rendered
/// natively (the plugin-detail RPC's wire shape).
struct DetailViewState {
    let text: String
    let metadata: [(String, String)]
}

/// A FPP2 plugin detail panel: the same slot the AI stream uses, for a
/// static payload. Text is selectable; metadata renders as a property list.
struct PluginDetailView: View {
    let state: DetailViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FulcrumTheme.accent)
                Text(I18nService.shared.t("detailTitle"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !state.text.isEmpty {
                        Text(state.text)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(state.metadata, id: \.0, content: { pair in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pair.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(pair.1)
                                .font(.system(size: 11.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 190)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// The launcher panel UI: one query field, one result list, one status line.
/// All state lives in LauncherModel; this view is deliberately dumb.
struct LauncherView: View {
    @EnvironmentObject private var model: LauncherModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(model.t("searchPlaceholder"),
                          text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .medium))
                    .accessibilityIdentifier("FulcrumQuery")
                    .focused($queryFocused)
                    .onSubmit { model.runSelected() }
                    .onChange(of: model.query) { _, newValue in
                        model.queryChanged(newValue)
                    }
                // The acceptance affordance must not become actionable until
                // the embedded backend has completed its health check.  If it
                // is pressed during startup, searchChanged intentionally drops
                // the request and beginSearch later clears the query, creating
                // a runner-speed-dependent false failure.
                if ProcessInfo.processInfo.environment["FULCRUM_ACCEPTANCE"] == "1",
                   model.ready {
                    Button("Acceptance query") {
                        model.query = "12*12"
                        model.queryChanged("12*12")
                    }
                    .accessibilityIdentifier("FulcrumAcceptanceQuery")
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            Divider().opacity(0.5)

            if let ai = model.aiStream, ai.phase != "idle" {
                AiStreamView(state: ai)
                Divider().opacity(0.5)
            }

            if let detail = model.detailView {
                PluginDetailView(state: detail)
                Divider().opacity(0.5)
            }

            if model.ready {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.rows, id: \.rowId) { row in
                                ResultRowView(row: row,
                                              isSelected: model.selection == row.rowId)
                                    .id(row.rowId)
                                    .onTapGesture { model.select(row) }
                                    .onTapGesture(count: 2) { model.run(row) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selection) { _, newValue in
                        if let newValue {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                        queryFocused = true
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "command")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(FulcrumTheme.accent.opacity(0.8))
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().opacity(0.5)
            HStack {
                Text(model.showingActions
                      ? model.t("navigationHintActions")
                      : model.t("navigationHintMac"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Text(model.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .help(model.status)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(VisualEffectBackground())
        .onAppear { queryFocused = true }
    }
}

/// Thin snake-case wrapper over the codegen client so LauncherModel reads
/// naturally. The generated file is replaced by raco rivet build; this one
/// is ours.
struct FulcrumAPI {
    let generated: RivetAPI

    init(client: RivetClient) {
        generated = RivetAPI(client: client)
    }

    func health() async throws -> String { try await generated.health() }
    func getHotkey() async throws -> String { try await generated.get_hotkey() }
    func snippets() async throws -> [(keyword: String, text: String)] {
        let rows = try await generated.snippet_list()
        return rows.compactMap { row in
            guard row.count >= 4, !row[2].isEmpty, !row[3].isEmpty else { return nil }
            return (keyword: row[2], text: row[3])
        }
    }
    func getTheme() async throws -> String { try await generated.get_theme() }
    func pluginDetail(rowId: String, arg: String) async throws -> RivetTypes.DetailView {
        try await generated.plugin_detail(row_id: rowId, arg: arg)
    }
    func search(_ query: String) async throws -> [ResultRow] {
        (try await generated.search(query: query)).compactMap { ResultRow.from($0) }
    }
    func runAction(id: String, arg: String) async throws -> String {
        try await generated.run_action(id: id, arg: arg)
    }
    func clipboardRecord(_ text: String) async throws -> String {
        try await generated.clipboard_record(text: text)
    }
    func rowActions(id: String, arg: String) async throws -> [ResultRow] {
        (try await generated.row_actions(id: id, arg: arg)).compactMap { ResultRow.from($0) }
    }
    func settingsList() async throws -> [ResultRow] {
        (try await generated.settings_list()).compactMap { ResultRow.from($0) }
    }
    /// settings-list rows carry the value in the title column and the
    /// description in the subtitle column (badge is empty — reading it is
    /// the historical bug that left language and expansion settings dead).
    func settingsSet(key: String, value: String) async throws -> Bool {
        try await generated.settings_set(key: key, value: value)
    }
    func aiStatus() async throws -> String { try await generated.ai_status() }
    func updateCheck(manual: Bool) async throws -> RivetTypes.UpdateCheck {
        try await generated.update_check(manual: manual)
    }
    func updateDownload() async throws -> Void {
        try await generated.update_download()
    }
    func updateState() async throws -> RivetTypes.UpdateState {
        try await generated.update_state()
    }
}

/// Launcher state and backend plumbing. One embedded Racket CS instance,
/// one FulcrumAPI; searches are generation-guarded so a slow response can
/// never overwrite a newer result set.
@MainActor
final class LauncherModel: ObservableObject {
    /// Backend events arrive on a @Sendable callback that cannot capture
    /// actor state; the active model is registered at startup instead.
    nonisolated(unsafe) static var active: LauncherModel?

    @Published var query = ""
    @Published var rows: [ResultRow] = []
    @Published var selection: String?
    @Published var ready = false
    @Published var status = I18nService.shared.t("startingStatus")
    /// Drives a SwiftUI repaint when the backend-owned language changes.
    @Published private(set) var language = "en"
    /// ⌘K mode: rows currently holds secondary actions for `actionParent`.
    @Published var showingActions = false
    /// Live AI answer (nil = nothing to show); survives typing so the user
    /// can keep reading while the model finishes.
    @Published var aiStream: AiStreamState?
    /// FPP2 plugin detail view (nil = nothing to show); dismissed by the
    /// next keystroke or Esc.
    @Published var detailView: DetailViewState?
    private var actionParent: ResultRow?

    var onToggle: (() -> Void)?
    var onHide: (() -> Void)?
    /// Fired once the backend is healthy: the AppDelegate reads the language
    /// setting (i18n) and arms the throttled silent update check there.
    var onBackendReady: (() -> Void)?
    private(set) var api: FulcrumAPI?

    private var backend: EmbeddedRacketBackend?
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?

    func setPersistentStatus(_ text: String) {
        status = text
    }

    func setLanguage(_ value: String) {
        I18nService.shared.setLanguage(value)
        language = I18nService.shared.language
        if ready { status = t("readyStatusMac") }
    }

    func t(_ key: String) -> String {
        // Reading the published language is what makes this lookup reactive.
        _ = language
        return I18nService.shared.t(key)
    }

    func start() {
        guard backend == nil else { return }
        Self.active = self

        do {
            let config = try Self.runtimeConfiguration()
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            Task.detached { [backend] in
                do {
                    try backend.start(onEvent: { name, value in
                        Task { @MainActor in
                            LauncherModel.active?.handleEvent(name: name,
                                                              value: value)
                        }
                    })
                    let api = FulcrumAPI(client: backend.client)
                    _ = try await api.health()
                    await MainActor.run {
                        guard let model = LauncherModel.active else { return }
                        model.api = api
                        model.ready = true
                        model.status = model.t("readyStatusMac")
                        model.beginSearch()
                        model.onBackendReady?()
                    }
                } catch {
                    await MainActor.run {
                        LauncherModel.active?.ready = false
                        LauncherModel.active?.status = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    func beginSearch() {
        showingActions = false
        actionParent = nil
        query = ""
        searchChanged("")
    }

    /// Esc with text on screen: wipe the query and stay open.
    func clearQuery() {
        query = ""
        searchChanged("")
    }

    /// Esc with a finished AI answer on screen: dismiss the panel only.
    func dismissAiStream() {
        aiStream = nil
    }

    /// Esc over a plugin detail panel: dismiss it only.
    func dismissDetailView() {
        detailView = nil
    }

    /// Tab: autocomplete the selected row's title into the query field —
    /// the Raycast convention for refining a fuzzy hit into its exact
    /// text before running it.
    func completeFromSelection() {
        guard !showingActions,
              let row = rows.first(where: { $0.rowId == selection }),
              !row.title.isEmpty else { return }
        detailView = nil
        query = row.title
    }

    /// The backend bumped search-revision (FPP2 daemon push): refresh the
    /// on-screen rows for the current query, debounced.
    func refreshForRevision() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self, let api = self.api else { return }
            let text = self.query
            do {
                let result = try await api.search(text)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard text == self.query else { return }
                    self.rows = result
                    self.selection = result.first?.rowId
                }
            } catch {
                // A failed refresh is silent: the stale rows stay.
            }
        }
    }

    func queryChanged(_ text: String) {
        detailView = nil
        searchChanged(text)
    }

    func select(_ row: ResultRow) {
        selection = row.rowId
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.rowId)
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(current + delta, 0), ids.count - 1)
        selection = ids[next]
    }

    /// ⌘K on the selected row: swap the list for its secondary actions.
    func openActionsForSelection() {
        guard !showingActions, let api,
              let row = rows.first(where: { $0.rowId == selection }) else { return }
        Task { [weak self] in
            do {
                let actions = try await api.rowActions(id: row.id, arg: row.arg)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if actions.isEmpty {
                        self.status = self.t("noSecondaryActions")
                        return
                    }
                    self.rows = actions
                    self.selection = actions.first?.rowId
                    self.showingActions = true
                    self.actionParent = row
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Actions error: \(error)"
                }
            }
        }
    }

    /// Esc inside the action panel: back to the live search results.
    func closeActions() {
        showingActions = false
        actionParent = nil
        searchChanged(query)
    }

    func runSelected() {
        guard let selection,
              let row = rows.first(where: { $0.rowId == selection }) else { return }
        run(row)
    }

    func run(_ row: ResultRow) {
        guard let api else { return }
        Task { [weak self] in
            do {
                let status = try await api.runAction(id: row.id, arg: row.arg)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Update rows drive host-native install/reveal; the
                    // backend already did its part (state transitions).
                    if row.id == "update.install" {
                        UpdateController.shared?.quitAndInstall()
                        return
                    }
                    switch status {
                    case "ok", "launched", "copied", "opened":
                        if self.showingActions {
                            // A secondary action (pin, delete, copy) keeps
                            // the launcher open, back on the search rows.
                            self.closeActions()
                        } else {
                            self.hide()
                        }
                    case "started":
                        // AI run: the request continues on a backend thread;
                        // the ai-stream State drives the streaming panel.
                        self.status = self.t("aiRunning")
                    case "stay":
                        // The result is meant to be read (update check, …):
                        // the notify event already wrote the status line;
                        // keep the panel open so it stays visible.
                        break
                    case "detail":
                        // FPP2 plugin detail: fetch the payload and show it
                        // in the panel slot; the row stays put behind it.
                        self.status = ""
                        Task { [weak self] in
                            do {
                                let view = try await api.pluginDetail(rowId: row.id,
                                                                      arg: row.arg)
                                await MainActor.run { [weak self] in
                                    self?.detailView = DetailViewState(
                                        text: view.text,
                                        metadata: view.metadata.map { ($0[0], $0[1]) })
                                }
                            } catch {
                                await MainActor.run { [weak self] in
                                    self?.status = "Detail error: \(error)"
                                }
                            }
                        }
                    case "quit-and-install":
                        UpdateController.shared?.quitAndInstall()
                    case "downloading":
                        self.status = I18nService.shared.t("updateDownloading")
                        self.hide()
                    case "delegated":
                        // Host-native actions: the backend cannot reach
                        // other apps' windows or this app's own windows.
                        if row.id == "about.open" {
                            AppDelegate.shared?.showAboutPanel()
                            self.hide()
                        } else if row.id == "settings.open" {
                            AppDelegate.shared?.showSettingsWindow()
                            self.hide()
                        } else if WindowCommands.performAndRemember(id: row.id) {
                            self.hide()
                        } else {
                            self.status = WindowCommands.permissionHint
                        }
                    default:
                        self.status = status
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.status = "Action error: \(error)"
                }
            }
        }
    }

    func hide() {
        onHide?()
    }

    private func searchChanged(_ text: String) {
        guard let api, ready else { return }
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // Debounce: coalesce fast typing into one backend round-trip.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await api.search(text)
                await MainActor.run { [weak self] in
                    guard let self, generation == self.searchGeneration else { return }
                    self.rows = result
                    self.selection = result.first?.rowId
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard generation == self?.searchGeneration else { return }
                    self?.status = "Search error: \(error)"
                }
            }
        }
    }

    private func handleEvent(name: String, value: RivetValue) {
        // Shared-state pushes arrive as reserved "$state" events carrying
        // [state-name, wire-value]; everything else is a bare String.
        if name == "$state" {
            guard let change = RivetClient.stateChange(eventName: name,
                                                       value: value) else { return }
            switch change.name {
            case "theme":
                if case .string(let theme) = change.value {
                    AppDelegate.applyTheme(theme)
                }
            case "hotkey":
                if case .string(let spec) = change.value {
                    AppDelegate.shared?.applyHotkey(spec)
                }
            case "language":
                if case .string(let language) = change.value {
                    setLanguage(language)
                    AppDelegate.shared?.refreshLocalizedMenus()
                }
            case "ai-stream":
                if case .list(let fields) = change.value, fields.count == 3,
                   case .string(let phase) = fields[0],
                   case .string(let text) = fields[1] {
                    var error: String?
                    if case .string(let message) = fields[2] { error = message }
                    aiStream = AiStreamState(phase: phase, text: text,
                                             error: error)
                }
            case "search-revision":
                refreshForRevision()
            default:
                break
            }
            return
        }
        // Every other backend event carries a bare String payload (RVT1
        // event frames are [name, value]; the runtime hands us value).
        let payload: String
        if case .string(let text) = value {
            payload = text
        } else {
            payload = ""
        }
        switch name {
        case "copy-to-clipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
            hide()
        case "paste-to-frontmost":
            pasteToFrontmost(payload)
        case "ai-finished":
            // The answer lands on the clipboard, but the panel stays: the
            // user is reading the streamed text right now.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
            status = "Answer copied to the clipboard"
        case "open-url":
            if let url = URL(string: payload) {
                NSWorkspace.shared.open(url)
            }
            hide()
        case "update-available":
            // A check found a newer version — make the offer visible.
            status = payload
            UpdateController.shared?.offered()
        default:
            break
        }
    }

    /// Paste-to-frontmost: write the pasteboard, step the app aside so the
    /// previous one is frontmost again, then synthesize ⌘V. Accessibility
    /// trust is required for the synthetic keystroke (the same permission
    /// window management already asks for).
    private func pasteToFrontmost(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hide()
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard AXIsProcessTrusted() else {
                self?.status = WindowCommands.permissionHint
                return
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            let cmdDown = CGEvent(keyboardEventSource: source,
                                  virtualKey: 55, keyDown: true)
            let vDown = CGEvent(keyboardEventSource: source,
                                virtualKey: 9, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source,
                              virtualKey: 9, keyDown: false)
            let cmdUp = CGEvent(keyboardEventSource: source,
                                virtualKey: 55, keyDown: false)
            for event in [cmdDown, vDown, vUp, cmdUp] {
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private static func runtimeConfiguration() throws -> EmbeddedRacketConfiguration {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        // Packaged apps keep Racket data in Contents/Resources. `raco rivet
        // dev` runs the staged executable directly, where runtime/res live
        // next to the executable. Pick the first complete layout so both
        // paths use exactly the same host binary.
        let roots = [
            Bundle.main.resourceURL,
            executable.deletingLastPathComponent()
        ].compactMap { $0 }

        for root in roots {
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let core = root.appendingPathComponent("res/core.zo")
            let required = [
                runtime.appendingPathComponent("petite.boot"),
                runtime.appendingPathComponent("scheme.boot"),
                runtime.appendingPathComponent("racket.boot"),
                core
            ]
            if required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return EmbeddedRacketConfiguration(
                    executable: executable,
                    petiteBoot: required[0],
                    schemeBoot: required[1],
                    racketBoot: required[2],
                    core: core,
                    moduleName: RivetGeneratedConfig.moduleName,
                    entryName: RivetGeneratedConfig.entryName
                )
            }
        }

        throw HostError.missingRuntimeLayout(
            roots.map(\.path).joined(separator: ", ")
        )
    }
}

enum HostError: Error, CustomStringConvertible {
    case missingRuntimeLayout(String)

    var description: String {
        switch self {
        case .missingRuntimeLayout(let roots):
            return "missing Rivet runtime/res layout under: \(roots)"
        }
    }
}
