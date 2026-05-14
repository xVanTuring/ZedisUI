import SwiftUI

/// One per session window — owns its session lookup/setup.
struct SessionWindow: View {
    let connection: Connection
    @Environment(AppState.self) private var appState
    @State private var failure: String?
    @State private var credentialPrompt: CredentialPromptRequest?
    /// True while `ensureSession` is mid-flight. Without this, the
    /// `.task(id:)` re-fires while we're still trying to connect (the
    /// dictionary entry only appears after `session(for:)` returns),
    /// kicking off duplicate connects and stacking duplicate prompts.
    @State private var connecting: Bool = false

    /// Always read the freshest copy of the connection from AppState —
    /// the value captured in the WindowGroup is a snapshot from when the
    /// window first opened and may be stale after the user edits the
    /// profile.
    private var currentConnection: Connection {
        appState.connections.first(where: { $0.id == connection.id }) ?? connection
    }

    var body: some View {
        Group {
            if let session = appState.sessions[connection.id] {
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
                ProgressView("Connecting to \(currentConnection.host):\(currentConnection.port)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(currentConnection.name)
                    .navigationSubtitle("\(currentConnection.host):\(currentConnection.port) · Connecting…")
            }
        }
        // The id flips whenever the session entry appears/disappears.
        // That covers both the initial open and the post-edit reload
        // path (AppState.updateConnection drops the session).
        .task(id: appState.sessions[connection.id] == nil) {
            await ensureSession()
        }
        .sheet(item: $credentialPrompt) { request in
            CredentialPromptSheet(request: request) { creds in
                credentialPrompt = nil
                Task { await performConnect(credentials: creds) }
            } onCancel: {
                credentialPrompt = nil
            }
        }
    }

    private func ensureSession() async {
        guard appState.sessions[connection.id] == nil else { return }
        guard !connecting else { return }
        // Don't auto-retry while the prompt is already on screen waiting
        // for the user — they'd see it flash open again as soon as they
        // hit Cancel and the dict re-evaluates.
        guard credentialPrompt == nil else { return }
        let latest = currentConnection
        if let request = CredentialPromptRequest.requirements(for: latest) {
            credentialPrompt = request
            return
        }
        // Detach the connect from the view's `.task` lifecycle. Awaiting
        // `performConnect` directly here would chain into RediStack's
        // AUTH future on the same task — and the moment AppState inserts
        // the new session into `sessions`, our `.task(id:)` value flips
        // (it watches `sessions[id] == nil`), SwiftUI cancels this task,
        // and the future throws `Swift.CancellationError` before the
        // handshake can finish. A fresh Task is independent of the view
        // task and survives that flip.
        Task { await performConnect(credentials: nil) }
    }

    private func performConnect(credentials: SessionCredentials?) async {
        connecting = true
        defer { connecting = false }
        failure = nil
        do {
            _ = try await appState.session(for: currentConnection, credentials: credentials)
        } catch {
            // For ask-each-time connections, a failed connect after the
            // user typed credentials is almost always a wrong password.
            // Drop the failed session entry and re-show the prompt with
            // the error message so they can retry without closing the
            // window.
            let latest = currentConnection
            if credentials != nil,
               let retry = CredentialPromptRequest.requirements(
                   for: latest,
                   error: error.localizedDescription
               ) {
                await appState.disconnect(connection.id)
                credentialPrompt = retry
            } else {
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Credential prompt

/// Identifies which secrets the current connect needs the user to
/// provide. Built from `CredentialPromptRequest.requirements(for:)` so
/// the SessionWindow only opens the sheet when at least one credential
/// mode is `.askEachTime`.
private struct CredentialPromptRequest: Identifiable {
    let id = UUID()
    let connectionName: String
    let needsRedisPassword: Bool
    let needsSSHPassword: Bool
    let needsSSHPassphrase: Bool
    /// Optional error from the previous attempt. When non-nil the
    /// sheet shows it above the fields so the user knows why they're
    /// being asked again (typically wrong password).
    let error: String?

    static func requirements(
        for connection: Connection,
        error: String? = nil
    ) -> CredentialPromptRequest? {
        let redis = connection.passwordMode == .askEachTime
        var ssh = false
        var passphrase = false
        if let cfg = connection.sshTunnel {
            switch cfg.authMethod {
            case .password:
                ssh = cfg.passwordMode == .askEachTime
            case .privateKey:
                passphrase = cfg.passphraseMode == .askEachTime
            }
        }
        guard redis || ssh || passphrase else { return nil }
        return CredentialPromptRequest(
            connectionName: connection.name,
            needsRedisPassword: redis,
            needsSSHPassword: ssh,
            needsSSHPassphrase: passphrase,
            error: error
        )
    }
}

private struct CredentialPromptSheet: View {
    let request: CredentialPromptRequest
    let onSubmit: (SessionCredentials) -> Void
    let onCancel: () -> Void

    @State private var redisPassword: String = ""
    @State private var sshPassword: String = ""
    @State private var sshPassphrase: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Credentials for \(request.connectionName)")
                .font(.headline)
            Text("These secrets are used for this connect only and aren't saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let msg = request.error {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                if request.needsSSHPassword {
                    SecureField("SSH Password", text: $sshPassword)
                }
                if request.needsSSHPassphrase {
                    SecureField("SSH Key Passphrase", text: $sshPassphrase)
                }
                if request.needsRedisPassword {
                    SecureField("Redis Password", text: $redisPassword)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private func submit() {
        var creds = SessionCredentials()
        if request.needsRedisPassword { creds.redisPassword = redisPassword }
        if request.needsSSHPassword { creds.sshPassword = sshPassword }
        if request.needsSSHPassphrase { creds.sshPassphrase = sshPassphrase }
        onSubmit(creds)
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
            NewKeySheet(initialType: dialog.type, jsonSupported: session.jsonSupported) { name, type in
                Task { await createKey(name: name, type: type) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { session.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!session.canGoBack)
                .help("Back")
                .keyboardShortcut("[", modifiers: .command)
                Button { session.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!session.canGoForward)
                .help("Forward")
                .keyboardShortcut("]", modifiers: .command)
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach(RedisKeyType.creatable(includeJSON: session.jsonSupported), id: \.self) { t in
                        Button(t.displayName) { newKeyDialog = NewKeyDialog(type: t) }
                    }
                    Divider()
                    Button("Fill Demo Data") {
                        Task { await session.seedDemoData() }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New key")
            }
            // Search field lives at the top of the sidebar instead of
            // here — macOS NSToolbar's `.principal` slot doesn't flex,
            // and the sidebar VStack gives the field true column-width
            // flex sizing.

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
                Button {
                    openWindow(id: WindowID.pubSub, value: session.connection)
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                .help("Pub/Sub")
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
            case .json:   try await session.service.jsonSet(name, value: "{}")
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
    @Environment(\.openWindow) private var openWindow

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
                Button("Detail") {
                    openWindow(id: WindowID.connectionDetail, value: session.connection)
                    onDismiss()
                }
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
