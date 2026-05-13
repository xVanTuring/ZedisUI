import SwiftUI

/// Inline command-query panel — Medis style. Plain text input at top with
/// a SwiftUI candidate list directly below it (no floating popover): as the
/// user types the first token of a line, matching Redis commands appear;
/// ↑↓ navigate, ⏎ or Tab accepts, Esc dismisses for this prefix. ⌘⏎ runs
/// the line under the cursor (or every non-empty line covered by the
/// current selection).
struct CommandQueryView: View {
    let session: RedisSession

    @State private var script: String = ""
    @State private var selection: NSRange = NSRange(location: 0, length: 0)
    @State private var suggestionIndex: Int = 0
    @State private var dismissedPrefix: String? = nil
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
            editorArea
            actionBar
            output
        }
    }

    // MARK: - Editor + suggestion stack

    private var editorArea: some View {
        VStack(spacing: 0) {
            input
                .frame(minHeight: 80, idealHeight: 140, maxHeight: .infinity)

            if showSuggestions {
                Divider()
                suggestionList
                    .frame(height: 180)
                Divider()
                docPanel
                    .frame(height: 56)
            }
        }
        .background(Color.black.opacity(0.25))
    }

    private var input: some View {
        RedisCommandInput(
            text: $script,
            selection: $selection,
            onMoveDown: {
                guard showSuggestions else { return false }
                suggestionIndex = (suggestionIndex + 1) % suggestions.count
                return true
            },
            onMoveUp: {
                guard showSuggestions else { return false }
                suggestionIndex = (suggestionIndex - 1 + suggestions.count) % suggestions.count
                return true
            },
            onAccept: {
                guard showSuggestions, suggestions.indices.contains(suggestionIndex) else {
                    return false
                }
                accept(suggestion: suggestions[suggestionIndex])
                return true
            },
            onCancel: {
                guard showSuggestions else { return false }
                dismissedPrefix = currentTokenInfo?.prefix
                return true
            },
            onExecute: { runFromSelection() }
        )
        .onChange(of: script) { _, _ in
            // New text means a new prefix — reopen suggestions if we had
            // dismissed them for a previous prefix.
            if let dismissed = dismissedPrefix,
               currentTokenInfo?.prefix != dismissed {
                dismissedPrefix = nil
            }
            suggestionIndex = 0
        }
        .overlay(alignment: .topLeading) {
            if script.isEmpty {
                // Leading = LineNumberRulerView initial thickness (30) +
                //           textContainerInset.width (6). Vertical = inset 10.
                // The placeholder only renders when there's 1 line, so the
                // gutter stays at its minimum width here.
                Text("Type Redis commands, one per line. ⌘⏎ runs the line under the cursor.")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.name) { idx, cmd in
                        suggestionRow(cmd: cmd, selected: idx == suggestionIndex)
                            .id(cmd.name)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                suggestionIndex = idx
                                accept(suggestion: cmd)
                            }
                    }
                }
                .padding(.vertical, 2)
            }
            .background(Color.black.opacity(0.35))
            .onChange(of: suggestionIndex) { _, new in
                guard suggestions.indices.contains(new) else { return }
                proxy.scrollTo(suggestions[new].name, anchor: .center)
            }
        }
    }

    private func suggestionRow(cmd: RedisCommand, selected: Bool) -> some View {
        HStack(spacing: 8) {
            HighlightedText(
                fullText: cmd.name,
                highlight: currentTokenInfo?.prefix ?? "",
                baseColor: selected ? .white : .primary,
                accentColor: selected ? .white : .accentColor
            )
            .font(.system(.body, design: .monospaced))

            Spacer(minLength: 8)
            Text(cmd.summary)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear)
    }

    private var docPanel: some View {
        HStack {
            if suggestions.indices.contains(suggestionIndex) {
                let cmd = suggestions[suggestionIndex]
                VStack(alignment: .leading, spacing: 2) {
                    Text(cmd.name).font(.system(.callout, design: .monospaced)).bold()
                    Text(cmd.summary).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.45))
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            Text(commandHintLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if running {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button {
                runFromSelection()
            } label: {
                HStack(spacing: 4) {
                    Text("Execute")
                    Text("⌘⏎")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(running || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    // MARK: - Output

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

    // MARK: - Suggestions

    /// The token under the caret, if it qualifies for completion.
    private var currentTokenInfo: (prefix: String, range: NSRange)? {
        let cursor = selection.location
        let ns = script as NSString
        guard cursor <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
        var contentLen = lineRange.length
        if contentLen > 0 {
            let last = ns.character(at: lineRange.location + contentLen - 1)
            if last == 0x0A { contentLen -= 1 }
        }
        // Walk back from the cursor over identifier chars to find the first
        // token's bounds, and ensure no whitespace token precedes the caret
        // on this line (which would imply we're past the first token).
        var i = cursor
        let lineStart = lineRange.location
        while i > lineStart {
            let c = ns.character(at: i - 1)
            if isIdentifierChar(c) { i -= 1 } else { break }
        }
        let tokenStart = i
        // Check that everything between lineStart and tokenStart is whitespace
        for j in lineStart..<tokenStart {
            let c = ns.character(at: j)
            if c != 0x20 && c != 0x09 { return nil }
        }
        let prefixLen = cursor - tokenStart
        guard prefixLen > 0 else { return nil }
        let prefix = ns.substring(with: NSRange(location: tokenStart, length: prefixLen))
        // Token range we'll replace on accept extends from tokenStart over
        // any contiguous identifier chars after the caret (so accepting in
        // the middle of "se|t" still replaces all of "set").
        var end = cursor
        let lineEnd = lineRange.location + contentLen
        while end < lineEnd {
            let c = ns.character(at: end)
            if isIdentifierChar(c) { end += 1 } else { break }
        }
        return (prefix, NSRange(location: tokenStart, length: end - tokenStart))
    }

    private var suggestions: [RedisCommand] {
        guard let info = currentTokenInfo else { return [] }
        if info.prefix == dismissedPrefix { return [] }
        return RedisCommandGrammar.match(prefix: info.prefix)
    }

    private var showSuggestions: Bool {
        !suggestions.isEmpty
    }

    private func accept(suggestion cmd: RedisCommand) {
        guard let info = currentTokenInfo else { return }
        let ns = script as NSString
        let endPos = info.range.location + info.range.length
        let hasTrailingSpace: Bool = {
            guard endPos < ns.length else { return false }
            let c = ns.character(at: endPos)
            return c == 0x20 || c == 0x09
        }()
        let insertText = hasTrailingSpace ? cmd.name : (cmd.name + " ")
        let newScript = ns.replacingCharacters(in: info.range, with: insertText)
        script = newScript
        // Land the caret just past the (kept-or-inserted) space so the user
        // can keep typing the next token immediately.
        let newCursor = info.range.location + (cmd.name as NSString).length + 1
        selection = NSRange(location: newCursor, length: 0)
        // Reset dismissal — user just made a choice.
        dismissedPrefix = nil
    }

    private func isIdentifierChar(_ c: unichar) -> Bool {
        // A-Z, a-z, 0-9, '_', '.', '-'
        return (c >= 0x41 && c <= 0x5A)
            || (c >= 0x61 && c <= 0x7A)
            || (c >= 0x30 && c <= 0x39)
            || c == 0x5F || c == 0x2E || c == 0x2D
    }

    // MARK: - Execute

    private var commandHintLabel: String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No commands · ⌘⏎ runs the cursor line / selection" }
        let n = script.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let suffix = "⌘⏎ runs the cursor line / selection"
        if n <= 1 { return "1 line · \(suffix)" }
        return "\(n) lines · \(suffix)"
    }

    private func runFromSelection() {
        let ns = script as NSString
        let sel = selection
        let safe = NSRange(
            location: max(0, min(sel.location, ns.length)),
            length: max(0, min(sel.length, max(0, ns.length - min(sel.location, ns.length))))
        )
        let targetRange = ns.lineRange(for: safe)
        guard targetRange.length > 0 || ns.length > 0 else { return }
        let block = ns.substring(with: targetRange)
        let cmds = block
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cmds.isEmpty else { return }
        Task { await runBatch(cmds) }
    }

    private func runBatch(_ cmds: [String]) async {
        guard !running else { return }
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

// MARK: - Helpers

/// Renders `fullText` with `highlight` (case-insensitive prefix or
/// substring) shown in `accentColor`; the rest in `baseColor`.
private struct HighlightedText: View {
    let fullText: String
    let highlight: String
    let baseColor: Color
    let accentColor: Color

    var body: some View {
        if highlight.isEmpty {
            Text(fullText).foregroundStyle(baseColor)
        } else if let range = fullText
            .range(of: highlight, options: [.caseInsensitive, .anchored]) {
            let head = String(fullText[range])
            let tail = String(fullText[range.upperBound...])
            (Text(head).foregroundStyle(accentColor).bold()
                + Text(tail).foregroundStyle(baseColor))
        } else {
            Text(fullText).foregroundStyle(baseColor)
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
