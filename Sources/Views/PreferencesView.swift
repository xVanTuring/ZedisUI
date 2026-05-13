import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    // Mirrors Sparkle's own `automaticallyChecksForUpdates`. The
    // @AppStorage keeps the Launcher's silent-check gate in sync with
    // what Sparkle persists internally; UpdaterService writes through
    // to both via `autoCheck`.
    @AppStorage("updater.autoCheck") private var autoCheckUpdates: Bool = true
    @AppStorage("updater.includePrereleases") private var includePrereleases: Bool = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520, height: 360)
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(appState.connections.count) saved connection(s)")
                .foregroundStyle(.secondary)
            List(appState.connections) { c in
                HStack {
                    Text(c.name)
                    Spacer()
                    Text("\(c.host):\(c.port)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .padding()
    }

    private var updatesTab: some View {
        Form {
            Section {
                Toggle("Automatically check for updates on launch", isOn: Binding(
                    get: { autoCheckUpdates },
                    set: { newValue in
                        autoCheckUpdates = newValue
                        appState.updater.autoCheck = newValue
                    }
                ))
                Toggle("Include pre-releases", isOn: $includePrereleases)
            } footer: {
                Text("Updates are downloaded, verified with EdDSA, and installed by Sparkle's out-of-process helper. Pre-release builds come from the `beta` channel in the appcast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Current version")
                    Spacer()
                    Text(appState.updater.currentVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text("Last checked")
                    Spacer()
                    Text(lastCheckedLabel)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Check Now…") {
                        appState.updater.checkForUpdates()
                    }
                    .disabled(!appState.updater.canCheck)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckedLabel: String {
        guard let date = appState.updater.lastChecked else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
