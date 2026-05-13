import SwiftUI

struct ZSetEditor: View {
    let session: RedisSession
    let key: String

    @State private var entries: [Entry] = []
    @State private var totalLength: Int = 0

    // Browse mode (no query): paginate by score-ordered index.
    @State private var page: Int = 0

    // Search mode (query non-empty): cursor + dedup.
    @State private var seenMembers: Set<String> = []
    @State private var cursor: Int = 0
    @State private var loading: Bool = false

    @State private var selection: Entry.ID?
    @State private var newMember = ""
    @State private var newScore = "0"

    @State private var query: String = ""
    @State private var mode: SearchMode = .contain

    private let pageSize = 200
    private let searchBatchTarget = 200

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        var member: String
        var score: Double
    }

    private var searching: Bool { !query.isEmpty }

    private var pageCount: Int {
        max(1, Int(ceil(Double(totalLength) / Double(pageSize))))
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSearchBar(query: $query, mode: $mode, placeholder: "Search members…")

            header

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
                            await reload()
                        }
                    }
                }
            }
            .id(searching ? -1 : page)

            // Search mode keeps a Load More button; browse mode keeps the
            // Prev/Next chevrons in the header.
            if searching && cursor != 0 {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        Task { await loadMore() }
                    } label: {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load more matches (\(entries.count) so far)")
                        }
                    }
                    .disabled(loading)
                    Spacer()
                }
                .padding(.vertical, 6)
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
        .task(id: key) {
            page = 0
            await reload()
        }
        .onChange(of: query) { _, _ in Task { await reload() } }
        .onChange(of: mode) { _, _ in
            if !query.isEmpty { Task { await reload() } }
        }
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
            query = ""
        }
        .onChange(of: session.dataVersion) { _, _ in
            Task { await reload() }
        }
        .sheet(item: $editTarget) { entry in
            ScoreEditSheet(member: entry.member, initial: entry.score) { newScore in
                Task {
                    try? await session.service.zadd(key, member: entry.member, score: newScore)
                    await reload()
                }
            }
        }
    }

    @State private var editTarget: Entry?

    private var header: some View {
        HStack(spacing: 12) {
            if searching {
                Text("\(entries.count) match\(entries.count == 1 ? "" : "es")")
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
                // ZSCAN walks by hash slot, so we lose score order in
                // search results. Surface the caveat.
                Text("· unordered")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("ZSCAN traverses by hash slot, so search results aren't sorted by score.")
            } else {
                Text("\(totalLength) member\(totalLength == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if totalLength > pageSize {
                    Text("· Page \(page + 1) of \(pageCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !searching && totalLength > pageSize {
                Button {
                    if page > 0 {
                        page -= 1
                        Task { await reload() }
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(page == 0)
                .help("Previous page")

                Button {
                    if page + 1 < pageCount {
                        page += 1
                        Task { await reload() }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(page + 1 >= pageCount)
                .help("Next page")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Reset everything and load the first batch. Dispatches between
    /// browse mode (ZRANGE start stop) and search mode (ZSCAN MATCH).
    private func reload() async {
        let len = (try? await session.service.zcard(key)) ?? 0
        totalLength = len

        if searching {
            entries = []
            seenMembers = []
            cursor = 0
            await loadMore()
        } else {
            let lastPage = max(0, Int(ceil(Double(len) / Double(pageSize))) - 1)
            if page > lastPage { page = lastPage }
            if len == 0 {
                entries = []
                return
            }
            let start = page * pageSize
            let stop = min(start + pageSize, len) - 1
            let raw = (try? await session.service.zrange(key, start: start, stop: stop)) ?? []
            entries = raw.map { Entry(member: $0.0, score: $0.1) }
        }
    }

    private func loadMore() async {
        guard searching, !loading else { return }
        loading = true
        defer { loading = false }

        let pattern = buildGlobPattern(query, mode: mode)
        let startCount = entries.count

        repeat {
            let (next, pairs) = (try? await session.service.zscan(
                key, cursor: cursor, match: pattern, count: pageSize
            )) ?? (0, [])
            for (m, s) in pairs where !seenMembers.contains(m) {
                seenMembers.insert(m)
                entries.append(Entry(member: m, score: s))
            }
            cursor = next
            if cursor == 0 { break }
            if entries.count - startCount >= searchBatchTarget { break }
        } while true
    }

    private func add() async {
        let score = Double(newScore) ?? 0
        try? await session.service.zadd(key, member: newMember, score: score)
        newMember = ""
        newScore = "0"
        await reload()
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
