import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import RediStack
import Logging

/// One row of `SLOWLOG GET`. Top-level so the view layer can render it
/// without crossing the actor isolation boundary with `RESPValue`.
struct SlowLogEntry: Identifiable, Hashable {
    let id: Int
    let timestampSeconds: Int
    let durationMicros: Int
    let command: String
    let client: String?
}

/// Thin async wrapper around RediStack's `RedisConnection` providing the command
/// surface the UI needs. One instance == one TCP connection to one Redis server.
///
/// We intentionally use a single connection rather than a pool: the UI is
/// effectively single-user and a single connection makes SELECT semantics
/// (which DB the next command targets) predictable. SCAN cursors are also
/// connection-bound in some setups, so this avoids surprises.
actor RedisService {
    enum ServiceError: LocalizedError {
        case notConnected
        case unexpectedReply(String)
        case redis(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:                return "Not connected to Redis."
            case .unexpectedReply(let s):      return "Unexpected reply: \(s)"
            case .redis(let s):                return s
            }
        }
    }

    /// Optional observer fired before every command is sent to Redis. Used
    /// by `CommandHistory` to populate the Command History window. The
    /// closure is `@Sendable` so it can hop to the MainActor; it must not
    /// capture actor-isolated state synchronously.
    typealias CommandLogger = @Sendable (_ command: String, _ args: [String], _ at: Date) -> Void

    private var host: String
    private var port: Int
    private let username: String?
    private let password: String?

    private let group: EventLoopGroup
    private var connection: RedisConnection?
    private(set) var currentDB: Int = 0
    private let commandLogger: CommandLogger?

    init(
        host: String,
        port: Int,
        username: String?,
        password: String?,
        commandLogger: CommandLogger? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.commandLogger = commandLogger
        // Single-threaded loop is plenty for a UI client.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    /// Re-point the service at a different endpoint. Used when a session
    /// brings up an SSH tunnel and wants Redis to dial the locally
    /// forwarded port instead of the original remote host:port.
    func setEndpoint(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    // MARK: - Lifecycle

    func connect(initialDB: Int = 0) async throws {
        guard connection == nil else { return }
        let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
        // Only forward a non-empty username — empty string would still trigger
        // RediStack's ACL `AUTH <user> <pass>` path and the server would reject
        // it as an invalid pair.
        let effectiveUsername = (username?.isEmpty == false) ? username : nil
        let effectivePassword = (password?.isEmpty == false) ? password : nil
        let config = try RedisConnection.Configuration(
            address: address,
            username: effectiveUsername,
            password: effectivePassword,
            initialDatabase: initialDB,
            defaultLogger: Logger(label: "ZedisUI.Redis")
        )

        let conn = try await RedisConnection.make(
            configuration: config,
            boundEventLoop: group.next()
        ).get()

        self.connection = conn
        self.currentDB = initialDB
    }

    func disconnect() async {
        guard let conn = connection else { return }
        try? await conn.close().get()
        self.connection = nil
    }

    var isConnected: Bool { connection != nil }

    // MARK: - Raw command (used by terminal & internal helpers)

    @discardableResult
    func raw(_ command: String, _ args: [String] = []) async throws -> RESPValue {
        guard let conn = connection else { throw ServiceError.notConnected }
        commandLogger?(command, args, Date())
        let respArgs = args.map { RESPValue(from: $0) }
        return try await conn.send(command: command, with: respArgs).get()
    }

    /// Convenience for the terminal: parse a full command line, run it, and return a
    /// pretty-printed reply string. We stringify inside the actor so the non-Sendable
    /// `RESPValue` never has to cross the isolation boundary.
    func runCommandLine(_ line: String) async throws -> String {
        let tokens = Self.tokenize(line)
        guard let head = tokens.first else { throw ServiceError.redis("Empty command") }
        let args = Array(tokens.dropFirst())
        let reply = try await raw(head, args)
        return reply.prettyPrinted()
    }

    // MARK: - Server / DB

    func select(db: Int) async throws {
        _ = try await raw("SELECT", [String(db)])
        self.currentDB = db
    }

    func dbCount() async throws -> Int {
        // CONFIG GET databases → ["databases", "16"]
        let reply = try await raw("CONFIG", ["GET", "databases"])
        if let array = reply.array, array.count >= 2, let s = array[1].string, let n = Int(s) {
            return n
        }
        return 16
    }

    func dbSize() async throws -> Int {
        let reply = try await raw("DBSIZE")
        return Int(reply.int ?? 0)
    }

    func ping() async throws -> String {
        let reply = try await raw("PING")
        return reply.string ?? ""
    }

    func info(section: String? = nil) async throws -> String {
        let reply: RESPValue
        if let section {
            reply = try await raw("INFO", [section])
        } else {
            reply = try await raw("INFO")
        }
        return reply.string ?? ""
    }

    /// SLOWLOG GET → already-Sendable rows. Parsing happens inside the
    /// actor so the non-Sendable `RESPValue` doesn't leak across.
    func slowLog(count: Int = 128) async throws -> [SlowLogEntry] {
        let reply = try await raw("SLOWLOG", ["GET", String(count)])
        guard let entries = reply.array else { return [] }
        return entries.compactMap { e -> SlowLogEntry? in
            guard let row = e.array, row.count >= 4 else { return nil }
            let id = Int(row[0].int ?? 0)
            let ts = Int(row[1].int ?? 0)
            let dur = Int(row[2].int ?? 0)
            let cmdParts: [String] = row[3].array?.compactMap(\.string) ?? []
            let client: String? = (row.count > 4) ? row[4].string : nil
            return SlowLogEntry(
                id: id,
                timestampSeconds: ts,
                durationMicros: dur,
                command: cmdParts.joined(separator: " "),
                client: client
            )
        }
    }

    /// Parses `redis_version` out of `INFO server`. Returns nil if missing.
    func serverVersion() async throws -> String? {
        let info = try await self.info(section: "server")
        for raw in info.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = String(raw)
            if line.hasPrefix("redis_version:") {
                return String(line.dropFirst("redis_version:".count))
            }
        }
        return nil
    }

    // MARK: - Key-level

    func type(of key: String) async throws -> RedisKeyType {
        let reply = try await raw("TYPE", [key])
        return RedisKeyType(rawWire: reply.string ?? "unknown")
    }

    func ttl(of key: String) async throws -> Int {
        let reply = try await raw("TTL", [key])
        return Int(reply.int ?? -2)
    }

    func expire(_ key: String, seconds: Int) async throws {
        _ = try await raw("EXPIRE", [key, String(seconds)])
    }

    func persist(_ key: String) async throws {
        _ = try await raw("PERSIST", [key])
    }

    func rename(_ key: String, to newKey: String) async throws {
        _ = try await raw("RENAME", [key, newKey])
    }

    func delete(_ keys: [String]) async throws -> Int {
        let reply = try await raw("DEL", keys)
        return Int(reply.int ?? 0)
    }

    /// `MEMORY USAGE key` — bytes used by the key's value (incl. object overhead).
    func memoryUsage(of key: String) async throws -> Int {
        let reply = try await raw("MEMORY", ["USAGE", key])
        return Int(reply.int ?? 0)
    }

    /// `OBJECT ENCODING key` — internal encoding name (e.g. ziplist, listpack…).
    func objectEncoding(of key: String) async throws -> String {
        let reply = try await raw("OBJECT", ["ENCODING", key])
        return reply.string ?? ""
    }

    /// Incrementally scan for keys matching `pattern` starting from `cursor`.
    /// Returns the next cursor (0 means done) and the batch of keys.
    func scan(cursor: Int, pattern: String, count: Int = 200) async throws -> (next: Int, keys: [String]) {
        let reply = try await raw("SCAN", [String(cursor), "MATCH", pattern, "COUNT", String(count)])
        guard let array = reply.array, array.count >= 2 else {
            throw ServiceError.unexpectedReply("SCAN")
        }
        let nextCursor = Int(array[0].string ?? "0") ?? 0
        let keys = array[1].array?.compactMap { $0.string } ?? []
        return (nextCursor, keys)
    }

    // MARK: - String

    func getString(_ key: String) async throws -> String? {
        let reply = try await raw("GET", [key])
        return reply.string
    }

    func setString(_ key: String, value: String) async throws {
        _ = try await raw("SET", [key, value])
    }

    // MARK: - RedisJSON

    /// Returns true if the server has the RedisJSON module loaded.
    /// Uses COMMAND INFO so no keys are touched; treats any "unknown command"
    /// error as absent, other errors as inconclusive (returns false).
    func hasRedisJSON() async -> Bool {
        guard let reply = try? await raw("COMMAND", ["INFO", "JSON.GET"]) else { return false }
        // COMMAND INFO returns an array with one element per queried command.
        // The element is null when the command is unknown.
        if case .array(let items) = reply, let first = items.first {
            if case .null = first { return false }
            return true
        }
        return false
    }

    func jsonGet(_ key: String) async throws -> String? {
        let reply = try await raw("JSON.GET", [key])
        return reply.string
    }

    func jsonSet(_ key: String, value: String) async throws {
        _ = try await raw("JSON.SET", [key, "$", value])
    }

    // MARK: - Hash

    func hgetall(_ key: String) async throws -> [(String, String)] {
        let reply = try await raw("HGETALL", [key])
        guard let arr = reply.array else { return [] }
        var result: [(String, String)] = []
        var i = 0
        while i + 1 < arr.count {
            result.append((arr[i].string ?? "", arr[i + 1].string ?? ""))
            i += 2
        }
        return result
    }

    func hset(_ key: String, field: String, value: String) async throws {
        _ = try await raw("HSET", [key, field, value])
    }

    func hdel(_ key: String, field: String) async throws {
        _ = try await raw("HDEL", [key, field])
    }

    func hlen(_ key: String) async throws -> Int {
        let reply = try await raw("HLEN", [key])
        return Int(reply.int ?? 0)
    }

    /// Cursor-based hash iteration. Returns the next cursor (0 means done)
    /// and a batch of field/value pairs. HSCAN may return duplicates across
    /// iterations during rehashing — caller is responsible for dedup. When
    /// `match` is non-nil it is sent as the MATCH glob; the filter is
    /// applied server-side after the slot is read, so many iterations may
    /// return zero matches before cursor=0.
    func hscan(_ key: String, cursor: Int, match: String? = nil, count: Int = 200) async throws -> (next: Int, pairs: [(String, String)]) {
        var args = [key, String(cursor)]
        if let m = match { args.append(contentsOf: ["MATCH", m]) }
        args.append(contentsOf: ["COUNT", String(count)])
        let reply = try await raw("HSCAN", args)
        guard let array = reply.array, array.count >= 2 else {
            throw ServiceError.unexpectedReply("HSCAN")
        }
        let nextCursor = Int(array[0].string ?? "0") ?? 0
        var pairs: [(String, String)] = []
        if let flat = array[1].array {
            var i = 0
            while i + 1 < flat.count {
                pairs.append((flat[i].string ?? "", flat[i + 1].string ?? ""))
                i += 2
            }
        }
        return (nextCursor, pairs)
    }

    // MARK: - List

    func lrange(_ key: String, start: Int = 0, stop: Int = -1) async throws -> [String] {
        let reply = try await raw("LRANGE", [key, String(start), String(stop)])
        return reply.array?.compactMap { $0.string } ?? []
    }

    func llen(_ key: String) async throws -> Int {
        let reply = try await raw("LLEN", [key])
        return Int(reply.int ?? 0)
    }

    func lset(_ key: String, index: Int, value: String) async throws {
        _ = try await raw("LSET", [key, String(index), value])
    }

    func rpush(_ key: String, value: String) async throws {
        _ = try await raw("RPUSH", [key, value])
    }

    func lpush(_ key: String, value: String) async throws {
        _ = try await raw("LPUSH", [key, value])
    }

    func lremByIndex(_ key: String, index: Int) async throws {
        // No direct command; pattern: set sentinel then LREM 1 sentinel.
        let sentinel = "__ZEDIS_DEL_\(UUID().uuidString)__"
        _ = try await raw("LSET", [key, String(index), sentinel])
        _ = try await raw("LREM", [key, "1", sentinel])
    }

    // MARK: - Set

    func smembers(_ key: String) async throws -> [String] {
        let reply = try await raw("SMEMBERS", [key])
        return reply.array?.compactMap { $0.string } ?? []
    }

    func sadd(_ key: String, member: String) async throws {
        _ = try await raw("SADD", [key, member])
    }

    func srem(_ key: String, member: String) async throws {
        _ = try await raw("SREM", [key, member])
    }

    func scard(_ key: String) async throws -> Int {
        let reply = try await raw("SCARD", [key])
        return Int(reply.int ?? 0)
    }

    /// Cursor-based set iteration. Returns the next cursor (0 means done)
    /// and a batch of members. SSCAN may return duplicates during rehashing.
    func sscan(_ key: String, cursor: Int, match: String? = nil, count: Int = 200) async throws -> (next: Int, members: [String]) {
        var args = [key, String(cursor)]
        if let m = match { args.append(contentsOf: ["MATCH", m]) }
        args.append(contentsOf: ["COUNT", String(count)])
        let reply = try await raw("SSCAN", args)
        guard let array = reply.array, array.count >= 2 else {
            throw ServiceError.unexpectedReply("SSCAN")
        }
        let nextCursor = Int(array[0].string ?? "0") ?? 0
        let members = array[1].array?.compactMap { $0.string } ?? []
        return (nextCursor, members)
    }

    // MARK: - Sorted Set

    func zrange(_ key: String, start: Int = 0, stop: Int = -1) async throws -> [(String, Double)] {
        let reply = try await raw("ZRANGE", [key, String(start), String(stop), "WITHSCORES"])
        guard let arr = reply.array else { return [] }
        var result: [(String, Double)] = []
        var i = 0
        while i + 1 < arr.count {
            let member = arr[i].string ?? ""
            let score = Double(arr[i + 1].string ?? "0") ?? 0
            result.append((member, score))
            i += 2
        }
        return result
    }

    func zadd(_ key: String, member: String, score: Double) async throws {
        _ = try await raw("ZADD", [key, String(score), member])
    }

    func zrem(_ key: String, member: String) async throws {
        _ = try await raw("ZREM", [key, member])
    }

    func zcard(_ key: String) async throws -> Int {
        let reply = try await raw("ZCARD", [key])
        return Int(reply.int ?? 0)
    }

    /// Cursor-based zset iteration. Returns the next cursor (0 means done)
    /// and a batch of (member, score) pairs. ZSCAN traverses by hash slot,
    /// so results are NOT in score order — caller may sort client-side if
    /// score ordering matters.
    func zscan(_ key: String, cursor: Int, match: String? = nil, count: Int = 200) async throws -> (next: Int, pairs: [(String, Double)]) {
        var args = [key, String(cursor)]
        if let m = match { args.append(contentsOf: ["MATCH", m]) }
        args.append(contentsOf: ["COUNT", String(count)])
        let reply = try await raw("ZSCAN", args)
        guard let array = reply.array, array.count >= 2 else {
            throw ServiceError.unexpectedReply("ZSCAN")
        }
        let nextCursor = Int(array[0].string ?? "0") ?? 0
        var pairs: [(String, Double)] = []
        if let flat = array[1].array {
            var i = 0
            while i + 1 < flat.count {
                let member = flat[i].string ?? ""
                let score = Double(flat[i + 1].string ?? "0") ?? 0
                pairs.append((member, score))
                i += 2
            }
        }
        return (nextCursor, pairs)
    }

    // MARK: - Stream

    /// Total number of entries in a stream.
    func xlen(_ key: String) async throws -> Int {
        let reply = try await raw("XLEN", [key])
        return Int(reply.int ?? 0)
    }

    /// Deletes one stream entry by ID. Returns the count XDEL reports
    /// (0 if the id wasn't present).
    @discardableResult
    func xdel(_ key: String, id: String) async throws -> Int {
        let reply = try await raw("XDEL", [key, id])
        return Int(reply.int ?? 0)
    }

    /// Appends an entry to a stream with a server-assigned ID. `fields`
    /// is an ordered list of (field, value) pairs — duplicates are
    /// allowed by Redis and we preserve the order on the wire.
    /// Returns the new entry's ID (e.g. `1700000000000-0`).
    @discardableResult
    func xadd(_ key: String, fields: [(String, String)]) async throws -> String {
        var args: [String] = [key, "*"]
        for (f, v) in fields {
            args.append(f)
            args.append(v)
        }
        let reply = try await raw("XADD", args)
        return reply.string ?? ""
    }

    /// Reads up to `count` entries from a stream. Each entry is its
    /// auto-generated ID (`<ms>-<seq>`) plus an ordered list of
    /// field/value pairs (XADD allows duplicate fields, so we keep them
    /// as an array rather than a dict).
    func xrange(_ key: String, count: Int = 200) async throws -> [(id: String, fields: [(String, String)])] {
        let reply = try await raw("XRANGE", [key, "-", "+", "COUNT", String(count)])
        guard let entries = reply.array else { return [] }
        return entries.compactMap { entry in
            guard let parts = entry.array, parts.count >= 2,
                  let id = parts[0].string,
                  let fieldArr = parts[1].array
            else { return nil }
            var fields: [(String, String)] = []
            var i = 0
            while i + 1 < fieldArr.count {
                fields.append((
                    fieldArr[i].string ?? "",
                    fieldArr[i + 1].string ?? ""
                ))
                i += 2
            }
            return (id, fields)
        }
    }

    // MARK: - Tokenizer for terminal input

    /// Splits a command line on whitespace, honoring single/double quoted strings.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character? = nil
        var escape = false
        for ch in line {
            if escape {
                current.append(ch)
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

// MARK: - Pretty-printing RESP for the terminal

extension RESPValue {
    /// Convert a RESP reply into a multi-line, human-readable string for the terminal.
    func prettyPrinted(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .null:
            return pad + "(nil)"
        case .simpleString(let buffer), .bulkString(.some(let buffer)):
            if let s = String(bytes: buffer.readableBytesView, encoding: .utf8) {
                return pad + "\"" + s + "\""
            }
            return pad + "<binary \(buffer.readableBytes) bytes>"
        case .bulkString(.none):
            return pad + "(nil)"
        case .integer(let n):
            return pad + "(integer) \(n)"
        case .error(let err):
            return pad + "(error) " + err.message
        case .array(let arr):
            if arr.isEmpty { return pad + "(empty array)" }
            var lines: [String] = []
            for (i, item) in arr.enumerated() {
                let inner = item.prettyPrinted(indent: indent + 1)
                let trimmed = inner.drop(while: { $0 == " " })
                lines.append("\(pad)\(i + 1)) \(trimmed)")
            }
            return lines.joined(separator: "\n")
        }
    }
}

extension RESPValue {
    /// Best-effort coercion to Int across simple-string / integer replies.
    var int: Int64? {
        switch self {
        case .integer(let n): return Int64(n)
        case .simpleString(let buf), .bulkString(.some(let buf)):
            if let s = String(bytes: buf.readableBytesView, encoding: .utf8) { return Int64(s) }
            return nil
        default: return nil
        }
    }
}
