import Foundation

/// Tree node used by the sidebar to group keys by their `:` prefix.
/// `key == nil` means this node is a folder; otherwise it's a leaf.
///
/// Grouping is recursive: `a:b:c` and `a:b:d` produce `a > b > {c, d}`.
/// Each leaf's `label` is its tail after the parent folder's prefix, so
/// rows inside a folder render compactly while top-level orphans keep
/// their full name.
struct KeyTreeNode: Identifiable, Hashable {
    let id: String
    let label: String
    let key: RedisKey?
    let children: [KeyTreeNode]?

    var isFolder: Bool { children != nil }

    /// Total number of leaf keys under this node (recursive). For a leaf,
    /// returns 1 — but `KeyGroupRow` only reads this on folders.
    var keyCount: Int {
        if let children {
            return children.reduce(0) { $0 + $1.keyCount }
        }
        return 1
    }

    /// Build a tree from a flat key list. By default every multi-segment
    /// key is folded (matches Medis): `a:b` becomes folder `a` containing
    /// leaf `b` even when it's the only key under that prefix. Pass a
    /// higher `minGroupSize` to suppress single-key folders.
    static func build(from keys: [RedisKey], minGroupSize: Int = 1) -> [KeyTreeNode] {
        return buildLevel(keys: keys, depth: 0, minGroupSize: minGroupSize, ancestorPrefix: "")
    }

    private static func buildLevel(
        keys: [RedisKey],
        depth: Int,
        minGroupSize: Int,
        ancestorPrefix: String
    ) -> [KeyTreeNode] {
        // Partition this level's keys: those whose `depth`-th segment is
        // not their last → group candidates; those whose last segment is
        // at this depth → leaves of this level.
        var groups: [String: [RedisKey]] = [:]
        var leaves: [RedisKey] = []

        for key in keys {
            let segments = key.name.components(separatedBy: ":")
            if depth < segments.count - 1 {
                let seg = segments[depth]
                groups[seg, default: []].append(key)
            } else {
                leaves.append(key)
            }
        }

        var nodes: [KeyTreeNode] = []

        for (segment, members) in groups.sorted(by: { $0.key < $1.key }) {
            if members.count < minGroupSize {
                // One key under this prefix — flatten it rather than make a
                // folder of one. Recurse so the *single* key gets its
                // relative label correctly even if it has deeper segments.
                for k in members.sorted(by: { $0.name < $1.name }) {
                    nodes.append(leaf(k, ancestorPrefix: ancestorPrefix))
                }
            } else {
                let nextPrefix = ancestorPrefix.isEmpty
                    ? segment
                    : "\(ancestorPrefix):\(segment)"
                let kids = buildLevel(
                    keys: members,
                    depth: depth + 1,
                    minGroupSize: minGroupSize,
                    ancestorPrefix: nextPrefix
                )
                nodes.append(KeyTreeNode(
                    id: "group:\(nextPrefix)",
                    label: segment,
                    key: nil,
                    children: kids
                ))
            }
        }

        for k in leaves.sorted(by: { $0.name < $1.name }) {
            nodes.append(leaf(k, ancestorPrefix: ancestorPrefix))
        }

        return nodes
    }

    private static func leaf(_ key: RedisKey, ancestorPrefix: String) -> KeyTreeNode {
        let label: String
        if ancestorPrefix.isEmpty {
            label = key.name
        } else {
            let cut = ancestorPrefix + ":"
            label = key.name.hasPrefix(cut)
                ? String(key.name.dropFirst(cut.count))
                : key.name
        }
        return KeyTreeNode(id: key.name, label: label, key: key, children: nil)
    }
}
