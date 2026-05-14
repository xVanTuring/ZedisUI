import SwiftUI

/// Window contents for `WindowID.pubSub`. Subscribes (PSUBSCRIBE) to a
/// channel pattern on a separate connection and renders incoming messages
/// in a Time / Channel / Message table, plus a detail viewer for the
/// selected row.
struct PubSubView: View {
    let connection: Connection
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let controller = appState.pubSubController(for: connection.id) {
                PubSubContent(controller: controller)
            } else {
                ContentUnavailableView(
                    "No Active Session",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("Open the connection from the Connection Manager first — Pub/Sub uses its own connection but needs the session's endpoint.")
                )
            }
        }
        .navigationTitle("Pub/Sub")
        .navigationSubtitle(connection.name)
        .frame(minWidth: 720, minHeight: 540)
    }
}

private struct PubSubContent: View {
    @Bindable var controller: PubSubController

    var body: some View {
        VStack(spacing: 0) {
            messageTable
            Divider()
            detailPane
            footer
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                TextField("Channel pattern", text: $controller.pattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200, idealWidth: 260)
                    .disabled(isRunning)
                    .onSubmit { startIfIdle() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.start()
                } label: {
                    Image(systemName: "play.fill")
                }
                .help("Start subscription")
                .disabled(isRunning || controller.pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop subscription")
                .disabled(!isRunning)
            }
        }
    }

    // MARK: - Message table

    private var messageTable: some View {
        Table(controller.messages, selection: $controller.selectedMessageID) {
            TableColumn("Time") { msg in
                Text(Self.timeFormatter.string(from: msg.timestamp))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 110, ideal: 120, max: 160)

            TableColumn("Channel") { msg in
                Text(msg.channel)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 140, ideal: 200, max: 360)

            TableColumn("Message") { msg in
                Text(msg.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .tableStyle(.inset)
        .frame(minHeight: 180)
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                if effectiveViewerIsJSON {
                    Picker("", selection: $controller.jsonMode) {
                        ForEach(PubSubController.JSONMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Picker("Viewer:", selection: $controller.viewer) {
                    ForEach(PubSubController.ViewerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Encoder:", selection: $controller.encoder) {
                    ForEach(PubSubController.EncoderMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minHeight: 140)
                .background(Color(NSColor.textBackgroundColor))
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let msg = selectedMessage {
            switch effectiveViewer(for: msg) {
            case .plain:
                ScrollView {
                    Text(msg.body)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            case .json:
                switch controller.jsonMode {
                case .text:
                    ScrollView {
                        Text(Self.prettyJSON(msg.body) ?? msg.body)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                case .tree:
                    JSONTreeDetail(payload: msg.body, messageID: msg.id)
                }
            case .hex:
                ScrollView([.horizontal, .vertical]) {
                    Text(Self.hexDump(msg.body))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            case .auto:
                // Should never happen — effectiveViewer collapses .auto.
                EmptyView()
            }
        } else {
            Color.clear
        }
    }

    /// Resolves Viewer for the current selection. `.auto` falls back to
    /// JSON when the body parses, otherwise Plain. Manual Plain / JSON /
    /// Hex picks are honored as-is.
    private func effectiveViewer(for msg: PubSubController.Message) -> PubSubController.ViewerMode {
        switch controller.viewer {
        case .plain, .json, .hex: return controller.viewer
        case .auto:
            return Self.looksLikeJSON(msg.body) ? .json : .plain
        }
    }

    /// True when the body trims to a `{`- or `[`-prefixed payload that
    /// parses cleanly via JSONSerialization. Fragment-allowed parses (raw
    /// strings, numbers) are deliberately rejected — we only auto-switch
    /// for object/array payloads to match Medis's behavior.
    private static func looksLikeJSON(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
    }

    /// True when the detail pane should show the JSON Tree/Text toggle —
    /// either user explicitly picked JSON, or Auto resolved to JSON for
    /// the current selection.
    private var effectiveViewerIsJSON: Bool {
        guard let msg = selectedMessage else { return controller.viewer == .json }
        return effectiveViewer(for: msg) == .json
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                Text("Subscribed to:")
                    .foregroundStyle(.secondary)
                Text(controller.subscribedPattern ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(controller.subscribedPattern == nil ? .secondary : .primary)
                if case .failed(let msg) = controller.status {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(msg)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Button("Clear") {
                controller.clear()
            }
            .disabled(controller.messages.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Helpers

    private var isRunning: Bool {
        switch controller.status {
        case .running, .starting: return true
        case .idle, .failed: return false
        }
    }

    private func startIfIdle() {
        if !isRunning { controller.start() }
    }

    private var selectedMessage: PubSubController.Message? {
        guard let id = controller.selectedMessageID else { return nil }
        return controller.messages.first(where: { $0.id == id })
    }

    private static func prettyJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let str = String(data: pretty, encoding: .utf8)
        else { return nil }
        return str
    }

    /// Classic `hexdump -C` style: 8-char offset, 16 bytes split into two
    /// 8-byte halves with a gap, then the printable-ASCII column. Capped
    /// at 64 KiB so a stray large payload doesn't render millions of
    /// lines into a single Text — anything past gets a truncation note.
    private static func hexDump(_ s: String) -> String {
        let bytes = Array(s.utf8)
        let cap = 64 * 1024
        let limited = bytes.count > cap ? Array(bytes.prefix(cap)) : bytes
        var lines: [String] = []
        var offset = 0
        while offset < limited.count {
            let end = min(offset + 16, limited.count)
            let slice = limited[offset..<end]
            var hexCols: [String] = []
            for i in offset..<offset + 16 {
                if i < end {
                    hexCols.append(String(format: "%02x", limited[i]))
                } else {
                    hexCols.append("  ")
                }
            }
            let leftHex = hexCols[0..<8].joined(separator: " ")
            let rightHex = hexCols[8..<16].joined(separator: " ")
            let ascii = slice.map { byte -> Character in
                (byte >= 0x20 && byte < 0x7f) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(format: "%08x  %@  %@  |%@|",
                                offset, leftHex as NSString, rightHex as NSString, String(ascii) as NSString))
            offset = end
        }
        if bytes.count > cap {
            lines.append("... (truncated, \(bytes.count - cap) more bytes)")
        }
        return lines.joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Read-only JSON tree
//
// Re-parses the message body into a `JSONNode` whenever the selected
// message changes. Renders a stripped-down version of `JSONEditor`'s tree
// — disclosure chevrons stay (they're navigation, not editing) but all
// click-to-edit, hover actions, and context menus are gone.

private struct JSONTreeDetail: View {
    let payload: String
    let messageID: PubSubController.Message.ID

    @State private var root: JSONNode?
    @State private var error: String?

    var body: some View {
        Group {
            if let root {
                JSONReadOnlyTree(root: root)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error ?? "Not valid JSON")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    ScrollView {
                        Text(payload)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.top, 4)
                    }
                }
                .padding(12)
            }
        }
        .task(id: messageID) { reparse() }
    }

    private func reparse() {
        do {
            root = try JSONNode.parse(payload)
            error = nil
        } catch {
            root = nil
            self.error = "Not valid JSON"
        }
    }
}

private struct JSONReadOnlyTree: View {
    @Bindable var root: JSONNode

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattened, id: \.node.id) { row in
                    JSONReadOnlyRow(
                        node: row.node,
                        parent: row.parent,
                        depth: row.depth,
                        isRoot: row.isRoot,
                        indexInParent: row.indexInParent
                    )
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Row {
        let node: JSONNode
        let parent: JSONNode?
        let depth: Int
        let isRoot: Bool
        let indexInParent: Int?
    }

    private var flattened: [Row] {
        var rows: [Row] = []
        flatten(root, parent: nil, depth: 0, isRoot: true, indexInParent: nil, into: &rows)
        return rows
    }

    private func flatten(
        _ node: JSONNode,
        parent: JSONNode?,
        depth: Int,
        isRoot: Bool,
        indexInParent: Int?,
        into rows: inout [Row]
    ) {
        rows.append(Row(node: node, parent: parent, depth: depth, isRoot: isRoot, indexInParent: indexInParent))
        if (node.kind == .object || node.kind == .array) && node.isExpanded {
            for (i, child) in node.children.enumerated() {
                flatten(child, parent: node, depth: depth + 1, isRoot: false, indexInParent: i, into: &rows)
            }
        }
    }
}

private struct JSONReadOnlyRow: View {
    @Bindable var node: JSONNode
    let parent: JSONNode?
    let depth: Int
    let isRoot: Bool
    let indexInParent: Int?

    private var isContainer: Bool { node.kind == .object || node.kind == .array }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 16, height: 1)

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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private var keyLabel: some View {
        if isRoot {
            Text("root")
                .foregroundStyle(.secondary)
                .italic()
                .font(.system(.body, design: .monospaced))
        } else if parent?.kind == .object {
            Text(node.key?.isEmpty == false ? node.key! : "\"\"")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.95))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 160, alignment: .leading)
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
                .contentShape(Rectangle())
                .onTapGesture { node.isExpanded.toggle() }
        case .array:
            Text("[ \(node.children.count) \(node.children.count == 1 ? "item" : "items") ]")
                .foregroundStyle(JSONNode.Kind.array.accent.opacity(0.75))
                .font(.system(.body, design: .monospaced))
                .contentShape(Rectangle())
                .onTapGesture { node.isExpanded.toggle() }
        case .string:
            Text(node.stringValue.isEmpty ? "\"\"" : node.stringValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(JSONNode.Kind.string.accent)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
        case .number:
            Text(node.numberValue.isEmpty ? "0" : node.numberValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(JSONNode.Kind.number.accent)
                .textSelection(.enabled)
        case .bool:
            Text(node.boolValue ? "true" : "false")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(JSONNode.Kind.bool.accent)
        case .null:
            Text("null")
                .foregroundStyle(JSONNode.Kind.null.accent)
                .italic()
                .font(.system(.body, design: .monospaced))
        }
    }
}
