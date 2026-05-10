import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
        .frame(width: 480, height: 320)
    }
}
