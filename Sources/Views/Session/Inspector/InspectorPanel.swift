import SwiftUI

/// Right-hand inspector — Medis-style row editor (Field / Content).
/// Phase A keeps it static; Phase B will wire it up to the active table selection.
struct InspectorPanel: View {
    @Bindable var session: RedisSession

    @State private var fieldDraft: String = ""
    @State private var contentDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Field")
            TextField("", text: $fieldDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(true)

            sectionHeader("Content")
            TextField("", text: $contentDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(6, reservesSpace: true)
                .disabled(true)

            HStack {
                Spacer()
                Button("Save") { /* phase B */ }
                    .disabled(true)
                    .controlSize(.regular)
            }

            Spacer()

            if session.selectedKey == nil {
                Text("Select a key on the left to start editing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a row in the main panel to edit it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer()
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
    }
}
