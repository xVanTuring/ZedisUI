import SwiftUI

/// One per session window — owns its session lookup/setup.
struct SessionWindow: View {
    let connection: Connection
    @Environment(AppState.self) private var appState
    @State private var session: RedisSession?
    @State private var failure: String?

    var body: some View {
        Group {
            if let session {
                SessionContent(session: session)
            } else if let failure {
                ContentUnavailableView(
                    "Connection failed",
                    systemImage: "xmark.octagon",
                    description: Text(failure)
                )
                .navigationTitle(connection.name)
                .navigationSubtitle("\(connection.host):\(connection.port) · Failed")
            } else {
                ProgressView("Connecting to \(connection.host):\(connection.port)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(connection.name)
                    .navigationSubtitle("\(connection.host):\(connection.port) · Connecting…")
            }
        }
        .task { await ensureSession() }
    }

    private func ensureSession() async {
        if let existing = appState.sessions[connection.id] {
            session = existing
            return
        }
        do {
            let s = try await appState.session(for: connection)
            session = s
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct SessionContent: View {
    @Bindable var session: RedisSession
    @State private var showInspector: Bool = false
    @State private var newKeyDialog: NewKeyDialog?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            KeySidebarView(session: session)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            DetailView(session: session)
        }
        .inspector(isPresented: $showInspector) {
            InspectorPanel(session: session)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .failed(let msg) = session.status {
                ConnectionErrorBanner(message: msg) {
                    Task { try? await session.connect() }
                }
            }
        }
        .navigationTitle(session.connection.name)
        .navigationSubtitle(subtitleText)
        .sheet(item: $newKeyDialog) { dialog in
            NewKeySheet(initialType: dialog.type) { name, type in
                Task { await createKey(name: name, type: type) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { /* nav back */ } label: { Image(systemName: "chevron.left") }
                    .disabled(true)
                Button { /* nav fwd */ } label: { Image(systemName: "chevron.right") }
                    .disabled(true)
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach([RedisKeyType.string, .hash, .list, .set, .zset], id: \.self) { t in
                        Button(t.displayName) { newKeyDialog = NewKeyDialog(type: t) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New key")
            }
            // Native NSSearchField, principal slot — lands between the
            // window title (rendered in `.navigationTitle`) and the trailing
            // primaryAction items. The magnifier icon's built-in menu
            // (`searchMenuTemplate`) doubles as the type filter.
            ToolbarItem(placement: .principal) {
                NativeSearchField(
                    text: $session.pattern,
                    typeFilter: $session.typeFilter,
                    prompt: "Search keys"
                ) {
                    Task { await session.reloadKeys() }
                }
                .frame(width: 240)
            }

            ToolbarItem(placement: .primaryAction) {
                ConnectionStatusButton(session: session)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: WindowID.commandHistory, value: session.connection)
                } label: {
                    Image(systemName: "clock")
                }
                .help("Command history")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { /* pubsub */ } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                    .disabled(true)
                    .help("Pub/Sub (coming soon)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { /* lock */ } label: { Image(systemName: "lock.open") }
                    .disabled(true)
                    .help("Read-only mode (coming soon)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.reloadKeys() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload keys")
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle inspector")
            }
        }
    }

    private func createKey(name: String, type: RedisKeyType) async {
        do {
            switch type {
            case .string: try await session.service.setString(name, value: "")
            case .list:   try await session.service.rpush(name, value: "")
            case .set:    try await session.service.sadd(name, member: "")
            case .zset:   try await session.service.zadd(name, member: "", score: 0)
            case .hash:   try await session.service.hset(name, field: "field", value: "")
            case .stream, .unknown: break
            }
            await session.reloadKeys()
            session.selectedKey = name
        } catch { /* surfaced via session.status */ }
    }

    private var subtitleText: String {
        let host = "\(session.connection.host):\(session.connection.port)"
        switch session.status {
        case .disconnected: return "\(host) · Disconnected"
        case .connecting:   return "\(host) · Connecting…"
        case .connected:    return "\(host) · DB \(session.currentDB)"
        case .failed:       return "\(host) · Failed"
        }
    }
}

// MARK: - Status button (toolbar) + popover

private struct ConnectionStatusButton: View {
    let session: RedisSession
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
        .help(helpText)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ConnectionStatusPopover(session: session) { showPopover = false }
        }
    }

    private var iconName: String {
        switch session.status {
        case .connected:    return "circle.fill"
        case .connecting:   return "circle.dotted"
        case .failed:       return "exclamationmark.circle.fill"
        case .disconnected: return "circle"
        }
    }

    private var iconColor: Color {
        switch session.status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return .secondary
        }
    }

    private var helpText: String {
        switch session.status {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .failed:       return "Connection failed"
        case .disconnected: return "Disconnected"
        }
    }
}

private struct ConnectionStatusPopover: View {
    let session: RedisSession
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.connection.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Host", session.connection.host)
                row("Port", String(session.connection.port))
                if let username = session.connection.username, !username.isEmpty {
                    row("Username", username)
                }
                row("Database", "DB \(session.currentDB)  ·  \(session.dbSize) keys")
                if let v = session.serverVersion {
                    row("Version", v)
                }
            }
            .font(.callout)

            HStack {
                if case .connected = session.status {
                    Button("Disconnect") {
                        Task { await session.disconnect() }
                        onDismiss()
                    }
                } else {
                    Button("Reconnect") {
                        Task { try? await session.connect() }
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .gridColumnAlignment(.leading)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch session.status {
        case .connected:        return "Connected"
        case .connecting:       return "Connecting…"
        case .failed(let msg):  return "Failed · \(msg)"
        case .disconnected:     return "Disconnected"
        }
    }
}

// MARK: - Error banner (only shown when status is .failed)

private struct ConnectionErrorBanner: View {
    let message: String
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Connection failed")
                .fontWeight(.medium)
            Text("·")
                .foregroundStyle(.white.opacity(0.6))
            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button("Reconnect", action: onReconnect)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white)
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.85))
    }
}
