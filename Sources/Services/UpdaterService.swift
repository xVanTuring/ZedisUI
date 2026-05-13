import Foundation
import Observation
import Sparkle
import Combine

/// Thin SwiftUI-friendly wrapper around Sparkle 2's
/// `SPUStandardUpdaterController`. The controller drives the entire
/// update flow — feed fetch, signature verification, download,
/// out-of-process install via the embedded Installer XPC service, and
/// restart — using Sparkle's native UI. We only own:
///
/// 1. The controller's lifetime (so the updater keeps running while
///    the app is alive).
/// 2. An `SPUUpdaterDelegate` that maps our "Include pre-releases"
///    preference onto Sparkle's channel system (`<sparkle:channel>beta</sparkle:channel>`
///    in the appcast).
/// 3. SwiftUI-observable mirrors of `canCheckForUpdates` and
///    `lastUpdateCheckDate` so the Preferences pane re-renders when
///    a check completes.
@Observable
@MainActor
final class UpdaterService {

    let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

    /// Mirrors `controller.updater.canCheckForUpdates`. Used to enable
    /// / disable the "Check Now" button while a check is in flight.
    private(set) var canCheck: Bool = true

    /// Mirrors `controller.updater.lastUpdateCheckDate`.
    private(set) var lastChecked: Date?

    /// The underlying Sparkle controller. Public so SwiftUI views can
    /// bind menu items / buttons straight to its target/action API
    /// (e.g. `controller.checkForUpdates(_:)`).
    let controller: SPUStandardUpdaterController

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private let delegate: UpdaterDelegate

    init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        lastChecked = updater.lastUpdateCheckDate

        // Sparkle marks these properties KVO-compliant; mirror them
        // into @Observable storage so SwiftUI subscribes correctly.
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastChecked = $0 }
            .store(in: &cancellables)
    }

    /// Bridges the legacy "updater.autoCheck" preference to Sparkle's
    /// own scheduled-check toggle. Sparkle persists the value in its
    /// own defaults domain — we read/write through the updater so both
    /// sides stay in sync.
    var autoCheck: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// User-initiated check. Sparkle drives the entire flow (including
    /// the "up to date" alert) with its native UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Silent launch-time check. Sparkle only surfaces UI if an update
    /// is actually available; no popup on "you're up to date".
    func checkInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }
}

/// Maps the "Include pre-releases" UserDefaults flag onto Sparkle's
/// channel mechanism. release.sh tags beta items with
/// `<sparkle:channel>beta</sparkle:channel>` in `appcast.xml`; items
/// without a channel tag are always considered (= stable).
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let includePrereleases = UserDefaults.standard.bool(forKey: "updater.includePrereleases")
        return includePrereleases ? ["beta"] : []
    }
}
