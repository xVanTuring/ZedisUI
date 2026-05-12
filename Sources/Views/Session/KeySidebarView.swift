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
    /// Text-field draft for the DB number at the bottom of the sidebar.
    /// Synced to `session.currentDB` on appear / external change and
    /// committed back via `switchDB` on Enter or stepper click. Kept as
    /// its own state so a half-typed number doesn't cause spurious
    /// SELECTs on every keystroke.
    @State private var dbDraft: Int = 0
    @FocusState private var dbFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar-hosted instead of the toolbar `.principal` slot
            // because macOS NSToolbar's principal placement doesn't
            // stretch to fill horizontal space — see commit history.
            // SwiftUI's natural VStack layout gives this true flex width
            // tied to the sidebar column.
            NativeSearchField(
                text: $session.pattern,
                typeFilter: $session.typeFilter,
                prompt: "Search keys",
                jsonSupported: session.jsonSupported
            ) {
                Task { await session.reloadKeys() }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            terminalRow
                .padding(.horizontal, 10)
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
        // After a reload (e.g. user searched and the previously selected
        // key is no longer in the result set), drop the stale list
        // highlight so List doesn't try to render a row that isn't in
        // the data — that's what produces the phantom rows.
        .onChange(of: session.reloadEpoch) { _, _ in
            if let sel = listSelection,
               !session.keys.contains(where: { $0.name == sel }),
               !expandedFolders.contains(sel) {
                listSelection = nil
            }
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
        // Bumped by RedisSession on every reloadKeys; combined with the
        // listSelection cleanup above, this forces SwiftUI to discard any
        // cached row views that don't correspond to the new key set.
        .id(session.reloadEpoch)
    }

    private var filteredKeys: [RedisKey] {
        let f = session.typeFilter
        guard !f.isEmpty else { return session.keys }
        return session.keys.filter { f.contains($0.type) }
    }

    // MARK: - DB bar

    /// DB switcher. A menu picker with 16 entries is fine; with 256
    /// (the Redis default) it's unusable, so we switched to a small
    /// editable field with stepper arrows. The text field commits on
    /// Enter (or focus loss); the stepper commits each click. Both
    /// run through `switchDB` so the rest of the session state stays
    /// consistent.
    private var dbBar: some View {
        let maxDB = max(0, session.availableDBs - 1)
        let stepperBinding = Binding<Int>(
            get: { session.currentDB },
            set: { newDB in
                let clamped = min(max(newDB, 0), maxDB)
                dbDraft = clamped
                Task { await session.switchDB(to: clamped) }
            }
        )

        return HStack(spacing: 6) {
            Spacer()
            Text("DB")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("", value: $dbDraft, formatter: dbFormatter(max: maxDB))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($dbFieldFocused)
                .onSubmit { commitDBDraft(maxDB: maxDB) }
            Stepper("", value: stepperBinding, in: 0...maxDB)
                .labelsHidden()
            Text("(\(session.dbSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .onAppear { dbDraft = session.currentDB }
        .onChange(of: session.currentDB) { _, new in
            // Mirror back into the field unless the user is mid-edit;
            // overwriting their draft mid-typing would be jarring.
            if !dbFieldFocused { dbDraft = new }
        }
    }

    private func commitDBDraft(maxDB: Int) {
        let target = min(max(dbDraft, 0), maxDB)
        dbDraft = target
        if target != session.currentDB {
            Task { await session.switchDB(to: target) }
        }
        dbFieldFocused = false
    }

    private func dbFormatter(max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 0
        f.maximum = NSNumber(value: max)
        return f
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
    let jsonSupported: Bool
    let onCreate: (String, RedisKeyType) -> Void
    @State private var name = ""
    @State private var type: RedisKeyType
    @Environment(\.dismiss) private var dismiss

    init(initialType: RedisKeyType, jsonSupported: Bool = false, onCreate: @escaping (String, RedisKeyType) -> Void) {
        self.initialType = initialType
        self.jsonSupported = jsonSupported
        self.onCreate = onCreate
        self._type = State(initialValue: initialType)
    }

    private var availableTypes: [RedisKeyType] {
        RedisKeyType.creatable(includeJSON: jsonSupported)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Key").font(.headline)
            Form {
                TextField("Key name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach(availableTypes, id: \.self) { t in
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
    @Binding var typeFilter: Set<RedisKeyType>
    var prompt: String
    var jsonSupported: Bool = false
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = WideHitSearchField()
        field.placeholderString = prompt
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        // NSTextFieldCell defaults to `isScrollable = false`, which means
        // once the typed string outgrows the visible width the editor
        // simply clips it — cursor can't follow past the right edge and
        // arrow keys feel broken. Single-line + scrollable + no-wrap is
        // the standard combo that lets the field editor scroll its
        // content horizontally as the cursor moves.
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
            cell.lineBreakMode = .byClipping
        }
        field.searchMenuTemplate = context.coordinator.makeMenu()
        // Capture the system-supplied magnifier-with-chevron image now,
        // _after_ assigning a menu (NSSearchField swaps between with-arrow
        // and without-arrow variants based on whether a menu exists).
        if let cell = field.cell as? NSSearchFieldCell {
            context.coordinator.defaultIcon = cell.searchButtonCell?.image
        }
        applySearchIcon(to: field, active: !typeFilter.isEmpty,
                        defaultIcon: context.coordinator.defaultIcon)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
        }
        // Only rebuild the menu / re-tint the icon when filter state
        // actually changes. Doing this on every keystroke poked the
        // search field's internal editor and broke horizontal cursor
        // scrolling once the typed string got longer than the field.
        if coord.lastTypeFilter != typeFilter || coord.lastJsonSupported != jsonSupported {
            field.searchMenuTemplate = coord.makeMenu()
            applySearchIcon(to: field, active: !typeFilter.isEmpty,
                            defaultIcon: coord.defaultIcon)
            coord.lastTypeFilter = typeFilter
            coord.lastJsonSupported = jsonSupported
        }
    }

    /// Keep AppKit's default magnifier+chevron glyph (so users still see
    /// the dropdown affordance), but tint it with the accent color when
    /// any type filter is active.
    private func applySearchIcon(to field: NSSearchField, active: Bool, defaultIcon: NSImage?) {
        guard let cell = field.cell as? NSSearchFieldCell,
              let button = cell.searchButtonCell,
              let base = defaultIcon
        else { return }
        if active {
            button.image = base.tinted(with: .controlAccentColor)
        } else {
            button.image = base
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        /// AppKit's stock search-button image, captured once at view
        /// creation. Tinted copies are derived from this; the original is
        /// re-applied when the filter clears.
        var defaultIcon: NSImage?
        /// Last seen filter state — used in `updateNSView` to skip menu /
        /// icon work when nothing relevant changed. Initialized to a
        /// sentinel that forces the first update to run.
        var lastTypeFilter: Set<RedisKeyType> = []
        var lastJsonSupported: Bool = false
        init(_ parent: NativeSearchField) {
            self.parent = parent
            self.lastTypeFilter = parent.typeFilter
            self.lastJsonSupported = parent.jsonSupported
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.onSubmit()
        }

        @objc func clearTypes(_ sender: NSMenuItem) {
            parent.typeFilter = []
        }

        @objc func toggleType(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let t = RedisKeyType(rawValue: raw)
            else { return }
            if parent.typeFilter.contains(t) {
                parent.typeFilter.remove(t)
            } else {
                parent.typeFilter.insert(t)
            }
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            // NSSearchField only calls actions on autoenabled items, so
            // disabling them when the set is empty would also kill the
            // click. Keep enabled; the action is a no-op when nothing
            // is selected — there's no harm.
            menu.autoenablesItems = false

            let clear = NSMenuItem(
                title: "Clear Filter",
                action: #selector(clearTypes(_:)),
                keyEquivalent: ""
            )
            clear.target = self
            clear.isEnabled = !parent.typeFilter.isEmpty
            menu.addItem(clear)
            menu.addItem(.separator())

            for t in RedisKeyType.filterable(includeJSON: parent.jsonSupported) {
                let item = NSMenuItem(
                    title: t.displayName,
                    action: #selector(toggleType(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = t.rawValue
                item.state = parent.typeFilter.contains(t) ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
    }
}

/// NSSearchFieldCell subclass that widens the search-button hit rect (the
/// magnifier + chevron area) without enlarging the glyph itself, so the
/// dropdown menu is easier to click. Pairs with `WideHitSearchField`.
///
/// Asymmetric padding: extra room on the left grows into the bezel margin
/// (free, invisible space), while right-side growth becomes the visible
/// gap before the text — keep it small. AppKit derives `searchTextRect`
/// from our overridden button rect, so we deliberately do _not_ override
/// `searchTextRect` here; doing so used to double-count the padding and
/// broke text-field cursor scrolling once the input got long.
private final class WideHitSearchFieldCell: NSSearchFieldCell {
    private static let padLeft: CGFloat = 8
    private static let padRight: CGFloat = 3

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchButtonRect(forBounds: rect)
        r.origin.x = max(rect.minX, r.origin.x - Self.padLeft)
        r.size.width += Self.padLeft + Self.padRight
        return r
    }
}

/// Marker NSSearchField subclass so AppKit instantiates our wider-hit
/// cell during `init`. `cellClass` is the documented hook for this; we
/// keep the setter accepting (ignored) writes for API compatibility.
private final class WideHitSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { WideHitSearchFieldCell.self }
        set { _ = newValue }
    }
}

private extension NSImage {
    /// Composite an opaque tint over the template-image alpha mask. Used
    /// to colorize the search-button glyph without altering its shape.
    func tinted(with color: NSColor) -> NSImage {
        let copy = NSImage(size: size)
        copy.lockFocus()
        defer { copy.unlockFocus() }
        let rect = NSRect(origin: .zero, size: size)
        self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
        copy.isTemplate = false
        return copy
    }
}
