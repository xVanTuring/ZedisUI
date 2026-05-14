import SwiftUI
import Observation

/// Top-level UI state for the app: which connection is selected, sheets, etc.
@Observable
@MainActor
final class AppState {
    /// All saved connections (persisted via ConnectionStore).
    var connections: [Connection] = []

    /// User-defined groups for organizing connections in the launcher.
    var groups: [ConnectionGroup] = []

    /// Currently active sessions, keyed by connection id. A session holds the
    /// live RedisService and the user's current DB / key selection.
    var sessions: [Connection.ID: RedisSession] = [:]

    /// One Pub/Sub controller per connection, created lazily when the
    /// Pub/Sub window is opened. Persists across window open/close so the
    /// subscription survives if the user toggles the window — it's torn
    /// down explicitly only on session disconnect / connection removal.
    var pubSubControllers: [Connection.ID: PubSubController] = [:]

    /// Sheet flags (driven from the Launcher window)
    var showNewConnectionSheet: Bool = false
    var connectionBeingEdited: Connection?

    /// Shared GitHub-releases auto-updater. Lives on AppState so the
    /// "Check for Updates…" menu item and the Updater window read the
    /// same phase.
    let updater = UpdaterService()

    init() {
        self.connections = ConnectionStore.shared.load()
        self.groups = ConnectionStore.shared.loadGroups()
    }

    // MARK: - Connection CRUD

    func addConnection(_ connection: Connection) {
        connections.append(connection)
        ConnectionStore.shared.save(connections)
    }

    func updateConnection(_ connection: Connection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx] = connection
        ConnectionStore.shared.save(connections)

        // Edits to a live connection should take effect right away — old
        // host/port/auth/SSH settings on the in-memory session would
        // otherwise stick around until the window is closed and reopened.
        // Tear the session down here; SessionWindow observes
        // `sessions[id]` and re-runs its connect flow (prompting for
        // credentials again if the new config requires it).
        if let existing = sessions[connection.id] {
            Task { await existing.disconnect() }
            sessions.removeValue(forKey: connection.id)
        }
        if let controller = pubSubControllers.removeValue(forKey: connection.id) {
            controller.stop()
        }
    }

    /// Creates a copy of an existing connection with a fresh UUID and a
    /// disambiguated name (e.g. "Prod" → "Prod Copy" / "Prod Copy 2").
    /// Any Keychain-backed secrets (Redis password, SSH password, SSH
    /// passphrase) are duplicated under the new id so the copy works
    /// without re-entering credentials. The clone keeps the source's
    /// group membership but is never pinned.
    @discardableResult
    func duplicateConnection(_ id: Connection.ID) -> Connection? {
        guard let source = connections.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName(basedOn: source.name)
        copy.isPinned = false

        // Mirror any persisted secrets onto the new id.
        if source.passwordMode == .keychain,
           let pw = KeychainHelper.password(for: source.id) {
            KeychainHelper.setPassword(pw, for: copy.id)
        }
        if let ssh = source.sshTunnel {
            if ssh.passwordMode == .keychain,
               let pw = KeychainHelper.sshPassword(for: source.id) {
                KeychainHelper.setSSHPassword(pw, for: copy.id)
            }
            if ssh.passphraseMode == .keychain,
               let pp = KeychainHelper.sshPassphrase(for: source.id) {
                KeychainHelper.setSSHPassphrase(pp, for: copy.id)
            }
        }

        connections.append(copy)
        ConnectionStore.shared.save(connections)
        return copy
    }

    /// Returns a name like "Foo Copy" / "Foo Copy 2" that doesn't
    /// collide with any existing connection in the list.
    private func uniqueName(basedOn base: String) -> String {
        let existing = Set(connections.map(\.name))
        let candidate = "\(base) Copy"
        if !existing.contains(candidate) { return candidate }
        var n = 2
        while existing.contains("\(candidate) \(n)") { n += 1 }
        return "\(candidate) \(n)"
    }

    func removeConnection(_ id: Connection.ID) {
        // Tear down any live session first.
        if let session = sessions[id] {
            Task { await session.disconnect() }
            sessions.removeValue(forKey: id)
        }
        if let controller = pubSubControllers.removeValue(forKey: id) {
            controller.stop()
        }
        connections.removeAll { $0.id == id }
        ConnectionStore.shared.save(connections)
    }

    func setPinned(_ id: Connection.ID, _ pinned: Bool) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        // Reassign the whole array so @Observable definitely fires —
        // nested mutation (connections[idx].isPinned = pinned) doesn't
        // always propagate through Swift's _modify chain to SwiftUI.
        var updated = connections
        updated[idx].isPinned = pinned
        connections = updated
        ConnectionStore.shared.save(connections)
    }

    func moveConnection(_ id: Connection.ID, toGroup groupId: UUID?) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        var updated = connections
        updated[idx].groupId = groupId
        connections = updated
        ConnectionStore.shared.save(connections)
    }

    // MARK: - Group CRUD

    @discardableResult
    func addGroup(named name: String) -> ConnectionGroup {
        let group = ConnectionGroup(name: name)
        groups.append(group)
        ConnectionStore.shared.saveGroups(groups)
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = name
        ConnectionStore.shared.saveGroups(groups)
    }

    /// Removes the group; any connections inside it move back to Ungrouped.
    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for idx in connections.indices where connections[idx].groupId == id {
            connections[idx].groupId = nil
        }
        ConnectionStore.shared.saveGroups(groups)
        ConnectionStore.shared.save(connections)
    }

    // MARK: - Session lifecycle

    /// Returns the existing session for a connection, or creates and
    /// connects one on demand. `credentials`, when provided, supplies
    /// secrets for any modes marked `.askEachTime` — typically gathered
    /// by the SessionWindow's credential prompt.
    @discardableResult
    func session(
        for connection: Connection,
        credentials: SessionCredentials? = nil
    ) async throws -> RedisSession {
        if let existing = sessions[connection.id] { return existing }
        let session = RedisSession(connection: connection, credentials: credentials)
        sessions[connection.id] = session
        try await session.connect()
        return session
    }

    func disconnect(_ id: Connection.ID) async {
        guard let session = sessions[id] else { return }
        await session.disconnect()
        sessions.removeValue(forKey: id)
        if let controller = pubSubControllers.removeValue(forKey: id) {
            controller.stop()
        }
    }

    /// Returns the Pub/Sub controller for this session, creating one on
    /// first use. Returns nil if no live session exists — Pub/Sub piggybacks
    /// on the same connection profile and the controller needs an active
    /// session to learn the (possibly tunneled) endpoint.
    func pubSubController(for id: Connection.ID) -> PubSubController? {
        if let existing = pubSubControllers[id] { return existing }
        guard let session = sessions[id] else { return nil }
        let controller = PubSubController(session: session)
        pubSubControllers[id] = controller
        return controller
    }
}
