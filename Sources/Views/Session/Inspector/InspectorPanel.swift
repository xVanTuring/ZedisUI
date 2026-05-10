import SwiftUI

/// Right-hand inspector — shows the row currently focused in the active
/// editor (`session.inspectorTarget`) and lets the user edit its content.
/// Hash rows expose a multi-line value editor; zset rows expose a score.
struct InspectorPanel: View {
    @Bindable var session: RedisSession

    @State private var contentDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let target = session.inspectorTarget {
                editor(for: target)
            } else {
                placeholder
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        // Sync the local draft whenever the active target changes (new row
        // selected, or the editor's onChange-of-key cleared it). `initial:
        // true` covers the case where a target is already present at first
        // appearance (e.g. inspector reopened mid-session).
        .onChange(of: session.inspectorTarget, initial: true) { _, target in
            contentDraft = target?.secondary ?? ""
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func editor(for target: InspectorTarget) -> some View {
        sectionHeader(target.primaryLabel)
        TextField("", text: .constant(target.primary))
            .textFieldStyle(.roundedBorder)
            .disabled(true)

        sectionHeader(target.secondaryLabel)
        switch target.kind {
        case .hashField:
            TextField("", text: $contentDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(6, reservesSpace: true)
                .font(.system(.body, design: .monospaced))
        case .zsetMember:
            TextField("", text: $contentDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }

        HStack {
            Spacer()
            Button("Save") {
                Task { await save(target: target) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(contentDraft == target.secondary || isInvalid(target: target))
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector")
                .font(.callout.weight(.semibold))
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
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer()
        }
    }

    // MARK: - Save / validation

    private func save(target: InspectorTarget) async {
        switch target.kind {
        case .hashField:
            try? await session.service.hset(
                target.key,
                field: target.primary,
                value: contentDraft
            )
        case .zsetMember:
            guard let score = Double(contentDraft) else { return }
            try? await session.service.zadd(
                target.key,
                member: target.primary,
                score: score
            )
        }
        // Refresh the cached target so the Save button disables again, and
        // bump the version so the editor table reloads.
        session.inspectorTarget = InspectorTarget(
            kind: target.kind,
            key: target.key,
            primary: target.primary,
            secondary: contentDraft
        )
        session.dataVersion += 1
    }

    private func isInvalid(target: InspectorTarget) -> Bool {
        switch target.kind {
        case .hashField:  return false
        case .zsetMember: return Double(contentDraft) == nil
        }
    }
}

private extension InspectorTarget {
    var primaryLabel: String {
        switch kind {
        case .hashField:  return "Field"
        case .zsetMember: return "Member"
        }
    }
    var secondaryLabel: String {
        switch kind {
        case .hashField:  return "Value"
        case .zsetMember: return "Score"
        }
    }
}
