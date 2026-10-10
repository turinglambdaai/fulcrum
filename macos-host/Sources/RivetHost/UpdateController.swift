import AppKit
import Foundation
import SwiftUI

/// Update orchestration for the macOS host (updater milestone 0.2).
///
/// The family split (rivet/distribution, taskly): the backend verifies the
/// Ed25519-signed manifest, selects the platform artifact and downloads it
/// with size + SHA-256 verification (the `update-check` / `update-download`
/// / `update-state` RPCs, with the 4-hour silent-check throttle owned by
/// the backend); the host owns presentation and installation. Installation
/// swaps the verified bundle atomically: unzip → verify bundle version →
/// keep the old bundle as `.old` until the relaunch succeeds (taskly's
/// proven swap script — the shell survives our exit and restores the old
/// bundle if the new one fails to move in).
///
/// The feed serves the portable zip (sign-manifest.rkt), so this is the
/// zip+ditto flow; the DMG is the human installer, not a feed artifact.
@MainActor
final class UpdateController: ObservableObject {
    /// The active controller (created by the AppDelegate at startup).
    nonisolated(unsafe) static var shared: UpdateController?

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case downloaded
        case failed
    }

    enum UpdateError: LocalizedError {
        case notInstalled
        case payloadMissing
        case versionMismatch(expected: String, got: String)
        case stateMissing

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "not an installed app bundle"
            case .payloadMissing: return "the update archive has no app bundle"
            case .versionMismatch(let expected, let got):
                return "bundle version \(got) ≠ manifest \(expected)"
            case .stateMissing: return "no downloaded update path"
            }
        }
    }

    @Published var panelVisible = false
    @Published var phase: Phase = .idle
    @Published var percent = 0
    @Published var availableVersion = ""
    @Published var availableSize: Int64 = 0
    @Published var errorMessage = ""
    /// The verified artifact path once the backend reports "downloaded".
    @Published var downloadedPath: String?

    private var pollTask: Task<Void, Never>?
    private weak var model: LauncherModel?

    var i18n: I18nService { I18nService.shared }

    init() {
        Self.shared = self
    }

    func attach(model: LauncherModel) {
        self.model = model
    }

    var api: FulcrumAPI? { model?.api }

    func t(_ key: String, _ args: Any...) -> String {
        if args.isEmpty { return i18n.t(key) }
        return i18n.format(key, args)
    }

    // MARK: - Check

    /// Menu entry: open the panel and force a manual check (bypasses the
    /// backend's 4-hour throttle).
    func checkForUpdates() {
        panelVisible = true
        guard phase != .downloading else { return }
        Task { await check(manual: true) }
    }

    /// Silent launch check: at most once per 4 h — the throttle lives in
    /// the backend (update-last-check), so the host just asks quietly.
    func silentStartupCheck() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard phase != .downloading else { return }
            await check(manual: false)
        }
    }

    /// The update-available event arrived (a check found something); open
    /// the panel so the offer is visible. The phase itself is set by the
    /// check response this event rides on.
    func offered() {
        panelVisible = true
    }

    func check(manual: Bool) async {
        guard let api else { return }
        phase = .checking
        errorMessage = ""
        downloadedPath = nil
        do {
            let result = try await api.updateCheck(manual: manual)
            switch result.status {
            case "available":
                availableVersion = result.available_version ?? ""
                availableSize = result.size_bytes ?? 0
                phase = .available
                panelVisible = true
            case "throttled":
                // A silent ask inside the throttle window is a no-op; a
                // manual one never gets here (manual bypasses).
                if panelVisible { phase = .upToDate } else { phase = .idle }
            case "up-to-date":
                phase = .upToDate
            default:
                errorMessage = result.error ?? t("updateCheckFailed", "unknown error")
                phase = .failed
            }
        } catch {
            errorMessage = t("updateCheckFailed", "\(error)")
            phase = .failed
        }
    }

    // MARK: - Download

    func startDownload() {
        guard phase == .available || phase == .failed else { return }
        phase = .downloading
        percent = 0
        errorMessage = ""
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self, let api = self.api else { return }
            do {
                try await api.updateDownload()
            } catch {
                await MainActor.run {
                    self.errorMessage = "\(error)"
                    self.phase = .failed
                }
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let state = try? await api.updateState() else { continue }
                await MainActor.run { self.absorb(state) }
                if state.phase != "downloading" { break }
            }
        }
    }

    private func absorb(_ state: RivetTypes.UpdateState) {
        percent = Int(state.percent)
        switch state.phase {
        case "downloaded":
            pollTask?.cancel()
            downloadedPath = state.downloaded_path
            phase = .downloaded
        case "error":
            pollTask?.cancel()
            errorMessage = state.message ?? t("updateInstallFailed", "download failed")
            phase = .failed
        default:
            break
        }
    }

    // MARK: - Install (quit and swap)

    /// "Quit and install": read the verified artifact path from the
    /// backend state, spawn the swap script, and leave through the normal
    /// exit path so AppKit tears the app down cleanly.
    func quitAndInstall() {
        guard phase == .downloaded else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                // The controller caches the path when the backend reported
                // "downloaded"; fall back to the state RPC if needed.
                var path = self.downloadedPath
                if path == nil, let api = self.api {
                    path = (try? await api.updateState())?.downloaded_path
                        .flatMap({ $0.isEmpty ? nil : $0 })
                }
                guard let zipPath = path else {
                    throw UpdateError.stateMissing
                }
                try Self.installAndRelaunch(zipPath: zipPath,
                                            expectedVersion: self.availableVersion)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                await MainActor.run {
                    self.errorMessage = self.t("updateInstallFailed", Self.cleanError(error))
                    self.phase = .failed
                }
            }
        }
    }

    static func cleanError(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// The installed bundle this copy can update in place, or nil for
    /// development copies (not under /Applications or ~/Applications).
    nonisolated static func installedBundleURL() -> URL? {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app"),
              path.hasPrefix("/Applications/")
                  || path.hasPrefix("/Users/") && path.contains("/Applications/") else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static var canUpdate: Bool { installedBundleURL() != nil }

    /// The whole verify → unzip → swap sequence, deliberately pure so it
    /// throws before touching the running install when anything is off.
    nonisolated static func installAndRelaunch(zipPath: String,
                                               expectedVersion: String) throws {
        guard let bundleURL = installedBundleURL() else {
            throw UpdateError.notInstalled
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fulcrum-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let unpacked = workDir.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipPath, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw UpdateError.payloadMissing
        }

        // The archive carries one .app (fulcrum.app); find it rather than
        // hard-coding the name so the release layout can evolve.
        let entries = try FileManager.default.contentsOfDirectory(atPath: unpacked.path)
        guard let appName = entries.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.payloadMissing
        }
        let newBundle = unpacked.appendingPathComponent(appName)
        guard let newVersion = Bundle(url: newBundle)?
            .infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw UpdateError.versionMismatch(expected: expectedVersion, got: "missing")
        }
        guard newVersion == expectedVersion else {
            throw UpdateError.versionMismatch(expected: expectedVersion, got: newVersion)
        }

        // Swap: the shell script survives our exit; it also restores the
        // old bundle if the new one fails to move in. The data directory
        // (settings, snippets, downloads) is never touched.
        let old = bundleURL.path + ".old"
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf \(q(old))
        if mv \(q(bundleURL.path)) \(q(old)); then
          if mv \(q(newBundle.path)) \(q(bundleURL.path)); then
            open \(q(bundleURL.path))
            rm -rf \(q(old))
            exit 0
          fi
          mv \(q(old)) \(q(bundleURL.path))
        fi
        exit 1
        """
        let swapPath = workDir.appendingPathComponent("swap.sh")
        try script.write(to: swapPath, atomically: true, encoding: .utf8)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", swapPath.path]
        try chmod.run()
        chmod.waitUntilExit()

        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = [swapPath.path]
        try bash.run()
    }

    nonisolated private static func q(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
