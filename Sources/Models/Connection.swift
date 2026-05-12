import Foundation

/// How a connection's secret (Redis password, SSH password, SSH key
/// passphrase) is supplied at connect time.
enum CredentialMode: String, Codable, Hashable {
    /// Stored in the macOS Keychain and loaded automatically.
    case keychain
    /// Never persisted; the user is prompted on each connect.
    case askEachTime
}

/// A user-saved Redis connection profile.
struct Connection: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String?
    /// How the Redis AUTH password is sourced. `nil` means no password
    /// configured at all (server doesn't require AUTH). The password
    /// itself is never stored in this struct — see Keychain / prompt
    /// flow at connect time.
    var passwordMode: CredentialMode?
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
        passwordMode: CredentialMode? = nil,
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
        self.passwordMode = passwordMode
        self.defaultDB = defaultDB
        self.defaultPattern = defaultPattern
        self.sshTunnel = sshTunnel
        self.isPinned = isPinned
        self.groupId = groupId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, passwordMode, defaultDB
        case defaultPattern, sshTunnel, isPinned, groupId
        // Legacy keys (pre-0.3): the old Bool form of password storage.
        case savePassword
    }

    /// Decoding tolerates older payloads:
    ///   - missing `isPinned` / `groupId` (pre-grouping)
    ///   - the old `savePassword: Bool` (pre-CredentialMode). `true`
    ///     becomes `.keychain`, `false` becomes `nil` (no password).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        if let mode = try c.decodeIfPresent(CredentialMode.self, forKey: .passwordMode) {
            self.passwordMode = mode
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .savePassword) {
            self.passwordMode = legacy ? .keychain : nil
        } else {
            self.passwordMode = nil
        }
        self.defaultDB = try c.decode(Int.self, forKey: .defaultDB)
        self.defaultPattern = try c.decode(String.self, forKey: .defaultPattern)
        self.sshTunnel = try c.decodeIfPresent(SSHTunnelConfig.self, forKey: .sshTunnel)
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
    }

    /// Custom encoder so we only emit the new `passwordMode` key and
    /// never the legacy `savePassword`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(passwordMode, forKey: .passwordMode)
        try c.encode(defaultDB, forKey: .defaultDB)
        try c.encode(defaultPattern, forKey: .defaultPattern)
        try c.encodeIfPresent(sshTunnel, forKey: .sshTunnel)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encodeIfPresent(groupId, forKey: .groupId)
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
