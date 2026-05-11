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

    /// Pinned connections sort to the top of their group in the launcher.
    var isPinned: Bool

    /// Optional group membership. `nil` means the connection lives in
    /// the implicit "Ungrouped" bucket.
    var groupId: UUID?

    init(
        id: UUID = UUID(),
        name: String = "New Connection",
        host: String = "127.0.0.1",
        port: Int = 6379,
        username: String? = nil,
        savePassword: Bool = false,
        defaultDB: Int = 0,
        defaultPattern: String = "*",
        sshTunnel: SSHTunnelConfig? = nil,
        isPinned: Bool = false,
        groupId: UUID? = nil
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
        self.isPinned = isPinned
        self.groupId = groupId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, savePassword, defaultDB
        case defaultPattern, sshTunnel, isPinned, groupId
    }

    /// Decoding tolerates older payloads that predate `isPinned` /
    /// `groupId`. New users get sensible defaults; existing stored
    /// connections decode untouched.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.savePassword = try c.decode(Bool.self, forKey: .savePassword)
        self.defaultDB = try c.decode(Int.self, forKey: .defaultDB)
        self.defaultPattern = try c.decode(String.self, forKey: .defaultPattern)
        self.sshTunnel = try c.decodeIfPresent(SSHTunnelConfig.self, forKey: .sshTunnel)
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
    }
}

/// A user-defined folder of connections in the launcher. Order of
/// `AppState.groups` is the display order; rename happens in-place.
struct ConnectionGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
