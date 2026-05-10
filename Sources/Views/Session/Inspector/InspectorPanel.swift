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
        // Primary label is suppressed for `.string` (no field/index/member
        // identifier exists) and for `.setMember` (the member IS the
        // editable content — primary is just its prior value).
        if !target.primaryLabel.isEmpty {
            sectionHeader(target.primaryLabel)
            TextField("", text: .constant(target.primary))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
        }

        sectionHeader(target.secondaryLabel)
        switch target.kind {
        case .string, .hashField, .listIndex:
            TextField("", text: $contentDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(6, reservesSpace: true)
                .font(.system(.body, design: .monospaced))
                .disabled(target.kind == .string)
        case .setMember:
            TextField("", text: $contentDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        case .zsetMember:
            TextField("", text: $contentDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }

        // No Save button for `.string`: the StringEditor itself owns the
        // editable copy, and a second writer would clobber its dirty state.
        if target.kind != .string {
            HStack {
                Spacer()
                Button("Save") {
                    Task { await save(target: target) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(contentDraft == target.secondary || isInvalid(target: target))
            }
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
        case .string:
            return  // read-only in the inspector
        case .hashField:
            try? await session.service.hset(
                target.key,
                field: target.primary,
                value: contentDraft
            )
        case .listIndex:
            guard let idx = Int(target.primary) else { return }
            try? await session.service.lset(
                target.key,
                index: idx,
                value: contentDraft
            )
        case .setMember:
            // Sets have no in-place rename — drop the old member and add
            // the new one. No-op if unchanged.
            guard contentDraft != target.primary else { return }
            try? await session.service.srem(target.key, member: target.primary)
            try? await session.service.sadd(target.key, member: contentDraft)
        case .zsetMember:
            guard let score = Double(contentDraft) else { return }
            try? await session.service.zadd(
                target.key,
                member: target.primary,
                score: score
            )
        }
        // Refresh the cached target so Save disables again, bump the
        // version so the editor table reloads. For setMember the rename
        // moves the identity to the new value too.
        let newPrimary = (target.kind == .setMember) ? contentDraft : target.primary
        session.inspectorTarget = InspectorTarget(
            kind: target.kind,
            key: target.key,
            primary: newPrimary,
            secondary: contentDraft
        )
        session.dataVersion += 1
    }

    private func isInvalid(target: InspectorTarget) -> Bool {
        switch target.kind {
        case .string, .hashField, .listIndex, .setMember:
            return false
        case .zsetMember:
            return Double(contentDraft) == nil
        }
    }
}

private extension InspectorTarget {
    var primaryLabel: String {
        switch kind {
        case .string:     return ""
        case .hashField:  return "Field"
        case .listIndex:  return "Index"
        case .setMember:  return ""
        case .zsetMember: return "Member"
        }
    }
    var secondaryLabel: String {
        switch kind {
        case .string:     return "Value"
        case .hashField:  return "Value"
        case .listIndex:  return "Value"
        case .setMember:  return "Member"
        case .zsetMember: return "Score"
        }
    }
}
