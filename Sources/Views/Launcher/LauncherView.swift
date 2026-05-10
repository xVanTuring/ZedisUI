import SwiftUI
import AppKit

struct LauncherView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var quickHost: String = "localhost"
    @State private var quickPort: String = "6379"
    @State private var quickConnecting: Bool = false
    @State private var quickError: String?

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 0) {
            sidePanel
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .background(SidebarBackground())

            mainPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
        .frame(minWidth: 760, minHeight: 460)
        .sheet(isPresented: $state.showNewConnectionSheet) {
            ConnectionDialogView(mode: .create) { newConnection in
                appState.addConnection(newConnection)
            }
        }
        .sheet(item: $state.connectionBeingEdited) { conn in
            ConnectionDialogView(mode: .edit(conn)) { updated in
                appState.updateConnection(updated)
            }
        }
    }

    // MARK: - Side panel (brand + actions)

    private var sidePanel: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 36)

            BrandLogo()
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("ZedisUI")
                    .font(.title3.bold())
                Text(buildLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 8) {
                Button {
                    appState.showNewConnectionSheet = true
                } label: {
                    Label("New Server…", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    // Group support: deferred. Show a tooltip-style hint via alert?
                    // For now we just no-op so the button keeps the visual rhythm.
                } label: {
                    Label("New Group…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(true)
                .help("Coming soon")

                Button {
                    importConnections()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var buildLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Build \(short) (\(build))"
    }

    // MARK: - Main panel (quick connect + saved list)

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickConnectSection
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            savedConnectionsSection
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var quickConnectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Connect")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("localhost", text: $quickHost)
                    .textFieldStyle(.roundedBorder)
                TextField("6379", text: $quickPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Button {
                    quickConnect()
                } label: {
                    if quickConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                            .frame(minWidth: 70)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(quickHost.trimmingCharacters(in: .whitespaces).isEmpty
                          || Int(quickPort) == nil
                          || quickConnecting)
            }
            if let quickError {
                Label(quickError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var savedConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved Connections")
                    .font(.headline)
                Spacer()
                Text("\(appState.connections.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }

            if appState.connections.isEmpty {
                ContentUnavailableView {
                    Label("No saved connections", systemImage: "tray")
                } description: {
                    Text("Click **New Server…** to add your first connection.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(appState.connections) { conn in
                            SavedConnectionRow(
                                connection: conn,
                                status: appState.sessions[conn.id]?.status,
                                onConnect: { connect(conn) },
                                onEdit: { appState.connectionBeingEdited = conn },
                                onDelete: { appState.removeConnection(conn.id) }
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Actions

    private func quickConnect() {
        quickError = nil
        guard let port = Int(quickPort), (1...65535).contains(port) else {
            quickError = "Port must be 1–65535"
            return
        }
        let host = quickHost.trimmingCharacters(in: .whitespaces)
        let conn = Connection(
            name: "\(host):\(port)",
            host: host,
            port: port
        )
        // We open the session window without saving the connection. The session
        // window owns the lifecycle of this transient connection.
        openWindow(id: WindowID.session, value: conn)
    }

    private func connect(_ connection: Connection) {
        openWindow(id: WindowID.session, value: connection)
    }

    private func importConnections() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import connections from JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode([Connection].self, from: data)
            for c in imported {
                // Re-key so we don't collide with existing ids.
                var copy = c
                copy.id = UUID()
                appState.addConnection(copy)
            }
        } catch {
            // Surface a brief alert via NSAlert; cheaper than threading another
            // @State error binding here.
            let alert = NSAlert()
            alert.messageText = "Could not import connections"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Saved connection row

private struct SavedConnectionRow: View {
    let connection: Connection
    let status: RedisSession.Status?
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .lineLimit(1)
                Text("\(connection.host):\(connection.port) · db\(connection.defaultDB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Edit", action: onEdit)
                .controlSize(.regular)
            Button("Connect", action: onConnect)
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? Color.primary.opacity(0.05) : Color.primary.opacity(0.025))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Connect", action: onConnect)
            Button("Edit…", action: onEdit)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .help(statusTooltip)
    }

    private var statusColor: Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected, .none: return .gray.opacity(0.5)
        }
    }

    private var statusTooltip: String {
        switch status {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .failed(let s): return "Failed: \(s)"
        case .disconnected: return "Disconnected"
        case .none:         return "Not connected"
        }
    }
}

// MARK: - Visual

private struct BrandLogo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.95, green: 0.35, blue: 0.30),
                             Color(red: 0.92, green: 0.55, blue: 0.35)],
                    startPoint: .top,
                    endPoint: .bottom))
                .shadow(color: Color.red.opacity(0.35), radius: 14, x: 0, y: 8)
            Text("Z")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

private struct SidebarBackground: View {
    var body: some View {
        // A soft, slightly darker panel that reads as "sidebar" in both light
        // and dark mode, even outside the standard NavigationSplitView chrome.
        Rectangle()
            .fill(.background.secondary)
    }
}
