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
    }

    func removeConnection(_ id: Connection.ID) {
        // Tear down any live session first.
        if let session = sessions[id] {
            Task { await session.disconnect() }
            sessions.removeValue(forKey: id)
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

    /// Returns the existing session for a connection, or creates and connects one on demand.
    @discardableResult
    func session(for connection: Connection) async throws -> RedisSession {
        if let existing = sessions[connection.id] { return existing }
        let session = RedisSession(connection: connection)
        sessions[connection.id] = session
        try await session.connect()
        return session
    }

    func disconnect(_ id: Connection.ID) async {
        guard let session = sessions[id] else { return }
        await session.disconnect()
        sessions.removeValue(forKey: id)
    }
}
