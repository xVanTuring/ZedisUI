import Foundation

/// Persists the list of saved connections to UserDefaults.
/// Passwords live in the Keychain (see KeychainHelper); never persisted here.
final class ConnectionStore: @unchecked Sendable {
    static let shared = ConnectionStore()

    private let defaultsKey = "ZedisUI.connections.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [Connection] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Connection].self, from: data)
        } catch {
            // Corrupt data — wipe and start fresh rather than crashing on launch.
            defaults.removeObject(forKey: defaultsKey)
            return []
        }
    }

    func save(_ connections: [Connection]) {
        do {
            let data = try JSONEncoder().encode(connections)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            // Encoding a [Connection] should never fail; swallow.
        }
    }
}
