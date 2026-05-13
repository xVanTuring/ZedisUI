import SwiftUI

struct ListEditor: View {
    let session: RedisSession
    let key: String

    @State private var items: [Item] = []
    @State private var totalLength: Int = 0
    @State private var page: Int = 0
    @State private var selection: Item.ID?
    @State private var newValue = ""
    @State private var pushHead = false

    @State private var query: String = ""
    @State private var mode: SearchMode = .contain

    // Full-list scan state (Search whole list button).
    @State private var scanMode: Bool = false
    @State private var scanMatches: [Item] = []
    @State private var scanScanned: Int = 0
    @State private var scanRunning: Bool = false
    @State private var scanTask: Task<Void, Never>?

    private let pageSize = 200
    private let scanChunkSize = 1000

    struct Item: Identifiable, Hashable {
        let id = UUID()
        var index: Int
        var value: String
    }

    private var searching: Bool { !query.isEmpty }

    private var pageCount: Int {
        max(1, Int(ceil(Double(totalLength) / Double(pageSize))))
    }

    /// Rows currently rendered. Three regimes:
    /// 1. No query → the current page of `items`.
    /// 2. Query + not in scan mode → client-side filter over the current page.
    /// 3. Query + scan mode → the accumulated `scanMatches`.
    private var visibleItems: [Item] {
        if scanMode { return scanMatches }
        guard let matcher = makeGlobMatcher(query, mode: mode) else { return items }
        return items.filter { matcher($0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSearchBar(query: $query, mode: $mode, placeholder: "Search values…")

            header

            Table(visibleItems, selection: $selection) {
                TableColumn("#") { item in
                    Text(String(item.index))
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 40, ideal: 60, max: 100)
                TableColumn("Value") { item in
                    Text(item.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: Item.ID.self) { selected in
                if let id = selected.first, let item = visibleItems.first(where: { $0.id == id }) {
                    Button("Edit…") { editTarget = item }
                    Button("Delete", role: .destructive) {
                        Task {
                            try? await session.service.lremByIndex(key, index: item.index)
                            await reload()
                        }
                    }
                }
            } primaryAction: { selected in
                if let id = selected.first, let item = visibleItems.first(where: { $0.id == id }) {
                    editTarget = item
                }
            }
            .id(scanMode ? "scan" : "page-\(page)")

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
        .task(id: key) {
            page = 0
            cancelScan()
            await reload()
        }
        // Clearing the committed query exits scan mode. Otherwise the
        // filter-in-page view re-derives via @State without a refetch.
        .onChange(of: query) { _, new in
            if new.isEmpty { cancelScan() }
        }
        // Changing mode mid-scan would render stale matches; force the
        // user to re-trigger the scan with the new mode.
        .onChange(of: mode) { _, _ in
            if scanMode { cancelScan() }
        }
        .onChange(of: selection) { _, newValue in
            if let id = newValue, let item = visibleItems.first(where: { $0.id == id }) {
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
            query = ""
            cancelScan()
        }
        .onChange(of: session.dataVersion) { _, _ in
            Task { await reload() }
        }
        .sheet(item: $editTarget) { item in
            ListItemEditSheet(title: "Edit list item #\(item.index)", initial: item.value) { v in
                Task {
                    try? await session.service.lset(key, index: item.index, value: v)
                    await reload()
                }
            }
        }
    }

    @State private var editTarget: Item?

    private var header: some View {
        HStack(spacing: 12) {
            if scanMode {
                Text("\(scanMatches.count) match\(scanMatches.count == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if scanRunning {
                    Text("· scanned \(scanScanned) of \(totalLength)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 2)
                } else {
                    Text("· scan complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if scanRunning {
                    Button("Cancel") { cancelScan() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else {
                    Button("Exit search") {
                        cancelScan()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } else if searching {
                Text("\(visibleItems.count) match\(visibleItems.count == 1 ? "" : "es") in this page")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· \(totalLength) total")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Search entire list…") {
                    startFullScan()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                pageChevrons
            } else {
                Text("\(totalLength) item\(totalLength == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if totalLength > pageSize {
                    Text("· Page \(page + 1) of \(pageCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                pageChevrons
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var pageChevrons: some View {
        if totalLength > pageSize {
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

    private func reload() async {
        let len = (try? await session.service.llen(key)) ?? 0
        totalLength = len
        let lastPage = max(0, Int(ceil(Double(len) / Double(pageSize))) - 1)
        if page > lastPage { page = lastPage }

        if len == 0 {
            items = []
            return
        }
        let start = page * pageSize
        let stop = min(start + pageSize, len) - 1
        let raw = (try? await session.service.lrange(key, start: start, stop: stop)) ?? []
        items = raw.enumerated().map { Item(index: start + $0.offset, value: $0.element) }
    }

    private func push() async {
        let v = newValue
        if pushHead {
            try? await session.service.lpush(key, value: v)
            page = 0
        } else {
            try? await session.service.rpush(key, value: v)
            page = max(0, Int(ceil(Double(totalLength + 1) / Double(pageSize))) - 1)
        }
        newValue = ""
        await reload()
    }

    // MARK: - Full-list scan (mode B)

    private func startFullScan() {
        cancelScan()
        guard let matcher = makeGlobMatcher(query, mode: mode) else { return }
        scanMode = true
        scanMatches = []
        scanScanned = 0
        scanRunning = true
        let snapshotKey = key
        let chunk = scanChunkSize
        scanTask = Task { @MainActor in
            defer { scanRunning = false }
            // Re-read total in case it grew/shrank since last reload().
            let total = (try? await session.service.llen(snapshotKey)) ?? 0
            totalLength = total
            var idx = 0
            while idx < total {
                if Task.isCancelled { return }
                let stop = min(idx + chunk, total) - 1
                let batch = (try? await session.service.lrange(snapshotKey, start: idx, stop: stop)) ?? []
                if Task.isCancelled { return }
                for (offset, value) in batch.enumerated() where matcher(value) {
                    scanMatches.append(Item(index: idx + offset, value: value))
                }
                idx += batch.count
                scanScanned = idx
                // The list may have been truncated mid-scan; bail rather
                // than spin forever on an empty LRANGE.
                if batch.isEmpty { break }
            }
        }
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanRunning = false
        scanMode = false
        scanMatches = []
        scanScanned = 0
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
