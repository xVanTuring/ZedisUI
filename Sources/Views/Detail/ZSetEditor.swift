import SwiftUI

struct ZSetEditor: View {
    let session: RedisSession
    let key: String

    @State private var entries: [Entry] = []
    @State private var selection: Entry.ID?
    @State private var newMember = ""
    @State private var newScore = "0"

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        var member: String
        var score: Double
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(entries, selection: $selection) {
                TableColumn("Score") { e in
                    Text(formatScore(e.score))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 100, max: 160)
                TableColumn("Member") { e in
                    Text(e.member)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: Entry.ID.self) { selected in
                if let id = selected.first, let e = entries.first(where: { $0.id == id }) {
                    Button("Edit Score…") { editTarget = e }
                    Button("Delete", role: .destructive) {
                        Task {
                            try? await session.service.zrem(key, member: e.member)
                            await load()
                        }
                    }
                }
            }

            Divider()
            HStack {
                TextField("Score", text: $newScore)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                TextField("Member", text: $newMember)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    Task { await add() }
                }
                .keyboardShortcut(.return)
                .disabled(newMember.isEmpty)
            }
            .padding(8)
        }
        .task(id: key) { await load() }
        .onChange(of: selection) { _, newValue in
            if let id = newValue, let e = entries.first(where: { $0.id == id }) {
                session.inspectorTarget = InspectorTarget(
                    kind: .zsetMember,
                    key: key,
                    primary: e.member,
                    secondary: formatScore(e.score)
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
        .sheet(item: $editTarget) { entry in
            ScoreEditSheet(member: entry.member, initial: entry.score) { newScore in
                Task {
                    try? await session.service.zadd(key, member: entry.member, score: newScore)
                    await load()
                }
            }
        }
    }

    @State private var editTarget: Entry?

    private func load() async {
        let raw = (try? await session.service.zrange(key)) ?? []
        entries = raw.map { Entry(member: $0.0, score: $0.1) }
    }

    private func add() async {
        let score = Double(newScore) ?? 0
        try? await session.service.zadd(key, member: newMember, score: score)
        newMember = ""
        newScore = "0"
        await load()
    }

    private func formatScore(_ s: Double) -> String {
        if s.rounded() == s && abs(s) < 1e15 { return String(Int64(s)) }
        return String(s)
    }
}

private struct ScoreEditSheet: View {
    let member: String
    let initial: Double
    let onSave: (Double) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(member: String, initial: Double, onSave: @escaping (Double) -> Void) {
        self.member = member
        self.initial = initial
        self.onSave = onSave
        self._text = State(initialValue: String(initial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Score for “\(member)”").font(.headline)
            TextField("Score", text: $text)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(Double(text) ?? initial)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
