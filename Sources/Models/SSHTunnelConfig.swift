import Foundation

/// Configuration for an SSH tunnel sitting in front of a Redis connection.
/// When attached to a `Connection`, the app first opens an SSH session to
/// `host:port` as `username`, then forwards a local 127.0.0.1 port through
/// it to the connection's real Redis host:port.
///
/// Secrets are never persisted in this struct:
///   - SSH password → Keychain (`<id>:ssh-password`)
///   - SSH key passphrase → Keychain (`<id>:ssh-passphrase`)
/// The private key file path is persisted, plus a security-scoped bookmark
/// so we can re-read the file from a sandboxed launch.
struct SSHTunnelConfig: Codable, Hashable {
    enum AuthMethod: String, Codable, Hashable {
        case password
        case privateKey
    }

    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod

    /// Display path for the chosen private key (e.g. `~/.ssh/id_ed25519`).
    /// Only meaningful when `authMethod == .privateKey`.
    var privateKeyPath: String?

    /// Security-scoped bookmark so the sandboxed app can read the key file
    /// across launches. Re-issued whenever the user re-picks the file.
    var privateKeyBookmark: Data?

    /// How the SSH password is sourced (when `authMethod == .password`).
    /// `keychain` persists, `askEachTime` prompts on each connect.
    var passwordMode: CredentialMode
    /// How the SSH key passphrase is sourced (when
    /// `authMethod == .privateKey` and the key is encrypted). `nil`
    /// means the key has no passphrase.
    var passphraseMode: CredentialMode?

    init(
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        privateKeyPath: String? = nil,
        privateKeyBookmark: Data? = nil,
        passwordMode: CredentialMode = .keychain,
        passphraseMode: CredentialMode? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.privateKeyBookmark = privateKeyBookmark
        self.passwordMode = passwordMode
        self.passphraseMode = passphraseMode
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, username, authMethod
        case privateKeyPath, privateKeyBookmark
        case passwordMode, passphraseMode
        // Legacy keys (pre-0.3).
        case savePassword, savePassphrase
    }

    /// Decoding tolerates the legacy `savePassword` / `savePassphrase`
    /// booleans: `true` → `.keychain`, `false` → `nil` for passphrase
    /// (no passphrase) and `.keychain` for SSH password (since a stored
    /// `false` previously meant "don't read from Keychain"; either way
    /// no secret is loaded, and Keychain with no entry is the natural
    /// default).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.username = try c.decode(String.self, forKey: .username)
        self.authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
        self.privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath)
        self.privateKeyBookmark = try c.decodeIfPresent(Data.self, forKey: .privateKeyBookmark)

        if let mode = try c.decodeIfPresent(CredentialMode.self, forKey: .passwordMode) {
            self.passwordMode = mode
        } else {
            // Legacy: either savePassword was true (use keychain) or
            // false/missing (still keychain by default, but with no
            // stored entry — same behavior as before).
            _ = try c.decodeIfPresent(Bool.self, forKey: .savePassword)
            self.passwordMode = .keychain
        }

        if let mode = try c.decodeIfPresent(CredentialMode.self, forKey: .passphraseMode) {
            self.passphraseMode = mode
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .savePassphrase) {
            self.passphraseMode = legacy ? .keychain : nil
        } else {
            self.passphraseMode = nil
        }
    }

    /// Custom encoder so we only write the new mode keys, never the
    /// legacy booleans.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(authMethod, forKey: .authMethod)
        try c.encodeIfPresent(privateKeyPath, forKey: .privateKeyPath)
        try c.encodeIfPresent(privateKeyBookmark, forKey: .privateKeyBookmark)
        try c.encode(passwordMode, forKey: .passwordMode)
        try c.encodeIfPresent(passphraseMode, forKey: .passphraseMode)
    }
}
