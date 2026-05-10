import SwiftUI

/// Inline command-query panel — Medis style. Top: multi-line script editor.
/// Bottom: output log. ⌘⏎ runs whichever line(s) are "selected" (for now,
/// runs all non-empty lines in the editor).
struct CommandQueryView: View {
    let session: RedisSession

    @State private var script: String = ""
    @State private var lines: [TerminalLine] = []
    @State private var running = false

    struct TerminalLine: Identifiable {
        let id = UUID()
        let kind: Kind
        let text: String
        enum Kind { case input, output, error }
    }

    var body: some View {
        VStack(spacing: 0) {
            editor
            actionBar
            output
        }
    }

    // MARK: - Editor (top half)

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.25)
            TextEditor(text: $script)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
            if script.isEmpty {
                Text("Type Redis commands here, one per line. ⌘⏎ to execute.")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 120, idealHeight: 220, maxHeight: .infinity)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            Text(commandCountLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if running {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button {
                Task { await runAll() }
            } label: {
                HStack(spacing: 4) {
                    Text("Execute")
                    Text("⌘⏎")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(commandLines.isEmpty || running)
            .controlSize(.regular)

            Button {
                lines = []
            } label: {
                Image(systemName: "trash")
            }
            .disabled(lines.isEmpty)
            .controlSize(.regular)
            .help("Clear output")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Output (bottom half)

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("Output will appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        ForEach(lines) { line in
                            TerminalLineView(line: line)
                                .id(line.id)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.45))
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(minHeight: 120, idealHeight: 220, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var commandLines: [String] {
        script.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var commandCountLabel: String {
        let n = commandLines.count
        if n == 0 { return "No command" }
        if n == 1 { return "1 command" }
        return "\(n) commands"
    }

    private func runAll() async {
        guard !running else { return }
        let cmds = commandLines
        guard !cmds.isEmpty else { return }
        running = true
        defer { running = false }
        for cmd in cmds {
            lines.append(.init(kind: .input, text: cmd))
            do {
                let pretty = try await session.service.runCommandLine(cmd)
                lines.append(.init(kind: .output, text: pretty))
            } catch {
                lines.append(.init(kind: .error, text: error.localizedDescription))
            }
        }
    }
}

private struct TerminalLineView: View {
    let line: CommandQueryView.TerminalLine

    var body: some View {
        Text(prefix + line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prefix: String {
        switch line.kind {
        case .input:  return "> "
        case .output: return ""
        case .error:  return "!! "
        }
    }

    private var color: Color {
        switch line.kind {
        case .input:  return .white
        case .output: return Color(nsColor: .systemGreen).opacity(0.95)
        case .error:  return .red
        }
    }
}
