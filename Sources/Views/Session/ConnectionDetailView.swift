import SwiftUI

/// Standalone Connection Detail window. Shows the saved profile plus the
/// full server `INFO` snapshot (grouped by section in a sidebar) and
/// `SLOWLOG GET`. Opens from the connection status popover in the session
/// window's toolbar; refresh is manual via toolbar or footer button.
struct ConnectionDetailView: View {
    let connection: Connection
    @Environment(AppState.self) private var appState

    @State private var session: RedisSession?
    @State private var info: ServerInfo?
    @State private var slowLog: [SlowLogEntry] = []
    @State private var loadError: String?
    @State private var loading: Bool = false
    @State private var selection: DetailCategory = .profile

    enum DetailCategory: Hashable {
        case profile
        case info(String)
        case slowLogs
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 540)
        .navigationTitle(connection.name)
        .navigationSubtitle(subtitle)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(loading)
            }
        }
    }

    private var subtitle: String {
        var bits: [String] = ["\(connection.host):\(connection.port)"]
        if let version = infoValue(section: "Server", field: "redis_version") {
            bits.append("Redis \(version)")
        }
        if let s = session {
            bits.append(statusText(for: s.status))
        }
        return bits.joined(separator: " · ")
    }

    private func infoValue(section: String, field: String) -> String? {
        info?.sections.first { $0.name.caseInsensitiveCompare(section) == .orderedSame }?
            .fields.first { $0.name == field }?.value
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Connection") {
                Label("Profile", systemImage: "person.text.rectangle")
                    .tag(DetailCategory.profile)
            }
            if let info, !info.sections.isEmpty {
                Section("Server INFO") {
                    ForEach(info.sections, id: \.name) { sec in
                        Label(sec.name, systemImage: iconFor(section: sec.name))
                            .tag(DetailCategory.info(sec.name))
                    }
                }
            }
            Section("Logs") {
                Label("Slow Logs", systemImage: "tortoise")
                    .tag(DetailCategory.slowLogs)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selection {
            case .profile:
                FieldTable(fields: profileFields)
            case .info(let name):
                if let sec = info?.sections.first(where: { $0.name == name }) {
                    if sec.fields.isEmpty {
                        ContentUnavailableView("No fields", systemImage: "tray")
                    } else {
                        FieldTable(fields: sec.fields)
                    }
                } else if let err = loadError {
                    errorBox(err)
                } else if loading {
                    loadingBox
                } else {
                    notConnectedView
                }
            case .slowLogs:
                if loading && slowLog.isEmpty {
                    loadingBox
                } else if slowLog.isEmpty {
                    ContentUnavailableView(
                        "No slow log entries",
                        systemImage: "tortoise",
                        description: Text("Slow commands recorded by Redis will appear here.")
                    )
                } else {
                    SlowLogTable(entries: slowLog)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(loading)
            if loading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if case .info(let name) = selection,
               let sec = info?.sections.first(where: { $0.name == name }) {
                Text("\(sec.fields.count) fields")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if case .slowLogs = selection, !slowLog.isEmpty {
                Text("\(slowLog.count) entries")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var loadingBox: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var notConnectedView: some View {
        ContentUnavailableView(
            "Not Connected",
            systemImage: "bolt.horizontal",
            description: Text(notConnectedHint)
        )
    }

    private func errorBox(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
            Text("Failed to load INFO")
                .font(.headline)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Profile rows

    private var profileFields: [InfoField] {
        var rows: [InfoField] = []
        rows.append(.init(name: "Name", value: connection.name))
        rows.append(.init(name: "Host", value: connection.host))
        rows.append(.init(name: "Port", value: String(connection.port)))
        if let u = connection.username, !u.isEmpty {
            rows.append(.init(name: "Username", value: u))
        }
        rows.append(.init(name: "Default DB", value: String(connection.defaultDB)))
        rows.append(.init(name: "Password", value: passwordModeLabel(connection.passwordMode)))
        rows.append(.init(name: "Default pattern", value: connection.defaultPattern))
        if let ssh = connection.sshTunnel {
            rows.append(.init(name: "SSH Tunnel", value: "\(ssh.username)@\(ssh.host):\(ssh.port)"))
            rows.append(.init(name: "SSH Auth", value: sshAuthLabel(ssh)))
        }
        if let s = session {
            rows.append(.init(name: "Status", value: statusText(for: s.status)))
        }
        return rows
    }

    // MARK: - Status

    private func statusText(for status: RedisSession.Status) -> String {
        switch status {
        case .connected:       return "Connected"
        case .connecting:      return "Connecting…"
        case .failed(let m):   return "Failed · \(m)"
        case .disconnected:    return "Disconnected"
        }
    }

    private var notConnectedHint: String {
        guard let session else {
            return "Session not started yet. Open the connection from the launcher first."
        }
        switch session.status {
        case .connecting:   return "Connecting — INFO will load once the session is up."
        case .failed(let m): return "Connection failed (\(m)). Reconnect from the session window."
        case .disconnected: return "Disconnected — INFO is only available while connected."
        default: return "INFO is only available while connected."
        }
    }

    private func sshAuthLabel(_ ssh: SSHTunnelConfig) -> String {
        switch ssh.authMethod {
        case .password:    return "password"
        case .privateKey:  return "private-key (\(ssh.privateKeyPath ?? "—"))"
        }
    }

    private func passwordModeLabel(_ mode: CredentialMode?) -> String {
        switch mode {
        case .keychain:    return "Saved in Keychain"
        case .askEachTime: return "Ask each time"
        case .none:        return "None"
        }
    }

    /// Map an INFO section header to a representative SF Symbol. Falls
    /// back to `info.circle` for unknown / future sections.
    private func iconFor(section: String) -> String {
        switch section.lowercased() {
        case "server":       return "server.rack"
        case "clients":      return "person.2"
        case "memory":       return "memorychip"
        case "persistence":  return "externaldrive"
        case "stats":        return "chart.bar"
        case "replication":  return "arrow.triangle.2.circlepath"
        case "cpu":          return "cpu"
        case "commandstats": return "list.bullet.rectangle"
        case "latencystats": return "speedometer"
        case "cluster":      return "circle.grid.3x3"
        case "keyspace":     return "key"
        case "errorstats":   return "exclamationmark.triangle"
        case "modules":      return "puzzlepiece"
        default:             return "info.circle"
        }
    }

    // MARK: - Data load

    private func load() async {
        session = appState.sessions[connection.id]
        guard let s = session, s.status == .connected else {
            info = nil
            slowLog = []
            loadError = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            let raw = try await s.service.info()
            info = ServerInfo.parse(raw)
            slowLog = (try? await s.service.slowLog(count: 128)) ?? []
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - INFO model

/// Sectioned INFO snapshot — preserves Redis's own section headers and
/// the order in which fields are reported. Built from the raw text reply.
struct ServerInfo {
    struct InfoSection: Hashable {
        var name: String
        var fields: [InfoField]
    }
    var sections: [InfoSection] = []

    static func parse(_ raw: String) -> ServerInfo {
        var result = ServerInfo()
        var current: InfoSection?
        for line in raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let s = String(line)
            if s.isEmpty { continue }
            if s.hasPrefix("#") {
                if let c = current { result.sections.append(c) }
                current = InfoSection(
                    name: s.dropFirst(1).trimmingCharacters(in: .whitespaces),
                    fields: []
                )
                continue
            }
            guard let colon = s.firstIndex(of: ":") else { continue }
            let key = String(s[s.startIndex..<colon])
            let value = String(s[s.index(after: colon)...])
            if current == nil {
                current = InfoSection(name: "Server", fields: [])
            }
            current?.fields.append(InfoField(name: key, value: value))
        }
        if let c = current { result.sections.append(c) }
        return result
    }
}

struct InfoField: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var value: String
}

// MARK: - Tables

private struct FieldTable: View {
    let fields: [InfoField]

    var body: some View {
        Table(fields) {
            TableColumn("Name") { row in
                Text(row.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .width(min: 180, ideal: 240, max: 340)
            TableColumn("Value") { row in
                Text(row.value)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.value)
            }
        }
    }
}

private struct SlowLogTable: View {
    let entries: [SlowLogEntry]

    var body: some View {
        Table(entries) {
            TableColumn("ID") { e in
                Text(String(e.id))
                    .monospacedDigit()
            }
            .width(50)
            TableColumn("Time") { e in
                Text(Self.formatter.string(from: Date(timeIntervalSince1970: TimeInterval(e.timestampSeconds))))
                    .monospacedDigit()
            }
            .width(150)
            TableColumn("Duration") { e in
                Text(Self.formatDuration(e.durationMicros))
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("Command") { e in
                Text(e.command)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(e.command)
            }
            TableColumn("Client") { e in
                Text(e.client ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(140)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private static func formatDuration(_ micros: Int) -> String {
        if micros < 1000 { return "\(micros) µs" }
        if micros < 1_000_000 {
            return String(format: "%.2f ms", Double(micros) / 1000)
        }
        return String(format: "%.2f s", Double(micros) / 1_000_000)
    }
}
