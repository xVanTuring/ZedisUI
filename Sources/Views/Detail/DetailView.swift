import SwiftUI

struct DetailView: View {
    @Bindable var session: RedisSession
    @State private var resolvedType: RedisKeyType?
    @State private var ttl: Int = -1
    @State private var memoryBytes: Int?
    @State private var encoding: String?
    @State private var renameDraft: String = ""
    @State private var pendingTTLEdit = false
    @State private var showTTLPopover = false

    var body: some View {
        Group {
            if session.commandQueryActive {
                CommandQueryView(session: session)
            } else if let key = session.selectedKey, let type = resolvedType {
                VStack(spacing: 0) {
                    headerBar(key: key, type: type)
                    metaBar(key: key)
                    Divider()
                    editor(for: key, type: type)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if session.selectedKey != nil {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Key Selected",
                    systemImage: "key",
                    description: Text("Pick a key on the left to view or edit its value.")
                )
            }
        }
        .task(id: session.selectedKey) { await reloadMeta() }
    }

    // MARK: - Header (key name + gear)

    private func headerBar(key: String, type: RedisKeyType) -> some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Key", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(.title3, weight: .semibold))
                .onSubmit { Task { await commitRename(from: key) } }
            Spacer()

            Menu {
                Button("Copy Key Name") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(key, forType: .string)
                }
                Divider()
                Button("Set TTL…") { pendingTTLEdit = true }
                Button("Persist (clear TTL)") {
                    Task {
                        try? await session.service.persist(key)
                        await reloadMeta()
                    }
                }
                .disabled(ttl <= 0)
                Divider()
                Button("Delete Key", role: .destructive) {
                    Task {
                        _ = try? await session.service.delete([key])
                        session.selectedKey = nil
                        await session.reloadKeys()
                    }
                }
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .sheet(isPresented: $pendingTTLEdit) {
            TTLEditView(currentTTL: ttl) { newSeconds in
                Task {
                    if newSeconds <= 0 {
                        try? await session.service.persist(key)
                    } else {
                        try? await session.service.expire(key, seconds: newSeconds)
                    }
                    await reloadMeta()
                }
            }
        }
    }

    // MARK: - Meta bar (TTL · Memory · Encoding)

    private func metaBar(key: String) -> some View {
        HStack(spacing: 18) {
            Button {
                showTTLPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("TTL:").foregroundStyle(.secondary)
                    Text(ttlText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTTLPopover, arrowEdge: .top) {
                TTLPopover(
                    currentTTL: ttl,
                    onPersist: {
                        Task {
                            try? await session.service.persist(key)
                            await reloadMeta()
                        }
                        showTTLPopover = false
                    },
                    onSave: { newSeconds in
                        Task {
                            try? await session.service.expire(key, seconds: newSeconds)
                            await reloadMeta()
                        }
                        showTTLPopover = false
                    }
                )
            }

            HStack(spacing: 4) {
                Text("Memory:").foregroundStyle(.secondary)
                Text(memoryText)
            }

            HStack(spacing: 4) {
                Text("Encoding:").foregroundStyle(.secondary)
                Text(encoding ?? "—")
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func editor(for key: String, type: RedisKeyType) -> some View {
        switch type {
        case .string: StringEditor(session: session, key: key)
        case .hash:   HashEditor(session: session, key: key)
        case .list:   ListEditor(session: session, key: key)
        case .set:    SetEditor(session: session, key: key)
        case .zset:   ZSetEditor(session: session, key: key)
        case .stream: StreamEditor(session: session, key: key)
        case .unknown:
            ContentUnavailableView(
                "Type not supported yet",
                systemImage: "wrench.and.screwdriver",
                description: Text("Streams and unknown types aren't editable in this build.")
            )
        }
    }

    private var ttlText: String {
        switch ttl {
        case -2: return "—"
        case -1: return "Forever"
        default: return formatTTL(ttl)
        }
    }

    private var memoryText: String {
        guard let m = memoryBytes else { return "—" }
        if m < 1024 { return "\(m) bytes" }
        if m < 1024 * 1024 { return String(format: "%.1f KB", Double(m) / 1024) }
        return String(format: "%.1f MB", Double(m) / 1024 / 1024)
    }

    private func formatTTL(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    private func reloadMeta() async {
        guard let key = session.selectedKey else {
            resolvedType = nil
            ttl = -1
            memoryBytes = nil
            encoding = nil
            return
        }
        renameDraft = key
        resolvedType = (try? await session.service.type(of: key)) ?? .unknown
        ttl = (try? await session.service.ttl(of: key)) ?? -1
        memoryBytes = try? await session.service.memoryUsage(of: key)
        encoding = try? await session.service.objectEncoding(of: key)
    }

    private func commitRename(from oldKey: String) async {
        let newKey = renameDraft
        guard !newKey.isEmpty, newKey != oldKey else { return }
        do {
            try await session.service.rename(oldKey, to: newKey)
            session.selectedKey = newKey
            await session.reloadKeys()
        } catch {
            renameDraft = oldKey
        }
    }
}

private struct TTLEditView: View {
    let currentTTL: Int
    let onApply: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var seconds: String

    init(currentTTL: Int, onApply: @escaping (Int) -> Void) {
        self.currentTTL = currentTTL
        self.onApply = onApply
        self._seconds = State(initialValue: currentTTL > 0 ? String(currentTTL) : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set TTL")
                .font(.headline)
            TextField("Seconds (empty / 0 = never expire)", text: $seconds)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(Int(seconds) ?? 0)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// Inline TTL editor that anchors to the meta-bar `TTL:` label as a
/// popover. Number input + unit picker on top, Persist / Save on the
/// bottom. The unit picker covers the four sensible Redis-side
/// resolutions; minutes / hours / days are just multipliers — Redis
/// itself only takes seconds via EXPIRE.
private struct TTLPopover: View {
    let currentTTL: Int
    let onPersist: () -> Void
    let onSave: (Int) -> Void

    enum Unit: String, CaseIterable, Identifiable {
        case seconds, minutes, hours, days
        var id: String { rawValue }
        var multiplier: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours:   return 3600
            case .days:    return 86400
            }
        }
    }

    @State private var input: String
    @State private var unit: Unit

    init(currentTTL: Int, onPersist: @escaping () -> Void, onSave: @escaping (Int) -> Void) {
        self.currentTTL = currentTTL
        self.onPersist = onPersist
        self.onSave = onSave
        // Pre-fill with the largest unit that yields a whole number, so
        // "3600s" shows as "1 hours" rather than "3600 seconds".
        if currentTTL > 0 {
            if currentTTL.isMultiple(of: 86400) {
                _input = State(initialValue: String(currentTTL / 86400))
                _unit  = State(initialValue: .days)
            } else if currentTTL.isMultiple(of: 3600) {
                _input = State(initialValue: String(currentTTL / 3600))
                _unit  = State(initialValue: .hours)
            } else if currentTTL.isMultiple(of: 60) {
                _input = State(initialValue: String(currentTTL / 60))
                _unit  = State(initialValue: .minutes)
            } else {
                _input = State(initialValue: String(currentTTL))
                _unit  = State(initialValue: .seconds)
            }
        } else {
            _input = State(initialValue: "")
            _unit  = State(initialValue: .seconds)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                TextField("", text: $input)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $unit) {
                    ForEach(Unit.allCases) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack {
                Button("Persist Key", action: onPersist)
                    .disabled(currentTTL <= 0)
                Spacer()
                Button("Save") {
                    if let n = Int(input), n > 0 {
                        onSave(n * unit.multiplier)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((Int(input) ?? 0) <= 0)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
