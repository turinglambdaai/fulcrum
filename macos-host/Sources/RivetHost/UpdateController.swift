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
    #if FULCRUM_UPDATE_E2E_TESTING
    private static let feedURL = URL(string:
        "https://github.com/turinglambdaai/fulcrum/releases/download/v0.14.0/update-manifest.json")!
    #else
    private static let feedURL = URL(string:
        "https://github.com/turinglambdaai/fulcrum/releases/latest/download/update-manifest.json")!
    #endif
    private static let publicKeyBase64 = "R5cgPk4fzhCeRdQbp1XofrfSYcCCtb9nKK4OqqWOVdc="
    private static let keyID = "fulcrum-2026-10"
    private static let lastCheckKey = "fulcrum.native-update.last-check"
    private static let rolloutBucketKey = "fulcrum.native-update.rollout-bucket"
    private static let maximumManifestBytes = 4 * 1024 * 1024

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
            // The native CryptoKit verifier authenticates the signed
            // payload, then we apply the same eligibility gates as Racket's
            // select-update: app ID, stable channel, minimum version,
            // sticky rollout bucket, architecture and zip installer.
            // RivetUpdateService.check() only compares versions, and must
            // not decide installation eligibility by itself.
            if let manifest = try await fetchEligibleManifest() {
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
            } else {
                phase = .upToDate
            }
        } catch {
            errorMessage = t("updateCheckFailed", Self.cleanError(error))
            phase = .failed
        }
    }

    #if FULCRUM_UPDATE_E2E_TESTING
    /// Test-only entry point used by the real signed-feed E2E workflow. It
    /// runs the same eligibility check and download/install path as the update
    /// panel, but records status to a file so CI can assert the transaction.
    func runUpdateE2ETest() {
        Task { @MainActor in
            UserDefaults.standard.set(0, forKey: Self.rolloutBucketKey)
            self.writeUpdateE2ELog("CHECK_STARTED")
            await self.check(manual: true)
            guard self.phase == .available else {
                self.writeUpdateE2ELog("ERROR: update was not eligible: \(self.errorMessage)")
                exit(2)
            }
            self.writeUpdateE2ELog("AVAILABLE: \(self.availableVersion ?? "unknown")")
            self.startDownload()
            guard self.phase == .downloading else {
                self.writeUpdateE2ELog("ERROR: download did not start")
                exit(3)
            }
            self.writeUpdateE2ELog("INSTALL_STARTED")
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if self.phase == .failed {
                    self.writeUpdateE2ELog("ERROR: \(self.errorMessage)")
                    exit(4)
                }
            }
        }
    }

    private func writeUpdateE2ELog(_ line: String) {
        let prefix = "--update-e2e-log="
        guard let argument = CommandLine.arguments.first(where: {
            $0.hasPrefix(prefix)
        }) else { return }
        let path = String(argument.dropFirst(prefix.count))
        let url = URL(fileURLWithPath: path)
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (previous + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    private static func stickyRolloutBucket() -> Int {
        let defaults = UserDefaults.standard
        if let bucket = defaults.object(forKey: rolloutBucketKey) as? Int,
           (0..<100).contains(bucket) {
            return bucket
        }
        // Platform-specific persistence; preserve the backend's sticky
        // per-installation rollout semantics across launches.
        let bucket = Int.random(in: 0..<100)
        defaults.set(bucket, forKey: rolloutBucketKey)
        return bucket
    }

    private func fetchEligibleManifest() async throws -> RivetUpdateManifest? {
        let (wrapperBytes, response) = try await URLSession.shared.data(from: Self.feedURL)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              wrapperBytes.count > 0,
              wrapperBytes.count <= Self.maximumManifestBytes else {
            throw RivetUpdateError.manifestMissing
        }

        // Must authenticate THIS wrapper before inspecting the policy JSON.
        let signedManifest = try RivetUpdateService.verifyManifest(
            wrapperBytes, keyBase64: Self.publicKeyBase64, keyID: Self.keyID)
        let policy = try NativeUpdatePolicy.decodeAuthenticatedPayload(
            from: wrapperBytes)
        // The parser consumed the same signed payload; never trust a policy
        // view with a version different from RivetUpdate's install object.
        guard policy.version == signedManifest.version else {
            throw RivetUpdateError.signatureInvalid
        }
        guard let artifact = signedManifest.artifact(forPlatform: "macos") else {
            return nil
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "0.0.0"
        guard NativeUpdatePolicy.eligible(
            policy,
            installedVersion: current,
            arch: RivetUpdateManifest.hostArchitecture,
            rolloutBucket: Self.stickyRolloutBucket()) else {
            return nil
        }
        // The source and installer selection must describe the same signed
        // asset; no implicit fallback from the installable zip to a DMG.
        guard policy.artifacts.contains(where: {
            $0.platform == "macos" &&
            $0.architecture == RivetUpdateManifest.hostArchitecture &&
            $0.installer == "zip" && $0.component == nil &&
            $0.url == artifact.url && $0.size == artifact.size
        }) else {
            throw RivetUpdateError.manifestMissing
        }
        return signedManifest
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
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                if Task.isCancelled {
                    self?.phase = .idle
                } else {
                    self?.errorMessage = Self.cleanError(error)
                    self?.phase = .failed
                }
            }
            self?.downloadTask = nil
        }
    }

    /// RivetUpdate's delegate downloader observes task cancellation.
    /// Only allow cancellation during transfer, before install handoff.
    func cancelDownload() {
        guard phase == .downloading, percent < 100 else { return }
        downloadTask?.cancel()
        phase = .idle
        pendingManifest = nil
        percent = 0
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
