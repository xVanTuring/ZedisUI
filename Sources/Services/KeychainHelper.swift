import Foundation
import Security

/// Stores connection secrets in the macOS file-based keychain. Entries are
/// keyed by `<connection-uuid>[:suffix]` so each connection can hold
/// multiple credentials (Redis password, SSH password, SSH key passphrase)
/// without colliding.
///
/// Ad-hoc signing complication: the default keychain ACL ties items to the
/// creating binary's code signature, so every rebuild produces a "ZedisUI
/// wants to access keychain" prompt. We work around this by attaching a
/// `SecAccess` created with a nil trusted-list, which marks the item as
/// "any app trusted" — locking it remains tied to the user's login, but
/// no per-app prompt. For an end-user release with a stable signing
/// identity this isn't necessary, but it keeps dev builds usable.
///
/// Data-protection (iOS-style) keychain isn't viable here because an
/// ad-hoc signed app has no team-prefixed access group, and SecItemAdd
/// silently fails.
enum KeychainHelper {
    private static let service = "tech.xvanturing.ZedisUI"

    // MARK: - Account naming

    private static func account(for id: UUID, suffix: String? = nil) -> String {
        if let suffix, !suffix.isEmpty {
            return "\(id.uuidString):\(suffix)"
        }
        return id.uuidString
    }

    // MARK: - Generic ops

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Builds a SecAccess that trusts any application. Without this, the
    /// keychain ACL pins items to the binary's code signature and prompts
    /// the user when an ad-hoc rebuilt binary tries to read them.
    private static func makeAnyAppAccess() -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate("ZedisUI Credential" as CFString, nil, &access)
        guard status == errSecSuccess else { return nil }
        return access
    }

    private static func set(_ value: String, account: String) {
        let data = Data(value.utf8)

        SecItemDelete(baseQuery(account: account) as CFDictionary)

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let access = makeAnyAppAccess() {
            addQuery[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("KeychainHelper: SecItemAdd failed (account=\(account), status=\(status))")
        }
    }

    private static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    // MARK: - Redis password (legacy account: bare UUID)

    static func setPassword(_ password: String, for connectionID: UUID) {
        set(password, account: account(for: connectionID))
    }

    static func password(for connectionID: UUID) -> String? {
        get(account: account(for: connectionID))
    }

    static func deletePassword(for connectionID: UUID) {
        delete(account: account(for: connectionID))
    }

    // MARK: - SSH password

    static func setSSHPassword(_ password: String, for connectionID: UUID) {
        set(password, account: account(for: connectionID, suffix: "ssh-password"))
    }

    static func sshPassword(for connectionID: UUID) -> String? {
        get(account: account(for: connectionID, suffix: "ssh-password"))
    }

    static func deleteSSHPassword(for connectionID: UUID) {
        delete(account: account(for: connectionID, suffix: "ssh-password"))
    }

    // MARK: - SSH key passphrase

    static func setSSHPassphrase(_ passphrase: String, for connectionID: UUID) {
        set(passphrase, account: account(for: connectionID, suffix: "ssh-passphrase"))
    }

    static func sshPassphrase(for connectionID: UUID) -> String? {
        get(account: account(for: connectionID, suffix: "ssh-passphrase"))
    }

    static func deleteSSHPassphrase(for connectionID: UUID) {
        delete(account: account(for: connectionID, suffix: "ssh-passphrase"))
    }
}
