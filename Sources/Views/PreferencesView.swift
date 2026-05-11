import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

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
                Toggle("Automatically check for updates on launch", isOn: $autoCheckUpdates)
                Toggle("Include pre-releases", isOn: $includePrereleases)
            } footer: {
                Text("ZedisUI checks the project's GitHub releases. The new build is downloaded for you, but you'll be asked to drag it into /Applications because the sandbox forbids self-replacement.")
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
                        NotificationCenter.default.post(name: .openUpdaterWindow, object: nil)
                        Task { await appState.updater.check() }
                    }
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
