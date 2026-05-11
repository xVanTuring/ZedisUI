import Foundation

/// A user-saved Redis connection profile.
struct Connection: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String?
    /// Password is NOT persisted in this struct; we keep it in the Keychain
    /// keyed by `id`. The store loads it on demand when establishing a session.
    var savePassword: Bool
    var defaultDB: Int
    /// Optional MATCH pattern to use when scanning keys.
    var defaultPattern: String

    /// When non-nil, the Redis connection is tunneled through this SSH
    /// session instead of dialed directly. See `SSHTunnelConfig`.
    var sshTunnel: SSHTunnelConfig?

    init(
        id: UUID = UUID(),
        name: String = "New Connection",
        host: String = "127.0.0.1",
        port: Int = 6379,
        username: String? = nil,
        savePassword: Bool = false,
        defaultDB: Int = 0,
        defaultPattern: String = "*",
        sshTunnel: SSHTunnelConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.savePassword = savePassword
        self.defaultDB = defaultDB
        self.defaultPattern = defaultPattern
        self.sshTunnel = sshTunnel
    }
}
