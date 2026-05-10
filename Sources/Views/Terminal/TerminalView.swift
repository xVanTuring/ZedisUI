import SwiftUI

struct TerminalView: View {
    let session: RedisSession
    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @State private var lines: [TerminalLine] = []
    @State private var history: [String] = []
    @State private var historyCursor: Int = 0
    @State private var running = false

    struct TerminalLine: Identifiable {
        let id = UUID()
        let kind: Kind
        let text: String
        enum Kind { case input, output, error }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                Text(session.connection.name)
                    .font(.headline)
                Text("·")
                Text("db\(session.currentDB)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { lines = [] }
                    .controlSize(.small)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(8)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            TerminalLineView(line: line)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.85))
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Text(">")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
                TerminalInputField(
                    text: $input,
                    onSubmit: { Task { await runCurrent() } },
                    onArrowUp: { recallHistory(direction: -1) },
                    onArrowDown: { recallHistory(direction: 1) }
                )
                .font(.system(.body, design: .monospaced))
                if running {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(8)
        }
    }

    private func runCurrent() async {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !running else { return }
        running = true
        lines.append(.init(kind: .input, text: line))
        history.append(line)
        historyCursor = history.count
        input = ""
        defer { running = false }
        do {
            let pretty = try await session.service.runCommandLine(line)
            lines.append(.init(kind: .output, text: pretty))
        } catch {
            lines.append(.init(kind: .error, text: error.localizedDescription))
        }
    }

    private func recallHistory(direction: Int) {
        guard !history.isEmpty else { return }
        let next = max(0, min(history.count, historyCursor + direction))
        if next == history.count {
            input = ""
        } else {
            input = history[next]
        }
        historyCursor = next
    }
}

private struct TerminalLineView: View {
    let line: TerminalView.TerminalLine

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
        case .output: return .green.opacity(0.9)
        case .error:  return .red
        }
    }
}

/// AppKit-backed text field that catches Up/Down for history navigation.
private struct TerminalInputField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = HistoryAwareTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.placeholderString = "Type a Redis command and press ⏎"
        tf.delegate = context.coordinator
        tf.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tf.target = context.coordinator
        tf.action = #selector(Coordinator.submit)
        tf.onArrowUp = onArrowUp
        tf.onArrowDown = onArrowDown
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if let h = nsView as? HistoryAwareTextField {
            h.onArrowUp = onArrowUp
            h.onArrowDown = onArrowDown
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalInputField
        init(_ parent: TerminalInputField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        @objc func submit() {
            parent.onSubmit()
        }
    }

    final class HistoryAwareTextField: NSTextField {
        var onArrowUp: (() -> Void)?
        var onArrowDown: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            switch event.specialKey {
            case .upArrow:
                onArrowUp?()
                return
            case .downArrow:
                onArrowDown?()
                return
            default:
                break
            }
            super.keyDown(with: event)
        }
    }
}
