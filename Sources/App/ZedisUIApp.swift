import SwiftUI

@main
struct ZedisUIApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("ZedisUI", id: WindowID.launcher) {
            LauncherView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 460)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    appState.showNewConnectionSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .windowList) {
                Divider()
                Button("Connection Manager") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("launcher") == true }) {
                        win.makeKeyAndOrderFront(nil)
                    }
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }

        WindowGroup(id: WindowID.session, for: Connection.self) { $connection in
            Group {
                if let connection {
                    SessionWindow(connection: connection)
                        .environment(appState)
                        .frame(minWidth: 1100, minHeight: 680)
                } else {
                    ContentUnavailableView(
                        "No Connection",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This window is missing its connection. Open the Connection Manager to start a new session.")
                    )
                }
            }
        }

        // One Command History window per connection. Same value-keyed
        // WindowGroup pattern as the session window — opening the same
        // connection twice reuses the existing history window.
        WindowGroup(id: WindowID.commandHistory, for: Connection.self) { $connection in
            Group {
                if let connection {
                    CommandHistoryView(connection: connection)
                        .environment(appState)
                } else {
                    ContentUnavailableView(
                        "No Connection",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This window is missing its connection.")
                    )
                }
            }
        }

        Settings {
            PreferencesView()
                .environment(appState)
        }
    }
}

enum WindowID {
    static let launcher = "launcher"
    static let session = "session"
    static let commandHistory = "command-history"
}
