import SwiftUI
import AppKit

// Plain-text NSTextView wrapped for SwiftUI, with JSON syntax highlighting.
// All of macOS's "smart" substitutions are off — typing `"` inserts `"`,
// not a curly quote, which is what code editors need.

struct JSONCodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }
        configure(tv, coordinator: context.coordinator)
        tv.string = text
        highlightJSON(in: tv)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        // Only sync external edits — the coordinator already updated text
        // from typing, so tv.string and text will be equal then.
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            highlightJSON(in: tv)
            let safeLoc = min(sel.location, (text as NSString).length)
            tv.setSelectedRange(NSRange(location: safeLoc, length: 0))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func configure(_ tv: NSTextView, coordinator: Coordinator) {
        // Kill every auto-substitution — "" -> "" is the worst offender.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false

        tv.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = coordinator
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.drawsBackground = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: JSONCodeEditor
        init(_ p: JSONCodeEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            highlightJSON(in: tv)
        }
    }
}

// MARK: - Syntax highlighting

// Tokens are colored to match the same accent palette used by JSONNode.Kind
// in the tree editor so the two views feel like one product.

private enum JSONTokenKind {
    case key, string, number, bool, null

    var color: NSColor {
        switch self {
        case .key:    return NSColor(red: 0.55, green: 0.85, blue: 0.95, alpha: 1.0)
        case .string: return NSColor(red: 0.96, green: 0.72, blue: 0.35, alpha: 1.0)
        case .number: return NSColor(red: 0.55, green: 0.85, blue: 0.55, alpha: 1.0)
        case .bool:   return NSColor(red: 1.00, green: 0.55, blue: 0.55, alpha: 1.0)
        case .null:   return NSColor.secondaryLabelColor
        }
    }
}

// Compiled once at module load; throwing here would be a programmer error.
private let jsonStringRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
private let jsonNumberRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z_])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
private let jsonKeywordRegex = try! NSRegularExpression(pattern: #"\b(?:true|false|null)\b"#)

private func highlightJSON(in tv: NSTextView) {
    guard let storage = tv.textStorage else { return }
    let s = tv.string
    let ns = s as NSString
    let fullRange = NSRange(location: 0, length: ns.length)

    storage.beginEditing()
    defer { storage.endEditing() }

    // Reset to defaults first so deleted tokens don't keep stale color.
    storage.setAttributes([
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ], range: fullRange)

    // Strings first; record their ranges so we can skip numbers/keywords
    // that appear inside string literals.
    var stringRanges: [NSRange] = []
    for m in jsonStringRegex.matches(in: s, range: fullRange) {
        stringRanges.append(m.range)
        let isKey = isFollowedByColon(at: m.range.location + m.range.length, in: ns)
        let kind: JSONTokenKind = isKey ? .key : .string
        storage.addAttribute(.foregroundColor, value: kind.color, range: m.range)
    }

    for m in jsonNumberRegex.matches(in: s, range: fullRange) {
        if !isInsideAny(m.range, in: stringRanges) {
            storage.addAttribute(.foregroundColor, value: JSONTokenKind.number.color, range: m.range)
        }
    }

    for m in jsonKeywordRegex.matches(in: s, range: fullRange) {
        if isInsideAny(m.range, in: stringRanges) { continue }
        let word = ns.substring(with: m.range)
        let kind: JSONTokenKind = (word == "null") ? .null : .bool
        storage.addAttribute(.foregroundColor, value: kind.color, range: m.range)
    }
}

private func isFollowedByColon(at startIndex: Int, in ns: NSString) -> Bool {
    var i = startIndex
    while i < ns.length {
        let c = ns.character(at: i)
        if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
        else { return c == 0x3A } // ':'
    }
    return false
}

private func isInsideAny(_ range: NSRange, in ranges: [NSRange]) -> Bool {
    for r in ranges {
        if range.location >= r.location
            && range.location + range.length <= r.location + r.length {
            return true
        }
    }
    return false
}
