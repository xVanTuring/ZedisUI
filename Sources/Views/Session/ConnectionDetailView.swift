import SwiftUI

/// Standalone Connection Detail window: shows the saved profile plus a
/// parsed `INFO` snapshot from the server (version / role / memory /
/// clients / stats / keyspace). Opens from the connection status popover
/// in the session window's toolbar. Refreshes on demand — INFO snapshots
/// otherwise go stale without warning.
struct ConnectionDetailView: View {
    let connection: Connection
    @Environment(AppState.self) private var appState

    @State private var session: RedisSession?
    @State private var info: ServerInfo?
    @State private var loadError: String?
    @State private var loading: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                profileSection

                if let session, session.status == .connected {
                    if let info {
                        serverSection(info)
                        memorySection(info)
                        clientsAndStatsSection(info)
                        keyspaceSection(info)
                    } else if let err = loadError {
                        errorBox(err)
                    } else if loading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading INFO…").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(notConnectedHint)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 540, minHeight: 540)
        .navigationTitle("Detail · \(connection.name)")
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh INFO")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(loading)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.name)
                    .font(.title2.bold())
                Text("\(connection.host):\(connection.port)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
            if let session {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(for: session.status))
                        .frame(width: 7, height: 7)
                    Text(statusText(for: session.status))
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        section(title: "Profile") {
            row("Host", connection.host)
            row("Port", String(connection.port))
            if let user = connection.username, !user.isEmpty {
                row("Username", user)
            }
            row("Default DB", String(connection.defaultDB))
            row("Save password", connection.savePassword ? "Yes" : "No")
            row("Default pattern", connection.defaultPattern)
            if let ssh = connection.sshTunnel {
                row("SSH Tunnel", "\(ssh.username)@\(ssh.host):\(ssh.port)")
                row("SSH Auth", sshAuthLabel(ssh))
            }
        }
    }

    private func serverSection(_ info: ServerInfo) -> some View {
        section(title: "Server") {
            if let v = info.version { row("Version", v) }
            if let m = info.mode { row("Mode", m) }
            if let r = info.role { row("Role", r) }
            if let os = info.os { row("OS", os) }
            if let uptime = info.uptimeSeconds {
                row("Uptime", formatUptime(uptime))
            }
            if let pid = info.processID {
                row("PID", String(pid))
            }
        }
    }

    private func memorySection(_ info: ServerInfo) -> some View {
        section(title: "Memory") {
            if let v = info.usedMemoryHuman { row("Used", v) }
            if let v = info.usedMemoryPeakHuman { row("Peak", v) }
            if let v = info.usedMemoryRSSHuman { row("RSS", v) }
            if let v = info.maxMemoryHuman, v != "0B" { row("Max", v) }
            if let v = info.memFragmentationRatio {
                row("Fragmentation", String(format: "%.2f", v))
            }
        }
    }

    private func clientsAndStatsSection(_ info: ServerInfo) -> some View {
        section(title: "Clients & Stats") {
            if let v = info.connectedClients {
                row("Connected clients", String(v))
            }
            if let v = info.totalConnectionsReceived {
                row("Total connections", String(v))
            }
            if let v = info.totalCommandsProcessed {
                row("Commands processed", String(v))
            }
            if let v = info.instantOpsPerSec {
                row("Ops / sec", String(v))
            }
            if let h = info.keyspaceHits, let m = info.keyspaceMisses {
                let total = h + m
                let hitRate = total > 0 ? Double(h) / Double(total) * 100 : 0
                row("Keyspace hit rate", String(format: "%.1f%%  (%d / %d)", hitRate, h, total))
            }
        }
    }

    private func keyspaceSection(_ info: ServerInfo) -> some View {
        section(title: "Keyspace") {
            if info.dbs.isEmpty {
                row("Databases", "all empty")
            } else {
                ForEach(info.dbs, id: \.db) { db in
                    row("DB \(db.db)", "\(db.keys) keys · \(db.expires) with TTL")
                }
            }
        }
    }

    // MARK: - Generic section / row scaffolding

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                content()
            }
            .font(.callout)
            Divider().padding(.top, 4)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 140, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .gridColumnAlignment(.leading)
        }
    }

    private func errorBox(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Failed to load INFO: \(msg)")
                .font(.callout)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Status

    private func statusColor(for status: RedisSession.Status) -> Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return .gray
        }
    }

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
        default: return ""
        }
    }

    // MARK: - Data load

    private func load() async {
        session = appState.sessions[connection.id]
        guard let s = session, s.status == .connected else {
            info = nil
            loadError = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            let raw = try await s.service.info()
            info = ServerInfo.parse(raw)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func sshAuthLabel(_ ssh: SSHTunnelConfig) -> String {
        switch ssh.authMethod {
        case .password:    return "password"
        case .privateKey:  return "private-key (\(ssh.privateKeyPath ?? "—"))"
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

// MARK: - INFO parsing

/// Holds the subset of fields surfaced by ConnectionDetailView. The
/// rest of the INFO output is intentionally discarded — this view is
/// for at-a-glance status, not full diagnostics.
struct ServerInfo {
    var version: String?
    var mode: String?
    var role: String?
    var os: String?
    var processID: Int?
    var uptimeSeconds: Int?

    var connectedClients: Int?
    var usedMemoryHuman: String?
    var usedMemoryPeakHuman: String?
    var usedMemoryRSSHuman: String?
    var maxMemoryHuman: String?
    var memFragmentationRatio: Double?

    var totalConnectionsReceived: Int?
    var totalCommandsProcessed: Int?
    var instantOpsPerSec: Int?
    var keyspaceHits: Int?
    var keyspaceMisses: Int?

    struct DB: Equatable {
        var db: Int
        var keys: Int
        var expires: Int
    }
    var dbs: [DB] = []

    static func parse(_ raw: String) -> ServerInfo {
        var info = ServerInfo()
        for line in raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let s = String(line)
            if s.isEmpty || s.hasPrefix("#") { continue }
            guard let colon = s.firstIndex(of: ":") else { continue }
            let key = String(s[s.startIndex..<colon])
            let value = String(s[s.index(after: colon)...])
            switch key {
            case "redis_version":               info.version = value
            case "redis_mode":                  info.mode = value
            case "role":                        info.role = value
            case "os":                          info.os = value
            case "process_id":                  info.processID = Int(value)
            case "uptime_in_seconds":           info.uptimeSeconds = Int(value)
            case "connected_clients":           info.connectedClients = Int(value)
            case "used_memory_human":           info.usedMemoryHuman = value
            case "used_memory_peak_human":      info.usedMemoryPeakHuman = value
            case "used_memory_rss_human":       info.usedMemoryRSSHuman = value
            case "maxmemory_human":             info.maxMemoryHuman = value
            case "mem_fragmentation_ratio":     info.memFragmentationRatio = Double(value)
            case "total_connections_received":  info.totalConnectionsReceived = Int(value)
            case "total_commands_processed":    info.totalCommandsProcessed = Int(value)
            case "instantaneous_ops_per_sec":   info.instantOpsPerSec = Int(value)
            case "keyspace_hits":               info.keyspaceHits = Int(value)
            case "keyspace_misses":             info.keyspaceMisses = Int(value)
            default:
                // dbN:keys=K,expires=E,avg_ttl=T
                if key.hasPrefix("db"),
                   let n = Int(key.dropFirst(2)) {
                    var keys = 0
                    var expires = 0
                    for part in value.split(separator: ",") {
                        let kv = part.split(separator: "=")
                        guard kv.count == 2 else { continue }
                        switch kv[0] {
                        case "keys":    keys = Int(kv[1]) ?? 0
                        case "expires": expires = Int(kv[1]) ?? 0
                        default: break
                        }
                    }
                    info.dbs.append(DB(db: n, keys: keys, expires: expires))
                }
            }
        }
        info.dbs.sort { $0.db < $1.db }
        return info
    }
}
