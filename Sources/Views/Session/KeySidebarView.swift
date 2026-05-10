import SwiftUI
import AppKit

/// Left sidebar of the session window — Command Query button, grouped key
/// tree, DB switcher. Search / filter / reload / "+" live in the window
/// toolbar (see `RootView.swift`) so we get native macOS chrome.
struct KeySidebarView: View {
    @Bindable var session: RedisSession
    /// Ids of expanded folders. We own the expansion state ourselves so
    /// the row body (not just the chevron) can toggle on click — and
    /// keep DisclosureGroup's built-in chevron-rotation + slide animation.
    @State private var expandedFolders: Set<String> = []
    /// The List's visual selection. May be a key name *or* a folder id —
    /// we accept both so folders stay visually selected after a click,
    /// instead of flashing back to the previous leaf when the binding
    /// rejects the folder id. Detail pane still keys off
    /// `session.selectedKey`, which we only update for leaf clicks.
    @State private var listSelection: String?

    var body: some View {
        VStack(spacing: 0) {
            terminalRow
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            scannedHeader
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            keyTreeList

            Divider()
            dbBar
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        // Keep the visual selection in sync if `selectedKey` changes
        // outside the sidebar (delete, terminal button, key rename, etc.).
        .onChange(of: session.selectedKey, initial: true) { _, newValue in
            listSelection = newValue
        }
    }

    private var terminalRow: some View {
        Button {
            session.commandQueryActive = true
            session.selectedKey = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text("Command Query")
                    .font(.callout)
                Spacer()
            }
            .foregroundStyle(session.commandQueryActive ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                session.commandQueryActive ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var scannedHeader: some View {
        HStack {
            Text("KEYS (\(session.keys.count) SCANNED)")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Tree list

    private var keyTreeList: some View {
        let nodes = KeyTreeNode.build(from: filteredKeys)

        // The List binding's *getter* drives the visual highlight. If we
        // returned `session.selectedKey`, SwiftUI would snap the
        // highlight back to the previous leaf right after the user
        // clicks a folder (a brief "selected → unselected" flash).
        // Instead, we own a separate `listSelection` that simply
        // remembers the most recent click — leaf or folder. The setter
        // then routes:
        //   leaf id   → write `session.selectedKey` (drives DetailView)
        //   folder id → toggle expansion only (DetailView unchanged)
        let keyNames = Set(session.keys.map(\.name))
        let selection = Binding<String?>(
            get: { listSelection },
            set: { newValue in
                listSelection = newValue
                guard let v = newValue else {
                    session.selectedKey = nil
                    return
                }
                if keyNames.contains(v) {
                    session.selectedKey = v
                    session.commandQueryActive = false
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expandedFolders.contains(v) {
                            expandedFolders.remove(v)
                        } else {
                            expandedFolders.insert(v)
                        }
                    }
                }
            }
        )

        return List(selection: selection) {
            KeyTreeContent(
                nodes: nodes,
                session: session,
                expandedFolders: $expandedFolders
            )

            if !session.scanFinished {
                Button {
                    Task { await session.loadMoreKeys() }
                } label: {
                    HStack {
                        Spacer()
                        Text("Load more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    private var filteredKeys: [RedisKey] {
        guard let f = session.typeFilter else { return session.keys }
        return session.keys.filter { $0.type == f }
    }

    // MARK: - DB bar

    private var dbBar: some View {
        HStack {
            Spacer()
            Picker("DB", selection: Binding(
                get: { session.currentDB },
                set: { newDB in Task { await session.switchDB(to: newDB) } }
            )) {
                ForEach(0..<session.availableDBs, id: \.self) { i in
                    Text("DB \(i)").tag(i)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Text("(\(session.dbSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

struct NewKeyDialog: Identifiable {
    let id = UUID()
    let type: RedisKeyType
}

// MARK: - Rows

/// Recursive renderer for the key tree. Uses `DisclosureGroup` so we
/// keep the native chevron-rotation + content-slide animation, but
/// drives the binding from a parent-owned `Set<String>` of expanded
/// ids so a tap anywhere on the folder row toggles — not just the
/// chevron's hit zone.
private struct KeyTreeContent: View {
    let nodes: [KeyTreeNode]
    let session: RedisSession
    @Binding var expandedFolders: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if let key = node.key {
                KeyTreeRow(node: node, key: key)
                    .tag(Optional(key.name))
                    .contextMenu {
                        Button("Copy Key Name") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(key.name, forType: .string)
                        }
                        Button("Delete", role: .destructive) {
                            Task {
                                _ = try? await session.service.delete([key.name])
                                await session.reloadKeys()
                            }
                        }
                    }
            } else if let children = node.children {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedFolders.contains(node.id) },
                        set: { isOpen in
                            if isOpen {
                                expandedFolders.insert(node.id)
                            } else {
                                expandedFolders.remove(node.id)
                            }
                        }
                    )
                ) {
                    KeyTreeContent(
                        nodes: children,
                        session: session,
                        expandedFolders: $expandedFolders
                    )
                } label: {
                    // Plain row — taps anywhere are routed to the List's
                    // selection setter, which we repurpose as a toggle for
                    // folder ids. Chevron click stays on the built-in
                    // DisclosureGroup path (it won't fire selection too —
                    // the chevron's button consumes the event).
                    KeyGroupRow(node: node)
                }
            }
        }
    }
}

private struct KeyTreeRow: View {
    let node: KeyTreeNode
    let key: RedisKey

    var body: some View {
        HStack(spacing: 6) {
            TypeBadge(type: key.type, compact: true)
            // `node.label` is the tail after the enclosing folder's prefix
            // (e.g. `c` inside `a > b`), or the full key name at the root.
            Text(node.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let ttl = key.ttl, ttl > 0 {
                Text(formatTTL(ttl))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatTTL(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

private struct KeyGroupRow: View {
    let node: KeyTreeNode

    var body: some View {
        HStack(spacing: 6) {
            // Gives the folder row the same vertical mass as leaf rows
            // (which carry a TypeBadge), so SwiftUI's OutlineGroup centers
            // the disclosure triangle at the same height for both.
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(node.label)
                .lineLimit(1)
            Spacer()
            Text("\(node.keyCount) keys")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct NewKeySheet: View {
    let initialType: RedisKeyType
    let onCreate: (String, RedisKeyType) -> Void
    @State private var name = ""
    @State private var type: RedisKeyType
    @Environment(\.dismiss) private var dismiss

    init(initialType: RedisKeyType, onCreate: @escaping (String, RedisKeyType) -> Void) {
        self.initialType = initialType
        self.onCreate = onCreate
        self._type = State(initialValue: initialType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Key").font(.headline)
            Form {
                TextField("Key name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach([RedisKeyType.string, .hash, .list, .set, .zset], id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(name, type)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Native search field

/// SwiftUI's `.searchable` always renders in the trailing toolbar slot on
/// macOS — there's no API to move it leading. To put a native search field
/// next to the title we wrap `NSSearchField` directly. The bonus is that
/// NSSearchField gives us the magnifier-icon menu (`searchMenuTemplate`)
/// for free, which we use as the type filter.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var typeFilter: RedisKeyType?
    var prompt: String
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.searchMenuTemplate = context.coordinator.makeMenu()
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = prompt
        // Rebuild so checkmarks reflect the current `typeFilter`.
        field.searchMenuTemplate = context.coordinator.makeMenu()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.onSubmit()
        }

        @objc func selectAllTypes(_ sender: NSMenuItem) {
            parent.typeFilter = nil
        }

        @objc func selectType(_ sender: NSMenuItem) {
            if let raw = sender.representedObject as? String,
               let t = RedisKeyType(rawValue: raw) {
                parent.typeFilter = t
            }
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            let all = NSMenuItem(
                title: "All Types",
                action: #selector(selectAllTypes(_:)),
                keyEquivalent: ""
            )
            all.target = self
            all.state = (parent.typeFilter == nil) ? .on : .off
            menu.addItem(all)
            menu.addItem(.separator())
            for t in [RedisKeyType.string, .hash, .list, .set, .zset, .stream] {
                let item = NSMenuItem(
                    title: t.displayName,
                    action: #selector(selectType(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = t.rawValue
                item.state = (parent.typeFilter == t) ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
    }
}
