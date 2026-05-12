import SwiftUI

struct JSONEditor: View {
    let session: RedisSession
    let key: String

    @State private var value: String = ""
    @State private var loaded = false
    @State private var dirty = false
    @State private var jsonError: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if let err = jsonError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.1))
                }
                TextEditor(text: $value)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .onChange(of: value) { _, _ in
                        if loaded {
                            dirty = true
                            validateJSON()
                        }
                    }
            }

            HStack(spacing: 8) {
                Button { formatJSON() } label: {
                    Label("Format", systemImage: "text.alignleft")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                if dirty {
                    Button { Task { await save() } } label: {
                        Label("Save", systemImage: "checkmark")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(jsonError != nil)
                    .transition(.opacity)
                }
            }
            .padding(14)
        }
        .background(
            Button("save") { Task { await save() } }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .task(id: key) { await load() }
    }

    private func load() async {
        loaded = false
        let raw = (try? await session.service.jsonGet(key)) ?? ""
        value = prettyPrint(raw) ?? raw
        dirty = false
        jsonError = nil
        loaded = true
    }

    private func save() async {
        guard dirty, jsonError == nil else { return }
        do {
            try await session.service.jsonSet(key, value: value)
            dirty = false
        } catch { /* surfaced via session.status */ }
    }

    private func formatJSON() {
        guard let formatted = prettyPrint(value) else { return }
        value = formatted
    }

    private func validateJSON() {
        guard !value.isEmpty else { jsonError = nil; return }
        guard let data = value.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
            jsonError = "Invalid JSON"
            return
        }
        jsonError = nil
    }

    private func prettyPrint(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .fragmentsAllowed]),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }
}
