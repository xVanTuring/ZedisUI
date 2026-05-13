import Foundation

/// A single Redis command in the editor's static grammar table.
struct RedisCommand: Hashable {
    let name: String
    let summary: String
    /// Option keywords accepted after the positional args (e.g. SET → EX, NX).
    /// Compared case-insensitively.
    let options: [String]
}

/// Static command catalog used by `RedisCommandEditor` for syntax highlighting
/// and completion. Not exhaustive — starts with the commands `RedisService`
/// actually issues, plus the handful of admin/inspection commands a Medis-style
/// command panel needs day-to-day.
enum RedisCommandGrammar {
    static let commands: [RedisCommand] = [
        // Server / connection
        .init(name: "PING",     summary: "Ping the server",                       options: []),
        .init(name: "ECHO",     summary: "Echo the given string",                 options: []),
        .init(name: "AUTH",     summary: "Authenticate to the server",            options: []),
        .init(name: "SELECT",   summary: "Change the selected database",          options: []),
        .init(name: "CLIENT",   summary: "Manage client connections",             options: ["ID","GETNAME","SETNAME","LIST","KILL","PAUSE","UNPAUSE","NO-EVICT","INFO","REPLY"]),
        .init(name: "INFO",     summary: "Server information and statistics",     options: []),
        .init(name: "CONFIG",   summary: "Read/write server configuration",       options: ["GET","SET","RESETSTAT","REWRITE"]),
        .init(name: "DBSIZE",   summary: "Number of keys in the selected database", options: []),
        .init(name: "FLUSHDB",  summary: "Remove all keys from the current DB",   options: ["ASYNC","SYNC"]),
        .init(name: "FLUSHALL", summary: "Remove all keys from all DBs",          options: ["ASYNC","SYNC"]),
        .init(name: "TIME",     summary: "Return current server time",            options: []),
        .init(name: "COMMAND",  summary: "Get command metadata",                  options: ["COUNT","DOCS","INFO","LIST","GETKEYS"]),
        .init(name: "SLOWLOG",  summary: "Manage the slow log",                   options: ["GET","LEN","RESET","HELP"]),
        .init(name: "DEBUG",    summary: "Internal commands for debugging",       options: ["OBJECT","SLEEP","JMAP","SET-ACTIVE-EXPIRE"]),
        .init(name: "MEMORY",   summary: "Memory diagnostics",                    options: ["USAGE","STATS","DOCTOR","PURGE","MALLOC-STATS"]),

        // Generic key
        .init(name: "DEL",      summary: "Delete one or more keys",               options: []),
        .init(name: "UNLINK",   summary: "Asynchronously delete keys",            options: []),
        .init(name: "EXISTS",   summary: "Check whether keys exist",              options: []),
        .init(name: "EXPIRE",   summary: "Set a TTL in seconds",                  options: ["NX","XX","GT","LT"]),
        .init(name: "PEXPIRE",  summary: "Set a TTL in milliseconds",             options: ["NX","XX","GT","LT"]),
        .init(name: "EXPIREAT", summary: "Set the expiration as a Unix timestamp", options: ["NX","XX","GT","LT"]),
        .init(name: "PERSIST",  summary: "Remove a key's TTL",                    options: []),
        .init(name: "TTL",      summary: "Get a key's TTL in seconds",            options: []),
        .init(name: "PTTL",     summary: "Get a key's TTL in milliseconds",       options: []),
        .init(name: "TYPE",     summary: "Determine the type stored at key",      options: []),
        .init(name: "RENAME",   summary: "Rename a key",                          options: []),
        .init(name: "RENAMENX", summary: "Rename a key only if the new name doesn't exist", options: []),
        .init(name: "KEYS",     summary: "Find keys matching a glob pattern",     options: []),
        .init(name: "SCAN",     summary: "Incrementally iterate the key space",   options: ["MATCH","COUNT","TYPE"]),
        .init(name: "RANDOMKEY", summary: "Return a random key",                  options: []),
        .init(name: "DUMP",     summary: "Serialized representation of a key",    options: []),
        .init(name: "RESTORE",  summary: "Restore a key from a serialized value", options: ["REPLACE","ABSTTL","IDLETIME","FREQ"]),
        .init(name: "OBJECT",   summary: "Inspect Redis internals for a key",     options: ["ENCODING","FREQ","IDLETIME","REFCOUNT","HELP"]),

        // String
        .init(name: "GET",      summary: "Get the value of a key",                options: []),
        .init(name: "SET",      summary: "Set the string value of a key",
              options: ["EX","PX","EXAT","PXAT","NX","XX","KEEPTTL","GET"]),
        .init(name: "GETSET",   summary: "Set a new value, return the old one",   options: []),
        .init(name: "GETDEL",   summary: "Get and delete a key",                  options: []),
        .init(name: "GETEX",    summary: "Get a value and optionally set TTL",    options: ["EX","PX","EXAT","PXAT","PERSIST"]),
        .init(name: "MGET",     summary: "Get multiple values",                   options: []),
        .init(name: "MSET",     summary: "Set multiple key/value pairs",          options: []),
        .init(name: "MSETNX",   summary: "Set multiple keys only if none exist",  options: []),
        .init(name: "SETEX",    summary: "Set value with a TTL in seconds",       options: []),
        .init(name: "PSETEX",   summary: "Set value with a TTL in milliseconds",  options: []),
        .init(name: "SETNX",    summary: "Set only if the key does not exist",    options: []),
        .init(name: "APPEND",   summary: "Append a value to a string",            options: []),
        .init(name: "STRLEN",   summary: "Length of a string value",              options: []),
        .init(name: "INCR",     summary: "Increment by 1",                        options: []),
        .init(name: "INCRBY",   summary: "Increment by N",                        options: []),
        .init(name: "INCRBYFLOAT", summary: "Increment by a float",               options: []),
        .init(name: "DECR",     summary: "Decrement by 1",                        options: []),
        .init(name: "DECRBY",   summary: "Decrement by N",                        options: []),

        // Hash
        .init(name: "HGET",     summary: "Get a hash field",                      options: []),
        .init(name: "HSET",     summary: "Set hash fields",                       options: []),
        .init(name: "HSETNX",   summary: "Set a hash field only if it doesn't exist", options: []),
        .init(name: "HMGET",    summary: "Get multiple hash fields",              options: []),
        .init(name: "HMSET",    summary: "Set multiple hash fields (deprecated)", options: []),
        .init(name: "HGETALL",  summary: "Get all fields and values",             options: []),
        .init(name: "HDEL",     summary: "Delete hash fields",                    options: []),
        .init(name: "HEXISTS",  summary: "Check whether a hash field exists",     options: []),
        .init(name: "HKEYS",    summary: "Get all hash field names",              options: []),
        .init(name: "HVALS",    summary: "Get all hash values",                   options: []),
        .init(name: "HLEN",     summary: "Number of fields in a hash",            options: []),
        .init(name: "HINCRBY",  summary: "Increment a hash field by N",           options: []),
        .init(name: "HINCRBYFLOAT", summary: "Increment a hash field by a float", options: []),
        .init(name: "HSCAN",    summary: "Incrementally iterate a hash",          options: ["MATCH","COUNT","NOVALUES"]),
        .init(name: "HSTRLEN",  summary: "Length of a hash field value",          options: []),

        // List
        .init(name: "LPUSH",    summary: "Prepend values to a list",              options: []),
        .init(name: "RPUSH",    summary: "Append values to a list",               options: []),
        .init(name: "LPUSHX",   summary: "Prepend only if the list exists",       options: []),
        .init(name: "RPUSHX",   summary: "Append only if the list exists",        options: []),
        .init(name: "LPOP",     summary: "Pop from the head of a list",           options: []),
        .init(name: "RPOP",     summary: "Pop from the tail of a list",           options: []),
        .init(name: "LRANGE",   summary: "Range of elements from a list",         options: []),
        .init(name: "LLEN",     summary: "Length of a list",                      options: []),
        .init(name: "LINDEX",   summary: "Element at an index",                   options: []),
        .init(name: "LSET",     summary: "Set the element at an index",           options: []),
        .init(name: "LREM",     summary: "Remove elements equal to value",        options: []),
        .init(name: "LTRIM",    summary: "Trim a list to a range",                options: []),
        .init(name: "LINSERT",  summary: "Insert before or after a pivot",        options: ["BEFORE","AFTER"]),
        .init(name: "LPOS",     summary: "Index of matching element",             options: ["RANK","COUNT","MAXLEN"]),

        // Set
        .init(name: "SADD",     summary: "Add members to a set",                  options: []),
        .init(name: "SREM",     summary: "Remove members from a set",             options: []),
        .init(name: "SMEMBERS", summary: "All members of a set",                  options: []),
        .init(name: "SISMEMBER", summary: "Test set membership",                  options: []),
        .init(name: "SMISMEMBER", summary: "Test membership of multiple values",  options: []),
        .init(name: "SCARD",    summary: "Number of members in a set",            options: []),
        .init(name: "SDIFF",    summary: "Difference of sets",                    options: []),
        .init(name: "SDIFFSTORE", summary: "Store the difference",                options: []),
        .init(name: "SINTER",   summary: "Intersection of sets",                  options: []),
        .init(name: "SINTERSTORE", summary: "Store the intersection",             options: []),
        .init(name: "SUNION",   summary: "Union of sets",                         options: []),
        .init(name: "SUNIONSTORE", summary: "Store the union",                    options: []),
        .init(name: "SSCAN",    summary: "Incrementally iterate a set",           options: ["MATCH","COUNT"]),
        .init(name: "SRANDMEMBER", summary: "Random member(s) from a set",        options: []),
        .init(name: "SPOP",     summary: "Pop one or more members",               options: []),
        .init(name: "SMOVE",    summary: "Move a member between sets",            options: []),

        // Sorted set
        .init(name: "ZADD",     summary: "Add members to a sorted set",
              options: ["NX","XX","GT","LT","CH","INCR"]),
        .init(name: "ZREM",     summary: "Remove members from a sorted set",     options: []),
        .init(name: "ZSCORE",   summary: "Score of a member",                    options: []),
        .init(name: "ZMSCORE",  summary: "Scores of multiple members",           options: []),
        .init(name: "ZINCRBY",  summary: "Increment the score of a member",     options: []),
        .init(name: "ZCARD",    summary: "Number of members in a sorted set",   options: []),
        .init(name: "ZCOUNT",   summary: "Count members in a score range",     options: []),
        .init(name: "ZRANGE",   summary: "Range of members by index/score/lex",
              options: ["BYSCORE","BYLEX","REV","LIMIT","WITHSCORES"]),
        .init(name: "ZRANGEBYSCORE", summary: "Members in a score range",
              options: ["LIMIT","WITHSCORES"]),
        .init(name: "ZRANGEBYLEX", summary: "Members in a lex range",
              options: ["LIMIT"]),
        .init(name: "ZREVRANGE", summary: "Range in reverse order",
              options: ["WITHSCORES"]),
        .init(name: "ZRANK",    summary: "Rank of a member",                    options: ["WITHSCORE"]),
        .init(name: "ZREVRANK", summary: "Reverse rank of a member",            options: ["WITHSCORE"]),
        .init(name: "ZSCAN",    summary: "Incrementally iterate a sorted set",  options: ["MATCH","COUNT"]),
        .init(name: "ZPOPMIN",  summary: "Pop members with the lowest scores",  options: []),
        .init(name: "ZPOPMAX",  summary: "Pop members with the highest scores", options: []),
        .init(name: "ZREMRANGEBYRANK", summary: "Remove by index range",        options: []),
        .init(name: "ZREMRANGEBYSCORE", summary: "Remove by score range",       options: []),
        .init(name: "ZREMRANGEBYLEX", summary: "Remove by lex range",           options: []),

        // Pub/Sub
        .init(name: "PUBLISH",  summary: "Publish to a channel",                 options: []),
        .init(name: "SUBSCRIBE", summary: "Subscribe to channels",               options: []),
        .init(name: "UNSUBSCRIBE", summary: "Unsubscribe from channels",         options: []),
        .init(name: "PSUBSCRIBE", summary: "Pattern subscribe",                  options: []),
        .init(name: "PUBSUB",   summary: "Inspect the Pub/Sub state",
              options: ["CHANNELS","NUMSUB","NUMPAT","SHARDCHANNELS","SHARDNUMSUB"]),

        // Transactions / scripting
        .init(name: "MULTI",    summary: "Start a transaction",                  options: []),
        .init(name: "EXEC",     summary: "Execute a transaction",                options: []),
        .init(name: "DISCARD",  summary: "Discard a transaction",                options: []),
        .init(name: "WATCH",    summary: "Watch keys for changes",               options: []),
        .init(name: "UNWATCH",  summary: "Unwatch all keys",                     options: []),
        .init(name: "EVAL",     summary: "Run a Lua script",                     options: []),
        .init(name: "EVALSHA",  summary: "Run a cached Lua script by hash",      options: []),
        .init(name: "SCRIPT",   summary: "Manage cached scripts",
              options: ["LOAD","EXISTS","FLUSH","KILL"]),

        // JSON (RedisJSON)
        .init(name: "JSON.GET",  summary: "Get a JSON value",
              options: ["INDENT","NEWLINE","SPACE","NOESCAPE"]),
        .init(name: "JSON.SET",  summary: "Set a JSON value",                    options: ["NX","XX"]),
        .init(name: "JSON.DEL",  summary: "Delete a JSON value at path",         options: []),
        .init(name: "JSON.TYPE", summary: "Type of a JSON value at path",        options: []),
        .init(name: "JSON.ARRLEN", summary: "Length of a JSON array",            options: []),
        .init(name: "JSON.OBJKEYS", summary: "Keys of a JSON object",            options: []),
    ]

    /// Set of all known command names (uppercased) for O(1) recognition during
    /// highlighting.
    static let commandNames: Set<String> = Set(commands.map { $0.name })

    private static let byName: [String: RedisCommand] = {
        var m: [String: RedisCommand] = [:]
        for c in commands { m[c.name] = c }
        return m
    }()

    /// Commands whose name starts with `prefix` (case-insensitive), ordered
    /// alphabetically. Returns all commands when `prefix` is empty.
    static func match(prefix: String) -> [RedisCommand] {
        let p = prefix.uppercased()
        if p.isEmpty { return commands }
        return commands.filter { $0.name.hasPrefix(p) }
    }

    /// Option keywords for a command name (case-insensitive lookup), filtered
    /// by `prefix` (also case-insensitive).
    static func options(for commandName: String, prefix: String = "") -> [String] {
        guard let cmd = byName[commandName.uppercased()] else { return [] }
        let p = prefix.uppercased()
        if p.isEmpty { return cmd.options }
        return cmd.options.filter { $0.hasPrefix(p) }
    }

    /// True when `token` matches a known command (case-insensitive).
    static func isCommand(_ token: String) -> Bool {
        commandNames.contains(token.uppercased())
    }

    /// True when `token` is a known option of `commandName` (case-insensitive).
    static func isOption(_ token: String, of commandName: String) -> Bool {
        guard let cmd = byName[commandName.uppercased()] else { return false }
        let t = token.uppercased()
        return cmd.options.contains { $0 == t }
    }
}
