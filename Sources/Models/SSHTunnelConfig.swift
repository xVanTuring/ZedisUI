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

    /// Persist the SSH password to Keychain. Ignored for key auth.
    var savePassword: Bool
    /// Persist the key passphrase to Keychain. Ignored for password auth.
    var savePassphrase: Bool

    init(
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        privateKeyPath: String? = nil,
        privateKeyBookmark: Data? = nil,
        savePassword: Bool = false,
        savePassphrase: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.privateKeyBookmark = privateKeyBookmark
        self.savePassword = savePassword
        self.savePassphrase = savePassphrase
    }
}
