import SwiftUI

struct SetEditor: View {
    let session: RedisSession
    let key: String

    @State private var members: [Member] = []
    @State private var seenValues: Set<String> = []
    @State private var cursor: Int = 0
    @State private var totalLength: Int = 0
    @State private var loading: Bool = false
    @State private var selection: Member.ID?
    @State private var newMember = ""

    @State private var query: String = ""
    @State private var mode: SearchMode = .contain

    private let pageSize = 200
    private let searchBatchTarget = 200

    struct Member: Identifiable, Hashable {
        let id = UUID()
        var value: String
    }

    private var searching: Bool { !query.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            EditorSearchBar(query: $query, mode: $mode, placeholder: "Search members…")

            header

            Table(members, selection: $selection) {
                TableColumn("Member") { m in
                    Text(m.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: Member.ID.self) { selected in
                if let id = selected.first, let m = members.first(where: { $0.id == id }) {
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(m.value, forType: .string)
                    }
                    Button("Delete", role: .destructive) {
                        Task {
                            try? await session.service.srem(key, member: m.value)
                            await reload()
                        }
                    }
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
                TextField("New member", text: $newMember)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    Task {
                        let v = newMember
                        try? await session.service.sadd(key, member: v)
                        newMember = ""
                        await reload()
                    }
                }
                .keyboardShortcut(.return)
                .disabled(newMember.isEmpty)
            }
            .padding(8)
        }
        .task(id: key) { await reload() }
        .onChange(of: query) { _, _ in Task { await reload() } }
        .onChange(of: mode) { _, _ in
            if !query.isEmpty { Task { await reload() } }
        }
        .onChange(of: selection) { _, newValue in
            if let id = newValue, let m = members.first(where: { $0.id == id }) {
                session.inspectorTarget = InspectorTarget(
                    kind: .setMember,
                    key: key,
                    primary: m.value,
                    secondary: m.value
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
    }

    private var loadMoreLabel: String {
        if searching {
            return "Load more matches (\(members.count) so far)"
        } else {
            return "Load more (\(members.count) of \(totalLength))"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if searching {
                Text("\(members.count) match\(members.count == 1 ? "" : "es")")
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
                Text("\(totalLength) member\(totalLength == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if totalLength > 0 && members.count < totalLength {
                    Text("· \(members.count) loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func reload() async {
        members = []
        seenValues = []
        cursor = 0
        totalLength = (try? await session.service.scard(key)) ?? 0
        await loadMore()
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        let pattern = buildGlobPattern(query, mode: mode)
        let startCount = members.count

        repeat {
            let (next, batch) = (try? await session.service.sscan(
                key, cursor: cursor, match: pattern, count: pageSize
            )) ?? (0, [])
            for v in batch where !seenValues.contains(v) {
                seenValues.insert(v)
                members.append(Member(value: v))
            }
            cursor = next
            if cursor == 0 { break }
            if !searching { break }
            if members.count - startCount >= searchBatchTarget { break }
        } while true
    }
}
