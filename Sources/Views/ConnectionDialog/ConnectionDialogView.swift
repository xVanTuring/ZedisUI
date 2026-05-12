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
    /// Toggle that enables/disables the Redis password row. Driven by
    /// `draft.passwordMode != nil`; flipping it on defaults the mode to
    /// `.keychain`, off clears the mode + clears the typed password.
    @State private var passwordEnabled: Bool = false
    /// Drives the "what is Username?" popover anchored on the info icon.
    /// SwiftUI's `.help()` doesn't reliably fire on small Images, so we
    /// use an explicit click-to-show popover instead.
    @State private var usernameHintShown: Bool = false

    // SSH tunnel — kept as separate UI state so the user can toggle
    // it on/off without losing what they typed.
    @State private var sshEnabled: Bool = false
    @State private var sshDraft: SSHTunnelConfig = SSHTunnelConfig()
    @State private var sshPassword: String = ""
    @State private var sshPassphrase: String = ""
    /// Toggle that enables/disables the passphrase row for private-key
    /// auth. Mirrors `sshDraft.passphraseMode != nil`.
    @State private var sshPassphraseEnabled: Bool = false
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
                    LabeledContent {
                        HStack(spacing: 6) {
                            TextField("", text: Binding(
                                get: { draft.username ?? "" },
                                set: { draft.username = $0.isEmpty ? nil : $0 }
                            ))
                            .labelsHidden()
                            Button {
                                usernameHintShown.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $usernameHintShown, arrowEdge: .top) {
                                Text("Optional. Used for Redis 6+ ACL authentication.")
                                    .font(.callout)
                                    .padding(12)
                                    .frame(maxWidth: 260)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } label: {
                        Text("Username")
                    }
                    Toggle("Requires password", isOn: Binding(
                        get: { passwordEnabled },
                        set: { enabled in
                            passwordEnabled = enabled
                            if enabled {
                                if draft.passwordMode == nil { draft.passwordMode = .keychain }
                            } else {
                                draft.passwordMode = nil
                                password = ""
                            }
                        }
                    ))
                    if passwordEnabled {
                        credentialRow(
                            label: "Password",
                            secret: $password,
                            mode: Binding(
                                get: { draft.passwordMode ?? .keychain },
                                set: { draft.passwordMode = $0 }
                            )
                        )
                    }
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
            credentialRow(
                label: "SSH Password",
                secret: $sshPassword,
                mode: $sshDraft.passwordMode
            )
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
            Toggle("Key is encrypted (passphrase)", isOn: Binding(
                get: { sshPassphraseEnabled },
                set: { enabled in
                    sshPassphraseEnabled = enabled
                    if enabled {
                        if sshDraft.passphraseMode == nil { sshDraft.passphraseMode = .keychain }
                    } else {
                        sshDraft.passphraseMode = nil
                        sshPassphrase = ""
                    }
                }
            ))
            if sshPassphraseEnabled {
                credentialRow(
                    label: "Passphrase",
                    secret: $sshPassphrase,
                    mode: Binding(
                        get: { sshDraft.passphraseMode ?? .keychain },
                        set: { sshDraft.passphraseMode = $0 }
                    )
                )
            }
        }
    }

    /// One labeled row holding a SecureField + a compact storage-mode
    /// dropdown to its right. Shared by all three credential rows (Redis
    /// password / SSH password / SSH key passphrase). When the mode is
    /// `.askEachTime` the field is disabled and shows a placeholder, so
    /// it's visually obvious nothing typed here will be persisted.
    @ViewBuilder
    private func credentialRow(
        label: String,
        secret: Binding<String>,
        mode: Binding<CredentialMode>
    ) -> some View {
        let ask = mode.wrappedValue == .askEachTime
        LabeledContent(label) {
            HStack(spacing: 8) {
                SecureField(ask ? "Asked at connect time" : "", text: secret)
                    .labelsHidden()
                    .disabled(ask)
                Picker("", selection: mode) {
                    Text("Keychain").tag(CredentialMode.keychain)
                    Text("Ask").tag(CredentialMode.askEachTime)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }
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
            passwordEnabled = existing.passwordMode != nil
            if existing.passwordMode == .keychain {
                password = KeychainHelper.password(for: existing.id) ?? ""
            }
            if let cfg = existing.sshTunnel {
                sshEnabled = true
                sshDraft = cfg
                if cfg.passwordMode == .keychain {
                    sshPassword = KeychainHelper.sshPassword(for: existing.id) ?? ""
                }
                sshPassphraseEnabled = cfg.passphraseMode != nil
                if cfg.passphraseMode == .keychain {
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
                password: passwordEnabled && !password.isEmpty ? password : nil
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
            let pass = (sshPassphraseEnabled && !sshPassphrase.isEmpty) ? sshPassphrase : nil
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
        // Redis password — persist to Keychain only when mode == .keychain.
        // For .askEachTime we explicitly wipe any stale entry. For "none"
        // (toggle off / passwordMode == nil) we also wipe.
        switch draft.passwordMode {
        case .keychain:
            if !password.isEmpty {
                KeychainHelper.setPassword(password, for: draft.id)
            } else {
                KeychainHelper.deletePassword(for: draft.id)
            }
        case .askEachTime, .none:
            KeychainHelper.deletePassword(for: draft.id)
        }

        // SSH config + secrets
        if sshEnabled {
            draft.sshTunnel = sshDraft
            switch sshDraft.authMethod {
            case .password:
                switch sshDraft.passwordMode {
                case .keychain:
                    if !sshPassword.isEmpty {
                        KeychainHelper.setSSHPassword(sshPassword, for: draft.id)
                    } else {
                        KeychainHelper.deleteSSHPassword(for: draft.id)
                    }
                case .askEachTime:
                    KeychainHelper.deleteSSHPassword(for: draft.id)
                }
                KeychainHelper.deleteSSHPassphrase(for: draft.id)
            case .privateKey:
                switch sshDraft.passphraseMode {
                case .keychain:
                    if !sshPassphrase.isEmpty {
                        KeychainHelper.setSSHPassphrase(sshPassphrase, for: draft.id)
                    } else {
                        KeychainHelper.deleteSSHPassphrase(for: draft.id)
                    }
                case .askEachTime, .none:
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
