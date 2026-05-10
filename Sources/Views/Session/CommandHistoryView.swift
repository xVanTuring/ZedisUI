import SwiftUI

/// Window contents for `WindowID.commandHistory`. Shows every command issued
/// against the session's Redis connection in a three-column table:
/// Time / Command / Argument. Most recent first, matching Medis.
struct CommandHistoryView: View {
    let connection: Connection
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let session = appState.sessions[connection.id] {
                HistoryTable(history: session.history)
            } else {
                ContentUnavailableView(
                    "No Active Session",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("Open the connection from the Connection Manager to start logging commands.")
                )
            }
        }
        .navigationTitle("Command History")
        .navigationSubtitle(connection.name)
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct HistoryTable: View {
    let history: CommandHistory

    var body: some View {
        Table(rows) {
            TableColumn("Time") { entry in
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .width(min: 110, ideal: 120, max: 160)

            TableColumn("Command") { entry in
                Text(entry.command.uppercased())
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            .width(min: 90, ideal: 110, max: 200)

            TableColumn("Argument") { entry in
                Text(entry.argument)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .tableStyle(.inset)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    history.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear history")
                .disabled(history.entries.isEmpty)
            }
        }
    }

    /// Newest entries on top — Medis's default ordering. We render a reversed
    /// view rather than reversing the storage so `append` stays O(1).
    private var rows: [CommandLogEntry] {
        Array(history.entries.reversed())
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
