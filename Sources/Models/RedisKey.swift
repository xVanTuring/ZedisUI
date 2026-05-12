import Foundation

enum RedisKeyType: String, Codable, CaseIterable, Hashable {
    case string
    case list
    case set
    case zset
    case hash
    case stream
    case json
    case unknown

    init(rawWire: String) {
        switch rawWire.lowercased() {
        case "string":     self = .string
        case "list":       self = .list
        case "set":        self = .set
        case "zset":       self = .zset
        case "hash":       self = .hash
        case "stream":     self = .stream
        case "rejson-rl":  self = .json
        default:           self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .string:  return "String"
        case .list:    return "List"
        case .set:     return "Set"
        case .zset:    return "Sorted Set"
        case .hash:    return "Hash"
        case .stream:  return "Stream"
        case .json:    return "JSON"
        case .unknown: return "?"
        }
    }

    var symbolName: String {
        switch self {
        case .string:  return "text.alignleft"
        case .list:    return "list.bullet"
        case .set:     return "circle.grid.cross"
        case .zset:    return "list.number"
        case .hash:    return "tablecells"
        case .stream:  return "waveform"
        case .json:    return "curlybraces"
        case .unknown: return "questionmark"
        }
    }

    /// Types the user can create via the new-key menu / sheet.
    /// Stream is omitted — there's no plain creation path for it.
    static func creatable(includeJSON: Bool) -> [RedisKeyType] {
        var types: [RedisKeyType] = [.string, .hash, .list, .set, .zset]
        if includeJSON { types.append(.json) }
        return types
    }

    /// Types the user can filter by in the search menu.
    static func filterable(includeJSON: Bool) -> [RedisKeyType] {
        var types: [RedisKeyType] = [.string, .hash, .list, .set, .zset, .stream]
        if includeJSON { types.append(.json) }
        return types
    }
}

/// One row in the key list.
struct RedisKey: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var type: RedisKeyType
    /// Seconds until expiry. -1 means no expiry, -2 means missing, nil means unknown / not yet fetched.
    var ttl: Int?
}
