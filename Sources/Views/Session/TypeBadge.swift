import SwiftUI

/// Color-coded uppercase label like `HASH`, `STRING`, etc. — matches the
/// pill used in Medis for sidebar rows.
struct TypeBadge: View {
    let type: RedisKeyType
    var compact: Bool = false

    var body: some View {
        Text(type.displayCode)
            .font(.system(size: compact ? 9 : 10, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 3 : 4)
            .background(badgeColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var badgeColor: Color {
        switch type {
        case .string:  return Color.green.opacity(0.85)
        case .hash:    return Color.purple.opacity(0.85)
        case .list:    return Color.blue.opacity(0.85)
        case .set:     return Color.pink.opacity(0.85)
        case .zset:    return Color.orange.opacity(0.85)
        case .stream:  return Color.teal.opacity(0.85)
        case .json:    return Color.cyan.opacity(0.85)
        case .unknown: return Color.gray
        }
    }
}

extension RedisKeyType {
    var displayCode: String {
        switch self {
        case .string:  return "STRING"
        case .list:    return "LIST"
        case .set:     return "SET"
        case .zset:    return "ZSET"
        case .hash:    return "HASH"
        case .stream:  return "STREAM"
        case .json:    return "JSON"
        case .unknown: return "?"
        }
    }
}
