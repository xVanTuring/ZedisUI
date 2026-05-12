import SwiftUI

struct StringEditor: View {
    let session: RedisSession
    let key: String

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text"
        case tree = "Tree"
        var id: String { rawValue }
    }

    @State private var value: String = ""
    @State private var loaded = false
    @State private var dirty = false
    @State private var mode: Mode = .text
    @State private var root: JSONNode = JSONNode(kind: .object)
    @State private var jsonError: String?

    // Recomputed reactively; cheap because looksLikeJSONContainer prefilters.
    private var canEditAsJSON: Bool { isJSONObjectOrArrayString(value) }
    private var showsToolbar: Bool { canEditAsJSON || mode == .tree }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if showsToolbar {
                    toolbar
                    Divider()
                }
                if let err = jsonError {
                    errorBar(err)
                }
                Group {
                    if mode == .tree {
                        JSONTreeView(root: root, onEdit: treeEdited)
                    } else {
                        textEditor
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if dirty {
                Button {
                    Task { await save() }
                } label: {
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
            Button("save", action: { Task { await save() } })
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .task(id: key) { await load() }
    }

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

            // Subtle "JSON detected" badge so users know why the toolbar showed up.
            if canEditAsJSON {
                Label("JSON", systemImage: "curlybraces")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JSONNode.Kind.object.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(JSONNode.Kind.object.accent.opacity(0.12), in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(JSONNode.Kind.object.accent.opacity(0.3), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var textEditor: some View {
        JSONCodeEditor(text: $value)
            .onChange(of: value) { _, _ in if loaded { dirty = true } }
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

    // MARK: Tree <-> Text

    // Called after any tree-side edit. Re-serialize and push back into `value`
    // so a single source of truth is preserved and Save just writes `value`.
    private func treeEdited() {
        guard loaded else { return }
        if JSONEditor.findInvalidNumber(in: root) {
            jsonError = "Invalid number"
            return
        }
        jsonError = nil
        if let s = JSONEditor.serialize(root) {
            value = s
            dirty = true
        }
    }

    private func switchMode(from old: Mode, to new: Mode) {
        guard old != new else { return }
        if old == .text && new == .tree {
            guard let parsed = try? JSONNode.parse(value),
                  parsed.kind == .object || parsed.kind == .array
            else {
                jsonError = "Invalid JSON — fix before switching to Tree"
                DispatchQueue.main.async { mode = .text }
                return
            }
            root = parsed
            jsonError = nil
        } else if old == .tree && new == .text {
            if let pretty = JSONEditor.prettyPrint(value) {
                value = pretty
            }
            jsonError = nil
        }
    }

    private func formatText() {
        if let pretty = JSONEditor.prettyPrint(value) {
            value = pretty
        }
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

    // MARK: Load / Save

    private func load() async {
        loaded = false
        let v = (try? await session.service.getString(key)) ?? ""
        // Pretty-print JSON content on load for readability. Doesn't mark dirty
        // because `loaded` is still false when value changes here.
        if isJSONObjectOrArrayString(v), let pretty = JSONEditor.prettyPrint(v) {
            value = pretty
        } else {
            value = v
        }
        if let parsed = try? JSONNode.parse(value) {
            root = parsed
        }
        dirty = false
        jsonError = nil
        mode = .text
        loaded = true
        session.inspectorTarget = InspectorTarget(
            kind: .string,
            key: key,
            primary: "",
            secondary: v
        )
    }

    private func save() async {
        guard dirty, jsonError == nil else { return }
        do {
            try await session.service.setString(key, value: value)
            dirty = false
        } catch { /* surfaced via session.status */ }
    }
}
