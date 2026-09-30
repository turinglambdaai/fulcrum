import SwiftUI
import RivetEmbedding
import RivetRuntime

/// Adapter over the generated `RivetAPI`: rows travel as `[[String]]` per
/// the backend contract; the UI keeps a typed struct.
struct ResultRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let arg: String
    let icon: String
    let hint: String
    let badge: String

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
}


/// The launcher panel UI: one query field, one result list, one status line.
/// All state lives in LauncherModel; this view is deliberately dumb.
struct LauncherView: View {
    @EnvironmentObject private var model: LauncherModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            if model.ready {
                List(selection: $model.selection) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if !row.badge.isEmpty {
                                    Text(row.badge)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                }
                            }
                            Text(row.displaySubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .tag(row.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(row) }
                        .onTapGesture(count: 2) { model.run(row) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
                Text("↑↓ navigate · ↵ run · esc hide")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Fulcrum")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 680, minHeight: 440)
        .background(KeyEventHandlingView(onEscape: { model.hide() },
                                         onUp: { model.moveSelection(-1) },
                                         onDown: { model.moveSelection(1) }))
        .onAppear { queryFocused = true }
        .onChange(of: model.selection) { _, _ in queryFocused = true }
    }
}

/// Esc/arrow handling that works while the text field keeps focus.
private struct KeyEventHandlingView: NSViewRepresentable {
    let onEscape: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void

    final class KeyView: NSView {
        let onEscape: () -> Void
        let onUp: () -> Void
        let onDown: () -> Void

        init(onEscape: @escaping () -> Void,
             onUp: @escaping () -> Void,
             onDown: @escaping () -> Void) {
            self.onEscape = onEscape
            self.onUp = onUp
            self.onDown = onDown
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("KeyEventHandlingView is created in code only")
        }

        override var acceptsFirstResponder: Bool { false }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: onEscape()          // esc
            case 125: onDown()           // down arrow
            case 126: onUp()             // up arrow
            default: super.keyDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> KeyView {
        KeyView(onEscape: onEscape, onUp: onUp, onDown: onDown)
    }

    func updateNSView(_ nsView: KeyView, context: Context) {}
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

    func queryChanged(_ text: String) {
        searchChanged(text)
    }

    func select(_ row: ResultRow) {
        selection = row.id
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.id)
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(current + delta, 0), ids.count - 1)
        selection = ids[next]
    }

    func runSelected() {
        guard let selection,
              let row = rows.first(where: { $0.id == selection }) else { return }
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
                        self.hide()
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
                    self.selection = result.first?.id
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
        var payload = ""
        if case .list(let cells) = value, let last = cells.last,
           case .string(let text) = last {
            payload = text
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
