import SwiftUI
import AppKit

/// "Check for Updates" window. Reads the shared UpdaterService on AppState
/// and drives the phase through check → available → download → ready.
struct UpdateView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .task {
            // Auto-kick a check the first time the window is opened in an
            // idle state; otherwise leave the existing phase alone (e.g.
            // user already saw "Update available" from the launch poll).
            if case .idle = appState.updater.phase {
                await appState.updater.check()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("ZedisUI")
                    .font(.title2.weight(.semibold))
                Text("Current version \(appState.updater.currentVersion)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch appState.updater.phase {
        case .idle:
            placeholder(systemImage: "arrow.triangle.2.circlepath",
                        title: "Check for Updates",
                        subtitle: "Click Check Now to look for a newer release on GitHub.")
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            placeholder(systemImage: "checkmark.circle.fill",
                        title: "You're up to date",
                        subtitle: "ZedisUI \(appState.updater.currentVersion) is the latest version.",
                        tint: .green)
        case .available(let release):
            availableSection(release)
        case .downloading(let progress, let release):
            downloadingSection(progress: progress, release: release)
        case .readyToInstall(_, let release):
            readySection(release: release)
        case .error(let message):
            placeholder(systemImage: "exclamationmark.triangle.fill",
                        title: "Update check failed",
                        subtitle: message,
                        tint: .orange)
        }
    }

    private var footer: some View {
        HStack {
            if let last = appState.updater.lastChecked {
                Text("Last checked \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            footerButtons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Phase sections

    private func availableSection(_ release: UpdaterService.Release) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Version \(release.version) is available")
                    .font(.headline)
                if release.isPrerelease {
                    Text("PRE-RELEASE")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 12) {
                Label("\(release.version)", systemImage: "tag")
                Label(byteCount(release.assetSize), systemImage: "internaldrive")
                if let published = release.publishedAt {
                    Label(published.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Release notes")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            ScrollView {
                Text(release.notes.isEmpty ? "_No release notes provided._" : release.notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    private func downloadingSection(progress: Double, release: UpdaterService.Release) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Downloading version \(release.version)…")
                .font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text("\(Int(progress * 100))% of \(byteCount(release.assetSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func readySection(release: UpdaterService.Release) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Version \(release.version) is ready to install")
                    .font(.headline)
            }
            if appState.updater.canInstallInPlace {
                Text("Click **Restart & Install** to finish. ZedisUI will quit, swap in the new version, and relaunch automatically.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If anything goes wrong, the previous version is kept alongside until install completes; you can also use Reveal in Finder to install by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("To finish updating:")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    bullet("1. Quit ZedisUI.")
                    bullet("2. In the Finder window that opens, drag **ZedisUI.app** into **/Applications**, replacing the existing copy.")
                    bullet("3. Relaunch ZedisUI from /Applications or Spotlight.")
                }
                .font(.callout)

                Text("Auto-install requires ZedisUI to be in /Applications — this build is running from a different location, so the drag step is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            Spacer()
        }
    }

    private func placeholder(systemImage: String,
                             title: String,
                             subtitle: String,
                             tint: Color = .secondary) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bullet(_ text: String) -> some View {
        Text(.init(text))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer buttons

    @ViewBuilder
    private var footerButtons: some View {
        switch appState.updater.phase {
        case .idle, .upToDate, .error:
            Button("Close") { dismissWindow() }
            Button("Check Now") {
                Task { await appState.updater.check() }
            }
            .keyboardShortcut(.defaultAction)
        case .checking:
            Button("Close") { dismissWindow() }
        case .available(let release):
            Button("View on GitHub") { appState.updater.openReleasePage() }
            Button("Later") { dismissWindow() }
            Button("Download Update") {
                Task { await appState.updater.downloadAndInstall(release) }
            }
            .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Close") { dismissWindow() }
                .disabled(true)
        case .readyToInstall:
            Button("Close") { dismissWindow() }
            Button("Reveal in Finder") {
                appState.updater.revealInFinder()
            }
            if appState.updater.canInstallInPlace {
                Button("Restart & Install") {
                    appState.updater.installAndRestart()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Helpers

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
