import SwiftUI

struct StringEditor: View {
    let session: RedisSession
    let key: String

    @State private var value: String = ""
    @State private var loaded = false
    @State private var dirty = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $value)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .onChange(of: value) { _, _ in if loaded { dirty = true } }

            // Floating Save pill — only visible when there are unsaved edits.
            // Cmd-S also works thanks to the hidden shortcut button below.
            if dirty {
                Button {
                    Task { await save() }
                } label: {
                    Label("Save", systemImage: "checkmark")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(14)
                .transition(.opacity)
            }
        }
        // Hidden command-S shortcut so the editor still saves via keyboard.
        .background(
            Button("save", action: { Task { await save() } })
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .task(id: key) { await load() }
    }

    private func load() async {
        loaded = false
        let v = (try? await session.service.getString(key)) ?? ""
        value = v
        dirty = false
        loaded = true
    }

    private func save() async {
        guard dirty else { return }
        do {
            try await session.service.setString(key, value: value)
            dirty = false
        } catch { /* surfaced via session.status */ }
    }
}
