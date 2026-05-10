import Foundation

/// Tree node used by the sidebar to group keys by their `:` prefix.
/// `key == nil` means this node is a folder; otherwise it's a leaf.
///
/// Right now we group only by the FIRST `:` segment. Recursive grouping
/// (e.g. `a:b:c` → a > b > c) can be layered on later by changing `build`.
struct KeyTreeNode: Identifiable, Hashable {
    let id: String
    let label: String
    let key: RedisKey?
    let children: [KeyTreeNode]?

    var isFolder: Bool { children != nil }
    var keyCount: Int { children?.count ?? 0 }

    static func build(from keys: [RedisKey], minGroupSize: Int = 2) -> [KeyTreeNode] {
        var grouped: [String: [RedisKey]] = [:]
        var ungrouped: [RedisKey] = []

        for key in keys {
            if let colon = key.name.firstIndex(of: ":") {
                let prefix = String(key.name[..<colon])
                grouped[prefix, default: []].append(key)
            } else {
                ungrouped.append(key)
            }
        }

        var nodes: [KeyTreeNode] = []
        for (prefix, members) in grouped.sorted(by: { $0.key < $1.key }) {
            if members.count < minGroupSize {
                // Don't bother folding a prefix that has just one key.
                for k in members.sorted(by: { $0.name < $1.name }) {
                    nodes.append(.leaf(k))
                }
            } else {
                let kids = members
                    .sorted(by: { $0.name < $1.name })
                    .map { KeyTreeNode.leaf($0) }
                nodes.append(KeyTreeNode(
                    id: "group:\(prefix)",
                    label: prefix,
                    key: nil,
                    children: kids
                ))
            }
        }
        for k in ungrouped.sorted(by: { $0.name < $1.name }) {
            nodes.append(.leaf(k))
        }
        return nodes
    }

    private static func leaf(_ key: RedisKey) -> KeyTreeNode {
        KeyTreeNode(id: key.name, label: key.name, key: key, children: nil)
    }
}
