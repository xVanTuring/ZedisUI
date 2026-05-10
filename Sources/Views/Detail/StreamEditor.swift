import SwiftUI
import AppKit

/// Stream viewer. Read-only on the field/value level (in-place edit
/// doesn't have clean Redis semantics for streams), but rows are
/// selectable, the context menu copies the ID / fields, XDEL removes
/// an entry, and the bottom bar opens a sheet to XADD a new one.
struct StreamEditor: View {
    let session: RedisSession
    let key: String

    @State private var entries: [Entry] = []
    @State private var totalLength: Int = 0
    @State private var selection: Entry.ID?
    @State private var showAddSheet = false

    struct Entry: Identifiable, Hashable {
        let id: String
        let fields: [Pair]
    }

    /// Hashable wrapper so SwiftUI can diff `Entry` rows. A tuple isn't
    /// Hashable, and we want to keep field ordering since XADD allows
    /// duplicate field names.
    struct Pair: Hashable {
        let field: String
        let value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Table(entries, selection: $selection) {
                TableColumn("ID") { entry in
                    Text(entry.id)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .width(min: 140, ideal: 180, max: 260)

                TableColumn("Fields") { entry in
                    Text(formatFields(entry.fields))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .contextMenu(forSelectionType: Entry.ID.self) { selected in
                if let id = selected.first, let entry = entries.first(where: { $0.id == id }) {
                    Button("Copy ID") { copy(entry.id) }
                    Button("Copy Fields") { copy(formatFields(entry.fields)) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        Task { await deleteEntry(id: entry.id) }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add entry…", systemImage: "plus")
                }
            }
            .padding(8)
        }
        .task(id: key) { await load() }
        // Stream entries don't surface in the inspector — there's no
        // cohesive "row edit" semantic. Clear stale state if a previous
        // editor left something pinned.
        .onAppear { session.inspectorTarget = nil }
        .onChange(of: session.dataVersion) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $showAddSheet) {
            AddStreamEntrySheet { fields in
                Task {
                    _ = try? await session.service.xadd(key, fields: fields)
                    await load()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(totalLength) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            if entries.count < totalLength {
                Text("(showing \(entries.count) most recent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func load() async {
        async let lenTask = (try? await session.service.xlen(key)) ?? 0
        async let rangeTask = (try? await session.service.xrange(key, count: 200)) ?? []
        let (len, range) = await (lenTask, rangeTask)
        totalLength = len
        // XRANGE is oldest-first; reverse for newest-on-top — matches what
        // a developer skimming "what just happened" expects.
        entries = range.reversed().map { entry in
            Entry(
                id: entry.id,
                fields: entry.fields.map { Pair(field: $0.0, value: $0.1) }
            )
        }
    }

    private func deleteEntry(id: String) async {
        _ = try? await session.service.xdel(key, id: id)
        await load()
    }

    /// Render `[Pair]` as `field=value field2=value2 …`. Quotes aren't
    /// added — values that genuinely contain spaces will look ambiguous,
    /// but that's the same compromise the terminal's pretty-printer makes.
    private func formatFields(_ fields: [Pair]) -> String {
        fields
            .map { "\($0.field)=\($0.value)" }
            .joined(separator: "  ")
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

/// Multi-row sheet for XADD: each row is a field / value pair. Submit
/// commits all rows in one XADD call (Redis allows duplicate fields,
/// which we preserve in order).
private struct AddStreamEntrySheet: View {
    let onAdd: ([(String, String)]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [PairDraft] = [PairDraft()]

    private struct PairDraft: Identifiable {
        let id = UUID()
        var field: String = ""
        var value: String = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Stream Entry")
                .font(.headline)

            ForEach($rows) { $row in
                HStack {
                    TextField("Field", text: $row.field)
                        .textFieldStyle(.roundedBorder)
                    TextField("Value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(rows.count <= 1)
                }
            }

            Button {
                rows.append(PairDraft())
            } label: {
                Label("Add field", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .controlSize(.small)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let pairs = rows
                        .filter { !$0.field.isEmpty }
                        .map { ($0.field, $0.value) }
                    if !pairs.isEmpty { onAdd(pairs) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.allSatisfy { $0.field.isEmpty })
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
