import AppKit
import Foundation
import RivetUpdate
import SwiftUI

/// macOS update flow uses RivetUpdate's native CryptoKit verification and
/// bounded, SHA-256-checked download. The embedded Racket updater continues
/// to serve Windows/Linux, but its libcrypto factory can be unavailable in
/// an installed macOS app even when the embedded DER public key is valid.
///
/// The committed key is the exact 32-byte Ed25519 public part of the DER SPKI
/// in app/update.rkt, base64-encoded for CryptoKit. tests/update-test.rkt
/// prevents these two trust roots from drifting.
@MainActor
final class UpdateController: ObservableObject {
    nonisolated(unsafe) static var shared: UpdateController?

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case failed
    }

    @Published var panelVisible = false
    @Published var phase: Phase = .idle
    @Published var percent = 0
    @Published var availableVersion = ""
    @Published var availableSize: Int64 = 0
    @Published var errorMessage = ""

    private weak var model: LauncherModel?
    private var pendingManifest: RivetUpdateManifest?
    private var downloadTask: Task<Void, Never>?

    // Never store a signing private key in the app. The feed URL is allowed
    // to move to latest, but the signature key identity is pinned here.
    private static let feedURL = URL(string:
        "https://github.com/turinglambdaai/fulcrum/releases/latest/download/update-manifest.json")!
    private static let publicKeyBase64 = "R5cgPk4fzhCeRdQbp1XofrfSYcCCtb9nKK4OqqWOVdc="
    private static let keyID = "fulcrum-2026-10"
    private static let lastCheckKey = "fulcrum.native-update.last-check"

    private let updater: RivetUpdateService?

    var i18n: I18nService { I18nService.shared }

    init() {
        updater = try? RivetUpdateService(configuration: RivetUpdateConfiguration(
            feedURL: Self.feedURL,
            publicKeyBase64: Self.publicKeyBase64,
            keyID: Self.keyID,
            bundleName: "fulcrum.app"))
        Self.shared = self
    }

    func attach(model: LauncherModel) {
        self.model = model
    }

    func t(_ key: String, _ args: Any...) -> String {
        if args.isEmpty { return i18n.t(key) }
        return i18n.format(key, args)
    }

    func checkForUpdates() {
        panelVisible = true
        guard phase != .downloading else { return }
        Task { await check(manual: true) }
    }

    func silentStartupCheck() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard phase != .downloading else { return }
            await check(manual: false)
        }
    }

    // A backend update-available notification may still arrive from older
    // RPC flows. It should only open the native panel, never trust an
    // unsigned or backend-only candidate.
    func offered() {
        checkForUpdates()
        AppDelegate.shared?.showUpdatePanel()
    }

    func check(manual: Bool) async {
        guard phase != .downloading else { return }
        // Preserve the 4-hour silent throttle; a manual check always
        // bypasses it. Store the timestamp across relaunches.
        if !manual {
            let defaults = UserDefaults.standard
            if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
               Date().timeIntervalSince(last) < 4 * 60 * 60 {
                return
            }
            defaults.set(Date(), forKey: Self.lastCheckKey)
        }
        phase = .checking
        errorMessage = ""
        pendingManifest = nil
        guard let updater else {
            errorMessage = t("updateCheckFailed", "native update configuration unavailable")
            phase = .failed
            return
        }
        do {
            switch try await updater.check() {
            case .upToDate:
                phase = .upToDate
            case .available(let manifest):
                guard let artifact = manifest.artifact(forPlatform: "macos") else {
                    throw RivetUpdateError.manifestMissing
                }
                pendingManifest = manifest
                availableVersion = manifest.version
                availableSize = Int64(artifact.size)
                phase = .available
                panelVisible = true
                if !manual {
                    AppDelegate.shared?.showUpdatePanel()
                }
            }
        } catch {
            errorMessage = t("updateCheckFailed", Self.cleanError(error))
            phase = .failed
        }
    }

    /// RivetUpdate verifies the signed archive's size, SHA-256 and bundle
    /// version before an atomic swap and relaunch. Do not call the Racket
    /// update-download RPC on macOS: it needs the unavailable libcrypto key.
    func startDownload() {
        guard phase == .available, let manifest = pendingManifest,
              let updater else { return }
        phase = .downloading
        percent = 0
        errorMessage = ""
        downloadTask = Task { [weak self] in
            do {
                try await updater.downloadAndInstall(manifest, onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.percent = progress
                    }
                })
                // Success normally terminates the app from RivetUpdate's
                // swap handoff; never claim an install if it returned.
            } catch {
                self?.errorMessage = Self.cleanError(error)
                self?.phase = .failed
            }
        }
    }

    static func cleanError(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    nonisolated static var canUpdate: Bool {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") &&
            (path.hasPrefix("/Applications/") ||
             (path.hasPrefix("/Users/") && path.contains("/Applications/")))
    }
}
