import SwiftUI
import AppKit

/// Search mode used by per-type editors. The mode picks how the user's
/// text is translated into a Redis glob pattern (or sent verbatim).
enum SearchMode: String, CaseIterable, Identifiable {
    case contain
    case startswith
    case endswith
    case glob

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contain:    return "Contains"
        case .startswith: return "Starts with"
        case .endswith:   return "Ends with"
        case .glob:       return "Glob"
        }
    }
}

/// Translate a user query + mode into a Redis glob pattern. Returns nil
/// when the query is empty (caller should drop the MATCH clause). For
/// non-glob modes the user's text is escaped so literal `*` `?` `[` `]`
/// don't accidentally turn it into a wildcard.
func buildGlobPattern(_ query: String, mode: SearchMode) -> String? {
    let trimmed = query
    guard !trimmed.isEmpty else { return nil }
    switch mode {
    case .glob:
        return trimmed
    case .contain:
        return "*\(escapeGlob(trimmed))*"
    case .startswith:
        return "\(escapeGlob(trimmed))*"
    case .endswith:
        return "*\(escapeGlob(trimmed))"
    }
}

/// Build a client-side predicate matching the same semantics as
/// `buildGlobPattern`. Returns nil for an empty query. Used by List,
/// which has no server-side SCAN-with-MATCH primitive.
func makeGlobMatcher(_ query: String, mode: SearchMode) -> ((String) -> Bool)? {
    guard !query.isEmpty else { return nil }
    switch mode {
    case .contain:    return { $0.localizedStandardContains(query) }
    case .startswith: return { $0.hasPrefix(query) }
    case .endswith:   return { $0.hasSuffix(query) }
    case .glob:
        guard let regex = globToRegex(query) else { return { _ in false } }
        return { value in
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, options: [], range: range) != nil
        }
    }
}

private func globToRegex(_ pattern: String) -> NSRegularExpression? {
    var rx = "^"
    var i = pattern.startIndex
    while i < pattern.endIndex {
        let c = pattern[i]
        switch c {
        case "*":
            rx += ".*"
        case "?":
            rx += "."
        case "\\":
            let next = pattern.index(after: i)
            if next < pattern.endIndex {
                rx += NSRegularExpression.escapedPattern(for: String(pattern[next]))
                i = pattern.index(after: next)
                continue
            }
        default:
            rx += NSRegularExpression.escapedPattern(for: String(c))
        }
        i = pattern.index(after: i)
    }
    rx += "$"
    return try? NSRegularExpression(pattern: rx)
}

private func escapeGlob(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        if ch == "*" || ch == "?" || ch == "[" || ch == "]" || ch == "\\" {
            out.append("\\")
        }
        out.append(ch)
    }
    return out
}

/// Shared search bar rendered above the per-type editor table.
///
/// The bound `query` is the **committed** search — only updated when the
/// user presses Enter (or clears the field). Typing into the TextField
/// edits a local `draft`, so editors don't re-query on every keystroke.
/// `mode` is committed eagerly since it's a discrete picker click.
struct EditorSearchBar: View {
    @Binding var query: String
    @Binding var mode: SearchMode
    var placeholder: String = "Search…"

    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .controlSize(.small)
                .onSubmit {
                    query = draft
                }
            if !draft.isEmpty {
                Button {
                    draft = ""
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Picker("", selection: $mode) {
                ForEach(SearchMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onAppear { draft = query }
        // Keep `draft` in sync when the editor resets `query` externally
        // (e.g. on key switch). Avoid clobbering a draft the user is still
        // typing — only sync when query and draft genuinely disagree on
        // the empty/non-empty axis or query was just reset.
        .onChange(of: query) { _, new in
            if new.isEmpty && draft != "" {
                draft = ""
            } else if !new.isEmpty && draft != new {
                draft = new
            }
        }
    }
}
