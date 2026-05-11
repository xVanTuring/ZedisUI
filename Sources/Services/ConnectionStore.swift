import Foundation

/// Persists the list of saved connections (and the user's groups) to
/// UserDefaults. Passwords live in the Keychain (see KeychainHelper);
/// never persisted here.
final class ConnectionStore: @unchecked Sendable {
    static let shared = ConnectionStore()

    private let connectionsKey = "ZedisUI.connections.v1"
    private let groupsKey = "ZedisUI.connectionGroups.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [Connection] {
        guard let data = defaults.data(forKey: connectionsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Connection].self, from: data)
        } catch {
            // Corrupt data — wipe and start fresh rather than crashing on launch.
            defaults.removeObject(forKey: connectionsKey)
            return []
        }
    }

    func save(_ connections: [Connection]) {
        do {
            let data = try JSONEncoder().encode(connections)
            defaults.set(data, forKey: connectionsKey)
        } catch {
            // Encoding a [Connection] should never fail; swallow.
        }
    }

    func loadGroups() -> [ConnectionGroup] {
        guard let data = defaults.data(forKey: groupsKey) else { return [] }
        do {
            return try JSONDecoder().decode([ConnectionGroup].self, from: data)
        } catch {
            defaults.removeObject(forKey: groupsKey)
            return []
        }
    }

    func saveGroups(_ groups: [ConnectionGroup]) {
        do {
            let data = try JSONEncoder().encode(groups)
            defaults.set(data, forKey: groupsKey)
        } catch {
            // ignore
        }
    }
}
