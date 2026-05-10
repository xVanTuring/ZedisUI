import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("ZedisUI.scanPageSize") private var scanPageSize: Int = 200
    @AppStorage("ZedisUI.fontSize") private var fontSize: Double = 13

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            connectionsTab
                .tabItem { Label("Connections", systemImage: "server.rack") }
        }
        .frame(width: 480, height: 320)
    }

    private var generalTab: some View {
        Form {
            Section("Scanning") {
                Stepper(
                    "Keys per SCAN page: \(scanPageSize)",
                    value: $scanPageSize,
                    in: 50...2000,
                    step: 50
                )
            }
            Section("Editor") {
                Slider(value: $fontSize, in: 10...20, step: 1) {
                    Text("Editor font size: \(Int(fontSize))pt")
                }
            }
        }
        .padding()
    }

    private var connectionsTab: some View {
        VStack(alignment: .leading) {
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
}
