import SwiftUI

// MARK: - JSONEditor view

struct JSONEditor: View {
    let session: RedisSession
    let key: String

    @State private var root: JSONNode = JSONNode(kind: .object)
    @State private var rawText: String = ""
    @State private var mode: Mode = .tree
    @State private var loaded = false
    @State private var dirty = false
    @State private var jsonError: String?

    enum Mode: String, CaseIterable, Identifiable {
        case tree = "Tree"
        case text = "Text"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let err = jsonError {
                    errorBar(err)
                }
                Group {
                    if mode == .tree {
                        JSONTreeView(root: root, onEdit: markDirty)
                    } else {
                        textEditor
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if dirty {
                Button { Task { await save() } } label: {
                    Label("Save", systemImage: "checkmark")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(14)
                .disabled(jsonError != nil)
                .transition(.opacity)
            }
        }
        .background(
            Button("save") { Task { await save() } }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .task(id: key) { await load() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: mode) { old, new in switchMode(from: old, to: new) }

            if mode == .text {
                Button { formatText() } label: {
                    Label("Format", systemImage: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button { setAllExpanded(true) } label: {
                    Label("Expand All", systemImage: "chevron.down.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { setAllExpanded(false) } label: {
                    Label("Collapse All", systemImage: "chevron.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var textEditor: some View {
        JSONCodeEditor(text: $rawText)
            .onChange(of: rawText) { _, _ in
                if loaded {
                    dirty = true
                    validateText()
                }
            }
    }

    private func errorBar(_ err: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
    }

    // MARK: Actions

    private func markDirty() {
        guard loaded else { return }
        dirty = true
        if mode == .tree { validateTree() }
    }

    private func switchMode(from old: Mode, to new: Mode) {
        guard old != new else { return }
        if old == .tree && new == .text {
            rawText = Self.serialize(root) ?? rawText
            validateText()
        } else if old == .text && new == .tree {
            if let parsed = try? JSONNode.parse(rawText) {
                root = parsed
                jsonError = nil
            } else {
                // Stay in text mode; surface the error.
                jsonError = "Invalid JSON — fix before switching to Tree"
                DispatchQueue.main.async { mode = .text }
            }
        }
    }

    private func load() async {
        loaded = false
        let raw = (try? await session.service.jsonGet(key)) ?? ""
        rawText = Self.prettyPrint(raw) ?? raw
        root = (try? JSONNode.parse(rawText)) ?? JSONNode(kind: .object)
        dirty = false
        jsonError = nil
        loaded = true
    }

    private func save() async {
        guard dirty, jsonError == nil else { return }
        let payload: String
        if mode == .tree {
            guard let s = Self.serialize(root) else {
                jsonError = "Invalid JSON"
                return
            }
            payload = s
        } else {
            payload = rawText
        }
        do {
            try await session.service.jsonSet(key, value: payload)
            if mode == .tree {
                rawText = payload
            } else if let parsed = try? JSONNode.parse(rawText) {
                root = parsed
            }
            dirty = false
        } catch { /* surfaced via session.status */ }
    }

    private func formatText() {
        if let pretty = Self.prettyPrint(rawText) {
            rawText = pretty
            validateText()
        }
    }

    private func validateText() {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            jsonError = nil
            return
        }
        guard let data = rawText.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
        else {
            jsonError = "Invalid JSON"
            return
        }
        jsonError = nil
    }

    private func validateTree() {
        jsonError = Self.findInvalidNumber(in: root) ? "Invalid number" : nil
    }

    static func findInvalidNumber(in node: JSONNode) -> Bool {
        if node.kind == .number {
            let s = node.numberValue.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty && Double(s) == nil { return true }
        }
        return node.children.contains(where: { findInvalidNumber(in: $0) })
    }

    private func setAllExpanded(_ expanded: Bool) {
        setExpanded(root, expanded)
    }

    private func setExpanded(_ node: JSONNode, _ expanded: Bool) {
        if node.kind == .object || node.kind == .array {
            node.isExpanded = expanded
            node.children.forEach { setExpanded($0, expanded) }
        }
    }

    // MARK: JSON I/O

    static func prettyPrint(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .fragmentsAllowed]
              ),
              let str = String(data: pretty, encoding: .utf8)
        else { return nil }
        return str
    }

    static func serialize(_ node: JSONNode) -> String? {
        var out = ""
        guard writeJSON(node, into: &out, indent: 0) else { return nil }
        return out
    }

    private static func writeJSON(_ node: JSONNode, into out: inout String, indent: Int) -> Bool {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch node.kind {
        case .object:
            if node.children.isEmpty { out += "{}"; return true }
            out += "{\n"
            for (i, c) in node.children.enumerated() {
                out += inner + encodeString(c.key ?? "") + ": "
                if !writeJSON(c, into: &out, indent: indent + 1) { return false }
                if i < node.children.count - 1 { out += "," }
                out += "\n"
            }
            out += pad + "}"
            return true
        case .array:
            if node.children.isEmpty { out += "[]"; return true }
            out += "[\n"
            for (i, c) in node.children.enumerated() {
                out += inner
                if !writeJSON(c, into: &out, indent: indent + 1) { return false }
                if i < node.children.count - 1 { out += "," }
                out += "\n"
            }
            out += pad + "]"
            return true
        case .string:
            out += encodeString(node.stringValue)
            return true
        case .number:
            let s = node.numberValue.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { out += "0"; return true }
            if Double(s) == nil { return false }
            out += s
            return true
        case .bool:
            out += node.boolValue ? "true" : "false"
            return true
        case .null:
            out += "null"
            return true
        }
    }

    private static func encodeString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out += String(ch)
                }
            }
        }
        out += "\""
        return out
    }
}

// String content that is a JSON object or array (used to offer rich editing).
func isJSONObjectOrArrayString(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first, first == "{" || first == "[" else { return false }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [])
    else { return false }
    return obj is [Any] || obj is [String: Any]
}

// MARK: - Tree model

@Observable
final class JSONNode: Identifiable {
    let id = UUID()
    var key: String?
    var kind: Kind
    var stringValue: String = "" {
        didSet { _cachedIsJSONLike = nil }
    }
    var numberValue: String = ""
    var boolValue: Bool = false
    var children: [JSONNode] = []
    var isExpanded: Bool = true

    // Cached result of `isJSONObjectOrArrayString(stringValue)`. The check
    // runs a full `JSONSerialization` parse, so for large string values it
    // was being re-evaluated on every SwiftUI body pass per row — death by
    // a thousand parses. Invalidated whenever `stringValue` changes.
    @ObservationIgnored private var _cachedIsJSONLike: Bool?
    var isJSONLikeString: Bool {
        if let v = _cachedIsJSONLike { return v }
        let v = isJSONObjectOrArrayString(stringValue)
        _cachedIsJSONLike = v
        return v
    }

    enum Kind: String, CaseIterable, Identifiable {
        case object, array, string, number, bool, null
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .object: return "Object"
            case .array:  return "Array"
            case .string: return "String"
            case .number: return "Number"
            case .bool:   return "Boolean"
            case .null:   return "Null"
            }
        }
        /// Foreground accent used to colorize the value/badge for this type.
        var accent: Color {
            switch self {
            case .object: return Color(red: 0.55, green: 0.78, blue: 1.00) // light blue
            case .array:  return Color(red: 0.78, green: 0.65, blue: 1.00) // lavender
            case .string: return Color(red: 0.96, green: 0.72, blue: 0.35) // amber
            case .number: return Color(red: 0.55, green: 0.85, blue: 0.55) // green
            case .bool:   return Color(red: 1.00, green: 0.55, blue: 0.55) // coral
            case .null:   return Color.secondary
            }
        }
        var badge: String {
            switch self {
            case .object: return "{ }"
            case .array:  return "[ ]"
            case .string: return "abc"
            case .number: return "123"
            case .bool:   return "T/F"
            case .null:   return "∅"
            }
        }
    }

    init(kind: Kind) { self.kind = kind }

    static func parse(_ text: String) throws -> JSONNode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8)
        else { return JSONNode(kind: .object) }
        let obj = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return build(from: obj)
    }

    private static func build(from any: Any) -> JSONNode {
        if any is NSNull {
            return JSONNode(kind: .null)
        }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                let node = JSONNode(kind: .bool)
                node.boolValue = n.boolValue
                return node
            }
            let node = JSONNode(kind: .number)
            node.numberValue = n.stringValue
            return node
        }
        if let s = any as? String {
            let node = JSONNode(kind: .string)
            node.stringValue = s
            return node
        }
        if let arr = any as? [Any] {
            let node = JSONNode(kind: .array)
            node.children = arr.map { build(from: $0) }
            return node
        }
        if let dict = any as? [String: Any] {
            let node = JSONNode(kind: .object)
            // NSDictionary doesn't guarantee key order — sort alphabetically
            // for a stable presentation. The user can re-order in v2.
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                let child = build(from: v)
                child.key = k
                node.children.append(child)
            }
            return node
        }
        return JSONNode(kind: .null)
    }

    func appendChild() -> JSONNode {
        let child = JSONNode(kind: .string)
        if kind == .object {
            let existing = Set(children.compactMap(\.key))
            var i = 1
            while existing.contains("key\(i)") { i += 1 }
            child.key = "key\(i)"
        }
        children.append(child)
        return child
    }

    func deepCopy() -> JSONNode {
        let copy = JSONNode(kind: kind)
        copy.key = key
        copy.stringValue = stringValue
        copy.numberValue = numberValue
        copy.boolValue = boolValue
        copy.isExpanded = isExpanded
        copy.children = children.map { $0.deepCopy() }
        return copy
    }
}

// MARK: - Tree view
//
// The tree is rendered as a flat list inside a single `LazyVStack` so SwiftUI
// can virtualize off-screen rows. `flattenJSONTree` walks only into expanded
// containers, so the produced row count is O(visible nodes) regardless of the
// total document size — a 50k-node JSON whose root is collapsed produces a
// single row.

private enum JSONFlatRow: Identifiable {
    case node(JSONNode, parent: JSONNode?, depth: Int, isRoot: Bool, indexInParent: Int?)
    case addChild(parent: JSONNode, depth: Int)

    var id: String {
        switch self {
        case .node(let n, _, _, _, _): return "n-\(n.id.uuidString)"
        case .addChild(let p, _):      return "a-\(p.id.uuidString)"
        }
    }
}

private func flattenJSONTree(
    _ node: JSONNode,
    parent: JSONNode?,
    depth: Int,
    isRoot: Bool,
    indexInParent: Int?,
    into rows: inout [JSONFlatRow]
) {
    rows.append(.node(node, parent: parent, depth: depth, isRoot: isRoot, indexInParent: indexInParent))
    if (node.kind == .object || node.kind == .array) && node.isExpanded {
        for (i, child) in node.children.enumerated() {
            flattenJSONTree(child, parent: node, depth: depth + 1, isRoot: false, indexInParent: i, into: &rows)
        }
        rows.append(.addChild(parent: node, depth: depth + 1))
    }
}

struct JSONTreeView: View {
    @Bindable var root: JSONNode
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattened) { row in
                    switch row {
                    case .node(let node, let parent, let depth, let isRoot, let indexInParent):
                        JSONRowView(
                            node: node,
                            parent: parent,
                            depth: depth,
                            isRoot: isRoot,
                            indexInParent: indexInParent,
                            onEdit: onEdit
                        )
                    case .addChild(let parent, let depth):
                        AddChildRow(parent: parent, depth: depth, onEdit: onEdit)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var flattened: [JSONFlatRow] {
        var rows: [JSONFlatRow] = []
        flattenJSONTree(root, parent: nil, depth: 0, isRoot: true, indexInParent: nil, into: &rows)
        return rows
    }
}

private struct JSONRowView: View {
    @Bindable var node: JSONNode
    let parent: JSONNode?
    let depth: Int
    let isRoot: Bool
    let indexInParent: Int?
    let onEdit: () -> Void

    @State private var hover = false
    @State private var showJSONSheet = false
    // Click-to-edit: TextFields are expensive on macOS (each one bridges to
    // NSTextField). LazyVStack re-creates rows as they scroll into view, so
    // showing TextField unconditionally was the dominant scroll-time cost.
    // We render `Text` by default and only swap in `TextField` when the cell
    // is actually being edited.
    @State private var editingKey = false
    @State private var editingString = false
    @State private var editingNumber = false

    private var isContainer: Bool { node.kind == .object || node.kind == .array }

    var body: some View {
        HStack(spacing: 6) {
            // Depth indent
            Color.clear
                .frame(width: CGFloat(depth) * 16, height: 1)

            // Disclosure or spacer
            if isContainer {
                Button {
                    node.isExpanded.toggle()
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 22, height: 1)
            }

            keyLabel
            if !isRoot {
                Text(":")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
                typeBadge
            }
            valueView

            Spacer(minLength: 4)

            if hover {
                trailingActions
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .background(hover ? Color.gray.opacity(0.08) : Color.clear)
        .contextMenu { contextMenuItems }
        .sheet(isPresented: $showJSONSheet) {
            EmbeddedJSONSheet(stringValue: Binding(
                get: { node.stringValue },
                set: { node.stringValue = $0; onEdit() }
            ))
        }
    }

    @ViewBuilder
    private var keyLabel: some View {
        if isRoot {
            Text("root")
                .foregroundStyle(.secondary)
                .italic()
                .font(.system(.body, design: .monospaced))
        } else if parent?.kind == .object {
            if editingKey {
                EditableKeyField(node: node, onEdit: onEdit) { editingKey = false }
            } else {
                Text(node.key?.isEmpty == false ? node.key! : "\"\"")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 160, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editingKey = true }
            }
        } else if parent?.kind == .array, let idx = indexInParent {
            Text("[\(idx)]")
                .foregroundStyle(Color(red: 0.78, green: 0.65, blue: 1.00))
                .font(.system(.body, design: .monospaced))
                .frame(width: 160, alignment: .leading)
        }
    }

    private var typeBadge: some View {
        Text(node.kind.badge)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(node.kind.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(node.kind.accent.opacity(0.15), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(node.kind.accent.opacity(0.35), lineWidth: 0.5))
            .frame(width: 36, alignment: .center)
    }

    @ViewBuilder
    private var valueView: some View {
        switch node.kind {
        case .object:
            Text("{ \(node.children.count) \(node.children.count == 1 ? "key" : "keys") }")
                .foregroundStyle(JSONNode.Kind.object.accent.opacity(0.75))
                .font(.system(.body, design: .monospaced))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { node.isExpanded.toggle() }
        case .array:
            Text("[ \(node.children.count) \(node.children.count == 1 ? "item" : "items") ]")
                .foregroundStyle(JSONNode.Kind.array.accent.opacity(0.75))
                .font(.system(.body, design: .monospaced))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { node.isExpanded.toggle() }
        case .string:
            HStack(spacing: 6) {
                if editingString {
                    EditableStringField(node: node, onEdit: onEdit) { editingString = false }
                } else {
                    Text(node.stringValue.isEmpty ? "\"\"" : node.stringValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(JSONNode.Kind.string.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 420, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { editingString = true }
                }

                if node.isJSONLikeString {
                    Button { showJSONSheet = true } label: {
                        HStack(spacing: 4) {
                            Text("{ }")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(JSONNode.Kind.object.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(JSONNode.Kind.object.accent.opacity(0.15), in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).strokeBorder(JSONNode.Kind.object.accent.opacity(0.35), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Edit as JSON")
                }
            }
        case .number:
            if editingNumber {
                EditableNumberField(node: node, onEdit: onEdit) { editingNumber = false }
            } else {
                let valid = node.numberValue.isEmpty || Double(node.numberValue) != nil
                Text(node.numberValue.isEmpty ? "0" : node.numberValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(valid ? JSONNode.Kind.number.accent : Color.red)
                    .frame(width: 420, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editingNumber = true }
            }
        case .bool:
            Toggle("", isOn: Binding(
                get: { node.boolValue },
                set: { node.boolValue = $0; onEdit() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(JSONNode.Kind.bool.accent)
            .frame(width: 420, alignment: .leading)
        case .null:
            Text("null")
                .foregroundStyle(JSONNode.Kind.null.accent)
                .italic()
                .font(.system(.body, design: .monospaced))
                .frame(width: 420, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if isContainer {
            Button {
                _ = node.appendChild()
                node.isExpanded = true
                onEdit()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add child")
        }
        if !isRoot {
            Button { delete() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isContainer {
            Button("Add Child") {
                _ = node.appendChild()
                node.isExpanded = true
                onEdit()
            }
        }
        Menu("Change Type") {
            ForEach(JSONNode.Kind.allCases) { k in
                Button(k.displayName) { changeType(to: k) }
                    .disabled(k == node.kind)
            }
        }
        if !isRoot {
            Divider()
            Button("Duplicate") { duplicate() }
            Button("Delete", role: .destructive) { delete() }
        }
    }

    private func delete() {
        guard let parent else { return }
        parent.children.removeAll { $0.id == node.id }
        onEdit()
    }

    private func duplicate() {
        guard let parent,
              let idx = parent.children.firstIndex(where: { $0.id == node.id })
        else { return }
        parent.children.insert(node.deepCopy(), at: idx + 1)
        onEdit()
    }

    private func changeType(to k: JSONNode.Kind) {
        node.kind = k
        if k != .object && k != .array {
            node.children = []
        }
        onEdit()
    }
}

// MARK: - Lazy editable fields
//
// These exist so the heavy `TextField` is only constructed for the one cell
// actually being edited. The parent row renders cheap `Text` views otherwise,
// which keeps `LazyVStack` scroll-time row creation fast.

private struct EditableKeyField: View {
    @Bindable var node: JSONNode
    let onEdit: () -> Void
    let exit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("key", text: Binding(
            get: { node.key ?? "" },
            set: { node.key = $0; onEdit() }
        ))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.95))
        .frame(width: 160)
        .focused($focused)
        .onAppear { focused = true }
        .onSubmit { exit() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { exit() }
        }
    }
}

private struct EditableStringField: View {
    @Bindable var node: JSONNode
    let onEdit: () -> Void
    let exit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: Binding(
            get: { node.stringValue },
            set: { node.stringValue = $0; onEdit() }
        ), axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.system(.body, design: .monospaced))
        .lineLimit(1...4)
        .foregroundStyle(JSONNode.Kind.string.accent)
        .frame(width: 420, alignment: .leading)
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { exit() }
        }
    }
}

private struct EditableNumberField: View {
    @Bindable var node: JSONNode
    let onEdit: () -> Void
    let exit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let valid = node.numberValue.isEmpty || Double(node.numberValue) != nil
        TextField("0", text: Binding(
            get: { node.numberValue },
            set: { node.numberValue = $0; onEdit() }
        ))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.system(.body, design: .monospaced))
        .frame(width: 420, alignment: .leading)
        .foregroundStyle(valid ? JSONNode.Kind.number.accent : Color.red)
        .focused($focused)
        .onAppear { focused = true }
        .onSubmit { exit() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { exit() }
        }
    }
}

private struct AddChildRow: View {
    @Bindable var parent: JSONNode
    let depth: Int
    let onEdit: () -> Void

    @State private var hover = false

    var body: some View {
        Button {
            _ = parent.appendChild()
            onEdit()
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * 16 + 22, height: 1)
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text(parent.kind == .object ? "Add key" : "Add item")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hover ? Color.gray.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Embedded JSON sheet
//
// Opens when a string value parses as a JSON object/array. The sheet edits the
// embedded JSON via the same Tree/Text editor as the top-level view, then
// writes the serialized result back to the parent string binding on Save.

private struct EmbeddedJSONSheet: View {
    @Binding var stringValue: String
    @Environment(\.dismiss) private var dismiss

    @State private var root: JSONNode = JSONNode(kind: .object)
    @State private var rawText: String = ""
    @State private var mode: JSONEditor.Mode = .tree
    @State private var jsonError: String?
    @State private var initialized = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let err = jsonError {
                errorBar(err)
            }
            Group {
                if mode == .tree {
                    JSONTreeView(root: root, onEdit: validateTree)
                } else {
                    JSONCodeEditor(text: $rawText)
                        .onChange(of: rawText) { _, _ in validateText() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 880, idealWidth: 960, minHeight: 540, idealHeight: 620)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            rawText = JSONEditor.prettyPrint(stringValue) ?? stringValue
            if let parsed = try? JSONNode.parse(rawText) {
                root = parsed
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .foregroundStyle(JSONNode.Kind.object.accent)
            Text("Edit JSON String")
                .font(.headline)
            Spacer()
            Picker("", selection: $mode) {
                ForEach(JSONEditor.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: mode) { old, new in switchMode(from: old, to: new) }

            if mode == .text {
                Button { formatText() } label: {
                    Label("Format", systemImage: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button { setAllExpanded(true) } label: {
                    Label("Expand All", systemImage: "chevron.down.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button { setAllExpanded(false) } label: {
                    Label("Collapse All", systemImage: "chevron.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(jsonError != nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func errorBar(_ err: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
    }

    private func switchMode(from old: JSONEditor.Mode, to new: JSONEditor.Mode) {
        guard old != new else { return }
        if old == .tree && new == .text {
            rawText = JSONEditor.serialize(root) ?? rawText
            validateText()
        } else if old == .text && new == .tree {
            if let parsed = try? JSONNode.parse(rawText) {
                root = parsed
                jsonError = nil
            } else {
                jsonError = "Invalid JSON — fix before switching to Tree"
                DispatchQueue.main.async { mode = .text }
            }
        }
    }

    private func save() {
        let payload: String
        if mode == .tree {
            guard let s = JSONEditor.serialize(root) else {
                jsonError = "Invalid JSON"
                return
            }
            payload = s
        } else {
            guard let data = rawText.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
            else {
                jsonError = "Invalid JSON"
                return
            }
            payload = rawText
        }
        stringValue = payload
        dismiss()
    }

    private func formatText() {
        if let pretty = JSONEditor.prettyPrint(rawText) {
            rawText = pretty
            validateText()
        }
    }

    private func validateText() {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { jsonError = nil; return }
        guard let data = rawText.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
        else {
            jsonError = "Invalid JSON"
            return
        }
        jsonError = nil
    }

    private func validateTree() {
        jsonError = JSONEditor.findInvalidNumber(in: root) ? "Invalid number" : nil
    }

    private func setAllExpanded(_ expanded: Bool) {
        setExpanded(root, expanded)
    }

    private func setExpanded(_ node: JSONNode, _ expanded: Bool) {
        if node.kind == .object || node.kind == .array {
            node.isExpanded = expanded
            node.children.forEach { setExpanded($0, expanded) }
        }
    }
}
