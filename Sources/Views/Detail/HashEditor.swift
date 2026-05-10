import SwiftUI

struct HashEditor: View {
    let session: RedisSession
    let key: String

    @State private var rows: [HashRow] = []
    @State private var selection: HashRow.ID?
    @State private var newField = ""
    @State private var newValue = ""

    struct HashRow: Identifiable, Hashable {
        let id = UUID()
        var field: String
        var value: String
    }

    var body: some View {
        VStack(spacing: 0) {
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
        .task(id: key) { await load() }
        .sheet(item: $editTarget) { row in
            EditValueSheet(field: row.field, initial: row.value) { newValue in
                Task {
                    try? await session.service.hset(key, field: row.field, value: newValue)
                    await load()
                }
            }
        }
    }

    @State private var editTarget: HashRow?

    private func editRow(_ row: HashRow) {
        editTarget = row
    }

    private func load() async {
        let pairs = (try? await session.service.hgetall(key)) ?? []
        rows = pairs.map { HashRow(field: $0.0, value: $0.1) }
    }

    private func addField() async {
        let f = newField, v = newValue
        try? await session.service.hset(key, field: f, value: v)
        newField = ""
        newValue = ""
        await load()
    }

    private func deleteField(_ field: String) async {
        try? await session.service.hdel(key, field: field)
        await load()
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
