import SwiftUI

struct ListEditor: View {
    let session: RedisSession
    let key: String

    @State private var items: [Item] = []
    @State private var selection: Item.ID?
    @State private var newValue = ""
    @State private var pushHead = false

    struct Item: Identifiable, Hashable {
        let id = UUID()
        var index: Int
        var value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(items, selection: $selection) {
                TableColumn("#") { item in
                    Text(String(item.index))
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 40, ideal: 50, max: 80)
                TableColumn("Value") { item in
                    Text(item.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: Item.ID.self) { selected in
                if let id = selected.first, let item = items.first(where: { $0.id == id }) {
                    Button("Edit…") { editTarget = item }
                    Button("Delete", role: .destructive) {
                        Task {
                            try? await session.service.lremByIndex(key, index: item.index)
                            await load()
                        }
                    }
                }
            } primaryAction: { selected in
                if let id = selected.first, let item = items.first(where: { $0.id == id }) {
                    editTarget = item
                }
            }

            Divider()
            HStack {
                TextField("New value", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $pushHead) {
                    Text("RPUSH (tail)").tag(false)
                    Text("LPUSH (head)").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Button("Push") {
                    Task { await push() }
                }
                .keyboardShortcut(.return)
                .disabled(newValue.isEmpty)
            }
            .padding(8)
        }
        .task(id: key) { await load() }
        .onChange(of: selection) { _, newValue in
            if let id = newValue, let item = items.first(where: { $0.id == id }) {
                session.inspectorTarget = InspectorTarget(
                    kind: .listIndex,
                    key: key,
                    primary: String(item.index),
                    secondary: item.value
                )
            } else {
                session.inspectorTarget = nil
            }
        }
        .onChange(of: key) { _, _ in
            selection = nil
            session.inspectorTarget = nil
        }
        .onChange(of: session.dataVersion) { _, _ in
            Task { await load() }
        }
        .sheet(item: $editTarget) { item in
            ListItemEditSheet(title: "Edit list item #\(item.index)", initial: item.value) { v in
                Task {
                    try? await session.service.lset(key, index: item.index, value: v)
                    await load()
                }
            }
        }
    }

    @State private var editTarget: Item?

    private func load() async {
        let raw = (try? await session.service.lrange(key)) ?? []
        items = raw.enumerated().map { Item(index: $0.offset, value: $0.element) }
    }

    private func push() async {
        let v = newValue
        if pushHead {
            try? await session.service.lpush(key, value: v)
        } else {
            try? await session.service.rpush(key, value: v)
        }
        newValue = ""
        await load()
    }
}

struct ListItemEditSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        self._draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
