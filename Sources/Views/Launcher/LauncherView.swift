import SwiftUI
import AppKit

struct LauncherView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var quickHost: String = "localhost"
    @State private var quickPort: String = "6379"
    @State private var quickConnecting: Bool = false
    @State private var quickError: String?

    @State private var newGroupPresented: Bool = false
    @State private var groupRenameTarget: ConnectionGroup?
    @State private var collapsedGroups: Set<UUID> = []
    @State private var importSummary: StatusBanner?

    /// Inline result banner shown above the saved-connections list after
    /// an import or export. `fileURL`, when set, makes `fileName` a
    /// clickable Reveal-in-Finder target.
    private struct StatusBanner {
        var prefix: String
        var fileName: String?
        var fileURL: URL?
    }

    /// Export flow state: when non-nil the passphrase sheet is shown.
    @State private var exportPassphraseSheet: ExportRequest?
    /// Import flow state: when non-nil the file is an encrypted envelope
    /// and we need a passphrase before decrypting.
    @State private var importPassphraseSheet: ImportRequest?

    private struct ExportRequest: Identifiable {
        let id = UUID()
    }
    private struct ImportRequest: Identifiable {
        let id = UUID()
        let data: Data
        let sourceName: String
    }

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
        // `.windowStyle(.hiddenTitleBar)` only suppresses the title text;
        // the title-bar height is still reserved above the content, and
        // macOS Big Sur+ draws a hairline separator under it. Reach
        // through to the NSWindow and turn on fullSizeContentView so the
        // content extends behind the traffic lights, drop the separator,
        // and ignore the top safe-area inset so SwiftUI lays out under
        // the title bar instead of below it.
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowConfigurator { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
        })
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
        .sheet(isPresented: $newGroupPresented) {
            GroupNameSheet(title: "New Group", initialName: "") { name in
                appState.addGroup(named: name)
            }
        }
        .sheet(item: $groupRenameTarget) { group in
            GroupNameSheet(title: "Rename Group", initialName: group.name) { name in
                appState.renameGroup(group.id, to: name)
            }
        }
        .sheet(item: $exportPassphraseSheet) { _ in
            ExportOptionsSheet { includePasswords, passphrase in
                exportPassphraseSheet = nil
                if includePasswords {
                    performEncryptedExport(passphrase: passphrase)
                } else {
                    performPlainExport()
                }
            } onCancel: {
                exportPassphraseSheet = nil
            }
        }
        .sheet(item: $importPassphraseSheet) { request in
            PassphraseSheet(
                title: "Decrypt \(request.sourceName)",
                hint: "Enter the passphrase used when this file was exported.",
                primaryLabel: "Import",
                requiresConfirm: false
            ) { passphrase in
                importPassphraseSheet = nil
                performEncryptedImport(data: request.data, passphrase: passphrase, sourceName: request.sourceName)
            } onCancel: {
                importPassphraseSheet = nil
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
                    newGroupPresented = true
                } label: {
                    Label("New Group…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                HStack(spacing: 8) {
                    Button {
                        importConnections()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)

                    Button {
                        exportConnections()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(appState.connections.isEmpty)
                }
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

            if let importSummary {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    HStack(spacing: 0) {
                        Text(importSummary.prefix).font(.caption)
                        if let name = importSummary.fileName {
                            if let url = importSummary.fileURL {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } label: {
                                    Text(name)
                                        .font(.caption)
                                        .underline()
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("Show in Finder")
                            } else {
                                Text(name).font(.caption)
                            }
                        }
                    }
                    Spacer()
                    Button {
                        self.importSummary = nil
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            if appState.connections.isEmpty && appState.groups.isEmpty {
                ContentUnavailableView {
                    Label("No saved connections", systemImage: "tray")
                } description: {
                    Text("Click **New Server…** to add your first connection.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        // Pinned bucket — only shown when something is pinned.
                        let pinned = appState.connections
                            .filter { $0.isPinned }
                            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                        if !pinned.isEmpty {
                            sectionHeader(
                                title: "Pinned",
                                icon: "pin.fill",
                                count: pinned.count,
                                collapsed: false,
                                onToggle: nil,
                                trailing: nil
                            )
                            ForEach(pinned) { conn in rowFor(conn) }
                        }

                        // Each user-defined group.
                        ForEach(appState.groups) { group in
                            let members = appState.connections
                                .filter { $0.groupId == group.id && !$0.isPinned }
                                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                            let isCollapsed = collapsedGroups.contains(group.id)
                            sectionHeader(
                                title: group.name,
                                icon: "folder",
                                count: members.count,
                                collapsed: isCollapsed,
                                onToggle: {
                                    if isCollapsed {
                                        collapsedGroups.remove(group.id)
                                    } else {
                                        collapsedGroups.insert(group.id)
                                    }
                                },
                                trailing: {
                                    AnyView(
                                        Menu {
                                            Button("Rename…") { groupRenameTarget = group }
                                            Button("Delete Group", role: .destructive) {
                                                appState.removeGroup(group.id)
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .menuStyle(.borderlessButton)
                                        .menuIndicator(.hidden)
                                        .fixedSize()
                                    )
                                }
                            )
                            if !isCollapsed {
                                if members.isEmpty {
                                    Text("Empty — move a connection here from its row menu.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                } else {
                                    ForEach(members) { conn in rowFor(conn) }
                                }
                            }
                        }

                        // Ungrouped bucket — only shown when groups exist, otherwise we
                        // just render the flat list with no header.
                        let ungrouped = appState.connections
                            .filter { $0.groupId == nil && !$0.isPinned }
                            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                        if !ungrouped.isEmpty {
                            if !appState.groups.isEmpty {
                                sectionHeader(
                                    title: "Ungrouped",
                                    icon: "tray",
                                    count: ungrouped.count,
                                    collapsed: false,
                                    onToggle: nil,
                                    trailing: nil
                                )
                            }
                            ForEach(ungrouped) { conn in rowFor(conn) }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func rowFor(_ conn: Connection) -> some View {
        SavedConnectionRow(
            connection: conn,
            status: appState.sessions[conn.id]?.status,
            groups: appState.groups,
            onConnect: { connect(conn) },
            onEdit: { appState.connectionBeingEdited = conn },
            onDelete: { appState.removeConnection(conn.id) },
            // Read pin state from appState at click time, not from the
            // captured `conn`, so a stale row prop can't double-pin or
            // refuse to unpin if SwiftUI happens to reuse the row view.
            onTogglePin: {
                let current = appState.connections.first { $0.id == conn.id }?.isPinned ?? conn.isPinned
                appState.setPinned(conn.id, !current)
            },
            onMoveToGroup: { gid in appState.moveConnection(conn.id, toGroup: gid) }
        )
        // Identity includes pin/group so SwiftUI doesn't reuse the
        // row across sections with stale visuals.
        .id("\(conn.id)-\(conn.isPinned)-\(conn.groupId?.uuidString ?? "none")")
    }

    @ViewBuilder
    private func sectionHeader(
        title: String,
        icon: String,
        count: Int,
        collapsed: Bool,
        onToggle: (() -> Void)?,
        trailing: (() -> AnyView)?
    ) -> some View {
        HStack(spacing: 6) {
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                trailing()
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            showImportError(error.localizedDescription)
            return
        }
        if ExportCrypto.isEncryptedEnvelope(data) {
            // Defer decryption until after the user supplies a passphrase.
            importPassphraseSheet = ImportRequest(data: data, sourceName: url.lastPathComponent)
            return
        }
        // Plain `[Connection]` JSON — back-compat path for files exported
        // before the encrypted format existed. No secrets are restored.
        do {
            let imported = try JSONDecoder().decode([Connection].self, from: data)
            applyImportedConnections(imported, secrets: [])
        } catch {
            showImportError("The file isn't a recognized ZedisUI connections export.\n\n\(error.localizedDescription)")
        }
    }

    private func performEncryptedImport(data: Data, passphrase: String, sourceName: String) {
        do {
            let payload = try ExportCrypto.decrypt(envelope: data, passphrase: passphrase)
            applyImportedConnections(payload.connections, secrets: payload.secrets)
        } catch {
            showImportError(error.localizedDescription)
        }
    }

    /// Merges imported connections into the saved list, re-keying ids
    /// and restoring each connection's secrets to the Keychain under
    /// the new id. Dedupes by display name like the older flat-JSON
    /// path did, so re-importing the same file is safe.
    private func applyImportedConnections(
        _ imported: [Connection],
        secrets: [ExportPayload.SecretBundle]
    ) {
        let existingNames = Set(appState.connections.map { $0.name })
        let secretsById = Dictionary(uniqueKeysWithValues: secrets.map { ($0.connectionId, $0) })
        var added = 0
        var skipped = 0
        for c in imported {
            if existingNames.contains(c.name) {
                skipped += 1
                continue
            }
            var copy = c
            let oldId = copy.id
            copy.id = UUID()
            // Clear group membership so imported items land in Ungrouped
            // rather than dangling at a missing group id.
            copy.groupId = nil
            appState.addConnection(copy)

            if let bundle = secretsById[oldId] {
                if let pw = bundle.redisPassword, copy.savePassword {
                    KeychainHelper.setPassword(pw, for: copy.id)
                }
                if let pw = bundle.sshPassword,
                   let ssh = copy.sshTunnel, ssh.savePassword {
                    KeychainHelper.setSSHPassword(pw, for: copy.id)
                }
                if let pp = bundle.sshPassphrase,
                   let ssh = copy.sshTunnel, ssh.savePassphrase {
                    KeychainHelper.setSSHPassphrase(pp, for: copy.id)
                }
            }
            added += 1
        }
        let text = "Imported \(added) connection\(added == 1 ? "" : "s")"
            + (skipped > 0 ? " · skipped \(skipped) duplicate name\(skipped == 1 ? "" : "s")" : "")
        importSummary = StatusBanner(prefix: text)
    }

    private func showImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not import connections"
        alert.informativeText = message
        alert.runModal()
    }

    private func exportConnections() {
        guard !appState.connections.isEmpty else { return }
        // Ask for the passphrase first; if the user cancels we never
        // bother prompting for a destination file.
        exportPassphraseSheet = ExportRequest()
    }

    private func performPlainExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "zedisui-connections.json"
        panel.title = "Export connections"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(appState.connections)
            try data.write(to: url, options: .atomic)
            importSummary = StatusBanner(
                prefix: "Exported \(appState.connections.count) connection\(appState.connections.count == 1 ? "" : "s") to ",
                fileName: url.lastPathComponent,
                fileURL: url
            )
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export connections"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func performEncryptedExport(passphrase: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "zedisui-connections.zedis-export.json"
        panel.title = "Export encrypted connections"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Pull each connection's secrets out of the Keychain so the
            // recipient gets a fully self-contained file. We skip the
            // bundle entirely for connections that don't have any
            // savePassword/savePassphrase toggle set, to keep the export
            // small and avoid stashing empty strings.
            let secrets: [ExportPayload.SecretBundle] = appState.connections.compactMap { conn in
                var bundle = ExportPayload.SecretBundle(connectionId: conn.id)
                var anything = false
                if conn.savePassword, let pw = KeychainHelper.password(for: conn.id) {
                    bundle.redisPassword = pw
                    anything = true
                }
                if let ssh = conn.sshTunnel {
                    if ssh.savePassword, let pw = KeychainHelper.sshPassword(for: conn.id) {
                        bundle.sshPassword = pw
                        anything = true
                    }
                    if ssh.savePassphrase, let pp = KeychainHelper.sshPassphrase(for: conn.id) {
                        bundle.sshPassphrase = pp
                        anything = true
                    }
                }
                return anything ? bundle : nil
            }
            let payload = ExportPayload(connections: appState.connections, secrets: secrets)
            let data = try ExportCrypto.encrypt(payload: payload, passphrase: passphrase)
            try data.write(to: url, options: .atomic)
            importSummary = StatusBanner(
                prefix: "Exported \(appState.connections.count) connection\(appState.connections.count == 1 ? "" : "s") (encrypted) to ",
                fileName: url.lastPathComponent,
                fileURL: url
            )
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export connections"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Saved connection row

private struct SavedConnectionRow: View {
    let connection: Connection
    let status: RedisSession.Status?
    let groups: [ConnectionGroup]
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onMoveToGroup: (UUID?) -> Void

    @State private var hovered = false
    /// One-shot result of clicking the status dot. Overrides the
    /// session-status colour while non-nil; never persisted. Reset to
    /// `.idle` on connection edit (when the row's `connection.id` slot
    /// gets re-bound) — see `.onChange` below.
    @State private var probe: ProbeState = .idle

    enum ProbeState: Equatable {
        case idle
        case running
        case ok(String)     // PONG payload
        case failed(String) // user-facing reason
    }

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
            // Single pin control: always visible when pinned (so users can
            // unpin), only visible on hover when not pinned (so it doesn't
            // clutter the row). Pin orange when active, secondary otherwise.
            if connection.isPinned || hovered {
                Button(action: onTogglePin) {
                    Image(systemName: connection.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(connection.isPinned ? Color.orange : Color.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(connection.isPinned ? "Unpin" : "Pin to top")
            }
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
            Button(connection.isPinned ? "Unpin" : "Pin to Top", action: onTogglePin)
            Menu("Move to Group") {
                Button("None (Ungrouped)") { onMoveToGroup(nil) }
                    .disabled(connection.groupId == nil)
                if !groups.isEmpty { Divider() }
                ForEach(groups) { g in
                    Button(g.name) { onMoveToGroup(g.id) }
                        .disabled(connection.groupId == g.id)
                }
            }
            .disabled(groups.isEmpty && connection.groupId == nil)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var statusDot: some View {
        Button(action: runProbe) {
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                if case .running = probe {
                    // Replace the dot with a tiny spinner while probing.
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                }
            }
            // Slightly larger hit area than the visual circle.
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled({ if case .running = probe { return true } else { return false } }())
        .help(statusTooltip)
    }

    /// Color resolution order: an in-flight or completed probe wins
    /// over the longer-lived session status, so the user sees direct
    /// feedback from the click. Session status fills in when the row
    /// hasn't been probed.
    private var statusColor: Color {
        switch probe {
        case .ok:      return .green
        case .failed:  return .red
        case .running: return .yellow
        case .idle:
            switch status {
            case .connected:    return .green
            case .connecting:   return .yellow
            case .failed:       return .red
            case .disconnected, .none: return .gray.opacity(0.5)
            }
        }
    }

    private var statusTooltip: String {
        switch probe {
        case .ok(let pong):      return "OK · PING → \(pong) — click to retest"
        case .failed(let msg):   return "Failed: \(msg) — click to retest"
        case .running:           return "Testing…"
        case .idle:
            switch status {
            case .connected:    return "Connected — click to retest"
            case .connecting:   return "Connecting…"
            case .failed(let s): return "Failed: \(s) — click to retest"
            case .disconnected: return "Disconnected — click to test"
            case .none:         return "Not connected — click to test"
            }
        }
    }

    private func runProbe() {
        if case .running = probe { return }
        probe = .running
        let connection = self.connection
        Task {
            let result = await ConnectionProbe.run(connection)
            probe = result
        }
    }
}

/// One-shot "is this host alive" check used by `SavedConnectionRow`'s
/// status dot. Mirrors `ConnectionDialogView.test()` but loads secrets
/// from the Keychain instead of in-memory dialog state. Always
/// shuts the socket down before returning so we don't leak listeners.
private enum ConnectionProbe {
    static func run(_ connection: Connection) async -> SavedConnectionRow.ProbeState {
        var tunnel: SSHTunnelService?
        var serviceHost = connection.host
        var servicePort = connection.port
        do {
            if let cfg = connection.sshTunnel {
                let credential = try sshCredential(for: connection, cfg: cfg)
                let t = SSHTunnelService(
                    sshHost: cfg.host,
                    sshPort: cfg.port,
                    username: cfg.username,
                    credential: credential,
                    targetHost: connection.host,
                    targetPort: connection.port
                )
                let port = try await t.start()
                tunnel = t
                serviceHost = "127.0.0.1"
                servicePort = port
            }

            let password = connection.savePassword
                ? KeychainHelper.password(for: connection.id)
                : nil
            let svc = RedisService(
                host: serviceHost,
                port: servicePort,
                username: connection.username,
                password: password
            )
            try await svc.connect(initialDB: connection.defaultDB)
            let pong = (try? await svc.ping()) ?? "?"
            await svc.disconnect()
            if let tunnel { await tunnel.stop() }
            return .ok(pong)
        } catch {
            if let tunnel { await tunnel.stop() }
            return .failed(error.localizedDescription)
        }
    }

    private static func sshCredential(
        for connection: Connection,
        cfg: SSHTunnelConfig
    ) throws -> SSHTunnelService.AuthCredential {
        switch cfg.authMethod {
        case .password:
            let pw = cfg.savePassword ? (KeychainHelper.sshPassword(for: connection.id) ?? "") : ""
            return .password(pw)
        case .privateKey:
            let key = try readKey(cfg)
            let passphrase = cfg.savePassphrase
                ? KeychainHelper.sshPassphrase(for: connection.id)
                : nil
            return .privateKey(key: key, passphrase: passphrase)
        }
    }

    private static func readKey(_ cfg: SSHTunnelConfig) throws -> String {
        if let bookmark = cfg.privateKeyBookmark {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return try String(contentsOf: url, encoding: .utf8)
        }
        if let path = cfg.privateKeyPath {
            return try String(
                contentsOfFile: (path as NSString).expandingTildeInPath,
                encoding: .utf8
            )
        }
        throw NSError(
            domain: "ZedisUI.SSH",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No private key file selected."]
        )
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

/// Reaches the host NSWindow and runs `configure` once attached. Used to
/// flip flags SwiftUI doesn't expose (e.g. `.fullSizeContentView`) — there
/// is no SwiftUI-native modifier for those as of macOS 15.
private struct GroupNameSheet: View {
    let title: String
    let initialName: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSave = onSave
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

/// Export options: lets the user opt into including saved passwords
/// (Redis + SSH). When that toggle is on we encrypt the file with a
/// user-chosen passphrase; when it's off we write plain JSON without
/// secrets, no passphrase needed.
private struct ExportOptionsSheet: View {
    let onSubmit: (_ includePasswords: Bool, _ passphrase: String) -> Void
    let onCancel: () -> Void

    @State private var includePasswords: Bool = false
    @State private var passphrase: String = ""
    @State private var confirm: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Connections").font(.headline)
            Toggle("Include saved passwords", isOn: $includePasswords)
            Text(includePasswords
                 ? "Stored Redis and SSH passwords will be included. The file is encrypted with the passphrase below — keep it safe; without it the file can't be imported."
                 : "Only connection metadata (host, port, username, etc.) will be exported. The file is plain JSON.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if includePasswords {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm passphrase", text: $confirm)
                    .textFieldStyle(.roundedBorder)
                if !confirm.isEmpty && confirm != passphrase {
                    Label("Passphrases don't match", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(includePasswords ? "Export…" : "Export…", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var canSubmit: Bool {
        if !includePasswords { return true }
        return !passphrase.isEmpty && passphrase == confirm
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(includePasswords, passphrase)
    }
}

/// Generic two-field passphrase sheet shared by the encrypted export
/// and the encrypted import flows. `requiresConfirm` enables the second
/// field with an inline "do not match" warning.
private struct PassphraseSheet: View {
    let title: String
    let hint: String
    let primaryLabel: String
    let requiresConfirm: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase: String = ""
    @State private var confirm: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if requiresConfirm {
                SecureField("Confirm passphrase", text: $confirm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if !confirm.isEmpty && confirm != passphrase {
                    Label("Passphrases don't match", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(primaryLabel, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var canSubmit: Bool {
        guard !passphrase.isEmpty else { return false }
        if requiresConfirm && confirm != passphrase { return false }
        return true
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(passphrase)
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
