import SwiftUI

struct HashEditor: View {
    let session: RedisSession
    let key: String

    @State private var rows: [HashRow] = []
    @State private var seenFields: Set<String> = []
    @State private var cursor: Int = 0
    @State private var totalLength: Int = 0
    @State private var loading: Bool = false
    @State private var selection: HashRow.ID?
    @State private var newField = ""
    @State private var newValue = ""

    @State private var query: String = ""
    @State private var mode: SearchMode = .contain

    private let pageSize = 200

    /// In search mode each cursor step may return zero matches, so we
    /// auto-loop until either we've collected this many or the cursor
    /// returns to 0. Caps memory and keeps the UI responsive.
    private let searchBatchTarget = 200

    struct HashRow: Identifiable, Hashable {
        let id = UUID()
        var field: String
        var value: String
    }

    private var searching: Bool { !query.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            EditorSearchBar(query: $query, mode: $mode, placeholder: "Search fields…")

            header

            Table(rows, selection: $selection) {
                TableColumn("Field") { row in
                    Text(row.field)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 100, ideal: 200)
                TableColumn("Value") { row in
                    Text(row.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: HashRow.ID.self) { selected in
                if let id = selected.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Edit Value…") { editRow(row) }
                    Button("Delete", role: .destructive) {
                        Task { await deleteField(row.field) }
                    }
                }
            } primaryAction: { selected in
                if let id = selected.first, let row = rows.first(where: { $0.id == id }) {
                    editRow(row)
                }
            }

            if cursor != 0 {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        Task { await loadMore() }
                    } label: {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(loadMoreLabel)
                        }
                    }
                    .disabled(loading)
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Divider()
            HStack {
                TextField("Field", text: $newField)
                    .textFieldStyle(.roundedBorder)
                TextField("Value", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    Task { await addField() }
                }
                .keyboardShortcut(.return)
                .disabled(newField.isEmpty)
            }
            .padding(8)
        }
        .task(id: key) { await reload() }
        // Search reruns only when the user commits a query (Enter or
        // clear) or changes mode. Editing the text mid-keystroke doesn't
        // re-query — the search bar commits `query` on submit.
        .onChange(of: query) { _, _ in Task { await reload() } }
        .onChange(of: mode) { _, _ in
            if !query.isEmpty { Task { await reload() } }
        }
        .onChange(of: selection) { _, newValue in
            if let id = newValue, let row = rows.first(where: { $0.id == id }) {
                session.inspectorTarget = InspectorTarget(
                    kind: .hashField,
                    key: key,
                    primary: row.field,
                    secondary: row.value
                )
            } else {
                session.inspectorTarget = nil
            }
        }
        .onChange(of: key) { _, _ in
            selection = nil
            session.inspectorTarget = nil
            query = ""
        }
        .onChange(of: session.dataVersion) { _, _ in
            Task { await reload() }
        }
        .sheet(item: $editTarget) { row in
            EditValueSheet(field: row.field, initial: row.value) { newValue in
                Task {
                    try? await session.service.hset(key, field: row.field, value: newValue)
                    await reload()
                }
            }
        }
    }

    @State private var editTarget: HashRow?

    private func editRow(_ row: HashRow) {
        editTarget = row
    }

    private var loadMoreLabel: String {
        if searching {
            return "Load more matches (\(rows.count) so far)"
        } else {
            return "Load more (\(rows.count) of \(totalLength))"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if searching {
                Text("\(rows.count) match\(rows.count == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if cursor != 0 {
                    Text("· scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("· of \(totalLength) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(totalLength) field\(totalLength == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if totalLength > 0 && rows.count < totalLength {
                    Text("· \(rows.count) loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Reset everything and pull the first batch. Used on key switch,
    /// query/mode change, and after any mutation.
    private func reload() async {
        rows = []
        seenFields = []
        cursor = 0
        totalLength = (try? await session.service.hlen(key)) ?? 0
        await loadMore()
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        let pattern = buildGlobPattern(query, mode: mode)
        let startCount = rows.count

        // Browse mode: one HSCAN per click (predictable batch size).
        // Search mode: loop until we hit the target or cursor=0, because
        // each iteration may return zero matches.
        repeat {
            let (next, pairs) = (try? await session.service.hscan(
                key, cursor: cursor, match: pattern, count: pageSize
            )) ?? (0, [])
            for (f, v) in pairs where !seenFields.contains(f) {
                seenFields.insert(f)
                rows.append(HashRow(field: f, value: v))
            }
            cursor = next
            if cursor == 0 { break }
            if !searching { break }
            if rows.count - startCount >= searchBatchTarget { break }
        } while true
    }

    private func addField() async {
        let f = newField, v = newValue
        try? await session.service.hset(key, field: f, value: v)
        newField = ""
        newValue = ""
        await reload()
    }

    private func deleteField(_ field: String) async {
        try? await session.service.hdel(key, field: field)
        await reload()
    }
}

private struct EditValueSheet: View {
    let field: String
    let initial: String
    let onSave: (String) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(field: String, initial: String, onSave: @escaping (String) -> Void) {
        self.field = field
        self.initial = initial
        self.onSave = onSave
        self._draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit value for field “\(field)”")
                .font(.headline)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
