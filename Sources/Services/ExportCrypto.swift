import Foundation
import CommonCrypto
import CryptoKit

/// Envelope written to disk by an encrypted connections export. The
/// inner ciphertext is a JSON-encoded `ExportPayload`.
///
/// Format: AES-256-GCM, key derived from the user passphrase via
/// PBKDF2-SHA256. Salt + nonce are random per export so the same
/// passphrase produces different ciphertexts. The 16-byte GCM tag is
/// embedded in `ciphertext` (see `SealedBox.combined`), so we don't
/// store it separately.
struct EncryptedExport: Codable {
    static let currentFormat = "zedisui-encrypted-v1"
    static let defaultIterations = 200_000

    /// Magic identifier so we can distinguish encrypted exports from
    /// plain `[Connection]` arrays at import time.
    var format: String
    var kdf: String          // "pbkdf2-sha256"
    var iterations: Int
    /// Base64-encoded random salt (16 bytes) fed to PBKDF2.
    var salt: String
    /// Base64-encoded 12-byte AES-GCM nonce.
    var nonce: String
    /// Base64-encoded ciphertext || 16-byte tag (AES-GCM combined output).
    var ciphertext: String
}

/// The plaintext payload an encrypted export contains. The secret
/// bundles are indexed by the (original) connection id so we can
/// re-key them onto fresh UUIDs at import time.
struct ExportPayload: Codable {
    var connections: [Connection]
    var secrets: [SecretBundle]

    struct SecretBundle: Codable {
        var connectionId: UUID
        var redisPassword: String?
        var sshPassword: String?
        var sshPassphrase: String?
    }
}

enum ExportCryptoError: LocalizedError {
    case pbkdf2Failed
    case wrongPassphrase
    case unsupportedFormat(String)
    case malformedEnvelope

    var errorDescription: String? {
        switch self {
        case .pbkdf2Failed:
            return "Failed to derive an encryption key from the passphrase."
        case .wrongPassphrase:
            return "Wrong passphrase, or the file is corrupted."
        case .unsupportedFormat(let f):
            return "Unsupported export format: \(f)."
        case .malformedEnvelope:
            return "The export envelope is malformed."
        }
    }
}

enum ExportCrypto {
    /// Encrypts `payload` under `passphrase` and returns the envelope as JSON Data.
    static func encrypt(payload: ExportPayload, passphrase: String) throws -> Data {
        let salt = randomBytes(16)
        let nonceBytes = randomBytes(12)
        let key = try deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: EncryptedExport.defaultIterations
        )
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: AES.GCM.Nonce(data: nonceBytes)
        )
        // SealedBox.combined = nonce || ciphertext || tag. We already
        // store the nonce separately, so use ciphertext + tag here.
        let ctAndTag = sealed.ciphertext + sealed.tag
        let envelope = EncryptedExport(
            format: EncryptedExport.currentFormat,
            kdf: "pbkdf2-sha256",
            iterations: EncryptedExport.defaultIterations,
            salt: salt.base64EncodedString(),
            nonce: nonceBytes.base64EncodedString(),
            ciphertext: ctAndTag.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Decrypts an envelope produced by `encrypt(payload:passphrase:)`.
    /// Throws `wrongPassphrase` on tag-mismatch (the typical failure
    /// mode for a bad password) and `unsupportedFormat` on a future
    /// format version we don't know how to read.
    static func decrypt(envelope data: Data, passphrase: String) throws -> ExportPayload {
        let envelope: EncryptedExport
        do {
            envelope = try JSONDecoder().decode(EncryptedExport.self, from: data)
        } catch {
            throw ExportCryptoError.malformedEnvelope
        }
        guard envelope.format == EncryptedExport.currentFormat else {
            throw ExportCryptoError.unsupportedFormat(envelope.format)
        }
        guard envelope.kdf == "pbkdf2-sha256" else {
            throw ExportCryptoError.unsupportedFormat(envelope.kdf)
        }
        guard let salt = Data(base64Encoded: envelope.salt),
              let nonceBytes = Data(base64Encoded: envelope.nonce),
              let ctAndTag = Data(base64Encoded: envelope.ciphertext),
              ctAndTag.count > 16 else {
            throw ExportCryptoError.malformedEnvelope
        }
        let key = try deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: envelope.iterations
        )
        let tag = ctAndTag.suffix(16)
        let ciphertext = ctAndTag.prefix(ctAndTag.count - 16)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            // AES-GCM authenticates the ciphertext; the only way `open`
            // throws is bad key (== wrong passphrase) or corrupted bytes.
            throw ExportCryptoError.wrongPassphrase
        }
        return try JSONDecoder().decode(ExportPayload.self, from: plaintext)
    }

    /// `true` when the bytes parse as a `zedisui-encrypted-v1` envelope.
    /// Used by Import to pick the encrypted code path without forcing the
    /// user to confirm a format up front.
    static func isEncryptedEnvelope(_ data: Data) -> Bool {
        guard let env = try? JSONDecoder().decode(EncryptedExport.self, from: data) else {
            return false
        }
        return env.format == EncryptedExport.currentFormat
    }

    // MARK: - PBKDF2

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        let keyLength = 32 // AES-256
        var derived = Data(count: keyLength)
        let pwBytes = Array(passphrase.utf8)
        let status = derived.withUnsafeMutableBytes { keyBuf -> Int32 in
            salt.withUnsafeBytes { saltBuf -> Int32 in
                pwBytes.withUnsafeBufferPointer { pwBuf -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.baseAddress, pwBytes.count,
                        saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBuf.bindMemory(to: UInt8.self).baseAddress, keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw ExportCryptoError.pbkdf2Failed
        }
        return SymmetricKey(data: derived)
    }

    // MARK: - RNG

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, count, buf.baseAddress!)
        }
        return bytes
    }
}
