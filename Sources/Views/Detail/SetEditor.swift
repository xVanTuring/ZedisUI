import SwiftUI

struct SetEditor: View {
    let session: RedisSession
    let key: String

    @State private var members: [Member] = []
    @State private var selection: Member.ID?
    @State private var newMember = ""

    struct Member: Identifiable, Hashable {
        let id = UUID()
        var value: String
    }

    var body: some View {
        VStack(spacing: 0) {
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
                            await load()
                        }
                    }
                }
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
                        await load()
                    }
                }
                .keyboardShortcut(.return)
                .disabled(newMember.isEmpty)
            }
            .padding(8)
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        let raw = (try? await session.service.smembers(key)) ?? []
        members = raw.map { Member(value: $0) }
    }
}
