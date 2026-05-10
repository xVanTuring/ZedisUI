import SwiftUI
import Observation

/// Top-level UI state for the app: which connection is selected, sheets, etc.
@Observable
@MainActor
final class AppState {
    /// All saved connections (persisted via ConnectionStore).
    var connections: [Connection] = []

    /// Currently active sessions, keyed by connection id. A session holds the
    /// live RedisService and the user's current DB / key selection.
    var sessions: [Connection.ID: RedisSession] = [:]

    /// Sheet flags (driven from the Launcher window)
    var showNewConnectionSheet: Bool = false
    var connectionBeingEdited: Connection?

    init() {
        self.connections = ConnectionStore.shared.load()
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
