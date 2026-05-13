import SwiftUI
import AppKit

/// Minimal NSTextView wrapper for the Redis Command Query panel.
///
/// On purpose this view does **not** do syntax highlighting, line numbers,
/// or floating popovers. It just gives SwiftUI:
///   - a two-way `text` binding,
///   - a one-way `selection` callback (so the parent can compute the
///     current token under the caret),
///   - hooks to intercept ↑ ↓ ⏎ Tab Esc when a SwiftUI-rendered candidate
///     list is shown next to the editor, and
///   - a hook for ⌘⏎ to execute the cursor line / selection.
///
/// The candidate list lives in the parent (`CommandQueryView`) as a plain
/// SwiftUI view below the editor — no AppKit popover or extra window.
struct RedisCommandInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var onMoveDown: () -> Bool = { false }
    var onMoveUp: () -> Bool = { false }
    var onAccept: () -> Bool = { false }
    var onCancel: () -> Bool = { false }
    var onExecute: () -> Void = { }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = CommandTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.textContainer?.widthTracksTextView = true
        // Eliminate the default 5-pt fragment padding so the placeholder
        // overlay (positioned with SwiftUI padding) can line up with typed
        // text using only `textContainerInset` as the offset.
        textView.textContainer?.lineFragmentPadding = 0

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize,
                                                    weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.delegate = context.coordinator

        textView.onExecuteShortcut = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onExecute()
        }

        context.coordinator.textView = textView
        scrollView.documentView = textView
        textView.string = text

        // Line number gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(scrollView: scrollView,
                                        orientation: .verticalRuler)
        scrollView.verticalRulerView = ruler
        context.coordinator.rulerView = ruler
        ruler.refresh()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scrollView.documentView as? NSTextView else { return }

        let textChanged = tv.string != text
        if textChanged {
            tv.string = text
        }

        // Push the parent's intended selection down to the text view if it
        // differs. This is how `accept(suggestion:)` moves the caret to the
        // end of the inserted command.
        let len = (tv.string as NSString).length
        let safeLoc = max(0, min(selection.location, len))
        let safeLen = max(0, min(selection.length, max(0, len - safeLoc)))
        let target = NSRange(location: safeLoc, length: safeLen)
        if tv.selectedRange() != target {
            tv.setSelectedRange(target)
        }

        if textChanged { context.coordinator.rulerView?.refresh() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RedisCommandInput
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?

        init(_ p: RedisCommandInput) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            let sel = tv.selectedRange()
            if parent.selection != sel { parent.selection = sel }
            rulerView?.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let sel = tv.selectedRange()
            if parent.selection != sel { parent.selection = sel }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveDown()
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveUp()
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onAccept()
            case #selector(NSResponder.insertTab(_:)):
                // Tab always accepts a suggestion if one is offered; otherwise
                // swallow it — tab characters inside Redis commands are useless.
                if parent.onAccept() { return true }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCancel()
            default:
                return false
            }
        }
    }
}

// MARK: - Line number gutter

final class LineNumberRulerView: NSRulerView {
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        // 2 digits worth → matches `refresh()` output for an empty document.
        ruleThickness = 30
    }
    required init(coder: NSCoder) { fatalError("not used") }

    /// Re-measure thickness against line count and force a redraw. Coordinator
    /// calls this on text change.
    func refresh() {
        guard let tv = clientView as? NSTextView else { return }
        let lines = (tv.string as NSString).components(separatedBy: "\n").count
        let digits = max(2, "\(lines)".count)
        let target = CGFloat(digits) * 8 + 14
        if abs(ruleThickness - target) > 0.5 { ruleThickness = target }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer,
              let sv = self.scrollView else { return }

        NSColor.windowBackgroundColor.withAlphaComponent(0.4).setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let visibleRect = sv.contentView.bounds
        let containerOrigin = tv.textContainerOrigin
        let ns = tv.string as NSString

        var lineStarts: [Int] = [0]
        for i in 0..<ns.length where ns.character(at: i) == 0x0A {
            lineStarts.append(i + 1)
        }

        let defaultLineHeight = (tv.font?.boundingRectForFont.height) ?? 16
        for (idx, start) in lineStarts.enumerated() {
            let lineNum = idx + 1
            let isTrailingEmpty = (idx == lineStarts.count - 1) && start == ns.length

            let lineBox: NSRect
            if isTrailingEmpty {
                let extra = lm.extraLineFragmentRect
                if extra.height > 0 {
                    lineBox = extra
                } else if start == 0 {
                    lineBox = NSRect(x: 0, y: 0, width: 1, height: defaultLineHeight)
                } else {
                    continue
                }
            } else {
                let nextStart = idx + 1 < lineStarts.count ? lineStarts[idx + 1] : ns.length
                let trailingNL = idx + 1 < lineStarts.count ? 1 : 0
                let len = max(0, nextStart - start - trailingNL)
                let r = NSRange(location: start, length: len)
                let glyphRange = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                let computed = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                lineBox = computed.height > 0
                    ? computed
                    : NSRect(x: 0, y: computed.minY, width: 1, height: defaultLineHeight)
            }

            let yInTV = lineBox.minY + containerOrigin.y
            let yInRuler = yInTV - visibleRect.minY

            if yInRuler + lineBox.height < 0 { continue }
            if yInRuler > bounds.height { break }

            let s = "\(lineNum)" as NSString
            let size = s.size(withAttributes: attrs)
            let drawX = bounds.width - size.width - 6
            let baseline = yInRuler + max(0, (lineBox.height - size.height) / 2)
            s.draw(at: NSPoint(x: drawX, y: baseline), withAttributes: attrs)
        }
    }
}

// MARK: - NSTextView subclass for ⌘⏎

final class CommandTextView: NSTextView {
    var onExecuteShortcut: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Cmd + Return / Enter — bypass doCommandBy (which is bypassed by AppKit
        // for command-modified keys) and call the execute hook directly.
        if event.modifierFlags.contains(.command),
           event.keyCode == 36 || event.keyCode == 76 {
            onExecuteShortcut?()
            return
        }
        super.keyDown(with: event)
    }
}
