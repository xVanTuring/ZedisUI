import SwiftUI

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
                TextField("Display Name", text: $draft.name)
                TextField("Host", text: $draft.host)
                HStack {
                    TextField("Port", value: $draft.port, formatter: portFormatter)
                        .frame(maxWidth: 80)
                    Spacer()
                    TextField("Default DB", value: $draft.defaultDB, formatter: dbFormatter)
                        .frame(maxWidth: 80)
                }
                TextField("Username (Redis 6+ ACL, optional)", text: Binding(
                    get: { draft.username ?? "" },
                    set: { draft.username = $0.isEmpty ? nil : $0 }
                ))
                SecureField("Password (optional)", text: $password)
                Toggle("Save password in Keychain", isOn: $draft.savePassword)
                TextField("Default key pattern", text: $draft.defaultPattern)
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
        .frame(minWidth: 460)
        .onAppear {
            if case .edit(let existing) = mode, existing.savePassword {
                password = KeychainHelper.password(for: existing.id) ?? ""
            }
        }
    }

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
                .lineLimit(2)
        }
    }

    private func test() async {
        testStatus = .running
        let svc = RedisService(
            host: draft.host,
            port: draft.port,
            username: draft.username,
            password: password.isEmpty ? nil : password
        )
        do {
            try await svc.connect(initialDB: draft.defaultDB)
            let pong = (try? await svc.ping()) ?? "?"
            await svc.disconnect()
            testStatus = .ok("OK · PING → \(pong)")
        } catch {
            testStatus = .fail(error.localizedDescription)
        }
    }

    private func commit() {
        if draft.savePassword && !password.isEmpty {
            KeychainHelper.setPassword(password, for: draft.id)
        } else if !draft.savePassword {
            KeychainHelper.deletePassword(for: draft.id)
        }
        onSave(draft)
        dismiss()
    }

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
