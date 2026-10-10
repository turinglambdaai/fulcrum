import SwiftUI

/// The update panel (opened from the menu bar's "Check for Updates…" or by
/// the update-available event). One column that follows the backend's phase
/// state machine: checking → up-to-date / available → downloading →
/// downloaded → quit-and-install, with errors recoverable in place. All
/// strings come from shared/i18n via I18nService (language setting).
struct UpdatePanelView: View {
    @ObservedObject var controller: UpdateController

    private var sizeLabel: String {
        let bytes = controller.availableSize
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        if bytes >= 1024 {
            return "\(bytes / 1024) KB"
        }
        return "\(bytes) B"
    }

    var body: some View {
        VStack(spacing: 18) {
            switch controller.phase {
            case .idle:
                checking
            case .checking:
                checking
            case .upToDate:
                upToDate
            case .available:
                available
            case .downloading:
                downloading
            case .downloaded:
                downloaded
            case .failed:
                failed
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    private var checking: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(controller.t("updateChecking"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 120)
    }

    private var upToDate: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text(controller.t("updateUpToDate"))
                .font(.system(size: 14, weight: .medium))
            closeButtons
        }
        .frame(minHeight: 120)
    }

    private var available: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(FulcrumTheme.accent)
            Text(controller.t("updateAvailableTitle"))
                .font(.system(size: 15, weight: .semibold))
            Text(controller.t("updateAvailableBody",
                              controller.availableVersion, sizeLabel))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(controller.t("updateClose")) {
                    controller.panelVisible = false
                    controller.phase = .idle
                }
                .keyboardShortcut(.cancelAction)
                Button(controller.t("updateDownload")) {
                    controller.startDownload()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            if !UpdateController.canUpdate {
                Text(controller.t("updateNotInstalled"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var downloading: some View {
        VStack(spacing: 14) {
            Text(controller.t("updateDownloadPercent", controller.percent))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            ProgressView(value: Double(controller.percent), total: 100)
                .progressViewStyle(.linear)
                .tint(FulcrumTheme.accent)
        }
        .frame(minHeight: 120)
    }

    private var downloaded: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(FulcrumTheme.accent)
            Text(controller.t("updateDownloaded"))
                .font(.system(size: 14, weight: .medium))
            Text(controller.t("updateReadyBody"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if !UpdateController.canUpdate {
                    Button(controller.t("updateOpenFolder")) {
                        if let path = controller.downloadedPath {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                }
                Button(controller.t("updateQuitAndInstall")) {
                    controller.quitAndInstall()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!UpdateController.canUpdate)
            }
            if !UpdateController.canUpdate {
                Text(controller.t("updateInstallHintMac"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
    }

    private var failed: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.orange)
            Text(controller.errorMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 10) {
                Button(controller.t("updateClose")) {
                    controller.panelVisible = false
                    controller.phase = .idle
                }
                .keyboardShortcut(.cancelAction)
                Button(controller.t("updateRetry")) {
                    Task { await controller.retry() }
                }
            }
        }
        .frame(minHeight: 120)
    }

    private var closeButtons: some View {
        Button(controller.t("updateClose")) {
            controller.panelVisible = false
            controller.phase = .idle
        }
        .keyboardShortcut(.defaultAction)
    }
}

extension UpdateController {
    /// Retry after a failed check or download (a downloaded artifact stays
    /// installed-ready; anything else re-runs the check).
    func retry() async {
        if downloadedPath != nil {
            phase = .available
            return
        }
        await check(manual: true)
    }
}
