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
/// system full-width bar.
struct ResultRowView: View {
    let row: ResultRow
    let isSelected: Bool

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
                      : Color.clear)
        )
        .contentShape(Rectangle())
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
                TextField("Search apps, clipboard, snippets, the web…",
                          text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .medium))
                    .focused($queryFocused)
                    .onSubmit { model.runSelected() }
                    .onChange(of: model.query) { _, newValue in
                        model.queryChanged(newValue)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            Divider().opacity(0.5)

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
                    .onChange(of: model.selection) { _, newValue in
                        if let newValue {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                        queryFocused = true
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
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
                      ? "↑↓ navigate · ↵ run · esc back"
                      : "↑↓ navigate · ↵ run · ⌘K actions · esc clear/hide")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Fulcrum")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
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
    @Published var status = "Starting embedded Racket CS…"
    /// ⌘K mode: rows currently holds secondary actions for `actionParent`.
    @Published var showingActions = false
    private var actionParent: ResultRow?

    var onToggle: (() -> Void)?
    var onHide: (() -> Void)?
    private(set) var api: FulcrumAPI?

    private var backend: EmbeddedRacketBackend?
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?

    func setPersistentStatus(_ text: String) {
        status = text
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
                        model.status = "Ready — press ⌥Space anywhere"
                        model.beginSearch()
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
        query = ""
        searchChanged("")
    }

    /// Esc with text on screen: wipe the query and stay open.
    func clearQuery() {
        query = ""
        searchChanged("")
    }

    func queryChanged(_ text: String) {
        searchChanged(text)
    }

    func select(_ row: ResultRow) {
        selection = row.id
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
                        self.status = "No secondary actions for this result"
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
                    switch status {
                    case "ok", "launched", "copied", "opened":
                        if self.showingActions {
                            // A secondary action (pin, delete, copy) keeps
                            // the launcher open, back on the search rows.
                            self.closeActions()
                        } else {
                            self.hide()
                        }
                    case "delegated":
                        // Window commands execute natively: the backend
                        // cannot reach other apps' windows.
                        if WindowCommands.performAndRemember(id: row.id) {
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
        // Every backend event carries a bare String payload (RVT1 event
        // frames are [name, value]; the runtime hands us value directly).
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
        case "open-url":
            if let url = URL(string: payload) {
                NSWorkspace.shared.open(url)
            }
            hide()
        case "update-available":
            status = payload
        default:
            break
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
