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
        // Hide the title bar entirely on the Launcher; the traffic lights
        // stay overlaid on content. Session windows keep the standard bar
        // because they need .navigationTitle / .navigationSubtitle for the
        // connection name + host.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") {
                    appState.showNewConnectionSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(WindowID.updater) == true }) {
                        win.makeKeyAndOrderFront(nil)
                    } else {
                        // A view bridges this notification to `openWindow`,
                        // which isn't available from a CommandGroup closure.
                        NotificationCenter.default.post(name: .openUpdaterWindow, object: nil)
                    }
                }
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

        // Connection Detail — a separate window that surfaces the full
        // INFO snapshot (server, memory, clients, stats, keyspace) plus
        // the saved profile. Same value-keyed reuse pattern.
        WindowGroup(id: WindowID.connectionDetail, for: Connection.self) { $connection in
            Group {
                if let connection {
                    ConnectionDetailView(connection: connection)
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

        // Singleton updater window. Opened from the app menu and (when
        // a background launch-time check finds a new version) auto-opened
        // by the launcher.
        Window("Software Update", id: WindowID.updater) {
            UpdateView()
                .environment(appState)
        }
        .windowResizability(.contentSize)

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
    static let connectionDetail = "connection-detail"
    static let updater = "updater"
}

extension Notification.Name {
    static let openUpdaterWindow = Notification.Name("ZedisUI.openUpdaterWindow")
}
