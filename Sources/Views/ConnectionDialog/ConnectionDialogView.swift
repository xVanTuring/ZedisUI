import SwiftUI
import UniformTypeIdentifiers

struct ConnectionDialogView: View {
    enum Mode {
        case create
        case edit(Connection)

        var title: String {
            switch self {
            case .create: return "New Connection"
            case .edit:   return "Edit Connection"
            }
        }
    }

    let mode: Mode
    let onSave: (Connection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Connection
    @State private var password: String = ""

    // SSH tunnel — kept as separate UI state so the user can toggle
    // it on/off without losing what they typed.
    @State private var sshEnabled: Bool = false
    @State private var sshDraft: SSHTunnelConfig = SSHTunnelConfig()
    @State private var sshPassword: String = ""
    @State private var sshPassphrase: String = ""
    @State private var keyPickerPresented: Bool = false

    @State private var testStatus: TestStatus = .idle

    enum TestStatus {
        case idle
        case running
        case ok(String)
        case fail(String)
    }

    init(mode: Mode, onSave: @escaping (Connection) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            self._draft = State(initialValue: Connection())
        case .edit(let existing):
            self._draft = State(initialValue: existing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.title3.bold())

            Form {
                Section("Redis") {
                    TextField("Display Name", text: $draft.name)
                    TextField("Host", text: $draft.host)
                    LabeledContent("Port") {
                        HStack(spacing: 16) {
                            TextField("", value: $draft.port, formatter: portFormatter)
                                .frame(width: 80)
                                .labelsHidden()
                            Divider().frame(height: 14)
                            Text("DB").foregroundStyle(.secondary)
                            TextField("", value: $draft.defaultDB, formatter: dbFormatter)
                                .frame(width: 50)
                                .labelsHidden()
                            Spacer()
                        }
                    }
                    TextField("Username (Redis 6+ ACL, optional)", text: Binding(
                        get: { draft.username ?? "" },
                        set: { draft.username = $0.isEmpty ? nil : $0 }
                    ))
                    SecureField("Password (optional)", text: $password)
                    Toggle("Save password in Keychain", isOn: $draft.savePassword)
                    TextField("Default key pattern", text: $draft.defaultPattern)
                }

                Section {
                    Toggle("Use SSH Tunnel", isOn: $sshEnabled)
                    if sshEnabled {
                        sshFields
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Test Connection") {
                    Task { await test() }
                }
                .disabled(testStatus.isRunning)

                statusView
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.host.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .onAppear(perform: loadInitialSecrets)
        .fileImporter(
            isPresented: $keyPickerPresented,
            allowedContentTypes: [.data, .text, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleKeyPick(result)
        }
    }

    private func handleKeyPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            sshDraft.privateKeyPath = url.path
            sshDraft.privateKeyBookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        case .failure:
            break
        }
    }

    // MARK: - SSH fields

    @ViewBuilder
    private var sshFields: some View {
        LabeledContent("SSH Host") {
            HStack(spacing: 16) {
                TextField("", text: $sshDraft.host)
                    .labelsHidden()
                Divider().frame(height: 14)
                Text("Port").foregroundStyle(.secondary)
                TextField("", value: $sshDraft.port, formatter: portFormatter)
                    .frame(width: 70)
                    .labelsHidden()
            }
        }
        TextField("SSH Username", text: $sshDraft.username)

        Picker("Authentication", selection: $sshDraft.authMethod) {
            Text("Password").tag(SSHTunnelConfig.AuthMethod.password)
            Text("Private Key").tag(SSHTunnelConfig.AuthMethod.privateKey)
        }
        .pickerStyle(.segmented)

        switch sshDraft.authMethod {
        case .password:
            SecureField("SSH Password", text: $sshPassword)
            Toggle("Save SSH password in Keychain", isOn: $sshDraft.savePassword)
        case .privateKey:
            HStack {
                Text("Key file:")
                Text(sshDraft.privateKeyPath ?? "—")
                    .foregroundStyle(sshDraft.privateKeyPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { keyPickerPresented = true }
            }
            SecureField("Passphrase (if key is encrypted)", text: $sshPassphrase)
            Toggle("Save passphrase in Keychain", isOn: $sshDraft.savePassphrase)
        }
    }

    // MARK: - Status view

    @ViewBuilder
    private var statusView: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .ok(let s):
            Label(s, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .fail(let s):
            Label(s, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)
        }
    }

    // MARK: - Lifecycle helpers

    private func loadInitialSecrets() {
        if case .edit(let existing) = mode {
            if existing.savePassword {
                password = KeychainHelper.password(for: existing.id) ?? ""
            }
            if let cfg = existing.sshTunnel {
                sshEnabled = true
                sshDraft = cfg
                if cfg.savePassword {
                    sshPassword = KeychainHelper.sshPassword(for: existing.id) ?? ""
                }
                if cfg.savePassphrase {
                    sshPassphrase = KeychainHelper.sshPassphrase(for: existing.id) ?? ""
                }
            }
        }
    }

    // MARK: - Test

    private func test() async {
        testStatus = .running

        // If SSH is enabled, bring the tunnel up first and dial 127.0.0.1.
        var tunnel: SSHTunnelService?
        var serviceHost = draft.host
        var servicePort = draft.port
        do {
            if sshEnabled {
                let credential = try buildTestCredential()
                let t = SSHTunnelService(
                    sshHost: sshDraft.host,
                    sshPort: sshDraft.port,
                    username: sshDraft.username,
                    credential: credential,
                    targetHost: draft.host,
                    targetPort: draft.port
                )
                let port = try await t.start()
                tunnel = t
                serviceHost = "127.0.0.1"
                servicePort = port
            }

            let svc = RedisService(
                host: serviceHost,
                port: servicePort,
                username: draft.username,
                password: password.isEmpty ? nil : password
            )
            try await svc.connect(initialDB: draft.defaultDB)
            let pong = (try? await svc.ping()) ?? "?"
            await svc.disconnect()
            if let tunnel { await tunnel.stop() }
            testStatus = .ok("OK · PING → \(pong)")
        } catch {
            if let tunnel { await tunnel.stop() }
            testStatus = .fail(error.localizedDescription)
        }
    }

    /// Build the credential the user just typed into the dialog (rather
    /// than loading from Keychain, which may not have been saved yet).
    private func buildTestCredential() throws -> SSHTunnelService.AuthCredential {
        switch sshDraft.authMethod {
        case .password:
            return .password(sshPassword)
        case .privateKey:
            let key = try readKeyFileNow()
            let pass = sshPassphrase.isEmpty ? nil : sshPassphrase
            return .privateKey(key: key, passphrase: pass)
        }
    }

    /// Reads the picked key file. The bookmark may not exist yet (user
    /// picked the file moments ago); falling back to the path works in
    /// that case because the security-scoped URL is still alive in this
    /// process.
    private func readKeyFileNow() throws -> String {
        if let bookmark = sshDraft.privateKeyBookmark {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return try String(contentsOf: url, encoding: .utf8)
        }
        if let path = sshDraft.privateKeyPath {
            return try String(
                contentsOfFile: (path as NSString).expandingTildeInPath,
                encoding: .utf8
            )
        }
        throw NSError(
            domain: "ZedisUI.SSH",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No private key file selected."]
        )
    }

    // MARK: - Commit

    private func commit() {
        // Redis password
        if draft.savePassword && !password.isEmpty {
            KeychainHelper.setPassword(password, for: draft.id)
        } else if !draft.savePassword {
            KeychainHelper.deletePassword(for: draft.id)
        }

        // SSH config + secrets
        if sshEnabled {
            draft.sshTunnel = sshDraft
            switch sshDraft.authMethod {
            case .password:
                if sshDraft.savePassword && !sshPassword.isEmpty {
                    KeychainHelper.setSSHPassword(sshPassword, for: draft.id)
                } else {
                    KeychainHelper.deleteSSHPassword(for: draft.id)
                }
                KeychainHelper.deleteSSHPassphrase(for: draft.id)
            case .privateKey:
                if sshDraft.savePassphrase && !sshPassphrase.isEmpty {
                    KeychainHelper.setSSHPassphrase(sshPassphrase, for: draft.id)
                } else {
                    KeychainHelper.deleteSSHPassphrase(for: draft.id)
                }
                KeychainHelper.deleteSSHPassword(for: draft.id)
            }
        } else {
            draft.sshTunnel = nil
            KeychainHelper.deleteSSHPassword(for: draft.id)
            KeychainHelper.deleteSSHPassphrase(for: draft.id)
        }

        onSave(draft)
        dismiss()
    }

    // MARK: - Formatters

    private var portFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 65535
        return f
    }

    private var dbFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 0
        f.maximum = 255
        return f
    }
}

private extension ConnectionDialogView.TestStatus {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
