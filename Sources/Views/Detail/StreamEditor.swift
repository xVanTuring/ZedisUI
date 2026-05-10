import SwiftUI

/// Read-only viewer for Redis Stream entries. Streams have append-only
/// semantics with auto-generated IDs (`<ms>-<seq>`) and arbitrary
/// field/value pairs per entry. We render the most recent entries first
/// (XRANGE returns oldest-first; we just reverse for display) and don't
/// expose XADD / XDEL editing yet — those would need a different sheet
/// flow than the other types.
struct StreamEditor: View {
    let session: RedisSession
    let key: String

    @State private var entries: [Entry] = []
    @State private var totalLength: Int = 0

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

            Table(entries) {
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
        }
        .task(id: key) { await load() }
        // Stream entries don't surface in the inspector — there's no
        // cohesive "row edit" semantic. Clear stale state if a previous
        // editor left something pinned.
        .onAppear { session.inspectorTarget = nil }
        .onChange(of: session.dataVersion) { _, _ in
            Task { await load() }
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

    /// Render `[Pair]` as `field=value field2=value2 …`. Quotes aren't
    /// added — values that genuinely contain spaces will look ambiguous,
    /// but that's the same compromise the terminal's pretty-printer makes.
    private func formatFields(_ fields: [Pair]) -> String {
        fields
            .map { "\($0.field)=\($0.value)" }
            .joined(separator: "  ")
    }
}
