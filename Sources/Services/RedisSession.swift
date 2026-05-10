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

    var status: Status = .disconnected
    var availableDBs: Int = 16
    var currentDB: Int = 0
    var dbSize: Int = 0
    var serverVersion: String?

    var keys: [RedisKey] = []
    var scanCursor: Int = 0
    var scanFinished: Bool = false
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
        self.currentDB = connection.defaultDB
        // The connection's saved default of "*" is presented as an empty
        // search field; any other custom pattern is shown verbatim.
        self.pattern = (connection.defaultPattern == "*") ? "" : connection.defaultPattern
    }

    func connect() async throws {
        status = .connecting
        do {
            try await service.connect(initialDB: connection.defaultDB)
            availableDBs = (try? await service.dbCount()) ?? 16
            currentDB = await service.currentDB
            status = .connected
            serverVersion = try? await service.serverVersion()
            await refreshDBSize()
            await reloadKeys()
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() async {
        await service.disconnect()
        status = .disconnected
        keys = []
        scanCursor = 0
        scanFinished = false
        selectedKey = nil
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
        await loadMoreKeys()
    }

    /// Loads the next page of keys via SCAN.
    func loadMoreKeys() async {
        guard !scanFinished, status == .connected else { return }
        do {
            let effectivePattern = pattern.isEmpty ? "*" : pattern
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
