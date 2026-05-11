import Foundation
import SwiftUI
import Observation

/// One active connection's UI-facing state. A `Connection` is the on-disk
/// profile; a `RedisSession` is the live session you get after connecting.
///
/// This type owns:
///   - the underlying RedisService (the actor that talks to Redis)
///   - which DB index is currently selected
///   - the loaded key list for the selected DB
///   - which key is selected in the middle column
///
/// It does NOT own the detail editor's working copy — that lives in the editor's view.
@Observable
@MainActor
final class RedisSession {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    let connection: Connection
    let service: RedisService
    let history: CommandHistory
    let tunnel: SSHTunnelService?

    var status: Status = .disconnected
    var availableDBs: Int = 16
    var currentDB: Int = 0
    var dbSize: Int = 0
    var serverVersion: String?

    var keys: [RedisKey] = []
    var scanCursor: Int = 0
    var scanFinished: Bool = false
    /// Monotonically increasing identifier for the current key listing.
    /// Bumped each time `reloadKeys()` resets the page; the sidebar uses
    /// this as a SwiftUI `.id()` so the underlying List view gets rebuilt
    /// from scratch on each reload — that keeps stale rows (e.g. the row
    /// for the previously selected key) from lingering after a search
    /// that returns a different result set.
    var reloadEpoch: Int = 0
    /// The text shown in the search field. Empty means "match everything";
    /// SCAN gets `*` in that case (see `loadMoreKeys`). The field is bound
    /// directly to `.searchable`, so we keep it free of the literal "*".
    var pattern: String = ""
    var typeFilter: RedisKeyType? = nil

    var selectedKey: String?

    /// Currently focused row in the active hash / zset editor, surfaced in
    /// the right inspector panel. Cleared when the selected key changes.
    var inspectorTarget: InspectorTarget?

    /// Bumped by the inspector after a write so editors can detect the
    /// change and reload their tables — they don't have a direct hook back
    /// from the inspector otherwise.
    var dataVersion: Int = 0

    /// When true, the detail pane shows the Command Query terminal instead
    /// of the selected key's editor. Mutually exclusive with `selectedKey`.
    var commandQueryActive: Bool = false

    init(connection: Connection) {
        self.connection = connection
        let password = connection.savePassword ? KeychainHelper.password(for: connection.id) : nil
        let history = CommandHistory()
        self.history = history
        self.service = RedisService(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password,
            commandLogger: { command, args, at in
                // RedisService is an actor running on a background loop;
                // hop to the MainActor before mutating the @Observable.
                Task { @MainActor in
                    history.append(.init(timestamp: at, command: command, args: args))
                }
            }
        )
        self.tunnel = Self.makeTunnel(for: connection)
        self.currentDB = connection.defaultDB
        // The connection's saved default of "*" is presented as an empty
        // search field; any other custom pattern is shown verbatim.
        self.pattern = (connection.defaultPattern == "*") ? "" : connection.defaultPattern
    }

    func connect() async throws {
        status = .connecting
        do {
            if let tunnel {
                let localPort = try await tunnel.start()
                await service.setEndpoint(host: "127.0.0.1", port: localPort)
            }
            try await service.connect(initialDB: connection.defaultDB)
            availableDBs = (try? await service.dbCount()) ?? 16
            currentDB = await service.currentDB
            status = .connected
            serverVersion = try? await service.serverVersion()
            await refreshDBSize()
            await reloadKeys()
        } catch {
            // If the SSH tunnel came up but Redis failed, tear it down so we
            // don't leak the listener/SSH session.
            if let tunnel { await tunnel.stop() }
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() async {
        await service.disconnect()
        if let tunnel { await tunnel.stop() }
        status = .disconnected
        keys = []
        scanCursor = 0
        scanFinished = false
        selectedKey = nil
    }

    // MARK: - SSH tunnel construction

    /// Builds an `SSHTunnelService` from the connection's stored config and
    /// Keychain-resident secrets. Returns nil if SSH is not configured, or
    /// if required saved secrets are missing (the connect will then surface
    /// a clear error). Never throws — credential errors surface at start().
    private static func makeTunnel(for connection: Connection) -> SSHTunnelService? {
        guard let cfg = connection.sshTunnel else { return nil }
        let credential: SSHTunnelService.AuthCredential
        switch cfg.authMethod {
        case .password:
            let pw = cfg.savePassword ? (KeychainHelper.sshPassword(for: connection.id) ?? "") : ""
            credential = .password(pw)
        case .privateKey:
            let keyContents = (try? Self.readPrivateKey(cfg)) ?? ""
            let passphrase: String? = cfg.savePassphrase
                ? KeychainHelper.sshPassphrase(for: connection.id)
                : nil
            credential = .privateKey(key: keyContents, passphrase: passphrase)
        }
        return SSHTunnelService(
            sshHost: cfg.host,
            sshPort: cfg.port,
            username: cfg.username,
            credential: credential,
            targetHost: connection.host,
            targetPort: connection.port
        )
    }

    /// Reads the SSH private key file referenced by `config`. Prefers the
    /// security-scoped bookmark (sandbox-safe across launches); falls back
    /// to the raw path for the same-session case (where the URL granted by
    /// `.fileImporter` still works directly).
    private static func readPrivateKey(_ config: SSHTunnelConfig) throws -> String {
        if let bookmark = config.privateKeyBookmark {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return try String(contentsOf: url, encoding: .utf8)
        }
        if let path = config.privateKeyPath {
            return try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        }
        throw NSError(
            domain: "ZedisUI.SSH",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No private key file selected."]
        )
    }

    // MARK: - DB switching

    func switchDB(to db: Int) async {
        guard db != currentDB else { return }
        do {
            try await service.select(db: db)
            currentDB = db
            keys = []
            scanCursor = 0
            scanFinished = false
            selectedKey = nil
            await refreshDBSize()
            await reloadKeys()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func refreshDBSize() async {
        if let n = try? await service.dbSize() { dbSize = n }
    }

    // MARK: - Key list

    /// Resets the scan cursor and loads the first page of keys.
    func reloadKeys() async {
        keys = []
        scanCursor = 0
        scanFinished = false
        reloadEpoch &+= 1
        await loadMoreKeys()
    }

    /// Wipe any existing `demo:*` keys, then seed a representative
    /// sample across every supported type — including a Stream entry —
    /// so the UI has data to exercise. Idempotent.
    func seedDemoData() async {
        // Wipe demo:* first so re-running doesn't accumulate.
        var cursor = 0
        var existing: [String] = []
        repeat {
            let page = (try? await service.scan(
                cursor: cursor, pattern: "demo:*", count: 500
            )) ?? (next: 0, keys: [])
            existing.append(contentsOf: page.keys)
            cursor = page.next
        } while cursor != 0
        if !existing.isEmpty {
            _ = try? await service.delete(existing)
        }

        // String — a plain value, a numeric counter, a JSON blob, and one
        // with a TTL so the meta bar has something to display.
        try? await service.setString("demo:string:greeting", value: "Hello, Redis!")
        try? await service.setString("demo:string:counter", value: "42")
        try? await service.setString(
            "demo:string:user-json",
            value: #"{"name":"Alice","role":"admin","tags":["swift","redis"]}"#
        )
        try? await service.setString("demo:string:session-token", value: "abc123xyz")
        try? await service.expire("demo:string:session-token", seconds: 3600)

        // List
        for v in ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] {
            try? await service.rpush("demo:list:weekdays", value: v)
        }
        for v in ["job-1001", "job-1002", "job-1003", "job-1004"] {
            try? await service.rpush("demo:list:queue", value: v)
        }

        // Set
        for v in ["swift", "redis", "macos", "ui", "client"] {
            try? await service.sadd("demo:set:tags", member: v)
        }
        for v in ["alice", "bob", "charlie", "dana"] {
            try? await service.sadd("demo:set:users", member: v)
        }

        // Hash
        for (f, v) in [("name", "Alice"), ("age", "30"), ("city", "Beijing"), ("role", "admin")] {
            try? await service.hset("demo:hash:user:1", field: f, value: v)
        }
        for (f, v) in [("theme", "dark"), ("lang", "en"), ("debug", "true"), ("tabSize", "4")] {
            try? await service.hset("demo:hash:settings", field: f, value: v)
        }

        // ZSet
        for (m, s) in [("alice", 100.0), ("bob", 85.0), ("charlie", 92.0), ("dana", 76.5)] {
            try? await service.zadd("demo:zset:leaderboard", member: m, score: s)
        }
        let now = Date().timeIntervalSince1970
        for (i, page) in ["/home", "/about", "/pricing", "/contact"].enumerated() {
            try? await service.zadd("demo:zset:recent-pages", member: page, score: now - Double(i * 60))
        }

        // Stream — XADD has no service helper; raw is fine. `*` lets the
        // server assign IDs.
        for i in 1...5 {
            _ = try? await service.raw("XADD", [
                "demo:stream:events",
                "*",
                "type", "click",
                "user", "user-\(i)",
                "page", i.isMultiple(of: 2) ? "/home" : "/pricing"
            ])
        }

        await refreshDBSize()
        await reloadKeys()
    }

    /// Loads the next page of keys via SCAN.
    func loadMoreKeys() async {
        guard !scanFinished, status == .connected else { return }
        do {
            // Redis SCAN MATCH is exact-glob matching, so a bare "foo"
            // only matches a key literally named "foo". Users typing in
            // the search field almost always want substring search, so
            // auto-wrap with `*…*` when they didn't supply any glob
            // metacharacters. Power users can still type `foo:*` etc.
            let effectivePattern: String
            if pattern.isEmpty {
                effectivePattern = "*"
            } else if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
                effectivePattern = pattern
            } else {
                effectivePattern = "*\(pattern)*"
            }
            let page = try await service.scan(cursor: scanCursor, pattern: effectivePattern, count: 200)
            // Resolve type for each key concurrently so the list shows the icon + ttl.
            let resolved = try await withThrowingTaskGroup(of: RedisKey.self) { group -> [RedisKey] in
                for name in page.keys {
                    group.addTask { [service] in
                        let type = (try? await service.type(of: name)) ?? .unknown
                        let ttl = (try? await service.ttl(of: name))
                        return RedisKey(name: name, type: type, ttl: ttl)
                    }
                }
                var collected: [RedisKey] = []
                for try await item in group { collected.append(item) }
                return collected
            }
            // Preserve scan order roughly by filtering out duplicates, appending new.
            let existing = Set(keys.map(\.name))
            for k in resolved where !existing.contains(k.name) {
                if let filter = typeFilter, k.type != filter { continue }
                keys.append(k)
            }
            scanCursor = page.next
            scanFinished = (page.next == 0)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Inspector target

/// What the right-side inspector panel is currently focused on. Set by
/// the hash / zset editors when their table selection changes; rendered
/// by `InspectorPanel`. Equatable so SwiftUI's `.onChange` can observe.
struct InspectorTarget: Equatable {
    enum Kind: Equatable {
        /// Whole-string preview. Inspector is read-only — the StringEditor
        /// itself owns the editable copy; we don't want both writing.
        case string
        case hashField
        /// `primary` carries the index as a decimal string.
        case listIndex
        /// `primary` is the original member; editing `secondary` renames
        /// via SREM + SADD.
        case setMember
        case zsetMember
    }
    let kind: Kind
    /// The Redis key the row belongs to (e.g. the hash's name).
    let key: String
    /// Field name / zset member / list index / original set member.
    /// Empty for `.string`.
    let primary: String
    /// Editable content (or read-only preview for `.string`). Stays a
    /// String so the inspector can stay type-agnostic; each kind tells
    /// `InspectorPanel` how to commit.
    let secondary: String
}

// MARK: - Command history

/// One entry in the per-session command log shown in the Command History
/// window. Captured at `RedisService.raw` (the only command chokepoint).
struct CommandLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let command: String
    let args: [String]

    var argument: String { args.joined(separator: " ") }
}

/// Per-session ring buffer of issued commands. Capped to keep memory bounded
/// during long sessions; SCAN/TYPE/TTL traffic adds up fast on a busy DB.
@Observable
@MainActor
final class CommandHistory {
    private(set) var entries: [CommandLogEntry] = []
    private let maxEntries: Int

    init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    func append(_ entry: CommandLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
