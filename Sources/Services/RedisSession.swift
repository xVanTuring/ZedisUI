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

    /// When true, the detail pane shows the Command Query terminal instead
    /// of the selected key's editor. Mutually exclusive with `selectedKey`.
    var commandQueryActive: Bool = false

    init(connection: Connection) {
        self.connection = connection
        let password = connection.savePassword ? KeychainHelper.password(for: connection.id) : nil
        self.service = RedisService(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password
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
