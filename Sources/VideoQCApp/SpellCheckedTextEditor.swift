import SwiftUI
import AppKit

/// Multi-line plain-text editor backed by NSTextView, with the system spellchecker (red underlines, right-click
/// suggestions, Learn/Ignore Spelling). Auto-correction and smart substitutions are off: subtitle text must only
/// change when the user changes it. Sizes itself to its text height.
struct SpellCheckedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12
    var textColor: NSColor
    /// Applied whenever `selectionToken` changes (find / spelling navigation).
    var selection: NSRange? = nil
    var selectionToken: Int = 0
    var onEscape: () -> Void = {}
    var onEndEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = FocusOnAttachTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        applyStyle(to: textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        applyStyle(to: textView)
        if selectionToken != context.coordinator.appliedSelectionToken, let selection = selection {
            context.coordinator.appliedSelectionToken = selectionToken
            let length = (textView.string as NSString).length
            let clamped = NSRange(location: min(selection.location, length), length: max(0, min(selection.length, length - min(selection.location, length))))
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(clamped)
                textView.scrollRangeToVisible(clamped)
                if clamped.length > 0 { textView.showFindIndicator(for: clamped) }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 260
        let padding = (nsView.textContainer?.lineFragmentPadding ?? 5) * 2 + nsView.textContainerInset.width * 2
        let font = nsView.font ?? NSFont.systemFont(ofSize: fontSize)
        let measured = NSAttributedString(string: nsView.string.isEmpty ? " " : nsView.string, attributes: [.font: font])
            .boundingRect(with: CGSize(width: max(10, width - padding), height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: ceil(measured.height) + nsView.textContainerInset.height * 2 + 2)
    }

    private func applyStyle(to textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        if textView.font != font { textView.font = font }
        if textView.textColor != textColor { textView.textColor = textColor }
        textView.insertionPointColor = textColor
    }

    /// Takes keyboard focus as soon as it is in a window (caret at the end), so typing edits the text
    /// instead of reaching the player's keyboard shortcuts.
    final class FocusOnAttachTextView: NSTextView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.window === window else { return }
                window.makeFirstResponder(self)
                if self.selectedRange() == NSRange(location: 0, length: 0) {
                    self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpellCheckedTextEditor
        var appliedSelectionToken: Int = -1

        init(parent: SpellCheckedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
